# ezagent / esr-ng —— 25 app 详细汇总

> **基线：`upstream/main` @ `63877f425`（2026-07-09 全量 re-bootstrap）。**
> 本文件在 49f0167f7（2026-07-06）全量索引基础上，把 49f0167f7..63877f425 约 60 个 commit 的变化并入（改动大的节全量重写，未动的节保留）。每条断言尽量带 `file:line`（现读取证，未二次编造）。
> 本轮（49f0167f7..HEAD）生产 lib 字节未动的 app：external_mirror / python / socialware(domain) / curl / email / feishu / kb / native / protocol_api / cli —— 这些节沿用上轮全量索引。
> 测试状态一律 best-effort，本轮 bootstrap **未现跑**（需与 CI 一致的 OTP 28 / Elixir 1.19 隔离工具链 + Postgres）。
>
> 三层（P9 "读什么数据决定归属"）：**core（L1 机制）→ domain（L2 领域）→ plugin（L3 扩展）**；`ezagent_cli` / `ezagent_web` 是 transport 顶层（P13）。
> 已裁决冲突：`Ezagent.Session.Membership.authorize` 现役是 **3 参**（`authorize(slice, caller, session_uri)`，membership_predicate.ex:55），`/2` 仍存但只 delegate 到 `/3` 传 nil（:42）；socialware 三处读全传 session_uri（external_feed.ex:402 / chat_feed.ex:137 / gc.ex:212）。moduledoc 里 "authorize/2" 是 stale。
> 四层词（Decision #161）：Definition（应用声明）/ Recipe（个体配方）/ Manifest（部署清单）/ Registry（运行时索引）；辅助后缀 `*Store`/`*Seed`/`*Resolver`/`*Materializer`。

---

## L1 core

### ezagent_core（L1 core，tier-agnostic 机制库；零 umbrella dep）

- **entry**：`apps/ezagent_core/lib/ezagent_core/application.ex:9`（`EzagentCore.Application.start/2` 监督树）。dispatch 入口 `lib/ezagent/router.ex:79`（`Router.dispatch/1`）+ legacy `lib/ezagent/invocation.ex`（`Invocation.dispatch/1`）。
- **拥有**：dispatch pipeline、Kind actor runtime（GenServer + snapshot/event-log + 可靠性原语）、ActionSet 契约 + effect 语法、CapBAC、URI SPEC v3（6 scheme）、Plugin 授权契约 + 两阶段声明式 boot、PluginPackage manifest、flavor-agnostic Recipe、routing registry/matcher/**role-token resolver + trace**、audit、**Home deploy-seed 车道（SocialwareSeed/SkillSeed）+ SkillRegistry + Utf8Tail**。

**Dispatch 三原语（Router / ActionSet / Kind）**
- `Ezagent.Router` — dispatch 原语，`%Cmd{}` → 13 步 middleware pipeline；Phase 1 策略翻译成 `%Invocation{}` 复用 legacy 路径（router.ex:79 dispatch/1）。
- `Ezagent.Invocation` — universal request 形状 + 12 步 dispatch 契约。**#1259 修 silent drop**：`{:not_ready, :cast}` 分支（:192）不再吞 `PendingDelivery.buffer/2` 的 `{:error, :buffer_full}`——新私有 `pending_delivery_overflow/2`（:398）loud `Logger.error` + telemetry `[:ezagent, :dispatch, :pending_delivery_overflow]` + best-effort `Ezagent.DLQ.put(:buffer_full, inv)`，返回 `{:error, :buffer_full}`。cold-activation budget 默认 20_000ms。
- `Ezagent.DLQ` — 新 reason `:buffer_full`（dlq.ex:26-32，#1259）；`Ezagent.PendingDelivery` moduledoc 更新（溢出进 DLQ，Decision #67 wiring）。
- `Ezagent.Message` — **新 `hops` 字段**（message.ex:125，`field :hops, :integer, default: 8`，#1212）：非负路由跳数预算，声明式 role 编排的防环预算。
- `Ezagent.ActionSet` — 契约模块（**T1 rename**：文件仍 `lib/ezagent/behavior.ex:1`，模块名 `Ezagent.ActionSet`）；`use ...` + `action` 宏 + `handle_<action>/2` → `{:ok, result, [effect]}`。9 effect。**开发者唯一 surface 是 `use Ezagent.Lifecycle`**。**例外**：`Ezagent.BehaviorRegistry` 模块名**没**改（behavior_registry.ex:1，CLI/ApiV1 仍消费——正确非 bug）。
- `Ezagent.Kind` — Kind 声明宏（kind.ex）；runtime `kind/runtime.ex`、GenServer host `kind/server.ex`、snapshot `kind/snapshot.ex` + `kind/state_rebuilder.ex`。`Ezagent.Kind.Runtime.Receipt`（#1193 cross-workspace receipt）与 `Ezagent.Kind.CascadeHook`（#161-B slice-mutation emit chokepoint）沿革不变。
- `Ezagent.Entity.System`（entity/system.ex:1）— core 唯一 Kind；boot spawn `system://routing/default`。

**Home deploy-seed 车道（本轮新增，SPEC §4）**
- `Ezagent.Home.SocialwareSeed`（home/socialware_seed.ex）— socialware 包的 FS 复制层。`@source_rel "socialware_seed"`（:27）；`source_dirs/0`（:34-43）泛型发现任何 loaded app 的 `priv/socialware_seed`（不硬编码 ezagent_web）；`seed!/1`（:65-92）经 `Ezagent.System.FsResolver.path!(URI.system_principal("socialware"))` 解析目的地 `$EZAGENT_HOME/<profile>/socialware/`（:72，sanctioned system:// seam 非裸 Home）；`seed_one/2`（:94-102）已存在包目录跳过（operator 手改幂等保留）。纯 FS 无 Repo/dispatch，层洁净。
- `Ezagent.Home.SkillSeed`（home/skill_seed.ex，#1266 P2）— skill 目录 deploy-seed 安装器。`boot!/1`（:27）= recover! 崩溃残留 → seed! 字节 → `SkillRegistry.refresh!(runtime_dir: dest)`（:29-30，SkillSeed 就是让 SkillRegistry ready 的东西）。`seed!/1`（:87）per skill `seed_one`（:129）：新装 copy 或 `reconcile_existing`（:145，shipped-hash 对账 4 分支 :149-167——operator 编辑保留，跳过升级发 telemetry `[:ezagent, :skill_seed, :upgrade_skipped]` :221-238）；`.staging-`/`.old-` 原子 rename crash-safe（atomic_replace/3 :170-185）。写索引对象进 ConfigStore（`maybe_upsert_index/3` :189-208，layer "workspace"、key "skill"、subject `skill:<ref>`、`@seed_family_prefix "skill-seed"`——与 role-seed 同一套三态 upsert 纪律）。
- `Ezagent.SkillRegistry`（skill_registry.ex，#1266 P1）— "Read-through index for deployed agent skills"。存储 **`:persistent_term`**（:22-23，非 ETS 非 durable，boot 扫盘重建）。entry = `ref => {dir, hash}`（dir=运行时 skill 源目录，hash=目录闭包 sha256 :59-65；ref=含 SKILL.md marker 的子目录名 :184-197）。`resolve/1`（:34）→ `{:ok, {dir, hash}}`；**未 ready 调用 raise（:35-39）= boot 顺序 bug**。`refresh!/1`（:56，扫单一 runtime origin `system://skills` :178-182）；`seed_bundle_refs/0`（:91）；`derived_recipe_skill_refs/0,1`（:107/:120，从各 `ezagent_plugin_*` 模块 `roles/0` 经 `Recipe.new/1` 校验后收集 `.skills` :226-239）；`dir_hash/1`（:163，`{relpath, exec_bit, content_digest}` 决定性闭包 hash，symlink 按 link target hash 不 follow :248-272）。消费方：`credential/home_runtime.ex:390`（skill 内容装进 agent config_dir）+ cc `OrchestratorBootstrap`（:207-208）。
- `Mix.Tasks.Ezagent.Skills.RegenSeed`（mix/tasks/ezagent.skills.regen_seed.ex）— 从各插件 `roles/0` 派生 ref、从 `.claude/skills/<ref>/` 复制重生成 `apps/ezagent_web/priv/skills_seed`（:31-50）。**`@requirements ["compile"]`（:21）钉死 fresh beam**——没有它 regen 会从 stale `_build` 派生静默掉新 ref（2026-07-09 #1266 事故 :13-17）。

**可靠性原语（P22，全在 core，boot 于 application.ex）**
- ReadyGate / PendingDelivery / Idempotency+Sweeper / DLQ / Audit.Writer / Snapshot.Writer（`:test` 跳的 skip 逻辑 + invariant 双向 pin 不变）。
- `Ezagent.Utf8Tail`（utf8_tail.ex，**#1215 新**）— UTF-8 codepoint 边界感知切尾。`tail/2`（:25-31），`advance_past_continuation`（:36-44）跳过 `0x80..0xBF` 续字节（最多 3）让 slice 落在 codepoint 边界；moduledoc :1-18 解释裸 `binary_part` 在 CJK 流 2/3 概率切中 codepoint 中间。消费方：pty Server、codex AppServer、cc SdkSidecar。

**CapBAC / URI**
- `Ezagent.Capability`（capability.ex）+ `CapabilityRegistry`；`Ezagent.URI`（uri.ex，6 scheme `entity/workspace/session/template/resource/system`，`@unified_per_tenant_schemes` 3-segment authority）+ `uri_query.ex`。本轮未变。

**Plugin 契约 + 热装**
- `Ezagent.Plugin`（plugin.ex）：callback = `plugin_info/0` 必需 + 可选 kinds/behaviors/spawns(RESERVED 必 [])/template_classes/agent_flavors/roles/adapters/routing_tables/resource_types/config_surface/children/after_boot。boot `publish/1` 流程与 RoleSeedHook seed 序不变（roles/0 的 recipe seed 在 `:test` 跳）。
- `Ezagent.PluginPackage.Manifest`（plugin_package/manifest.ex）：**仍拒 `:socialware` seed_ref**（socialware 分发走 deploy-seed 车道，不走 plugin package）。

**Recipe 原语（flavor-agnostic）**
- `Ezagent.Agent.Recipe`（agent/recipe.ex）：defstruct `name/passive/skills/plugins/prompt/script/behaviors/requested_caps/contributions/session_template/config`（:47-57，**新 `contributions: %{}`**——如 cc OrchestratorRecipe 的 `%{tools: ...}`）。`skills :: [skill_ref()] = [String.t()]`（:59/:213-217，SkillRegistry ref）。`@flavor_fields` 拒收 flavor/kind/bridge_adapter/template_class（:34/:94）；behaviors 归一到 loaded ActionSet 模块（:260-262）；requested_caps 禁 materialization 轴（:41/:289-296）。
- `Ezagent.Agent.Recipe.Compose`（compose.ex）：`materialize/2`（:57）→ materialized map（:37-48）= `behaviors`（role ++ flavor 去重 :67）+ `contributions` + `passive` + `recipe: role.name`（P2 provenance :80）+ **`sandbox_content: %{skills, plugins, prompt, script}`**（:81-89）。**caps 刻意不在这里 compose**（:19-31，authz+mint 推迟到 materialization 步）。

**Routing（#1212 声明式 role 编排）**
- `routing/resolver.ex`：receiver 支持 **`{:role, role_name}` token**——`expand_receiver/7`（:436-461）经注入的 `role_resolver.(role_name, %{message, session_uri, members, workspace_uri})` 回调解析成 URI；无 resolver fall-through `[]`（:463-472）。magic tokens `$session_members`/`$session_users`/`$mentions`（:19-38 moduledoc；`{:magic, token}` :408-410）。
- `routing/matcher.ex`：5 leaf（mention/from/text_contains/text_matches/always）+ 3 combinator（all_of/any_of/negate），纯 JSON-serializable tuple（:1-45）。
- `routing/trace.ex`（**新**）：Ecto schema `routing_traces`（message_id/workspace_uri/rule_id/receivers/hop/drop_reason，:12-30）——delivery_failed/delivery_dropped 也写此表。
- RuleStore boot 水化 durable rule（G1-b）不变。

**arch gate / mix task**
- `mix ezagent.arch.scan`：**两个新 gate**——(1) `concatenated_namespace_modules`（cap 0，:279-294 意图注释 + :962 实现 + :450 上报）：同 app 内 `Ezagent.Xyz` 已是点分 namespace 时禁再出现单段 `Ezagent.XyzAbc`；allowlist `@concatenated_namespace_allowlist`（:295+，`AgentFlavor*`/`AgentPassiveAttributes`/`AgentBridge`/`AgentLineage`/`AgentManifest` 等 sanctioned 拼接名），两个真 offender 已改名 `Ezagent.Agent.Recipe*`（#1255）。(2) `socialware_priv_manifest_files`（:448 注册 / :499-501 glob `apps/*/priv/socialware/*/manifest.yaml`，#1246）：app-priv 下发现 manifest = 违规，必须搬 `priv/socialware_seed/<名>/`（注意源目录名是 `socialware_seed` 非 `socialware`）。
- `mix ezagent.check_invariants`（8 硬不变式 grep）、`ezagent.doc.scan`、`caps.audit`、`uri_query.scan`、home init/backup/restore、snapshot 工具等不变；新增 `ezagent.skills.regen_seed`（见上）。
- Credential 子系统（credential/*.ex）：`home_runtime.ex` 新增 skill 内容安装点（:390 `SkillRegistry.resolve(ref)`）。EventLog/SnapshotStore/SagaRunner/MessageStore/SliceChange/NotificationSubscriptions/Presence/Audit/Runtime(erlexec)/Home 沿革不变；`Home.skeleton_dirs/0` 含 `:socialware` 与 `:skills`（home.ex:74）。

**对外契约 / 易混淆点**
- **P14 dispatch-only**：inbound 唯一路径 `Router.dispatch/1` / legacy `Invocation.dispatch/1`。
- **`Ezagent.Behavior` 文件名 vs `Ezagent.ActionSet` 模块名**：T1 后契约模块叫 ActionSet，文件仍 behavior.ex。
- **层纯度**：mix.exs 只声明 Hex deps，零 umbrella dep。"SQLite" 注释 stale（真 dep `:postgrex`）。
- **SkillRegistry 是 content-ref 索引不是声明权威**：谁"该有"某 skill 由 recipe.skills 声明，SkillRegistry 只回答"这个 ref 的字节在哪 + hash 是什么"。

**自 49f0167f7（本轮）**：新增 home/socialware_seed.ex、home/skill_seed.ex、skill_registry.ex、utf8_tail.ex、routing/trace.ex、mix/tasks/ezagent.skills.regen_seed.ex；invocation/dlq/pending_delivery（#1259 buffer_full→DLQ）；message.ex（#1212 hops）；routing matcher/resolver（#1212 role token）；recipe.ex/compose.ex（contributions + sandbox_content）；arch.scan（两新 gate）；credential/home_runtime（skill 安装点）；behavior/sandbox.ex、agent/credential_adapter.ex、fs_resolver 等配套小改。

**测试**：`test/` 下 ~252+ 个 `*_test.exs`（best-effort）：architecture/（含 socialware_seed_path_test.exs 新 gate 基线）、invariants/、e2e/、integration/、ezagent/、mix/。

---

## L2 domain

### ezagent_domain_agent（Tier-2 Domain LEAF）

- **entry**：`apps/ezagent_domain_agent/lib/ezagent_domain_agent/application.ex:25`。**tier/deps**：im→session→agent 的 LEAF；只 dep core + identity + agent_bridge，从不 dep session/im 或 plugin。
- **拥有**：统一 Agent Kind + AgentTemplate Kind、`agent.receive`→AgentBridge 交付缝、flavor 数据簇、role=recipe 读模型（RecipeRegistry）+ recipe×flavor 物化（RecipeMaterializer/**RecipeBehaviorFold**/DefaultAgentSeed）+ 两个 reparented flavor Behavior（CcHeadlessAgent/CurlAgent）+ **HostLoginAdopt** + **`:complete` cap ActionSet**。

