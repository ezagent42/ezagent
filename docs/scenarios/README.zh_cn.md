# E2E 场景 — 主目录

> **状态**：草稿 — 2026-05-28。作者：Claude，对应 Allen Feishu 12:32 指令
> *"请先整理 e2e scenarios 的文档，说明应该有哪些 E2E 场景"*。
>
> 双语锁步镜像：[`README.md`](./README.md)。
>
> **本目录是什么**：ezagent 端到端需要验证的全部 E2E 场景的主目录 —
> 跨越 UI、CLI、Feishu、agent flavor、持久化、恢复、插件作者 DX。
> 每个场景是一个子目录 `<NN>-<slug>/scenario.md`（+ ZH 镜像）。
>
> **本目录不是什么**：实施计划。"not-implemented" 状态意味着我们尚未
> 拥有该场景的可运行 E2E harness，但很多底层 action 在生产代码里
> 已经可用（Allen 手工跑过）—— 缺的是 codified runbook + 不变式测试
> 的组合。

---

## 0. 目的

按 Allen 2026-05-28 安排：随着 Phase 2（基于 PR #451 Router/Behavior/Kind
原语之上的 per-domain Behavior 迁移）启动，测试矩阵已分散在：

- 集成测试（`apps/*/test/integration/*`）— 57 个文件，但**它们集体
  断言什么**没有目录。
- 操作员 runbook（`docs/runbook/*`）— 4 个文件；仅覆盖 cc-agent + 4-agent
  综合场景。
- 作为 PR 证据的手工 smoke（`docs/notes/evidence/*`）— ad hoc，没有
  主索引。
- Phase-specs `docs/phase-specs/phaseN/VERIFICATION.md` — 各 phase
  自含，没有跨 phase 汇总。

本文件就是**唯一的汇总**。Phase 2+ 每个 PR 的 `VERIFICATION` 章节
应当能用"场景 NN、MM"回答。

---

## 1. 如何运行一个场景

每个 `<NN>-<slug>/scenario.md` 声明：

- **前置条件** — 启动状态、登录状态、env 变量、种子数据。
- **角色** — 涉及的 `entity://user/...`、`entity://agent/...` URI。
- **步骤** — 具体的 UI 点击 / CLI 命令 / Feishu 输入。
- **预期结果** — 最终状态断言 + 审计日志行。
- **失败模式** — 故意破坏什么以验证优雅降级。
- **交叉引用** — PR / SPEC / 测试 / open bugs。

### 1.1 标准前置

大多数场景假设：

| 资源 | 值 |
|---|---|
| Phx server | `http://100.64.0.27:10042`（Tailscale IP，Allen 远端访问）|
| 本机 URL | `http://127.0.0.1:10042`（操作员本机；Feishu webhook 需公网 sidecar）|
| Allen Feishu chat_id（DM）| `oc_d9b47511b085e9d5b66c4595b3ef9bb9` |
| Dev / smoke Feishu chat_id | `oc_83a4f1ff0bf627ffe26aa60647e5b04a` |
| 系统管理员 | `entity://user/system/admin`（dev seed 密码 `8bdemo`）|
| 默认 workspace | `workspace://system`（PR #398 改名后；`workspace://default` 是禁用别名，见 PR #399）|

### 1.2 工具链

| 工具 | 用途 |
|---|---|
| `mix ezagent.bootstrap` | 幂等 DB-migrate + plugin install。`mix ecto.create` 后跑一次。 |
| `mix phx.server` | umbrella 启动。Allen 在 tmux `esrd` 跑。 |
| `mix ezagent <behavior> <action>` | CLI dispatch（PR #386 后从 `mix esr` 重命名）。 |
| `mix ezagent.demo.seed_cc_sandbox` | 给 cc-agent 的沙箱化 `.claude/` 种入凭据。 |
| `agent-browser` | **强制**的 UI 验证表面，见 `feedback_agent_browser_debug`。 |
| Feishu Sidecar | 出站外部镜像 sender；入站 webhook receiver。 |
| `codex_app_server_thread_repro.py` | codex bridge UDS WS 回归 smoke（PR #441）。 |

### 1.3 验证表面 — 硬规则

按 `feedback_esr_e2e_standards`：任何触及 UI 或 Feishu 的 E2E 场景
**必须**包含 agent-browser 截图（LV）+ Feishu 聊天截图（适用时）。
仅看日志的验证**不**算签收。cc-openclaw Feishu DM（操作员自己的频道）
**不**计 —— 只有 ezagent Feishu sidecar 的回复才算。

