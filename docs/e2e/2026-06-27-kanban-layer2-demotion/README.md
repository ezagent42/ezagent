# Layer-2 降级 视觉/数据验证 — 看板 = agent,撤顶层「看板」nav,Identities 按 role 过滤

日期：2026-06-27 ｜ worktree：`kanban-agent-e2e` ｜ 代码 head：`b1ad55b3`
（refactor(world): Layer-2 降级 — 看板=agent,撤顶层 nav,Identities 按 role 过滤）
Server：`http://world.localhost:10042`（built world bundle `/assets/world/main.js`）
板：`entity://system/agent/l2-demo-board`（本验证经 sanctioned `kanban.create` dispatch 现建）

## Layer-2 降级是什么（新 DoD，2026-06-27 用户重定）

反转 2026-06-26「Layer-2 保留顶层看板入口」的判断。新决策：**看板板 = 一个 agent**
（flavor `native` × role `kanban-manager`），**不是**跟 Sessions / Identities / Workspaces
平级的顶层建筑。因此：

- 撤左栏顶层「看板」一级 nav（kanban `nav_surfaces/0` → `[]`，契约机制保留）。
- 板作为 agent 出现在 **Identities / agents 列表**（`entity://<ws>/agent/<板名>`，kind=agent，
  flavor=native）。
- 正确的隔离轴是 **role**（`role:kanban-manager`）——world 读模型把 `role` surface 到每个 agent
  行，并支持 `role:<role>` 过滤子句。

> ⚠️ **旧 DoD 作废**：之前「左栏看板入口」截图不再是验收依据。新 DoD = ①顶层无看板 nav +
> ②板在 agents 列表 + ③按 role 过滤命中板。

## 结论（一句话）

**Layer-2 降级 DoD 三项全绿**：左栏顶层 nav 已无「看板」（①，E2E-PASS）；新建的板
`l2-demo-board` 作为 **Agent native** 出现在 Identities/agents 列表（②，E2E-PASS）；其 agent 行
携带 `role:"kanban-manager"`，`role:kanban-manager` 过滤只命中该板、不命中无 role 的 `py_default`
（③，DATA-PASS——role chip 前端留 owner #84，本来就只能数据实证）。

---

## 环境与前置（built-bundle 法 + 隔离 DB）

| 项 | 做法 | 备注 |
|---|---|---|
| 前端 | built world bundle（`main.js`）+ 主 `app.js`，均 200 | vite binary 损坏 + 5174 被占 → 用已 build 产物；`data-world-module-url="/assets/world/main.js"` 已验 |
| **隔离 DB** | `POSTGRES_DB=ezagent_layer2_e2e`（drop/create/migrate） | 用户的 10052 server 共享默认 `ezagent_pg_compat_dev`,该库已被另一分支种了**分歧的 orchestrator role body** → 同库 boot 撞 `role_seed_collision`。隔离库避开,**不碰用户数据** |
| admin | `EZAGENT_ADMIN_PASSWORD=worlddev`（fresh 库经 migration 种空 hash 行 + boot `repair_admin_user` 设密码） | 登录 `admin@ezagent.chat` / `worlddev` |
| server 稳定 | **临时**改 `config/dev.exs`：① `world_module_url` 读 `WORLD_MODULE_URL` env；② built-bundle 模式跳过 vite watcher（避 crash-loop）；③ `code_reloader: false`（26-app umbrella 下每请求 recompile 使 LiveView join 慢到 35-60s/不稳,CDP 渲染 flaky）。**事后已 `git checkout config/dev.exs` 全部还原** | 关 reloader 后响应 ~0.27s,渲染稳定 |
| 端口 | `PORT=10042` / vite 名义 `5174` / CDP chrome `9333`（自起独立 profile）；**不撞用户 10052/5176/9222** | — |

> 注：`role_seed_collision` 还有一个二阶现象——同一隔离库**重启**也会撞（orchestrator role body
> 序列化非确定性,重算 ≠ 已存）。故每次起 server 前 drop/create/migrate 重建库、**单次 boot 不重起**。

---

## 逐步证据 + 分级

