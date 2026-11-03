import json
import ssl
import urllib.request

UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

URLS = [
    "https://shuyuan-api.yiove.com/shuyuan/book-sources?page=1&page_size=20",
    "https://shuyuan-api.yiove.com/shuyuan/book-source-collections?page=1&page_size=20",
    "https://shuyuan-api.yiove.com/shuyuan/book-sources?page=1&page_size=100",
    "https://shuyuan-api.yiove.com/shuyuan/rss-sources?page=1&page_size=20",
]

for url in URLS:
    try:
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
        resp = urllib.request.urlopen(req, timeout=20, context=CTX)
        raw = resp.read()
        text = raw.decode("utf-8", "ignore")
        note = ""
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                note = f"dict keys={list(data.keys())[:8]}"
                inner = data.get("data") or data.get("results") or data.get("list")
                if isinstance(inner, list) and inner:
                    note += f" inner={len(inner)} firstKeys={sorted(inner[0].keys())[:8] if isinstance(inner[0], dict) else type(inner[0]).__name__}"
            elif isinstance(data, list):
                note = f"list n={len(data)}"
        except Exception as exc:  # noqa: BLE001
            note = f"notJSON {exc} head={text[:80]!r}"
        print(f"{url}\n  {resp.status} len={len(raw)} {note}")
    except Exception as exc:  # noqa: BLE001
        print(f"{url}\n  ERR {exc}")