---

## 2. 状态分类

| 符号 | 状态 | 含义 |
|---|---|---|
| ✅ | `implemented-and-tested` | runbook 存在 + 自动化测试覆盖 happy path + 至少一个失败模式。Allen 签过手动 smoke。 |
| ⚠️ | `implemented-with-gaps` | 生产代码路径可用，但场景缺以下之一：codified runbook / 自动化测试 / 失败模式覆盖 / 交叉引用索引。 |
| ❌ | `not-implemented` | 用户可见的 action 端到端不可用。可能是已知 gap（例如今天 `/admin/agents` 404）或将来 scope。 |
| ⏳ | `partially-implemented` | 生产代码存在但被 flag 门控、依赖未合并的 PR，或仅覆盖部分 flavor / case。 |

一个场景仅当其 `scenario.md` 引用了 `apps/.../test/...` 测试路径 + 一个
runbook 路径 + 至少一个 PR 证据截图时，才标 ✅。这是 2026-05-04
`feedback_esr_e2e_standards` 规则。

---

## 3. 18 个类别

| # | 类别 | 场景 | 主表面 |
|---|---|---|---|
| 1 | [认证 / Identity](#类别-1--认证--identity) | 01-04 | LV `/login`, `/admin/users` |
| 2 | [Agent 生命周期](#类别-2--agent-生命周期) | 05-08 | LV `/admin/agents`, CLI `ezagent agent`, PTY |
| 3 | [Session 流程](#类别-3--session-流程) | 09-11 | LV `/admin/sessions/:uri`, Feishu 绑定 |
| 4 | [Feishu 集成](#类别-4--feishu-集成) | 12-13 | Sidecar webhook + outbound |
| 5 | [能力管理](#类别-5--能力管理-capbac) | 14-15 | LV `/admin/caps`, CLI `ezagent capability` |
| 6 | [跨 workspace](#类别-6--跨-workspace) | 16-17 | LV workspace 下拉、多 WS 用户 |
| 7 | [PTY 交互](#类别-7--pty-交互) | 18-19 | LV `/admin/agents/:uri/terminal` |
| 8 | [Workspace 管理](#类别-8--workspace-管理) | 20 | LV `/admin/workspaces`, CLI `ezagent workspace` |
| 9 | [Template + 版本 tag](#类别-9--template--版本-tag) | 21 | LV `/admin/templates`, CLI `ezagent template` |
| 10 | [Routing](#类别-10--routing) | 22 | LV `/admin/routing`, `RoutingRegistry` |
| 11 | [External mirror 绑定](#类别-11--external-mirror-绑定) | 23 | `ExternalMirrorWorker`, Feishu sidecar |
| 12 | [销毁 + 级联清理](#类别-12--销毁--级联清理) | 24 | Saga 风格 facade 级联 |
| 13 | [恢复 + 启动](#类别-13--恢复--启动) | 25 | `phx restart`, `StateRebuilder`, `BootReconciler` |
| 14 | [Codex bridge](#类别-14--codex-bridge) | 26 | `codex_app_server_thread_repro.py`, UDS WS |
| 15 | [资源管理](#类别-15--资源管理) | 27 | 沙箱 `.claude/`, api-key, write_path |
| 16 | [审计 + 可观测](#类别-16--审计--可观测) | 28 | `EventLog`, telemetry, `/admin/events` |
| 17 | [Admin LV 页面](#类别-17--admin-lv-页面) | 29 | 全部 `/admin/*` LV + cmdK |
| 18 | [插件作者 DX](#类别-18--插件作者-dx) | 30 | `use Ezagent.Behavior`, effects, LegacyAdapter |

---

## 4. 场景索引 — 平铺列表

| # | 标题 | 类 | 状态 | 测试路径 |
|---|---|---|---|---|
| 01 | [Magic-link 邮件登录](./01-magic-link-login/scenario.zh_cn.md) | 1 | ⚠️ | `magic_link_invariants_test.exs` |
| 02 | [密码登录（admin）](./02-password-login-admin/scenario.zh_cn.md) | 1 | ✅ | `magic_link_invariants_test.exs` + Allen 2026-05-21 签收 |
| 03 | [Token CLI 认证（mint / list / revoke）](./03-cli-token-auth/scenario.zh_cn.md) | 1 | ⚠️ | `cli_dispatch_test.exs`（缺 User-Kind 测试 — todo #1 HIGH-1）|
| 04 | [跨 workspace token 使用（codex 外部 agent）](./04-cross-workspace-token/scenario.zh_cn.md) | 1 | ❌ | 无 |
| 05 | [cc agent — spawn → 首启 → 消息 → 回复](./05-cc-agent-roundtrip/scenario.zh_cn.md) | 2 | ✅ | `cc_agent_admin_reply_e2e_test.exs` |
| 06 | [codex agent — spawn → bridge → 回复](./06-codex-agent-roundtrip/scenario.zh_cn.md) | 2 | ⚠️ | `orchestrator_mcp_e2e_test.exs` + `codex_app_server_thread_repro.py` |
| 07 | [curl agent — spawn → DeepSeek 往返](./07-curl-agent-deepseek/scenario.zh_cn.md) | 2 | ✅ | PR #126 证据 + `curl-agent-walkthrough.md` |
| 08 | [4-agent 综合（cc → curl → np → user）](./08-4agent-comprehensive/scenario.zh_cn.md) | 2 | ✅ | `comprehensive_4agent_e2e_test.exs` + `docs/runbook/4-agent-comprehensive-e2e.md` |
| 09 | [LV 创建 session + 添加成员](./09-session-create-lv/scenario.zh_cn.md) | 3 | ✅ | `session_create_orchestrator_unified_test.exs` |
| 10 | [@-mention 派发 — mention-gated 路由](./10-mention-gated-routing/scenario.zh_cn.md) | 3 | ✅ | `mention_gated_routing_test.exs` + PR #406 |
| 11 | [跨 session @-mention 被拒](./11-cross-session-mention-rejected/scenario.zh_cn.md) | 3 | ⚠️ | 通过路由规则隐式；无专用测试 |
| 12 | [Feishu chat ↔ session 绑定 + outbound](./12-feishu-bind-outbound/scenario.zh_cn.md) | 4 | ✅ | PR #420 + `external_mirror/facade_test.exs` |
| 13 | [Feishu 入站消息 → 路由到 agent](./13-feishu-inbound-routing/scenario.zh_cn.md) | 4 | ✅ | `feishu_chat_binding_test.exs` + `inbound_chat_lookup_test.exs` |
| 14 | [LV 授予 cap（action 轴）](./14-grant-cap-action-axis/scenario.zh_cn.md) | 5 | ✅ | `cap_action_axis_invariant_test.exs` + PR #410 |
| 15 | [撤销 cap + 非 admin 拒绝](./15-revoke-cap-non-admin-denial/scenario.zh_cn.md) | 5 | ✅ | `caps_denial_e2e_test.exs` + `non_admin_grant_flow_e2e_test.exs` |
| 16 | [切换 workspace + 可见性过滤](./16-workspace-switch-visibility/scenario.zh_cn.md) | 6 | ✅ | `workspace_isolation_test.exs` + PR #434 |
| 17 | [多 workspace 用户](./17-multi-workspace-user/scenario.zh_cn.md) | 6 | ⚠️ | 部分 — `workspace_isolation_test.exs` 仅覆盖反向路径 |
| 18 | [PTY 首启 theme 对话框处理](./18-pty-first-run/scenario.zh_cn.md) | 7 | ✅ | `cc_agent_admin_reply_e2e_test.exs` + PR #385 |
| 19 | [PTY 重启保留 cwd + 孤儿回收](./19-pty-restart-orphan/scenario.zh_cn.md) | 7 | ✅ | PR #385 + #388 + `sandbox_destroy_test.exs` |
| 20 | [Workspace 创建 + 添加成员 + 销毁](./20-workspace-lifecycle/scenario.zh_cn.md) | 8 | ⚠️ | `add_member_spawn_then_grant_test.exs` + PR #417（无销毁 E2E）|
| 21 | [Template 版本 tag + 实例化](./21-template-version-tag/scenario.zh_cn.md) | 9 | ⏳ | `add_template_invokes_test.exs` — 版本 tag 尚未发布 |
| 22 | [Routing 规则 CRUD + 优先级](./22-routing-crud/scenario.zh_cn.md) | 10 | ✅ | `routing_consolidation_invariant_test.exs` + `routing_boot_test.exs` |
| 23 | [ExternalMirrorWorker 冷启重新订阅](./23-external-mirror-resubscribe/scenario.zh_cn.md) | 11 | ✅ | PR #420 修复 task #49 |
| 24 | [销毁级联 — agent / session / workspace](./24-destroy-cascade/scenario.zh_cn.md) | 12 | ⚠️ | `lifecycle_terminate_test.exs` + `sandbox_destroy_test.exs`（Saga 补偿未测）|
| 25 | [Phx 重启 — 快照重建 + ExternalMirror](./25-phx-restart-rebuild/scenario.zh_cn.md) | 13 | ✅ | `snapshot_restart_test.exs` + `session_survives_restart_test.exs` + `cap_action_axis_snapshot_restore_test.exs` |
| 26 | [Codex bridge UDS WS thread 连续性（PR #441 回归）](./26-codex-bridge-uds-ws/scenario.zh_cn.md) | 14 | ✅ | `orchestrator_mcp_bridge_test.exs` + `scripts/codex_app_server_thread_repro.py` |
| 27 | [Per-agent api-key + 沙箱隔离](./27-api-keys-sandbox/scenario.zh_cn.md) | 15 | ⚠️ | `cc_agent_sandbox_credentials_test.exs` — Bug A（config_dir 原子化）推迟 |
| 28 | [派发审计行（invocations → EventLog）](./28-dispatch-audit/scenario.zh_cn.md) | 16 | ⏳ | `Audit.@events` 已覆盖；EventLog 迁移是 Phase 2+ |
| 29 | [Admin LV smoke — registry / snapshots / templates / routing / cmdK](./29-admin-lv-smoke/scenario.zh_cn.md) | 17 | ⚠️ | per-LV 手动 smoke；`/admin/agents` 返回 404（gap）|
| 30 | [插件作者 DX — 用 effects 写新 Behavior](./30-plugin-author-behavior/scenario.zh_cn.md) | 18 | ⏳ | Phase 1 落地 LegacyAdapter（PR #451）；Phase 2 将演练绿地 Behavior 编写 |

---

## 5. 类别说明

### 类别 1 — 认证 / Identity

生产路径：magic-link 经 `Ezagent.Web.MagicLinkController`，密码经
`Ezagent.Behavior.Identity`（User Kind），CLI token 经
`Ezagent.Behavior.UserTokens`（`mint` / `list` / `revoke`）。

待办 gap：
- `feedback_uuid_is_canonical_identifier`（2026-05-12）— username 是
  可变的显示字段；cap-key 走 username → UUID 解析。需要一个
  "用户改名 + cap 仍有效" 的场景。
- Token revoke + 活跃 CLI session：当前 token revoke 不会让飞行中的
  CLI dispatch 失效。

### 类别 2 — Agent 生命周期

今天 5 种 flavor：`cc`、`codex`、`curl`、`np`、`echo`。每个通过其
plugin 的 `agent_flavors/0` 声明（Decision Log #133-#134）。Flavor →
Template Class 解析在 `AgentFlavorRegistry`。

4-agent 综合（场景 08）是跨 flavor 集成测试。cc + curl + np + echo + codex
各有 `plugin_contract_test.exs` 验证它们正确声明 flavor。

### 类别 3 — Session 流程

统一 create 路径落地于 PR #408（`Behavior.Workspace :create_session`）。
成员操作走 workspace cap。Mention-gated 路由（PR #422 + SPEC
`mention-gated-routing`）是默认；显式路由规则覆盖之。

跨 session 泄漏防护由 `RoutingResolver` 通过 `$session_members` 魔法
receptor token 实施（Decision #120）。

### 类别 4 — Feishu 集成

Sidecar 架构（独立进程，JSON-RPC bridge）。两种模式：
1. **入站**：Feishu webhook → sidecar → `FeishuAdapter.receive/1` →
   路由规则 → agent action。
2. **出站**：agent emit → `ExternalMirrorWorker` → sidecar → Feishu
   app send_message。

按 `feedback_register_lookup_key_parity`（2026-04 教训），入站 chat
lookup 测试覆盖 `chat_id → session_uri` 映射（PR-EM-1）。

### 类别 5 — 能力管理（CapBAC）

PR #410 后的 cap shape（action-axis SPEC `capability-action-axis`）：
`{kind, behavior, action, instance, workspace_uri}` — 5 维。
`matches?/2` 强制 5 维全检。`cap_for_action/3` per-Kind 权威。

Admin 持有 `%{kind: :any, behavior: :any, action: :any, instance:
:any, workspace_uri: :any}`（decision #99）。`feedback_let_it_crash_no_workarounds`
规则禁止 `:any` 当 wildcard fallback；admin cap 是结构性的，不是默认。

待办 gap：`/admin/caps` LV 授予表单的 action 下拉（todo "Entity-caps
LV grant form needs action-selector dropdown"）；admin-role 豁免是当前
桥接。

### 类别 6 — 跨 workspace

基于 cap 的可见性替换了旧的 `visible` 字段（PR #434，SPEC
`workspace-cap-based-visibility`）。用户能看到一个 workspace 当且仅当
持有任何 `workspace_uri: <ws_uri>`（或 `:any`）的 cap。

Workspace 前缀不变式（PR #417）：每个 entity URI 携带其归属 workspace
作为路径段，例如 `entity://agent/<workspace>/<agent_name>`。`add_member`
验证器强制此约束。

### 类别 7 — PTY 交互

cc agent + np agent + python agent（codex 也经新 bridge）都 spawn PTY
子进程。孤儿回收（PR #385）用 pid-file（PR #388 替换了 `ps`-walk）。
PTY phase 状态机（PR #390）：boot → first-run → ready → working → idle。

cc agent 首启 theme 对话框：spawn 的 `claude` 首次启动显示 TUI theme
picker；ezagent PTY handler 盲打 `<Enter>` 关闭它（PR #390）。

### 类别 8 — Workspace 管理

CRUD + 成员 op。带活跃 session 的销毁当前**没有**端到端跑过 —
`lifecycle_terminate_test.exs` 覆盖 terminate action body，但没有完整
级联测试。

默认 workspace 是 `workspace://system`（PR #398 后；Allen 2026-05-26
修正了早期的 `default` 别名）。

### 类别 9 — Template + 版本 tag

Template 今天是 Kind（per-template 快照策略 `{:snapshot, :on_change}`）。
版本 tag**尚未发布** — 最近的是经 `AgentFlavorRegistry` 注册 template_class。
将来的 SPEC 会加 tag + rollback。

### 类别 10 — Routing

`RoutingRegistry` 是第 3 个 Registry 家族（Decision #95），带 owner-pid
检查（admin 运行时写）。5-leaf Matcher AST（`mention` / `from` /
`text_contains` / `text_matches` / `always`）+ 3 组合子（and / or / not，
PR #118 in Decision #118）。

路由规则优先级：DB 顺序 + `enabled` 标志（PR #120，Decision #120）。
System-default `always() → ["$session_members"]` 规则仅可 admin 禁用，
不可删除。

### 类别 11 — External mirror 绑定

`ExternalMirrorWorker` per-binding GenServer。PR #420 修复了冷启重新订阅
gap（task #49）—— 当 Session 从快照重新启动时，对应 worker 必须重新
订阅 session publisher。

多 app-id 支持：同一 `chat_id` 可被多个 bot 绑定；worker registry 以
`{chat_id, app_id}` 为 key。

### 类别 12 — 销毁 + 级联清理

Saga 风格级联随 PR #451 的 `SagaRunner` 落地。Phase 2 将端到端演练。
今天：facade 级销毁基本是单步（部分失败无补偿）。

### 类别 13 — 恢复 + 启动

`StateRebuilder`（PR #451）重放 `EventLog` 行以在启动时重建 Kind 状态。
`BootReconciler`（在 `ExternalMirror`）扫 `bindings` 行 + 确保每个活跃
绑定有 live worker。

`session_survives_restart_test.exs` 覆盖 session 侧；ExternalMirrorWorker
的类比测试落地于 PR #420；cc agent orchestrator 快照恢复见
`orchestrator_mcp_e2e_test.exs`。

### 类别 14 — Codex bridge

Bridge sidecar 作为独立进程运行；ezagent + bridge 经 UDS WebSocket 的
JSON-RPC 共享 `thread_id`（PR #441 fix）。TUI 恢复路径在 PR #437 修复。
操作员 smoke：`scripts/codex_app_server_thread_repro.py` +
`scripts/codex_bridge_thread_smoke.py`。

### 类别 15 — 资源管理

Per-agent api-key（PR #389 从 User flip 到 Agent Kind）。Per-agent
`claude_config_dir`（沙箱化 `.claude/`）。Bug A（"config_dir 原子化"）
推迟 —— 当 cc agent 在 setup 中途重启时，部分填充的 config_dir 残留。
SPEC #445 §3.3 在 Phase 2 PR 8 把这些提升为一等 `resource://` URI。

### 类别 16 — 审计 + 可观测

今天：每个 `Invocation.dispatch/1` 发出 telemetry
`[:ezagent, :authz, granted | denied]` + 写一行 `invocations`。Phase 1
PR #451 加 `EventLog` 作为规范事件表（Phase 2 把 `invocations` 迁移到
`EventLog`）。

`/admin/events` LV 尚不存在 — 观察走 SQLite 查询或 telemetry dashboard。

### 类别 17 — Admin LV 页面

| 路径 | 覆盖 |
|---|---|
| `/admin` | ✅ workspace 下拉 + chat + 派发 UI |
| `/admin/users` | ✅ create / set_password / mint_token（CLI parity gap — todo HIGH-4）|
| `/admin/caps` | ✅ list + grant + revoke（action 选择器表单 gap — todo）|
| `/admin/workspaces` | ✅ create / add_member / destroy（最后一项无 E2E 测）|
| `/admin/templates` | ✅ list + create + 表单（从 Template Class 自动派生）|
| `/admin/routing` | ✅ 规则 CRUD + 优先级 + enable/disable |
| `/admin/registry` | ✅ live KindRegistry 快照 |
| `/admin/snapshots` | ✅ kind_snapshots 浏览 + dump + clear |
| `/admin/agents` | ❌ 今天返回 404 — gap，场景 29 标记 |
| `/admin/sessions/:uri` | ✅ chat + 成员名册 + 派发 |
| `/admin/sessions/:uri/routing` | ✅ per-session 路由规则（PR #418 fix）|
| `/admin/agents/:uri/terminal` | ✅ live PTY 镜像 |
| cmdK 搜索 | ⚠️ 已发布（SPEC `v1-uri-pickers-and-cmdk`）— 全部 action verb 覆盖未测 |

### 类别 18 — 插件作者 DX（新 — 为 Router/Behavior/Kind）

按 SPEC #445 §4（PR 2026-05-28 合并），插件作者将用 `use Ezagent.Behavior`
模块写 `action :foo, caps: [...] do ... end` 宏，返回 effects。
Phase 1（PR #451）发布原语 + `LegacyBehaviorAdapter`（包装 62 个现有
`invoke/4` 调用点）；Phase 2 将 per-domain 改造。

本类别场景目标：
1. 写一个新 Behavior（绿地）— 演练 action 宏、effects 词汇表、cap 声明、
   EventLog 发射。
2. 经 LegacyAdapter 迁移一个现有 `Behavior.invoke/4` — 验证 adapter
   对调用者透明。
3. Saga 补偿模式 — 声明多步骤 saga，验证部分失败时的补偿顺序。

---

## 6. 优先级 — Phase 2 测试基础设施 Top 5

Phase 2（按 SPEC #445 §6）从 `invoke/4` 迁移 22 个 Behavior 到新
`action/3` 宏。最大限度降低迁移风险的测试基础设施投资：

| 排名 | 场景 | 为什么 |
|---|---|---|
| **1** | **30 — 插件作者 DX（绿地 Behavior）** | Phase 2 的 done-gate 是插件作者无核心知识写新 Behavior。改造之前需要可运行的 E2E + golden file。 |
| **2** | **25 — Phx 重启重建** | 基于快照的恢复是 22-Behavior 迁移的安全网。如果 StateRebuilder 回归，每个改造的 Behavior 都有风险。 |
| **3** | **24 — 销毁级联 w/ Saga** | PR #451 的 `SagaRunner` 在生产未测。Phase 2 将用于多步骤 Behavior 迁移；之前需要 baseline 场景。 |
| **4** | **05 + 06 + 07 — 跨 flavor agent 往返** | 3 个最常用 agent flavor。任何 Phase 2 触及 `chat.send` / `chat.receive` 的 Behavior 必须回归通过这些。 |
| **5** | **14 — Cap action-axis 授予** | Cap-axis 是插件隔离的**核心**不变式（一个 wildcard cap 会破坏模型）。任何 Phase 2 Behavior 迁移必须保留 action-narrow 授予。 |

次级投资（top-5 之后）：
- **17 — 多 workspace 用户** — 今天是 gap；需要在任何 workspace-aware
  Behavior 改造前落地。
- **04 — 跨 workspace token 使用** — 今天 `❌`；codex plugin（最进取的
  外部 agent 集成）的 v2 ship 前需要此场景。
- **21 — Template 版本 tag** — SPEC 待定；不阻塞 Phase 2 但阻塞 Phase 3。

---

## 7. 引用

### 顶层架构

- [`ARCHITECTURE.md`](../../ARCHITECTURE.md) — v0.4 final, Decision Log #1-#137
- [`IMPLEMENTATION_ROADMAP.md`](../../IMPLEMENTATION_ROADMAP.md) — 7-phase 计划
- [`GLOSSARY.md`](../../GLOSSARY.md) — 消歧引用
- [`CLAUDE.md`](../../CLAUDE.md) — 项目级 Claude 指令

### Phase 1（Router/Behavior/Kind）— 2026-05-28 合并

- SPEC PR — `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md`
- Integration PR #451 — feat/router-behavior-kind-phase-1-v2
- Sub-PRs #447 (EventLog), #448 (SnapshotStore), #449 (SagaRunner), #450 (Router + Behavior + Kind + LegacyAdapter)

### 现有场景来源（汇总在此）

- [`docs/runbook/4-agent-comprehensive-e2e.md`](../runbook/4-agent-comprehensive-e2e.md) — 场景 08
- [`docs/runbook/cc-agent-e2e.md`](../runbook/cc-agent-e2e.md) — 场景 05, 18, 19
- [`docs/runbook/cc-agent-config.md`](../runbook/cc-agent-config.md) — 场景 27
- [`docs/notes/curl-agent-walkthrough.md`](../notes/curl-agent-walkthrough.md) — 场景 07
- [`docs/notes/caps-e2e-design.md`](../notes/caps-e2e-design.md) — 场景 14, 15
- [`docs/notes/demo-followup-walkthrough.md`](../notes/demo-followup-walkthrough.md) — 场景 09, 12
- [`docs/futures/todo.md`](../futures/todo.md) — open gap 在场景"Notes"段交叉引用

### 定义预期行为的 SPEC

- `2026-05-22-plugin-authoring-contract.md` — 类别 18 契约
- `2026-05-22-mention-gated-routing.md` — 场景 10
- `2026-05-23-capability-registry.md` — 场景 14, 15
- `2026-05-24-caps-data-ownership-v2.md` — 场景 16
- `2026-05-24-external-mirror-domain.md` — 场景 12, 13, 23
- `2026-05-25-agent-create-cli-gui-parity.md` — 场景 03, 05-08
- `2026-05-26-session-create-orchestrator-unified.md` — 场景 09
- `2026-05-27-capability-action-axis.md` — 场景 14
- `2026-05-27-workspace-cap-based-visibility.md` — 场景 16
- `2026-05-28-router-behavior-kind-architecture.md` — 场景 30

### 场景引用的 open feedback 规则

- `feedback_esr_e2e_standards` — 验证表面硬规则
- `feedback_agent_browser_debug` — UI 验证强制
- `feedback_open_terminal_first_when_debugging` — 调试纪律
- `feedback_bilingual_docs_convention` — 本目录遵循的 ZH 锁步约定

---

## 8. 如何添加新场景

1. 选下一个空闲的 `NN`（补零到 2 位）。
2. 选一个 Kebab-case slug。
3. 创建 `docs/scenarios/<NN>-<slug>/scenario.md`（EN）+
   `scenario.zh_cn.md`（ZH 锁步）。
4. 用 `docs/scenarios/template/scenario.md` 中的模板（TODO — 暂未发布；
   暂时从现有场景复制）。
5. 更新上面的 §4 + §3 类别计数。
6. 优先级变化时更新 §6。

诚实状态报告是规则（`feedback_completion_requires_invariant_test`）：
仅当 `scenario.md` 和一个 `apps/.../test/...` 文件都存在 + Allen 签收
时，场景才标 ✅。

---

## 9. 变更日志

| 日期 | 变更 | 作者 |
|---|---|---|
| 2026-05-28 | 初始目录 — 18 类别 30 场景 | Claude（Allen 12:32 指令派遣的 subagent）|
