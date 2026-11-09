# Android 内置 ffmpeg（投屏解密中继）

投屏加密切片时，`native/bridge/core/castrelay.go` 需要在本机启动 ffmpeg 解密并转 HLS。
桌面端从 exe 同目录或 PATH 找 ffmpeg；Android 没有可执行文件，因此把预编译二进制
以 `libffmpeg.so` 的形式放进 `jniLibs`，由系统解压到 `nativeLibraryDir` 后直接执行。

## 仓库内位置

本目录只放三个二进制，**纳入版本控制**：

```
android/ffmpeg/libffmpeg-arm64-v8a.so     # 28,154,936 B（ffmpeg 8.0.1，11-09 自建）
android/ffmpeg/libffmpeg-armeabi-v7a.so   # 24,311,480 B（ffmpeg 8.0.1，11-09 自建）
android/ffmpeg/libffmpeg-x86_64.so        # 34,372,944 B（ffmpeg 8.0.1，11-09 自建）
```

`android/app/src/main/jniLibs/` 整体被 `.gitignore` 排除（Go 产物每次重建），所以
`scripts/build_native.py --android` 会在编译完成后把这三个文件复制成
`jniLibs/<abi>/libffmpeg.so`。CI 与本地走同一个脚本，不需要额外步骤。

## 来源（11-09 升级：2018 构建 → 自建 ffmpeg 8.0.1）

自建脚本：`scripts/build_android_ffmpeg.sh`（MSYS2 bash + NDK r28 交叉编译）。
固定输入：

| 组件 | 版本/提交 | 说明 |
|---|---|---|
| ffmpeg | **8.0.1**（ffmpeg.org 官方源码） | `--enable-gpl --enable-version3 --enable-libx264 --enable-openssl`，全静态 PIE，API 24 |
| x264 | `0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee`（code.videolan.org master） | aarch64/x86_64 开 asm；armeabi-v7a 禁 asm（gas-preprocessor 链风险） |
| openssl | **3.5.4**（GitHub releases） | `no-shared no-tests`，静态链接 |

修复记录（构建脚本注释同步）：4.0.x 不认识 `-hls_flags independent_segments`
（4.3+ 参数，Eval 秒退）；8.0.1 满足版本门控（`ffmpegHasIndependentSegments`），
该 flag 自动生效。

### SHA256（自建产物）

| ABI | SHA256 | 大小 |
|---|---|---|
| arm64-v8a | `8AC53E1780F9A9EBE730D31872D9F56B72808D6CB2026D465F3D816F5CD353D4` | 28,154,936 B |
| armeabi-v7a | `280CE10D55B7C70AE042FC207C2F9BA8B2F90C45F4CEDF68991DD35C181561D7` | 24,311,480 B |
| x86_64 | `A002EB334C473AFF371ACCB9CC6A668C26E3E0746A174FD677C05E2E3CA20410` | 34,372,944 B |

历史（已退役）：2018-07-31 Khang-NT 构建（ffmpeg 4.0.2，见 git 历史与 v1.9.8 及之前
tag）——因缺 `independent_segments`/旧 TLS 被替换。

## 校验方式

```powershell
# ELF 头：e_type=3（PIE 可执行）、e_machine（183=AArch64 / 40=ARM / 62=x86-64）
python -c "import struct;d=open('libffmpeg.so','rb').read();print(d[0:4],struct.unpack_from('<H',d,16)[0],struct.unpack_from('<H',d,18)[0],b'independent_segments' in d)"
```

关键能力必须存在：`libx264`（重编码）、`hls`（输出封装）、`decryption_key`
（HLS AES-128 解密）、`independent_segments`（4.3+ hls flag）、`OpenSSL 3`（TLS）。

## 打包要求

1. 文件名必须是 `lib*.so`，AGP 才会把文件放进 `nativeLibraryDir`。
2. `AndroidManifest.xml` 需要 `android:extractNativeLibs="true"`。
3. `android/app/build.gradle.kts` 需要：

```kotlin
packaging {
    jniLibs {
        useLegacyPackaging = true
        keepDebugSymbols += "**/libffmpeg.so"
    }
}
```

`keepDebugSymbols` 是必须的：该文件是 PIE 可执行文件而不是共享库，AGP 的 `strip` 任务会把它改坏。

## 许可证

自建构建包含 **libx264**（GPL）且链接 **OpenSSL 3.x**（ffmpeg 要求
`--enable-version3` 才允许），因此整个二进制按 **GPLv3 或更高版本**分发
（历史 2018 构建为 GPLv2+）。它只随 Android 包分发；桌面端仍由用户自行提供 ffmpeg。

## 回退

若某 ROM 禁止从 `nativeLibraryDir` 执行（`EPERM`），中继会返回
`CAST_RELAY_UNAVAILABLE`；客户端不再阻断投屏面板，而是提示并自动切到「镜像屏幕」投屏
（MediaProjection → MediaCodec → MPEG-TS），该路径不依赖 ffmpeg。

版本回退：git 历史中的 2018 三文件可直接 checkout 回来（运行时版本门控对两种构建
都正确——旧内核自动摘除 `independent_segments`）。
