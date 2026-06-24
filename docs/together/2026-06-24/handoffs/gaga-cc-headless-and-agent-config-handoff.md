# Handoff: cc-headless real impl + agent-config backend — for @黄佳佳

> **Date:** 2026-06-24 · **From:** lead (@林懿伦) · **To:** @黄佳佳 (gaga)
> **Tracking:** goal ① — "ezagent 团队内跑起来" · **Base:** `origin/main` @ `78d70e21`
> **Status:** confirmed — 两件任务（上午 cc-headless 真实现；下午 agent-config 后端，与 @戴明 并行）

## 0. Mission
两件，先后做：
- **上午** —— 把 `cc-headless` 从 spawn-stub 做成**真**的无 PTY Claude agent（按已验证的 3A 路线，3B 已证不可行）。
- **下午（与 @戴明 并行）** —— 把 agent 配置的**后端**做完整：完整 config cascade 可读、每个 config key 可写、console 需要的后端函数齐全，**逐项 CRUD 有 domain 层断言测试**。这是 @戴明 #84 前端要调的契约。

---

## 任务 1（上午）：`feat/cc-headless-real`

### Task
当前 `cc-headless` slice 注册了 flavor / template / adapter / workspace 创建路径，但**不启动 Claude 后端**（`Ezagent.PluginCc.Template.CcHeadlessAgent` 仍把子进程路径标为 stub，凭据物化后直接返回成功）。把它做成真的会话能力 agent。

**3B 已证不可行 → 实施 3A**（见 §3A）：`claude -p --input-format stream-json --output-format stream-json`，配 `--session-id` / `--resume` 做多轮持久化；transport class 用 `:in_process_sync`（与 curl 同类），`CcHeadlessBridgeAdapter.deliver/2` 内跑一次短命 `claude -p` 子进程（stdin 写 user 消息，stdout 读 assistant 回复）。

### Required reading
1. `docs/together/2026-06-23/handoffs/cc-headless-real-implementation.md` —— **§3A**（选定路线）、§"Implementation plan" 的 6 步、§"Acceptance wording"、§"Non-goals"。**3B（`server:esr-bridge` 无 PTY）已在 2026-06-23 对 Claude Code 2.1.186 验证不可行，不要再试。**
2. Skill **ezagent-developer**（PR 门禁的 invariants）。

### Owned surfaces（cc-headless）
- `EzagentPluginCc.CcHeadlessBridgeAdapter`（改 `transport_class` → `:in_process_sync`，实现 `deliver/2`）。
- `Ezagent.PluginCc.Template.CcHeadlessAgent`（替换 spawn stub：生成 UUID `session_id` + bootstrap + respawn data；实现真 `ensure_subprocess_alive/2`）。
- 新建 `Ezagent.PluginCc.HeadlessRunner`（包一次 `claude -p`：stream-json 输入输出，按 `--session-id`/`--resume` 多轮）。
- 新增 cc-headless 的 `:sync_result` behavior（推荐独立 `CcHeadlessSyncResult` —— flavor 隔离干净）。

### DoD（可演示 artifact）
- [ ] **真渠道会话往返截图**：一个 `cc-headless` agent 在会话里给出**真 Claude 回复**（不是 ACK）；并演示一次**多轮**（Round 2 走 `--resume` 正确引用 Round 1 上下文）。
- [ ] 焦点测试：`HeadlessRunner.call/4`（mock claude 脚本）、`CcHeadlessBridgeAdapter.deliver/2` 返回 `{:ok, response}` 形状、`ensure_subprocess_alive/2` 校验 session_id、缺 session_id 的失败路径有清晰错误。
- [ ] 所有门禁绿：arch.scan、doc.scan、uri_query.scan、check_invariants、format、test、`:ezagent_plugin_check`。

---

## 任务 2（下午，与 @戴明 并行）：`feat/agent-config-backend`

### Task
agent 配置**后端完整性** —— **不碰 UI**，只把 domain 层契约做齐做对，让 @戴明 的前端（#84 console）有可靠后端可调：
1. **完整 config cascade 可读** —— 把一个 agent 的全量配置 cascade（继承 + override 后的有效值）通过后端函数读出来。
2. **每个 config key 可写** —— 每一项配置都能经 `apply_config_delta` 写入（先支持全量、再按 UX 裁剪，与 fatnine 草案一致）。
3. **console 需要的后端函数齐全** —— 对照 @戴建明草案里前端要调的后端面，补齐缺的函数。
4. **逐项 CRUD 断言测试** —— 在 domain 层证明每一项「读/写/改/删某 config key」真能用（不是 UI 演示）。

