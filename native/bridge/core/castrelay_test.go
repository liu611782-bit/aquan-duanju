package core

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestRelayOptionsFromJSON(t *testing.T) {
	opts, err := relayOptionsFromJSON([]byte(
		`{"url":"http://up/1.m3u8","backup_url":"http://up/2.m3u8","dec_key":"ABCDEF","user_agent":"","referer":""}`))
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if opts.URL != "http://up/1.m3u8" || opts.BackupURL != "http://up/2.m3u8" {
		t.Fatalf("字段不匹配: %+v", opts)
	}
	if _, err := relayOptionsFromJSON([]byte(`not json`)); err == nil {
		t.Fatal("非法 JSON 应报错")
	}
}

func TestBuildFFmpegArgs(t *testing.T) {
	dir := t.TempDir()
	args := buildFFmpegArgs("ffmpeg", relayOptions{
		URL:       "http://up/1.m3u8",
		BackupURL: "http://up/2.m3u8",
		DecKey:    "0xABCDEF12",
	}, dir, "0xABCDEF12")

	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-decryption_key abcdef12") {
		t.Fatalf("密钥应小写去前缀: %v", args)
	}
	if !strings.Contains(joined, filepath.Join(dir, "index.m3u8")) {
		t.Fatalf("清单输出路径缺失: %v", args)
	}
	if !strings.Contains(joined, "-hls_time 3") {
		t.Fatalf("HLS 分片时长缺失: %v", args)
	}
	// 无 UA/Referer 时不应有空 -headers 参数。
	for _, a := range args {
		if a == "-headers" {
			t.Fatalf("无头时不应出现 -headers: %v", args)
		}
	}
}

// TestBuildFFmpegArgsTs：ts 档分支（R2）——-f mpegts 写 stream.ts、-c copy
// 不重编码、muxer 降延迟参数；不出现 hls/转码参数。
func TestBuildFFmpegArgsTs(t *testing.T) {
	dir := t.TempDir()
	args := buildFFmpegArgs("ffmpeg", relayOptions{
		URL:    "http://up/1.mkv",
		Format: "ts",
	}, dir, "")
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-f mpegts") {
		t.Fatalf("ts 档应输出 mpegts: %v", args)
	}
	if !strings.Contains(joined, filepath.Join(dir, "stream.ts")) {
		t.Fatalf("ts 档应写 stream.ts: %v", args)
	}
	if !strings.Contains(joined, "-c copy") {
		t.Fatalf("ts 档应 remux 不重编码: %v", args)
	}
	if !strings.Contains(joined, "-muxdelay 0 -muxpreload 0") {
		t.Fatalf("ts 档应带 muxer 降延迟参数: %v", args)
	}
	if strings.Contains(joined, "-f hls") || strings.Contains(joined, "libx264") {
		t.Fatalf("ts 档不应出现 hls/转码参数: %v", args)
	}
}

// TestBuildFFmpegArgsFormatFallback：Format 为空/未知值一律按 hls（R2 证据
// 缺失回落现状，旧调用方零改动）。
func TestBuildFFmpegArgsFormatFallback(t *testing.T) {
	for _, format := range []string{"", "hls", "webvtt"} {
		args := buildFFmpegArgs("ffmpeg", relayOptions{
			URL:    "http://up/1.m3u8",
			Format: format,
		}, t.TempDir(), "")
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "-f hls") || !strings.Contains(joined, "index.m3u8") {
			t.Fatalf("format=%q 应回落 hls: %v", format, args)
		}
		if strings.Contains(joined, "mpegts") {
			t.Fatalf("format=%q 不应走 ts 分支: %v", format, args)
		}
	}
}

