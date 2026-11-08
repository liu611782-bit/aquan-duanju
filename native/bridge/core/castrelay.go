// castrelay 实现加密分集的局域网解密中继（方案文档 §5.4 / §7.2）：
//
//	电视(Renderer) ──GET /cast/<token>/index.m3u8──▶ Go 中继 ──ffmpeg -decryption_key──▶ 上游
//
// 设计要点（guoappxxx transcode.go 验证过的链路）：
//   - ffmpeg 子进程把「加密上游」转成明文 HLS（H.264/AAC，顺带解决 HEVC 兼容）；
//   - 中继只响应 /cast/<token>/ 前缀，token 每会话 32 位随机 hex（防局域网拖走）；
//   - 3 秒快检：进程提前退出（缺二进制/密钥错/输入不可读）立即报错，不让电视转圈；
//   - 会话回收三条路径：空闲 5 分钟 / castRelayStop / 进程退出；
//   - ffmpeg 环境强制清空代理变量（上游是签名直链，走系统代理会坏）。
package core

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

// relayOptions 是 castRelayStart 的入参（Dart 侧拍平后的播放要素）。
type relayOptions struct {
	URL         string `json:"url"`
	BackupURL   string `json:"backup_url"`
	DecKey      string `json:"dec_key"` // hex 内容密钥；空 = 未加密（不必要走中继，但允许）
	UserAgent   string `json:"user_agent"`
	Referer     string `json:"referer"`
	AudioURL    string `json:"audio_url"`    // DASH 双轨上游（可选）
	Format      string `json:"format"`       // 输出档位（R2）：""/"hls"（默认）| "ts"；未知值一律按 hls
	Quality     string `json:"quality"`      // 画质档位（R2）：high|balanced|compact；空/未知 = balanced（现状）
	SubtitleURL string `json:"subtitle_url"` // 会话字幕地址（R3）：非空时媒体响应带 CaptionInfo.sec
}

// relaySessionInfo 是 castRelayStart/Status 的出参。
type relaySessionInfo struct {
	Session   string             `json:"session"`
	Token     string             `json:"token"`
	Port      int                `json:"port"`
	URL       string             `json:"url"`
	Format    string             `json:"format"`
	LanIP     string             `json:"lanIp"` // 本机 LAN IP（R3：会话内缓存，诊断面板防火墙指引用）
	Encrypted bool               `json:"encrypted"`
	UptimeMs  int64              `json:"uptimeMs"`
	Segments  int                `json:"segments"`
	Ready     bool               `json:"ready"`
	Recent    []relayAccessEntry `json:"recent,omitempty"` // 电视取流环形日志（M0-5）
}

// relayAccessEntry 是一条电视取流记录（M0-5）：时间/路径/Range/UA/状态码/字节数。
type relayAccessEntry struct {
	Seq    int64  `json:"seq"` // 单调递增：Dart 侧按它去重新增记录
	At     string `json:"at"`  // 本地时间 HH:MM:SS
	Path   string `json:"path"`
	Range  string `json:"range,omitempty"`
	UA     string `json:"ua,omitempty"`
	Status int    `json:"status"`
	Bytes  int64  `json:"bytes"`
}

type relaySession struct {
	id          string
	token       string
	port        int
	dir         string
	cmd         *exec.Cmd
	srv         *http.Server
	startedAt   time.Time
	lastAccess  time.Time
	ready       bool
	encrypted   bool
	format      string // 输出档位："hls"（默认）| "ts"（R2）
	subtitleURL string // 会话字幕（R3）：serveCastFile 据此带 CaptionInfo.sec
	lanIP       string // 本机 LAN IP（R3）：会话内缓存一次，info() 不重复枚举网卡

	// 电视取流环形日志（M0-5）：最近 relayAccessLogSize 条。
	// 独立小锁：info() 会在持 relayMu 的调用点（castRelayStatus）里读取，
	// sync.Mutex 不可重入，共用 relayMu 会死锁。
	logMu     sync.Mutex
	accessLog []relayAccessEntry
	logSeq    int64

	// waitCh 在 ffmpeg 退出时关闭；waitErr 记录退出原因。
	// 不依赖 cmd.ProcessState：未调用 Wait() 时它恒为 nil，快检会失效。
	waitCh  chan struct{}
	waitErr error
}

