---
name: project-discussion-esr-ng
description: >-
  项目知识问答 skill（ezagent / esr-ng —— 25-app Elixir/OTP 消息路由 umbrella）。提供有实证支撑的项目知识——
  每个回答都附带 file:line 引用或 mix test 输出，而非凭记忆。覆盖：三层架构（core/domain/plugin）、
  Kind/ActionSet(前 Behavior)/Invocation 契约、CapBAC/URI(SPEC v3 6 scheme)/可靠性原语、
  ActionSet 与 recipe（role=recipe、flavor-as-data）、**socialware 生命周期（author→publish→discover→install→use 全链）**、
  **部署级 seed 车道（SocialwareSeed/ManifestSeed/SkillSeed + ConfigStore 三态 seed 契约）**、skill 分发（SkillRegistry）、
  25 个 umbrella app 的职责与依赖、测试状态与 pipeline。讨论这个项目时**总是先加载本 skill**，即使只是简单的项目问题也应触发。
  验证某模块是否正常工作、处理 bug 分流、查询测试状态时同样触发。
baseline_commit: 63877f425
baseline_branch: "upstream/main (2026-07-09 全量 re-bootstrap)"
baseline_date: 2026-07-09
---

# ezagent / esr-ng 项目知识问答

ESR(Ezagent Session Router) —— Elixir/OTP 消息路由 runtime，multi-channel → multi-agent 编排。
一个 25-app umbrella，三层：**core（L1 机制）→ domain（L2 领域）→ plugin（L3 扩展）**，`ezagent_cli`/`ezagent_web` 是 transport 顶层（P13）。

本 skill 是**项目知识的实证问答层**：回答 ezagent 代码结构/契约/边界的问题，验证某模块是否工作，做 bug 分流。
**与设计原则权威集分工**：架构原则（P1-P26）、CI gate、反模式 refuse 在 `.claude/skills/ezagent-developer/SKILL.md`（写代码/改架构时加载那个）；本 skill 回答 "现在代码是什么样、在哪、通不通"。

---

## 基线说明（禁用旧名）

**基线**：`upstream/main` @ `63877f425`（2026-07-09 **全量 re-bootstrap**，上个基线 49f0167f7/2026-07-06，间隔 ~60 commit：部署级 seed 车道三连 #1231/#1233/#1248、ConfigStore 三态契约 #1242、skill 分发 P1-P3 #1266、治理统一 #1213、点分命名 #1255、生产韧性弧 #1252/#1257/#1259/#1263 等全部吸收进全量索引）。逐 app 细节见 `references/module-details.md`（每条断言带 file:line）。

**到基线为止已落地的重命名/重构（不要再用旧名）**：

| 现名（用这个） | 旧名（禁用） | 出处 file:line |
|---|---|---|
| `Ezagent.ActionSet`（契约模块） | `Ezagent.Behavior` | core behavior.ex:1（**文件名仍 behavior.ex**，模块名是 ActionSet；T1 #1138） |
| `use Ezagent.Lifecycle`（唯一 dev surface） | 手写 `invoke/4` | `invoke/4` 是 `@optional_callbacks` 无 runtime 路径 |
| `Ezagent.Agent.Recipe`（role=flavor-agnostic recipe） | role 作 code / role 作 URL | core agent/recipe.ex；subject `recipe:<名>`（结构化非-URI） |
| `Ezagent.Agent.RecipeAttributes` / `Ezagent.Agent.RecipeResolver` / `Ezagent.Agent.RecipeRegistry`（点分命名） | `Ezagent.AgentRecipeAttributes` / `Ezagent.AgentRecipeResolver`（拼接命名） | #1255 dot-convention；arch gate `concatenated_namespace_modules` cap 0（arch.scan.ex:279-294）；`AgentFlavor*`/`AgentBridge`/`AgentLineage` 在 allowlist **没**改 |
| `Ezagent.ConfigGovernance.Store`（CR 生命周期引擎，identity 域） | `Ezagent.Socialware.ConfigChangeStore` | #1213 PR-A；identity config_governance/store.ex:1 |
| **deploy-seed 单源**：`priv/socialware_seed/<名>/manifest.yaml` → `$EZAGENT_HOME/<profile>/socialware/` | app-priv `priv/socialware/<名>/` 车道、app_sources 扫描、插件 boot 自发布（`maybe_publish_hello_demo` / `Demo.publish/0`） | #1231/#1233/#1248/#1249；arch gate `socialware_priv_manifest_files`（arch.scan.ex:499-501，#1246） |
| `hello.front-desk` recipe（hello 前台，模块名仍 `HelloOrchestrator`） | `hello.orchestrator` recipe 名 | hello application.ex:104；四角色见 FAQ |
| `Definition.roles`（agent 槽 + human 槽） | `Definition.agents` / `.members` | session definition.ex（#1180 退休 agents/members） |
| agent 带 **recipe provenance**（`:sandbox.:recipe`）；`role_name` 只住 (entity×session) 成员边 | agent 级 session role | #1185 de-bake |
| `socialware:<名>`（Definition OPAQUE 非-URI subject，key `socialware`） | Definition 作 URI | session definition_registry.ex |
| orchestrator tool **13 个** | "12 tool"（更旧 "7/9 tool"） | cc orchestrator/mcp_server/tool_catalog.ex `raw_tool_schemas/0`（13 个，加了 add_participant）；domain_session `Ezagent.Orchestrator.Tools.ToolCatalog` 是 fail-closed name guard（fallback 13 名单 :4） |