- `Ezagent.Entity.Agent`（agent.ex:1）— Agent Kind（`type_name :agent`）。persistence `{:snapshot,:on_change}`。`behaviors/0` = base ∪ 每注册 flavor 的 `instance_behaviors` thunk；**新增 `Ezagent.ActionSet.Agent.Complete` 挂载**（agent.ex:512）+ **`complete/3` 直调函数**（curl flavor 同步 LLM 补全，非 dispatch——hello llm delegation 的被调方）。
- `Ezagent.ActionSet.Agent.Complete`（behavior/agent/complete.ex，**新**）— capability-only Behavior：`action(:complete, args: %{prompt}, returns: %{content}, caps: [:complete], modes: [:call])`（:14-20）；`handle_complete/2` **no-op**（:27）——只注册 `:complete` cap subject，真调用是 `Entity.Agent.complete/3` 直接函数调用（:6-9）。
- `Ezagent.Agent.RecipeBehaviorFold`（agent/recipe_behavior_fold.ex，**新，#1219/#1266 P3**）— recipe×flavor behavior 组合唯一收口。`fold/2`（:18）：`(%Recipe{}, flavor)` → lookup flavor decl（AgentFlavorRegistry）→ `flavor_behavior_set`（instance_behaviors thunk 或 `Kind.nil_capture_behavior_set` :37）→ `Recipe.Compose.materialize`（:19-22）。调用方：RecipeMaterializer（recipe_materializer.ex:102）+ workspace RoleStep（role_step.ex:95）——**两条物化路共用一个 fold，behaviors 在 spawn 前组合完毕**。
- `Ezagent.Agent.RecipeMaterializer`（agent/recipe_materializer.ex）— `create_agent_from_recipe/1` 现收 **spawn_opts map**（:24-37），pipeline（:101-121）：normalize_recipe → **RecipeBehaviorFold.fold** → `template_content/2`（:47，recipe.skills → template 的 **`desired_skills`** :73，另 plugins/prompt/script 条件并入 :74-76）→ spawn_from_content（folded `:behaviors` 作 behavior_overlay）→ `record_launch_attributes`（:216，只写 build provenance `Ezagent.Agent.RecipeAttributes.put` :217，Gate B）。
- `Ezagent.Agent.HostLoginAdopt`（agent/host_login_adopt.ex，**新，#1209 / #1201 A②**）— spawn 前幂等把 HOST OPERATOR（genesis admin）的宿主登录收编成 durable #17 user-default credential source，让 socialware 物化的 agent 继承装机人登录（否则 boot "Not logged in"）。入口 `ensure_installer_source/3`（:68，installer_uri×workspace×flavor）；no-op 阶梯（非 credentialled flavor / 无宿主登录 / 非 admin installer / 已有非我方指针）；`adopt/4`（:87）→ `register_source/4`（:126）+ cap-checked `UserDefaultSource.set_via_dispatch/3`（:149-160）；admin 门 `require_host_operator/1`（:187）。调用方：session definition_agents.ex:158。
- `Ezagent.Agent.RecipeRegistry`（agent/recipe_registry.ex:1，**模块名已点分**）— role name→recipe read-through over ConfigStore。ETS `@table :ezagent_role_registry`（:68，invalidate-on-publish cache 非权威）；layer "workspace"（:84）、key "recipe"（:81）、subject `recipe:<name>`（:122-125）。`lookup/1,2`（:137/:147）ETS→caller-ws→system-ws→rehydrate+canonicalize（:161-244）。**#1240 role-seed upgrade**：`seed_role_if_absent/2`（:295）——per-boot collision guard `boot_seed_collision/2`（:308/:361-367，persistent_term）+ 三态委托 `ConfigStore.seed_object_upsert/1`（:318-329）；`@seed_family_prefix "role-seed"`（:91），seed turn `role-seed:<ws>:<name>`（:378）、upgrade turn `role-seed-upgrade:<ws>:<name>:<hash>`（:380）——**同 boot 两插件不同 body = `{:error, {:role_seed_collision, name}}`；跨版本 reflow（DB 旧 body、无 per-boot 记录）= UPGRADE**。`retire_role/1`（:404，只删 seed-family 对象 :419）；`validate_data_role_recipe/1`（:459，用户作 role 禁 script）。
- `Ezagent.Agent.RecipeAttributes`（agent/recipe_attributes.ex:1，**#1255 从 `Ezagent.AgentRecipeAttributes` 点分改名**）— per-URI recipe(build-provenance) ETS `:ezagent_agent_recipe_attributes`（:44）；durable 真相在 `:sandbox.:recipe`。
- `Ezagent.Agent.RecipeResolver`（agent/recipe_resolver.ex:1，**#1255 从 `Ezagent.AgentRecipeResolver` 点分改名**）— recipe-provenance LIST 读模型；`list_by_recipe/2`（:52，kind_snapshots 扫 live+dormant）、`recipe_from_durable_snapshot/1`（:89）。
- 其余沿革不变：`Ezagent.ActionSet.Agent.Receive`（member-cap 授权在 handler TOP，CLASS TAG 分支）、`Delivery`（flavor 三层解析）、`AgentFlavorRegistry`（seal 机制）、`AgentFlavorResolver`（durable snapshot 回退，#1203）、`AgentFlavorAttributes`/`AgentPassiveAttributes`、`Agent.Config`、`Agent.CredentialStatus`（#160）、`TemplateSpawn`（#1202 fire-and-forget cast）+ Cascade、`ActionSet.CcHeadlessAgent`/`CurlAgent`（reparented STATE 半）、`Mix.Tasks...GrantRecipeCaps`、`DefaultAgentSeed`、hooks、EtsOwner。
- **易混淆点**：flavor 是 DATA 非 code；`Agent.RecipeAttributes`(build-provenance) ≠ session role_name（成员边，Gate B）；`agent.receive` flavor-BLIND；`:complete` 是 cap-subject-only ActionSet（handler no-op，真路径直调）；frozen supervisor 名 `EzagentDomainInstanceMessage.AgentSupervisor` 未改。

