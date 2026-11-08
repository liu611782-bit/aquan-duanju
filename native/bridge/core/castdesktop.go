// castdesktop 实现 Windows 桌面屏幕镜像的中继（投屏 P2）：
//
//	本机桌面 ──ffmpeg ddagrab(DXGI 桌面复制) 采集──▶ libx264 HLS（滚动窗口）──▶ 电视拉流
//
// 会话模型/端口/令牌/回收与 castrelay 完全一致（共用 relaySessions 与 sweeper）；
// 与 castrelay 的差异：输入是 ddagrab 桌面（无需授权框）、HLS 用 delete_segments
// 滚动窗口（直播语义，磁盘不涨）、仅 Windows（ddagrab 平台限定，ffmpeg ≥6.0）。
// 音频：Windows 桌面回放采集需 dshow 虚拟设备，首版仅视频。
//
// 实测坑（本机 ffmpeg 9.0.2 验证）：
//   - gdigrab 在部分会话抓不到帧（静默零输出），必须用 ddagrab（DXGI）；
//   - ddagrab 输出 D3D11 帧，libx264 前必须 hwdownload,format=bgra；
//   - DXGI 只在画面变化时送帧：滤镜链加 fps=N 复制末帧补节拍，否则静止桌面
//     流时间冻结、HLS 永远切不出段；
//   - 关键帧间隔要与 hls_time 对齐（-g = fps×2），否则首段要等默认 250 帧的 IDR；
//   - exec 无 shell：min(720,ih) 的逗号要写成 \\,（Go 源码双反斜杠）。
package core

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"time"
)

// 桌面镜像哨兵错误：注册进 errorCodes 表。
var ErrDesktopUnsupported = errors.New("desktop mirror unsupported")

// desktopOptions 是 castDesktopStart 的入参。
type desktopOptions struct {
	FPS int `json:"fps"` // 采集帧率；0 → 10
}

// castDesktopStart 启动桌面镜像中继。入参：[optionsJSON]；
// 出参：relaySessionInfo（URL 指向 /cast/<token>/index.m3u8）。
func castDesktopStart(opts desktopOptions) (*relaySessionInfo, error) {
	if runtime.GOOS != "windows" {
		return nil, relayFail(ErrDesktopUnsupported, "桌面镜像仅支持 Windows")
	}
	if opts.FPS <= 0 || opts.FPS > 60 {
		opts.FPS = 10
	}
	startSweeper()

	ffmpeg, err := findFFmpeg()
	if err != nil {
		return nil, relayFail(ErrRelayUnavailable,
			"未找到 ffmpeg，无法镜像桌面；请将 ffmpeg 放到应用目录或 PATH")
	}
	token, err := randomToken()
	if err != nil {
		return nil, relayFail(ErrRelayInternal, "token 生成失败")
	}
	dir, err := mkCastTempDir("aquan-cast-desktop-")
	if err != nil {
		return nil, relayFail(ErrRelayInternal, "临时目录创建失败")
	}
	port, ln, err := listenOnFreePort(relayBasePort)
	if err != nil {
		removeCastDir(dir)
		return nil, relayFail(ErrRelayInternal, "端口监听失败")
	}
	srv := newCastServer()

	sessionID := token[:16]
	session := &relaySession{
		id:         sessionID,
		token:      token,
		port:       port,
		dir:        dir,
		srv:        srv,
		startedAt:  time.Now(),
		lastAccess: time.Now(),
	}
	args := buildDesktopFFmpegArgs(ffmpeg, opts, dir)
	cmd := execCommand(args)
	cmd.Env = cleanProxyEnv()
	// stderr 落会话目录（桌面采集无敏感 URL）：诊断 ddagrab/滤镜问题；随目录回收。
	if logFile, logErr := os.Create(filepath.Join(dir, "ffmpeg.log")); logErr == nil {
		cmd.Stderr = logFile
	}
	session.cmd = cmd
	if err := cmd.Start(); err != nil {
		srv.Close()
		removeCastDir(dir)
		return nil, relayFail(ErrRelayUnavailable, "ffmpeg 启动失败: "+err.Error())
	}
	// 与 castrelay 同款（castrelay_job_windows.go）：桌面镜像的 ffmpeg 同样
	// 挂进程级 Job，app 强杀/崩溃不留孤儿转码进程。
	assignFfmpegToJob(cmd.Process)
	session.waitCh = make(chan struct{})
	go func() {
		session.waitErr = cmd.Wait()
		close(session.waitCh)
	}()

	serveCastFiles(session, ln)

	// 就绪快检：10s 内出 index.m3u8 即放行；进程提前退出即失败。
	deadline := time.NewTimer(10 * time.Second)
	defer deadline.Stop()
	for {
		select {
		case <-session.waitCh:
			stopAndRemove(session)
			return nil, relayFail(ErrRelayUnavailable,
				"桌面镜像启动失败（ffmpeg 提前退出，检查桌面会话是否可用）")
		case <-deadline.C:
			session.ready = indexReady(dir)
			putRelaySession(session)
			return session.info(), nil
		default:
			if indexReady(dir) && hasSegments(dir) {
				session.ready = true
				putRelaySession(session)
				return session.info(), nil
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
}

// castDesktopStop 停止桌面镜像会话。
func castDesktopStop(sessionID string) error {
	relayStop(sessionID)
	return nil
}

// castDesktopStatus 查询桌面镜像会话状态。
func castDesktopStatus(sessionID string) (*relaySessionInfo, error) {
	return relayStatus(sessionID)
}

// desktopOptionsFromJSON 解析 Dart 传来的 options JSON。
func desktopOptionsFromJSON(raw []byte) (desktopOptions, error) {
	var opts desktopOptions
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &opts); err != nil {
			return opts, relayFail(ErrRelayInvalid, "options 解析失败")
		}
	}
	return opts, nil
}

// buildDesktopFFmpegArgs：ddagrab 全屏采集 → hwdownload → fps 补帧 → ≤720p 缩放
// → libx264（GOP 对齐 hls_time）→ HLS 滚动窗口。
func buildDesktopFFmpegArgs(ffmpeg string, opts desktopOptions, dir string) []string {
	return []string{
		ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "ddagrab=framerate=" + strconv.Itoa(opts.FPS),
		// exec 无 shell：min(720,ih) 的逗号必须转义，否则滤镜链按逗号被切碎。
		"-vf", "hwdownload,format=bgra,fps=" + strconv.Itoa(opts.FPS) +
			",scale=-2:min(720\\,ih),format=yuv420p",
		"-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
		"-g", strconv.Itoa(opts.FPS * 2),
		"-f", "hls",
		"-hls_time", "2",
		"-hls_list_size", "6",
		"-hls_flags", "delete_segments+independent_segments",
		"-hls_segment_filename", filepath.Join(dir, "seg_%05d.ts"),
		filepath.Join(dir, "index.m3u8"),
	}
}
