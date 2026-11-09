#!/usr/bin/env bash
# build_android_ffmpeg.sh — 交叉编译安卓中继三件套（x264 → openssl → ffmpeg）
#
# 运行环境：MSYS2 bash（/d/msys64/usr/bin/bash），需 make/perl/nasm/pkg-config。
# 产物：android/ffmpeg/libffmpeg-<abi>.so（静态 PIE 单文件，同现有打包通道）。
# 版本钉死 + SHA256 由本脚本下载后计算并写 build/ffmpeg-build/SHA256S.txt，
# 人工核对后登记 android/ffmpeg/README.md。
#
# 用法：
#   /d/msys64/usr/bin/bash scripts/build_android_ffmpeg.sh            # 全部 ABI
#   /d/msys64/usr/bin/bash scripts/build_android_ffmpeg.sh arm64-v8a  # 单 ABI
# 阶段有 stamp 幂等：重跑跳过已完成阶段（stamps/ 目录删某个 stamp 即重做该阶段）。
set -euo pipefail

# 非登录 bash 会继承调用方（如 Git Bash）的 PATH，缺少 MSYS2 的 /usr/bin
# （make/strings/od 都在那）——先规范化，再走到 NDK 目录。
export PATH="/usr/bin:/bin:/mingw64/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO_ROOT/build/ffmpeg-build"
SRC="$WORK/src"
PREFIXES="$WORK/prefixes"
STAMPS="$WORK/stamps"
LOGS="$WORK/logs"
OUT="$REPO_ROOT/android/ffmpeg"
NDK="/d/Android/Sdk/ndk/28.2.13676358"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64"
API=24

X264_REF="0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee"          # code.videolan.org master @2026-11-09
OPENSSL_VER="3.5.4"
FFMPEG_VER="8.0.1"

mkdir -p "$SRC" "$PREFIXES" "$STAMPS" "$LOGS"
cd "$WORK"

# 原生 Windows clang 的临时目录必须是「正斜杠 Windows 路径」——MSYS2 的
# /tmp 传给它会「unable to make temporary file」；反斜杠形式同样失败
# （11-09 实测两种都踩过）。cygpath -m = D:/xxx 混合形态。
mkdir -p "$WORK/tmp"
BUILD_TMP_WIN=$(cygpath -m "$WORK/tmp")
export TMP="$BUILD_TMP_WIN" TEMP="$BUILD_TMP_WIN" TMPDIR="$BUILD_TMP_WIN"

# ---- 源码获取（钉版本，幂等） ------------------------------------------------
fetch_sources() {
  if [ ! -d "$SRC/x264" ]; then
    echo "[fetch] x264 @$X264_REF"
    curl -sL --max-time 300 -o x264.tar.bz2 \
      "https://code.videolan.org/videolan/x264/-/archive/$X264_REF/x264-$X264_REF.tar.bz2"
    tar xjf x264.tar.bz2
    mv "x264-$X264_REF" "$SRC/x264"
  fi
  if [ ! -d "$SRC/openssl-$OPENSSL_VER" ]; then
    echo "[fetch] openssl $OPENSSL_VER"
    curl -sL --max-time 600 -o openssl.tar.gz \
      "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz"
    tar xzf openssl.tar.gz
    mv "openssl-$OPENSSL_VER" "$SRC/openssl-$OPENSSL_VER"
  fi
  if [ ! -d "$SRC/ffmpeg-$FFMPEG_VER" ]; then
    echo "[fetch] ffmpeg $FFMPEG_VER"
    curl -sL --max-time 600 -o ffmpeg.tar.xz \
      "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz"
    tar xJf ffmpeg.tar.xz
    mv "ffmpeg-$FFMPEG_VER" "$SRC/ffmpeg-$FFMPEG_VER"
  fi
  echo "[fetch] done"
}

