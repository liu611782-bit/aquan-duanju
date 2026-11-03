import json
import ssl
import urllib.request

UA = {"User-Agent": "Mozilla/5.0"}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

URLS = [
    "https://shuyuan.nyasama.cc/cdn/5f626361539d546e6fa3a02b24598284.json",
    "https://gh.ns114.cc/github.com/XIU2/Yuedu/raw/refs/heads/master/shuyuan",
    "https://shuyuan-api.yiove.com/import/book-source-collection/eaedccd4-1252-4962-a565-c7a342f95f90",
    "https://legado.miaogongzi.org/%E9%98%85%E8%AF%BB%E4%B9%A6%E6%BA%90/sy.json",
    "https://shuyuan.nyasama.cc/shuyuan/c5dccfb4fea13577819b10e0a3a810ea.json",
]

for url in URLS:
    try:
        raw = urllib.request.urlopen(
            urllib.request.Request(url, headers=UA), timeout=20, context=CTX
        ).read()
        data = json.loads(raw.decode("utf-8", "ignore"))
        n = len(data) if isinstance(data, list) else len(data.keys())
        first = data[0] if isinstance(data, list) and data else {}
        kind = "book" if isinstance(first, dict) and "bookSourceUrl" in first else "?"
        print(f"{n:5d} {kind:4s} {url[:70]}")
    except Exception as exc:  # noqa: BLE001
        print(f"  ERR {str(exc)[:36]:38s} {url[:70]}")