| # | 步骤 | 分级 | 证据 |
|---|---|---|---|
| ① | 左栏顶层 nav 已无「看板」 | **E2E-PASS** | `01-left-nav-no-kanban.png`。左栏 = `Overview / Sessions / Identities / Admin / Workspaces / Plugins / Profile`,**无「看板」一级入口**。CDP eval：`hasKanbanWord=false`,navText 不含看板/kanban。（对比降级前左栏有「看板」一级 nav） |
| ② | 板作为 agent 出现在 Identities/agents 列表 | **E2E-PASS** | `02-board-as-agent-in-identities.png`。`l2-demo-board`（`entity://system/agent/l2-demo-board`）作为 **Agent native** 卡片出现；过滤 chip 多出 `agent:native`（由板 flavor 派生）。板经 sanctioned `world:dispatch` `kanban.create`（`Workspace.create_agent` RF-5a role-create 路径）现建 |
| ③ | 板的 agent 行携带 `role:kanban-manager`,`role:kanban-manager` 过滤命中板 | **DATA-PASS** | `role-filter-forensic.json`。role chip 前端未建(owner #84),只能数据实证——下表 |

### ③ role 过滤数据实证（live read-model）

来源：运行中 server 的 `Ezagent.World.IdentityData.list_entities/2` 输出,经 world LiveView 序列化进
`/identities` 页 `world-root` 的 `data-world-state`（**只读 forensic**,CDP eval 提取,未驱动任何操作）。

板行全文：

```json
{"uri":"entity://system/agent/l2-demo-board","kind":"agent","name":"l2-demo-board",
 "display_name":"l2-demo-board","flavor":"native","role":"kanban-manager","alive":true, ...}
```

全 entities 行 + `role:kanban-manager` 过滤模拟（照 committed `matches_filter?` 子句 `kind=agent ∧ role==suffix`）：

| uri | kind | flavor | role | `role:kanban-manager` 命中? |
|---|---|---|---|---|
| `entity://system/agent/l2-demo-board` | agent | native | **kanban-manager** | ✅ 命中 |
| `entity://system/agent/py_default` | agent | py | `null` | ❌（无 role） |
| `entity://system/user/admin` | user | "" | `null` | ❌（非 agent） |

→ `role:kanban-manager` selects = `["entity://system/agent/l2-demo-board"]`（只板,排除无 role 的
py_default 与 user admin）。证明：(a) `role_for/2` 把 `kanban-manager` surface 到板行；
(b) `matches_filter?(%{kind:agent, role:kanban-manager}, "role:kanban-manager")` 只命中板。

**对照矩阵（Layer-2 降级 DoD）**

| DoD 项 | 期望 | 结果 |
|---|---|---|
| 顶层无看板 nav | 左栏无「看板」一级入口 | ① **E2E-PASS** |
| 板在 agents 列表 | 板 = `entity://.../agent/<名>`,kind=agent,flavor=native | ② **E2E-PASS** |
| 按 role 过滤 | `role:kanban-manager` 命中板、不命中无 role agent | ③ **DATA-PASS**（chip 前端留 #84） |

---

## sanctioned 路径 / 铁律自查

- **建板** = sanctioned UI dispatch：CDP 触发 world LiveView `world:dispatch` `{action:"kanban.create",
  args:{name:"l2-demo-board"}}`（经 hook `pushHookEvent`,走真 authz → `Workspace.create_agent`）。
  审计行可见 `workspace.create_agent` `granted` + 板 `kanban.*` cap 全授（add_node/get_tree/…）。
  **未用 raw RPC 驱动任何操作**。
- **读** 全 read-only forensic：`data-world-state` 提取（`IdentityData.list_entities` 序列化）。
- 真浏览器（headless chrome + CDP）截图,每步独立图。
- **token 不外露**：本任务无 github/miro 写动作。
- **事后 `git checkout config/dev.exs`**：3 处临时改（module_url env / watcher / code_reloader）已全部还原,
  `git status` 无 tracked config 改动。
- 端口未撞用户（10052/5176/9222）：本任务用 10042 + CDP 9333（独立 profile）。

## 卡点记录（如实）

- 同库并发/重启撞 `role_seed_collision` → 用隔离库 + 单次 boot 解决（详见前置表）。
- 起初 LiveView join 慢到 35-60s 且 flaky（截图常只出 spinner）→ 根因 dev `code_reloader` 每请求
  recompile 26-app umbrella；关掉后稳定。
- 想经 `iex --remsh` 跑 live-node 只读 RPC 取 role 过滤,但两个 `@127.0.0.1` long-name 节点
  distribution 握手不通（erlang IP-host quirk,非 cookie）→ 改从 `data-world-state`（同一
  `list_entities` 序列化输出）提取,等价且无需分布式连接。
