"""claudeMeter の収集フック。statusLine スクリプトから呼び出す。

statusLine の stdin JSON に入る `rate_limits`（サーバーが返した 5時間／7日／支出の
実測消費率）を ~/.claude/claudemeter/samples.jsonl へ追記する。値が変化したときだけ
書くので、1 セッションあたり数十行に収まる。

statusline.py 側の main() 先頭付近で:

    try:
        record_rate_limits(data)
    except Exception:
        pass

とだけ呼ぶ。収集が失敗しても statusLine の表示は壊さない。
"""
import json
import os
import time

METER_DIR = os.path.expanduser("~/.claude/claudemeter")
METER_SAMPLES = os.path.join(METER_DIR, "samples.jsonl")
METER_MAX_BYTES = 4 * 1024 * 1024
METER_WINDOWS = ("five_hour", "seven_day", "spend_limit")


def record_rate_limits(data):
    """rate_limits を samples.jsonl へ追記する（前回と同じ値なら書かない）。"""
    limits = data.get("rate_limits") or {}
    windows = {}
    for key in METER_WINDOWS:
        w = limits.get(key) or {}
        used = w.get("used_percentage")
        if used is None:
            continue
        windows[key] = {"used": float(used), "resets_at": w.get("resets_at")}
    if not windows:
        return

    os.makedirs(METER_DIR, exist_ok=True)
    if _unchanged(windows):
        return

    rec = dict(windows)
    rec["ts"] = int(time.time())
    model = (data.get("model") or {}).get("id")
    if model:
        rec["model"] = model

    with open(METER_SAMPLES, "a") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    _trim()


def _unchanged(windows):
    line = _last_line()
    if not line:
        return False
    try:
        prev = json.loads(line)
    except ValueError:
        return False
    return all(prev.get(k) == v for k, v in windows.items()) and \
        all(k in windows for k in METER_WINDOWS if k in prev)


def _last_line():
    try:
        size = os.path.getsize(METER_SAMPLES)
    except OSError:
        return None
    with open(METER_SAMPLES, "rb") as f:
        f.seek(max(0, size - 8192))
        tail = f.read().decode("utf-8", "replace").strip().split("\n")
    return tail[-1] if tail and tail[-1] else None


def _trim():
    """肥大したら後半だけ残す。追記専用なので行単位で切り落とすだけでよい。"""
    try:
        if os.path.getsize(METER_SAMPLES) <= METER_MAX_BYTES:
            return
        with open(METER_SAMPLES) as f:
            lines = f.readlines()
        keep = lines[len(lines) // 2:]
        tmp = METER_SAMPLES + ".tmp"
        with open(tmp, "w") as f:
            f.writelines(keep)
        os.replace(tmp, METER_SAMPLES)
    except OSError:
        pass
