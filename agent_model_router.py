#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 Agent 分别绑定模型（大肥鱼=控制器）。免费优先/自动排/付费兜底。"""
import argparse, datetime, json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import select_model as sm

BASE = os.path.dirname(os.path.abspath(__file__))
P_CFG = os.path.join(BASE, "bindings", "agent-bindings.json")
P_STATE = os.path.join(sm.TOKDIR, "agent-bindings-state.json")

def rank_free_first(pool, paid_lines):
    free = [x for x in pool if x["line"] not in paid_lines]
    paid = [x for x in pool if x["line"] in paid_lines]
    return free, paid

def support_pool(target, free, paid):
    if target == "opencode":
        return ([x for x in free if x.get("opencode_provider")],
                [x for x in paid if x.get("opencode_provider")])
    if target == "hermes":
        return ([x for x in free if (x["line"], x["model"]) in sm.HERMES_MODEL],
                [x for x in paid if (x["line"], x["model"]) in sm.HERMES_MODEL])
    if target == "dsh":
        usable = sm.DSH_PROVIDER or {}
        bad = getattr(sm, "DSH_UNUSABLE", set())
        return ([x for x in free if x["line"] in usable and x["line"] not in bad],
                [x for x in paid if x["line"] in usable and x["line"] not in bad])
    if target == "zcode":
        zcfg = sm.jload(sm.P_ZCODE, {}) or {}
        order = list(((zcfg.get("config") or {}).get("providerOrder")) or [])
        return ([x for x in free if x.get("zcode_provider") in order],
                [x for x in paid if x.get("zcode_provider") in order])
    return [], []

def pick(agent, free, paid):
    f, p = support_pool(agent["target"], free, paid)
    prefer_free = agent.get("prefer_free", True)
    fallback = agent.get("paid_fallback", True)
    if prefer_free and f:
        return f[0], "free"
    if fallback and p:
        return p[0], "fallback"
    if f:
        return f[0], "free"
    return None, "none"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()
    cfg = sm.jload(P_CFG, {}) or {}
    paid_lines = set((cfg.get("policy") or {}).get("paid_lines") or []) or set(sm.PAID_LINES)
    pool, _ = sm.candidates()
    free, paid = rank_free_first(pool, paid_lines)
    plan = []
    for agent in cfg.get("agents", []):
        best, source = pick(agent, free, paid)
        e = {"agent": agent["id"], "name": agent["name"], "target": agent["target"], "source": source}
        if best:
            e.update({"line": best["line"], "model": best["model"], "tier": best["tier"],
                      "note": best.get("note", ""), "opencode_provider": best.get("opencode_provider"),
                      "zcode_provider": best.get("zcode_provider")})
        plan.append(e)
    applied = {}
    if args.apply:
        done = set()
        for agent in cfg.get("agents", []):
            t = agent["target"]
            best, _ = pick(agent, free, paid)
            if best is None or t in done:
                if t in done: applied[agent["id"]] = {"ok": True, "shared": t}
                continue
            done.add(t)
            r = {}
            if t == "opencode":
                sm.apply_opencode(best, r)
            elif t == "dsh": sm.apply_dsh(best, r)
            elif t == "hermes": sm.apply_hermes(best, r)
            elif t == "zcode": sm.apply_zcode(best, r)
            applied[agent["id"]] = r
        sm.write_json(P_STATE, {"at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                                "plan": plan, "applied": applied})
    out = {"ok": True, "policy": cfg.get("policy", {}), "plan": plan}
    if args.apply:
        out["applied"] = applied; out["state_file"] = P_STATE
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 0

if __name__ == "__main__":
    sys.exit(main())