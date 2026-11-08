---
name: duanju-search-play
description: 在本地「阿圈短剧」客户端里搜索剧名并按 1、2、3 序号列出结果，再按用户回复的序号或剧名唤起客户端播放（有观看历史就从上次那一集那一秒续播）；也能指挥正在播放的窗口（暂停/继续/上下集/查询进度）。当用户说「搜索短剧XX」「我要看短剧XX」「第2个」「就3」「暂停」「下一集」「现在放的什么」这类只给剧名、序号或播放控制的请求，或要求用 Agent 驱动阿圈短剧时使用。
---

# 阿圈短剧：搜索、开播与播放控制

程序提供两组入口，Agent 不需要操作界面：

**搜剧与开播：**

- `aquan-cli search <关键词> [--filter short|comic|ai]`：只查一次列表，打到 stdout 就退出，**不打开窗口**；`--filter` 按内容筛选（真人剧/漫剧/AI 剧）
- `aquan-cli series <ID> [--episode N]`：唤起窗口，直接进这一部的详情页并开播（有历史就续播；指定 `--episode` 从第 N 集开播）
- `aquan-cli watch <关键词>`：唤起窗口，程序自己搜、自己挑最匹配的一条开播

**指挥正在播放的窗口：**

- `aquan-cli pause` / `resume` / `toggle`：暂停 / 继续 / 播放暂停切换
- `aquan-cli next` / `prev`：下一集 / 上一集
- `aquan-cli seek <秒 | mm:ss | +30 | -15>`：跳转进度（带 +/- 相对当前）
- `aquan-cli volume <0-100 | up | down>`：设置音量
- `aquan-cli speed <倍速>`：调倍速（0.5-3.0，按剧记忆）
- `aquan-cli cast`：把**上次投屏的剧**恢复投到上次设备（跨天自动重新解析新鲜地址）
- `aquan-cli cast <关键词或剧集ID> [--episode N]`：把指定剧集投到上次设备——
  关键词会自动搜索挑最匹配的；加密剧集自动走电脑本机转码
- `aquan-cli cast stop`：断开投屏
- 投屏前提：电视/接收端与本机同一局域网，且至少成功投屏过一次（设备与配方
  会被记住）；接收端本机也可当投屏目标（应用设置里开启「允许其他设备投到本机」）
- `aquan-cli open`：把主窗口唤起到前台
- `aquan-cli status`：当前在播什么、播到哪一集哪一秒

`aquan-cli` 与 `aquan_duanju`（Windows 是 `aquan-cli.exe` / `aquan_duanju.exe`）
在同一个目录，随发布包一起分发。

## 工作流

1. 解析程序路径（见下）
2. 搜索：`aquan-cli search 持械入宋`
3. 把输出原样列给用户（序号 + 剧名，别改顺序、别吞掉 ID），等用户选
4. 用户回序号 → 取那一行的 ID：`aquan-cli series 7671966197985856536`
5. 用户一上来就给了剧名、没要列表 → 跳过第 2 步直接 `aquan-cli watch 剧名`
6. 播放后用户说「暂停」「下一集」「放到哪了」「快进到5分钟」「声音小点」「3倍速」→
   直接 `pause` / `next` / `status` / `seek 5:00` / `volume down` / `speed 3`
   把一句话结果转述给用户即可
7. 用户说「看第 N 集」→ 取这部剧的 ID：`series <ID> --episode N`

路径按优先级找：

```powershell
$CLI = @($env:AQUAN_CLI,
  "$env:LOCALAPPDATA\aquan-duanju\aquan-cli.exe",
  "$PWD\aquan-cli.exe") |
  Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
```

macOS / Linux 把 `aquan-cli.exe` 换成 `aquan-cli`，放在解压目录或
`.app/Contents/MacOS/` 里。Windows 安装版默认安装在
`%LOCALAPPDATA%\aquan-duanju`（安装器默认目录）。

## 输出形状

搜索（`search`）：

```
持械入宋 · 10 条结果，显示前 10 条
 1  持械入宋：第一季  ID 7671966197985856536  100集
 2  持械入宋：第十季  ID 7697209269287914521  100集
```

序号只在这次列表里有效，所以下一条指令必须带 ID 而不是序号。列表默认 10 条，
`--limit 3` 收窄；要机读就加 `--json`。

播放控制（`pause`/`next` 等）回一句话；`status` 回：

```
持械入宋：第一季 · 第1集 00:10/02:15（播放中）
```

控制命令加 `--json` 输出结构化回包（含 series/episode/position/duration/playing）。

## 坑

- **节目已经开着不用管**：`series` / `watch` 会由单实例转交给在跑的那个实例
  （窗口置顶并开播），不要先杀进程。
- **播放控制要求窗口在跑**：`pause` 这类命令在窗口没开时返回
  「阿圈短剧没在运行；先用 watch 或 series 打开一部剧」——按提示先开播再控制，
  不要换别的剧。
- **乱码**：PowerShell 先执行 `[Console]::OutputEncoding = [Text.Encoding]::UTF8`
  再取输出；cmd 用 `chcp 65001`。
- **退出码非 0**：`搜索失败：…` 属上游瞬时错误，重试一次；仍失败就如实告诉用户
  来源在抽风，不要换成别的剧。
- **零匹配仍返回列表**：关键词对不上时站点会给推荐位（标题跟关键词无关），
  这种列表要在回话里点明「没搜到精确匹配的《XX》」。
- **播放失败时**程序自己停在详情页或搜索页，不会乱点，Agent 不需要兜底重试。
- 本软件仅供学习与研究使用，不收费。