**自 49f0167f7（本轮）**：新 recipe_behavior_fold.ex / host_login_adopt.ex / behavior/agent/complete.ex；recipe_attributes/recipe_resolver 点分改名（#1255）；recipe_materializer 重构（fold 前置 + desired_skills）；recipe_registry 三态 seed upgrade（#1240）；entity/agent + template_spawn/cascade 配套（#1209/#1219）；application/ets_owner 小改。

**测试**：13+ 个测试文件（recipe_registry/flavor/credential_status/grant_recipe_caps 等 + 新 fold/host-login 相关）。

### ezagent_domain_agent_bridge（Tier-2 Domain；声明 NO Kind/ActionSet/recipe/flavor）

- **entry**：`apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex:11`（`Ezagent.AgentBridge.deliver/2` 门面）。deps 只 core + phoenix + yaml_elixir。**本轮仅 #1243 触及 agent_bridge.ex（curl delegation 配套小改），机制不变**。
- **拥有**：flavor→adapter 解析 + 两 transport class（`:subprocess_ws` vs `:in_process_sync`）+ `agent_uri→channel_pid` ETS registry + per-agent connect-token store + Phoenix Socket/Channel + self-healing delivery。
- `Ezagent.AgentBridge` — `deliver/2` 按 `resolve_flavor` + `AdapterRegistry.transport_class` 分支：`:in_process_sync` 绕 Channel 同步 `adapter.deliver(payload, nil)`；`:subprocess_ws` channel 查找 + `deliver_or_buffer`。`deliver_ensuring/3` 自愈消失 bridge。
- `Ezagent.AgentBridge.AdapterRegistry` — flavor→adapter GenServer 注册；transport_class 缺省 `:subprocess_ws`；buffer TTL 5s/百条 drain-on-register。**≠ `Ezagent.ExternalMirror.AdapterRegistry`（adapter_id-keyed，别 app）**。
- `Registry`（`bind/3` 幂等、`unbind/2` PID-GUARDED）、`Adapter`（transport-neutral behaviour，`deliver/2` 返 `:ok | {:ok,term} | {:error,term}` 勿窄化）、`Channel`（topic `agent_bridge:<flavor>:<uri>`）、`Socket`、`TokenStore`、`Payload`、`AttachmentNormalizer` 全沿革不变。

### ezagent_domain_external_mirror（domain tier；invariant 15 — 拥有每一条 OUTBOUND mirror）

- **entry**：`lib/ezagent_domain_external_mirror/application.ex:76`。**本轮零 commit（字节相同）**。
- **拥有**：Publisher 契约 + Session 上 bind/unbind/list Behavior + forgery-proof cap-gated facade + per-binding Worker Kind + AdapterRegistry/BindingRegistry + adapter KIND 轴（push/pull/request_scoped）。deps 只 core + identity（刻意不 dep session）。
- `Adapter`（KIND 轴 `kind_of/1` :394 默认 `:push`、`delivery_discipline_of/1` :411、`participation_profile_of/1` :425、`render/3` chokepoint :440）；`Gates.run_all/4`（:102，session-bind-cap → lookup → check_adapter_bindable（pull → `:not_bindable`）→ per-adapter-allow-cap → workspace-iso → target_ownership_check bounded Task）；`AdapterRegistry`（`register/1` :87 insert_new + `assert_no_binding_for_pull!` :272 + per-kind callback 强制 :155-180）；`AdapterInstall`（`install/1` :82 注册 `allow_<adapter_id>` cap + 仅 push reconcile + spawn Worker）；`ActionSet.ExternalMirror`（Session 上 bind/unbind/list，nonce 两步 bind，`:external_mirror` slice 是 SoT）；`ActionSet.ExternalMirrorWorker` + `Entity.ExternalMirrorWorker`（`:ephemeral`，custom spawn 两层 supervisor）；`ExternalMirror` facade（`bind/4` 唯一跑 adapter I/O）；`ActionSet.Publisher`（4 callback，V1 唯一实现 Entity.Session）。CLI mix tasks Bind/Unbind/ListBindings/ListAdapters。
- **易混淆点**：adapter KIND 三轴；`target_ownership_check/2` 是唯一许可的 adapter I/O，禁 re-enter dispatch（invariant #17）；两个 AdapterRegistry 别混。
- **测试**：33 个。

### ezagent_domain_identity（domain / L2，core-team owned，非 pluggable）

- **entry**：`lib/ezagent_domain_identity/application.ex:62`；注册相位在 supervisor 前 `register_identity_behaviors/0` + `ConfigProjection.register/0`。
- **拥有**：统一身份域——User Kind + CapBAC 数据槽（`:identity`）、统一 grant chokepoint、users/entity_tokens/profiles/invite/magic-link 表 + 认证 facade、per-agent 凭证与默认凭证源治理、**agent-owned durable config 演进 + 统一 CR 治理引擎（#1213）**、**ConfigStore 三态 seed 契约（#1242）**、membership-cap 授权三真相源、邮件配置 facade。

**Kind + 启动 / Identity ActionSet / Grant chokepoint / membership-cap 三真相源**（沿革不变）
- `Ezagent.Entity.User`（唯一 Kind，`default_caps/1 → []` Decision #154）；`Ezagent.ActionSet.Identity`（`:identity` 槽 caps MapSet + `:cascade_notify_managers` #161-B）+ `IdentityAdmin`（grant/revoke，授权者集 {self, admin, manager-of-target}）；`Ezagent.Identity.Grant`（每 grant/revoke 唯一入口，`prepare/4` 派生 granted_by，4-tag authorization）；`Ezagent.Identity`（读 facade：list_caps_for/caps_authorize?/read_entity_caps/admin?）；`AdminAuthority`；`Identity.Authority`（manages?/2 = durable caps 判定，owner-approval 依据）；`Identity.Cascade`（managers_of + content-free notify）；`Ezagent.Session.MemberReceive`（authorize/1 读接收方 identity slice 的 member-cap，住 identity 域）。
- 凭证/授权 ActionSet cluster（ApiKeys 挂 Agent、UserCredentials/UserTokens、WorkspaceUserAdmin、CredentialGrant、UserDefaultCredentialSource、WorkspaceSharedCredentialSource）与注册/认证 cluster（Users/Entity/Token/Profile/InviteCode/MagicLinkToken/Registration/AppSettings/SmtpOpts）沿革不变。

**ConfigStore + 三态 seed 契约（#1242，本轮重点）**
- `Ezagent.Socialware.ConfigStore`（socialware/config_store.ex，**前缀刻意保留**——Decision #161 red-line-5 substrate seam）— 不可变 config 对象 + high-layer cascade 指针；唯一公开 durable 写 `write_and_point/1`。
- **`seed_object_if_no_pointer/1`**（:130-134 spec，impl :136-168）— 两态 + 同 boot collision guard：`{:ok, :seeded}`（无指针）/ `{:ok, :exists}`（同 body）/ `{:error, collision_tag}`（同 seed turn 不同 body）；race-safe（on_conflict :nothing + 单次有界重试 :159-163）；指针已存在分支三 cond（:221-225：同 body→exists；异 body 同 turn→collision；异 body 异 turn→exists，override 存活）。
- **`seed_object_upsert/1`**（:292-320）— **完整三/四态契约**：`:none`→`seed_object_if_no_pointer`（absent→write）；content_hash 相同→`{:ok, :exists}`（same→skip）；否则 `upgradable?`→`upgrade_object` else exists（outdated→upgrade）。返回 `{:ok, :seeded | :exists | :already_upgraded} | {:error, term}`（:293）。`upgradable?/2`（:325-330）：nil prefix 恒升级（DefinitionRegistry builtin §5.2）；string prefix 只升级 `String.starts_with?` 的 seed-family turn（RecipeRegistry §4.2 override 安全）。`upgrade_object/1`（:337-355）append 新对象 + repoint under `:upgrade_source_turn_id`；unique 撞→`{:ok, :already_upgraded}`（#1235 幂等）。moduledoc :239-241：把 DefinitionRegistry（#1235）和 RecipeRegistry（#1240）手搓模式收编进一处。
- `Ezagent.Socialware.ContentHash`（content_hash.ex，单算法源 SHA-256）不变。

**ConfigGovernance 统一（#1213 PR-A，本轮重点）**
- `Ezagent.ConfigGovernance`（config_governance.ex:1，**新**）— subject-agnostic CR 共享断言：`fetch_cr/1`（:16，`:none`→`{:error, :cr_not_found}`）、`assert_status/2`（:25-27）、`assert_workspace/2`（:33）。subject 策略与可观测 error term 留给各 caller。
- `Ezagent.ConfigGovernance.Agent`（config_governance/agent.ex:1，**新**）— agent-subject 策略：`assert_agent_subject/1`（:12）、`assert_self_cr/2`（:21，CE-1 self-binding）。
- `Ezagent.ConfigGovernance.Store`（config_governance/store.ex:1，**从 socialware/config_change_store.ex 改名**，旧模块名 `ConfigChangeStore` 禁用）— CR 生命周期薄 store：只拥有 ConfigChangeRequest/ConfigChangeItem 行，**每次 config 读写全委托 ConfigStore，零授权**（moduledoc :2-31）；`stage_item/1`（写 inert 对象不 point）、`publish/1`（单 Multi all-or-nothing 指针翻转）；前缀 `@cr_stage_prefix "cr-stage:"` / `@cr_publish_prefix "cr-publish:"`（:41-42）。
- `Ezagent.ActionSet.ConfigGovernance`（behavior/config_governance.ex:1）— dispatch 驱动侧，**仍 7 action**（open_cr :58 / stage_item :66 / unstage_item :80 / preview_cr :88 / publish_cr :96 / reject_cr :104 / rollback_cr :112），**变薄全 delegate Store**（handle_open_cr→Store.open :161 等；moduledoc :37 "Owns NO persistent state"）。cap = agent MANAGE cap。`Ezagent.ActionSet.ConfigEvolve`（rev4）不变。
- socialware-subject 的 `Ezagent.ConfigGovernance.Socialware` 在 session 域（见该节）。

