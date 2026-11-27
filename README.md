# ALEN 额度条 · TokenMeter

Windows 桌面悬浮条：把各条免费/付费模型线路的**剩余额度、剩余时间、探活状态**压成一根根小进度条，
常驻屏幕右下角，一眼看完。零依赖，纯 PowerShell 5.1 + WinForms。

```
◆ ALEN 额度条                          11 条线 · 18:20
● MoMA 移动云   ████████████░░░░   剩3天5h
● 七牛活动      ██░░░░░░░░░░░░░░   已到期·待巡检清
● AMD 云        ███░░░░░░░░░░░░░   12h 后重置
● 魔搭          ████████████████   长期免费
● 智谱          ██████████████░░   剩21天2h
...
```

## 功能介绍

额度条把散落在各厂商控制台里的「免费额度 / 剩余天数 / 密钥状态」集中到屏幕右下角一条悬浮窗里，
不用逐个登录网站查余额。适合同时持有多个免费模型线路、需要随时知道「哪条还能用、哪条快到期」的场景。

- **看额度**：每条线路一行进度条，剩余额度/天数/重置倒计时一眼可见；额度 0 标红「已用完」，探活失败标红「不可用」，低效能模型灰显「不启用」
- **看明细**：点线路行展开该线路下每个模型的额度/免费/已用完状态，再点收起
- **自动选线**：启动时按「可用 + 高分档（S>A>B）+ 低延迟」挑一条最优线路，自动写入 opencode / hermes / ZCode；可锁定不自动切换
- **到期提醒**：key 剩 ≤7 天每天弹一次提醒（当天只弹一次），过期的线路自动踢出候选
- **百智云积分**：控件内手动设置积分快照，并可复用已登录 Edge 自动点「每日领积分」
- **零依赖**：纯 PowerShell 5.1 + WinForms 单文件，UTF-8 BOM，带 `-STA` 后台运行，不占任务栏

## 特性

- **每线路一行**：状态点（绿/橙/红/灰）+ 名称 + 额度条 + 右侧说明（剩余天数/小时、重置倒计时、错误原因）
- **点线路展开模型明细**（v1.1.0）：点一下线路行 → 展开该线路每个模型的剩余额度/免费/已用完/不启用；再点收起；右键可「全部展开 / 全部收起」
- **低效能模型灰显**：按 S/A/B/C 分档，C 档默认标「不启用」，可查但不参与使用
- **三种数据源合并**：台账（额度/到期）+ 线路巡检（探活）+ 钥匙巡检（401/余额）
- **自动刷新**：默认 120 秒；右键「立即刷新」
- **百智云每日领积分**：标题栏「✓积分 / 领积分」小按钮或右键「百智每日领积分」→ 复用已登录 Edge 窗口自动点「每日领积分 +100」；成功后写 `tokens/baizhi-credits.json` 与 `tokens/baizhi-daily-claim.json`。启动时和每 30 分钟后台检查一次，当天成功领过自动跳过；站点弹验证码时会把浏览器切到前台并提示人工完成
- **自动选可用线路**：控件启动时后台按「可用 + 高分档 + 低延迟」挑一条线路，写 opencode / hermes / ZCode；当前线路行标「当前 ·」
- **key 到期自动踢出候选**：台账 `expires_at` 过期的线路不再被自动选中（如 TokenRouter 免费 key 30 天）
- **无边框可拖动**：左键按住任意位置拖动；右键菜单可置顶开关、打开台账目录、退出
- **单实例**：互斥锁 `ALENTokenMeterMutex`，重复启动自动退出
- **不占任务栏**：`ShowInTaskbar = false`，贴右下角工作区

