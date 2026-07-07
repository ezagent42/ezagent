---
name: project-discussion-esr-ng
description: >-
  项目知识问答 skill（ezagent / esr-ng —— 25-app Elixir/OTP 消息路由 umbrella）。提供有实证支撑的项目知识——
  每个回答都附带 file:line 引用或 mix test 输出，而非凭记忆。覆盖：三层架构（core/domain/plugin）、
  Kind/ActionSet(前 Behavior)/Invocation 契约、CapBAC/URI(SPEC v3 6 scheme)/可靠性原语、
  ActionSet 与 recipe（role=recipe、flavor-as-data）、**socialware 生命周期（author→publish→discover→install→use 全链）**、
  25 个 umbrella app 的职责与依赖、测试状态与 pipeline。讨论这个项目时**总是先加载本 skill**，即使只是简单的项目问题也应触发。
  验证某模块是否正常工作、处理 bug 分流、查询测试状态时同样触发。
baseline_commit: 49f0167f7
baseline_branch: "upstream/main (2026-07-06 全量 re-bootstrap)"
baseline_date: 2026-07-06
# 增量 #1208 (5d540f53→49f0167f, 全量bootstrap后1个commit): hello 迁移到标准
# socialware substrate + framework routing table (B'-direct, 15个hello文件+core/world/web各1)。
# hello 节按 5d540f53 写成——读 hello 相关(orchestrator投递/routing/Members.role_uris)先看 #1208 diff。
# main 自身 duplicate-fn baseline 43→44 (#1208 forced fork)。
---

# ezagent / esr-ng 项目知识问答

ESR(Ezagent Session Router) —— Elixir/OTP 消息路由 runtime，multi-channel → multi-agent 编排。
一个 25-app umbrella，三层：**core（L1 机制）→ domain（L2 领域）→ plugin（L3 扩展）**，`ezagent_cli`/`ezagent_web` 是 transport 顶层（P13）。

本 skill 是**项目知识的实证问答层**：回答 ezagent 代码结构/契约/边界的问题，验证某模块是否工作，做 bug 分流。
**与设计原则权威集分工**：架构原则（P1-P26）、CI gate、反模式 refuse 在 `.claude/skills/ezagent-developer/SKILL.md`（写代码/改架构时加载那个）；本 skill 回答 "现在代码是什么样、在哪、通不通"。

---

## 基线说明（禁用旧名）