var (
	relayMu       sync.Mutex
	relaySessions = map[string]*relaySession{}
	relaySweeper  *time.Ticker
)

const (
	relayBasePort      = 29170
	relayIdleTimeout   = 5 * time.Minute
	relayFastWait      = 3 * time.Second
	relayAccessLogSize = 32 // 电视取流环形日志容量
)

// 中继层哨兵错误：注册进 errorCodes 表（core.go），Dart 按 code 分级文案。
var (
	ErrRelayUnavailable = errors.New("relay unavailable")
	ErrRelayInvalid     = errors.New("relay invalid options")
	ErrRelayNoSession   = errors.New("relay no session")
	ErrRelayInternal    = errors.New("relay internal")
)

// relayFail 返回携带哨兵的可读错误：fmt.Errorf("%w: detail", sentinel)。
func relayFail(sentinel error, detail string) error {
	if detail == "" {
		return sentinel
	}
	return fmt.Errorf("%w: %s", sentinel, detail)
}

// castRelayStart 启动（或复用）一个解密中继会话。
// 入参：[optionsJSON]；出参：relaySessionInfo。
func castRelayStart(opts relayOptions) (*relaySessionInfo, error) {
	if opts.URL == "" {
		return nil, relayFail(ErrRelayInvalid, "缺少播放地址")
	}
	startSweeper()
	sweepOrphanDirs()

	// ffmpeg 可用性最先探（缺二进制是最常见的失败，秒回）。
	ffmpeg, err := findFFmpeg()
	if err != nil {
		return nil, relayFail(ErrRelayUnavailable,
			"未找到 ffmpeg，无法中继加密内容；请将 ffmpeg 放到应用目录或 PATH")
	}

	token, err := randomToken()
	if err != nil {
		return nil, relayFail(ErrRelayInternal, "token 生成失败")
	}
	dir, err := os.MkdirTemp("", "aquan-cast-")
	if err != nil {
		return nil, relayFail(ErrRelayInternal, "临时目录创建失败")
	}

	port, ln, err := listenOnFreePort(relayBasePort)
	if err != nil {
		os.RemoveAll(dir)
		return nil, relayFail(ErrRelayInternal, "端口监听失败")
	}
	srv := &http.Server{Handler: http.NotFoundHandler()}

	// 输出档位（R2）：空/未知值一律按 hls —— 旧调用方零改动（证据缺失回落现状）。
	if opts.Format != "ts" {
		opts.Format = "hls"
	}

	sessionID := token[:16]
	session := &relaySession{
		id:          sessionID,
		token:       token,
		port:        port,
		dir:         dir,
		srv:         srv,
		startedAt:   time.Now(),
		lastAccess:  time.Now(),
		encrypted:   opts.DecKey != "",
		format:      opts.Format,
		subtitleURL: opts.SubtitleURL,
		lanIP:       lanIP(), // 会话内缓存一次：info() 高频拉取不再重复枚举网卡
	}

	args := buildFFmpegArgs(ffmpeg, opts, dir, opts.DecKey)
	cmd := exec.Command(args[0], args[1:]...)
	// 上游是签名直链：清空代理环境（guoappxxx 同款坑）。
	cmd.Env = cleanProxyEnv()
	cmd.Stderr = nil // ffmpeg 日志体积大且含上游 URL：不落盘，靠退出码与快检判断。
	session.cmd = cmd
	if err := cmd.Start(); err != nil {
		srv.Close()
		os.RemoveAll(dir)
		return nil, relayFail(ErrRelayUnavailable, "ffmpeg 启动失败: "+err.Error())
	}
	// ffmpeg 挂进进程级 Job（KILL_ON_JOB_CLOSE）：app 被强杀/崩溃时子进程
	// 随父退出，不再残留孤儿转码消耗 CPU 与带宽（sweeper 只清目录不清进程）。
	assignFfmpegToJob(cmd.Process)
	session.waitCh = make(chan struct{})
	go func() {
		session.waitErr = cmd.Wait()
		close(session.waitCh)
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/cast/"+token+"/", session.serveCastFile)
	session.srv.Handler = mux
	go func() {
		_ = srv.Serve(ln) // 端口已预先绑定，不存在二次绑定竞态
	}()

	// 产物就绪判定按档位分流（R2）：hls = 清单+分片；ts = stream.ts > 64KB
	// （对齐 hls ready 的保守口径，起步阶段的空洞文件不算就绪）。
	productReady := func() bool {
		if opts.Format == "ts" {
			return tsReady(dir)
		}
		return indexReady(dir) && hasSegments(dir)
	}

	// 3 秒快检：进程提前退出时，若已产出清单与分片则视为「转码完成」
	// （短视频/小文件秒级完成，静态服务即可），否则才是早期失败。
	deadline := time.NewTimer(relayFastWait)
	defer deadline.Stop()
	for {
		select {
		case <-session.waitCh:
			if productReady() {
				session.ready = true
				relayMu.Lock()
				relaySessions[sessionID] = session
				relayMu.Unlock()
				return session.info(), nil
			}
			relayStop(sessionID)
			return nil, relayFail(ErrRelayUnavailable,
				"中继启动失败（ffmpeg 提前退出，检查密钥与播放地址）")
		case <-deadline.C:
			// 超时但进程仍存活：转码慢属正常，放行交给电视端边转边播。
			if opts.Format == "ts" {
				session.ready = tsReady(dir)
			} else {
				session.ready = indexReady(dir)
			}
			relayMu.Lock()
			relaySessions[sessionID] = session
			relayMu.Unlock()
			return session.info(), nil
		default:
			if productReady() {
				session.ready = true
				relayMu.Lock()
				relaySessions[sessionID] = session
				relayMu.Unlock()
				return session.info(), nil
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
}

// castRelayStop 停止会话并回收资源。
func castRelayStop(sessionID string) error {
	relayStop(sessionID)
	return nil
}

// castRelayStatus 查询会话状态（诊断面板用）。
func castRelayStatus(sessionID string) (*relaySessionInfo, error) {
	relayMu.Lock()
	s := relaySessions[sessionID]
	relayMu.Unlock()
	if s == nil {
		return nil, relayFail(ErrRelayNoSession, "会话不存在或已回收")
	}
	return s.info(), nil
}

// ---------- 内部 ----------

func (s *relaySession) touch() {
	relayMu.Lock()
	s.lastAccess = time.Now()
	relayMu.Unlock()
}

func (s *relaySession) info() *relaySessionInfo {
	// 分片数只对 hls 档有意义；ts 档产物是单文件 stream.ts（不能把它当
	// 分片计数，诊断「电视拉到几个分片」会失真）。
	segments := 0
	if s.format != "ts" {
		if entries, err := os.ReadDir(s.dir); err == nil {
			for _, e := range entries {
				if strings.HasSuffix(e.Name(), ".ts") {
					segments++
				}
			}
		}
	}
	// LAN IP 会话内缓存一次（castRelayStart 时取好）；测试直建的结构体
	// 无缓存值时回落 lanIP()。
	lan := s.lanIP
	if lan == "" {
		lan = lanIP()
	}
	// 产物 URL 按档位分流（R2）：hls 指向清单；ts 指向 stream.ts——
	// Dart 侧按 URL 扩展名自动判 video/mp2t。
	url := fmt.Sprintf("http://%s:%d/cast/%s/index.m3u8", lan, s.port, s.token)
	if s.format == "ts" {
		url = fmt.Sprintf("http://%s:%d/cast/%s/stream.ts", lan, s.port, s.token)
	}
	format := s.format
	if format != "ts" {
		format = "hls"
	}
	return &relaySessionInfo{
		Session:   s.id,
		Token:     s.token,
		Port:      s.port,
		URL:       url,
		Format:    format,
		LanIP:     lan,
		Encrypted: s.encrypted,
		UptimeMs:  time.Since(s.startedAt).Milliseconds(),
		Segments:  segments,
		Ready:     s.ready,
		Recent:    s.recentAccess(),
	}
}

func relayStop(sessionID string) {
	relayMu.Lock()
	s := relaySessions[sessionID]
	delete(relaySessions, sessionID)
	relayMu.Unlock()
	if s == nil {
		return
	}
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
	if s.srv != nil {
		_ = s.srv.Close()
	}
	_ = os.RemoveAll(s.dir)
}

// sweepOrphanDirs 清理上次进程遗留的中继临时目录：app 强杀/退出时
// relaySessions 随内存消失，临时目录成孤儿（实测 Temp 残留 30+）。启动时
// 活跃会话为空，Temp 下 aquan-cast- 前缀目录全部属于孤儿，直接删除；
// 30s 周期的 sweeper 只覆盖进程存活期。
func sweepOrphanDirs() {
	matches, err := filepath.Glob(filepath.Join(os.TempDir(), "aquan-cast-*"))
	if err != nil {
		return
	}
	for _, dir := range matches {
		_ = os.RemoveAll(dir)
	}
}

// startSweeper 启动空闲回收（30s 扫一遍，5 分钟无访问即回收）。
func startSweeper() {
	relayMu.Lock()
	defer relayMu.Unlock()
	if relaySweeper != nil {
		return
	}
	relaySweeper = time.NewTicker(30 * time.Second)
	go func(t *time.Ticker) {
		for range t.C {
			relayMu.Lock()
			var expired []string
			for id, s := range relaySessions {
				if time.Since(s.lastAccess) > relayIdleTimeout {
					expired = append(expired, id)
				}
			}
			relayMu.Unlock()
			for _, id := range expired {
				relayStop(id)
			}
		}
	}(relaySweeper)
}

// buildFFmpegArgs 组装转码命令，按输出档位分流（R2）：
//
//   - hls（默认/空/未知值）：libx264+aac 转 HLS（guoappxxx 验证参数，
//     **字节级保持现状**——hls 分支的任何改动都会影响已调通的设备）；
//     x264 重编码参数按画质档位（R2）取 [x264VideoParams]，balanced 档
//     与现状逐字节一致；
//   - ts：Sink 只认 TS 容器时 remux（-c copy 不重编码，WMP 族不认 HLS
//     清单，TS 直流才是它们的母语；-muxdelay 0 / -muxpreload 0 降起播
//     延迟），产物单文件 stream.ts。画质档位不影响本分支（无重编码）。
func buildFFmpegArgs(ffmpeg string, opts relayOptions, dir string, decKey string) []string {
	input := opts.URL
	if decKey != "" {
		decKey = strings.ToLower(strings.TrimPrefix(decKey, "0x"))
	}
	args := []string{ffmpeg, "-hide_banner", "-loglevel", "error"}
	var headers string
	if opts.UserAgent != "" {
		headers += "User-Agent: " + opts.UserAgent + "\r\n"
	}
	if opts.Referer != "" {
		headers += "Referer: " + opts.Referer + "\r\n"
	}
	if headers != "" {
		args = append(args, "-headers", headers)
	}
	if decKey != "" {
		args = append(args, "-decryption_key", decKey)
	}
	if opts.Format == "ts" {
		args = append(args,
			"-i", input,
			"-c", "copy",
			"-muxdelay", "0", "-muxpreload", "0",
			"-f", "mpegts",
			filepath.Join(dir, "stream.ts"),
		)
		return args
	}
	// 备用地址：主地址 ffmpeg 自己会失败退出 → 上层重试时换备用。
	args = append(args, "-i", input)
	args = append(args, x264VideoParams(opts.Quality)...)
	args = append(args,
		"-c:a", "aac", "-b:a", "96k", "-ac", "2",
		"-f", "hls",
		"-hls_time", "3",
		"-hls_playlist_type", "event",
		"-hls_flags", "independent_segments",
		"-hls_segment_filename", filepath.Join(dir, "seg_%05d.ts"),
		filepath.Join(dir, "index.m3u8"),
	)
	return args
}

// x264VideoParams 按画质档位返回 x264 重编码参数（R2 画质三档）：
//
//   - high：crf 20 + preset fast（画质优先，CPU 占用更高）；
//   - balanced（含空/未知值）：crf 25 + preset veryfast —— **现状参数逐字节
//     不动**，旧调用方（未传 quality）零回归；
//   - compact：crf 30 + preset veryfast + maxrate 2M / bufsize 4M（省流档，
//     给低配发送机与窄带宽）。
//
// 仅影响 x264 重编码分支；`-c copy` 的 TS 档不受影响。前四段
// （-c:v/-preset/-crf/-pix_fmt）三档形状一致，便于测试与 diff。
func x264VideoParams(quality string) []string {
	switch quality {
	case "high":
		return []string{
			"-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p",
		}
	case "compact":
		return []string{
			"-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-pix_fmt", "yuv420p",
			"-maxrate", "2M", "-bufsize", "4M",
		}
	default:
		// balanced / 空 / 未知值：现状参数（字节级保持，证据缺失回落现状）。
		return []string{
			"-c:v", "libx264", "-preset", "veryfast", "-crf", "25", "-pix_fmt", "yuv420p",
		}
	}
}

// findFFmpeg 按优先级定位可执行的 ffmpeg。
//
// Android 上没有 PATH 里的 ffmpeg，也没有「exe 同目录」的概念：二进制由
// jniLibs 打包、系统解压到 nativeLibraryDir，文件名 libffmpeg.so（是 PIE
// 可执行文件而不是共享库，改名只是为了让它进 nativeLibraryDir）。
// 因此额外两跳：环境变量 AQUAN_FFMPEG → nativeLibraryDir。
func findFFmpeg() (string, error) {
	if p := os.Getenv("AQUAN_FFMPEG"); isExecutableFile(p) {
		return p, nil
	}
	if dir := nativeLibraryDir(); dir != "" {
		for _, name := range []string{"libffmpeg.so", "ffmpeg"} {
			p := filepath.Join(dir, name)
			if isExecutableFile(p) {
				return p, nil
			}
		}
	}
	if exe, err := os.Executable(); err == nil {
		for _, name := range []string{"ffmpeg.exe", "ffmpeg"} {
			p := filepath.Join(filepath.Dir(exe), name)
			if isExecutableFile(p) {
				return p, nil
			}
		}
	}
	return exec.LookPath("ffmpeg")
}

// isExecutableFile 要求路径存在、是普通文件、且有任一执行位。
//
// Windows 不看权限位（os.Stat 在那里的 perm 不反映 ACL），只看存在性——
// 桌面端原本就是「exe 旁有 ffmpeg.exe 就用」，不能因为权限位判断退化。
func isExecutableFile(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode().Perm()&0o111 != 0
}

// nativeLibraryDir 在 Android 上定位应用的原生库目录。
//
// Go 侧拿不到 Java 的 ApplicationInfo，但进程 maps 里一定有 libaquan_core.so，
// 它所在目录就是 nativeLibraryDir。非 Android 直接返回空串。
func nativeLibraryDir() string {
	if runtime.GOOS != "android" {
		return ""
	}
	data, err := os.ReadFile("/proc/self/maps")
	if err != nil {
		return ""
	}
	return parseNativeLibDir(string(data))
}

// parseNativeLibDir 从 /proc/self/maps 内容里取出 libaquan_core.so 所在目录。
//
// 行格式：`7f... r-xp 00000000 fd:01 1234 /data/app/.../lib/arm64/libaquan_core.so`
// 第 6 列是映射文件路径。
func parseNativeLibDir(maps string) string {
	for _, line := range strings.Split(maps, "\n") {
		if !strings.Contains(line, "libaquan_core.so") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		mapped := fields[5]
		if !strings.HasPrefix(mapped, "/") {
			continue
		}
		// maps 里的路径永远是 POSIX 形式：必须用 path 而不是 filepath，
		// 否则在 Windows 上跑单测会被改写成反斜杠。
		return path.Dir(mapped)
	}
	return ""
}

// cleanProxyEnv 清空全部代理变量（上游是签名直链）。
func cleanProxyEnv() []string {
	out := make([]string, 0, len(os.Environ()))
	for _, e := range os.Environ() {
		upper := strings.ToUpper(e)
		if strings.HasPrefix(upper, "HTTP_PROXY=") ||
			strings.HasPrefix(upper, "HTTPS_PROXY=") ||
			strings.HasPrefix(upper, "ALL_PROXY=") ||
			strings.HasPrefix(upper, "NO_PROXY=") {
			continue
		}
		out = append(out, e)
	}
	return out
}

func randomToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// listenOnFreePort 从 base 起顺延探测可用端口并**预绑定**监听（消除二次绑定竞态）。
func listenOnFreePort(base int) (int, net.Listener, error) {
	for port := base; port < base+50; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", port))
		if err != nil {
			continue
		}
		return port, ln, nil
	}
	return 0, nil, fmt.Errorf("no free port from %d", base)
}

func indexReady(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "index.m3u8"))
	return err == nil
}

// tsReady 判定 TS 直流产物就绪（R2）：stream.ts 存在且 > 64KB——对齐 hls
// ready 的保守口径（起步阶段的空洞/极小文件不算就绪，避免把启动瞬间当
// 「转码完成」）。
func tsReady(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, "stream.ts"))
	return err == nil && info.Size() > 64*1024
}