### 真实落点（已核对代码，引用路径作落点）
- `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex` —— 配置演进 Behavior，是这条 track 的主模块：
  - `handle_apply_config_delta/2`（`apply_config_delta` action 的实现 → `do_apply_config_delta/3`）—— 写路径。
  - `handle_repoint_config/2`（`repoint_config`）。
  - `required_caps/0` —— `apply_config_delta` / `repoint_config` 都要 `cap(:agent, Ezagent.Behavior.Manage, :any)`（**manage-cap**），写测试时按此授权。
  - `handle_reconcile_cascade/2` —— cascade 协调路径（与「完整 cascade 可读」相关）。
- 读路径 / cascade 取值：以该模块对外读取 cascade 的函数为准；若 console 需要的读函数尚不存在，本 track 补齐它（这正是「后端完整性」的范围）。

> 注意：`apply_config_delta` 是 dispatched-TO 的 STEP-1 action（见模块 moduledoc §STEP 1），写测试时按 action 路径调用、用 manage-cap ctx，不要绕过授权。

### Owned surfaces（agent-config 后端）
- `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex` 及其同域读/写函数。
- 对应的后端测试文件（每项 CRUD 一条断言）。
- **不碰 UI / LiveView**（那是 @戴明 #84 的 surface）。

### DoD（可演示 artifact）
- [ ] **每项 config CRUD 一条断言测试**：read（cascade 全量读得到）、create/update（经 `apply_config_delta` 写入后读回值一致）、delete（删某 key 后读回不存在）—— 每条在 domain 层断言，含 manage-cap 授权路径 + 一条 cap 拒绝的失败路径。
- [ ] 测试输出（E2E/domain run）展示前端要调的每个后端函数返回期望形状。
- [ ] 所有门禁绿：arch.scan、doc.scan、uri_query.scan、check_invariants、format、test、`:ezagent_plugin_check`。

---

## Required reading（两件共用）
1. Skill **ezagent-developer**（always）。
2. `docs/together/2026-06-23/handoffs/cc-headless-real-implementation.md`（§3A，任务 1）。
3. `docs/together/2026-06-24/handoffs/agent-console-crud-handoff.draft.md`（任务 2 —— 看 @戴明 前端需要哪些后端函数 / 字段，对齐契约）。
4. `dev-together` skill —— 流程 + DoD 标准。

## Discuss-first vs Deferred
**Discuss-first（下午开工前，必拍）：** agent-config **后端 ↔ 前端接口契约** —— 函数签名 / 入参形状 / 错误返回，与 @戴明 对齐，避免前端做完后端对不上。
**Deferred（已标 + 有目标）：** config key 的**按 UX 裁剪**（先支持全量写，裁剪留到 @戴明前端 UX 定稿后的后续 PR）。
**Never deferred here：** manage-cap 授权（写路径必须过 cap）、每项 CRUD 的断言测试、cc-headless 的真会话往返证据、门禁。

## Conflict-avoidance
- 任务 1 owned：cc plugin 的 cc-headless 三个模块 + 新 `HeadlessRunner` + 新 sync_result behavior（cc plugin 内部，flavor 隔离）。
- 任务 2 owned：`ezagent_domain_identity` 的 `config_evolve.ex` + 测试，**不动 UI**。
- 与 @戴明 的边界：你做后端契约，他做前端调用；下午开工前对齐契约后各做各的，互不改对方文件。

## Merge model
两件各自 PR 合入各自 task 分支（`feat/cc-headless-real` / `feat/agent-config-backend`，绝不直接进 `main`）；保持 rebase 在 `main` 上；DoD 满足后由 lead（@林懿伦）把 task 分支合 `main`。

## 讨论项（早会 standup — 谁需要在场）
- **agent-config 后端 ↔ 前端接口契约。** 参与：**@黄佳佳 @戴明** —— 下午并行开工前对齐函数签名 / 入参 / 错误返回。这是两条 track 的会合点，先对齐再各做。
