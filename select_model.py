#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自动挑选「可用 + 高分档 + 低延迟」的模型线路，写入本机各 agent 配置。

用法:
    python select_model.py --dry          # 只看选择结果，不写任何文件
    python select_model.py --apply        # 挑选并写入 opencode / hermes / zcode
    python select_model.py --apply --quiet  # 供 TokenMeter 启动时静默调用

数据源: tokens/TOKENS.json (台账, model_details.usable/probe/tier)
        tokens/TOKEN-STATUS.json (钥匙巡检, 余额/auth)
        tokens/baizhi-credits.json (控件内手动维护的积分)

写入结果: tokens/selected-line.json (谁、何时、选了什么、各 agent 落地情况)
"""
import argparse
import datetime
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BASE = os.path.dirname(os.path.abspath(__file__))
TOKDIR = os.environ.get("TOKENS_DIR", r"D:\Backup\Documents\deepseek-harness\default-workspace\tokens")
HOME = os.path.expanduser("~")

P_TOKENS = os.path.join(TOKDIR, "TOKENS.json")
P_KEYS = os.path.join(TOKDIR, "TOKEN-STATUS.json")
P_CREDIT = os.path.join(TOKDIR, "baizhi-credits.json")
P_SELECTED = os.path.join(TOKDIR, "selected-line.json")
P_LOCK = os.path.join(TOKDIR, "model-lock.json")

P_OPENCODE = os.environ.get("OPENCODE_CONFIG", os.path.join(HOME, ".config", "opencode", "opencode.json"))
P_HERMES = os.path.join(os.environ.get("LOCALAPPDATA", os.path.join(HOME, "AppData", "Local")), "hermes", "config.yaml")
P_ZCODE = os.path.join(HOME, ".zcode", "v2", "provider_config.json")

TIER_RANK = {"S": 4, "A": 3, "B": 2, "C": 1}
NO_PROBE_MS = 999999

# 台账线路 id -> opencode provider id
OPENCODE_PROVIDER = {
    "moma-deepseek": "deepseek",
    "scnet-tokenplan": "scnet",
    "gitcode-codingplan": "gitcode-codingplan",
    "free-amd": "free-amd",
    "modelscope": "modelscope",
    "zhipu": "zhipu",
    "magpie-zen": "magpie-zen",
    "opencode-zen-builtin": "opencode",
    "deepseek-official": "deepseek-official",
    "baizhi": "baizhi",
}

# 台账线路 id -> zcode providerId（ZCode 内部命名不统一）
ZCODE_PROVIDER = {
    "moma-deepseek": "custom-moma",
    "scnet-tokenplan": "bigmodel-api",
    "gitcode-codingplan": "new-provider",
    "free-amd": "custom-amd",
    "modelscope": "custom-modelscope",
    "zhipu": "zai-standard-api",
    "magpie-zen": "custom-magpie",
    "deepseek-official": "deepseek",
    "baizhi": "new-provider",
}

# 台账 (线路, 模型) -> hermes (provider, model)
# hermes 的 custom provider 走 fallback_providers 里已有的 base_url；
# magpie provider 走本机 Magpie 网关。没列出的线路视为「该 agent 不支持」。
HERMES_MODEL = {
    ("zhipu", "glm-4-flash"): ("custom", "glm-4-flash"),
    ("zhipu", "glm-4.6v"): ("custom", "glm-4.6v"),
    ("moma-deepseek", "deepseek-v4.1-flash"): ("custom", "deepseek-v4.1-flash"),
    ("moma-deepseek", "deepseek-v4.1-flash-1017"): ("custom", "deepseek-v4.1-flash"),
    ("moma-deepseek", "deepseek-v3.2"): ("custom", "deepseek-v4.1-flash"),
    ("free-amd", "GLM-5.3-Flash"): ("custom", "GLM-5.3-Flash"),
    ("free-amd", "DeepSeek-V4.1-Flash"): ("custom", "DeepSeek-V4.1-Flash"),
    ("free-amd", "Gemma-4-31B-IT"): ("custom", "Gemma-4-31B-IT"),
}
for _mid in (
    "deepseek-v4.1-flash-free", "big-pickle", "nemotron-3.5-super-vl-free",
    "flint-40b-free", "mimo-v2.6-flash-free", "nemotron-3.5-lightning-free",
    "iceman-free",
):
    HERMES_MODEL[("magpie-zen", "opencode-zen/" + _mid)] = ("magpie", "opencode-zen/" + _mid)
    HERMES_MODEL[("opencode-zen-builtin", _mid)] = ("magpie", "opencode-zen/" + _mid)


def jload(path, default=None):
    try:
        with open(path, "rb") as f:
            b = f.read()
        if b[:3] == b"\xef\xbb\xbf":
            b = b[3:]
        return json.loads(b.decode("utf-8"))
    except Exception:
        return default


def refresh_ds_balance():
    """实时查 DS 官方余额，回写钥匙巡检；返回 True/False（不足）。"""
    cfg = jload(P_OPENCODE, {}) or {}
    o = (((cfg.get("provider") or {}).get("deepseek-official") or {}).get("options") or {})
    base, key = o.get("baseURL"), o.get("apiKey")
    if not base or not key:
        return None
    try:
        req = urllib.request.Request(base.rstrip("/") + "/user/balance",
                                     headers={"Authorization": "Bearer " + str(key)})
        data = json.loads(urllib.request.urlopen(req, timeout=15).read().decode("utf-8"))
        avail = bool(data.get("is_available"))
        infos = data.get("balance_infos") or []
        bal = infos[0].get("total_balance") if infos else None
        ks = jload(P_KEYS, {}) or {}
        for k in ks.get("keys", []):
            if k.get("name") == "deepseek-official":
                k["balance"] = bal
                k["auth"] = "ok" if avail and float(bal or 0) >= 0.04 else "402"
                k["note"] = "GET /user/balance 200 (CNY %s; is_available=%s)" % (bal, avail)
        ks["timestamp"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        backup(P_KEYS)
        write_json(P_KEYS, ks)
        return avail and float(bal or 0) >= 0.04
    except Exception:
        return None


def live_probe(pool):
    """应用前实时探活候选模型；剔除实际跑不通的线路。"""
    cfg = jload(P_OPENCODE, {}) or {}
    provs = cfg.get("provider") or {}
    targets = []
    for x in pool[:8]:
        pid = x["opencode_provider"]
        o = (provs.get(pid) or {}).get("options") or {}
        base, key = o.get("baseURL"), o.get("apiKey")
        if base and key:
            targets.append((x, base, key))

    def one(item):
        x, base, key = item
        body = {"model": x["model"], "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1}
        req = urllib.request.Request(
            base.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
            headers={"Authorization": "Bearer " + str(key), "Content-Type": "application/json"})
        last = ("", 0, 0, "")
        for attempt in range(2):
            t0 = time.time()
            try:
                with urllib.request.urlopen(req, timeout=12) as r:
                    r.read()
                    return (x["line"], x["model"], True, r.status,
                            int((time.time() - t0) * 1000), "")
            except urllib.error.HTTPError as e:
                msg = e.read().decode("utf-8", "replace")[:160]
                return (x["line"], x["model"], False, e.code,
                        int((time.time() - t0) * 1000), msg)
            except Exception as e:
                last = (str(e)[:120], 0, 0, "")
        return (x["line"], x["model"], False, 0, 0, last[0])

    results = {}
    if targets:
        with ThreadPoolExecutor(max_workers=6) as ex:
            for line, model, ok, status, ms, err in ex.map(one, targets):
                results[(line, model)] = {"ok": ok, "status": status, "ms": ms, "error": err}

    kept, dropped, checked = [], [], []
    for x in pool:
        r = results.get((x["line"], x["model"]))
        if not r:
            kept.append(x)
            continue
        checked.append({"line": x["line"], "model": x["model"], **r})
        if r["ok"]:
            x["ms"] = r["ms"]
            x["probe_ok"] = True
            kept.append(x)
        else:
            d = dict(x)
            d["why"] = "实时探活 %s %s" % (r["status"], r["error"][:60])
            dropped.append(d)
    for z in kept:
        z["score"] = (z["tier_rank"], 1 if z["probe_ok"] else 0, -z["ms"])
    kept.sort(key=lambda x: x["score"], reverse=True)
    return kept, dropped, checked


def writeback_probes(checked):
    """把实时探活结果回写台账，额度条同步显示。"""
    if not checked:
        return 0
    tok = jload(P_TOKENS, {}) or {}
    idx = {(t.get("id"), m.get("name")): m for t in tok.get("tokens", [])
           for m in (t.get("model_details") or [])}
    n = 0
    stamp = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    for c in checked:
        m = idx.get((c["line"], c["model"]))
        if m is None:
            continue
        m["probe"] = {"at": stamp, "ok": c["ok"], "status": c["status"],
                      "ms": c["ms"], "error": c["error"]}
        n += 1
    if n:
        backup(P_TOKENS)
        write_json(P_TOKENS, tok)
    return n


def backup(path):
    if not os.path.isfile(path):
        return None
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dst = path + ".bak-" + stamp
    shutil.copy2(path, dst)
    return dst


def write_json(path, obj, bom=False):
    s = json.dumps(obj, ensure_ascii=False, indent=2) + "\n"
    data = (b"\xef\xbb\xbf" if bom else b"") + s.encode("utf-8")
    with open(path, "wb") as f:
        f.write(data)


def balance_of(key_status, name):
    for k in (key_status or {}).get("keys", []):
        if k.get("name") == name:
            v = str(k.get("balance", "-"))
            try:
                return float(v)
            except Exception:
                return None
    return None


def candidates():
    tok = jload(P_TOKENS, {}) or {}
    keys = jload(P_KEYS, {}) or {}
    keep = set((tok.get("model_policy") or {}).get("keep") or [])
    credit = jload(P_CREDIT, {}) or {}
    out = []
    rejected = []
    for t in tok.get("tokens", []):
        tid = t.get("id")
        status = str(t.get("status") or "")
        for m in t.get("model_details") or []:
            name = m.get("name")
            tier = str(m.get("tier") or "C")
            probe = m.get("probe") or {}
            quota = m.get("quota") or {}
            reasons = []
            if not status.startswith("active"):
                reasons.append("线路状态=" + status)
            if not m.get("usable"):
                reasons.append("usable=false")
            if tier == "C" and name not in keep:
                reasons.append("C档不启用")
            if probe and not probe.get("ok"):
                reasons.append("探活%s %s" % (probe.get("status"), str(probe.get("error", ""))[:30]))
            qunit = quota.get("unit")
            if qunit == "tokens" and quota.get("remaining") == 0:
                reasons.append("额度0")
            if tid == "deepseek-official":
                bal = balance_of(keys, "deepseek-official")
                if bal is not None and bal < 0.04:
                    reasons.append("余额不足")
            if tid == "baizhi" and credit.get("remaining") is not None:
                try:
                    if float(credit["remaining"]) <= 0:
                        reasons.append("积分0")
                except Exception:
                    pass
            if reasons:
                rejected.append({"line": tid, "model": name, "why": "；".join(reasons)})
                continue
            ms = probe.get("ms") if probe.get("ok") else None
            note = ""
            if tid == "deepseek-official":
                bal = balance_of(keys, "deepseek-official")
                if bal is not None:
                    note = "DS 官方余额 ¥%.2f（按量付费）" % bal
            elif tid == "baizhi" and credit.get("remaining") is not None:
                note = "百智云积分 %s（积分计费）" % credit["remaining"]
            out.append({
                "line": tid,
                "model": name,
                "tier": tier,
                "tier_rank": TIER_RANK.get(tier, 0),
                "probe_ok": bool(probe.get("ok")),
                "note": note,
                "ms": ms if ms is not None else NO_PROBE_MS,
                "opencode_provider": OPENCODE_PROVIDER.get(tid),
                "zcode_provider": ZCODE_PROVIDER.get(tid),
                "score": (TIER_RANK.get(tier, 0), 1 if probe.get("ok") else 0,
                          -(ms if ms is not None else NO_PROBE_MS)),
            })
    out.sort(key=lambda x: x["score"], reverse=True)
    return out, rejected


def apply_opencode(best, results):
    p = P_OPENCODE
    if not os.path.isfile(p):
        results["opencode"] = {"ok": False, "why": "配置文件不存在: " + p}
        return
    d = jload(p, {}) or {}
    provider = best["opencode_provider"]
    if not provider or provider not in (d.get("provider") or {}):
        results["opencode"] = {"ok": False, "why": "opencode 未配置 provider " + str(provider)}
        return
    model_id = provider + "/" + best["model"]
    changed = model_id != d.get("model")
    if changed:
        backup(p)
        d["model"] = model_id
        write_json(p, d)
    results["opencode"] = {"ok": True, "model": model_id, "changed": changed}
    results["dsh"] = {"ok": True, "why": "DSH 驱动同一份 opencode 配置，自动跟随"}


def apply_hermes(best, results):
    p = P_HERMES
    if not os.path.isfile(p):
        results["hermes"] = {"ok": False, "why": "配置文件不存在: " + p}
        return
    target = HERMES_MODEL.get((best["line"], best["model"]))
    if not target:
        results["hermes"] = {"ok": False, "why": "hermes 无对应模型映射（线路不通用）"}
        return
    provider, model = target
    try:
        with open(p, "r", encoding="utf-8-sig") as f:
            text = f.read()
    except Exception as e:
        results["hermes"] = {"ok": False, "why": "读取失败: " + str(e)}
        return
    new_text, n1 = re.subn(r"(?m)^(\s*provider:\s*)[^\s#]+(\s*#.*)?$",
                          lambda m: m.group(1) + provider + (m.group(2) or ""), text, count=1)
    new_text, n2 = re.subn(r"(?m)^(\s*default:\s*)[^\s#]+(\s*#.*)?$",
                          lambda m: m.group(1) + model + (m.group(2) or ""), new_text, count=1)
    if not (n1 and n2):
        results["hermes"] = {"ok": False, "why": "未找到 model.provider/default 两行"}
        return
    if new_text != text:
        backup(p)
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(new_text)
    results["hermes"] = {"ok": True, "provider": provider, "model": model}


def zcode_running():
    try:
        import subprocess
        out = subprocess.run(["tasklist", "/NH", "/FI", "IMAGENAME eq ZCode.exe"],
                             capture_output=True, text=True, timeout=8).stdout
        return "ZCode.exe" in out
    except Exception:
        return False


def apply_zcode(best, results):
    p = P_ZCODE
    if not os.path.isfile(p):
        results["zcode"] = {"ok": False, "why": "配置文件不存在: " + p}
        return
    if zcode_running():
        results["zcode"] = {"ok": False, "why": "ZCode 正在运行，内存态会在退出时覆盖配置；需先退出再重选"}
        return
    zid = best["zcode_provider"]
    if not zid:
        results["zcode"] = {"ok": False, "why": "无对应 ZCode providerId"}
        return
    d = jload(p, {}) or {}
    cfg = d.get("config") or {}
    order = list(cfg.get("providerOrder") or [])
    if zid not in order:
        results["zcode"] = {"ok": False, "why": "zcode providerOrder 无 " + zid}
        return
    if order[0] != zid:
        backup(p)
        order.remove(zid)
        cfg["providerOrder"] = [zid] + order
        d["config"] = cfg
        write_json(p, d)
    results["zcode"] = {"ok": True, "provider": zid, "note": "已提到 providerOrder 首位；模型需在 ZCode 界面确认"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="写入各 agent 配置")
    ap.add_argument("--dry", action="store_true", help="只显示选择结果")
    ap.add_argument("--quiet", action="store_true", help="静默（供控件调用）")
    ap.add_argument("--no-live", action="store_true", help="跳过实时探活（只用台账快照）")
    args = ap.parse_args()

    pool, rejected = candidates()
    dropped_live, checked = [], []
    if args.apply and not args.no_live:
        if refresh_ds_balance() is False:
            before = len(pool)
            pool = [x for x in pool if x["line"] != "deepseek-official"]
            if len(pool) != before:
                rejected.append({"line": "deepseek-official", "model": "*",
                                 "why": "实时余额不可用（GET /user/balance）"})
        pool, dropped_live, checked = live_probe(pool)
        rejected.extend(dropped_live)
        writeback_probes(checked)
    if not pool:
        msg = {"ok": False, "why": "没有可用线路", "rejected": rejected[:8]}
        print(json.dumps(msg, ensure_ascii=not args.quiet))
        return 2
    best = pool[0]

    results = {}
    if args.apply:
        lock = jload(P_LOCK, {}) or {}
        if lock.get("locked"):
            results["_skipped"] = "已锁定自动切换（model-lock.json locked=true）"
        else:
            apply_opencode(best, results)
            apply_hermes(best, results)
            apply_zcode(best, results)
        rec = {
            "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "line": best["line"], "model": best["model"], "tier": best["tier"],
            "probe_ms": best["ms"] if best["ms"] != NO_PROBE_MS else None,
            "opencode_model": (results.get("opencode") or {}).get("model"),
            "note": best.get("note", ""),
            "agents": results,
        }
        write_json(P_SELECTED, rec)

    if not args.quiet:
        print(json.dumps({
            "ok": True,
            "selected": {k: best[k] for k in ("line", "model", "tier", "probe_ok", "ms", "opencode_provider", "note")},
            "runners_up": [{k: x[k] for k in ("line", "model", "tier", "ms")} for x in pool[1:5]],
            "applied": results if args.apply else "dry-run",
            "selected_file": P_SELECTED if args.apply else None,
        }, ensure_ascii=False, indent=2))
    elif args.apply:
        print(best["opencode_provider"] + "/" + best["model"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
