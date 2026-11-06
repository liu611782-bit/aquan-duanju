// Command bridge 是阿圈短剧 app 的 c-shared 动态库入口：Android 的
// libaquan_core.so 与 Windows 的 aquan_core.dll。
//
// 这一层只做 C 字符串与 Go 字符串的转换，全部逻辑在 core 包里（见其文档）。
// 结果 JSON 用完必须调 AquaFreeString 释放。
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"github.com/wjsqqj/aquan-core/core"
)

// AquaNew 创建客户端。profilePath 是设备档案 JSON 的路径；configJSON 可以为空。
// 返回 {"handle":N} 或 {"error":{…}}。
//
//export AquaNew
func AquaNew(profilePath, configJSON *C.char) *C.char {
	// Dart 可调导出统一走 core.Guard（defer recover）：panic 转既有 error
	// envelope，绝不跨 FFI abort；方法表与 Dart 侧调用签名不变。
	return cString(core.Guard(func() string {
		return core.New(goString(profilePath), goString(configJSON))
	}))
}

// AquaCall 阻塞执行一次 SDK 调用（必须在后台线程调用）：
// method 是 dispatch 方法名，argsJSON 是参数数组的 JSON。
// 返回 {"result":…} 或 {"error":{…}}。
//
//export AquaCall
func AquaCall(handle C.int, method, argsJSON *C.char) *C.char {
	return cString(core.Guard(func() string {
		return core.Call(int32(handle), goString(method), goString(argsJSON))
	}))
}

// AquaVersion 返回核心版本号。
//
//export AquaVersion
func AquaVersion() *C.char {
	return cString(core.Guard(func() string { return core.Version }))
}

// AquaFreeString 释放 AquaNew/AquaCall/AquaVersion 返回的字符串。
// 每个返回值恰好释放一次。
//
//export AquaFreeString
func AquaFreeString(s *C.char) {
	// 无返回值的导出同样兜底 recover，保持统一护栏口径。
	defer func() { _ = recover() }()
	C.free(unsafe.Pointer(s))
}

func goString(s *C.char) string {
	if s == nil {
		return ""
	}
	return C.GoString(s)
}

func cString(s string) *C.char {
	return C.CString(s)
}

// main 不会被执行；c-shared 构建要求它存在。
func main() {}