func hasSegments(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".ts") {
			return true
		}
	}
	return false
}

// lanIP 取一个电视可达的局域网地址：偏好 192.168.* > 10.* > 172.16-31，
// 跳过 169.254 链路本地与虚拟网卡地址（Windows 上按字典序选会踩坑）；
// 取不到回退 127.0.0.1（单机自测）。
func lanIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "127.0.0.1"
	}
	var prefer192, prefer10, prefer172 string
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok || ipnet.IP.IsLoopback() || ipnet.IP.To4() == nil {
			continue
		}
		ip := ipnet.IP.To4()
		if ip.IsLinkLocalUnicast() {
			continue
		}
		if !ip.IsPrivate() {
			continue
		}
		s := ip.String()
		switch {
		case strings.HasPrefix(s, "192.168."):
			prefer192 = s
		case strings.HasPrefix(s, "10."):
			if prefer10 == "" {
				prefer10 = s
			}
		case strings.HasPrefix(s, "172."):
			if prefer172 == "" {
				prefer172 = s
			}
		}
	}
	if prefer192 != "" {
		return prefer192
	}
	if prefer10 != "" {
		return prefer10
	}
	if prefer172 != "" {
		return prefer172
	}
	return "127.0.0.1"
}

// relayOptionsFromJSON 解析 Dart 传来的 options JSON。
func relayOptionsFromJSON(raw []byte) (relayOptions, error) {
	var opts relayOptions
	if err := json.Unmarshal(raw, &opts); err != nil {
		return opts, relayFail(ErrRelayInvalid, "options 解析失败")
	}
	if opts.URL == "" {
		return opts, relayFail(ErrRelayInvalid, "缺少播放地址")
	}
	return opts, nil
}