## 运行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File .\TokenMeter.ps1
```

或直接：

```powershell
.\start.ps1     # 后台隐藏启动
.\stop.ps1      # 退出
```

> **必须带 `-STA`**（WinForms 剪贴板/ToolTip 需要单线程单元），**脚本必须保存为 UTF-8 BOM**，
> 否则 PowerShell 5.1 会按 GBK 解析中文注释而报错。

## 数据源

默认读 `D:\Backup\Documents\deepseek-harness\default-workspace\tokens\`，可用环境变量覆盖：

```powershell
$env:TOKENS_DIR = 'D:\my\tokens'
```

三个文件（缺哪个就跳过对应信息，不报错）：

### 1. `TOKENS.json` — 台账（必需）

| 字段 | 说明 |
|---|---|
| `tokens[].id` | 线路 id，内置短名映射见脚本 `$shortNames` |
| `tokens[].provider` | 供应商全名，鼠标悬停提示 |
| `tokens[].expires_at` | ISO 到期时间；有则画倒计时条 |
| `tokens[].expiry_rule` | 到期规则说明（提示用） |
| `tokens[].quota_official` | 官方额度说明（提示用） |
| `tokens[].verified_at` | 最近实测时间（提示用） |
| `tokens[].status` | 状态标记 |

特殊线路有专门分支：`deepseek-official`（读余额）、`free-amd`（每日重置倒计时）、
`groq` / `openai-gemini`（代理禁用）、`scnet-maas`（待建 key）。

### 模型明细 `model_details`（v1.1.0，可选）

每个线路可带 `model_details`，展开后逐模型显示：

```json
"model_details": [
  { "name": "glm-4-flash",  "tier": "C", "usable": true,
    "quota": { "unit": "free" }, "note": "免费档 200 OK" },
  { "name": "glm-4.5-air",  "tier": "B", "usable": false,
    "quota": { "remaining": 0, "total": 12000000, "unit": "tokens" },
    "note": "赠送包已用完（429/1113）" }
]
```

| 字段 | 说明 |
|---|---|
| `name` | 模型名（过长会截断，悬停看全名） |
| `tier` | `S` 旗舰 / `A` 强 / `B` 主力 / `C` 小模型 |
| `usable` | `false` → 灰显「不启用」；缺省按线路状态判断 |
| `quota.unit` | `free`（免费）/ `tokens`（带 total+remaining）/ 省略（共享池） |
| `note` | 悬停提示 |

显示规则：

| 情况 | 右侧文字 | 颜色 |
|---|---|---|
| `usable=false` 且额度为 0 | **已用完** | 红 |
| `usable=false` 其他 | **不启用** | 灰 |
| `unit=free` | **免费** | 绿 |
| 有 `remaining/total` | **剩 1200万**（按比例画条） | 绿/橙/红 |
| 无模型级额度 | **共享池** | 绿 |

> 现实限制：只有智谱的资源包能按模型查到余额（控制台），其余厂商是线路共享池
> （每日调用数 / 积分 / 余额），所以模型行只写「共享池」。台账里的数字由巡检/人工更新。

### 百智云积分（baizhi）

- `TOKENS.json` 的 `baizhi.credits` 是控制台快照（`remaining` / `checked_at` / `source`）。
- 控制台积分只认网页登录态，API key 调积分接口一律 401，因此暂不自动抓取。
- 手动更新：右键控件 →「设置百智云积分…」，或直接编辑 `tokens/baizhi-credits.json`
- 自动领取：`baizhi_daily.ps1`（UIA 点按钮，不用 key/密码），状态在 `baizhi-daily-claim.json`；`ok=true` 才算当天领过，脚本会比对积分是否增加或页面是否出现「领取成功」
- 验证码：点位型验证码无法可靠自动通过；脚本等待 15 秒后若仍在验证，会把浏览器切前台、写 `need_captcha=true`，控件显示「待验证」
  （格式 `{"remaining":100,"checked_at":"...","source":"..."}`）；该文件存在时优先于台账快照。

### TokenRouter 免费线路（tokenrouter）

- 2026-11-27 接入，模型 `deepseek/deepseek-v4.1-flash-1017-free`（**结尾必须带 `-free`**）
- Base URL `https://api.tokenrouter.com/v1`，OpenAI 兼容；输入/输出标 0 价，免费算力有限
- key 有效期 **30 天**：台账 `expires_at = 2026-12-27T00:00:00+08:00`
- 控件显示「剩X天」，剩 2 天内转红；`select_model.py` 到期后直接把它踢出候选
- 换 key：更新 `opencode.json#provider.tokenrouter.options.apiKey`、
  `hermes config.yaml` 里 `api.tokenrouter.com` 那条 `api_key`、台账 `expires_at`
- 同 key 还有 `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` 等免费模型

根级 `model_policy` 记录分档规则与例外（例如 `keep: ["glm-4-flash"]`：C 档但保留可用）。

### 2. `FREE-LINES-status.json` — 线路巡检（可选）

```json
{ "lines": { "amd": { "ok": true }, "moma": { "ok": false } } }
```

`ok=false` 时该行状态点转橙、右侧加「上游断 / 探活失败」。

### 3. `TOKEN-STATUS.json` — 钥匙巡检（可选）

```json
{ "keys": [ { "name": "deepseek-official", "auth": "401", "balance": "¥-0.03" } ] }
```

`auth=401` → 状态点转红、右侧显示「key 401」。

## 状态色

| 颜色 | 含义 |
|---|---|
| 绿 | 正常；剩余比例 > 30% 且 > 2 天 |
| 橙 | 剩余 ≤ 30% 或 ≤ 2 天；或上游探活失败 |
| 红 | 已到期 / key 401 / 余额为负 |
| 灰 | 长期免费或已禁用线路 |

## 开机自启