**易混淆点**：本 app 全部 ActionSet 100% `use Ezagent.Lifecycle`；唯一 Kind 是 User；grant 唯一 chokepoint = `Grant.prepare/4`；`Ezagent.Socialware.ConfigStore` 物理住 identity（前缀不改是决策非遗漏）；`ConfigGovernance.Store` 文件在 identity、socialware-subject 治理在 session——两层别混。

**自 49f0167f7（本轮）**：新 config_governance.ex + config_governance/agent.ex；config_change_store.ex → config_governance/store.ex 改名（R099）；config_store.ex 沉入三态 seed 契约（#1242）；behavior/config_governance.ex 变薄。

**测试**：约 41+ 个（behavior/ identity/ entity/ socialware/ + 新 governance/seed 契约相关）。

### ezagent_domain_pty（domain / L2）

- **entry**：`apps/ezagent_domain_pty/lib/ezagent_domain_pty/application.ex:32`；facade `Ezagent.Domain.Pty`（pty.ex:45 `start/2`）。deps 只 core + erlexec。
- **拥有**：PTY-managed sidecar runtime（一 Server per agent_uri，erlexec 真 tty）+ `:write` ActionSet + 数据驱动 auto-prompt scanner + auth-failure observer + 三相 phase 状态机 + stdout snapshot/redraw。
- `Ezagent.Domain.Pty.Server`（server.ex）— cmd_override LIST(argv)/STRING(legacy)；`@packet2_limit` backstop；auth-failure observer emit-only；auto-prompt scanner。
- **CJK crash 已修（#1215）**：`alias Ezagent.Utf8Tail`（server.ex:66）；两处 buffer trim 换 `Utf8Tail.tail`（:312-315 snapshot 尾切 + :823-830 64k→16k trim，注释 `#1201 ①`）；`normalize_ws/1`（:791-792）先 `scrub_invalid/1`（:800-802，`String.valid?` else `String.replace_invalid`）再 `~r/\s+/u`；`matches?` 对 stripped 也 scrub（:789）。**旧 forensic "三处热点裸字节切片必崩" 描述作废**。
- `Ezagent.ActionSet.Pty`（behavior/pty.ex:107，`:write` ActionSet）、`AutoPrompts`（7 个 well-known claude 启动对话 auto-prompt）不变。
- **易混淆点**：本 app 无 Kind；phase topic `"pty:phase:" <> uri` 与 Domain.Python 故意同名。
- **测试**：11+ 个（含 e2e/category_07 + utf8 边界回归）。

### ezagent_domain_python（domain / L2 runtime）

- **entry**：`apps/ezagent_domain_python/application.ex:27`；facade `Ezagent.Domain.Python`。**本轮无 commit**。声明 NO Kind/ActionSet/flavor/recipe。
- **拥有**：uv 启动的 Python 子进程 OS-process 生命周期——一 Server per canonical handle，LSP-framed JSON-RPC 2.0 over stdio。
- `Python`（facade：start_subprocess 同步阻塞到 ping pong、call/notify/stop/alive?、`handle_key/1` canonicalization chokepoint）；`Server`（readiness 同步在 init/1 内、per-call timer、RPC timeout → unhealthy tear-down、三相 phase、bounded stderr、pid-file namespace "python"）；`AgentLifecycle`（py/np 复用 helper，零 Template 反向引用）；`Spec`（validate/to_argv，uv 经 System.find_executable）；`FrameBuffer` + `JsonRpc`。
- **易混淆点**：preflight 在 caller 进程跑；并发 start 在 `:via` Registry 塌缩。
- **测试**：9 个。

### ezagent_domain_session（domain 层，socialware 生命周期核心所在）

- **otp_app**：`:ezagent_domain_instance_message`（历史名，目录已改名 domain_session，模块前缀仍 `EzagentDomainInstanceMessage`）。**entry**：`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:62`。
- **拥有**：统一 `Ezagent.Entity.Session` Kind（chat + socialware 一个参数化 Kind）、SessionCreator materialization pipeline、成员/准入/member-cap 安全机器、**整条 socialware 生命周期 author→publish→discover→install→use**、**manifest seed/YAML 车道（session 侧）**、**DeliveryQueue**、**orchestrator-as-definition**。

**socialware 生命周期五段（全在此 app）**
- **author（manifest 车道，本轮新增）**：`Ezagent.Socialware.ManifestSeed`（manifest_seed.ex）— "ONE lane over the single deployment-level seed directory"（moduledoc :2-35：app-priv `priv/socialware/<名>/` 旧车道 retired、arch gate `socialware_priv_manifest_files` 锁死、app_sources 死分支已删 #1227/#1249）。`enabled?/0`（:46-52，读 `:ezagent_domain_session, :socialware_manifest_boot_scan`，**config.exs:33 覆写为 prod-only**）；`scan_all!/1`（:66-73，唯一 late 扫描，从 EzagentWeb.Application 触发）；`scan_dir!/2`（:84-99，每 `*/manifest.yaml` parse→resolve→conformance→governed publish，首错 raise）；`deploy_dir/1`（:102-119，boot fallback 先 `SocialwareSeed.seed!()` 再 FsResolver 解析 `system://socialware`）；`import_manifest_path/1`（:121-139，`operator_admin_ctx` + `ManifestYaml.import`）；uses 未装的友好报错 `seed_failure_message/4`（:144-150）。
- `Ezagent.Socialware.ManifestYaml`（manifest_yaml.ex）— YAML interchange，**content-only API**（caller 递字节不递路径，:2-7）：`parse/1`（:42-52）、`render/1`（:56-67，canonical key 序 `@top_level_order` :19-38）、`import/2`（:71-80，parse→ManifestResolver.resolve→Conformance.check_candidate→`publish_or_upgrade`）、`export/2`（:84-89）、`operator_admin_ctx/2`（:93-106，system admin caller + manage_cap + admin_genesis_cap——manifest 能声明 scope:public 的原因）。`ManifestViews`（manifest_views.ex，registry-locator 薄模块）。
- mix 任务：`mix ezagent.socialware.import` / `export`（mix/tasks/ezagent.socialware.{import,export}.ex，唯二文件 IO 点）+ `manifest_args.ex`。
- 老 author 路仍在：`ManifestResolver.resolve/1`（manifest_resolver.ex:14，string name-refs → Definition，fail-closed）；world 表单 `save_session_template/2`。
- **publish**：`Ezagent.ConfigGovernance.Socialware`（**config_governance/socialware.ex，从 socialware/config_governance/ 搬家，模块名没变**）— `manage_cap/3` :26、`open_cr/2` :43、`stage_definition/3` :62、`publish_cr/2` :83、**`publish_or_upgrade/2`（:119-135）**（none→`:published`；hash 同→`:exists`；异→`:upgraded` 经 `publish_new_revision/3` :137-143 完整 open→stage→publish 链）、`retract/2` :159、`restore/2` :170、`reject_cr/2` :190。deploy-seed 车道的 publish 原语就是它。
- **discover**：`DefinitionRegistry.list/1`（cross-ws 可见性 + retract 过滤 + 去重）。
- **install**：`Ezagent.Socialware.Installation`（installation.ex）— freeze-pin（`freeze_template_installs/2` :117-124、`pin_installs_from_session/2` :166-178、`repoint_template_installs/4` :245-271 唯一显式升级路）；**requires 依赖（#1230）**：`ensure_requirements/4`（:520-541，`requires: []` 容错 :520-521，非空递归 `seed_install` 每个被依赖 def）、`required_installs/2`（:627-635）、`expand_installs_with_requires/3`（:637-658）；**卸载（#1245）**：`retract_session_installs/2`（:187-201，append-only tombstone `%{removed: true}`，:426-457 写入）、`install_state/2`（:565-573，`:removed | :installed | :none` 三态，`seed_install/6` :479-518 按态分支：removed→re-point、installed→no-op 持 pin、none→fresh）；匿名两层 web gate（`web_anon_access?/1` / `anon_view_caps/1`）不变。
- **use**：`DefinitionAgents.materialize_definition_agents/4`（session_creator/definition_agents.ex:65）→ `materialize_one/4`（:98）→ `install_mode_of` 分支 `:fresh`/`:reuse`（:111-131/:475-481）。fresh 5 步：lookup_recipe → **`HostLoginAdopt.ensure_installer_source`（:157-162，#1209）** → `spawn_and_join/8`（:300-331，→ `RecipeMaterializer.create_agent_from_recipe` :312，join 失败 terminate worker :326）→ grant recipe caps LAST（:174）。reuse 路 `reuse_existing_agent/6`（:179，recipe 一致性校验）。`lookup_ref` 剥 `recipe:` 前缀（:295-296）。

**Conformance（15 断言，原 12）**
- `Ezagent.Socialware.Conformance`（conformance.ex）。`assertions/0`（:179-197）15 条：uses_plugins_installed / **requires_published** / **requires_cycle_free** / bases_shape_load / views_exist_caps_registered / agent_recipes_resolve / agent_caps_and_role_uniqueness / adapters_registered / orchestrator_uri_parses / install_resolves / template_installable / routing_receivers_resolve / **routing_role_dag** / prompt_template_refs_valid / view_caps_gate_ready。入口 `check/2` :37、`check_with_warnings/2` :52、`check_candidate/2` :65（manifest import 用）。`mix ezagent.socialware.check` 薄 wrapper。