// ---------- 投屏会话共享助手（castrelay / castdesktop 共用） ----------

func mkCastTempDir(prefix string) (string, error) { return os.MkdirTemp("", prefix) }

func removeCastDir(dir string) { _ = os.RemoveAll(dir) }

func execCommand(args []string) *exec.Cmd { return exec.Command(args[0], args[1:]...) }

func newCastServer() *http.Server { return &http.Server{Handler: http.NotFoundHandler()} }

// stopAndRemove 停进程/服务并清理临时目录（启动失败快路径）。
func stopAndRemove(s *relaySession) {
	relayStop(s.id)
}

// putRelaySession 登记会话（relayMu 保护）。
func putRelaySession(s *relaySession) {
	relayMu.Lock()
	relaySessions[s.id] = s
	relayMu.Unlock()
}

// relayStatus 按会话 ID 查状态（castRelayStatus/castDesktopStatus 共用）。
func relayStatus(sessionID string) (*relaySessionInfo, error) {
	relayMu.Lock()
	s := relaySessions[sessionID]
	relayMu.Unlock()
	if s == nil {
		return nil, relayFail(ErrRelayNoSession, "会话不存在或已回收")
	}
	return s.info(), nil
}

// serveCastFiles 挂 /cast/<token>/ 静态清单与分片服务并开始监听
// （端口已由 listenOnFreePort 预绑定，不存在二次绑定竞态）。
func serveCastFiles(s *relaySession, ln net.Listener) {
	mux := http.NewServeMux()
	mux.HandleFunc("/cast/"+s.token+"/", s.serveCastFile)
	s.srv.Handler = mux
	go func() {
		_ = s.srv.Serve(ln)
	}()
}

