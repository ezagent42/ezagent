> **Task:** agent-console-operate-first-demo (#84 · Agents surface 增量)
> **Branch:** `agent-console-operate-first-demo`
> **PR:** https://github.com/ezagent42/ezagent/pull/904
> **Dev:** Claude (cc, 与 the dev 协作)
> **returned_at:** 2026-06-23 20:50 +0800
> **deadline:** 2026-06-23 20:00 +0800
> **deadline_status:** out_of_scope

## 📨 RETURN — `agent-console-operate-first-demo` → @allenwoods (lead)

**Status: `out_of_scope`** — 不在今天 `plan.md` 的 4 个 handoff 里;#84 Agent Console 是平行 track。当天完成(20:50,略晚于 20:00 day deadline)· 工作树干净 · 2 个 commit 已推 PR #904 · ⚠️ **未 rebase**(落后 `origin/main` 6 commit,见 merge request)

### 背景(为什么有这次增量)
林懿伦 review operate-first demo 时指出"agent console 里没有 agent",诉求 = "每个用户(持 manage caps)修改自己 own 的 agent"。本次把 **Agents** 补成 operate-first IA 的第 4 个一等对象(view-only MVP)。

### 交付(全在 PR #904)
- ✅ **PRD delta**(`docs/superpowers/specs/2026-06-23-agent-console-admin-dashboard-prd.md`,commit `610cc6a2`):§3 Agents nav + 权威定义、§5.4 新线框图、§6 matrix `agents-read` + MVP in/out、§7 grounding、§8 decision #9。
- ✅ **Demo 实现**(`apps/ezagent_web/priv/static/agent-console-demo/index.html`,commit `652ef370`):智能体 nav + 只读页(agent / flavor / 来源模板 / 所在会话)+ 置灰写动作 + 授权矩阵 `agents-read` 行。
- ✅ **独立 AI review 修正已吸收**:`data_owner/creator` 降级为 ApiKeys-only(非通用归属);现有 world `agents_table`/`agent_detail` 仅作数据形态、真实列表需新建授权 Manage-filtered snapshot;点名 post-demo 写闭环。

### DoD 可演示产物
- Agents surface **已在浏览器预览核验**(本 session,本地 preview server):智能体 nav 高亮、`page-agents` 渲染、授权矩阵含 `agents-read`、**无 console error**;已截图(对话留存,未落盘成 evidence 文件)。
- 复现:本分支 checkout 下 `uv run python -m http.server 8922 --directory apps/ezagent_web/priv/static/agent-console-demo`,开 `:8922`。团队远程预览惯例走 Tailnet(100.64.0.27);http.server 绑 0.0.0.0,但我**仅本地核过、未实测 Tailnet 可达**。
- 设计稿 = PRD §3 / §5.4 / §6 / §8;代码全在 PR #904。

### 代码 grounding(已核实,非凭印象)
- Agents 列表 source-of-truth = **Manage cap**:`create_agent` 给 creator 铸 `cap(:agent, Manage, :any)`(`workspace/agent_create.ex:523` → `creator_grant.ex:19`);可查 = `Identity.list_caps_for(operator)` 滤 Manage over `:agent`。
- `data_owner` = ApiKeys 行为内出站凭据归属(`behavior/api_keys.ex`),**不**定义 Agents 成员。
- `agents_table` = raw `list_entities`、无 Manage 过滤(`world/identity_data.ex:58`)→ 真实读路径需新建授权 snapshot(吃 PRD §6.1.2 read-side authority blocker)。

### 仍 gated / 交回 lead 决策
- **Agents 写闭环**(`create_agent` / config edit `Behavior.Manage :reconfigure` / grant·revoke caps / api-keys)= post-demo,走 Manage-gate —— 这才闭合"修改 own agent"。`Behavior.Manage` 现仅 `:delete`/`:reconfigure`(`manage.ex:17`)。
- backend-connected MVP 仍被 Manage-gate §10(read-side authority + audit schema)阻塞,见 PRD §6.1。

### ⚠️ 环境 caveat(给 lead / 其他 dev)
预览 **:8921 服务的是 worktree 里的旧 Phase-0 demo**(相对 `--directory` 落错 checkout),不是本 PR 的 operate-first demo。看 Agents 用 **:8922**;:8921 那份不是交付物。

### Merge request
- lead review 后合 **PR #904** → `main`。两个 commit(`610cc6a2` docs + `652ef370` demo + 本 return 文件)干净叠加,无需 split。
- ⚠️ 分支**落后 `origin/main` 6 commit、未 rebase**;merge 前请 rebase(docs + 静态 HTML,冲突风险低)。要我先 rebase 可吩咐。