// TestBuildFFmpegArgsQuality：画质三档参数组（R2）——high/balanced/compact
// 各自的 x264 参数 + 空/未知值缺省回 balanced；balanced 与现状参数逐字节
// 一致（旧行为零回归）。
func TestBuildFFmpegArgsQuality(t *testing.T) {
	balanced := []string{
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "25", "-pix_fmt", "yuv420p",
	}
	high := []string{
		"-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p",
	}
	compact := []string{
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-pix_fmt", "yuv420p",
		"-maxrate", "2M", "-bufsize", "4M",
	}

	// 三档显式取值。
	if got := x264VideoParams("balanced"); !reflect.DeepEqual(got, balanced) {
		t.Fatalf("balanced 参数不符: %v", got)
	}
	if got := x264VideoParams("high"); !reflect.DeepEqual(got, high) {
		t.Fatalf("high 参数不符: %v", got)
	}
	if got := x264VideoParams("compact"); !reflect.DeepEqual(got, compact) {
		t.Fatalf("compact 参数不符: %v", got)
	}

	// 空/未知值缺省回 balanced（旧调用方未传 quality 的现状路径）。
	for _, q := range []string{"", "unknown", "HIGH"} {
		if got := x264VideoParams(q); !reflect.DeepEqual(got, balanced) {
			t.Fatalf("quality=%q 应回落 balanced: %v", q, got)
		}
	}

	// 端到端：buildFFmpegArgs 产物携带档位参数（hls 分支），ts 分支不受影响。
	dir := t.TempDir()
	hlsArgs := buildFFmpegArgs("ffmpeg", relayOptions{
		URL:     "http://up/1.m3u8",
		Quality: "compact",
	}, dir, "")
	hlsJoined := strings.Join(hlsArgs, " ")
	if !strings.Contains(hlsJoined, "-crf 30 -pix_fmt yuv420p -maxrate 2M -bufsize 4M") {
		t.Fatalf("hls 分支应携带 compact 档参数: %v", hlsArgs)
	}
	tsArgs := buildFFmpegArgs("ffmpeg", relayOptions{
		URL:     "http://up/1.mkv",
		Format:  "ts",
		Quality: "high",
	}, dir, "")
	tsJoined := strings.Join(tsArgs, " ")
	if strings.Contains(tsJoined, "libx264") || strings.Contains(tsJoined, "crf") ||
		strings.Contains(tsJoined, "maxrate") {
		t.Fatalf("ts 档不应受画质档位影响（-c copy 不重编码）: %v", tsArgs)
	}

	// balanced 档完整 hls 命令与改动前逐字节一致（现状锁定）。
	want := "ffmpeg -hide_banner -loglevel error -i http://up/1.m3u8 " +
		"-c:v libx264 -preset veryfast -crf 25 -pix_fmt yuv420p " +
		"-c:a aac -b:a 96k -ac 2 -f hls -hls_time 3 " +
		"-hls_playlist_type event -hls_flags independent_segments " +
		"-hls_segment_filename " + filepath.Join(dir, "seg_%05d.ts") + " " +
		filepath.Join(dir, "index.m3u8")
	gotArgs := buildFFmpegArgs("ffmpeg", relayOptions{
		URL: "http://up/1.m3u8",
	}, dir, "")
	if strings.Join(gotArgs, " ") != want {
		t.Fatalf("balanced 档与现状参数不一致:\n got: %v\nwant: %s", gotArgs, want)
	}
}

func TestListenOnFreePort(t *testing.T) {
	port, ln, err := listenOnFreePort(relayBasePort)
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}
	defer ln.Close()
	if port < relayBasePort || port >= relayBasePort+50 {
		t.Fatalf("端口越界: %d", port)
	}
}

func TestRandomToken(t *testing.T) {
	a, err := randomToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := randomToken()
	if len(a) != 32 || a == b {
		t.Fatalf("token 应为 32 hex 且随机: %s", a)
	}
}

func TestCleanProxyEnv(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:7890")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:7890")
	env := cleanProxyEnv()
	for _, e := range env {
		upper := strings.ToUpper(e)
		if strings.HasPrefix(upper, "HTTP_PROXY=") || strings.HasPrefix(upper, "HTTPS_PROXY=") {
			t.Fatalf("代理变量应被剔除: %s", e)
		}
	}
}

// TestCastRelayStartUnavailable：ffmpeg 不存在时秒回 unavailable（CI 环境通常无 ffmpeg）。
func TestCastRelayStartUnavailable(t *testing.T) {
	if _, err := findFFmpeg(); err == nil {
		t.Skip("本机有 ffmpeg，跳过不可用路径测试")
	}
	_, err := castRelayStart(relayOptions{URL: "http://up/1.m3u8", DecKey: "aa"})
	if err == nil {
		t.Fatal("无 ffmpeg 应报错")
	}
	if !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("应返回 relay_unavailable: %v", err)
	}
}