// serveCastFile 伺服单个清单/分片并记录电视取流日志（M0-5）。
// http.ServeFile 自己处理 Range/206/416：用 accessRecorder 包一层拿状态码
// 与字节数，并按 M1-9 条件化规则附加 DLNA 响应头。
//
// ts 档（R2）：token 根路径（无清单可给）301 到 stream.ts——部分接收端只
// 拼 token 前缀取流，重定向保证拿得到产物；stream.ts 走 ServeFile 现有
// Range/206/accessRecorder 路径，与 hls 分片同口径。
func (s *relaySession) serveCastFile(w http.ResponseWriter, r *http.Request) {
	s.touch()
	name := strings.TrimPrefix(r.URL.Path, "/cast/"+s.token+"/")
	if s.format == "ts" && (name == "" || name == "/") {
		rec := s.newAccessRecorder(w, r, "")
		http.Redirect(rec, r, "stream.ts", http.StatusMovedPermanently)
		s.recordAccess(r, rec.status, rec.bytes)
		return
	}
	name = filepath.Base(name) // 防 ../ 穿越
	rec := s.newAccessRecorder(w, r, name)
	http.ServeFile(rec, r, filepath.Join(s.dir, name))
	s.recordAccess(r, rec.status, rec.bytes)
}

// newAccessRecorder 组装取流记录器（条件化 DLNA 头规则见 accessRecorder）。
func (s *relaySession) newAccessRecorder(w http.ResponseWriter, r *http.Request, name string) *accessRecorder {
	return &accessRecorder{
		ResponseWriter: w,
		status:         http.StatusOK,
		// playbridge 条件化写法：设备显式索要才回 contentFeatures。
		wantContentFeatures: r.Header.Get("Getcontentfeatures.dlna.org") == "1",
		// 清单路由不声明 byte-seek（review §8.5 诚实化）：只删 Accept-Ranges
		// 声明，Range 请求仍按 ServeFile 真实行为应答。
		suppressAcceptRanges: strings.HasSuffix(strings.ToLower(name), ".m3u8"),
		// 字幕第三通道（R3）：仅会话登记了字幕才带（与 Dart 侧
		// LocalMediaServer/CastMediaProxy 同规，未登记不产生噪声）。
		captionSec: s.subtitleURL,
	}
}

