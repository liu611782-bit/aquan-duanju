package core

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/beilunyang/openhongguo/sdk"
)

// registeredCode 校验 code 已在 errorCodes 表注册：panic 必须复用已注册 code，
// 不新增错误码，也不改变 Dart 侧方法表签名。
func registeredCode(code string) bool {
	for _, e := range errorCodes {
		if e.Code == code {
			return true
		}
	}
	return false
}

func TestFFIRecoverGuardPanicEnvelope(t *testing.T) {
	// 若 Guard 未 recover，本用例会直接 panic 让 go test 进程崩溃（即跨 FFI abort）。
	out := Guard(func() string {
		panic("boom https://cdn.example/play?token=SECRET123&key=abc")
	})
	env := decode(t, out)
	if env.Error == nil {
		t.Fatalf("panic 应转成 error 信封，得到: %s", out)
	}
	code, _ := env.Error["code"].(string)
	if !registeredCode(code) {
		t.Fatalf("code=%q 未注册在 errorCodes 表", code)
	}
	if env.Result != nil {
		t.Fatalf("错误信封不应带 result: %s", out)
	}
	if strings.Contains(out, "SECRET123") || strings.Contains(out, "key=abc") {
		t.Fatalf("panic 摘要未脱敏（完整 URL / 凭据泄漏）: %s", out)
	}
}

func TestFFIRecoverCallPanicDoesNotAbort(t *testing.T) {
	// 临时注入一个必然 panic 的方法（测试键，不写入正式方法表签名）。
	const name = "__ffi_recover_panic__"
	methods[name] = func(_ context.Context, _ *sdk.Client, _ []json.RawMessage) (any, error) {
		panic("encoder nil pointer")
	}
	defer delete(methods, name)

	h := register(&sdk.Client{})
	out := Call(h, name, "")
	env := decode(t, out)
	if env.Error == nil {
		t.Fatalf("方法 panic 应转成 error 信封，得到: %s", out)
	}
	code, _ := env.Error["code"].(string)
	if !registeredCode(code) {
		t.Fatalf("code=%q 未注册在 errorCodes 表", code)
	}
	// 进程存活且登记表未损坏：再来一次与常规方法调用都应正常返回信封。
	if again := decode(t, Call(h, name, "")); again.Error == nil {
		t.Fatal("二次 panic 仍应被包裹为 error 信封")
	}
	if unknown := decode(t, Call(h, "noSuchMethod", "")); unknown.Error == nil {
		t.Fatal("recover 之后常规路径应仍可用")
	}
}

func TestFFIRecoverNewStillReturnsInvalidOptions(t *testing.T) {
	// New 也经 Guard 包装：常规错误路径的 code 不受影响。
	env := decode(t, New("", "{bad json"))
	if env.Error == nil || env.Error["code"] != "INVALID_OPTIONS" {
		t.Fatalf("Guard 不应改变 New 的常规错误码: %v", env.Error)
	}
}

func TestFFIRecoverVersionAndMethods(t *testing.T) {
	// C 导出 AquaVersion 的底层字符串与 Methods 列表在护栏后仍可用。
	if out := Guard(func() string { return Version }); out == "" {
		t.Fatal("Version 不应为空")
	}
	if !registeredCode("TRANSPORT") {
		t.Fatal("panic 复用的 TRANSPORT 必须是已注册 code")
	}
	if names := Methods(); len(names) == 0 {
		t.Fatal("Methods 在 recover 护栏后仍应返回方法名")
	}
}
