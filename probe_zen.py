#!/usr/bin/env python3
"""Probe the OpenCode *builtin* Zen models and write the result into TOKENS.json.

Why a separate script: Zen's free tier is only usable from inside the official
OpenCode client. Any HTTP call carrying an API key (including through the local
gateway on :3425) is rejected with ``429 FreeUsageLimitError``. The only working
probe is therefore to spawn the real CLI:

    opencode run -m opencode/<model> "只回复：ok"

and look at the exit code. Same write-back shape as probe_models.py so the
token meter / alert panel can read ``model_details[].probe`` uniformly.

Usage:
    python probe_zen.py                # probe every model (slow: ~15s each)
    python probe_zen.py --quick        # first 3 models only
    python probe_zen.py --only big-pickle
    python probe_zen.py --timeout 45
    python probe_zen.py --dry-run      # print table, do not write

Env:
    TOKENS_DIR       directory of TOKENS.json (default: ../tokens next to this file)
    OPENCODE_BIN     path of the opencode executable (default: opencode on PATH)

Exit code: 0 always (a failed model is data, not an error).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_CANDS = [
    os.environ.get("TOKENS_DIR"),
    os.path.join(os.path.dirname(HERE), "tokens"),
    os.path.join(os.path.dirname(HERE), "default-workspace", "tokens"),
    os.path.join(HERE, "tokens"),
]
TOKENS_DIR = next(
    (c for c in _CANDS if c and os.path.exists(os.path.join(c, "TOKENS.json"))),
    os.path.join(os.path.dirname(HERE), "tokens"))
TOK_PATH = os.path.join(TOKENS_DIR, "TOKENS.json")
LINE_PATH = os.path.join(TOKENS_DIR, "FREE-LINES-status.json")
PROVIDER_ID = "opencode-zen-builtin"
OPENCODE_PID = "opencode"
WORKDIR = os.environ.get("ZEN_PROBE_CWD") or os.path.dirname(TOKENS_DIR)

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# 走 cmd /c 时中文会被 GBK/UTF-8 混编搞坏, 探活用纯 ASCII 提示词
PROMPT = "reply with: ok"


def resolve_bin():
    """opencode 在 Windows 上通常是 npm 的 .cmd 包装, subprocess 必须经 cmd /c."""
    b = os.environ.get("OPENCODE_BIN")
    if b and os.path.exists(b):
        return b
    found = shutil.which("opencode")
    if found:
        return found
    cand = os.path.join(os.environ.get("APPDATA", ""), "npm", "opencode.cmd")
    if os.path.exists(cand):
        return cand
    return "opencode"


def build_cmd(bin_path, model):
    args = ["run", "-m", "%s/%s" % (OPENCODE_PID, model), PROMPT]
    low = bin_path.lower()
    if low.endswith(".cmd") or low.endswith(".bat"):
        return ["cmd", "/c", bin_path] + args
    return [bin_path] + args


def load_json(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8-sig"))


def refresh_lines(entry):
    """把一个内置 Zen 的探活结果同步到 FREE-LINES-status.json 的 magpie 条目。

    原来那条是「GET /v1/models 200 就算通」(local gateway 3425)，网关进程活着就显示
    绿色长期免费，完全掩盖了 chat 全 429 的事实。改成以 `opencode run` 的真实结果为准。
    """
    if not os.path.exists(LINE_PATH):
        return
    with open(LINE_PATH, "rb") as f:
        raw = f.read()
    bom = raw[:3] == b"\xef\xbb\xbf"
    lines = json.loads(raw.decode("utf-8-sig"))
    md = [m for m in (entry.get("model_details") or []) if m.get("name")]
    prb = [m["probe"] for m in md if m.get("probe")]
    if not prb:
        print("FREE-LINES not synced: no probe data in ledger")
        return
    oks = [p for p in prb if p.get("ok")]
    lat = min([p.get("ms") or 0 for p in oks]) if oks else None
    lines.setdefault("lines", {})["magpie"] = {
        "ok": bool(oks),
        "latency_ms": lat,
        "note": "opencode 官方入口通道: %d/%d 可用（opencode run 实测）; 本地网关 3425 转发已被 Zen 判 429, 废弃" % (len(oks), len(md)),
    }
    data = json.dumps(lines, ensure_ascii=False, indent=2).encode("utf-8")
    with open(LINE_PATH, "wb") as f:
        if bom:
            f.write(b"\xef\xbb\xbf")
        f.write(data)
    print("synced FREE-LINES-status.json magpie -> %d/%d ok" % (len(oks), len(md)))


def guess_status(text):
    t = (text or "").lower()
    if "429" in t or "free usage limit" in t or "rate limit" in t:
        return 429
    if "unavailable" in t or "not found" in t or "model_not_found" in t:
        return 404
    if "unauthor" in t or "401" in t:
        return 401
    if "forbidden" in t or "403" in t:
        return 403
    return 400


def probe_one(bin_path, model, timeout):
    """Return (ok, status, ms, error)."""
    cmd = build_cmd(bin_path, model)
    t0 = time.time()
    try:
        p = subprocess.run(
            cmd, cwd=WORKDIR, timeout=timeout,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
    except subprocess.TimeoutExpired:
        return False, 0, int((time.time() - t0) * 1000), "timeout %ds 无响应" % timeout
    except FileNotFoundError:
        return False, 0, 0, "找不到 opencode 可执行文件: %s" % bin_path
    ms = int((time.time() - t0) * 1000)
    raw = p.stdout or b""
    try:
        txt = raw.decode("utf-8")
    except UnicodeDecodeError:
        txt = raw.decode("gbk", "replace")
    out = ANSI.sub("", txt).strip()
    low = out.lower()
    if p.returncode == 0 and "error:" not in low:
        return True, 200, ms, ""
    msg = ""
    for line in out.splitlines():
        s = line.strip()
        if s.lower().startswith("error:"):
            msg = s
            break
    if not msg:
        msg = out.splitlines()[-1].strip() if out else "exit=%d 无输出" % p.returncode
    return False, guess_status(msg), ms, msg[:200]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="only probe the first 3 models")
    ap.add_argument("--only", default="", help="probe a single model name")
    ap.add_argument("--timeout", type=int, default=45)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--limit", type=int, default=0, help="只探前 N 个（0=不限制）")
    ap.add_argument("--skip", type=int, default=0, help="跳过前 N 个")
    ap.add_argument("--sync-lines-only", action="store_true",
                    help="不探活, 只把台账里已有的 probe 结果同步到 FREE-LINES-status.json")
    args = ap.parse_args()

    bin_path = resolve_bin()
    if not args.sync_lines_only and not os.path.exists(bin_path) and not shutil.which(bin_path):
        print("找不到 opencode 可执行文件，用 OPENCODE_BIN 指定完整路径")
        return 1
    ledger = load_json(TOK_PATH)
    entry = None
    for t in ledger.get("tokens", []):
        if t.get("id") == PROVIDER_ID:
            entry = t
            break
    if not entry:
        print("no %s in TOKENS.json" % PROVIDER_ID)
        return 0

    details = entry.get("model_details") or []
    if args.sync_lines_only:
        refresh_lines(entry)
        return 0
    targets = [m for m in details if m.get("name")]
    if args.only:
        targets = [m for m in targets if m.get("name") == args.only]
    else:
        if args.skip:
            targets = targets[args.skip:]
        if args.quick:
            targets = targets[:3]
        elif args.limit:
            targets = targets[:args.limit]
    if not targets:
        print("nothing to probe")
        return 0

    print("probing %d model(s) via `%s run` (timeout %ds each)" % (len(targets), bin_path, args.timeout))
    now = time.strftime("%Y-%m-%dT%H:%M:%S+08:00")
    okn = 0
    for m in targets:
        name = m["name"]
        ok, status, ms, err = probe_one(bin_path, name, args.timeout)
        m["probe"] = {"at": now, "ok": ok, "status": status, "ms": ms, "error": err}
        m["usable"] = bool(ok)
        if ok:
            okn += 1
        print("%s %-34s %6dms %4s  %s" % ("OK " if ok else "ERR", name, ms, status, err))
        # 增量落盘: 分批跑或中途被杀都不丢已完成的结果
        if not args.dry_run:
            ledger["updated_at"] = now
            with open(TOK_PATH, "wb") as f:
                f.write(json.dumps(ledger, ensure_ascii=False, indent=2).encode("utf-8"))

    # 汇总用「全部 model 的 probe」而不是本轮 targets, 分批跑也能反映整体
    allprb = [m["probe"] for m in details if m.get("probe")]
    okall = sum(1 for p in allprb if p.get("ok"))
    if allprb:
        stamp = time.strftime("%Y-%m-%d %H:%M")
        entry["verified_at"] = "%s 探活 %d/%d 可用（opencode run 实测）" % (stamp, okall, len(details))
        entry["last_probe"] = {"at": now, "ok": okall, "total": len(details)}
        entry["status"] = "active" if okall > 0 else "active-quota-exhausted-429"

    if args.dry_run:
        print("dry-run: TOKENS.json not written")
        return 0

    ledger["updated_at"] = now
    data = json.dumps(ledger, ensure_ascii=False, indent=2).encode("utf-8")
    with open(TOK_PATH, "wb") as f:
        f.write(data)
    print("written %s (%d bytes) | %d/%d ok" % (TOK_PATH, len(data), okn, len(targets)))
    refresh_lines(entry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
