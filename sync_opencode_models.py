# -*- coding: utf-8 -*-
"""
sync_opencode_models.py — ALEN 额度条 -> opencode.json 模型自动导入/清理 (zcode 2026-11-28)

数据源 (只读, 均为巡检产物):
  tokens/FREE-LINES-status.json  免费线路探活 (4.5h 巡检写)
  tokens/TOKENS.json             全量台账 (每日 09:00 台账巡检写)
  tokens/TOKEN-STATUS.json       key 鉴权巡检 (每日 09:05 写)
目标 (读改写):
  C:\\Users\\Administrator\\.config\\opencode\\opencode.json
  TokenMeter\\provider_registry.json  全量 provider 注册表: 被删线路的定义存档于此,
                                     状态恢复后自动重新导入 (含模型清单)

规则:
  1. 每条 opencode provider 映射一条台账线路 (LINE_MAP); 线路 ok/active 且未过期 -> 导入
  2. 线路 not-ok / blocked / removed / disabled / auth!=ok -> 从 opencode.json 删除
  3. 默认 model 所在线路被删时 -> 切到 recommended_order 首个可用线路的首个模型
  4. opencode 内置 provider (openai/groq/modelscope/qiniu) 不可用时挂 disabled_providers
  5. 严禁打印 key; 备份 opencode.json.bak_sync_* 保留最近 10 份; 无变化不写 (幂等)

用法:
  python sync_opencode_models.py                  # 单次同步
  python sync_opencode_models.py --dry            # 只报告不写
  python sync_opencode_models.py --quiet          # 只写日志文件
  python sync_opencode_models.py --interval 7200  # 循环模式, 每 7200s 一次
"""
import json, os, sys, glob
from datetime import datetime

TOKDIR   = r"D:\Backup\Documents\deepseek-harness\default-workspace\tokens"
TMDIR    = r"D:\Backup\Documents\deepseek-harness\TokenMeter"
OCJSON   = r"C:\Users\Administrator\.config\opencode\opencode.json"
REGISTRY = os.path.join(TMDIR, "provider_registry.json")
SYNCLOG  = os.path.join(TMDIR, "tokenmeter-sync.log")

# opencode provider -> (状态源, 线路键): free=FREE-LINES-status.lines / tokens=TOKENS.tokens[id]
LINE_MAP = {
    "free-amd":           ("free",  "amd"),
    "zhipu":              ("free",  "zhipu"),
    "opencode":           ("free",  "magpie"),         # magpie 线 = opencode 官方 zen 入口
    "scnet":              ("free",  "scnet-tokenplan"),
    "deepseek":           ("free",  "moma"),
    "tokenrouter":        ("free",  "tokenrouter"),
    "modelscope":         ("free",  "modelscope"),
    "apinex":             ("free",  "apinex"),
    "gitcode-codingplan": ("tokens", "gitcode-codingplan"),
    "baizhi":             ("tokens", "baizhi"),
    "deepseek-official":  ("tokens", "deepseek-official"),
    "groq":               ("tokens", "groq"),
    "qiniu":              ("tokens", "qiniu-conatus"),
    "magpie-zen":         ("tokens", "magpie-zen"),
}
# TOKEN-STATUS.json keys 键名与 provider 名不同者
TSTAT_KEY = {"deepseek": "moma", "qiniu": "qiniu", "qiniu-conatus": "qiniu",
             "deepseek-official": "deepseek-official"}
# opencode 内置 provider 名: 不可用时须挂 disabled_providers 才不在选择器出现
BUILTIN_SUPPRESS = {"openai", "groq", "modelscope", "qiniu"}
BAD_TOKENS_STATUS = ("removed", "blocked", "disabled", "not-purchased", "expired")


