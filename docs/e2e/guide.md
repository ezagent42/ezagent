# 测试全流程的流程(人肉 E2E 记录指南)

> 这份 guide 定义**你怎么操作、我怎么记**,以及每条 `scenario-<no>.md` 的取证、命名、判定规范。
> 索引和黄金路径清单在 [`README.md`](./README.md)。

---

## 1. 角色分工

| 角色 | 谁 | 做什么 |
|---|---|---|
| **操作员** | zyli(你) | 真实点 UI / 敲命令,口述每一步在做什么、看到了什么 |
| **记录员** | Claude(我) | 实时把你的操作写进 `scenario-<no>.md`,抓证据、归档截图、回填判定与状态表 |

**节奏**:你做一步 → 告诉我"我点了 X,看到 Y"(或贴截图)→ 我追加一条执行记录行 + 归档证据 → 进入下一步。
一条 scenario 跑完 → 我回填实测结果、判定、`README.md` 状态表,并提示是否 commit。

---

## 2. 全流程总览(黄金路径)

```
01 登录 ─→ 02 创建 agent ─→ 03 建 session+加成员 ─→ 04 echo 往返
                                                       │
        ┌──────────────────────────────────────────────┤  (逐个 agent flavor 接入同一 session)
        ▼              ▼                ▼
   05 cc 往返     06 codex 往返    07 curl/deepseek 往返
        └──────────────┬─────────────────┘
                       ▼
              08 @mention 门控路由
                       ▼
              09 跨 session mention 被拒(负路径)
                       ▼
              10 绑定 Feishu chat↔session(出站:session 回包镜像到 Feishu)
                       ▼
              11 Feishu 入站到达 → 路由到 agent(外部 channel → dispatch)
                       ▼
              12 dispatch 审计核对(收口:DB/审计行兜底证明前面都真发生了)
```

- **顺序硬约束**:01→02→03 必须先跑(登录态 → 有 agent 可加 → session+成员是后续前置)。04~07 可任意顺序但都依赖 03。08 依赖至少 2 个成员。10→11 依赖 Feishu sidecar(出站先通才验入站)。12 最后跑,用审计行交叉验证前 11 条。
- **每条都对应一个设计场景**(`docs/scenarios/NN`)——执行前先读对应设计场景的"预期结果/失败模式",照着验。**02 创建 agent 当前无设计场景**(`docs/scenarios` 缺位)——按 world UI 实际流程跑,并把它当成候选补一条设计场景。

---

## 3. 环境前置(每次开测先确认)

| 项 | 值 | 备注 |
|---|---|---|
| Phoenix HTTP | `http://localhost:10042`(或 Tailscale `http://100.64.0.27:10042`) | `PORT` 可覆盖 |
| **World 操作员 UI** | `http://world.localhost:10042` | host-routed;**别用** `world.ezagent.chat`(HSTS 升级成 HTTPS 会白屏) |
| 登录/注册 | `http://localhost:10042/login`、`/register` | host-agnostic |
| 公开 customer 页 | `http://localhost:10042/socialware/customer?session_uri=<enc>` | `public_view` session 免登录 |
| Health | `GET /_health` → 200 | 起没起先探这个 |
| Action 目录 | `GET /api/v1`(JSON,106 路由) | 排错用 |
| **world seed admin** | `admin@ezagent.chat` / `worlddev` | world E2E seed 后(见下) |
| 共享 stack admin | `entity://system/user/admin` / `e2e-admin-2026` | 登录用户名栏填**完整 URI** |
| 默认 workspace | `workspace://system` | `workspace://default` 是禁用别名 |

**启动**(server 没跑时):按 `docs/guide/world-e2e-seed.md` 起 PG → seed → `mix phx.server`。
**自助凭据**:卡密码就自己 mint,别等 Allen —— `mix ezagent.user.token entity://system/user/admin --mint` 然后 `set_password`(见 scenarios/README §1.1)。

每条 scenario 头部都要记下**当次实际**的:commit hash、分支、server URL、执行时间。

---

## 4. 取证规范(硬规则)

> 沿用 `feedback_esr_e2e_standards`:触及 UI / Feishu 的 E2E,**必须** agent-browser 截图。仅看日志**不算签收**。

1. **主证据 = agent-browser 截图**(headless Chrome 对 LiveView)。每个关键步骤(登录成功、session 创建、消息往返、路由命中/被拒)至少一张。
2. **辅助证据**:CLI/curl 原始输出贴进代码块;关键 SQL/审计行(`invocations` 表)在 09 收口时抓。
3. **不算数的**:cc-openclaw 自己的 Feishu DM 不计;只有 ezagent sidecar 的回复算。纯日志截图不算 UI 签收。
4. **截图存放**:`docs/e2e/evidence/scenario-NN/`,命名见 [`evidence/README.md`](./evidence/README.md)。
5. **React 岛注意**(见 `world_react_island_form_submit_swallowed` 记忆):world 里 `phx-update=ignore` 岛内原生 form submit 会被 LiveView 吞,取证时若遇"点了没反应",用 `onClick + form.submit()` 绕过,并在记录里标注。