// relayContentFeatures 是 contentFeatures.dlna.org 的值：中继产物是静态
// HLS 文件，支持字节 Range 206 → OP=01；不转码（产物即最终形态）→ CI=0。
const relayContentFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;" +
	"DLNA.ORG_FLAGS=01700000000000000000000000000000"

// setDlnaHeader 直写 header map：net/http 的 Set 会把键名改写成它的规范
// 形式（首字母大写 + 其余小写，"transferMode.dlna.org" 会变成
// "Transfermode.dlna.org"）。DLNA 规范拼写是驼峰式，部分固件按名字面
// 匹配，必须原样输出。
func setDlnaHeader(h http.Header, name, value string) {
	h[name] = []string{value}
}

// accessRecorder 包装 ResponseWriter，捕获状态码与写给电视的字节数（取流日志），
// 并在首写头时附加 DLNA 响应头（M1-9，与 LocalMediaServer/CastMediaProxy 同规）：
// transferMode.dlna.org: Streaming 恒带；contentFeatures.dlna.org 仅当请求带
// getcontentFeatures.dlna.org: 1 才回；realTimeInfo.dlna.org 恒带；
// CaptionInfo.sec 仅会话登记字幕才带（R3）；HLS 清单响应删除 Accept-Ranges
// 声明（TS 分片按 ServeFile 真实现状保留）。
type accessRecorder struct {
	http.ResponseWriter
	status               int
	wroteHeader          bool
	bytes                int64
	wantContentFeatures  bool
	suppressAcceptRanges bool
	captionSec           string // 非空时媒体响应带 CaptionInfo.sec（R3）
}