def log(msg, quiet=False):
    line = datetime.now().strftime("%Y-%m-%d %H:%M:%S ") + msg
    if not quiet:
        print(line)
    try:
        with open(SYNCLOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def expired(expires_at):
    if not expires_at:
        return False
    try:
        return datetime.fromisoformat(expires_at) <= datetime.now(expires_at.tzinfo)
    except Exception:
        return False


def line_available(provider):
    """返回 (available, reason)。状态源优先级: FREE-LINES > TOKENS > TOKEN-STATUS auth。"""
    src, key = LINE_MAP[provider]
    free = load_json(os.path.join(TOKDIR, "FREE-LINES-status.json")) or {}
    tokens = load_json(os.path.join(TOKDIR, "TOKENS.json")) or {}
    tstat = load_json(os.path.join(TOKDIR, "TOKEN-STATUS.json")) or {}

    if src == "free":
        info = (free.get("lines") or {}).get(key)
        if info is None:
            return False, "free 状态缺行"
        return bool(info.get("ok")), str(info.get("note", ""))[:60]
    else:
        info = next((t for t in tokens.get("tokens", []) if t.get("id") == key), None)
        if info is None:
            return False, "台账缺条目"
        st = str(info.get("status", ""))
        if any(st.startswith(b) for b in BAD_TOKENS_STATUS):
            return False, st
        if expired(info.get("expires_at")):
            return False, "已过 expires_at"
        # TOKENS 说 active -> 再核对鉴权巡检
        tkey = TSTAT_KEY.get(key, key)
        auth = next((k for k in tstat.get("keys", []) if k.get("name") == tkey), None)
        if auth is not None and str(auth.get("auth", "ok")).lower() not in ("ok", "true", "200"):
            return False, "auth " + str(auth.get("auth"))
        return True, st


def default_model_for(provider, defs):
    models = (defs.get(provider) or {}).get("models") or {}
    return (provider + "/" + list(models)[0]) if models else None


def sync(dry=False, quiet=False):
    oc = load_json(OCJSON)
    if oc is None:
        log("FATAL: opencode.json 读取失败", quiet)
        return 1
    providers = dict(oc.get("provider") or {})

    # 注册表: 当前定义优先并入 (先入库再删, 被删线路可自动恢复)
    reg = load_json(REGISTRY) or {"providers": {}}
    regp = reg.get("providers") or {}
    for name, defn in providers.items():
        regp[name] = defn

    keep, drop = {}, {}
    for name in LINE_MAP:
        if name in providers or name in regp:
            ok, why = line_available(name)
            if ok:
                keep[name] = providers.get(name) or regp.get(name)
            else:
                drop[name] = why
    # 未映射的自定义 provider 一律保留 (人工新增线路不受本工具管理)
    for name, defn in providers.items():
        if name not in LINE_MAP:
            keep[name] = defn

    new_disabled = []
    for name in BUILTIN_SUPPRESS:
        if name in drop or name not in keep:
            new_disabled.append(name)

    new_model = oc.get("model")
    cur_provider = (new_model or "").split("/")[0]
    if cur_provider and cur_provider not in keep:
        free = load_json(os.path.join(TOKDIR, "FREE-LINES-status.json")) or {}
        line2prov = {v[1]: k for k, v in LINE_MAP.items() if v[0] == "free"}
        for line in (free.get("recommended_order") or []):
            p = line2prov.get(line)
            m = default_model_for(p, keep) if p in keep else None
            if m:
                new_model = m
                log("默认线路被删, 默认模型切到 " + m, quiet)
                break

    changed = (keep != providers) or (new_model != oc.get("model")) \
        or (sorted(new_disabled) != sorted(oc.get("disabled_providers") or []))

    log("--- sync start (dry=%s) ---" % dry, quiet)
    for n, d in sorted(keep.items()):
        log("  导入 %s (%d 模型)" % (n, len((d or {}).get("models") or {})), quiet)
    for n, why in sorted(drop.items()):
        log("  删除 %s  [%s]" % (n, why), quiet)
    log("  默认模型: %s%s" % (new_model, "" if changed else " (无变化)"), quiet)

    if dry or not changed:
        log(changed and "DRY: 未写盘" or "无变化, 跳过写盘", quiet)
        return 0

    bak = OCJSON + ".bak_sync_" + datetime.now().strftime("%Y%m%d_%H%M")
    with open(OCJSON, "rb") as f:
        raw = f.read()
    bom = raw[:3] == b"\xef\xbb\xbf"
    with open(bak, "wb") as f:
        f.write(raw)

    out = dict(oc)
    out["provider"] = keep
    out["model"] = new_model
    out["disabled_providers"] = new_disabled
    data = json.dumps(out, ensure_ascii=False, indent=2)
    with open(OCJSON, "wb") as f:
        f.write(("\ufeff" if bom else "").encode("utf-8") + data.encode("utf-8"))
    # 写回后校验
    if load_json(OCJSON) is None:
        with open(OCJSON, "wb") as f:
            f.write(raw)  # 还原
        log("FATAL: 写后校验失败, 已还原备份", quiet)
        return 1
    # 清理旧备份, 保留 10 份
    baks = sorted(glob.glob(OCJSON + ".bak_sync_*"))
    for old in baks[:-10]:
        try:
            os.remove(old)
        except OSError:
            pass
    # 存注册表
    reg["providers"] = regp
    reg["saved_at"] = datetime.now().isoformat(timespec="seconds")
    with open(REGISTRY, "w", encoding="utf-8") as f:
        json.dump(reg, f, ensure_ascii=False, indent=2)
    log("opencode.json 已写入 (备份 " + os.path.basename(bak) + ")", quiet)
    return 0


def main():
    args = sys.argv[1:]
    dry = "--dry" in args
    quiet = "--quiet" in args
    interval = None
    if "--interval" in args:
        i = args.index("--interval")
        interval = int(args[i + 1])
    if interval:
        import time
        log("循环模式: 每 %ds 同步一次" % interval, quiet)
        while True:
            sync(dry, quiet)
            time.sleep(interval)
    return sync(dry, quiet)


if __name__ == "__main__":
    sys.exit(main())