---

## 5. 一条 scenario 的生命周期

```
⬜ pending          复制 template,填头部元信息 + 前置 + cross-ref
   ↓ 你开始操作
🔧 executing        每步追加一行:操作 | 实际观察 | 证据链接 | 单步判定
   ↓ 跑完
🟩/🟥/🟨 判定       回填"实测 vs 预期"、遗留/bug、证据清单
   ↓
回填 README 状态表 + 进度汇总 + 提示 commit
```

**记录粒度**:执行记录表一行 = 一个可观察动作。宁可细不可粗 —— 别人照着这张表能复现。

---

## 6. 判定标准

| 判定 | 含义 |
|---|---|
| 🟩 **PASS** | 实测结果 == 设计场景预期,关键步骤都有截图证据,无未解释偏差 |
| ⚠️ **PASS-with-gaps** | 主路径过了,但有非阻塞瑕疵(UI 小问题、缺失败模式覆盖),已在"遗留"列明 |
| 🟥 **FAIL** | 关键步骤结果 != 预期,且不是前置问题。必须附:复现步骤 + 证据 + 初判根因 |
| 🟨 **BLOCKED** | 被前置 scenario 失败 / 已知 bug(如 F5)/ 环境问题卡住,没法判 PASS/FAIL。注明阻塞源 |

FAIL/BLOCKED **不要**自己改代码"修"掉 —— 按 CLAUDE.md grill 文化:记 issue、标证据、暂停等 Allen。

---

## 7. 收尾约定

- 一条跑完:回填该 `scenario-NN.md` 末尾 + `README.md` 状态表那一行 + 进度汇总。
- 一轮(多条)跑完:`docs(e2e): <范围> 执行记录(NN..MM)` 提交(证据截图一并入库)。
- 发现的 bug:在该 scenario 的"遗留/bug"区记清,必要时新建 `docs/scenarios/` 的 open-bug 交叉引用,**不在执行层修设计**。

---

## 8. 自动化运行约定(agent-browser runbook)

> 上面 §1-§7 是**人肉执行记录**规范(zyli 操作、Claude 记录)。本节定义另一条腿:**让一个拿 agent-browser 的 agent 不靠人、照着 scenario 末尾的「自动化运行」节自动重放**。
> 两层不互斥:人肉记录留 bug 发现与判定的叙事价值;自动化 runbook 给确定性可重放的回归资产。每条 scenario 文件同时承载两者(人肉记录在前、`## 自动化运行(agent-browser runbook)` 节在后)。

### 8.1 确定性环境入口(每次自动跑前先建干净基线)

人肉记录会夹带"上一次跑剩下的状态"(stale agent `r2-*`、特定 commit)。自动化**不依赖累积态**——每次从干净 seed 起:

```bash
# 1. PG(Windows 宿主 mirrored WSL → 127.0.0.1:5432)
bin/dev-pg                                   # 起 PG 服务(若没跑)
# 2. 迁移 + seed(core seed + world E2E seed)
mix ecto.migrate
mix run scripts/world_e2e_seed.exs           # 详见 docs/guide/world-e2e-seed.md
# 3. server 后台启(前台 mix phx.server 会被信号杀,见记忆 ezagent-e2e-runtime-recipe)
mix phx.server &                             # 或 iex -S mix phx.server
# 4. 探活
curl -fsS http://localhost:10042/_health     # → 200 才继续
```