**基线**：`upstream/main` @ `5d540f535`（2026-07-06 **全量 re-bootstrap**，25 app 逐个 lib/*.ex 现读）。逐 app 细节见 `references/module-details.md`（每条断言带 file:line）。本次 bootstrap 把此前所有逐-PR 增量补丁（#1168-1207 那一长串）全部吸收进全量索引，故本节不再逐条罗列历史增量——要看某 app 的变更史，读 module-details 对应节的 "自 de4f40a5 的变化"。

**到基线为止已落地的重命名/重构（不要再用旧名）**：

| 现名（用这个） | 旧名（禁用） | 出处 file:line |
|---|---|---|
| `Ezagent.ActionSet`（契约模块） | `Ezagent.Behavior` | core behavior.ex:1（**文件名仍 behavior.ex**，模块名是 ActionSet；T1 #1138） |
| `use Ezagent.Lifecycle`（唯一 dev surface） | 手写 `invoke/4` | `invoke/4` 是 `@optional_callbacks` 无 runtime 路径 |
| `Ezagent.Agent.Recipe`（role=flavor-agnostic recipe） | role 作 code / role 作 URL | core recipe.ex；subject `recipe:<名>`（结构化非-URI，domain-agent recipe_registry.ex:92-95） |
| `Definition.roles`（agent 槽 + human 槽） | `Definition.agents` / `.members` | session definition.ex:20（#1180 退休 agents/members） |
| agent 带 **recipe provenance**（`:sandbox.:recipe`）；`role_name` 只住 (entity×session) 成员边 | agent 级 session role | #1185 de-bake；core Sandbox `:role`→`:recipe`；`AgentRoleAttributes`→`AgentRecipeAttributes`、`AgentRoleResolver`→`AgentRecipeResolver`（domain-agent） |
| `socialware:<名>`（Definition OPAQUE 非-URI subject，key `socialware`，workspace 独立字段） | Definition 作 URI | session definition_registry.ex:37-40 |

**没改的别误报**：`Ezagent.BehaviorRegistry` 模块名**没**改（core behavior_registry.ex:1，CLI/ApiV1 仍消费它——正确非 bug）；CLI 仍消费 `behavior_module.interface()`/`state_slice()`（core 仍存，模块名未 rename）。

---

## socialware 生命周期现状（load-bearing —— 回答"能不能发布/发现/安装一个 socialware"的权威）

**author→publish→discover→install→use 全链在代码里通了**，核心机器全在 **ezagent_domain_session**（不是 ezagent_domain_socialware —— 后者只是 customer-feed/anon-User substrate，无 session Kind）。world 只 CONSUME（DefinitionRegistry/DefinitionEditor/Installation/RoleAssignments）。

| 段 | 现状 | 入口（file:line） |
|---|---|---|
| **author** | 通 | config 侧 `ManifestResolver.resolve/1`（session manifest_resolver.ex:14，string name-refs → Definition module refs，fail-closed）；world 表单侧 `WorkspacePluginActions.save_session_template/2`（world workspace_plugin_actions.ex:191-250） |
| **publish** | 通 | `ConfigGovernance.Socialware.publish_cr/2`（session config_governance/socialware.ex:81）；幂等入口 `publish_or_upgrade/2`（:114-132）；PUBLIC scope admin-gated（`authorize_public_scope/2` :197 → `:public_socialware_requires_admin` :228） |
| **discover** | 通 | `DefinitionRegistry.list/1`（session definition_registry.ex:262，cross-ws 可见性 + retract 过滤 + 每 name 去重）；world 侧 `socialware_rows/1`（world world_live.ex:751-813） |
| **install** | 通 | `Installation.install_template_installs/4`（session installation.ex:177，freeze-pin 到当前 revision）；world 侧 `SocialwareInstall.prepare_create_template/6`（world socialware_install.ex，content-hash-addressed，被 `ConversationActions.create_session/6` 调） |
| **use** | 通 | `SessionCreator.TemplateTeam → DefinitionAgents.materialize_definition_agents/4`（session definition_agents.ex:64，只物化 `roles` 里 `fill==:agent` 的槽） |
| **anon 消费** | 通 | public + web_anon_access 的 session 可被匿名 VIEW：web `AnonIngress` → domain `AnonAdmission.admit_anonymous_participant/2` → 只读 anon-User + `<sw>_render` view cap；公开路由在 RequireEntity 外（web router.ex:159/186） |

**表单一条龙（world 侧，#165 caps 穿线后）**：`save_session_template/2` → `prepare_form_socialware`（`DefinitionEditor.validate_definition(socialware, complete:true)`，workspace_plugin_actions.ex:337-345）→ `save_prepared_socialware`（`DefinitionEditor.save_authored_definition`，:349-360，**真实携带 caller `:current_caps` :195-209 让 domain public-scope admin gate 授权 `:public` publish**）→ `SessionTemplate.create` 嵌 socialware_ref → `publish_current_template` 标 "current"。

**publish_or_upgrade 幂等 RULE**（session config_governance/socialware.ex:114-132）：查 `DefinitionRegistry.lookup`，content-hash 相同 `:exists`、不同走 `publish_new_revision(:upgraded)`、无则 `:published`（:134，跑完整 open_cr→stage→publish 保 admin 门+审计）。**这是 `Demo.Hello.publish` 的调用入口**（session demo/hello.ex:139）。

**role-slot 物化（#1194 fresh/reuse 分叉）**（session definition_agents.ex）：`materialize_one`（:97）→ `install_mode_of`（:385）：`:fresh` → `materialize_fresh_agent`（:118，**新 UUID 实例 URI** `planned_agent_uri` :347，无 role/session 段，recipe×flavor create :222，faceted `session.join` 带 `%{role_name}` :246，grant recipe caps LAST :303）；`:reuse` → `reuse_existing_agent`（:139，复用已存在 agent URI，`ensure_reuse_recipe_match` :158 校验 recipe 一致）。flavor 缺省 `"cc"`（flavor_of :404-409）。role_name 只落在成员边——**同一 uuid agent 能在 A 会话当某 role、B 会话当另一 role**。

**fork_config（copy-config UX）**：`Ezagent.Session.ConfigFork.fork_config/3`（session config_fork.ex:93）——config-only（Invariant #10 无 message history），真授权门是 workspace `:create_session` cap 原样透传进 `Ezagent.Workspace.create_session`（:167）；跨 workspace fail-closed `:cross_workspace_copy_unsupported`（:156）。

**boot 自证**：hello demo（session demo/hello.ex:133）经真 governance（`publish_or_upgrade`）把 hello 发为 scope:public/web_anon_access:true 的 PUBLIC 条目——broken governance 会 boot 时 fail-LOUD。boot 调用点在 `ezagent_plugin_hello` Application（application.ex:59）。builtin `chat`+`socialware` boot seed 进 `workspace://system`（session definition_registry.ex:201）。

**Definition 字段（17 个，session definition.ex:12-28）**：name/version/title/description/uses/bases/shape/views/**roles**/assets/routing_rules/prompt_templates/legends/orchestrator_template_uri/adapters/visibility_policy/owner_policy。顶层无 flavor（在 agent 角色槽携带 :284-286）。三个 enforce 点（`new/1` with 链 :70-83）：退休字段 fail-loud（:313-318）、参与者实例 URI fail-loud（:323-366，`URI.type?(uri,:agent|:user)`）、`:fixed` owner 被拒（:412-425，只准 `%{type: :installer}`）。

