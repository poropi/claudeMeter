#!/usr/bin/env python3
"""collector/claudemeter_collector.py を ~/.claude/statusline.py へ差し込む。

マーカーで囲んで挿入するので、収集ロジックを更新したら再実行するだけで入れ替わる。
アンインストールは --uninstall。
"""
import os
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "collector", "claudemeter_collector.py")
TARGET = os.path.expanduser("~/.claude/statusline.py")
BACKUP = TARGET + ".bak.claudemeter"

BEGIN = "# >>> claudemeter collector >>>"
END = "# <<< claudemeter collector <<<"
ANCHOR = "    write_state(data, ctx)\n"
CALL = """    try:
        record_rate_limits(data)
    except Exception:
        pass
"""


def payload():
    with open(SOURCE) as f:
        text = f.read()
    # モジュール docstring は落とす（statusline.py 側に既に docstring があるため）
    if text.startswith('"""'):
        text = text[text.index('"""', 3) + 3:].lstrip("\n")
    # import は statusline.py 側に既にある json / os / time のみ
    lines = [l for l in text.splitlines(True) if l.strip() not in ("import json", "import os", "import time")]
    return BEGIN + "\n" + "".join(lines).strip("\n") + "\n" + END + "\n"


def strip_existing(text):
    if BEGIN not in text:
        return text
    head, rest = text.split(BEGIN, 1)
    _, tail = rest.split(END, 1)
    return head + tail.lstrip("\n")


def main():
    uninstall = "--uninstall" in sys.argv

    with open(TARGET) as f:
        original = f.read()

    if not os.path.exists(BACKUP):
        shutil.copy2(TARGET, BACKUP)
        print(f"backup: {BACKUP}")

    text = strip_existing(original).replace(CALL, "")

    if not uninstall:
        if ANCHOR not in text:
            sys.exit(f"anchor not found in {TARGET}: {ANCHOR.strip()!r}")
        text = text.replace("def main():", payload() + "\n\ndef main():", 1)
        text = text.replace(ANCHOR, ANCHOR + CALL, 1)

    if text == original:
        print("no change")
        return

    tmp = TARGET + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, TARGET)
    print(("uninstalled from " if uninstall else "installed into ") + TARGET)


if __name__ == "__main__":
    main()
