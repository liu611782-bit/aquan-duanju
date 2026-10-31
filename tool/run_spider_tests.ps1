# Run the QuickJS spider integration tests.
#
# `flutter test` runs on the plain Dart VM (flutter_tester.exe), which cannot
# load the Flutter plugin's native library. These spider tests are therefore
# integration tests: they need the real native engines plus a real HTTP
# fixture, so they are skipped by default and enabled by this script.
#
# Engines:
#   - quickjs_c_bridge.dll  (flutter_js) — js_engine_probe_test.dart 基线探针
#   - flutter_qjs.dll       (flutter_qjs fork) — spider_synthetic_test.dart 运行时
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tool/run_spider_tests.ps1
param(
  [string]$Flutter = 'flutter',
  [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root

try {
  if (-not $SkipBuild) {
    Write-Host '==> Building Windows debug (produces quickjs_c_bridge.dll + flutter_qjs.dll)' -ForegroundColor Cyan
    & $Flutter build windows --debug
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
  }

  $buildDir = Join-Path $root 'build\windows\x64\runner\Debug'
  $qjsBridge = Join-Path $buildDir 'quickjs_c_bridge.dll'
  $fqjs = Join-Path $buildDir 'flutter_qjs.dll'
  if (-not (Test-Path $qjsBridge) -or -not (Test-Path $fqjs)) {
    throw "Missing native libs in $buildDir (need quickjs_c_bridge.dll + flutter_qjs.dll) - rerun without -SkipBuild."
  }

  # LoadLibrary resolves by module name; putting the artifact dir on PATH lets
  # the engines' DynamicLibrary.open('<name>') find them.
  $env:PATH = "$buildDir;$env:PATH"
  Write-Host "==> PATH now includes $buildDir" -ForegroundColor Cyan

  # Opt in to the spider integration tests (skipped by default).
  $env:AQUAN_SPIDER_TESTS = '1'

  Write-Host '==> Running test/spider' -ForegroundColor Cyan
  & $Flutter test test/spider
  if ($LASTEXITCODE -ne 0) { throw 'spider tests failed' }
}
finally {
  Pop-Location
}