**两个"public"正交**（visibility_policy :27）：`web_anon_access`（公网面匿名可看）**自助不需 admin**；`scope:public`（全域跨 ws 可发现）**admin-gated**。admin 只守全域，不守公网面。

**仍是有意边界（不是待补缺口）**：
- **`PluginPackage.Manifest` 仍拒 `:socialware` seed**（core manifest.ex:175-178 / :360-363，seed_ref kind 必须 `:recipe`，"future enhancement — rejected, not a no-op"）——不能把 socialware Definition 打进可分发插件包 manifest.json；socialware seeding 走 imperative（`App.ensure_app`）或 governance publish。
- **Plugin 契约无 `definitions/0` callback**（core plugin.ex:195-244）——插件不能声明式声明 Definition。这是 Allen 有意的 code-vs-config split（#1147/#1152），非缺口。
- **world nav 无独立 `/socialware` 路由**——socialware 面渲在 sessions_table state（socialware rows）。
- **ChatFeedAdapter 当前无插件声明**（advisor vertical 退役）→ `allow_chat_feed` cap subject 不再 boot-published；live chat feed 直接调 ChatFeed（socialware chat_feed_adapter.ex:66-73）。

---

## 沟通方式（硬性要求）

- **说人话，用中文整句**。不要中英夹杂堆概念、不要甩一串术语了事。
- **术语首次出现给一句解释**（例："ActionSet（前身叫 Behavior，处理 action 的模块）"）。
- **代码标识符保留原文**（模块名/函数名/URI/cap，如 `Ezagent.ActionSet.Session`、`session.send`、`entity://<ws>/agent/<name>`）——不要翻译或意译。
- **每个断言带 file:line 或 mix test 输出**。拿不到证据就说"需要现读代码确认"，别编。
- **不堆概念**：先给结论，再给一两条支撑证据（file:line），停。

---

## 项目概览

