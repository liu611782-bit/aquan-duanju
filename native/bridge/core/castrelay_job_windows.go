//go:build windows

package core

import (
	"fmt"
	"os"
	"unsafe"

	"golang.org/x/sys/windows"
)

// 进程级 Job Object：所有 ffmpeg 子进程挂进同一个 Job 并设置
// KILL_ON_JOB_CLOSE——app 进程（无论正常退出/强杀/崩溃）终止句柄关闭时，
// 内核自动终止全部子进程。sweeper 只能清临时目录，清不了孤儿进程；
// 这是转码资源泄漏的最终防线。

var (
	jobHandle windows.Handle
)

func assignFfmpegToJob(proc *os.Process) {
	if err := ensureCastJob(); err != nil {
		// Job 不可用（极少见）：退化为旧行为，孤儿由用户任务管理器处理。
		return
	}
	// os.Process 不暴露句柄：按 PID 打开（进程刚 Start，权限必然满足）。
	hProc, err := windows.OpenProcess(windows.PROCESS_ALL_ACCESS, false, uint32(proc.Pid))
	if err != nil {
		return
	}
	defer windows.CloseHandle(hProc)
	_ = windows.AssignProcessToJobObject(jobHandle, hProc)
}

func ensureCastJob() error {
	if jobHandle != 0 {
		return nil
	}
	h, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return err
	}
	limit := windows.JOBOBJECT_BASIC_LIMIT_INFORMATION{
		LimitFlags: windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{
		BasicLimitInformation: limit,
	}
	if _, err := windows.SetInformationJobObject(
		h,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)),
		uint32(unsafe.Sizeof(info)),
	); err != nil {
		_ = windows.CloseHandle(h)
		return fmt.Errorf("SetInformationJobObject: %w", err)
	}
	jobHandle = h
	return nil
}