func (w *accessRecorder) WriteHeader(code int) {
	if !w.wroteHeader {
		w.wroteHeader = true
		h := w.Header()
		setDlnaHeader(h, "transferMode.dlna.org", "Streaming")
		if w.wantContentFeatures {
			setDlnaHeader(h, "contentFeatures.dlna.org", relayContentFeatures)
		}
		if w.captionSec != "" {
			// 直写 header map 保留 Samsung 规范驼峰拼写（与 transferMode 同坑：
			// net/http 的 Set 会把键名改写成首字母大写形式）。
			setDlnaHeader(h, "CaptionInfo.sec", w.captionSec)
		}
		setDlnaHeader(h, "realTimeInfo.dlna.org", "DLNA.ORG_TLAG=*")
		if w.suppressAcceptRanges {
			h.Del("Accept-Ranges")
		}
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *accessRecorder) Write(p []byte) (int, error) {
	if !w.wroteHeader {
		w.wroteHeader = true
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += int64(n)
	return n, err
}

// recordAccess 追加一条电视取流记录（环形，超过 relayAccessLogSize 淘汰最旧）。
func (s *relaySession) recordAccess(r *http.Request, status int, bytes int64) {
	s.logMu.Lock()
	defer s.logMu.Unlock()
	s.logSeq++
	s.accessLog = append(s.accessLog, relayAccessEntry{
		Seq:    s.logSeq,
		At:     time.Now().Format("15:04:05"),
		Path:   r.URL.Path,
		Range:  r.Header.Get("Range"),
		UA:     r.Header.Get("User-Agent"),
		Status: status,
		Bytes:  bytes,
	})
	if len(s.accessLog) > relayAccessLogSize {
		s.accessLog = s.accessLog[len(s.accessLog)-relayAccessLogSize:]
	}
}

// recentAccess 快照最近取流记录（供 info() 组装，避免与 relayMu 嵌套）。
func (s *relaySession) recentAccess() []relayAccessEntry {
	s.logMu.Lock()
	defer s.logMu.Unlock()
	if len(s.accessLog) == 0 {
		return nil
	}
	out := make([]relayAccessEntry, len(s.accessLog))
	copy(out, s.accessLog)
	return out
}