// TestCastRelayServeFile：本地 ffmpeg 存在时走完整启动 → HTTP 拉清单 → 停止回收。
// 无加密真源，用「ffmpeg 生成测试 HLS」替代上游（testsrc 是 ffmpeg 自带滤镜）。
func TestCastRelayServeFile(t *testing.T) {
	if _, err := findFFmpeg(); err != nil {
		t.Skip("本机无 ffmpeg，跳过完整链路测试")
	}
	// 先用 ffmpeg 生成一个本地 mp4「上游」（testsrc 自带滤镜）。
	ffmpeg, err := findFFmpeg()
	if err != nil {
		t.Skip("本机无 ffmpeg")
	}
	upstream := filepath.Join(t.TempDir(), "up.mp4")
	gen := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc=duration=6:size=320x240:rate=10",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", upstream)
	if out, err := gen.CombinedOutput(); err != nil {
		t.Fatalf("上游生成失败: %v (%s)", err, out)
	}
	info, err := castRelayStart(relayOptions{URL: upstream})
	if err != nil {
		t.Fatalf("启动失败: %v", err)
	}
	defer castRelayStop(info.Session)

	// 等清单与首个分片就绪（快检已等 3s，这里再放宽）。
	// 直连客户端：绕过系统代理（中继地址是局域网直连语义）。
	direct := &http.Client{Transport: &http.Transport{Proxy: nil}}
	deadline := time.Now().Add(10 * time.Second)
	var body []byte
	for time.Now().Before(deadline) {
		resp, err := direct.Get(info.URL)
		if err != nil {
			t.Logf("GET err: %v (url=%s)", err, info.URL)
		} else {
			body, _ = io.ReadAll(resp.Body)
			resp.Body.Close()
			t.Logf("GET status=%d len=%d body-head=%.60s", resp.StatusCode, len(body), string(body))
			if strings.Contains(string(body), "#EXTM3U") {
				break
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	if !strings.Contains(string(body), "#EXTM3U") {
		t.Fatalf("清单未就绪: %s", string(body))
	}

	// token 之外的路径必须 404（防拖走）。
	resp, err := direct.Get(strings.Replace(info.URL, "/cast/"+info.Token+"/", "/cast/wrongtoken/", 1))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("错误 token 应 404: %d", resp.StatusCode)
	}

	// 停止后会话回收：Status 应报 no_session。
	castRelayStop(info.Session)
	if _, err := castRelayStatus(info.Session); err == nil {
		t.Fatal("停止后 Status 应报会话不存在")
	}
}

// TestRelayInfoJSON：出参字段名符合 FFI 契约（camelCase）。
func TestRelayInfoJSON(t *testing.T) {
	info := (&relaySession{
		id: "s", token: "tok", port: 1, startedAt: time.Now(),
		lastAccess: time.Now(), encrypted: true, ready: true,
	}).info()
	raw, err := json.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"session"`, `"token"`, `"port"`, `"url"`, `"format":"hls"`, `"encrypted"`, `"uptimeMs"`, `"segments"`, `"ready"`} {
		if !strings.Contains(string(raw), field) {
			t.Fatalf("缺少字段 %s: %s", field, raw)
		}
	}
}

// TestRelayAccessLog：电视取流环形日志（M0-5）——记录时间/路径/Range/UA/
// 状态码/字节数，经 castRelayStatus 的 recent 字段返回；环形上限淘汰最旧。
// HTTP 客户端必须 Proxy:nil（中继是局域网直连语义，与 castrelay 上游同坑）。
func TestRelayAccessLog(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.m3u8"), []byte("#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &relaySession{
		id: "s1", token: "tok1234567890abcdef", dir: dir,
		startedAt: time.Now(), lastAccess: time.Now(),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/cast/"+s.token+"/", s.serveCastFile)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	defer func() { _ = srv.Close() }()
	base := fmt.Sprintf("http://127.0.0.1:%d/cast/%s", ln.Addr().(*net.TCPAddr).Port, s.token)

	// 直连客户端：绕过系统代理。
	direct := &http.Client{Transport: &http.Transport{Proxy: nil}}

	// 1) 带 Range + UA 的正常取流。
	req, err := http.NewRequest("GET", base+"/index.m3u8", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Range", "bytes=0-1")
	req.Header.Set("User-Agent", "TV-UA/1.0")
	resp, err := direct.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	// ServeFile 按 Range 正确回 206（2 字节）——记录的状态码就是给电视的形态。
	if resp.StatusCode != 206 || len(body) != 2 {
		t.Fatalf("Range 取流应 206/2B: %d %dB", resp.StatusCode, len(body))
	}

	// 2) 缺失文件 → 404 也必须记录（诊断「电视拉了但没拉到」依赖它）。
	resp2, err := direct.Get(base + "/missing.ts")
	if err != nil {
		t.Fatal(err)
	}
	resp2.Body.Close()

	recent := s.recentAccess()
	if len(recent) != 2 {
		t.Fatalf("应有 2 条取流记录: %d", len(recent))
	}
	first, second := recent[0], recent[1]
	if first.Status != 206 || first.Range != "bytes=0-1" || first.UA != "TV-UA/1.0" {
		t.Fatalf("首条记录字段不符: %+v", first)
	}
	if first.Path != "/cast/"+s.token+"/index.m3u8" || first.At == "" || first.Seq <= 0 {
		t.Fatalf("首条记录字段不符: %+v", first)
	}
	if first.Bytes != int64(len(body)) {
		t.Fatalf("字节数不符: got %d want %d", first.Bytes, len(body))
	}
	if second.Status != 404 {
		t.Fatalf("404 也应记录: %+v", second)
	}
	if second.Seq <= first.Seq {
		t.Fatalf("seq 应单调递增: %d -> %d", first.Seq, second.Seq)
	}

	// 3) recent 经 info() 进 castRelayStatus 出参（FFI 契约）。
	raw, err := json.Marshal(s.info())
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"recent"`, `"seq"`, `"path"`, `"status"`, `"bytes"`} {
		if !strings.Contains(string(raw), field) {
			t.Fatalf("出参缺少字段 %s: %s", field, raw)
		}
	}

	// 4) 环形上限：超过 relayAccessLogSize 淘汰最旧，seq 仍连续。
	for i := 0; i < relayAccessLogSize+5; i++ {
		s.recordAccess(&http.Request{URL: &url.URL{Path: "/cast/" + s.token + "/seg.ts"}, Header: http.Header{}}, 200, int64(i))
	}
	recent = s.recentAccess()
	if len(recent) != relayAccessLogSize {
		t.Fatalf("环形日志应封顶 %d: %d", relayAccessLogSize, len(recent))
	}
	// 环形淘汰后：首条 seq = 末条 seq - 容量 + 1（seq 连续无缺口）。
	lastSeq := recent[len(recent)-1].Seq
	if recent[0].Seq != lastSeq-int64(relayAccessLogSize)+1 {
		t.Fatalf("环形淘汰后 seq 不连续: 首条 %d 末条 %d", recent[0].Seq, lastSeq)
	}
}