**Definition / DefinitionRegistry**
- `Ezagent.Socialware.Definition`（socialware/definition.ex）— 17 老字段 + **`requires`**（部署依赖清单，normalize 到 []）。role_slot agent 槽 `%{role_name, fill: :agent, recipe, flavor}` / human 槽；三 enforce 点（退休字段 / 实例 URI / `:fixed` owner）不变；`content_hash/1` 委托 ContentHash。
- `Ezagent.Socialware.DefinitionRegistry`（definition_registry.ex）— retract 独立 key、`resolve_installable_revision/3` 硬 scope 门、`write_definition/2` + `authorize_public_scope_write/2`（#165 domain chokepoint）不变。**builtin 三件**：`builtin_definitions/0`（:285-306）= `chat` + `socialware` + **`orchestrator`**（#1223：uses ["cc"]，单 agent 槽 recipe "orchestrator" × flavor "cc"）；`seed_builtin_definitions/0`（:208-211）逐个 `seed_builtin_definition/2`（:525-542，**走 `ConfigStore.seed_object_upsert`，无 seed_family_prefix = §5.2 恒升级**，`builtin_upgrade_source_turn_id` :550-551）；`seed_definition_if_absent/2`（:221，`seed_object_if_no_pointer`，turn `socialware-definition-seed:<ws>:<name>` :234）。
- `DefinitionEditor` / `DefinitionSync` / `Migration` 沿革不变。
- **`Ezagent.Socialware.Demo.Hello`（demo/hello.ex）变薄**：moduledoc :2-29 "Production AND tests publish via the deploy-seed lane (NOT this module)"，**旧 `publish/0` 原语已删**；`@manifest_relpath "hello/manifest.yaml"`（:35），`manifest_path/0`（:48-53，经 `SocialwareSeed.source_dirs/0` 发现不点名 app），`manifest_attrs/1`（:72-80，无 :role_name → 解析 shipped YAML；带 :role_name → legacy 单-agent code fixture 仅测试用）。

**orchestrator-as-definition（#1223）**
- `Ezagent.Entity.Session.Orchestrator`（entity/session/orchestrator.ex）— `ensure_orchestrator/3`（:78）→ `ensure_orchestrator_compat`（:93）→ nil 分支 `materialize_orchestrator_definition/3`（:160-176）：`install_orchestrator_definition`（:178-185，`Installation.install_template_installs(..., %{installs: ["orchestrator"]}, ...)`）→ `SessionCreator.materialize_template_team(..., %{installs: ["orchestrator"]})`（:163-168）。**不再直接 spawn**。legacy 复活 `adopt_legacy_orchestrator_member`（:134-158，install_mode :reuse）；`check_orchestrator/3`（:231-268）`:owned`/`{:foreign,_}`/`:not_live`；caps 委托 `Orchestrator.Caps`。默认 session template `installs: ["chat", "orchestrator"]`（application.ex:630-631，members: []）。
- `Ezagent.Orchestrator.Tools.ToolCatalog`（orchestrator/tools/tool_catalog.ex，**新**）— transport 边界 fail-closed name guard：`tool_names/0`（:29）读 cc `OrchestratorRecipe` 的 recipe contributions，fallback `@fallback_tool_names`（:4，**13 个**：add_managed_member/add_participant/update_member_template/remove_member/define_rule_set_rule/define_prompt_template/define_legend/update_template/save_template_as/migrate_session/list_templates/kb_query/kb_ingest）；`tool?/1`（:46-47）。schema 本体仍在 cc（见 cc 节）。

**DeliveryQueue + 投递韧性（#1252/#1259）**
- `Ezagent.Session.DeliveryQueue`（session/delivery_queue.ex，**新**）— **单个中央 GenServer**（:55，非 per-recipient 进程；moduledoc :33-43 否定 keyed-GenServer 方案避 idle-exit race）+ per-key FIFO。`enqueue(key, fun)` 是 cast（:78-80，永不阻塞 caller，Prong A）；真投递跑 `Task.Supervisor.async_nolink(Ezagent.Session.DeliverySupervisor, fun)`（:136）。key = recipient instance URI string（:27-31，按 recipient 非 {session,recipient}，跨 session 同 recipient 也串行）。每 key 独立队列——死/慢 member 只堵自己（:22-25 Prong B）；job crash `:DOWN` 只推进队列不重试（:127-129）；at-most-once，重启丢队列（durable 靠 MessageStore :45-52）。
- `Ezagent.ActionSet.Session.Delivery`（behavior/session/delivery.ex）— **fan-out 全异步**：`deliver_async/5`（:49-79）逐 recipient enqueue（key `URI.to_string(recipient)` :58）；**sender echo 解耦**：`{:notify, :chat_message}` 在 `handle_send` 返回即发（moduledoc :19-21），投递从不 in-handler 跑。失败归因：fn 内 try/catch → Logger.error + `Routing.Trace.record` `rule_id: "delivery_failed"`（:69-74/:83-103）。`dispatch_receive_call/3`（:264-335）：cold agent 先 `SpawnRegistry.ensure_live`（:285-287）；`caps: MapSet.new()`（:304，R1.1）；`{:error, :buffer_full}`（:313-328，#1259）→ Logger.error + trace `delivery_dropped` 不 mark delivered。跨 session forward same-workspace guard（:192-229）。

**Listing / TemplateResolver（#1257/#1263/#1217/#1244）**
- `SessionCreator.Listing`（session_creator/listing.ex）— `list_sessions/2`（:66-85）：admin 绕过（:70），非 admin 按 member_uris 过滤、nil/非 URI caller fail-closed（:85，#1217 W0）。**冷启动**：`persisted_session_entries/1`（:111-144）= live ∪ durable（`KindSnapshot.list_in_workspace` :154-169），cold membership 从快照 decode（:183-205）。**dedup 键 `Ezagent.URI.canonical!/1` struct**（:125-137，#1263，非 URI.to_string）。
- `SessionCreator.TemplateResolver`（template_resolver.ex）— #1244 Prong 1：`find_session_template_uri_by_scan/2`（:183-225，snapshot∪live URI，按 `kind_snapshots.inserted_at` birth-time 选 NEWEST :213-221，moduledoc :167-182 论证）；先试 `TemplateTags.resolve(ws, name, "current")`（:157-165）；`require_template_name!/1`（:39-63，删 "default" 静默 fallback）。Prong 2 "tag the seed" 在 application.ex `do_seed_default_session_template`（:613/:656-677，seed 时写 TemplateTags default→current）。

**统一 Session Kind + 准入/member-cap 安全机器**（沿革不变）
- `Ezagent.Entity.Session`（entity/session.ex）— ONE parameterized Kind，behaviors UNION superset + per-instance ACTIVE subset 经 `:kind_base`。
- `Ezagent.ActionSet.Session`（behavior/session.ex）— admission actions cap-exempt+in-handler authz（#1178）+ `assign_role`（#1194）。
- `Membership`（do_join 唯一 chokepoint + admission gate 四条 AND + `caller_controls_member?` = `Authority.manages?` ∪ `{:spawned_by,caller}`）；`MemberCap`（grant_at_join 强制 `:async`、revoke_membership sync）；delivery fan-out `caps: MapSet.new()`（#1175，授权在接收方 member-cap）。
- `ConfigFork.fork_config/3`（config-only，Invariant #10）不变。

**易混淆点**：Definition ≠ live Kind（config-as-data，OPAQUE subject）；两个 socialware app——lifecycle CORE 在本 app；member-cap grant `:async` / revoke `:sync`；`ManifestSeed` 归 session 域、`SocialwareSeed`（FS 层）归 core、seed 实物归 ezagent_web priv——三层别混；`Tools.ToolCatalog`（name guard，本 app）≠ cc `McpServer.ToolCatalog`（schema 本体）。

**自 49f0167f7（本轮）**：新 manifest_seed/manifest_yaml/manifest_views + mix socialware.{import,export,manifest_args} + session/delivery_queue + orchestrator/tools/tool_catalog；config_governance/socialware.ex 搬家；conformance 12→15；installation requires+uninstall；definition +requires；definition_registry builtin orchestrator + seed_object_upsert 收编；definition_agents HostLoginAdopt+fold 配套；listing/template_resolver/rollback/uri_query_resolvers 韧性弧；demo/hello 变薄；behavior/session delivery 异步化。

**测试**：130+ 个 .exs（e2e/、ezagent/socialware/、session/、behavior/、entity/、integration/ 含 reflow_rehearsal_test.exs〔CI `--include reflow_rehearsal` 专用〕、invariants/）。

### ezagent_domain_socialware（domain tier — customer-feed / anon-User substrate，非生命周期核心）

- **entry**：`lib/ezagent_domain_socialware/application.ex:19`。监督树唯一 child `AnonUser.Sweeper`；boot 后注册两个 `:pull` adapter：`ChatFeedAdapter` + `ExternalFeedAdapter`。**本轮零 commit**。无 session Kind。
- **拥有**：customer-feed / settlement 投影 substrate + anon-User（匿名只读访客）铸造/准入/GC + PageView 投影。
- `ExternalFeed`（participatory + durable delta-cursor replay over DeliveryOutbox；`chat_messages/2` :94 供 hello 白板；committed-surface 渲染防 leak）；`ChatFeed`（windowed snapshot-refresh，history 200）；`ExternalFeedAdapter`（`:pull`/`:cursor_replay`/`:participatory`）+ `ChatFeedAdapter`（`:pull`/`:snapshot_refresh`/`:read_only`；moduledoc :66-73——advisor 退役后无插件声明它，`allow_chat_feed` cap subject 不再 boot-published）；`ChatFeedAuth`（caller-identity token 非授权）；`AnonUser`（mint/1 empty caps、`mint_for_public_session/1` gated on `PublicView.web_anon_access?`，born WITH 窄 join cap + view read-caps）；`AnonAdmission`（admit/refresh 经 `Invocation.dispatch` P14）；`AnonBinding`（Ecto，merge FSM 6 态）；`AnonUser.GC`（48h-TTL 非破坏 reaper）+ `Sweeper`；`PublicView`（fail-closed delegate Installation）；`PageView`（`Ezagent.UI.SessionView` impl，id :page，live surface 渲染）。
- **易混淆点**：两投影两读模型都是 `:pull` adapter 由 web `SessionFeedChannel` 驱动；单一安全边界 `Membership.authorize/3`；mix.exs 注释引用不存在的 `CustomerFeedAdapter` 是 stale。
- **测试**：37 个。

### ezagent_domain_ui（domain / L2；声明 NO Kind NO ActionSet）

