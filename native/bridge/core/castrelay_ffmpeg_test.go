package core

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestParseNativeLibDir(t *testing.T) {
	maps := strings.Join([]string{
		"7f0000000000-7f0000100000 r-xp 00000000 fd:01 100 /system/lib64/libc.so",
		"7f0000100000-7f0000200000 r-xp 00000000 fd:01 101 /data/app/~~abc/com.aquan.duanju-xyz/lib/arm64/libaquan_core.so",
		"7f0000200000-7f0000300000 r--p 00000000 fd:01 102 /data/app/~~abc/com.aquan.duanju-xyz/lib/arm64/libffmpeg.so",
	}, "\n")

	got := parseNativeLibDir(maps)
	want := "/data/app/~~abc/com.aquan.duanju-xyz/lib/arm64"
	if got != want {
		t.Fatalf("nativeLibraryDir 解析错误: got %q want %q", got, want)
	}
}

func TestParseNativeLibDirMissing(t *testing.T) {
	cases := []string{
		"",
		"7f0000000000-7f0000100000 r-xp 00000000 fd:01 100 /system/lib64/libc.so",
		// 只有 5 列（没有路径）——不能当成有效映射。
		"7f0000100000-7f0000200000 r-xp 00000000 fd:01 101",
		// 路径不是绝对路径（[anon:...] 之类的伪路径）。
		"7f0000200000-7f0000300000 r-xp 00000000 fd:01 102 [anon:libaquan_core.so]",
	}
	for _, maps := range cases {
		if got := parseNativeLibDir(maps); got != "" {
			t.Fatalf("期望空结果，got %q (maps=%q)", got, maps)
		}
	}
}

func TestIsExecutableFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "ffmpeg")
	if err := os.WriteFile(p, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !isExecutableFile(p) {
		t.Fatalf("存在的文件应判定为可执行: %s", p)
	}
	if isExecutableFile(filepath.Join(dir, "missing")) {
		t.Fatal("不存在的文件不能判定为可执行")
	}
	if isExecutableFile("") {
		t.Fatal("空路径不能判定为可执行")
	}
	if isExecutableFile(dir) {
		t.Fatal("目录不是可执行文件")
	}

	// 非 Windows 平台才检查执行位。
	if runtime.GOOS != "windows" {
		plain := filepath.Join(dir, "plain")
		if err := os.WriteFile(plain, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		if isExecutableFile(plain) {
			t.Fatal("没有执行位的文件不应判定为可执行")
		}
	}
}

func TestFindFFmpegEnvOverride(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "custom-ffmpeg")
	if err := os.WriteFile(p, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AQUAN_FFMPEG", p)

	got, err := findFFmpeg()
	if err != nil {
		t.Fatalf("应命中环境变量指定的 ffmpeg: %v", err)
	}
	if got != p {
		t.Fatalf("应优先使用 AQUAN_FFMPEG: got %q want %q", got, p)
	}
}

func TestFindFFmpegIgnoresBadEnv(t *testing.T) {
	// 指向不存在的路径时必须回落到其它查找方式，而不是直接失败。
	t.Setenv("AQUAN_FFMPEG", filepath.Join(t.TempDir(), "nope"))

	if runtime.GOOS != "android" {
		// 桌面环境 PATH 里通常有 ffmpeg；没有时 findFFmpeg 会返回错误，
		// 这里只断言「不会返回那个坏路径」。
		got, _ := findFFmpeg()
		if strings.Contains(got, "nope") {
			t.Fatalf("不应返回不存在的路径: %q", got)
		}
	}
}
