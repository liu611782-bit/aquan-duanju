#!/usr/bin/env python3
"""Apply narrowly-scoped repairs for malformed Dart fragments before Android builds.

The repairs are idempotent and fail if the expected source shape changes, so CI
won't silently rewrite unrelated code.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def replace_optional(path: str, old: str, new: str) -> None:
    file_path = ROOT / path
    content = file_path.read_text(encoding="utf-8")
    count = content.count(old)
    if count > 1:
        raise RuntimeError(f"Expected at most one repair target in {path}, found {count}")
    if count == 1:
        file_path.write_text(content.replace(old, new, 1), encoding="utf-8")
        print(f"Repaired {path}")


# This UI helper was left as an orphaned fragment outside any widget/class.
replace_optional(
    "lib/screens/book_audio_screen.dart",
    "import '../core/tts/voice_icons.dart';\n",
    "",
)
replace_optional(
    "lib/screens/book_audio_screen.dart",
    "avatar: voiceChipAvatar(\n"
    "  id: tone.id,\n"
    "  title: tone.title,\n"
    "  iconUrl: tone.icon,\n"
    "),\n",
    "",
)

# This IconButton was also orphaned in the State class body. Keep the download
# handler intact; only remove the invalid, unparented widget expression.
replace_optional(
    "lib/screens/player_screen.dart",
    "  IconButton(\n"
    "                    tooltip: '下载(MP4)',\n"
    "                    icon: _mp4Downloading\n"
    "                        ? const SizedBox(\n"
    "                            width: 22,\n"
    "                            height: 22,\n"
    "                            child: CircularProgressIndicator(\n"
    "                              strokeWidth: 2,\n"
    "                              color: Colors.white,\n"
    "                            ),\n"
    "                          )\n"
    "                        : const Icon(Icons.download_outlined),\n"
    "                    color: Colors.white,\n"
    "                    onPressed: _mp4Downloading ? null : _downloadCurrentMp4,\n"
    "                  ),\n",
    "",
)

# MineScreen uses this screen in a const route but was missing its import.
replace_optional(
    "lib/screens/mine_screen.dart",
    "import 'downloads_screen.dart';\n",
    "import 'downloads_screen.dart';\nimport 'mp4_downloads_screen.dart';\n",
)