- **entry**：`apps/ezagent_domain_ui/lib/ezagent_domain_ui/application.ex:30`（空 children，`register_session_views/0` 注册 3 个 builtin view）。deps core + pty + identity + external_mirror，无 ezagent_web 依赖。**本轮仅 routing/routing_view.ex 被 #1212 触及**（routing 声明式 role 编排的 view 侧适配），其余不变。
- **拥有**：无状态 Phoenix.Component 库 + **SessionView 扩展点契约 + ETS registry**（per-view cap 授权门 `authorize_view/3` T2-2b）+ caller-authorized 读 helper。
- `Ezagent.UI.SessionView`（session_view.ex，callback id/label/icon/applies_to?/render + optional external_render?/external_render/view_behavior；`authorize_view/3` :121）；`SessionViewRegistry`（ETS，`applicable_views/2` caller-aware；**ManifestYaml 经 ManifestViews 定位它做 view name-ref 解析**）；3 builtin view（Pty.TerminalView / Routing.RoutingView / ExternalMirror.View）；chrome IdeShell/WorkspaceShell/AdminShell + Primitives/Components + UriOptions/CommandSource/AutoDerive + Pty.Terminal/TerminalSeam + Gettext。
- **测试**：13 个。

### ezagent_domain_workspace（domain / L2）

- **entry**：`apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:32`；`boot_complete/0` → `Loader.load_all/0`。deps core + agent + identity。
- **拥有**：Workspace Kind（`workspace://<name>`，persistence `:ephemeral`，`workspaces` 表 SoT）+ cluster shape + 统一 provisioning（create_agent/create_session/create_user）。
- `Ezagent.ActionSet.Workspace`（behavior/workspace.ex）— **14 action** 不变；`action(:instantiate)` :254（caps [:instantiate] :257）；`handle_instantiate/2`（:780）返 children 作 DATA：`{:member, uri}` 先（:790-793）、`{:template, name, data}` 后（:795-799）。#1259 的 "2-element generic instantiate" 接收侧在 session/loader（loader 接受 2 元 generic child tuple），Workspace handler 输出形状未变。
- `AgentCreate` + **`RoleStep`（role_step.ex）**——"ONE generic step — no role-specific branch"（:15）：`resolve/2` 现走 **`RecipeBehaviorFold`**（:95 fold + :183 lookup_flavor_decl，#1219/#1255），`mint_and_grant_caps/4` CapMint × cap_policy fail-closed、durable marker 写 `Ezagent.Agent.RecipeAttributes`（点分新名）+ `:sandbox.:recipe`。
- `Ezagent.Workspace` facade（统一 provisioning + `workspace_self_ctx/2` #154）、`Loader`、`Store`、`Listing`、`MagicLinkRule`、`ResponsibilityAssignment` 沿革不变。
- **易混淆点**：Kind `:ephemeral`；`:instantiate` 返 children 作 DATA；`session_templates` 列名误导；无 Definition/socialware 代码（只 RoleStep 消费 RecipeRegistry）。
- **自 49f0167f7（本轮）**：behavior/workspace.ex + role_step.ex（#1219 fold、#1255 点分名、#1185 序）。
- **测试**：20 个。

---

## L3 plugin

### ezagent_plugin_cc（plugin 层）

- **entry**：`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:72`（`start/2 → Ezagent.Plugin.boot`）。`after_boot/0`：McpRegistry/LiveJoinRegistry init → reap orphans → `Workspace.Loader.load_all` → `CcOrchestratorSeed.seed`。
- **职责**：统一 Claude Code agent 插件——`cc`（PTY/TUI）+ `cc-headless`（Python SDK sidecar）两 flavor（挂共享 `Entity.Agent`）、Template Class、bridge adapter、内置 `orchestrator` role recipe（**含 tool contributions**），host 编排器 MCP transport。**声明 NO 自有 Kind/ActionSet**。
- `Template.CcAgent`（cc PTY Template Class；CredentialAdapter `CLAUDE_CONFIG_DIR`；`credential_status/2` #160；`check_role` 已泛化接受任何注册 role〔T4〕）+ `CcAgent.Spawn`（PR-3T：`:already_started` foreign-Kind adoption 拒、launch 前二次 grant 复验、失败 terminate 全回滚）+ `SpawnPlan`（BUILD-ONLY #701：claude argv + `EZAGENT_AGENT_URI/TOKEN` + role env + CLI 身份 token）。
- `CcHeadlessAgent` + `SdkSidecar`（supervised Python ClaudeSDKClient worker；**#1215 收编 Utf8Tail** 防 CJK 边界撕裂）。
- `BridgeAdapter`（cc flavor，`:subprocess_ws`，reply 三桶经 `Invocation.dispatch` P14）+ `CcHeadlessBridgeAdapter`（`:in_process_sync`）。
- `McpConfigWriter`、`OrphanReaper`、`CredentialFreshness`（#17(c) + #1171 status/expires_at）、`CredentialRefresh`（TEST/E2E）沿革不变。
- **编排器 MCP transport**：`McpSocket`/`McpChannel`/`McpServer`（纯 transport 零 authority，bridge token 唯一 authz 门）/`McpRegistry`（CACHE）。**`McpServer.ToolCatalog`（orchestrator/mcp_server/tool_catalog.ex）= schema 本体：`raw_tool_schemas/0`（:6）返回 13 个 tool map**（12→13，加 add_participant，SPEC §5.3 计入 kb_query/kb_ingest）。
- **`OrchestratorRecipe`（orchestrator/orchestrator_recipe.ex）**：`@tool_atoms`（:50-63，13 个）；`tool_schemas/0`（:84，delegate `McpServer.ToolCatalog.raw_tool_schemas/0` :85）；`tool_contributions/0`（:72）；**`recipe/0`（:107）带 `contributions: %{tools: tool_contributions()}`**——domain_session 的 `Tools.ToolCatalog` name guard 从这读；`persona/0`（:130）。orchestrator 的**部署形态**已是 builtin socialware definition（session 域 #1223），recipe 本体仍在这。
- **`OrchestratorBootstrap`（template/orchestrator_bootstrap.ex）消费 SkillRegistry**：`ready?()`（:181/:207）+ `resolve(ref)`（:208）解析 recipe 声明的 skill ref，ready 但 ref 未解析 → loud fail（:152）。
- **易混淆点**：session 是真 prod compile dep；MCP transport 零 authority；moduledoc "7/9/12 tool" 全 stale（实 13）；schema 归 cc、name guard 归 session。
- **自 49f0167f7（本轮）**：tool_catalog 12→13 + OrchestratorRecipe contributions（#1223 配套）；orchestrator_bootstrap 接 SkillRegistry（#1266）；sdk_sidecar Utf8Tail（#1215）；cc_agent/spawn/cc_headless host-login 配套（#1209）；application（#1221 install conformance 硬化）。
- **测试**：38+ 个。

### ezagent_plugin_codex（plugin 层）

- **entry**：`apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/application.ex:15`。`after_boot/0` reap → load_all → CodexOrchestratorSeed.seed。
- **职责**：`codex`（app-server + TUI + Python bridge，三子进程）与 `codex-remote`（headless 两子进程）两 flavor，复用 cc 的 `OrchestratorRecipe`，codex-native 编排（`run_tool` seam 直调 `SessionManager.run_tool/4`，无 cc PTY / cc MCP transport）。不声明自有 Kind。
- `Template.CodexAgent`（CredentialAdapter `CODEX_HOME`，credential_status #160，SUN_LEN socket slug；**#1209 host-login 配套**）+ `CodexRemoteAgent`；`AppServer`（erlexec sidecar；**#1215 收编 Utf8Tail**）；`BridgeSidecar`；`BridgeAdapter`（`handle_client_event("run_tool")` → SessionManager.run_tool）；`CodexOrchestratorSeed`；`CredentialFreshness`/`CredentialRefresh`。
- **自 49f0167f7（本轮）**：app_server Utf8Tail（#1215）、codex_agent host-login（#1209）、application（#1221）、bridge_sidecar 小改。
- **测试**：15 个。

### ezagent_plugin_curl_agent（plugin / L3）

- **entry**：`apps/ezagent_plugin_curl_agent/lib/ezagent_plugin_curl_agent/application.ex:70`。**本轮无 lib 变化**。
- **职责**：连 OpenAI-compatible `/chat/completions` 的 HTTP-API agent；curl-as-flavor fold 后无独立 Kind，flavor `"curl"` WIRING 到统一 `Entity.Agent`（STATE Behavior `Ezagent.ActionSet.CurlAgent` 在 domain_agent）。**hello 的 `hello.llm` 角色宿主 flavor**——`Entity.Agent.complete/3` 同步补全走 curl member。
- `ApiClient`（`:httpc`，`body_format: :binary` 防 CJK 乱码）；`BridgeAdapter`（`:in_process_sync`，stateless，读 SNAPSHOT slice 避 self-deadlock）；`Template`（CredentialSliceAdapter `:api_keys`）。**`CurlSnapshotMigration` + mix task 已删除**（chore/retire-dead-kind-migrations，2026-07-29：系统未正式进入生产，pre-fold `curl_agent` 行从未存在，one-shot migration 无需保留）。
- **测试**：12 个。

### ezagent_plugin_email（plugin）

- **entry**：`lib/ezagent_plugin_email/application.ex:36`。**本轮无 commit**。
- **职责**：email 能力——Swoosh send + CF-Email-Worker HTTP pull 收信 + email ExternalMirror `:push` adapter（RFC 5322 threaded 出站 + 入站 poll 注回 session）。纯 transport/adapter，非 socialware。
- `Email` facade / `Mailer` / `Adapter`（`:push`，ownership check 仅格式 sanity）/ `Binding`（durable server-owned verification gate）/ `Inbound`（SPF/DKIM/DMARC + dedup + `Invocation.dispatch` P14 + at-least-once DELETE）/ `InboundBinding` / `Guard` / `Principal` / `ThreadState` / `Verification` / `Inbox.CFWorker` / `Allow`。
- **易混淆点**：#1198 REST Swoosh adapter（`Ezagent.Mail.EzagentChatAdapter`）在 ezagent_web 不在本 app；两 Mailer 勿混。
- **测试**：约 15 个。

### ezagent_plugin_feishu（plugin）

- **entry**：`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/application.ex:70`。HTTP 入站 webhook_plug.ex:31（forward 在 ezagent_web router）。**本轮无 lib 变化**。
- **职责**：Feishu(Lark) 双向 transport adapter——入站（webhook + WSS node sidecar）经 `Invocation.dispatch` 注入；出站走 generic ExternalMirror；open_id↔user 绑定 + @mention/@legend 消歧 + presence 镜像。
- `WebhookPlug` / `WsClient`（erlexec node sidecar）/ `InboundDispatcher`（mode: :call 让 cap 拒绝同步冒泡，三种失败回不同 Feishu 文本不 silent drop）/ `SenderResolver` / `InboundChatLookup`（多绑定 fail-closed）/ `MentionParser` / `FeishuAdapter`（ownership check 是唯一外部 I/O）/ `FeishuChatBinding`（partial-publish RAISE）/ `UserBinding` / `PresenceMirror` / `Client`。
- **测试**：约 16 个。

