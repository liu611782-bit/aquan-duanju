# 投屏第三方互操作冒烟 · 一键脚本（任务 11-08-cast-engineer-closeout R1）。
#
# 用途：
#   把 test/cast/interop_go_dlna_test.dart 头注释里的手动 5 步流程打包成一条
#   命令：检查/自动构建 go-dlna.exe → 定位 mpv / ffmpeg → 剥掉代理环境变量 →
#   设 AQUAN_INTEROP=1 与各路径 env → 跑第三方互操作冒烟（windows-dlna-receiver
#   go-dlna + mpv 真播放：发现 / 投送 / PLAYING / seek / stop 全链）→
#   汇总 PASS / FAIL 与退出码。维护者可随时复跑。
#
# 前置：
#   - Flutter SDK（默认 C:\flutter\bin\flutter.bat，可用 -Flutter 覆盖）；
#   - windows-dlna-receiver 仓库（-ReceiverRepo，默认 D:\IdeaProjects\windows-dlna-receiver）；
#     缺 go-dlna.exe 时自动在工作目录执行 `go build -o go-dlna.exe .`（需 PATH 有 go）；
#   - mpv.exe（默认 C:\Program Files\MPV Player\mpv.exe；缺则打印 winget 安装提示并退出）；
#   - ffmpeg.exe（默认 PATH / winget Links；缺则打印 winget 安装提示并退出）。
#
# 用法（Git Bash 或 PowerShell）：
#   powershell -ExecutionPolicy Bypass -File scripts/cast_interop_smoke.ps1
#   powershell -ExecutionPolicy Bypass -File scripts/cast_interop_smoke.ps1 `
#     -Godlna 'D:\elsewhere\go-dlna.exe' -Mpv 'D:\elsewhere\mpv.exe' `
#     -Ffmpeg 'D:\elsewhere\ffmpeg.exe' -ReceiverRepo 'D:\src\windows-dlna-receiver'
#
# 退出码：0 = 全部通过；1 = 仓库根/环境异常；2 = go-dlna 缺失且构建失败；
#         3 = mpv 缺失；4 = ffmpeg 缺失；其他值 = flutter test 原样退出码（失败）。

param(
  [string]$Godlna = '',
  [string]$Mpv = 'C:\Program Files\MPV Player\mpv.exe',
  [string]$Ffmpeg = '',
  [string]$ReceiverRepo = 'D:\IdeaProjects\windows-dlna-receiver',
  [string]$Flutter = 'C:\flutter\bin\flutter.bat'
)

$ErrorActionPreference = 'Stop'

# 输出编码：flutter / go 子进程的 UTF-8 输出按 UTF-8 解码回显，避免经管道乱码。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# 仓库根 = scripts 的上一级（脚本随仓库走，不依赖调用时的工作目录）。
$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $RepoRoot 'pubspec.yaml'))) {
  Write-Host "[smoke] FAIL：仓库根异常（$RepoRoot 下没有 pubspec.yaml）"
  exit 1
}

# ① go-dlna.exe：默认落在 receiver 仓库内；缺失时自动构建。
$godlnaDefault = Join-Path $ReceiverRepo 'go-dlna.exe'
if ($Godlna -eq '') { $Godlna = $godlnaDefault }
if (-not (Test-Path $Godlna)) {
  if (-not (Test-Path $ReceiverRepo)) {
    Write-Host "[smoke] FAIL：receiver 仓库不存在：$ReceiverRepo（-ReceiverRepo 可覆盖）"
    exit 2
  }
  if ($null -eq (Get-Command go -ErrorAction SilentlyContinue)) {
    Write-Host "[smoke] FAIL：缺 $Godlna 且 PATH 里没有 go，无法自动构建"
    exit 2
  }
  Write-Host "[smoke] go-dlna.exe 不存在，自动构建：go build -o go-dlna.exe .（工作目录 $ReceiverRepo）"
  Push-Location $ReceiverRepo
  try { go build -o go-dlna.exe . }
  finally { Pop-Location }
  if ($LASTEXITCODE -ne 0) {
    Write-Host '[smoke] FAIL：go build 失败'
    exit 2
  }
  if ($Godlna -ne $godlnaDefault) {
    Copy-Item $godlnaDefault $Godlna -Force
  }
}
if (-not (Test-Path $Godlna)) {
  Write-Host "[smoke] FAIL：构建后仍找不到 $Godlna"
  exit 2
}

# ② mpv：缺失即止（winget 提示）。
if (-not (Test-Path $Mpv)) {
  Write-Host "[smoke] FAIL：mpv 不存在：$Mpv"
  Write-Host '       安装：winget install --id shinchiro.mpv -e'
  Write-Host '       或到 https://mpv.io/installation 下载后用 -Mpv 传入路径'
  exit 3
}

# ③ ffmpeg：参数允许裸命令名（按 PATH 解析）；默认 PATH → winget Links。
$ffmpegResolved = ''
if ($Ffmpeg -ne '') {
  if (Test-Path $Ffmpeg) {
    $ffmpegResolved = $Ffmpeg
  } else {
    $cmd = Get-Command $Ffmpeg -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $ffmpegResolved = $cmd.Source }
  }
} else {
  $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
  if ($null -ne $cmd) { $ffmpegResolved = $cmd.Source }
  if ($ffmpegResolved -eq '') {
    $wingetFfmpeg = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'
    if (Test-Path $wingetFfmpeg) { $ffmpegResolved = $wingetFfmpeg }
  }
}
if ($ffmpegResolved -eq '') {
  Write-Host '[smoke] FAIL：ffmpeg 不存在（PATH 与 winget Links 均未找到）'
  Write-Host '       安装：winget install --id Gyan.FFmpeg -e'
  exit 4
}

# ④ 剥代理环境变量（Go/Dart HttpClient 会读这些变量；代理会吞掉 127.0.0.1
#    本地 HTTP 与 SSDP 组播路径——与 README「剥离代理」的回归跑法同口径）。
foreach ($name in 'http_proxy', 'https_proxy', 'all_proxy',
  'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY') {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

# ⑤ 互操作门控与路径 env（与 interop_go_dlna_test.dart 读取的键一致）。
$env:AQUAN_INTEROP = '1'
$env:AQUAN_INTEROP_GODLNA = $Godlna
$env:AQUAN_INTEROP_MPV = $Mpv
$env:AQUAN_INTEROP_FFMPEG = $ffmpegResolved

Write-Host '[smoke] ==== 互操作冒烟环境 ===='
Write-Host "[smoke] go-dlna : $Godlna"
Write-Host "[smoke] mpv     : $Mpv"
Write-Host "[smoke] ffmpeg  : $ffmpegResolved"
Write-Host '[smoke] AQUAN_INTEROP=1（代理环境变量已剥除）'
Write-Host ''

# ⑥ 跑门控测试（仓库根为工作目录），原样透传输出。
Push-Location $RepoRoot
try {
  & $Flutter test test/cast/interop_go_dlna_test.dart
  $testExit = $LASTEXITCODE
} finally {
  Pop-Location
}

Write-Host ''
if ($testExit -eq 0) {
  Write-Host '[smoke] PASS：第三方互操作冒烟全部通过（go-dlna + mpv 全链）'
} else {
  Write-Host "[smoke] FAIL：flutter test 退出码 $testExit"
}
exit $testExit
