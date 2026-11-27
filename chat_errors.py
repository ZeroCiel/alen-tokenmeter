#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""扫描 opencode 会话库, 把「回话失败」抽出来给 TokenMeter 告警窗用.

数据源: %USERPROFILE%\\.local\\share\\opencode\\opencode.db  →  message 表
        assistant 消息里 data.error = {name, data:{message,statusCode,...}}
输出:   <TOKENS_DIR>\\chat-errors.json

用法:  python chat_errors.py [--minutes 360] [--quiet]
"""
import argparse
import datetime
import io
import json
import os
import re
import sqlite3
import sys

DB = os.path.expanduser(r"~/.local/share/opencode/opencode.db")
TOKENS_DIR = os.environ.get("TOKENS_DIR") or r"D:\Backup\Documents\deepseek-harness\default-workspace\tokens"
OUT = os.path.join(TOKENS_DIR, "chat-errors.json")


def iso(ms):
    if not ms:
        return ""
    # 不用 ISO8601(带 T 的形式): PowerShell 的 ConvertFrom-Json 会自动把它转成
    # DateTime, 再转回字符串就变成 round-trip 格式, 导致去重键(ackKey)前后不一致.
    return datetime.datetime.fromtimestamp(ms / 1000.0).strftime("%Y-%m-%d %H:%M:%S")


def short(msg, n=120):
    msg = re.sub(r"\s+", " ", (msg or "")).strip()
    return msg[:n] + ("…" if len(msg) > n else "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--minutes", type=int, default=360)
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    now = datetime.datetime.now().astimezone()
    since_ms = int((now.timestamp() - a.minutes * 60) * 1000)
    result = {
        "at": now.isoformat(timespec="seconds"),
        "window_minutes": a.minutes,
        "db": DB,
        "total_rows": 0,
        "errors": [],
        "note": "",
    }

    if not os.path.exists(DB):
        result["note"] = "找不到 opencode.db"
        write(result, a.quiet)
        return

    try:
        con = sqlite3.connect("file:%s?mode=ro" % DB.replace("\\", "/"), uri=True, timeout=10)
        rows = list(con.execute(
            "select id, time_created, data from message "
            "where time_created >= ? order by time_created desc", (since_ms,)))
        con.close()
    except Exception as e:  # 文件被锁/表结构变化
        result["note"] = "读库失败: %s: %s" % (type(e).__name__, e)
        write(result, a.quiet)
        return

    result["total_rows"] = len(rows)
    groups = {}
    for mid, tms, raw in rows:
        try:
            d = json.loads(raw)
        except Exception:
            continue
        if d.get("role") != "assistant":
            continue
        err = d.get("error")
        if not err:
            continue
        edata = err.get("data") or {}
        name = err.get("name") or "Error"
        msg = edata.get("message") or ""
        status = edata.get("statusCode") or edata.get("status") or 0
        if not msg:
            msg = json.dumps({k: v for k, v in edata.items() if k != "responseHeaders"},
                             ensure_ascii=False)[:160]
        prov = d.get("providerID") or "?"
        model = d.get("modelID") or "?"
        key = "%s|%s|%s|%s" % (prov, model, status or name, short(msg, 60))
        g = groups.get(key)
        if g is None:
            groups[key] = {
                "key": key,
                "provider": prov,
                "model": model,
                "status": status if isinstance(status, int) else 0,
                "type": name,
                "msg": short(msg, 200),
                "count": 1,
                "first": iso(tms),
                "last": iso(tms),
                "last_ms": tms,
                "message_id": mid,
            }
        else:
            g["count"] += 1
            if tms < g["last_ms"]:
                g["last"] = iso(tms)
                g["last_ms"] = tms
                g["message_id"] = mid

    items = sorted(groups.values(), key=lambda x: x["last_ms"], reverse=True)
    for it in items:
        it.pop("last_ms", None)
    result["errors"] = items[:40]
    write(result, a.quiet)


def write(obj, quiet):
    try:
        os.makedirs(TOKENS_DIR, exist_ok=True)
        with io.open(OUT, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
    except Exception as e:
        if not quiet:
            print("write failed: %s" % e, file=sys.stderr)
        return
    if not quiet:
        print("errors=%d / rows=%d -> %s" % (len(obj.get("errors") or []), obj.get("total_rows", 0), OUT))


if __name__ == "__main__":
    main()
