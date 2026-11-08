//go:build !windows

package core

import "os"

// 非 Windows 平台：ffmpeg 在进程组内随父进程退出（Android 无独立 ffmpeg
// 子进程，libffmpeg 在进程内），无孤儿问题，空实现。
func assignFfmpegToJob(proc *os.Process) {}