`Win+R` → `shell:startup`，新建快捷方式：

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "D:\...\TokenMeter.ps1"
```

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 启动即退出，无窗口 | 看同目录 `tokenmeter.log`；`already running - exit` 说明已有实例 |
| 中文乱码或解析报错 | 文件不是 UTF-8 BOM，另存为「UTF-8 带 BOM」 |
| 窗口跑到屏幕外 | 分辨率/缩放变化后重启一次，窗口按工作区重新定位 |
| 所有条都是灰的 | 台账文件路径不对或 JSON 解析失败；右键「打开台账目录」核对 |
| 点线路没展开 | 按住移动超过 4px 会当拖动窗口；轻点一下即可 |
| 展开后看不全 | 窗口高度自动封顶到工作区高度，面板内出现滚动条 |
| 模型全显示「共享池」 | 该线路没有按模型额度接口，只有线路级共享额度 |

## 模型探活（probe_models.py）

```powershell
python probe_models.py               # 每个模型发一条最小请求，结果写回 TOKENS.json
python probe_models.py --dry-run     # 只打印，不写
python probe_models.py --only zhipu  # 只探一条线路
python probe_models.py --timeout 120 # 慢线路（GitCode 冷启动 ~38s）
```

- 读 `TOKENS.json.model_details` + `opencode.json` 的 baseURL/apiKey（zhipu 回退 `CHATGPT_API_KEY`，DS 官方回退 `DEEPSEEK_API_KEY`）
- 写回 `model_details[].probe = {at, ok, status, ms, error}`，并重算 `usable`
  （`usable = probe.ok`，但 C 档且不在 `model_policy.keep` 里仍为 false）
- 探活线程池默认 5，单条超时 30s；失败是数据不是异常，退出码始终 0

**2026-11-25 23:37 全量结果（27 个模型，8 个 200）**

| 线路 | 可用 | 说明 |
|---|---|---|
| MoMA 移动云 | 3/3 | 全部 200（829ms–1.7s），流式/非流式都通 |
| 七牛活动 | 0/1 | `model_not_found`：conatus-free 已没有可用通道 |
| AMD 云 | 3/5 | GLM-5.3-Flash / MiMo-V2.6-Flash / Gemma-4-31B-IT 200；V4.1-Flash 429 满载，Qwen3.8-Flash-Next 404 |
| 魔搭 | 0/4 | 全部 429 `insufficient balance` |
| 智谱 | 1/3 | glm-4-flash 200；4.5-air / 4.6v 429/1113 余额不足 |
| Magpie Zen | 0/7 | 全部 429 `Free usage limit reached` |
| SCNet 套餐 | 1/1 | 200 |
| DS 官方 | 0/2 | 402 余额为负 |
| GitCode Lite | 2/2 | 200，但冷启动约 38s（默认 30s 超时会误判） |

**智谱上下文实测（2026-11-25 23:47）**：glm-4-flash 在 114k / 131k prompt tokens 下均 200，
多轮 60k + 流式 + tools 也 200。客户端报「token expired or incorrect」不是智谱返回的（同 key 直连 200），
应查客户端模型 id / key 注入。

## 自动选可用线路（select_model.py）

控件启动时在后台跑 `select_model.py --apply --quiet`，不阻塞界面；约 25 秒后自动刷新一次。

**挑选规则**：候选必须线路 `status=active`、模型 `usable=true`、非 C 档（`model_policy.keep` 例外）；
应用前再做一次**实时探活**（HTTP 200 才算可用，最多探前 8 个），并按 `S > A > B > C` → 有实测 → 延迟低 排序。
DS 官方会先查 `/user/balance`，`is_available=false` 或余额 < ¥0.04 直接排除。

**写入的 agent**：

| agent | 写哪里 | 说明 |
|---|---|---|
| opencode | `~/.config/opencode/opencode.json` 的 `model` | 形如 `deepseek/deepseek-v4.1-flash` |
| DSH 桌面端 | 同上 | 驱动同一份 opencode 配置 |
| hermes | `%LOCALAPPDATA%\hermes\config.yaml` 的 `model.provider/default` | 仅限映射表里有的线路，否则跳过 |
| ZCode | `~/.zcode/v2/provider_config.json` 的 `providerOrder` | ZCode 运行时不写（会被内存态覆盖） |

**手动控制**（右键菜单）：

- `当前线路: …` — 点击复制
- `重新选择可用线路` — 立即重跑（同步，约 10–20 秒）
- `锁定/解锁自动切换` — 写 `tokens/model-lock.json`；锁定时启动不再自动改配置

```powershell
python select_model.py --dry     # 只看会选谁
python select_model.py --apply   # 实时探活并写入
python select_model.py --apply --no-live   # 只用台账快照（快）
```

结果落在 `tokens/selected-line.json`（谁、何时、选了什么、各 agent 落地情况）。

> 注意：opencode 自带「模型故障回退」，某条线路报错时会把全局 `model` 改回可用的旧线路
> （会在同目录留下 `opencode.json.bak_fallback_*`）。控件的启动重选/手动重选就是用来纠偏的；
> 若希望完全不让控件改，右键「锁定自动切换」。

## 文件

| 文件 | 用途 |
|---|---|
| `TokenMeter.ps1` | 主程序 |
| `probe_models.py` | 全模型探活，结果写回台账 |
| `start.ps1` / `stop.ps1` | 后台启动 / 退出 |
| `meter.ico` | 图标 |
| `_mkicon.py` | 图标生成脚本（可选） |
| `samples/` | 三个数据文件的示例骨架 |

## License

MIT
