#!/usr/bin/env python3
"""Android 完整构建：Go 核心 so（三 ABI）→ flutter build apk --split-per-abi。

用法：python scripts/build_android.py --ndk <NDK 路径> [--version 0.1.0]
产物：build/app/outputs/flutter-apk/*.apk
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def sh(cmd: list[str]) -> None:
    # Windows 上 flutter 是 .bat，CreateProcess 不做 PATHEXT 解析。
    if os.name == "nt" and cmd and cmd[0] == "flutter":
        cmd = ["flutter.bat"] + cmd[1:]
    print("+", " ".join(cmd))
    subprocess.run(cmd, check=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ndk", required=True)
    ap.add_argument("--version", default="0.0.0-dev")
    args = ap.parse_args()

    sh([sys.executable, str(REPO / "scripts" / "build_native.py"),
        "--android", "--ndk", args.ndk, "--version", args.version])
    # Repair known malformed Dart fragments in the checkout before compilation.
    sh([sys.executable, str(REPO / "scripts" / "repair_android_dart_sources.py")])
    sh(["flutter", "build", "apk", "--release", "--split-per-abi"])


if __name__ == "__main__":
    main()