// TestRelayDlnaHeaders：DLNA 响应头条件化附加（M1-9）——transferMode 恒带、
// contentFeatures 仅在请求带 getcontentFeatures.dlna.org: 1 才回、
// HLS 清单不声明 Accept-Ranges、TS 分片按 ServeFile 真实现状（206 路由保留）。
// HTTP 客户端必须 Proxy:nil。
func TestRelayDlnaHeaders(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "index.m3u8"),
		[]byte("#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "seg0.ts"),
		[]byte(strings.Repeat("\x47", 256)), 0o644); err != nil {
		t.Fatal(err)
	}
	s := &relaySession{
		id: "s1", token: "tok1234567890abcdef", dir: dir,
		startedAt: time.Now(), lastAccess: time.Now(),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/cast/"+s.token+"/", s.serveCastFile)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	defer func() { _ = srv.Close() }()
	base := fmt.Sprintf("http://127.0.0.1:%d/cast/%s", ln.Addr().(*net.TCPAddr).Port, s.token)
	direct := &http.Client{Transport: &http.Transport{Proxy: nil}}

	// 1) 清单（不索要 contentFeatures）：Streaming/realTimeInfo 恒带，
	//    contentFeatures 缺席，Accept-Ranges 不声明。
	resp, err := direct.Get(base + "/index.m3u8")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), "#EXTM3U") {
		t.Fatalf("清单应 200: %d", resp.StatusCode)
	}
	if got := resp.Header.Get("transferMode.dlna.org"); got != "Streaming" {
		t.Fatalf("transferMode = %q", got)
	}
	if got := resp.Header.Get("realTimeInfo.dlna.org"); got != "DLNA.ORG_TLAG=*" {
		t.Fatalf("realTimeInfo = %q", got)
	}
	if resp.Header.Get("contentFeatures.dlna.org") != "" {
		t.Fatal("未索要不应回 contentFeatures")
	}
	if resp.Header.Get("Accept-Ranges") != "" {
		t.Fatal("HLS 清单路由不应声明 Accept-Ranges（诚实化）")
	}

	// 2) 清单（索要 contentFeatures）：条件化回。
	req, err := http.NewRequest("GET", base+"/index.m3u8", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("getcontentFeatures.dlna.org", "1")
	resp2, err := direct.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	io.ReadAll(resp2.Body)
	resp2.Body.Close()
	got := resp2.Header.Get("contentFeatures.dlna.org")
	want := "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
	if got != want {
		t.Fatalf("contentFeatures = %q, want %q", got, want)
	}

	// 3) TS 分片（带 Range）：ServeFile 真答 206 → Accept-Ranges 保留；
	//    未索要 contentFeatures 仍不回。
	req3, err := http.NewRequest("GET", base+"/seg0.ts", nil)
	if err != nil {
		t.Fatal(err)
	}
	req3.Header.Set("Range", "bytes=0-9")
	resp3, err := direct.Do(req3)
	if err != nil {
		t.Fatal(err)
	}
	seg, _ := io.ReadAll(resp3.Body)
	resp3.Body.Close()
	if resp3.StatusCode != 206 || len(seg) != 10 {
		t.Fatalf("分片 Range 应 206/10B: %d %dB", resp3.StatusCode, len(seg))
	}
	if resp3.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("206 路由应声明 Accept-Ranges: %q", resp3.Header.Get("Accept-Ranges"))
	}
	if resp3.Header.Get("contentFeatures.dlna.org") != "" {
		t.Fatal("未索要不应回 contentFeatures")
	}

	// 4) 直写 header map 保留 DLNA 规范驼峰拼写（net/http 的 Set 会改写大小写）。
	raw, err := rawHttpGet(t, base+"/index.m3u8")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(raw, "transferMode.dlna.org: Streaming") {
		t.Fatalf("响应头应保留规范拼写: %s", raw)
	}
}