**没改的别误报**：`Ezagent.BehaviorRegistry` 模块名**没**改（core behavior_registry.ex:1，CLI/ApiV1 仍消费它——正确非 bug）；`Ezagent.ConfigGovernance.Socialware` 模块名没变（#1213 只把文件从 `socialware/config_governance/` 搬到 `config_governance/`）；`Ezagent.Socialware.ConfigStore` 前缀刻意保留（Decision #161 red-line-5 substrate seam，不跟 governance 改名走）。

**四层词 convention（Decision #161，GLOSSARY.md:174 + :1214）**：**Definition**（应用声明"这个 socialware 是什么"）/ **Recipe**（个体配方"这个 agent 怎么做出来"）/ **Manifest**（部署清单"装什么"，$EZAGENT_HOME seed 输入）/ **Registry**（运行时索引"按名字怎么找到"）。辅助后缀 `*Store`/`*Seed`/`*Resolver`/`*Materializer`。回答分层问题用这套词。

---

## 部署级 seed 车道（load-bearing —— 回答"一个 socialware/skill 怎么进系统"的权威）

2026-07-07 起，**socialware 与 skill 都从"代码 boot 自发布"改成"部署目录 seed + 唯一 late 扫描"**。三层机制：

**① FS 复制层（core）**：`Ezagent.Home.SocialwareSeed`（core home/socialware_seed.ex）——`source_dirs/0`（:34-43）泛型发现**任何** loaded OTP app 的 `priv/socialware_seed/<名>/`（现实物全在 `apps/ezagent_web/priv/socialware_seed/{autoservice,hello,kanban}/`），`seed!/1`（:65-92）幂等复制到 `system://socialware`（= `$EZAGENT_HOME/<profile>/socialware/`，经 FsResolver 非裸 Home 路径），已存在的包目录跳过（尊重 operator 手改，:94-102）。纯 FS，无 Repo/dispatch。

**② manifest 扫描层（session 域）**：`Ezagent.Socialware.ManifestSeed`（session socialware/manifest_seed.ex）——`scan_all!/1`（:66-73）是**唯一一次 late 扫描**（sw-home lane #1224），触发点在 `EzagentWeb.Application.start/2` 末尾（ezagent_web application.ex:39，web 是 dep 闭包里最后 boot 的 app，此时所有插件的 view/recipe 已注册）。每个 `<deploy_dir>/*/manifest.yaml` 走 parse→resolve→conformance→**governed publish**（`publish_or_upgrade`），任一失败 raise = fail-loud boot。**默认只在 :prod 开**（config/config.exs:33 `socialware_manifest_boot_scan: config_env() in [:prod]`——dev/test 关，这就是 "manifest boot scan disabled in dev"）。`deploy_dir/1`（:102-119）boot fallback 会先调 `SocialwareSeed.seed!()` 兜底 CI/dev。
YAML interchange 是 `Ezagent.Socialware.ManifestYaml`（manifest_yaml.ex，content-only API：parse/render/import/export）；operator 手动进出走 `mix ezagent.socialware.import` / `export`（唯二文件 IO 点）。

