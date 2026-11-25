#!/usr/bin/env python3
"""Probe every model in TOKENS.json and write the result back.

Reads tokens/TOKENS.json (model_details) + opencode.json (base_url / api key),
sends one tiny chat completion per model, then writes into each model_detail:

    "probe": {"at": "...", "ok": true, "status": 200, "ms": 830, "error": ""}

and recomputes "usable":
    usable = probe.ok and not (tier == "C" and name not in model_policy.keep)

Usage:
    python probe_models.py                 # probe + write TOKENS.json
    python probe_models.py --dry-run       # probe only, print table
    python probe_models.py --timeout 30
    python probe_models.py --only zhipu    # one provider id

Env:
    TOKENS_DIR          directory of TOKENS.json (default: ../tokens next to this file)
    OPENCODE_CONFIG     path to opencode.json (default: ~/.config/opencode/opencode.json)
    HTTP_PROXY / PROBE_PROXY   proxy for remote calls, e.g. http://127.0.0.1:7790

Exit code: 0 always (a failed model is data, not an error).
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

# provider id in TOKENS.json -> provider id in opencode.json (+ env fallback for the key)
PROVIDER_MAP = {
    'moma-deepseek': ('deepseek', None),
    'qiniu-conatus': ('qiniu', None),
    'free-amd': ('free-amd', None),
    'modelscope': ('modelscope', None),
    'zhipu': ('zhipu', 'CHATGPT_API_KEY'),
    'magpie-zen': ('magpie-zen', None),
    'opencode-zen-builtin': (None, None),
    'deepseek-official': ('deepseek-official', 'DEEPSEEK_API_KEY'),
    'scnet-tokenplan': ('scnet', None),
    'scnet-maas': (None, None),  # no generic sk- key yet
    'gitcode-codingplan': ('gitcode-codingplan', None),
    'openai-gemini': (None, None),
    'scnet-token-plan': (None, None),
}

SKIP_PIDS = {'scnet-token-plan'}  # not purchased


def load_json(path):
    with open(path, 'rb') as f:
        return json.loads(f.read().decode('utf-8-sig'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--timeout', type=int, default=30)
    ap.add_argument('--only', default='')
    ap.add_argument('--prompt', default='只回复两个字：在线')
    ap.add_argument('--workers', type=int, default=5)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    cands = [
        os.environ.get('TOKENS_DIR'),
        os.path.join(os.path.dirname(here), 'tokens'),
        os.path.join(os.path.dirname(here), 'default-workspace', 'tokens'),
        os.path.join(here, 'tokens'),
    ]
    tokens_dir = next(
        (c for c in cands if c and os.path.exists(os.path.join(c, 'TOKENS.json'))),
        os.path.join(os.path.dirname(here), 'tokens'))
    tok_path = os.path.join(tokens_dir, 'TOKENS.json')
    cfg_path = os.environ.get(
        'OPENCODE_CONFIG',
        os.path.join(os.path.expanduser('~'), '.config', 'opencode', 'opencode.json'))

    ledger = load_json(tok_path)
    cfg = load_json(cfg_path) if os.path.exists(cfg_path) else {}
    provs = cfg.get('provider', {}) or {}

    proxy = os.environ.get('PROBE_PROXY') or os.environ.get('HTTPS_PROXY') or os.environ.get('HTTP_PROXY') or ''
    if proxy and not proxy.startswith('http'):
        proxy = 'http://' + proxy

    keep = set((ledger.get('model_policy') or {}).get('keep') or [])

    tasks = []
    for t in ledger.get('tokens', []):
        pid = t['id']
        if pid in SKIP_PIDS:
            continue
        if args.only and pid != args.only:
            continue
        cfg_name, env_key = PROVIDER_MAP.get(pid, (pid, None))
        p = provs.get(cfg_name) if cfg_name else None
        if not p:
            continue
        opts = p.get('options', {}) or {}
        api_key = opts.get('apiKey') or (os.environ.get(env_key, '') if env_key else '')
        if not api_key:
            continue
        base = (opts.get('baseURL') or t.get('base_url') or '').rstrip('/')
        if not base:
            continue
        url = base + '/chat/completions'
        for md in (t.get('model_details') or []):
            tasks.append({
                'pid': pid, 'name': md.get('name', ''),
                'url': url, 'key': api_key,
                'local': '127.0.0.1' in base or 'localhost' in base,
            })

    if not tasks:
        print('no probeable models found')
        return 0

    def probe(task):
        body = json.dumps({
            'model': task['name'],
            'messages': [{'role': 'user', 'content': args.prompt}],
            'max_tokens': 12,
            'stream': False,
        }).encode()
        req = urllib.request.Request(task['url'], data=body, method='POST')
        req.add_header('Authorization', 'Bearer ' + task['key'])
        req.add_header('Content-Type', 'application/json')
        if proxy and not task['local']:
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({'http': proxy, 'https': proxy}))
        else:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        t0 = time.time()
        try:
            with opener.open(req, timeout=args.timeout) as r:
                d = json.loads(r.read().decode('utf-8', 'ignore'))
                reply = ''
                try:
                    reply = (d['choices'][0]['message'].get('content') or '').strip()
                except Exception:
                    pass
                return task, True, r.status, int((time.time() - t0) * 1000), reply.replace('\n', ' ')[:40], ''
        except urllib.error.HTTPError as e:
            raw = e.read().decode('utf-8', 'ignore')
            code, msg = '', raw[:200]
            try:
                j = json.loads(raw)
                err = j.get('error', j)
                if isinstance(err, dict):
                    code = str(err.get('code') or err.get('type') or '')
                    msg = str(err.get('message') or msg)
            except Exception:
                pass
            return task, False, e.code, int((time.time() - t0) * 1000), '', (code + ' ' + msg).strip()[:160]
        except Exception as e:
            return task, False, 0, int((time.time() - t0) * 1000), '', f'{type(e).__name__}: {e}'[:160]

    results = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as ex:
        futs = [ex.submit(probe, t) for t in tasks]
        for f in as_completed(futs):
            results.append(f.result())

    order = {t['name']: i for i, t in enumerate(tasks)}
    results.sort(key=lambda r: order.get(r[0]['name'], 999))

    now = time.strftime('%Y-%m-%dT%H:%M:%S+08:00')
    by_pid = {}
    for task, ok, status, ms, reply, error in results:
        by_pid.setdefault(task['pid'], []).append((task['name'], ok, status, ms, error))
        flag = 'OK ' if ok else 'ERR'
        print(f"{flag} {task['pid']:<20} {task['name']:<48} {ms:>5}ms {status:>3}  {reply or error}")

    if args.dry_run:
        print('dry-run: TOKENS.json not written')
        return 0

    for t in ledger.get('tokens', []):
        rows = by_pid.get(t['id'])
        if not rows:
            continue
        map_rows = {r[0]: r for r in rows}
        for md in (t.get('model_details') or []):
            r = map_rows.get(md.get('name', ''))
            if not r:
                continue
            _, ok, status, ms, error = r
            md['probe'] = {'at': now, 'ok': ok, 'status': status, 'ms': ms, 'error': error}
            tier_off = (md.get('tier') == 'C' and md['name'] not in keep)
            md['usable'] = bool(ok) and not tier_off
            if not ok and error and 'model_not_found' in error:
                md['note'] = '模型不存在/已下线（model_not_found）'
        okn = sum(1 for r in rows if r[1])
        t['verified_at'] = time.strftime('%Y-%m-%d %H:%M') + f' 探活 {okn}/{len(rows)} 可用'
        t['last_probe'] = {'at': now, 'ok': okn, 'total': len(rows)}

    ledger['updated_at'] = now
    data = json.dumps(ledger, ensure_ascii=False, indent=2).encode('utf-8')
    with open(tok_path, 'wb') as f:
        f.write(data)
    print(f'written {tok_path} ({len(data)} bytes)')
    return 0


if __name__ == '__main__':
    sys.exit(main())