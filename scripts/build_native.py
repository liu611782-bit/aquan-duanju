#!/usr/bin/env python3
"""编译 Go 数据核心（native/bridge）为各平台的动态库。

- Windows: aquan_core.dll（mingw gcc，需在 PATH）
- Android: android/app/src/main/jniLibs/<abi>/libaquan_core.so（NDK clang）
- Linux:   libaquan_core.so（本机 gcc）

用法：
  python scripts/build_native.py --windows
  python scripts/build_native.py --android --ndk "$ANDROID_HOME/ndk/28.2.13676358"
  python scripts/build_native.py --all --ndk <path>

版本号注入：--version X.Y.Z（与 pubspec 的 version 前缀一致）。
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
BRIDGE = REPO / "native" / "bridge"

# ABI → (clang triple 前缀, GOARCH)
ANDROID_ABIS = {
    "arm64-v8a": ("aarch64-linux-android", "arm64"),
    "armeabi-v7a": ("armv7a-linux-androideabi", "arm"),
    "x86_64": ("x86_64-linux-android", "amd64"),
}

# 16KB 页对齐：Android 15+ 对含未对齐段的应用的新要求。
ANDROID_LDFLAGS = "-Wl,-z,max-page-size=16384"


def run(cmd: list[str], env: dict[str, str], cwd: Path = BRIDGE) -> None:
    print("+", " ".join(str(c) for c in cmd))
    subprocess.run(cmd, check=True, env=env, cwd=str(cwd))


def ldflags(version: str) -> str:
    return f"-X github.com/wjsqqj/aquan-core/core.Version={version}"


def build_windows(version: str, out: Path | None = None) -> Path:
    if shutil.which("gcc") is None:
        sys.exit("需要 mingw gcc（windows 上 go build -buildmode=c-shared 依赖它）")
    target = out or (REPO / "build" / "aquan_core.dll")
    target.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.setdefault("CGO_ENABLED", "1")
    run(
        ["go", "build", "-buildmode=c-shared",
         "-ldflags", ldflags(version), "-o", str(target), "."],
        env,
    )
    print(f"built {target}")
    return target


def stage_android_ffmpeg(jni: Path) -> None:
    """把仓库内的 libffmpeg-<abi>.so 落位成 jniLibs/<abi>/libffmpeg.so。

    jniLibs 整体被 .gitignore 排除（Go 产物每次重建），所以内置的 ffmpeg 二进制
    放在 android/ffmpeg/ 里纳入版本控制，构建时再拷进 jniLibs——否则 CI 打出的
    APK 不含 ffmpeg，加密分集只能退化成镜像投屏。
    """
    src_dir = REPO / "android" / "ffmpeg"
    for abi in ("arm64-v8a", "armeabi-v7a"):
        src = src_dir / f"libffmpeg-{abi}.so"
        if not src.exists():
            print(f"skip ffmpeg for {abi}: {src} 不存在")
            continue
        dst = jni / abi / "libffmpeg.so"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        print(f"staged {dst}")


def build_android(version: str, ndk: str) -> None:
    ndk_path = Path(ndk)
    toolchain = ndk_path / "toolchains" / "llvm" / "prebuilt"
    hosts = [d for d in toolchain.iterdir() if d.is_dir()]
    if not hosts:
        sys.exit(f"NDK 工具链不存在: {toolchain}")
    clang_bin = hosts[0] / "bin"
    jni = REPO / "android" / "app" / "src" / "main" / "jniLibs"
    for abi, (triple, goarch) in ANDROID_ABIS.items():
        out_dir = jni / abi
        out_dir.mkdir(parents=True, exist_ok=True)
        so = out_dir / "libaquan_core.so"
        env = os.environ.copy()
        env.update({
            "CGO_ENABLED": "1",
            "GOOS": "android",
            "GOARCH": goarch,
            "CC": f"{clang_bin / triple}24-clang.cmd"
            if os.name == "nt"
            else f"{clang_bin / triple}24-clang",
        })
        cmd = ["go", "build", "-buildmode=c-shared",
               "-ldflags",
               f"{ldflags(version)} -extldflags '{ANDROID_LDFLAGS}'",
               "-o", str(so), "."]
        run(cmd, env)
        print(f"built {so}")

    # jniLibs 被 .gitignore 排除：ffmpeg 二进制从 android/ffmpeg 落位进来。
    stage_android_ffmpeg(jni)


def build_linux(version: str) -> None:
    out = REPO / "build" / "libaquan_core.so"
    out.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.setdefault("CGO_ENABLED", "1")
    run(["go", "build", "-buildmode=c-shared",
         "-ldflags", ldflags(version), "-o", str(out), "."], env)
    print(f"built {out}")


def build_macos(version: str) -> None:
    out = REPO / "build" / "libaquan_core.dylib"
    out.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.setdefault("CGO_ENABLED", "1")
    run(["go", "build", "-buildmode=c-shared",
         "-ldflags", ldflags(version), "-o", str(out), "."], env)
    print(f"built {out}")


def build_cli(version: str, goos: str = "", goarch: str = "") -> Path:
    """构建命令行入口（纯 Go，不依赖 cgo）。"""
    name = "aquan-cli.exe" if goos == "windows" else "aquan-cli"
    out = REPO / "build" / name
    out.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CGO_ENABLED"] = "0"
    if goos:
        env["GOOS"] = goos
    if goarch:
        env["GOARCH"] = goarch
    run(["go", "build", "-trimpath", "-ldflags", ldflags(version),
         "-o", str(out), "./cmd/aquan-cli"], env)
    print(f"built {out}")
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--windows", action="store_true")
    ap.add_argument("--android", action="store_true")
    ap.add_argument("--linux", action="store_true")
    ap.add_argument("--macos", action="store_true")
    ap.add_argument("--cli", action="store_true", help="只构建命令行工具")
    ap.add_argument("--all", action="store_true", help="windows+android")
    ap.add_argument("--ndk", default=os.environ.get("ANDROID_NDK", ""))
    ap.add_argument("--version", default="0.0.0-dev")
    args = ap.parse_args()

    if not (args.windows or args.android or args.linux or args.macos
            or args.cli or args.all):
        ap.error("至少选择一个目标：--windows/--android/--linux/--macos/--cli/--all")

    targets = {
        "windows": args.windows or args.all,
        "android": args.android or args.all,
        "linux": args.linux,
        "macos": args.macos,
    }
    if targets["android"] and not args.ndk:
        sys.exit("--android 需要 --ndk <NDK 路径>（或 ANDROID_NDK 环境变量）")

    if targets["windows"]:
        build_windows(args.version)
    if targets["android"]:
        build_android(args.version, args.ndk)
    if targets["linux"]:
        build_linux(args.version)
    if targets["macos"]:
        build_macos(args.version)
    if args.cli:
        build_cli(args.version, "windows" if os.name == "nt" else "")


if __name__ == "__main__":
    main()
