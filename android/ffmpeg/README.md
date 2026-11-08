# Android 内置 ffmpeg（投屏解密中继）

投屏加密切片时，`native/bridge/core/castrelay.go` 需要在本机启动 ffmpeg 解密并转 HLS。
桌面端从 exe 同目录或 PATH 找 ffmpeg；Android 没有可执行文件，因此把预编译二进制
以 `libffmpeg.so` 的形式放进 `jniLibs`，由系统解压到 `nativeLibraryDir` 后直接执行。

## 仓库内位置

本目录只放三个二进制，**纳入版本控制**：

```
android/ffmpeg/libffmpeg-arm64-v8a.so     # 17,779,024 B
android/ffmpeg/libffmpeg-armeabi-v7a.so   # 16,484,516 B
android/ffmpeg/libffmpeg-x86_64.so        # 21,619,808 B（11-08 补齐：模拟器/平板不再缺二进制）
```

`android/app/src/main/jniLibs/` 整体被 `.gitignore` 排除（Go 产物每次重建），所以
`scripts/build_native.py --android` 会在编译完成后把这三个文件复制成
`jniLibs/<abi>/libffmpeg.so`。CI 与本地走同一个脚本，不需要额外步骤。

## 来源

| ABI | 下载地址 | SHA256 | 大小 |
|---|---|---|---|
| arm64-v8a | `https://github.com/Khang-NT/ffmpeg-binary-android/releases/download/2018-07-31/arm64-v8a-full.tar.bz2` | `86FD9F45FC8594C61D0AF64F82CAF90D1CD30A6E5D6B23F3A7FB55A1B936B206` | 17,779,024 B |
| armeabi-v7a | `https://github.com/Khang-NT/ffmpeg-binary-android/releases/download/2018-07-31/armv7-a-full.tar.bz2` | `30EF724DDF72C1FD15F2192F462B0FD204CCCF1345E95F974711515FE65B251A` | 16,484,516 B |
| x86_64 | `https://github.com/Khang-NT/ffmpeg-binary-android/releases/download/2018-07-31/x86_64-full.tar.bz2` | `11515B46C98B0476B24C72B6ED43674C5A68CF0B279F9834AA5BDC73045A675B` | 21,619,808 B |

上游仓库：<https://github.com/Khang-NT/ffmpeg-binary-android>

## 校验方式

```powershell
# ELF 头：e_type=3（PIE 可执行）、e_machine（183=AArch64 / 40=ARM）
python -c "import struct;d=open('libffmpeg.so','rb').read();print(d[0:4],struct.unpack_from('<H',d,16)[0],struct.unpack_from('<H',d,18)[0],b'libx264' in d)"
```

关键能力必须存在：`libx264`（重编码）、`hls`（输出封装）、`decryption_key`（HLS AES-128 解密）。

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

上游 `full` 构建包含 **libx264**，因此整个二进制按 **GPLv2 或更高版本**分发。
它只随 Android 包分发；桌面端仍由用户自行提供 ffmpeg。

如果将来需要更宽松的分发许可，改用不含 libx264 的 `lite` 构建，并把
`castrelay.go` 的 `-c:v libx264` 改为 `-c copy`（体积更小，但老电视兼容性下降）。

## 回退

若某 ROM 禁止从 `nativeLibraryDir` 执行（`EPERM`），中继会返回
`CAST_RELAY_UNAVAILABLE`；客户端不再阻断投屏面板，而是提示并自动切到「镜像屏幕」投屏
（MediaProjection → MediaCodec → MPEG-TS），该路径不依赖 ffmpeg。
