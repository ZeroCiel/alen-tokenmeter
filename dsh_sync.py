#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DSH 侧接额度条: ① 把额度写进供应商显示名  ② 让额度条的选线落到 DSH 默认模型。

两件事都能单独跑, 也都能当模块被 select_model.py 导入(apply_dsh)。

数据源(额度条同一份台账):
    tokens/TOKENS.json            model_details[].probe / expires_at / status
    tokens/TOKEN-STATUS.json      keys[].balance
    tokens/baizhi-credits.json    remaining

写入:
    ~/.dsh/profiles/desktop/cordis.patch.yml
      - llm-pi-ai.providers.<id>.displayName  <- 额度/到期/可用性
      - agent-default-model 块的 provider/model <- 额度条选中的线路
    只动这几行; provider id / model id / apiKeyEnv 一律不碰。写前自动备份, 写后 YAML 自检。

用法:
    python dsh_sync.py --show            # 打印每条线路压出来的名字(不写)
    python dsh_sync.py --apply-display   # 写显示名
    python dsh_sync.py --apply-model     # 按 selected-line.json 写 DSH 默认模型
"""
import argparse
import datetime
import json
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOKDIR = os.environ.get("TOKENS_DIR",
                        r"D:\Backup\Documents\deepseek-harness\default-workspace\tokens")
P_TOKENS = os.path.join(TOKDIR, "TOKENS.json")
P_KEYS = os.path.join(TOKDIR, "TOKEN-STATUS.json")
P_CREDIT = os.path.join(TOKDIR, "baizhi-credits.json")
P_SELECTED = os.path.join(TOKDIR, "selected-line.json")
P_PATCH = os.path.join(os.path.expanduser("~"), ".dsh", "profiles", "desktop", "cordis.patch.yml")

SUFFIX_SEP = " · "

# DSH provider id -> 台账线路 id（额度条里那一行的身份）
LINE_OF = {
    "amd": "free-amd",
    "baizhi": "baizhi",
    "zhipu": "zhipu",
    "scnet": "scnet-tokenplan",
    "moma": "moma-deepseek",
    "deepseek-official": "deepseek-official",
    "modelscope": "modelscope",
    "tokenrouter": "tokenrouter",
    "gitcode": "gitcode-codingplan",
    "apinex": "apinex",
    "magpie": "magpie-zen",
    "magpie-anthropic": None,
    "xai": None,
    "deepseek": None,
}

# magpie 工具会重写它自己那两个 provider 块，别跟它抢
SKIP_PROVIDERS = {"magpie", "magpie-anthropic"}

BASE = {
    "amd": "AMD Radeon Cloud",
    "baizhi": "百智云",
    "zhipu": "智谱 GLM 免费",
    "scnet": "SCNet",
    "moma": "MoMA 免费",
    "deepseek-official": "DeepSeek 官方",
    "modelscope": "魔搭 ModelScope 免费",
    "tokenrouter": "TokenRouter",
    "gitcode": "GitCode CodingPlan",
    "apinex": "APInex 免费",
    "magpie": "Magpie",
    "magpie-anthropic": "Magpie · Anthropic",
    "xai": "Grok 3 (xAI)",
}

# 额度口径（从台账 quota_official 人工压成一行；数字变了改这里）
QUOTA = {
    "amd": "每日1积分",
    "zhipu": "免费档",
    "scnet": "5万Credits/月",
    "moma": "2500万Token/30天",
    "modelscope": "2000次/日",
    "tokenrouter": "0价免费",
    "gitcode": "5h/300次",
    "apinex": "需充值",
    "magpie": "Zen 免费池",
    "magpie-anthropic": "Zen 付费池",
}

# 台账线路 id -> DSH provider id（agent-default-model 用）
DSH_PROVIDER = {
    "moma-deepseek": "moma",
    "free-amd": "amd",
    "zhipu": "zhipu",
    "scnet-tokenplan": "scnet",
    "modelscope": "modelscope",
    "tokenrouter": "tokenrouter",
    "apinex": "apinex",
    "deepseek-official": "deepseek-official",
    "baizhi": "baizhi",
    "gitcode-codingplan": "gitcode",
    "magpie-zen": "magpie",
}

# 这些线路 DSH 用不了：OpenCode 内置 Zen 只认 `opencode run` 内部通道，
# 外部 HTTP（包括走本机 3425 网关）一律 429 FreeUsageLimitError，别拿它当 DSH 默认模型。
DSH_UNUSABLE = {"opencode-zen-builtin"}


def jload(path, default=None):
    try:
        with open(path, "rb") as f:
            b = f.read()
        if b[:3] == b"\xef\xbb\xbf":
            b = b[3:]
        return json.loads(b.decode("utf-8"))
    except Exception:
        return default


def backup(path):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    dst = path + ".bak-dshsync-" + stamp
    shutil.copy2(path, dst)
    return dst


def atomic_write(path, text):
    """先写临时文件再 os.replace：定时任务/多 agent 同时写时不会写出半个文件。"""
    tmp = path + ".tmp-dshsync"
    with open(tmp, "w", encoding="utf-8", newline="") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def yaml_ok(path):
    try:
        import yaml  # type: ignore
    except Exception:
        return True, "PyYAML 不可用，跳过解析校验"
    try:
        with open(path, "r", encoding="utf-8") as f:
            yaml.safe_load(f)
        return True, "YAML 解析 OK"
    except Exception as e:
        return False, "YAML 解析失败: %s" % e


# ---------------------------------------------------------------- 显示名


def line_index(tok):
    return {t.get("id"): t for t in (tok.get("tokens") or []) if t.get("id")}


STATUS_TEXT = {
    "removed-model-not-found": "已下架",
    "removed-zen-gateway-429": "Zen 429 限流",
    "disabled-needs-proxy": "需代理",
    "blocked-needs-topup": "需充值",
    "blocked-needs-model-api-key": "缺 key",
    "not-purchased": "未购买",
    "active-quota-exhausted-429": "额度耗尽",
}


def probe_tail(entry, only=None):
    """按额度条口径: 全红 -> 不可用; 全 429/402 -> 写明; 否则 n/m 可用。

    only: 只统计 DSH 实际暴露的那些模型的探活（DSH 没有的模型不参与打分）。
    """
    if not entry:
        return ""
    details = [d for d in (entry.get("model_details") or [])
               if isinstance(d.get("probe"), dict)]
    if only:
        picked = [d for d in details if d.get("name") in only]
        if picked:
            details = picked
    probes = [d["probe"] for d in details]
    if not probes:
        return ""
    okn = sum(1 for p in probes if p.get("ok"))
    if okn:
        return "%d/%d 可用" % (okn, len(probes))
    statuses = {p.get("status") for p in probes}
    if statuses == {0}:
        return "未探活"
    if statuses == {429}:
        return "429 限流"
    if statuses == {402}:
        return "402 欠费"
    return "不可用"


def expiry_tail(entry):
    if not entry:
        return ""
    exp = entry.get("expires_at")
    if not exp:
        return ""
    try:
        now = datetime.datetime.now(datetime.timezone.utc).astimezone()
        dt = datetime.datetime.fromisoformat(str(exp))
        if dt < now:
            return "已过期"
        days = int((dt - now).total_seconds() // 86400)
        return "至%s(%d天)" % (dt.strftime("%m-%d"), days)
    except Exception:
        return ""


def extra_tail(dsh_id, keys, credit):
    if dsh_id == "deepseek-official":
        for k in (keys or {}).get("keys") or []:
            if k.get("name") == "deepseek-official":
                try:
                    bal = float(k.get("balance"))
                    if bal < 0.04:
                        return "余额 ¥0" if abs(bal) < 0.005 else "欠费"
                    return "余额 ¥%.2f" % bal
                except Exception:
                    return ""
    if dsh_id == "baizhi" and isinstance(credit, dict):
        rem = credit.get("remaining")
        if rem is not None:
            return "积分 %s" % rem
    return ""


def provider_models(text):
    """cordis.patch.yml 的 llm-pi-ai.providers.<id>.models[].id 集合。"""
    out = {}
    in_llm = in_prov = in_models = False
    cur = None
    for raw in text.splitlines():
        if re.match(r"^-\s+id:\s*llm-pi-ai\s*$", raw):
            in_llm = True
            continue
        if in_llm and re.match(r"^-\s", raw) and not re.match(r"^-\s+id:\s*llm-pi-ai\s*$", raw):
            break
        if not in_llm:
            continue
        if re.match(r"^\s{4}providers:\s*$", raw):
            in_prov = True
            continue
        if not in_prov:
            continue
        m = re.match(r"^\s{6}([A-Za-z0-9_.\-]+):\s*$", raw)
        if m:
            cur = m.group(1)
            out.setdefault(cur, set())
            in_models = False
            continue
        if re.match(r"^\s{8}models:\s*$", raw):
            in_models = True
            continue
        m = re.match(r"^\s{10}-\s+id:\s*(\S+)", raw)
        if m and in_models and cur:
            out[cur].add(m.group(1))
            continue
        if re.match(r"^\s{8}[A-Za-z_]", raw):
            in_models = False
    return out


def build_names(patch_text=None):
    tok = jload(P_TOKENS, {}) or {}
    entries = line_index(tok)
    keys = jload(P_KEYS, {}) or {}
    credit = jload(P_CREDIT, {}) or {}
    if patch_text is None:
        try:
            with open(P_PATCH, "r", encoding="utf-8", newline="") as f:
                patch_text = f.read()
        except Exception:
            patch_text = ""
    pmodels = provider_models(patch_text)
    out = {}
    for dsh_id, line_id in LINE_OF.items():
        base = BASE.get(dsh_id)
        if base is None:
            continue
        if dsh_id in SKIP_PROVIDERS:
            # 这两条由 magpie 工具自己维护写法，写了也会被它改回去 → 只留原名，避免反复写盘
            out[dsh_id] = base
            continue
        parts = [base]
        entry = entries.get(line_id) if line_id else None
        status = str((entry or {}).get("status") or "")
        if entry and not status.startswith("active"):
            parts.append(STATUS_TEXT.get(status, status[:12] or "不可用"))
        else:
            q = QUOTA.get(dsh_id)
            if q:
                parts.append(q)
            e = extra_tail(dsh_id, keys, credit)
            if e:
                parts.append(e)
            mine = pmodels.get(dsh_id) or set()
            p = probe_tail(entry, only=mine)
            if p:
                parts.append(p)
            x = expiry_tail(entry)
            if x:
                parts.append(x)
        out[dsh_id] = SUFFIX_SEP.join(parts)
    return out


NAME_RE = re.compile(r"^(\s{8}displayName:\s*)(.*?)(\r?\n)?$")
PROV_RE = re.compile(r"^(\s{6})([A-Za-z0-9_.\-]+):\s*(\r?\n)?$")


def rewrite_names(text, newnames):
    lines = text.splitlines(True)
    in_llm = False
    in_providers = False
    cur = None
    changed = []
    out = []
    for ln in lines:
        raw = ln.rstrip("\r\n")
        eol = ln[len(raw):]
        if re.match(r"^-\s+id:\s*llm-pi-ai\s*$", raw):
            in_llm, in_providers, cur = True, False, None
            out.append(ln)
            continue
        if in_llm and re.match(r"^-\s+id:\s*", raw):
            in_llm, in_providers, cur = False, False, None
        if in_llm and re.match(r"^\s{4}providers:\s*$", raw):
            in_providers = True
            out.append(ln)
            continue
        if in_providers:
            m = PROV_RE.match(raw)
            if m:
                cur = m.group(2)
                out.append(ln)
                continue
            m = NAME_RE.match(raw)
            if m and cur in newnames and m.group(2) != newnames[cur]:
                changed.append((cur, m.group(2), newnames[cur]))
                out.append(m.group(1) + newnames[cur] + eol)
                continue
            if re.match(r"^\s{0,4}[A-Za-z_\-]+:", raw) and not raw.startswith("      "):
                in_providers, cur = False, None
        out.append(ln)
    return "".join(out), changed


def apply_display(dry, verbose=True):
    with open(P_PATCH, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    names = build_names(text)
    new_text, changed = rewrite_names(text, names)
    if verbose:
        for pid, old, new in changed:
            print("  %-16s %s  ->  %s" % (pid, old, new))
    if not changed:
        if verbose:
            print("（没有需要改的显示名）")
        return 0
    if dry:
        if verbose:
            print("[dry] 待改 %d 个 provider" % len(changed))
        return 0
    bak = backup(P_PATCH)
    atomic_write(P_PATCH, new_text)
    ok, msg = yaml_ok(P_PATCH)
    if verbose:
        print(msg)
    if not ok:
        shutil.copy2(bak, P_PATCH)
        if verbose:
            print("已回滚: " + P_PATCH)
        return 2
    if verbose:
        print("写入 %s（备份 %s）" % (P_PATCH, os.path.basename(bak)))
    return len(changed)


# ---------------------------------------------------------------- 默认模型


def dsh_target(best):
    """台账 (线路, 模型) -> DSH (provider, model)；无对应返回 None。"""
    prov = DSH_PROVIDER.get(best.get("line"))
    if not prov:
        return None
    model = best.get("model")
    if prov == "magpie" and not str(model).startswith("opencode-zen/"):
        model = "opencode-zen/" + str(model)
    return prov, model


def dsh_usable(x):
    """这条候选线路 DSH 能不能用（有 provider 且不是 opencode 专属通道）。"""
    return bool(x) and x.get("line") in DSH_PROVIDER and x.get("line") not in DSH_UNUSABLE


def pick_for_dsh(pool):
    """在额度条排好序的候选里，挑第一条 DSH 真能用的。

    先免费/限时（pool 已按此排序），付费线路只在没有别的选择时才用。
    """
    usable = [x for x in pool if dsh_usable(x)]
    if not usable:
        return None
    free = [x for x in usable if not str(x.get("note") or "").startswith("DS") and
            x.get("line") != "deepseek-official"]
    return (free or usable)[0]


def apply_dsh_pool(pool, results):
    """select_model 用：从候选池里挑 DSH 能用的最佳线路并落盘。"""
    best = pick_for_dsh(pool)
    if best is None:
        results["dsh"] = {"ok": False, "why": "候选里没有 DSH 可用的线路，保持原默认模型"}
        return
    apply_dsh(best, results)
    if results.get("dsh", {}).get("ok"):
        results["dsh"]["line"] = best.get("line")


def _set_kv(line, key, value):
    m = re.match(r"^(\s*" + re.escape(key) + r":\s*)(.*?)(\r?\n)?$", line)
    if not m:
        return None
    return m.group(1) + value + (m.group(3) or "")


def set_default_model(text, provider, model):
    """在 cordis.patch.yml 的 agent-default-model 块里改 provider/model 两行。"""
    lines = text.splitlines(True)
    hit = None
    for i, ln in enumerate(lines):
        if re.match(r"^-\s+id:\s*agent-default-model\s*$", ln.rstrip("\r\n")):
            hit = i
            break
    if hit is None:
        return text, False, "未找到 agent-default-model 块"
    done = set()
    for j in range(hit + 1, min(hit + 6, len(lines))):
        if "provider" not in done:
            n = _set_kv(lines[j], "provider", provider)
            if n is not None:
                lines[j] = n
                done.add("provider")
                continue
        if "model" not in done:
            n = _set_kv(lines[j], "model", model)
            if n is not None:
                lines[j] = n
                done.add("model")
    if len(done) != 2:
        return text, False, "块里缺 provider/model 行"
    new_text = "".join(lines)
    return new_text, new_text != text, ""


def apply_dsh(best, results):
    """给 select_model / agent_model_router 调：把选中的线路写成 DSH 默认模型。"""
    tgt = dsh_target(best)
    if not tgt:
        results["dsh"] = {"ok": False, "why": "DSH 无对应 provider（线路 %s）" % best.get("line")}
        return
    provider, model = tgt
    if not os.path.isfile(P_PATCH):
        results["dsh"] = {"ok": False, "why": "配置文件不存在: " + P_PATCH}
        return
    with open(P_PATCH, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    if not re.search(r"(?m)^      " + re.escape(provider) + r":\s*$", text):
        results["dsh"] = {"ok": False, "why": "cordis.patch.yml 里没有 provider " + provider}
        return
    new_text, changed, why = set_default_model(text, provider, model)
    if why:
        results["dsh"] = {"ok": False, "why": why}
        return
    if changed:
        bak = backup(P_PATCH)
        atomic_write(P_PATCH, new_text)
        ok, msg = yaml_ok(P_PATCH)
        if not ok:
            shutil.copy2(bak, P_PATCH)
            results["dsh"] = {"ok": False, "why": msg + "（已回滚）"}
            return
    results["dsh"] = {"ok": True, "provider": provider, "model": model, "changed": changed}


def apply_from_selected(dry):
    sel = jload(P_SELECTED, {}) or {}
    line = sel.get("line")
    model = sel.get("model")
    if not line or not model:
        print("selected-line.json 里没有 line/model")
        return 1
    with open(P_PATCH, "r", encoding="utf-8", newline="") as f:
        text = f.read()
    tgt = dsh_target({"line": line, "model": model})
    if not tgt:
        print("线路 %s 在 DSH 没有对应 provider" % line)
        return 1
    provider, dm = tgt
    new_text, changed, why = set_default_model(text, provider, dm)
    if why:
        print(why)
        return 1
    print("selected-line: %s/%s  ->  DSH %s/%s%s" % (line, model, provider, dm,
                                                  "" if changed else "（已是这个，不动）"))
    if dry or not changed:
        return 0
    bak = backup(P_PATCH)
    atomic_write(P_PATCH, new_text)
    ok, msg = yaml_ok(P_PATCH)
    print(msg)
    if not ok:
        shutil.copy2(bak, P_PATCH)
        print("已回滚")
        return 2
    print("写入 %s（备份 %s）" % (P_PATCH, os.path.basename(bak)))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--apply-display", action="store_true")
    ap.add_argument("--apply-model", action="store_true")
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()
    if args.show:
        for k, v in sorted(build_names().items()):
            print("%-18s %s" % (k, v))
        return 0
    if args.apply_display:
        apply_display(args.dry)
        return 0
    if args.apply_model:
        return apply_from_selected(args.dry)
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