- **25-app umbrella**，三层 + transport 顶层。app 索引见下表，逐 app 细节见 `references/module-details.md`。
- **DB**：PostgreSQL @ docker `55432`。注意 core 源里 "SQLite" 注释是 stale（真 dep 是 `:postgrex`）；`workspaces`/KB 等确有 SQLite 局部用途（KB 用 exqlite per-KB 文件）。
- **工具链**：mise 固定 OTP27 / Elixir 1.18（隔离）。
- **端口**：dev web `10042`。**admin**：`admin@ezagent.chat` / `worlddev`。
- **两条核心差异（vs typical Phoenix app）**：(1) 是 router 不是 req/resp app——每条 message 没人接收要有人知道（telemetry+DLQ+显式 reject）；(2) 跨 Kind 唯一路径是 dispatch（P14，`Ezagent.Router.dispatch/1` / legacy `Invocation.dispatch/1`），禁 `PubSub.broadcast` 到 inbound topic。

---

## 问答流程

**Step 0 — drift 自查**（每次开始）：本 skill 基线是 `5d540f535`（2026-07-06 全量 re-bootstrap）。先确认当前 worktree HEAD：

```bash
git -C <repo> rev-parse HEAD
git -C <repo> log --oneline -5
```

若 HEAD 已远超基线，警告用户"本 skill 索引到 5d540f535，之后的改动需现读代码确认"，并对相关 app 现读。

**定位 → 读当前代码 → 跑测试（若需）→ 有据回答 → bug 分流**：
1. 用模块索引表定位 app + 入口 file:line。
2. `references/module-details.md` 拿该 app 的 key facts（都带 file:line）。
3. 需要精确/怀疑 stale 时，现读那个 file:line 确认（skill 索引可能滞后于 HEAD）。
4. 涉及"通不通"，跑对应测试（见测试节），贴输出。
5. **bug 分流**：区分 (a) 真 bug（代码与不变式/SPEC 冲突）→ 标 issue、别自作主张绕过、等 Allen；(b) 故意 stub（如 protocol_api `cap_subject` behavior_module: nil 是"API-key auth 在 cap model 之外"，非 bug）；(c) stale 注释/moduledoc（代码对、注释错，见 FAQ）。

**自我演进 3 层**：
- **L1 索引刷新**：发现某 app 已改（rename/新模块/删模块），更新 `references/module-details.md` 对应节 + 本文件模块索引表。
- **L2 基线刷新**：发现新的 landmark PR（新 rename、新 gate、新 track），更新 frontmatter baseline_* + "基线说明" 禁用旧名表。
- **L3 现状刷新**：socialware 等 load-bearing track 有进展（某段从半→通、缺口补上），更新"socialware 生命周期现状"表——这是回答产品能力问题的权威，必须跟代码同步。

---

## 模块索引表（25 app）

层：`C`=core / `D`=domain / `P`=plugin / `T`=transport 顶层。测试为 best-effort（本轮未现跑）。

