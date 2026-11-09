#!/usr/bin/env python3
"""Build the Go native library and Flutter APK for Android.

Examples:
  python scripts/build_android.py --ndk "$ANDROID_HOME/ndk/28.2.13676358"
  python scripts/build_android.py --ndk <path> --abi armeabi-v7a --mode debug
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SUPPORTED_ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
ABI_PLATFORMS = {
    "arm64-v8a": "android-arm64",
    "armeabi-v7a": "android-arm",
    "x86_64": "android-x64",
}


def run(cmd: list[str], *, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, cwd=REPO, env=env)


def app_version() -> str:
    """Read the semantic version from pubspec.yaml for native version injection."""
    pubspec = (REPO / "pubspec.yaml").read_text(encoding="utf-8")
    match = re.search(r"(?m)^version:\s*([^+\s]+)", pubspec)
    if not match:
        raise ValueError("pubspec.yaml 中未找到有效的 version 字段")
    return match.group(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ndk", default=os.environ.get("ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK"))
    parser.add_argument("--abi", choices=("arm64-v8a", "armeabi-v7a", "all"), default="all")
    parser.add_argument("--mode", choices=("debug", "release"), default="release")
    parser.add_argument("--version", help="Native version; defaults to pubspec.yaml version")
    parser.add_argument("--output-dir", type=Path, default=REPO / "dist" / "android")
    args = parser.parse_args()

    if not args.ndk:
        parser.error("--ndk 或 ANDROID_NDK_HOME 必须指定")

    ndk = Path(args.ndk).expanduser().resolve()
    if not (ndk / "toolchains" / "llvm" / "prebuilt").is_dir():
        parser.error(f"NDK 工具链目录不存在: {ndk}")

    abis = SUPPORTED_ABIS if args.abi == "all" else (args.abi,)
    version = args.version or app_version()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    run([
        sys.executable,
        str(REPO / "scripts" / "build_native.py"),
        "--android",
        "--ndk", str(ndk),
        "--abi", args.abi,
        "--version", version,
    ])

    flutter_cmd = ["flutter", "build", "apk", f"--{args.mode}", "--split-per-abi"]
    if args.abi != "all":
        flutter_cmd.append(f"--target-platform={ABI_PLATFORMS[args.abi]}")
    run(flutter_cmd)

    apk_dir = REPO / "build" / "app" / "outputs" / "flutter-apk"
    mode_suffix = f"-{args.mode}.apk"
    copied: list[Path] = []
    for abi in abis:
        source = apk_dir / f"app-{abi}{mode_suffix}"
        if not source.is_file():
            raise FileNotFoundError(f"预期的 APK 不存在: {source}")
        destination = output_dir / f"阿圆短剧-{abi}-{args.mode}.apk"
        destination.write_bytes(source.read_bytes())
        copied.append(destination)
        print(f"APK: {destination} ({destination.stat().st_size:,} bytes)")

    if not copied:
        raise RuntimeError("构建成功但没有生成任何 APK")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"Android build failed: {exc}", file=sys.stderr)
        sys.exit(1)