**③ 三态 seed 契约（ConfigStore 原语，#1242）**：`Ezagent.Socialware.ConfigStore.seed_object_upsert/1`（identity socialware/config_store.ex:292-320）——**absent→write**（`:seeded`）/ **same→skip**（content_hash 相同 `:exists`）/ **outdated→upgrade**（`upgradable?` 门 :325-330：`seed_family_prefix` 为 nil 恒升级〔DefinitionRegistry builtin〕，有 prefix 则只升级 seed-family 自己的 turn〔RecipeRegistry role-seed #1240，operator override 存活〕）。upgrade 撞 unique source_turn_id → `{:ok, :already_upgraded}`（crash-restart 幂等 #1235）。消费方：DefinitionRegistry `seed_builtin_definition`（:525-542）、RecipeRegistry `seed_role_if_absent`（:295，同 boot 不同 body = `{:error, {:role_seed_collision, name}}`，跨版本 reflow = upgrade）、SkillSeed 索引。**CI reflow 彩排闸**：`.github/workflows/ci.yml:124` `mix test --include reflow_rehearsal`（旧 DB + 新 seed 路径 boot 彩排）。

**skill 分发（#1266 P1-P3）**：镜像同一套车道——`Ezagent.Home.SkillSeed.boot!/1`（core home/skill_seed.ex:27，触发点 ezagent_web application.ex:28）把各 app `priv/skills_seed/<ref>/`（实物 `apps/ezagent_web/priv/skills_seed/{kanban-assistant,dev-together,ezagent-session-orchestrator}/`）原子复制进 `$EZAGENT_HOME/<profile>/skills/`（`.staging-`/`.old-` rename，operator 改动保留 + `upgrade_skipped` telemetry），再 `Ezagent.SkillRegistry.refresh!`。`Ezagent.SkillRegistry`（core skill_registry.ex）是 **persistent_term read-through 索引**（非 ETS 非 durable）：`resolve/1`（:34）→ `{:ok, {dir, hash}}`，**未 ready 调用 raise = boot 顺序 bug**。recipe 的 `skills: [ref]` 字段就是这些 ref；消费方 = credential/home_runtime.ex:390（装进 agent config_dir）+ cc OrchestratorBootstrap（:207-208）。回填 seed 用 `mix ezagent.skills.regen_seed`（从各插件 `roles/0` 派生 ref、从 `.claude/skills/` 复制，`@requirements ["compile"]` 防 stale beam 掉 ref）。

---

## socialware 生命周期现状（load-bearing —— 回答"能不能发布/发现/安装一个 socialware"的权威）

**author→publish→discover→install→use 全链通**，核心机器全在 **ezagent_domain_session**（不是 ezagent_domain_socialware —— 后者只是 customer-feed/anon-User substrate，无 session Kind）。world 只 CONSUME。

| 段 | 现状 | 入口（file:line） |
|---|---|---|
| **author** | 通，三条路 | ① **deploy manifest**（生产主路）：`priv/socialware_seed/<名>/manifest.yaml` → `ManifestSeed.scan_dir!`（manifest_seed.ex:84-99）；② world 表单：`WorkspacePluginActions.save_session_template/2`（world workspace_plugin_actions.ex）；③ imperative：`EzagentPluginHello.App.ensure_app`（code-author 流，hello app.ex:33-97）。string name-refs → Definition 统一走 `ManifestResolver.resolve/1`（fail-closed） |
| **publish** | 通 | `Ezagent.ConfigGovernance.Socialware`（session config_governance/socialware.ex，**文件已搬家模块名没变**）：`open_cr/2` :43 → `stage_definition/3` :62 → `publish_cr/2` :83；幂等入口 **`publish_or_upgrade/2`（:119-135）**：查 lookup，hash 同 `:exists`、异 `:upgraded`（走完整 CR 链 :137-143）、无 `:published`。PUBLIC scope admin-gated（`authorize_public_scope`→`:public_socialware_requires_admin`） |
| **discover** | 通 | `DefinitionRegistry.list/1`（definition_registry.ex，cross-ws 可见性 + retract 过滤 + 每 name 去重）；world 侧 `socialware_rows/1` |
| **install** | 通 + **requires 依赖** + **卸载** | `Installation.install_template_installs/4`（freeze-pin 到 revision）；**`ensure_requirements/4`（installation.ex:520-541）递归安装 `Definition.requires`**（#1230，空/absent 容错 :520-521——hello requires orchestrator 就靠这个）；**卸载 `retract_session_installs/2`（:187-201，#1245）**：append-only tombstone `%{removed: true}`，`install_state/2`（:565-573）三态 `:removed/:installed/:none` |
| **use** | 通 | `SessionCreator.TemplateTeam → DefinitionAgents.materialize_definition_agents/4`（definition_agents.ex:65），fresh 5 步 pipeline：lookup_recipe → **`HostLoginAdopt.ensure_installer_source`（:157-162，#1209 装机人 host login 经 #17 cascade 传染给物化 agent）** → spawn_and_join（→ `RecipeMaterializer.create_agent_from_recipe`，内部先 `RecipeBehaviorFold.fold` 折 flavor behaviors #1219）→ grant recipe caps LAST |
| **anon 消费** | 通 | public + web_anon_access 的 session 可匿名 VIEW；公开路由在 RequireEntity 外；**`/hello/:session_name` 短链**（web router.ex:193，#1243） |