// rawHttpGet 用裸 TCP 读原始响应头（验证线上字节的键名拼写）。
func rawHttpGet(t *testing.T, rawURL string) (string, error) {
	t.Helper()
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", err
	}
	conn, err := net.Dial("tcp", u.Host)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	fmt.Fprintf(conn, "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n", u.Path, u.Host)
	data, err := io.ReadAll(conn)
	if err != nil && len(data) == 0 {
		return "", err
	}
	return string(data), nil
}

// serveRelaySession 把手工构造的会话挂到临时监听上（ts 档/响应头单测共用），
// 返回 base URL（http://127.0.0.1:<port>/cast/<token>）。
func serveRelaySession(t *testing.T, s *relaySession) string {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/cast/"+s.token+"/", s.serveCastFile)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	return fmt.Sprintf("http://127.0.0.1:%d/cast/%s", ln.Addr().(*net.TCPAddr).Port, s.token)
}

// noRedirectClient：不跟随 301 的直连客户端（中继是局域网直连语义，
// HTTP 客户端必须 Proxy:nil——系统代理会 502）。
func noRedirectClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{Proxy: nil},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

// TestTsReady：TS 产物就绪判定（R2）——stream.ts 存在且 > 64KB。
func TestTsReady(t *testing.T) {
	dir := t.TempDir()
	if tsReady(dir) {
		t.Fatal("无文件不应就绪")
	}
	if err := os.WriteFile(filepath.Join(dir, "stream.ts"), bytes.Repeat([]byte{0x47}, 64*1024-1), 0o644); err != nil {
		t.Fatal(err)
	}
	if tsReady(dir) {
		t.Fatal("64KB 以下不应就绪（空洞/极小文件不算）")
	}
	if err := os.WriteFile(filepath.Join(dir, "stream.ts"), bytes.Repeat([]byte{0x47}, 64*1024+1), 0o644); err != nil {
		t.Fatal(err)
	}
	if !tsReady(dir) {
		t.Fatal("超过 64KB 应就绪")
	}
}

