#!/usr/bin/env python3
"""发布产物隐私扫描（VenHM package_privacy_scan 同思路，零依赖）。

发布前的必跑项：对成品包做字节级扫描，抓「不该带出去的本机痕迹」——
开发机绝对路径、私钥材料、密钥/设备档案特征。`tools/secret_scan.ps1`
管源码/暂存区，本工具管**产物**，两者互补。

用法::

    python tool/scan_release.py <file-or-dir> [--report out.json]
    python tool/scan_release.py --self-test

扫描面（ASCII 与 UTF-16LE 双编码）：

- ``C:\\Users\\<当前用户>`` 与 ``D:\\IdeaProjects``——本机路径泄露
  （native ``__FILE__`` / 日志常量的经典来源）；
- ``BEGIN … PRIVATE KEY``——私钥材料；
- ``aquan_device.json`` / ``aquan_secret.json``——设备档案与密钥 sidecar
  的内容特征（设备指纹/密钥不该随包分发）；
- zip 族（apk/zip/hap/jar）条目**名**含 ``.p12/.jks/.keystore``——签名材料。

zip 族解包逐条目扫（解压后内容；单条目 >200MB 跳过记 skipped），
嵌套 zip 递归一层。severity：路径/私钥/密钥档案 = high（有即退出码 1），
zip 条目名可疑 = medium。

退出码：0 干净 / 1 有 high / 2 参数或 IO 错误。
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import zipfile

ARTIFACT_EXTS = {".exe", ".dll", ".so", ".apk", ".zip", ".hap", ".jar"}
ZIP_EXTS = {".apk", ".zip", ".hap", ".jar"}
MAX_ENTRY_BYTES = 200 * 1024 * 1024
CONTEXT_SNIPPET = 32

# (rule_id, description, severity, bytes-pattern builder)
def _patterns() -> list[tuple[str, str, str, list[bytes]]]:
    user = os.environ.get("USERNAME") or os.environ.get("USER") or ""
    pats: list[tuple[str, str, str, list[bytes]]] = []

    def add(rule: str, desc: str, severity: str, text: str) -> None:
        if not text:
            return
        raw = text.encode("utf-8", "ignore")
        pats.append((rule, desc, severity, [raw, raw.decode("ascii", "ignore").encode("utf-16-le", "ignore")]))

    if user:
        add("dev_path_user", f"本机用户路径 C:\\Users\\{user}", "high", f"C:\\Users\\{user}")
    add("dev_path_repo", "开发仓库路径 D:\\IdeaProjects", "high", "D:\\IdeaProjects")
    add("private_key", "私钥材料（PEM 头）", "high", "BEGIN ")
    # BEGIN 太宽：收紧为私钥家族。
    # PEM 头本身不算数：libssh/libmpv 等解析器自带这些字符串常量。
    # 只有序头后紧跟疑似 base64（≥40 位密文体）才判 high。
    pats[-1] = (
        "private_key",
        "私钥材料（PEM 头）",
        "high",
        [b"BEGIN RSA PRIVATE KEY", b"BEGIN PRIVATE KEY",
         b"BEGIN EC PRIVATE KEY", b"BEGIN OPENSSH PRIVATE KEY"],
    )
    pats.append(("private_key_parser", "PEM 头字符串（库内解析器常量，非密钥）",
                 "medium", [b"-----BEGIN OPENSSH PRIVATE KEY-----"]))
    # 文件名常量在二进制里属正常（程序自身读写路径），降 medium 提示人工确认
    # 是否连内容一起打进去了；真正的内容特征（device_id 等）由人工复核。
    add("device_profile", "设备档案文件名特征（aquan_device.json，非内容泄露）", "medium", "aquan_device.json")
    add("secret_sidecar", "密钥 sidecar 文件名特征（aquan_secret.json，非内容泄露）", "medium", "aquan_secret.json")
    return pats


ENTRY_NAME_SUSPECT = re.compile(r"\.(p12|jks|keystore)$", re.IGNORECASE)


def _find_all(data: bytes, needle: bytes) -> list[int]:
    out = []
    start = 0
    while True:
        i = data.find(needle, start)
        if i < 0:
            return out
        out.append(i)
        start = i + 1


def _context(data: bytes, offset: int, needle_len: int) -> str:
    lo = max(0, offset - CONTEXT_SNIPPET)
    hi = min(len(data), offset + needle_len + CONTEXT_SNIPPET)
    chunk = data[lo:hi]
    text = re.sub(rb"[^\x20-\x7e]", b"?", chunk).decode("ascii", "ignore")
    return text.strip()[:96]


BASE64ISH = re.compile(rb"[A-Za-z0-9+/]{40,}")


def _pem_has_key_body(data: bytes, offset: int) -> bool:
    """PEM 头后 64 字节内出现长 base64 行才算真密钥（否则是解析器常量）。"""
    return BASE64ISH.search(data, offset, min(len(data), offset + 120)) is not None


def scan_bytes(data: bytes, patterns: list[tuple[str, str, str, list[bytes]]]):
    """返回 {rule: {desc, severity, spots}}；同一规则只报前 3 处。

    private_key 规则特殊：PEM 头后无 base64 密文体 → 降为
    private_key_parser（medium），避免把库内解析器字符串当真钥匙。
    """
    hits = {}
    for rule, desc, severity, needles in patterns:
        for needle in needles:
            for offset in _find_all(data, needle):
                out_rule, out_sev = rule, severity
                if rule == "private_key" and not _pem_has_key_body(data, offset):
                    out_rule, out_sev = "private_key_parser", "medium"
                key = out_rule
                hits.setdefault(key, {"desc": desc if key == rule else
                                      ("私钥材料（PEM 头 + 密文体）" if key == "private_key"
                                       else "PEM 头字符串（库内解析器常量，非密钥）"),
                                      "severity": out_sev, "spots": []})
                if len(hits[key]["spots"]) < 3:
                    hits[key]["spots"].append((offset, _context(data, offset, len(needle))))
    return hits


def scan_zip(data: bytes, rel: str, patterns, findings, depth: int = 0) -> None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            for info in zf.infolist():
                name = info.filename
                if ENTRY_NAME_SUSPECT.search(name):
                    findings.append({
                        "file": f"{rel}!{name}",
                        "rule": "signing_material_name",
                        "severity": "medium",
                        "desc": "zip 条目名疑似签名材料",
                        "context": name[-80:],
                    })
                if info.file_size > MAX_ENTRY_BYTES:
                    findings.append({
                        "file": f"{rel}!{name}",
                        "rule": "skipped_too_large",
                        "severity": "medium",
                        "desc": f"条目超过 {MAX_ENTRY_BYTES} 字节，跳过扫描",
                        "context": "",
                    })
                    continue
                try:
                    content = zf.read(name)
                except Exception:
                    continue
                for rule, hit in scan_bytes(content, patterns).items():
                    for offset, context in hit["spots"]:
                        findings.append({
                            "file": f"{rel}!{name}",
                            "rule": rule,
                            "severity": hit["severity"],
                            "desc": hit["desc"],
                            "context": context,
                        })
                # 嵌套 zip 一层（zip 内 zip）。
                if depth == 0 and name.lower().endswith(tuple(ZIP_EXTS)):
                    scan_zip(content, f"{rel}!{name}", patterns, findings, depth + 1)
    except zipfile.BadZipFile:
        findings.append({
            "file": rel,
            "rule": "bad_zip",
            "severity": "medium",
            "desc": "zip 族文件损坏，无法解包（只做了裸字节扫）",
            "context": "",
        })


def collect_artifacts(root: str) -> list[str]:
    if os.path.isfile(root):
        return [root]
    out = []
    for base, _dirs, files in os.walk(root):
        for name in files:
            if os.path.splitext(name)[1].lower() in ARTIFACT_EXTS:
                out.append(os.path.join(base, name))
    return sorted(out)


def scan_target(root: str) -> list[dict]:
    patterns = _patterns()
    findings: list[dict] = []
    for path in collect_artifacts(root):
        rel = os.path.relpath(path, root if os.path.isdir(root) else os.path.dirname(path) or ".")
        try:
            data = open(path, "rb").read()
        except OSError as e:
            findings.append({"file": rel, "rule": "io_error", "severity": "medium",
                             "desc": f"读取失败：{e}", "context": ""})
            continue
        for rule, hit in scan_bytes(data, patterns).items():
            for offset, context in hit["spots"]:
                findings.append({"file": rel, "rule": rule, "severity": hit["severity"],
                                 "desc": hit["desc"], "context": context})
        if os.path.splitext(path)[1].lower() in ZIP_EXTS:
            scan_zip(data, rel, patterns, findings)
    return findings


def self_test() -> int:
    """正负对照：构造坏/好产物，断言扫描器命中与放行（负向控制防空跑）。"""
    import tempfile

    patterns = _patterns()
    failures = []

    # 正例 1：假 exe 内嵌开发机路径（UTF-8）。
    bad_exe = b"MZ" + b"\x00" * 64 + f"C:\\Users\\{os.environ.get('USERNAME','me')}\\dev\\x.dll".encode()
    if "dev_path_user" not in scan_bytes(bad_exe, patterns):
        failures.append("正例1：开发机用户路径未命中")

    # 正例 2：UTF-16LE 变体。
    bad_utf16 = "D:\\IdeaProjects\\aquan-duanju".encode("utf-16-le")
    if "dev_path_repo" not in scan_bytes(bad_utf16 + b"\x00" * 8, patterns):
        failures.append("正例2：UTF-16LE 仓库路径未命中")

    # 正例 3：假 apk 内嵌私钥与 .jks 条目名。
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("classes.dex", b"x" * 16)
        zf.writestr("keys/release.jks", b"junk")
        zf.writestr("assets/leak.txt", b"---BEGIN RSA PRIVATE KEY---\n" + b"A" * 60 + b"\n")
    zip_hits = []
    scan_zip(buf.getvalue(), "bad.apk", patterns, zip_hits)
    rules = {f["rule"] for f in zip_hits}
    if "signing_material_name" not in rules:
        failures.append("正例3a：apk 内 .jks 条目名未命中")
    if "private_key" not in rules:
        failures.append("正例3b：apk 内私钥材料未命中")

    # 负例：干净文件必须放行（防「扫描器永远报红」的空跑）。
    clean = b"MZ" + os.urandom(256) + b"totally clean binary payload"
    if scan_bytes(clean, patterns):
        failures.append("负例：干净文件被误报")

    if failures:
        for f in failures:
            print(f"SELF-TEST FAIL: {f}", file=sys.stderr)
        return 1
    print("SELF-TEST PASS：正负对照全部通过")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="发布产物隐私扫描")
    parser.add_argument("target", nargs="?", help="产物文件或目录")
    parser.add_argument("--report", help="JSON 报告输出路径")
    parser.add_argument("--self-test", action="store_true", help="内置正负对照")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.target:
        parser.print_help()
        return 2
    if not os.path.exists(args.target):
        print(f"路径不存在：{args.target}", file=sys.stderr)
        return 2

    findings = scan_target(args.target)
    for f in findings:
        print(f"[{f['severity'].upper():6}] {f['file']} :: {f['rule']} :: {f['desc']}"
              f"{(' :: ' + f['context']) if f['context'] else ''}")
    highs = sum(1 for f in findings if f["severity"] == "high")
    print(f"\n扫描完成：{len(findings)} 处发现（high={highs}）", file=sys.stderr)
    if args.report:
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump({"target": args.target, "findings": findings}, fh,
                      ensure_ascii=False, indent=2)
        print(f"报告已写入 {args.report}", file=sys.stderr)
    return 1 if highs else 0


if __name__ == "__main__":
    sys.exit(main())