**conformance 现在 15 断言**（conformance.ex:179-197，原 12）：新增 `requires_published` / `requires_cycle_free` / `routing_role_dag`。`mix ezagent.socialware.check` 是薄 wrapper。

**orchestrator 现在是 builtin socialware definition**（#1223）：`DefinitionRegistry.builtin_definitions/0`（definition_registry.ex:285-306）seed **三个** builtin 进 `workspace://system`：`chat` + `socialware` + **`orchestrator`**（uses:["cc"]，单 role 槽 `%{role_name:"orchestrator", fill: :agent, recipe:"orchestrator", flavor:"cc"}`）。session 要编排器不再直接 spawn，走 `Orchestrator.ensure_orchestrator/3`（entity/session/orchestrator.ex:78）→ `materialize_orchestrator_definition`（:160-176）= install "orchestrator" + materialize_template_team；默认 session template 声明 `installs: ["chat", "orchestrator"]`（application.ex:630-631）。

**routing 声明式 role 编排**（#1212）：rule receiver 支持 `{:role, role_name}` token（core routing/resolver.ex:436-461，经注入 `role_resolver` 回调解析成员边）+ magic tokens `$session_members/$session_users/$mentions`；`Ezagent.Message` 加 `hops` 跳数预算（message.ex:125，默认 8）；conformance `routing_role_dag` 断言防环。hello v2 manifest 的 `from_role viewer → responser`、`responser+[need-build] → builder` 就是这套。落库 trace 表 `routing_traces`（core routing/trace.ex）。

**Definition 字段**：17 个老字段 + **`requires`**（部署依赖清单）。role_slot：agent 槽 `%{role_name, fill: :agent, recipe, flavor}`、human 槽 `%{role_name, fill: :human}`。三个 enforce 点没变（退休字段 fail-loud / 参与者实例 URI fail-loud / `:fixed` owner 被拒）。

**两个"public"正交**：`web_anon_access`（公网面匿名可看）自助不需 admin；`scope:public`（全域跨 ws 可发现）admin-gated。

**仍是有意边界**：`PluginPackage.Manifest` 仍拒 `:socialware` seed_ref（core plugin_package/manifest.ex，socialware 分发走 deploy-seed 车道非 plugin package）；Plugin 契约无 `definitions/0` callback（code-vs-config split）；world nav 无独立 `/socialware` 路由。

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
- **工具链**：CI 固定 OTP 28 / Elixir 1.19；本地应使用同一大版本的隔离工具链。
- **端口**：dev web `10042`。**admin**：`admin@ezagent.chat` / `worlddev`。
- **两条核心差异（vs typical Phoenix app）**：(1) 是 router 不是 req/resp app——每条 message 没人接收要有人知道（telemetry+DLQ+显式 reject；#1259 后 PendingDelivery 溢出也进 DLQ `:buffer_full`）；(2) 跨 Kind 唯一路径是 dispatch（P14，`Ezagent.Router.dispatch/1` / legacy `Invocation.dispatch/1`），禁 `PubSub.broadcast` 到 inbound topic。

---

## 问答流程

**Step 0 — drift 自查**（每次开始）：本 skill 基线是 `63877f425`（2026-07-09 全量 re-bootstrap）。先确认当前 worktree HEAD：

```bash
git -C <repo> rev-parse HEAD
git -C <repo> log --oneline -5
```