// TestRelayTsMode：TS 直流档（R2）——stream.ts 伺服 200/Range 206、token
// 根路径 301 到 stream.ts、取流日志三态全记、info 出参 format/url/segments、
// 停止回收（会话 + 临时目录）。HTTP 客户端必须 Proxy:nil。
func TestRelayTsMode(t *testing.T) {
	dir := t.TempDir()
	payload := bytes.Repeat([]byte{0x47}, 256*1024)
	if err := os.WriteFile(filepath.Join(dir, "stream.ts"), payload, 0o644); err != nil {
		t.Fatal(err)
	}
	s := &relaySession{
		id: "s-ts", token: "tok1234567890abcdef", dir: dir, format: "ts",
		startedAt: time.Now(), lastAccess: time.Now(),
	}
	base := serveRelaySession(t, s)
	direct := noRedirectClient()

	// 1) stream.ts 全量 200。
	resp, err := direct.Get(base + "/stream.ts")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || len(body) != len(payload) {
		t.Fatalf("stream.ts 应 200 全量: %d %dB", resp.StatusCode, len(body))
	}

	// 2) Range → 206（ServeFile 真答，与 hls 分片同口径）。
	req, err := http.NewRequest("GET", base+"/stream.ts", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Range", "bytes=0-9")
	respRange, err := direct.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	seg, _ := io.ReadAll(respRange.Body)
	respRange.Body.Close()
	if respRange.StatusCode != 206 || len(seg) != 10 {
		t.Fatalf("Range 取流应 206/10B: %d %dB", respRange.StatusCode, len(seg))
	}

	// 3) token 根路径 → 301 到 stream.ts（ts 档无清单）。
	respRoot, err := direct.Get(base + "/")
	if err != nil {
		t.Fatal(err)
	}
	io.ReadAll(respRoot.Body)
	respRoot.Body.Close()
	if respRoot.StatusCode != http.StatusMovedPermanently {
		t.Fatalf("token 根路径应 301: %d", respRoot.StatusCode)
	}
	if loc := respRoot.Header.Get("Location"); !strings.HasSuffix(loc, "stream.ts") {
		t.Fatalf("301 应指向 stream.ts: %q", loc)
	}

	// 4) info 出参：format=ts、URL 指向 stream.ts、segments=0、lanIp 非空。
	info := s.info()
	if info.Format != "ts" {
		t.Fatalf("format=%q", info.Format)
	}
	if !strings.HasSuffix(info.URL, "/cast/"+s.token+"/stream.ts") {
		t.Fatalf("URL 应指向 stream.ts: %s", info.URL)
	}
	if info.Segments != 0 {
		t.Fatalf("ts 档不应把 stream.ts 当分片计数: %d", info.Segments)
	}
	if info.LanIP == "" {
		t.Fatal("lanIp 出参缺失")
	}

	// 5) 取流日志：200/206/301 三条全记（诊断「电视拉了但没拉到」依赖）。
	recent := s.recentAccess()
	if len(recent) < 3 {
		t.Fatalf("应有 3 条取流记录: %d", len(recent))
	}
	if recent[0].Status != 200 || recent[1].Status != 206 || recent[2].Status != 301 {
		t.Fatalf("记录状态码不符: %d/%d/%d", recent[0].Status, recent[1].Status, recent[2].Status)
	}

	// 6) 停止回收：会话不存在 + 临时目录删除（与 hls 档同口径）。
	putRelaySession(s)
	castRelayStop(s.id)
	if _, err := castRelayStatus(s.id); !errors.Is(err, ErrRelayNoSession) {
		t.Fatalf("停止后 Status 应报 no_session: %v", err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("临时目录应随会话删除: %v", err)
	}
}

// TestRelayTsModeLive：本地 ffmpeg 存在时走完整 TS 链路（remux → stream.ts
// 伺服 → Range 206 → 停止回收），与 hls 完整链路（TestCastRelayServeFile）
// 同口径。上游用 testsrc 强制 2M 码率，保证产物越过 64KB 就绪线。
func TestRelayTsModeLive(t *testing.T) {
	ffmpeg, err := findFFmpeg()
	if err != nil {
		t.Skip("本机无 ffmpeg，跳过完整链路测试")
	}
	upstream := filepath.Join(t.TempDir(), "up.mp4")
	gen := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc=duration=10:size=640x480:rate=25",
		"-c:v", "libx264", "-preset", "ultrafast", "-b:v", "2M", "-pix_fmt", "yuv420p", upstream)
	if out, err := gen.CombinedOutput(); err != nil {
		t.Fatalf("上游生成失败: %v (%s)", err, out)
	}
	info, err := castRelayStart(relayOptions{URL: upstream, Format: "ts"})
	if err != nil {
		t.Fatalf("启动失败: %v", err)
	}
	defer castRelayStop(info.Session)
	if info.Format != "ts" {
		t.Fatalf("format=%q", info.Format)
	}
	if !strings.HasSuffix(info.URL, "/stream.ts") {
		t.Fatalf("URL 应指向 stream.ts: %s", info.URL)
	}

	direct := &http.Client{Transport: &http.Transport{Proxy: nil}}
	deadline := time.Now().Add(10 * time.Second)
	served := int64(0)
	for time.Now().Before(deadline) {
		resp, err := direct.Get(info.URL)
		if err == nil {
			n, _ := io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode == 200 && n > 64*1024 {
				served = n
				break
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	if served <= 64*1024 {
		t.Fatalf("stream.ts 未产出（>64KB）: %dB", served)
	}

	// Range 206：ts 产物与 hls 分片同口径。
	req, _ := http.NewRequest("GET", info.URL, nil)
	req.Header.Set("Range", "bytes=0-9")
	resp2, err := direct.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp2.Body)
	resp2.Body.Close()
	if resp2.StatusCode != 206 || len(b) != 10 {
		t.Fatalf("Range 应 206/10B: %d %dB", resp2.StatusCode, len(b))
	}

	castRelayStop(info.Session)
	if _, err := castRelayStatus(info.Session); err == nil {
		t.Fatal("停止后 Status 应报会话不存在")
	}
}

// TestRelayInfoLanIP：lanIp 出参（R3）——会话内缓存值优先；未缓存（测试
// 直建结构体/旧路径）回落 lanIP()。
func TestRelayInfoLanIP(t *testing.T) {
	s := &relaySession{
		id: "s", token: "tok", port: 1, startedAt: time.Now(),
		lastAccess: time.Now(), lanIP: "10.1.2.3",
	}
	info := s.info()
	if info.LanIP != "10.1.2.3" {
		t.Fatalf("缓存值应优先: %q", info.LanIP)
	}
	raw, err := json.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"lanIp":"10.1.2.3"`) {
		t.Fatalf("出参应含 lanIp 字段: %s", raw)
	}
	s2 := &relaySession{
		id: "s2", token: "tok", port: 1, startedAt: time.Now(),
		lastAccess: time.Now(),
	}
	if s2.info().LanIP == "" {
		t.Fatal("未缓存应回落 lanIP()")
	}
}

// TestRelayCaptionInfoHeader：CaptionInfo.sec 第三通道（R3）——会话登记字幕
// 时媒体响应带该头（直写 header map 保留驼峰拼写），未登记不带（不产生噪声）。
func TestRelayCaptionInfoHeader(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "stream.ts"), bytes.Repeat([]byte{0x47}, 256), 0o644); err != nil {
		t.Fatal(err)
	}
	caption := "http://192.168.1.5:18280/m/AbCdEf0123456789AbCdEf0123456789/subtitle.srt"
	s := &relaySession{
		id: "s-cap", token: "tok1234567890abcdef", dir: dir, format: "ts",
		subtitleURL: caption,
		startedAt:   time.Now(), lastAccess: time.Now(),
	}
	base := serveRelaySession(t, s)
	direct := noRedirectClient()

	resp, err := direct.Get(base + "/stream.ts")
	if err != nil {
		t.Fatal(err)
	}
	io.ReadAll(resp.Body)
	resp.Body.Close()
	if got := resp.Header.Get("CaptionInfo.sec"); got != caption {
		t.Fatalf("登记字幕应带 CaptionInfo.sec: %q", got)
	}
	raw, err := rawHttpGet(t, base+"/stream.ts")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(raw, "CaptionInfo.sec: "+caption) {
		t.Fatalf("响应头应保留规范驼峰拼写: %s", raw)
	}

	// 未登记字幕：不带（AC-6 不误带）。
	s2 := &relaySession{
		id: "s-cap2", token: "tok1234567890abcdef", dir: dir, format: "ts",
		startedAt: time.Now(), lastAccess: time.Now(),
	}
	base2 := serveRelaySession(t, s2)
	resp2, err := direct.Get(base2 + "/stream.ts")
	if err != nil {
		t.Fatal(err)
	}
	io.ReadAll(resp2.Body)
	resp2.Body.Close()
	if resp2.Header.Get("CaptionInfo.sec") != "" {
		t.Fatal("未登记字幕不应带 CaptionInfo.sec")
	}
	raw2, err := rawHttpGet(t, base2+"/stream.ts")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(raw2, "CaptionInfo.sec:") {
		t.Fatalf("未登记字幕线上字节不应出现该头: %s", raw2)
	}
}

func TestSweepOrphanDirs(t *testing.T) {
	// 孤儿目录： aquan-cast- 前缀 → 应被清；其他前缀 → 不动。
	orphan, err := os.MkdirTemp("", "aquan-cast-orphan-test")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(orphan)
	other, err := os.MkdirTemp("", "not-aquan-cast-keep")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(other)
	// 孤儿里放个产物文件，验证目录确实被删。
	if err := os.WriteFile(filepath.Join(orphan, "index.m3u8"), []byte("#EXTM3U"), 0o644); err != nil {
		t.Fatal(err)
	}

	sweepOrphanDirs()

	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("孤儿中继目录未被清理: %s", orphan)
	}
	if _, err := os.Stat(other); err != nil {
		t.Fatalf("非 aquan-cast 目录被误删: %s", other)
	}
}

// --- 11-08-android-cast-device-fixes：workDir / stderr 诊断 / URL 清洗 ---

func TestMkRelayTempDirWorkDir(t *testing.T) {
	base, err := os.MkdirTemp("", "aquan-workdir-base")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)

	dir, err := mkRelayTempDir(relayOptions{WorkDir: base})
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)

	if !strings.HasPrefix(dir, base) {
		t.Fatalf("会话目录应落在 WorkDir 下: dir=%s base=%s", dir, base)
	}
	relayWorkDirMu.Lock()
	got := relayWorkDirCurrent
	relayWorkDirMu.Unlock()
	if got != base {
		t.Fatalf("relayWorkDirCurrent 未随 mkRelayTempDir 更新: %s", got)
	}

	// 空基址回落现状（os.TempDir），且不清 relayWorkDirCurrent 之外的值。
	dir2, err := mkRelayTempDir(relayOptions{})
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir2)
	if !strings.HasPrefix(dir2, os.TempDir()) {
		t.Fatalf("空 WorkDir 应回落 os.TempDir(): %s", dir2)
	}
}

func TestSweepOrphanDirsWorkDir(t *testing.T) {
	base, err := os.MkdirTemp("", "aquan-sweep-base")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(base)

	orphan := filepath.Join(base, "aquan-cast-orphan")
	if err := os.Mkdir(orphan, 0o755); err != nil {
		t.Fatal(err)
	}
	keep := filepath.Join(base, "not-aquan-cast-keep")
	if err := os.Mkdir(keep, 0o755); err != nil {
		t.Fatal(err)
	}

	// 伪装最近会话在 base：清扫应覆盖它（os.TempDir 也要扫，防误删无关目录不成立——
	// base 内非前缀目录必须保留）。
	relayWorkDirMu.Lock()
	prev := relayWorkDirCurrent
	relayWorkDirCurrent = base
	relayWorkDirMu.Unlock()
	defer func() {
		relayWorkDirMu.Lock()
		relayWorkDirCurrent = prev
		relayWorkDirMu.Unlock()
	}()

	sweepOrphanDirs()

	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("WorkDir 下的孤儿目录未被清理: %s", orphan)
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("非 aquan-cast 目录被误删: %s", keep)
	}
}

func TestRedactUrls(t *testing.T) {
	in := "https://cdn.example.com/v.mp4?sig=abc http://a.b/c 403 Forbidden"
	got := redactUrls(in)
	if strings.Contains(got, "example.com") || strings.Contains(got, "a.b") {
		t.Fatalf("URL 未清洗: %s", got)
	}
	if !strings.Contains(got, "<url>") || !strings.Contains(got, "403 Forbidden") {
		t.Fatalf("清洗后应保留非 URL 文本: %s", got)
	}
}

func TestRelayStderrTail(t *testing.T) {
	dir := t.TempDir()
	if got := relayStderrTail(dir); got != "" {
		t.Fatalf("无日志文件应返回空串: %q", got)
	}
	log := filepath.Join(dir, "ffmpeg-stderr.log")
	content := "https://secret.example.com/v.mp4?sig=1: Server returned 403 Forbidden (access denied)"
	if err := os.WriteFile(log, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	got := relayStderrTail(dir)
	if strings.Contains(got, "secret.example") {
		t.Fatalf("stderr 尾部含未清洗 URL: %s", got)
	}
	if !strings.Contains(got, "403 Forbidden") || !strings.HasPrefix(got, "; stderr: ") {
		t.Fatalf("尾部格式不符: %s", got)
	}

	// 超长截尾：只保留最后 800 字节且不劈 UTF-8。
	long := strings.Repeat("a", 900) + "中文结尾"
	if err := os.WriteFile(log, []byte("https://x.y/z "+long), 0o644); err != nil {
		t.Fatal(err)
	}
	tail := relayStderrTail(dir)
	if len(tail) == 0 || strings.Contains(tail, "中文结尾") == false {
		t.Fatalf("超长日志应保留尾部内容: %s", tail)
	}
}

// --- 11-09-cast-relay-ffmpeg-compat：independent_segments 版本门控 ---

func TestFfmpegVersionAtLeast43(t *testing.T) {
	cases := []struct {
		name string
		out  string
		want bool
	}{
		{"4.0.x（内置 2018 构建）", "ffmpeg version 4.0.2 Copyright (c) 2000-2018 the FFmpeg developers", false},
		{"4.2 边界下", "ffmpeg version 4.2.9-0ubuntu0.1", false},
		{"4.3 起支持", "ffmpeg version 4.3 Copyright (c) 2000-2020 the FFmpeg developers", true},
		{"n 前缀 4.3.1", "ffmpeg version n4.3.1-22-gdb8806958c", true},
		{"v 前缀 4.4", "ffmpeg version v4.4.2", true},
		{"6.x", "ffmpeg version 6.1.1 Copyright", true},
		{"git 日期构建按年份判新", "ffmpeg version 2024-05-05-git-abc123 Copyright", true},
		{"master 缩写截断解析失败按旧", "ffmpeg version N-109483-gabc123", false},
		{"3.x", "ffmpeg version 3.4.8", false},
		{"无 version 字段", "garbage output", false},
		{"空输出", "", false},
	}
	for _, c := range cases {
		if got := ffmpegVersionAtLeast43(c.out); got != c.want {
			t.Errorf("%s: ffmpegVersionAtLeast43 = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestBuildFFmpegArgsIndependentSegmentsGate(t *testing.T) {
	opts := relayOptions{URL: "https://up/v.mp4", Format: "hls", Quality: "balanced"}
	dir := t.TempDir()

	containsFlag := func(args []string) bool {
		for i, a := range args {
			if a == "-hls_flags" && i+1 < len(args) && args[i+1] == "independent_segments" {
				return true
			}
		}
		return false
	}

	// 旧内核（探测失败/解析失败同口径）：不挂 flag，其余参数原样。
	ffmpegCapsMu.Lock()
	ffmpegCaps["/fake/old"] = false
	ffmpegCapsMu.Unlock()
	old := buildFFmpegArgs("/fake/old", opts, dir, "")
	if containsFlag(old) {
		t.Fatal("旧内核不应挂 independent_segments")
	}

	// 新内核：字节级等于现状（含 flag）。
	ffmpegCapsMu.Lock()
	ffmpegCaps["/fake/new"] = true
	ffmpegCapsMu.Unlock()
	newArgs := buildFFmpegArgs("/fake/new", opts, dir, "")
	if !containsFlag(newArgs) {
		t.Fatal("新内核应挂 independent_segments（桌面现状）")
	}

	// 清理：不留缓存污染其他用例（真实 ffmpeg e2e 需要走真实探测）。
	ffmpegCapsMu.Lock()
	delete(ffmpegCaps, "/fake/old")
	delete(ffmpegCaps, "/fake/new")
	ffmpegCapsMu.Unlock()
}