### ezagent_plugin_hello（plugin / L3，socialware 黄金样板）

- **entry**：`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:39`。
- **职责**：AI builder 把用户 chat 请求变成结构化 `@json-render` UI page（shadcn 约束），页面经 `Turn`→`Surface` chokepoint 落地，经 socialware substrate 暴露给匿名访客；一个不可见 per-session 前台（front-desk）按意图×身份路由到 builder/concierge；**LLM 调用 delegation 给 session 自己的 curl "llm" member（#1243 X2b）**。
- **boot（重写）**：`start/2`（application.ex:38-56）= `Plugin.boot` + 注册 `PageView`。**`maybe_publish_hello_demo` 已删**——:46-54 明注：hello demo socialware 不在此发布，走 deploy-seed 包 `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`（SocialwareSeed 复制 + ManifestSeed 扫描发布），"Zero call from this plugin's boot"。
- **`roles/0`（:94-100）四 recipe**：`hello.front-desk`（:104，flavor "hello"，收 chat 隐形前台）/ `hello.builder`（:116）/ `hello.concierge`（:129）/ **`hello.llm`（:142-157，flavor "curl"〔app.ex roles :143〕，`credential_optional: true`，config `provider: "deepseek"`）**。`agent_flavors/0`（:71-84，单 "hello" flavor，cap_policy 复用 native）；`behaviors/0`（`{Session, :hello_render, HelloRender}`）；`template_classes/0`（[Template.HelloSession]）。
- **v2 seed page（#1277）**：`children/0`（:187-190）挂 `demo_seed_children`（**`HELLO_DEMO_SEED=1` 才开，默认关**）；`demo_seed/0`（:238-259）+ `seed_page/1`（:297-313）读 `priv/seed_page/{body.json,shell.css}`（:298-299）经 `TurnDriver.drive` 落 "v2 website page"。这是运行时 demo 播种，**不是** socialware publish 路径。
- `EzagentPluginHello.App`（app.ex）— in-code author 流：`ensure_app/2`（:33-97）；`hello_definition_attrs/1`（:128-165，roles :139-144 含 llm 槽）；`requires: hello_requires()`（:158，env-gated `["orchestrator"]` 或 []，:122-124）。
- **Router（#1225 capabilities rebuild）**：`route/3`（router.ex:36-50，supervised Task）；`decide/3`（:107-111，身份优先：非 owner 恒 `:concierge` 无 LLM；owner → `Generator.classify_intent`）；`dispatch_to_member/4`（:54-78，`Invocation.dispatch` `:cast`，target `URI.with_action(member_uri, :agent, :rebuild|:answer)`，caps admin_genesis）；loop guard `should_route?/2`（:92-98，`@worker_roles ["builder","concierge"]` fail-closed）。**注意这是 hello 内部 Router 非 `Ezagent.Router`**。
- **Generator（LLM delegation，#1243）**：`call_llm/3`（generator.ex:475-500）——`HELLO_LLM_BACKEND=claude_code` → `LLM.ClaudeCode.chat/2`（本地 CLI）；**否则 `Members.role_uri(session_uri, "llm")` → `Ezagent.Entity.Agent.complete(admin, curl_uri, prompt)`**（:486-495，API key 在该 curl agent 自己的 `:api_keys` slice，:16-22 moduledoc）。**旧 `llm/api_client.ex`（DeepSeek 直连 HTTP client）已删**。
- Behavior 三件：`HelloOrchestrator`（front-desk relay，action `:hello_sync_result` :43-51，create 存 flavor "hello" :54）/ `HelloBuilder`（actions `:receive` + `:rebuild`）/ `HelloConcierge`（`:receive` dormant + `:answer` active，结构上无 page-write 路径）。`HelloRender`（cap-only view，dispatchable? false）。`TurnDriver` / `PageView`（view_behavior HelloRender cap-gated）/ `Migrate` / `Template.HelloSession` / `Template.HelloAgent` / Prompts/Spec/Sanitize/ShellCss/LLM.ClaudeCode/Gettext。
- **manifest（v2，纯 config）**：`apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`——roles builder/responser（np×py）+ viewer（human），routing_rules `from_role viewer→responser`、`responser+^\[need-build\]→builder`，`requires: [orchestrator]`，scope public / supervised / web_anon_access true。**注意 manifest 版 hello（纯 config，np×py 角色）与插件版 hello（code recipes，"hello"/"curl" flavor）是同名两形态**——manifest 是 deploy-seed 车道发布的 config 版。
- **易混淆点**：四角色非三角色（llm 是纯服务角色不收 chat）；front-desk recipe 名 ≠ HelloOrchestrator 模块名；chat 只 fan-out 到 front-desk（唯一 chat member），builder/concierge/llm 不作 chat member；发布零 boot 自发布。
- **自 49f0167f7（本轮）**：#1225（capabilities dispatch rebuild）、#1243（llm 角色 + curl delegation + api_client.ex 删除）、#1233（发布迁 deploy-seed）、#1223（requires orchestrator）、#1277+21cbeff70/add4428ad/5d1f08dd8/d974865da（v2 seed page + requires 容错 + dev 禁扫）。
- **测试**：8+ 个（generator/router/template + integration hello_*）。

### ezagent_plugin_kanban（plugin / L3，kanban-as-role）

- **entry**：`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:32`。
- **职责**：node-tree 看板 Behavior + 出站连接器（**现仅 Miro/markmap——GitHub HTTP 连接器已删**）；board 不是 `resource://` Kind——role `kanban-manager` × flavor `native` 的 passive agent，board state 住 `Entity.Agent` 的 `:kanban` slice；纯声明式路 A 插件。
- **boot（#1248）**：`start/2`（:32-51）= boot + 注册 **`BoardView`**。:40-49 明注：kanban demo socialware 不在此发布——deploy-seed 包 `apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml`（"the hello #162 play"）。
- **`roles/0`（:84）三 recipe**：`kanban_manager_recipe`（:225-243，passive true、behaviors [ActionSet.Kanban]、config 9-stage 链 :237-241）+ **`kanban_assistant_recipe`** + **`dev_together_recipe`**（新，对应 skills_seed 里 kanban-assistant / dev-together skill 包；Demo `@relay_done_marker "__done__"` :47 是 dev-together 完成契约）。`behaviors/0`（:259-264）：`{Entity.Session, :kanban_render, Ezagent.ActionSet.KanbanRender}`（cap-only view subject）。无 kinds/0（K5 gate 锁死）。
- `Ezagent.ActionSet.Kanban`（kanban.ex）— core 15 action 不变；**connector action 缩水**：GitHub 活动连接器（sync_github 建 issue / push_pr / sync_prs / save_github_creds）**全移除**（kanban.ex:168-171 / connectors.ex:11-16 文档化删除）；存活的 GitHub 相关是**纯数据**：`register_pr`/`attach_code_file` 构造 github link（connectors.ex:34-101）、`set_board_config` 存 `github_repo`（:125-131），无出站 HTTP。Miro 侧（sync_miro/MiroSync GenServer/Miro.Sync 纯函数）+ markmap 不变。stage R1 单调链 / `owner==nil ⟺ :unassigned` 不变。
- **`github.ex` 文件已删**（`EzagentPluginKanban.Github` REST client 整体移除）；world 侧 kanban_actions.ex 还留 sync_github UI 引用（读模型遗留）。
- **新 view**：`BoardView`（board_view.ex，`id :kanban_board` :37、`view_behavior/0 → KanbanRender` :48 cap-gated、`render/1` :73）+ `Ezagent.ActionSet.KanbanRender`（behavior/kanban_render.ex:1，`use Ezagent.Lifecycle` :35，actions [:kanban_render] :38）——kanban 进 SessionViewRegistry 一等 view（#1261 配套点分 RecipeResolver 改名）。
- **`Demo`（demo.ex）**：薄 YAML loader + 测试 fixture（moduledoc :2-33 "Production publishes via the deploy-seed lane"；旧 boot publish + `Demo.publish/0` 均删）；`manifest_path/0`（:67-71 泛型 source_dirs）；`manifest_attrs/1`（:89-104，:name/:flavor override seam）。
- `Shared`（唯一 `{:set, :tree, …}` 收口 `commit/1`；stages read-through 现经 **`Ezagent.Agent.RecipeAttributes` / `Ezagent.Agent.RecipeResolver` 点分新名**）、`BoardConfig`、`Ci`、`Markmap` 沿革不变。
- **易混淆点**：kanban-as-role 未变但已入 socialware 生态（deploy-seed manifest + BoardView registry view）；GitHub"连接器"现在是纯 link 数据不是集成；两个 Miro 模块别混。
- **自 49f0167f7（本轮）**：#1248（deploy-seed 迁移：github.ex 删、demo.ex 新、BoardView/KanbanRender 新、assistant/dev_together recipe 新）、#1261/#1255（点分名消费侧）。
- **测试**：8+ 个。

### ezagent_plugin_kb（plugin / L3，kb-as-role，path A）

- **entry**：`apps/ezagent_plugin_kb/lib/ezagent_plugin_kb/application.ex:36`。**本轮无 lib 变化**。
- **职责**：retrieval-first KB 纯插件——一 KB = 一 agent（recipe `kb` × flavor `native`），非新 Kind，ezagent PG 零行，corpus+FTS5 全在独立 per-KB sqlite。
- `roles/0`（kb_recipe：passive + [ActionSet.Kb] + `:query`/`:ingest` cap-template）、`resource_types/0`（kb-store/kb-source，R-3 workspace 隔离）、`ActionSet.Kb`（sqlite 连接 TRANSIENT：activate 开/deactivate 关，store-path confinement）、`Chunker`（grapheme 切不破 CJK）、`Store`（exqlite 直连，FTS5 trigram，journal DELETE，BOUND param）。
- **易混淆点**：本 app HOSTS 两个非-KB E2E gate（plugin_package_codex_gate / socialware_p10_codex_gate）。
- **测试**：6 个。

### ezagent_plugin_native（plugin / L3，native flavor，RF-8）

- **entry**：`apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex:67`。**本轮无 commit**。
- **职责**：`native` flavor——NO-engine/NO-sidecar/NO-bridge 的 ROLE agent 通用宿主（kanban-manager / kb 等），behaviors+caps+sandbox 由 role recipe per-instance 提供（RF-5a）。
- `agent_flavors/0`（flavor "native" + cap_policy `CapPolicy.for_recipe/1` fail-closed）；**刻意 NO behaviors/0 / NO bridge_adapter / NO instance_behaviors thunk**（省略 ≠ `fn -> [] end`）。
- **测试**：2 个。