若 HEAD 已远超基线，警告用户"本 skill 索引到 63877f425，之后的改动需现读代码确认"，并对相关 app 现读。

**定位 → 读当前代码 → 跑测试（若需）→ 有据回答 → bug 分流**：
1. 用模块索引表定位 app + 入口 file:line。
2. `references/module-details.md` 拿该 app 的 key facts（都带 file:line）。
3. 需要精确/怀疑 stale 时，现读那个 file:line 确认（skill 索引可能滞后于 HEAD）。
4. 涉及"通不通"，跑对应测试（见测试节），贴输出。
5. **bug 分流**：区分 (a) 真 bug（代码与不变式/SPEC 冲突）→ 标 issue、别自作主张绕过、等 Allen；(b) 故意 stub（如 protocol_api `cap_subject` behavior_module: nil 是"API-key auth 在 cap model 之外"，非 bug）；(c) stale 注释/moduledoc（代码对、注释错，见 FAQ）。

**自我演进 3 层**：
- **L1 索引刷新**：发现某 app 已改（rename/新模块/删模块），更新 `references/module-details.md` 对应节 + 本文件模块索引表。
- **L2 基线刷新**：发现新的 landmark PR（新 rename、新 gate、新 track），更新 frontmatter baseline_* + "基线说明" 禁用旧名表。
- **L3 现状刷新**：socialware / seed 车道等 load-bearing track 有进展（某段从半→通、缺口补上），更新对应现状节——这是回答产品能力问题的权威，必须跟代码同步。

---

## 模块索引表（25 app）

层：`C`=core / `D`=domain / `P`=plugin / `T`=transport 顶层。测试为 best-effort（本轮未现跑）。

