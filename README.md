# 阿圈短剧

一个基于 [openhongguo](https://github.com/beilunyang/openhongguo)（红果短剧逆向接口 SDK，
Apache-2.0）的 Flutter 短剧播放器，支持 **Windows / Android / Linux / macOS**。

> **免责声明**
>
> 本项目仅供学习与研究，禁止用于商业用途。应用内数据来自开源项目 openhongguo
> 逆向的红果短剧公开接口，所有短剧内容的版权归原平台及权利方所有。
> 请勿将本项目用于任何侵犯他人合法权益的用途；使用本项目即表示您同意上述条款。
>
> **第三方影视源与直播配置均由用户自行导入**：应用不内置、不分发任何内容源地址，
> 预置的接口索引站仅是「清单页」入口且可删除。第三方源与直播内容来自用户导入的
> 第三方采集站，请自行确认授权与合法性，使用后果自负。B 站功能依赖用户本人账号
> 登录，请遵守 B 站用户协议。加密分集的解密中继仅处理用户已可播放的内容。

## 功能

| 模块 | 说明 |
|---|---|
| 发现 | 推荐流、频道切换（新剧/热剧/漫剧…）、双列瀑布、分页加载 |
| 随机看 | 全屏竖滑 feed，上下滑随机换剧（红果「随机看」的交互） |
| 榜单 | 短剧榜单多内容多榜切换、类型筛选、筛选页、上新日历 |
| 搜索 | 热搜榜、猜你想搜、输入联想、结果分页 |
| 详情 | 简介、演员、分集网格、季与合集、相关推荐、续播 |
| 播放 | 清晰度切换、倍速（0.5–3.0x）、手势、双击快进退、自动连播、CENC 加密分集透明解密 |
| 竖横屏 | 移动端按片源自动转屏；桌面端可让窗口自动适应片源比例 |
| 桌面操作 | 键盘快捷键（空格/←→/↑↓/F/M/I/PageUp/Down…）、双击全屏、窗口记忆、迷你置顶小窗、系统媒体控制（媒体键/音量浮层） |
| 本地 | 观看历史（秒级续播）、追剧收藏、深浅色主题、默认清晰度/倍速、备份恢复、重置匿名设备 |
| AI 代播 | 命令行入口 + `skills/duanju-search-play`，对 AI 说「看短剧 XX」即可搜剧并开播 |
| 影视聚合 | 发现页入口：导入 TVBox / MoonTV / 多仓 / 文本行源（六形态解码含 2423 AES 加密配置），源市场从索引站一键抓源+逐源测速（「连接成功 XXXms」）、聚合搜索（流式先到先显示）、源管理（自检/钉选/排序/导入导出）、短剧源自动标记 |
| B 站 | 扫码登录（免 appkey）、推荐/搜索（WBI 签名 + buvid/bili_ticket 风控）、视频/番剧 DASH 双轨播放、弹幕展示与发送、屏蔽词 |
| 直播 | TVBox lives（TXT/M3U/JSON）：分组换台、备用地址自动切换、逐频道测速、EPG 节目单（XMLTV/xml.gz） |
| 投屏 | **DLNA + Chromecast 双协议**（SSDP+mDNS 双发现，同设备自动换协议降级）；受保护流四级选路（直链/源站头代理/CENC 解密中继/本地文件）；**屏幕镜像**（MediaProjection→H264/AAC→MPEG-TS，含系统声音、编码器卡死自动降档恢复）；B 站 DASH 双轨合流投送；电视端播完自动连播下一集；GENA 事件推送替代高频轮询；静音/音量/字幕（sec:SubtitleUri + VTT）遥控；断开回本地续播 |
| 语音 | 搜索框语音输入：Android 系统识别；桌面 OpenAI 兼容端点（自备 key，设置里配置与自检） |
| 去广告 | CMS 源播放经本地回环代理重写 m3u8（关键字表剔广告分片），失败自动回退直链 |
| 扫码导入 | 源管理页生成一次性二维码，手机浏览器粘贴配置提交导入 |
| JS 爬虫源 | 影视聚合支持 .js 爬虫源双口味自动识别（CatVod 长名 / FongMi 短名同步 req），ES 模块加载器 + 打包 lib（cheerio/crypto-js/gbk），播放二次解析 |
| 漫画源 | 发现页（小说频道）漫画源入口：Venera 契约第三方漫画源（探索/搜索/详情/阅读/收藏/源设置/换源，账号登录持久化） |

架构：Flutter UI → Dart FFI → Go 核心（`native/bridge`，c-shared 动态库）→
openhongguo SDK（请求签名、匿名设备注册、播放地址与内容密钥）。
播放内核是 media_kit（libmpv），加密分集的 CENC 内容密钥通过
`demuxer-lavf-o` 的 `decryption_key` 交给 mpv 解密。

## 下载

在 [Releases](../../releases) 页面：

| 平台 | 产物 |
|---|---|
| Windows | `aquan-windows-x64-<版本>-setup.exe`（双击安装）、`aquan-windows-x64-<版本>.zip`（解压即用） |
| Android | `aquan-arm64-v8a.apk`（主流 64 位手机）、`aquan-armeabi-v7a.apk`、`aquan-x86_64.apk` |
| Linux | `aquan-linux-x64-<版本>.tar.gz`（解压运行，需系统装有 libmpv） |
| macOS | `aquan-macos-arm64-<版本>.zip`（未签名，首次右键 → 打开） |

Android 正式发布包使用 release 签名；未配置签名 Secrets 的构建回退 debug 签名，
安装时系统可能提示未知来源，允许即可。Windows / macOS 包未做开发者签名，
SmartScreen / Gatekeeper 提示时选择「仍要运行」/「打开」。

## 让 AI 替你搜、替你播

发布包内 `aquan-cli`（Windows 为 `aquan-cli.exe`）与主程序同目录：

```powershell
# 只查列表，不打开窗口；把输出原样给用户挑
aquan-cli search 持械入宋

# 用户选了第 2 个：拿那一行的 ID 直接开播（有历史就续播）
aquan-cli series 7697209269287914521

# 让程序自己挑最匹配的一部开播
aquan-cli watch 持械入宋

# 指挥正在播放的窗口
aquan-cli pause      # 暂停（resume / toggle / next / prev 同理）
aquan-cli status     # 持械入宋：第一季 · 第1集 00:10/02:15（播放中）
```

主程序本身也认这些参数（`aquan_duanju --search/--series/--watch/--pause/...`）。
窗口已经在跑时，命令会转交给已运行的窗口并置顶，不会重复开窗；
播放控制要求窗口在运行，没开会明确报错提示先开播。

把 [`skills/duanju-search-play`](skills/duanju-search-play/SKILL.md) 装进你的 AI 助手，
就可以直接说「搜索短剧 XX」「第 2 个」；也可以直接把下面这段丢给 AI：

> 读一下这个技能并按它操作：https://github.com/wjsqqj/aquan-duanju/blob/main/skills/duanju-search-play/SKILL.md
> 我要看短剧 持械入宋

## 从源码构建

要求：Flutter 3.47+、Go 1.22+；Windows 构建需 mingw-w64 gcc，Android 构建需 NDK，
Linux 构建需 GTK3 / libmpv 开发包。

```sh
# Windows（zip + 可选 Inno 安装包）
python scripts/build_windows.py --version 0.4.0 --zip

# Android
python scripts/build_android.py --ndk <NDK 路径> --version 0.4.0

# Linux
python3 scripts/build_linux.py --version 0.4.0

# macOS
python3 scripts/build_macos.py --version 0.4.0
```

也可以只构建原生库后用 `flutter build`：

```sh
python scripts/build_native.py --windows --version 0.4.0   # 或 --android/--linux/--macos
flutter build windows --release
flutter build apk --release --split-per-abi
```

构建后需要把原生库放进产物（Windows `aquan_core.dll`、Linux `lib/libaquan_core.so`、
macOS `Contents/MacOS/libaquan_core.dylib`、Android `jniLibs/<abi>/libaquan_core.so`），
上面的脚本已自动处理。

## 发布流程

1. 修改 `pubspec.yaml` 的 `version: X.Y.Z+N`，在 `CHANGELOG.md` 加 `## X.Y.Z (日期)` 小节。
2. 提交后打 tag：`git tag vX.Y.Z && git push origin vX.Y.Z`。
3. GitHub Actions 会校验 tag 与 `pubspec` 一致，然后并行构建
   Windows / Android / Linux / macOS，并自动创建 Release（release notes 取自 CHANGELOG）。
   macOS 构建失败不会阻塞其它平台发版。

## Android 签名

按优先级：

1. `android/key.properties`（本机，不入库）；
2. 环境变量（CI Secrets）：`ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、
   `ANDROID_KEYSTORE_ALIAS`、`ANDROID_KEYSTORE_KEY_PASSWORD`；
3. 都没有时回退 debug 签名。

## 开发

```sh
flutter pub get
flutter analyze --fatal-infos
flutter test
cd native/bridge && go vet ./... && go test ./...
dart run tool/smoke.dart <构建产物目录>     # 全链路冒烟（真实接口）
```

## 致谢

- [openhongguo](https://github.com/beilunyang/openhongguo) — 红果短剧逆向接口的 Go SDK，
  本项目的数据核心；Apache-2.0。
- [media_kit](https://github.com/media-kit/media-kit) — libmpv 的 Flutter 绑定。
- Windows media_kit 崩溃补丁与播放链路参考了社区先行探索（`packages/` 内带补丁说明）。

## LICENSE

Apache License 2.0（见 [LICENSE](LICENSE)）。`native/bridge/vendor/` 内是 openhongguo
的 Apache-2.0 源码副本，版权归属其原作者。