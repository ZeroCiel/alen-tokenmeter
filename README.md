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

## 特性

- **每线路一行**：状态点（绿/橙/红/灰）+ 名称 + 额度条 + 右侧说明（剩余天数/小时、重置倒计时、错误原因）
- **点线路展开模型明细**（v1.1.0）：点一下线路行 → 展开该线路每个模型的剩余额度/免费/已用完/不启用；再点收起；右键可「全部展开 / 全部收起」
- **低效能模型灰显**：按 S/A/B/C 分档，C 档默认标「不启用」，可查但不参与使用
- **三种数据源合并**：台账（额度/到期）+ 线路巡检（探活）+ 钥匙巡检（401/余额）
- **自动刷新**：默认 120 秒；右键「立即刷新」
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

## 文件

| 文件 | 用途 |
|---|---|
| `TokenMeter.ps1` | 主程序 |
| `start.ps1` / `stop.ps1` | 后台启动 / 退出 |
| `meter.ico` | 图标 |
| `_mkicon.py` | 图标生成脚本（可选） |
| `samples/` | 三个数据文件的示例骨架 |

## License

MIT