| app | 层 | 入口 file:line | 职责一句话 |
|---|---|---|---|
| ezagent_core | C | `apps/ezagent_core/lib/ezagent_core/application.ex:9` | dispatch/Kind runtime/CapBAC/URI(v3 6 scheme)/Plugin 契约/Recipe/可靠性原语 + **SocialwareSeed/SkillSeed/SkillRegistry/Utf8Tail/routing role-token**；零 umbrella dep |
| ezagent_domain_agent | D | `apps/ezagent_domain_agent/lib/ezagent_domain_agent/application.ex:25` | 统一 Agent Kind + flavor(data)/recipe read-model + **RecipeBehaviorFold** materialize + **HostLoginAdopt** + `:complete` cap ActionSet；acyclic leaf |
| ezagent_domain_agent_bridge | D | `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex:11` | 到 agent sidecar 的 bridge transport（:subprocess_ws / :in_process_sync） |
| ezagent_domain_external_mirror | D | `apps/ezagent_domain_external_mirror/lib/ezagent_domain_external_mirror/application.ex:76` | 唯一 outbound mirror owner + adapter KIND axis(:push/:pull/:request_scoped) |
| ezagent_domain_identity | D | `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:62` | User Kind + Grant chokepoint(#154) + **ConfigStore 三态 seed 契约** + **ConfigGovernance 统一 CR 引擎（Store/Agent/共享断言）** + membership-cap 三真相源 |
| ezagent_domain_pty | D | `apps/ezagent_domain_pty/lib/ezagent_domain_pty/application.ex:32` | PTY sidecar runtime + :write ActionSet；CJK crash 已修（#1215 Utf8Tail） |
| ezagent_domain_python | D | `apps/ezagent_domain_python/application.ex:27` | uv Python 子进程 runtime（JSON-RPC over stdio，facade python.ex） |
| ezagent_domain_session | D | `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:62` | 统一 Session Kind + **整条 socialware 生命周期 + ManifestSeed/ManifestYaml + DeliveryQueue + orchestrator-as-definition**；otp_app `:ezagent_domain_instance_message` |
| ezagent_domain_socialware | D | `apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/application.ex:19` | customer-feed/external-projection + anon-User 生命周期；两 :pull adapter；无 session Kind |
| ezagent_domain_ui | D | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/application.ex:30` | SessionView 契约+registry(属主) + UI atom/shell 库；无 Kind |
| ezagent_domain_workspace | D | `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:32` | Workspace Kind(:ephemeral) + 统一 provisioning(create_agent/session/user)；RoleStep 走 RecipeBehaviorFold "ONE generic step" |
| ezagent_plugin_cc | P | `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:72` | cc/cc-headless flavor + orchestrator MCP transport(**13 tool**)+OrchestratorRecipe（tool contributions）；无自有 Kind |
| ezagent_plugin_codex | P | `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/application.ex:15` | codex/codex-remote flavor（三/两子进程）；走 SessionManager.run_tool 无 MCP transport |
| ezagent_plugin_curl_agent | P | `apps/ezagent_plugin_curl_agent/lib/ezagent_plugin_curl_agent/application.ex:70` | curl flavor(HTTP-API agent)；`Entity.Agent.complete/3` 同步补全的宿主 flavor（hello llm 角色用） |
| ezagent_plugin_email | P | `apps/ezagent_plugin_email/lib/ezagent_plugin_email/application.ex:36` | email ExternalMirror adapter(:push) + inbound poll；非 socialware |
| ezagent_plugin_feishu | P | `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:70` | Feishu 双向 transport（webhook+WSS 入站 / ExternalMirror 出站） |
| ezagent_plugin_hello | P | `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:39` | **socialware 黄金样板**：四 recipe(front-desk/builder/concierge/**llm**=curl delegation)；发布走 deploy-seed 车道零 boot 自发布 |
| ezagent_plugin_kanban | P | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:32` | kanban-as-role passive agent + **BoardView/KanbanRender view** + kanban_assistant/dev_together recipe；**GitHub 出站连接器已删**（剩纯数据 link）+ Miro/markmap |
| ezagent_plugin_kb | P | `apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/application.ex:36` | kb-as-role，per-KB sqlite FTS5(trigram)，ezagent PG 零行 |
| ezagent_plugin_native | P | `apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex:67` | native(no-engine) flavor host(RF-8)；role agent 通用宿主；NO behaviors/bridge |
| ezagent_plugin_protocol_api | P | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/application.ex:23` | inbound OpenAI-compat HTTP API(:request_scoped)；auth 是真 ApiKeyStore 在 CapBAC 外 |
| ezagent_plugin_py | P | `apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:76` | py flavor(operator Python script agent) + np recipe；echo/np re-home 进它 |
| ezagent_plugin_world | P | `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex:14` | React/shadcn world UI host + socialware install/discover/author/**uninstall** UI + ConversationView |
| ezagent_cli | T | `apps/ezagent_cli/lib/mix/tasks/ezagent.ex:44`（→ exec.ex:45） | 分布式-Erlang RPC CLI shell；auth 强制；`mix esr` 已弃用 |
| ezagent_web | T | `apps/ezagent_web/lib/ezagent_web/endpoint.ex:6` | Phoenix HTTP/WS 入口 + **deploy-seed 实物宿主（priv/socialware_seed + priv/skills_seed）+ 唯一 late scan 触发点**（application.ex:28,39）+ socialware feed/anon-ingress |

---

## 测试

**全部 best-effort，需现跑**（本轮 2026-07-09 全量 bootstrap **未跑任何测试**——只逐文件现读；工具链按 CI 的 OTP 28 / Elixir 1.19 隔离；MEMORY 记 ~11 个稳定失败是工具链 triage、与代码无关）。

**跑法（umbrella 根，绝不 per-app `cd`）**：
```bash
docker start ezagent-pg-compat-audit-postgres   # 起 disposable Postgres
mise exec -- mix ecto.create && mise exec -- mix ecto.migrate
mise exec -- mix test apps/<app>/test            # 单 app（从 umbrella 根，不 cd 进 app）
mise exec -- mix test apps/<app>/test/path/to/file_test.exs:42   # 单文件/单行
mise exec -- mix ezagent.socialware.check         # socialware conformance gate（15 断言）
mise exec -- mix test --include reflow_rehearsal apps/ezagent_domain_session/test/integration/reflow_rehearsal_test.exs   # 三态 seed 契约彩排（CI 同款）
```

各 app 关键测试文件见 `references/module-details.md` 对应节。socialware 生命周期测试集中在 `apps/ezagent_domain_session/test/ezagent/socialware/*` + `test/integration/*`。

---

## FAQ / 已知边界（都带 file:line）

- **"Behavior 还是 ActionSet？"** → ActionSet（T1 #1138 rename，core behavior.ex:1，文件名仍 behavior.ex）。但 `Ezagent.BehaviorRegistry` 模块名没改（core behavior_registry.ex:1），CLI/ApiV1 仍用它是对的。
- **"一个新 socialware 怎么上线？"** → 生产主路是 **deploy-seed 车道**：写 `priv/socialware_seed/<名>/manifest.yaml`（YAML 声明 name/uses/requires/bases/shape/views/roles/routing_rules/visibility_policy）→ boot 时 `SocialwareSeed.seed!` FS 复制 → `ManifestSeed.scan_all!`（web application.ex:39，prod-only）governed publish。**插件 boot 自发布已全部退休**（hello application.ex:46-54 明注 "Zero call from this plugin's boot"）。手动路走 `mix ezagent.socialware.import`。
- **"hello 是什么形态？"** → **四 recipe on 统一 `Entity.Agent`**（application.ex:94-100）：`hello.front-desk`（flavor "hello"，收 chat 的隐形前台，ActionSet 模块仍叫 `HelloOrchestrator`）、`hello.builder`（改页）、`hello.concierge`（只读答）、**`hello.llm`（flavor "curl"，#1243 X2b：Generator 的 LLM 调用 delegation 给 session 自己的 curl member，`Entity.Agent.complete/3`，API key 在该 agent `:api_keys` slice，generator.ex:479-500）**。发布走 deploy-seed（manifest 在 ezagent_web priv，`requires: [orchestrator]`）；v2 seed page 实物 `priv/seed_page/{body.json,shell.css}`（`HELLO_DEMO_SEED=1` 运行时 demo，默认关）。**旧说法"三角色 hello.orchestrator / boot maybe_publish_hello_demo / Demo.Hello.publish"全作废**。
- **"kanban 形态？"** → kanban-as-role passive agent（board state 在 `:kanban` slice）没变，但：**GitHub 出站连接器整体删除**（github.ex 文件已删，sync_github/push_pr/sync_prs/save_github_creds 全移除，剩纯数据 register_pr/attach_code_file，connectors.ex:11-16）；新增 `kanban_assistant`/`dev_together` 两个 recipe（application.ex:84）+ `BoardView`（id :kanban_board，view_behavior KanbanRender cap-gated）；kanban demo socialware 走 deploy-seed 车道（#1248，Demo 模块变薄 YAML loader）。
- **"orchestrator 是什么形态？"** → **builtin socialware definition**（#1223）：`builtin_definitions/0` = chat + socialware + orchestrator（definition_registry.ex:285-306）；session 需要编排器走 install "orchestrator" + materialize（entity/session/orchestrator.ex:160-176），不再直接 spawn。recipe 仍是 cc 插件的 `OrchestratorRecipe`（tool contributions 13 个）。
- **"role_name 住哪？"** → (entity×session) 成员边（#1185 de-bake）。agent 自己带 recipe provenance（`:sandbox.:recipe`，immutable）。同一 uuid agent 能在不同 session 是不同 role。
- **"消息投递会丢吗？"** → 三层兜底：**DeliveryQueue**（#1252，session/delivery_queue.ex，中央 GenServer + per-recipient FIFO + unlinked Task——sender echo 在 handle_send 即回，慢/死 member 只堵自己的 key，失败 Logger.error + routing_traces `delivery_failed`，at-most-once 无重试）；**PendingDelivery 溢出进 DLQ**（#1259，invocation.ex:192 `{:error, :buffer_full}` 不再吞，`pending_delivery_overflow/2` :398 → telemetry + `DLQ.put(:buffer_full)`——py 冷 uv provision 长 not-ready 窗口的修复）；durable 靠 MessageStore。
- **"session 列表冷启动看得到吗？"** → 看得到（#1257）：`Listing.persisted_session_entries/1`（listing.ex:111-144）= live ∪ durable（kind_snapshots 扫描），cold membership 从快照 decode；dedup 键用 `Ezagent.URI.canonical!/1` struct（#1263，非 to_string）；非 admin 按 member_uris 过滤 fail-closed（#1217 W0）。
- **"routing 支持按 role 编排吗？"** → 支持（#1212）：rule receiver `{:role, name}` token（core resolver.ex:436-461）+ `$mentions` 等 magic token + `Message.hops` 预算（默认 8）+ conformance `routing_role_dag` 防环。hello v2 就是纯 config routing（viewer→responser→[need-build]→builder）。
- **"双 dispatch？"** → `Ezagent.Router.dispatch/1`（router.ex:79）主路径，`Ezagent.Invocation.dispatch/1`（invocation.ex）legacy，都是 sanctioned 入口。
- **"几个 effect？"** → 9 个：`:set` / `:emit` / `:dispatch` / `:notify` / `:effect` / `:effect_returning` / `:saga` / `:terminate` / `:halt`。
- **"两个 socialware app 谁拥有生命周期？"** → **ezagent_domain_session** 拥有全套；`ezagent_domain_socialware` 只是 customer-feed/anon-User substrate。
- **"外部读的授权门？"** → 共享 `Ezagent.Session.Membership.authorize/3`（3 参含 session_uri，#1175），caller 须 HOLD session member-cap。
- **"发 public socialware 要 admin 吗？"** → 全路径都要（governance `authorize_public_scope` + domain chokepoint `authorize_public_scope_write/2`）。`web_anon_access` 自助不需 admin，与 `scope:public` 正交。deploy-seed 车道走 `operator_admin_ctx`（manifest_yaml.ex:93-106，system admin caller）所以 manifest 可以声明 scope:public。
- **"PTY 为什么会崩（CJK 输出）？"** → **已修**（#1215）：新 `Ezagent.Utf8Tail.tail/2`（core utf8_tail.ex:25-31，续字节边界感知切尾）替换 pty server.ex 两处裸 `binary_part`（:312-315 / :823-830）；`normalize_ws` 先 `scrub_invalid`（`String.replace_invalid`，server.ex:791-802）再上 `/u` regex。codex AppServer / cc SdkSidecar 同样收编 Utf8Tail。旧 forensic "三处热点必崩" 描述作废。
- **"cc orchestrator 几个 tool？"** → **13**（cc orchestrator/mcp_server/tool_catalog.ex `raw_tool_schemas/0`；比旧 12 多了 add_participant）。schema 归 cc（OrchestratorRecipe.tool_schemas/0 delegate），domain_session 的 `Ezagent.Orchestrator.Tools.ToolCatalog` 只是 fail-closed name guard（读 recipe contributions，fallback 13 名单 :4）。moduledoc 里 "7/9/12 tools" 都是 stale。
- **"ConfigGovernance 有几套？"** → 一套引擎两个 subject（#1213 统一）：共享断言 `Ezagent.ConfigGovernance`（identity config_governance.ex，fetch_cr/assert_status/assert_workspace）+ CR 生命周期引擎 `Ezagent.ConfigGovernance.Store`（前身 ConfigChangeStore，零授权，全委托 ConfigStore）+ agent-subject 策略 `Ezagent.ConfigGovernance.Agent`；dispatch 驱动侧 `Ezagent.ActionSet.ConfigGovernance`（仍 7 action，变薄全 delegate Store）+ socialware-subject `Ezagent.ConfigGovernance.Socialware`（session 域）。substrate 都是 `Ezagent.Socialware.ConfigStore`（前缀刻意不改，red-line-5）。
- **"session 域为什么叫 instance_message？"** → 历史名：otp_app 是 `:ezagent_domain_instance_message`，目录已改名 ezagent_domain_session。
- **"github 是独立插件吗？"** → 不是，而且 kanban 的 GitHub HTTP client 也删了（见 kanban FAQ）；world 侧 kanban_actions 还留着 sync_github 的 UI 引用（读模型侧，纯遗留）。
- **"protocol_api 是纯 stub 吗？"** → 不。adapter/Binding 是 P0 stub，但有真 durable ApiKeyStore（bcrypt）；auth 刻意在 CapBAC 之外。两个 latent smell 仍在（`Process.sleep(3000)` + empty-caps dispatch）。
- **"world 怎么消费 SessionView？"** → registry 路线（`ConversationData.session_views/2` = `SessionViewRegistry.applicable_views/2` caller-aware 含 cap 门）vs Layer-3 plugin duck-type tab（`WorkspacePluginData.plugin_session_tabs/1`）两条别混；switch_view 白名单动态。kanban 现在也有 registry view 了（BoardView）。
- **"最新 Decision 到几号？"** → **#161**（GLOSSARY.md:174，四层词 convention）。#160 = `agents[].flavor` flavor routing。

逐 app 的完整 key facts（含更多 file:line）在 **`references/module-details.md`**。