- **seed 后干净基线**(实地核实):agent `claude-bot`(cc)、`py_default`(py)等;session `feishu-bing` 等。**注意 echo flavor 已退役并入 py**(#1011),flavor 下拉现为 `[cc, cc-headless, codex, codex-remote, curl, hello_builder, native, np, py]`。**runbook 自建的实体**用带 `e2e-` 前缀的确定性名字(如 `e2e-py`/`e2e-test-1`),跑完可清理,不污染基线。
- **运行顺序**:scenario 01→12 **按编号顺序**自动跑(登录态/agent/session/成员名册逐步累积,是设计而非偶然);每条 scenario 的「自动化运行」节头部 `前置(自动化)` 列出它假设已建立的最小态(哪条 scenario 已跑 / 或可独立建)。

### 8.2 agent-browser 交互约定(world UI 专属坑——不知道这些必然跑不通)

| 坑 | 现象 | 自动化对策 |
|---|---|---|
| **base URL** | 用 `world.ezagent.chat` → HSTS 升 HTTPS 白屏 | 永远用 `http://world.localhost:10042`(host-routed) |
| **React 受控 input** | 直接 `el.value = x` React 不识别,提交空值 | 用 **native setter** 填值 + 派发 `input` 事件(见下 snippet) |
| **React 岛 form 提交** | `phx-update="ignore"` 岛内 form;`button.click()` 不一定触发 React onSubmit | **实地核实有效**:native-setter 填值 + 派发 `input`/`change` → `form.requestSubmit(btn)`。提交结果看 `#world-root` 的 **`data-last-dispatch`**(`ok`/`idle`=成功,`error:<reason>`=后端拒绝) |
| **@mention 必须走 autocomplete** | **native-setter 硬塞 `@name` 文本不生成结构化 mention → 不 dispatch 到 agent(发出去成普通文本,无人回)** | **实地核实**:用 agent-browser **真实键盘** `keyboard type '@py'` → 等 `ul[role=listbox]` 过滤 → `click 'ul[role=listbox] button'` 插入 mention → `keyboard type ' payload'` → `press Enter`。**别用 native-setter 设 textarea** |
| **邀请成员要完整 URI** | `#world-invite-input` 填裸名 `e2e-x` → `error:bad_member_uri` | 填 **完整 URI** `entity://system/agent/<name>` |
| **~~session 模板默认 `advisor` 无效~~(已解决)** | ~~New session 不选模板 → 默认 `advisor` → `error:{:invalid_template, "class"=>"session.advisor"}`~~ | **已修**:`chore/retire-session-advisor` 删除 advisor plugin,下拉不再有 `advisor`,选项为 `default/generic/hello`,默认 `default` 直接可建 |
| **py flavor 建不出(缺脚本)** | New Agent 选 `py` 提交 → `error:missing_script`(表单不提供脚本入口) | 零配置可建的 flavor:**`native`/`np`/`hello_builder`**;**但这些不回显聊天**——会回显的是 seeded `py_default`(py+echo.py)。详见各 scenario 与「产品缺口」 |
| **session 详情入口** | 直接 `/admin/sessions/<uri>/...` → **404** | 走 Sessions 列表行 "Open" → `/sessions?session=<encoded-uri>`(URI 需 encodeURIComponent) |
| **LiveView 异步渲染** | 立即断言 → 元素还没 mount,误判 FAIL | 每个 assert 前 **wait-for** 目标元素出现 + 适当 settle(React hydrate 比 SSR `data-*` 晚) |

React 受控 input/select 填值 snippet(agent-browser `eval`,**表单字段用此;聊天 mention 用真实键盘**):

```js
// 用 native setter 绕过 React 的 value 拦截,再派发事件让 React onChange 收到。input 用 'input',select 用 'change'。
const proto = el.tagName === 'SELECT' ? window.HTMLSelectElement.prototype : window.HTMLInputElement.prototype;
Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, '<value>');
el.dispatchEvent(new Event(el.tagName === 'SELECT' ? 'change' : 'input', { bubbles: true }));
// 提交:const form = el.closest('form'); form.requestSubmit(form.querySelector('button[type=submit]'));
```

### 8.3 「自动化运行」节的步骤表列义

每条 scenario 末尾的 runbook 用下表(区别于 §5 人肉「执行记录」表——那是过去式观察,这是可执行指令):

| # | 动作 | 定位 | 输入 | 断言 | evidence |
|---|---|---|---|---|---|
| 1 | navigate/fill/click/submit/wait —— **单一祈使动作** | 稳定 selector / 文本 / `data-*` —— agent-browser 直接用的串 | fill 时的字面值(无则 `—`) | 机器可判谓词(见 §8.4) | 该步要截的图名(见 §8.5) |

- **动作**:一格一个原子动作,别把"填 X 再点 Y 再看 Z"塞一格。
- **定位**:本项目**不用** `data-test`/`data-testid`。真实锚点优先级:`id`/`name`(服务端表单:登录、session 创建 `#world-session-short-name`、邀请 `#world-invite-input`) → `data-world-component`(组件顶层容器,如 `[data-world-component=conversation]`)/ 消息气泡 `data-msg-id`/`data-sender-kind`/`data-mine` / 成员 `li[data-kind][data-online]` → `aria-label`(无 id 的 React input,如 `textarea[aria-label=Message]`)→ placeholder / 稳定文本(React 受控表单字段如 New Agent 无 name,只能靠 placeholder)。只能靠结构/文本时在「遗留」标注健壮性风险。
- **断言**:不是散文,是 §8.4 的谓词。一条 scenario 的每个「期望」至少映射 1 行断言。

### 8.4 断言谓词(机器可判)

| 谓词 | 写法 | 例 |
|---|---|---|
| URL 匹配 | `url~ <substr>` | `url~ /sessions` |
| 元素可见 | `visible <selector>` | `visible [data-world-component=conversation]` |
| 文本包含 | `text~ <selector> "<s>"` | `text~ [data-sender-kind=agent][data-mine=false] "ping-42"`(py 逐字回显) |
| 属性等值 | `attr <selector> <name>=<v>` | `attr li[data-kind=agent] data-online=true` |
| 计数等值 | `count <selector> = <n>` | `count [data-world-component=conversation] li[data-online] = 2` |

跑通判定:所有断言 pass = 🟩;任一 fail = 🟥(附失败断言 + 截图),**不自己改代码修**(§6 grill 文化)。

### 8.5 evidence 自动捕获

- 每个**带断言**的步骤截一张图,命名沿用 [`evidence/README.md`](./evidence/README.md),自动化截图加 **`-auto`** 后缀区分人肉截图:`sNN-stepK-<slug>-auto.png`。
- 断言失败时**额外**截一张 `sNN-stepK-<slug>-fail.png` + 把失败断言文本写进 scenario 的「遗留」。