# ---- 单 ABI 构建 -------------------------------------------------------------
# $1 = abi 名（arm64-v8a / armeabi-v7a / x86_64）
build_abi() {
  local abi="$1"
  local triple arch cpu openssl_target x264_host extra_x264_flags
  case "$abi" in
    arm64-v8a)   triple=aarch64-linux-android;    arch=aarch64; cpu=armv8-a;  openssl_target=android-arm64
                 x264_host=aarch64-linux; extra_x264_flags=""
                 extra_asflags="--target=${triple}${API} --sysroot=$TOOLCHAIN/sysroot" ;;
    armeabi-v7a) triple=armv7a-linux-androideabi; arch=arm;     cpu=armv7-a;  openssl_target=android-arm
                 # v7a 的 x264 asm 需要 gas-preprocessor 链，风险高：禁 asm
                 x264_host=arm-linux; extra_x264_flags="--disable-asm"
                 extra_asflags="" ;;
    x86_64)      triple=x86_64-linux-android;     arch=x86_64;  cpu=x86-64;   openssl_target=android-x86_64
                 # x86_64 的 AS 是 nasm（非 clang），不能带 --target 类参数
                 x264_host=x86_64-linux; extra_x264_flags=""
                 extra_asflags="" ;;
    *) echo "unknown abi: $abi"; exit 1 ;;
  esac
  local CC="$TOOLCHAIN/bin/${triple}${API}-clang"
  local PREFIX="$PREFIXES/$abi"
  mkdir -p "$PREFIX"

  # --- x264（静态 .a；asm 由工具链默认，失败人工加 --disable-asm 重跑） ---
  if [ ! -f "$STAMPS/$abi.x264" ]; then
    echo "[x264/$abi] configure + make"
    (
      cd "$SRC/x264"
      make distclean >/dev/null 2>&1 || true
      # NDK 只有 llvm-ar/llvm-strip（无 triple-ar 包装器），工具走环境变量
      # 显式指定而不是 --cross-prefix。CC 用裸 clang.exe + 显式 target：
      # sh 包装器（#!/usr/bin/env bash）spawn 的子 bash 会丢 TMP 环境变量，
      # clang 就地「unable to make temporary file」（11-09 实测）。
      CC="$TOOLCHAIN/bin/clang.exe" \
      ASFLAGS="$extra_asflags" \
      AR="$TOOLCHAIN/bin/llvm-ar" \
      STRIP="$TOOLCHAIN/bin/llvm-strip" \
      RANLIB="$TOOLCHAIN/bin/llvm-ranlib" \
      ./configure \
        --host="$x264_host" \
        --sysroot="$TOOLCHAIN/sysroot" \
        --enable-static --enable-pic --disable-cli \
        --prefix="$PREFIX" \
        $extra_x264_flags \
        --extra-cflags="--target=${triple}${API} -Os" \
        --extra-ldflags="--target=${triple}${API}" \
        > "$LOGS/$abi.x264.configure.log" 2>&1
      make -j"$(nproc)" > "$LOGS/$abi.x264.make.log" 2>&1
      make install > "$LOGS/$abi.x264.install.log" 2>&1
    )
    touch "$STAMPS/$abi.x264"
    echo "[x264/$abi] OK"
  fi

  # --- openssl（静态 .a；no-tests 省时） ---
  if [ ! -f "$STAMPS/$abi.openssl" ]; then
    echo "[openssl/$abi] Configure + make"
    (
      cd "$SRC/openssl-$OPENSSL_VER"
      make distclean >/dev/null 2>&1 || true
      PATH="$TOOLCHAIN/bin:$PATH" \
      ANDROID_NDK_ROOT="$NDK" \
      ./Configure "$openssl_target" \
        -D__ANDROID_API__=$API no-shared no-tests \
        --prefix="$PREFIX" \
        > "$LOGS/$abi.openssl.configure.log" 2>&1
      PATH="$TOOLCHAIN/bin:$PATH" \
      make -j"$(nproc)" > "$LOGS/$abi.openssl.make.log" 2>&1
      make install_sw > "$LOGS/$abi.openssl.install.log" 2>&1
    )
    touch "$STAMPS/$abi.openssl"
    echo "[openssl/$abi] OK"
  fi

  # --- ffmpeg（全静态 PIE CLI；openssl+libx264 经 pkg-config 探测） ---
  if [ ! -f "$STAMPS/$abi.ffmpeg" ]; then
    echo "[ffmpeg/$abi] configure + make"
    (
      cd "$SRC/ffmpeg-$FFMPEG_VER"
      make distclean >/dev/null 2>&1 || true
      PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
      ./configure \
        --target-os=android --enable-cross-compile \
        --arch="$arch" --cpu="$cpu" \
        --cc="$TOOLCHAIN/bin/clang.exe" \
        --host-cc="$(which gcc)" \
        --ar="$TOOLCHAIN/bin/llvm-ar" --nm="$TOOLCHAIN/bin/llvm-nm" \
        --ranlib="$TOOLCHAIN/bin/llvm-ranlib" --strip="$TOOLCHAIN/bin/llvm-strip" \
        --pkg-config="$(which pkg-config)" \
        --sysroot="$TOOLCHAIN/sysroot" \
        --prefix="$PREFIX" \
        --enable-gpl --enable-version3 \
        --enable-libx264 --enable-openssl \
        --enable-pthreads --enable-static --disable-shared \
        --enable-ffmpeg --disable-ffprobe --disable-ffplay \
        --disable-doc --disable-debug --disable-autodetect \
        --disable-avdevice \
        --extra-cflags="--target=${triple}${API} -Os -fPIE -I$PREFIX/include" \
        --extra-ldflags="--target=${triple}${API} -L$PREFIX/lib -pie -s" \
        > "$LOGS/$abi.ffmpeg.configure.log" 2>&1
      make -j"$(nproc)" > "$LOGS/$abi.ffmpeg.make.log" 2>&1
      cp -f ffmpeg "$PREFIX/ffmpeg"
    )
    touch "$STAMPS/$abi.ffmpeg"
    echo "[ffmpeg/$abi] OK"
  fi

  # --- 产物落位（ stripping 后拷入仓库通道） ---
  local stripped="$WORK/stripped"
  mkdir -p "$stripped"
  "$TOOLCHAIN/bin/llvm-strip" -o "$stripped/libffmpeg-$abi.so" "$PREFIX/ffmpeg"
  cp -f "$stripped/libffmpeg-$abi.so" "$OUT/libffmpeg-$abi.so"
  echo "[out/$abi] $(ls -la "$OUT/libffmpeg-$abi.so" | awk '{print $5}') bytes"
}

# ---- main --------------------------------------------------------------------
fetch_sources

ABIS=("${@:-arm64-v8a armeabi-v7a x86_64}")
if [ $# -gt 0 ]; then ABIS=("$@"); fi
for abi in "${ABIS[@]}"; do
  build_abi "$abi"
done

echo "=== SHA256（登记 android/ffmpeg/README.md 用） ==="
sha256sum "$OUT"/libffmpeg-arm64-v8a.so "$OUT"/libffmpeg-armeabi-v7a.so "$OUT"/libffmpeg-x86_64.so 2>/dev/null || true
echo "ALL_DONE"