### ezagent_plugin_protocol_api（plugin，inbound transport adapter）

- **entry**：`lib/ezagent_plugin_protocol_api/application.ex:23`。HTTP 入口 chat_completions_plug.ex:40（forward 在 ezagent_web router）。**本轮无 commit**。
- **职责**：inbound OpenAI-compat HTTP API——`POST /v1/chat/completions` ack-then-async-reply（202 + retrieve_url 轮询）；durable API-key 认证 + conversation binding。声明 NO Kind/ActionSet/recipe/flavor。
- `ChatCompletionsPlug`（**两个 latent smell 仍在**：`Process.sleep(3000)` :182-183 + empty-caps dispatch :191,:260；P14 join Router.dispatch :196 / send Invocation.dispatch :263）；`ApiKeyStore`（真 durable bcrypt `protocol_api_keys`）；`ConversationRegistry`（复用 external_mirror_bindings adapter_id "protocol_api"）；`ReplyTransport`/`ReplyWaiter`/`PendingReplyStore`/`ResponseRenderer`；`Adapter`（`:request_scoped`，cap_subject behavior_module nil = 刻意在 cap model 外）+ `Binding`（P0 no-op stub）。
- **测试**：约 4 个。

### ezagent_plugin_py（plugin / L3，py flavor，terminal python host）

- **entry**：`apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:76`。
- **职责**：`py` flavor——每 py-agent 跑 operator python script 在 per-agent `Domain.Python` 子进程；folded 到统一 `Entity.Agent`。np recipe（只 name+script 空 caps）。**hello v2 manifest 的 builder/responser 角色 = np×py**。
- `behaviors/0`（PyAgent 三 action 挂 Entity.Agent）、`agent_flavors/0`（"py" + bridge_adapter + CapPolicy）、`roles/0`（np）、`seed_default/0`（py_default 跑 echo.py）。`ActionSet.PyAgent`（:py_sync_result/:py_reset/:py_configure；activate rebuild 订阅 + re-spawn）；`Template.PyAgent`（非-credentialled 但 config-dir-allocating；script 不可变门 `:script_immutable`；子进程失败不回滚 materialize = DEGRADED）；`BridgeAdapter`（`:in_process_sync`）；`OrphanReaper`。
- **自 49f0167f7（本轮）**：#1259（cold uv provision 解阻配套：behavior/template 小改，可见面在 core invocation `:buffer_full`→DLQ + session delivery drop trace）、#1221（application）。
- **测试**：7 个。

### ezagent_plugin_world（plugin — web entry `:ezagent_web_world`）

- **entry**：`apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex:14`。LiveView shell world_live.ex。
- **职责**：坐在所有 plugin 之上的 React/shadcn UI HOST——WorldLive SSR/comms shell + workspace-scoped layout 持久 + socialware author→publish→install→use→**uninstall** 的 world 侧面 + world-side plugin-UI-surface 契约。声明 NO Kind/flavor/recipe，一个 ActionSet（Behavior.Layout）+ 一个 resource_type（world-layouts）。
- `WorldLive`（SSR/comms shell；`socialware_rows/1` 含 roles + recipe→agent_options；**conversation_actions 白名单含 `session.socialware.uninstall`**（world_live.ex:263））。
- `ConversationActions` — 会话 dispatch 面（chat.send/switch/invite/assign_role/create/fork_config/publish_template/view.switch/pty.open/orchestrator.restart/turn.*/routing.*）+ **`uninstall_socialware/3`（:802-834，#1245）**：event `"session.socialware.uninstall"`（:73-78）→ installed_definitions 查 ref → `remove_socialware_members`（:836+）+ `RoutingPrune.prune_all_for_session`（:819）+ `Installation.retract_session_installs`（:820）；caller 必须 `%URI{}`（:818 fail-closed）。
- `ConversationData`（registry-driven view tabs `session_views/2` caller-aware；human_role_slots；parse_mentions）/ `ConversationView`（world-own SessionView，id :conversation，不 cap-gate）/ `ConversationSessionState` / `SocialwareInstall`（content-hash-addressed revision-pin install）/ `WorkspacePluginActions`（save_session_template author→publish 全链 + #165 caps 穿线）/ `WorkspacePluginData`（Layer-2 nav + Layer-3 session tabs duck-type）/ `UiSurfaceProvider` / `KanbanActions`（K4 纯 dispatcher；sync_github UI 引用是读模型遗留）/ `KanbanData`（`list_instances` = **`Ezagent.Agent.RecipeResolver.list_by_recipe`（点分新名，#1261/#1255）**；stages read-through RecipeRegistry）/ `IdentityData` / `AgentActions` / `AdminActions` / `AdminData` / `LayoutManager` / `SlotRegistry` / `Behavior.Layout` / `LayoutBootstrap`。
- **易混淆点**：socialware lifecycle CORE 不在 world（只 CONSUME）；两条 SessionView 消费路径别混；switch_view 白名单严格；plugin→world 无编译依赖（duck-typed）。
- **自 49f0167f7（本轮）**：#1245（uninstall UI 全链）、#1248（kanban_data BoardView/deploy-seed 配套）、#1255/#1261（点分名）、conversation_* 若干（#1216 display name prefer role_name、#1220 mention by role name、#1212 routing form）。
- **测试**：40+ 个。

---

## transport 顶层

### ezagent_cli（top / operator）

- **entry**：客户端 `apps/ezagent_cli/lib/mix/tasks/ezagent.ex:44`（→ `:rpc.call`）→ 服务端 `lib/ezagent_cli/exec.ex:45`。**本轮无 commit**。
- **职责**：`mix ezagent <kind> <action> [--flags]` 的 THIN 分布式-Erlang RPC shell——客户端连已跑 runtime BEAM，在那 BEAM 内 parse+coerce+dispatch（CLI↔LV runtime 同构）。
- `Mix.Tasks.Ezagent`（token/uri 回退 env，runtime 不可达 exit 5）；`Mix.Tasks.Esr`（DEPRECATED 薄 alias）；`Exec`（auth MANDATORY，`:no_token` exit 4）；`Dispatch`（P14 `%Invocation{}`，`--as` 需 `EZAGENT_CLI_ALLOW_AS=1`）；`TreeBuilder`（BehaviorRegistry 派生命令树）；`Coercion`/`Formatter`/`FacadeRegistry`/`AgentManifestFacade`。
- **易混淆点**：STALE-NAMING drift 仍在（CLI 消费 `BehaviorRegistry`/`behavior_module.interface()`，core 仍存故正确）；CLI 的 "manifest"=AgentManifest 单-agent spawn，与 socialware manifest 车道无关。
- **测试**：8 个。

### ezagent_web（top / web-transport，P13）

- **entry**：`apps/ezagent_web/lib/ezagent_web/endpoint.ex:6`；OTP `application.ex:9`。
- **职责**：整个 umbrella 的 Phoenix HTTP/WS 入口——endpoint、router、认证边界、session-principal 写漏斗、LiveView on_mount 门、匿名 socialware ingress、socialware pull-feed WS 面、自动派生 JSON API；**deploy-seed 实物宿主 + 唯一 late scan 触发点**。声明 ZERO Kind/ActionSet/flavor/recipe。
- **boot（本轮重点）**：`EzagentWeb.Application.start/2` supervisor 起来后：① `Ezagent.Home.SkillSeed.boot!(index?: MIX_ENV != test)`（application.ex:28，skill 分发 P2——恢复/复制 release-bundled skill seeds 进 EZAGENT_HOME + 扫单一 runtime origin）；② `Ezagent.Socialware.ManifestSeed.scan_all!()`（:39，sw-home lane 唯一 late 扫描；:29-38 注释——web 是 dep 闭包最后 boot 的 app，此时所有插件 view/recipe 已注册；扫描逻辑归 session 域，这里只是 trigger；fail-loud；test 默认 off）。
- **deploy-seed 实物**：`priv/socialware_seed/{autoservice,hello,kanban}/manifest.yaml`（autoservice 还带 package.yaml/kb/persona）+ `priv/skills_seed/{kanban-assistant,dev-together,ezagent-session-orchestrator}/`（SKILL.md + scripts/hooks/commands）。
- 路由/端点：`Router`（双 world scope host-scoped 过 RequireEntity；public scope 含 socialware 公开路由 + **`get "/hello/:session_name" → Socialware.ChatFeedController :show_by_name`**（router.ex:193，#1243 短链：`app.ezagent.chat/hello/<name>` 服务 hello 公共页 :188-192））；`Endpoint`（5 socket；CloudflareRemoteIp plug）；`CommandRoutes`。
- 认证/身份：`RequireEntity` / `WorldHostScope` / `CloudflareRemoteIp`（#1206）/ `SessionPrincipal` / `LiveAuth` / `Locale`（en zh_CN）不变。
- Socialware 匿名接入/feed：`AnonIngress` / `AnonCookie` / `AnonTakeover` / **`SessionFeedChannel`（#1243 改：participatory post 的 chat fan-out 改 mention-gated——:355-366 构造 mentions 进 `Ezagent.Message.new(..., mentions: mentions)`，不再直接 alias orchestrator）** / `ExternalFeedSocket`/`ChatFeedSocket` / `FeedEncoding`。
- Controller / LiveView / 邮件：`ApiV1Controller`（Bearer + X-Ezagent-Entity-URI 无 admin fallback）、`ExternalFeedController`/`ChatFeedController`、认证边界 controllers、`UploadsController`、`HomeLive`（W0 workspace-scoped listing）、`Ezagent.Mail.EzagentChatAdapter`（#1198 REST Swoosh）、`RateLimiter`。**#1222 关键资产本地化**：root.html.heex:10 `local_fonts.css`（无外部 Google Fonts CDN），css/js 全 `/assets/` phx-track-static；404/500 页同步。
- **易混淆点**：匿名在 RequireEntity 外（门是 `PublicView.web_anon_access?` 在 AnonIngress）；P14 遵守（唯一 subscribe 是 session_feed_channel advisory）；聚合点（in_umbrella 依赖起全部插件）；seed 实物住这但机制归 core/session。
- **自 49f0167f7（本轮）**：application.ex 两条 boot seed 车道（#1266/#1224）；router /hello（#1243）；session_feed_channel mention-gated（#1243）；root layout/404/500 本地资产（#1222）；chat_feed/external_feed controller 配套；priv seed 实物（#1231/#1233/#1248/#1266）。
- **测试**：42+ 个。