| app | 层 | 入口 file:line | 职责一句话 |
|---|---|---|---|
| ezagent_core | C | `apps/ezagent_core/lib/ezagent_core/application.ex:9` | dispatch/Kind runtime/CapBAC/URI(v3 6 scheme)/Plugin 契约/Recipe/可靠性原语；零 umbrella dep |
| ezagent_domain_agent | D | `apps/ezagent_domain_agent/lib/ezagent_domain_agent/application.ex:25` | 统一 Agent Kind + flavor(data)/recipe read-model + recipe×flavor materialize；acyclic leaf |
| ezagent_domain_agent_bridge | D | `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex:11` | 到 agent sidecar 的 bridge transport（:subprocess_ws / :in_process_sync） |
| ezagent_domain_external_mirror | D | `apps/ezagent_domain_external_mirror/lib/ezagent_domain_external_mirror/application.ex:76` | 唯一 outbound mirror owner + adapter KIND axis(:push/:pull/:request_scoped) |
| ezagent_domain_identity | D | `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:62` | User Kind + Grant chokepoint(#154) + ConfigStore/CR governance + membership-cap 三真相源 |
| ezagent_domain_pty | D | `apps/ezagent_domain_pty/lib/ezagent_domain_pty/application.ex:32` | PTY sidecar runtime（facade pty.ex:45）+ :write ActionSet；⚠ crash 现场见 FAQ |
| ezagent_domain_python | D | `apps/ezagent_domain_python/application.ex:27` | uv Python 子进程 runtime（JSON-RPC over stdio，facade python.ex） |
| ezagent_domain_session | D | `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:62` | 统一 Session Kind + **整条 socialware 生命周期**；otp_app `:ezagent_domain_instance_message` |
| ezagent_domain_socialware | D | `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/application.ex:19` | customer-feed/external-projection + anon-User 生命周期；两 :pull adapter；无 session Kind |
| ezagent_domain_ui | D | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/application.ex:30` | SessionView 契约+registry(属主) + UI atom/shell 库；无 Kind |
| ezagent_domain_workspace | D | `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:32` | Workspace Kind(:ephemeral) + 统一 provisioning(create_agent/session/user) |
| ezagent_plugin_cc | P | `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:72` | cc/cc-headless flavor + orchestrator MCP transport(12 tool)；无自有 Kind |
| ezagent_plugin_codex | P | `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/application.ex:15` | codex/codex-remote flavor（三/两子进程）；走 SessionManager.run_tool 无 MCP transport |
| ezagent_plugin_curl_agent | P | `apps/ezagent_plugin_curl_agent/lib/ezagent_plugin_curl_agent/application.ex:70` | curl flavor(HTTP-API agent)；fold 后无自有 Kind（STATE Behavior 在 domain_agent） |
| ezagent_plugin_email | P | `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex:36` | email ExternalMirror adapter(:push) + inbound poll；非 socialware |
| ezagent_plugin_feishu | P | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:70` | Feishu 双向 transport（webhook+WSS 入站 / ExternalMirror 出站） |
| ezagent_plugin_hello | P | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:39` | **socialware demo**：三角色(orchestrator/builder/concierge) × role×flavor；page→public_view 匿名可看 |
| ezagent_plugin_kanban | P | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:32` | kanban-as-role（native flavor passive agent）+ GitHub/Miro/markmap connector |
| ezagent_plugin_kb | P | `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/application.ex:36` | kb-as-role，per-KB sqlite FTS5(trigram)，ezagent PG 零行 |
| ezagent_plugin_native | P | `apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex:67` | native(no-engine) flavor host(RF-8)；role agent 通用宿主；NO behaviors/bridge |
| ezagent_plugin_protocol_api | P | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/application.ex:23` | inbound OpenAI-compat HTTP API(:request_scoped)；auth 是真 ApiKeyStore 在 CapBAC 外 |
| ezagent_plugin_py | P | `apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:76` | py flavor(operator Python script agent)；echo/np re-home 进它 |
| ezagent_plugin_world | P | `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex:14` | React/shadcn world UI host + socialware install/discover/author UI + ConversationView(#1199) |
| ezagent_cli | T | `apps/ezagent_cli/lib/mix/tasks/ezagent.ex:44`（→ exec.ex:45） | 分布式-Erlang RPC CLI shell；auth 强制；`mix esr` 已弃用 |
| ezagent_web | T | `apps/ezagent_web/lib/ezagent_web/endpoint.ex:6` | Phoenix HTTP/WS 入口 + socialware feed/anon-ingress transport；聚合 19 个插件 |

---

## 测试

**全部 best-effort，需现跑**（本轮 2026-07-06 全量 bootstrap **未跑任何测试**——只逐文件现读；工具链 mise OTP27/1.18 隔离；MEMORY 记 ~11 个稳定失败是工具链 triage、与代码无关）。

**跑法（umbrella 根，绝不 per-app `cd`）**：
```bash
docker start ezagent-pg-compat-audit-postgres   # 起 disposable Postgres
mise exec -- mix ecto.create && mise exec -- mix ecto.migrate
mise exec -- mix test apps/<app>/test            # 单 app（从 umbrella 根，不 cd 进 app）
mise exec -- mix test apps/<app>/test/path/to/file_test.exs:42   # 单文件/单行
mise exec -- mix ezagent.socialware.check         # socialware conformance gate（12 断言）
```

各 app 关键测试文件见 `references/module-details.md` 对应节。socialware 生命周期测试集中在 `apps/ezagent_domain_session/test/ezagent/socialware/*` + `test/integration/*`。

---

## FAQ / 已知边界（都带 file:line）

- **"Behavior 还是 ActionSet？"** → ActionSet（T1 #1138 rename，core behavior.ex:1，文件名仍 behavior.ex）。但 `Ezagent.BehaviorRegistry` 模块名没改（core behavior_registry.ex:1），CLI/ApiV1 仍用它是对的。
- **"hello 是什么形态？"** → **三角色 × role×flavor on 统一 `Entity.Agent`**（#1168，`roles/0` application.ex:116：`hello.orchestrator`(flavor "hello" 收 chat)、`hello.builder`(flavor "native")、`hello.concierge`(flavor "native")）。chat 只 fan-out 到 orchestrator（唯一 chat member），orchestrator 经 admin-authority TurnDriver 驱动 builder 改页/concierge 答。**旧说法"hello 有自己的 Entity.HelloBuilder Kind / HelloBuilder 是唯一 session 成员 / 无 orchestrator 层"全作废**（entity/hello_builder.ex 已删）。
- **"kanban 形态？"** → kanban-as-role：role `kanban-manager` × flavor `native` 的 passive agent，board state 在 `Entity.Agent` 的 `:kanban` slice。无自有 Kind/Definition/definitions_0（application.ex:44-48，K5 删 resource:// Kind）。socialware track 未触及 kanban。
- **"kb / py 形态？"** → kb = kb-as-role（per-KB exqlite FTS5 trigram，无 Kind，PG 零行）；py = py flavor（operator Python script agent，fold 到 Entity.Agent，echo/np re-home 进它）。
- **"role_name 住哪？"** → **(entity × session) 成员边**（membership edge，#1185 de-bake，session membership.ex do_join 从显式 join facets 取）。agent 自己带的是 **recipe provenance**（从哪个 recipe build，`:sandbox.:recipe` 字段，create 后 immutable）——**同一 uuid agent 能在不同 session 是不同 role**。`{:role, name}` 路由解析走 `:member_by_role` UriQuery（读成员边 role facet，**未改**）；改名的 `:role→:recipe` UriQuery 是"查 agent recipe provenance"那条（kanban shared/world kanban_data 用），不是路由解析。
- **"orchestrator recipe 在哪？"** → cc 插件 builtin role（`OrchestratorRecipe`，cc+codex `roles/0` 注册进 RecipeRegistry，复用同一 recipe）；main 上无独立 pm-coordinator 插件。persona 讲 8 tool，实际 ToolCatalog 12 tool。
- **"github 是独立插件吗？"** → 不是，GitHub connector 内联在 kanban（`EzagentPluginKanban.Github`，纯出站无 webhook）。
- **"session 域为什么叫 instance_message？"** → 历史名：otp_app 是 `:ezagent_domain_instance_message`（`EzagentDomainInstanceMessage.*`），目录已改名 ezagent_domain_session。
- **"双 dispatch？"** → `Ezagent.Router.dispatch/1`（router.ex:79）主路径，`Ezagent.Invocation.dispatch/1`（invocation.ex:118）legacy，都是 sanctioned 入口（有些模块混用）。
- **"几个 effect？"** → 9 个：`:set` / `:emit` / `:dispatch` / `:notify` / `:effect` / `:effect_returning` / `:saga` / `:terminate` / `:halt`。
- **"两个 socialware app 谁拥有生命周期？"** → **ezagent_domain_session** 拥有全套（definition/registry/governance/installation/conformance/manifest_resolver/definition_agents）；`ezagent_domain_socialware` 只是 customer-feed/anon-User substrate（无 session Kind）。
- **"外部读的授权门？"** → 共享 `Ezagent.Session.Membership.authorize/3`（**3 参含 session_uri**，membership_predicate.ex:55，#1175 后要求 caller HOLD 住 session member-cap，revoked ex-member 即便有陈旧 roster 也被拒；socialware 三处 external_feed.ex:402 / chat_feed.ex:137 / gc.ex:212）。`/2` 仍存但只 delegate 到 `/3` 传 nil（:42）——moduledoc 里 "authorize/2" 是 stale。
- **"world 怎么消费 SessionView？"** → **#1199 world 通用消费 registry**：world 自建 `ConversationView`（world-own `@behaviour Ezagent.UI.SessionView`，`view_behavior/0 → nil` 不 cap-gate）注册进 `SessionViewRegistry`；`ConversationData.session_views/2` = `SessionViewRegistry.applicable_views/2`（caller-aware，含 cap 门）；switch_view 白名单动态取 `session_view_ids/2`（cap-gated view 既不出 tab 也不可切，唯一例外 switch_to_pty 硬连 "pty"）。**另一条路** `WorkspacePluginData.plugin_session_tabs/1`（Layer-3 world-side plugin duck-type tab，如 kanban）——两者机制不同别混。SessionViewRegistry 属主在 ezagent_domain_ui。
- **"发 public socialware 要 admin 吗？"** → 全路径都要（governance publish_cr 的 `authorize_public_scope`，+ world save_session_template 穿 caller caps #165，+ domain chokepoint `DefinitionRegistry.authorize_public_scope_write/2` :462）。但 `web_anon_access`（公网面）是自助不需 admin，与 `scope:public` 正交。
- **"routing 被 socialware 波及了吗？"** → 没有。routing rule 是 workspace-scoped（`ActionSet.Routing` 注册在 Workspace Kind）；socialware Definition 有自己的 routing_rules 字段但走 Definition materialize，不改 routing 机制。conformance 要求 routing receiver 只能解析成已声明 role 名。
- **"两个 AdapterRegistry？"** → `Ezagent.AgentBridge.AdapterRegistry`（agent_bridge domain，register/2，flavor-keyed，agent sidecar）≠ `Ezagent.ExternalMirror.AdapterRegistry`（external_mirror domain，register/1，adapter_id-keyed，outbound mirror）。别混。
- **"PTY 为什么会崩（CJK 输出）？"** → forensic：erlexec 按任意字节边界投递 stdout，PTY buffer 含被切断的多字节 UTF-8。三处热点 `apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex:816`（trim_buffer_only 裸字节 binary_part 切片）、`server.ex:313`（snapshot_buffer 同样裸字节尾切）、`server.ex:794`（normalize_ws `~r/\s+/u` **unicode regex**，遇非法 UTF-8 raise → PtyServer crash → PTY 死）。触发链 handle_info({:stdout}) :648 → scan_auto_prompts :671 → AnsiStrip.strip :746 → normalize_ws :794。（三处行号现读确认，实际 raise 行为未跑测试验证——unverified。）
- **"cc 有几个 orchestrator tool？"** → **12**（ToolCatalog tool_catalog.ex:9-283）。moduledoc 多处写 "7/9 tools"（McpServer/McpChannel/CcOrchestratorSeed）是 **STALE**；OrchestratorRecipe persona 列 8 个也非全 12。
- **"cc check_role 只接受 orchestrator 吗？"** → 不，已泛化为接受**任何已注册 role**（`RecipeRegistry.lookup`，cc_agent.ex:370-389，T4 2026-06-28）。旧 OrchestratorBootstrap moduledoc 说 :352 只 default/orchestrator 是 STALE。
- **"protocol_api 是纯 stub 吗？"** → 不。adapter/Binding 是 P0 stub（满足 Grill-5），但**有真 durable ApiKeyStore**（bcrypt `protocol_api_keys` 表）；auth 是 API-KEY 刻意在 CapBAC 之外（dispatch ctx caps 恒空）。两个 latent smell 仍在（`Process.sleep(3000)` + empty-caps dispatch，chat_completions_plug.ex:182-183,191,260）。
- **"#1198 REST mail 在哪？"** → `Ezagent.Mail.EzagentChatAdapter` + `EzagentWeb.Mailer` 在 **ezagent_web**（仅供 magic-link/confirm/reset 认证邮件）；`ezagent_plugin_email` 自己的 Mailer/send 仍 Swoosh SMTP/Local/Test，未获 REST 分支。两 Mailer 不同 otp_app 勿混。

逐 app 的完整 key facts（含更多 file:line）在 **`references/module-details.md`**。
