# 架构加深提案 v1 — Phase 1 审查门

**状态**：提案，非实现计划。
**日期**：2026-06-07。
**范围**：基于当前 `main` 的行为保持型架构加深。
**英文对应**：[2026-06-07-architecture-deepening-v1.md](2026-06-07-architecture-deepening-v1.md)。

本文是 `docs/futures/todo.md` #25 的 Phase-1 交付物。目标不是启动 Phase-2 重构，而是用 deep module 的视角审查当前 ezagent umbrella：让更多行为藏在更小、更清晰的 **interface** 后面，提高 **depth**、**locality**，减少 RBK / Template / domain.agent seam 上的信息泄漏。

## 0. 基本约束

任何 Phase-2 PR 都必须遵守：

- 行为保持；不改功能，不加 silent default，不加 shim。
- 保持 RBK 不变式：dispatch-only、CapBAC chokepoint、workspace isolation、无 plugin-owned scheme、严格 sibling-slice read、Template / Lifecycle authoring contract。
- 只在 `MIX_ENV=test` 下跑测试；永远不对 dev/prod 执行迁移；永远不触碰 dev/prod Docker 容器。
- Codex companion review 保持 static-only，除非 reviewer 明确放开，否则 skip `mix`。
- 本文是审查门；Allen/Claude 审完前不开始 Phase 2。

## 1. 总体判断

当前架构方向是对的。大文件不是随机膨胀，很多是因为真实的不变式先聚集在一起，而更深的 interface 还没形成。正确动作不是大面积按行数切碎，而是围绕已有 domain 词汇抽出少量更深的 module：

- **Session materialization** 仍然由 `SessionCreator.create_session/3` 做唯一 lower-level writer，但 template resolution、orchestrator bootstrap、team materialization、rollback 应该成为内部 module。
- **Agent Template Class** 不应继续同时拥有 config-home materialization、credential grant、sidecar params、spawn rollback、respawn。`cc.agent` 和 `codex.agent` 应该变成 shared domain seam 上的 adapter。
- **AdminLive** 继续作为 `/sessions` coordinator，但 session selection、compose/upload、invite、routing-form、subscription state 应进入小的 state/event module。已有 view module 继续负责 render。
- **Core RBK primitives** 是 sound 的，但 `Behavior`、`Kind`、`Kind.Runtime`、`Capability` 每个文件里都有多个 interface。只在抽出的 module 真正隐藏 grammar/policy 复杂度时拆分，避免 pass-through stage module。

最高影响且相对安全的起点是 UI，因为主要是机械拆分，安全不变式少。最高影响但风险大的区域是 `SessionCreator` 和 agent-template spawn/config seam，因为这里承载 rollback、CapBAC、credential safety。

## 2. 现状快照

handoff 的 LOC 报告仍基本匹配当前源码，唯一差异是 `session_creator.ex` 在当前 `main` 上位于 `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex`。

| 区域 | 当前证据 | Interface 压力 |
|---|---:|---|
| `AdminLive` | 3,217 LOC / 186 个 `def*`；`mount/3`、大量 `handle_event/3`、render、session context、routing forms、mention parsing | 一个 LiveView 拥有太多 event-state seam |
| `SessionCreator` | 1,983 LOC / 78 个 `def*`；`create_session/3`、`repair_orchestrator/2`、rollback、materialization、list | 唯一 writer 正确，但内部 sequence 概念过多 |
| `Orchestrator.Tools` | 1,886 LOC / 83 个 `def*`；member ops、routing rules、template writes、list templates | tool facade、team mutation、routing mutation、template persistence 混在一个 interface |
| `Behavior.Chat` | 1,798 LOC / 78 个 `def*`；Lifecycle state、send/receive/join/leave、working-copy、legends、prompts、signals | 单一 Behavior interface 正确；implementation concept 需要 locality |
| `Entity.Agent` | 1,363 LOC / 59 个 `def*`；Kind declaration、spawn APIs、template-content spawn、credential cascade、sandbox state、lineage | Kind declaration 很浅，spawn/materialization 很深 |
| `Entity.Session` | 1,351 LOC / 59 个 `def*`；Kind declaration、Publisher facade、orchestrator ensure/readiness、working-copy readers | Session Kind 与 orchestrator support 是两个概念 |
| `Orchestrator.McpServer` | 1,071 LOC / 71 个 `def*`；context rebuild、schemas、tool dispatch、MCP error mapping、GenServer | MCP adapter、context resolver、schema catalog、result codec 可拆 |
| `CcAgent` | 2,222 LOC / 103 个 `def*`；Template Class、form、validation、config dir、command argv、PTY、credentials、respawn | Template Class 变成完整 flavor runtime |
| `CodexAgent` | 1,009 LOC / 92 个 `def*`；相同形状，另有 app-server/bridge/thread-id lifecycle | 与 cc 并行重复 seam 形状 |
| Core RBK modules | `Kind.Runtime` 1,459；`Behavior` 1,422；`Kind` 1,076；`Capability` 1,023 | 成熟 primitive 现在隐藏多个 grammar/policy |

本文使用的主要 source anchors：

- Handoff / task：`docs/superpowers/handoffs/2026-06-07-architecture-deepening-codex-handoff.md`、`docs/futures/todo.md`。
- 词汇与不变式：`GLOSSARY.md:30`（Kind）、`GLOSSARY.md:31`（Behavior）、`GLOSSARY.md:147`-`154`（RBK / Lifecycle / sibling-slice / capability decisions）、`.claude/skills/ezagent-developer/references/design-principles.md`、`.claude/skills/ezagent-developer/references/architecture-invariants.md`。
- 热点 module：`admin_live.ex:1`、`session_creator.ex:1`、`tools.ex:1`、`chat.ex:1`、`agent.ex:1`、`session.ex:1`、`mcp_server.ex:1`、`cc_agent.ex:1`、`codex_agent.ex:1`、`kind/runtime.ex:1`、`behavior.ex:609`、`kind.ex:1`、`capability.ex:1`。

## 3. 加深候选

### 3.1 `AdminLive`：coordinator，而不是 god-module

**反模式**：god-module + temporal decomposition。当前 LiveView 同时拥有 mount registration、session auto-ensure、PubSub/event handling、session selection、compose/upload、invite modal、routing rule form、rendering dispatch、mention parsing、error copy。

**提案**：保留 `EzagentPluginLiveview.AdminLive` 作为唯一 route module，把高 locality 的 state/event concern 移到内部 module：

- `EzagentPluginLiveview.Admin.SessionContext`
  - Interface：`default_main_session_uri/1`、`select/2`、`assign/2`、`authorize/2`、`refresh_views_and_members/1`。
  - 隐藏 session URI parsing、workspace authority check、view registry refresh、member/legend read。
- `EzagentPluginLiveview.Admin.Compose`
  - Interface：`form/0`、`send(socket, text, attachments)`、`parse_mentions(text, members, legends)`、`clear(socket)`。
  - 隐藏 upload attachment mapping 与 mention/legend parsing。
- `EzagentPluginLiveview.Admin.Invites`
  - Interface：`options(socket, session_uri, current_members)`、`invite(socket, member_uri)`。
  - 隐藏 invite workspace selection 与 `chat.join` dispatch。
- `EzagentPluginLiveview.Admin.SessionRoutingForm`
  - Interface：`build_matcher(params)`、`parse_receivers(params)`、`validate(socket, params)`、`add_rule(socket, params)`。
  - 隐藏 form parsing 与 receiver revalidation，同时保持 dispatch 路径。
- `EzagentPluginLiveview.Admin.RehydrateFlash`
  - Interface：`assign(socket, meta)`、`text(meta)`。
  - 隐藏 orchestrator-status flash 文案。

**为什么更深**：caller 仍然面对一个 LiveView route，但 LiveView 不再暴露每个 workflow 的数据形状。抽出的 module 隐藏真实 policy/parsing，而不是按行号切文件。

**风险**：低。主要是机械拆分。必须保持 template IDs、`Layouts.app`、stream usage，以及已有 `SessionEditor` / `MemberPanel` / `OrchestratorHealthCard` render。

### 3.2 `SessionCreator`：public writer 不变，内部 materializer 加深

**反模式**：god-module + information leakage。public interface 是对的：`create_session/3` 是 lower-level atomic writer，必须保持唯一 chokepoint。问题是一个 module 同时持有 template lookup、lock orchestration、Session Kind spawn、workspace bind、orchestrator working-copy writes、cap grants、MCP context、team materialization、prompt templates、legends、routing rows、rollback、repair、listing。

**提案**：保持 public facade 不变：

```elixir
EzagentDomainInstanceMessage.SessionCreator.create_session/3
EzagentDomainInstanceMessage.SessionCreator.repair_orchestrator/1
EzagentDomainInstanceMessage.SessionCreator.repair_orchestrator/2
EzagentDomainInstanceMessage.SessionCreator.rollback_session/3
EzagentDomainInstanceMessage.SessionCreator.materialize_template_team/4
```

内部拆成真实 sequence seam：

- `SessionCreator.TemplateResolver`
  - Interface：`resolve!(template_name, workspace_uri)`、`resolve_for_repair(session_uri, workspace_uri)`、`find_uri(template_name, workspace_name)`。
  - 隐藏 snapshot lookup 与 content-addressed SessionTemplate selection。
- `SessionCreator.Materializer`
  - Interface：`create(session_uri, workspace_uri, creator_uri, template)`，返回 `{:ok, meta}` 或 `{:error, reason}`。
  - 拥有 4-8 fail-loud sequence，并委托 sub-operation。
- `SessionCreator.OrchestratorBootstrap`
  - Interface：`materialize_working_copy/3`、`ensure/4`、`grant_caps/4`、`register_mcp/4`、`ready_meta/4`。
  - 隐藏 orchestrator-specific materialization，同时让 rollback 对 materializer 可见。
- `SessionCreator.TemplateTeam`
  - Interface：`materialize(session_uri, workspace_uri, granted_by, content)`，返回 spawned members 和 installed rows。
  - 隐藏 role-name to URI map、member facets、prompt templates、legends、rule sets。
- `SessionCreator.Rollback`
  - Interface：`session(session_uri, orchestrator_uri, opts)`、`delete_rule_rows/1`、`forget_lineage/1`。
  - 隐藏 compensation detail，并集中“必须清理哪些 residue”。
- `SessionCreator.Listing`
  - Interface：`list_sessions/0`、`list_sessions/1`。
  - 低风险 tail extraction。

**为什么更深**：public writer 继续简单且 load-bearing；implementation 按 invariant cluster 获得 locality。reviewer 可以只审 “template resolution” 或 “rollback surfaces”，不用读两千行。

**风险**：高。触碰 RBK invariants、rollback、workspace binding、orchestrator MCP context、template materialization。Phase-2 PR 必须小步，并附 source review + test proof。

### 3.3 `cc.agent` 和 `codex.agent`：Template Class 作为 flavor runtime adapter

**反模式**：leaky seam + duplicated flavor runtime。`CcAgent` 和 `CodexAgent` 同时实现 `Ezagent.Kind.Template`、`Ezagent.UI.Form`、credential declaration、config-home allocation、cascade materialization、sidecar process params、rollback、respawn、test credential refresh。Template Class interface 太小，撑不起这些 runtime 细节，导致长 private helper chain 泄漏。

**提案**：只在已有两个真实 adapter（cc 和 codex）的地方引入 shared module：

- `Ezagent.Agent.TemplateData`
  - Interface：`validate_common/2`、`template_data_extra/2`、`form_to_args/2`。
  - 隐藏 common agent URI/cwd/config_dir validation 和 optional flavor data。
- `Ezagent.Agent.ConfigHome`
  - Interface：`resolve(agent_uri, tmpl, adapter)`、`materialize(agent_uri, tmpl, adapter)`、`env(agent_uri, tmpl, adapter)`。
  - Adapter callbacks：`namespace/0`、`env_var/0`、`secret_relpaths/0`、`credential_relpaths/0`。
  - 保持 cascade materializer 与 credential safety；不能削弱类似 `validate_and_normalize` 的边界。
- `Ezagent.Agent.SpawnPlan`
  - Interface：`build(agent_uri, tmpl, flavor_adapter)`、`start(plan)`、`rollback(plan, reason)`。
  - 隐藏 fresh/adopted 语义与 “adopted worker 不启动 sidecar” policy。
- `EzagentPluginCc.Runtime` 与 `EzagentPluginCodex.Runtime`
  - 保持 flavor-specific interface：`pty_params/3`、`command/3`、`sidecars/3`、`ensure_alive/2`。
  - 这些是 adapter，不是新 core concept。

`CcAgent` / `CodexAgent` 应收敛到：

- `template_name/0`、`config_dir_namespace/0`、credential adapter declaration。
- `validate/1`、`instantiate/3`、`form_fields/0`、`form_to_args/1`。
- flavor-specific command/sidecar adapter delegation。

**为什么更深**：Template Class interface 重新变成 leverage。shared config-home 与 spawn-plan policy 只审一次；flavor module 只表达差异。

**风险**：高。安全敏感点包括 config-home copy、secret relpaths、grant minting、cascade resolution、sidecar rollback、auth failure signals。提案 review 前不要做。

### 3.4 `Orchestrator.Tools` 与 `Orchestrator.McpServer`：domain tools 和 MCP transport 分离

**反模式**：leaky adapter seam。MCP server 同时知道 context rebuild、schemas、argument coercion、tool dispatch、error mapping、GenServer process form。`Tools` 同时知道 tool names、member lifecycle、routing rule mutation、template writes、cap preflight。

**提案**：

- `Ezagent.Orchestrator.ToolCatalog`
  - Interface：`names/0`、`schema(tool)`、`schemas/0`、`normalize(tool)`。
  - 隐藏 MCP JSON schema，并保持 schema 与真实 tool parity。
- `Ezagent.Orchestrator.ContextResolver`
  - Interface：`new(opts)`、`from_orchestrator_uri(uri)`、`refresh_caps(ctx)`。
  - 隐藏 `McpRegistry` cache 从 durable Session snapshot rebuild 的逻辑。
- `Ezagent.Orchestrator.McpCodec`
  - Interface：`args(tool, raw_args)`、`result(tool, tool_result)`、`error(reason)`。
  - 隐藏 argument coercion 与 MCP error mapping。
- `Ezagent.Orchestrator.TeamTools`
  - Interface：`add_member/4`、`update_member_template/3`、`remove_member/2`。
  - 隐藏 managed-member spawn、regeneration、compensation。
- `Ezagent.Orchestrator.RoutingTools`
  - Interface：`define_rule_set_rule/4`、`define_prompt_template/3`、`define_legend/5`、`prune_for_member/2`。
- `Ezagent.Orchestrator.TemplateTools`
  - Interface：`update_template/1`、`save_template_as/2`、`list_templates/2`。

`McpServer` 变成 context + codec + catalog 的 value/process wrapper；`Tools` 可继续作为 compatibility facade。

**为什么更深**：MCP transport 可变化而不碰 team mutation；team mutation 可审计而不用读 JSON schema 和 GenServer boilerplate。

**风险**：中。触碰 CapBAC-sensitive tool execution，但可用 `Tools` facade 做行为保持。

### 3.5 `Behavior.Chat`：保留一个 Behavior，拆 implementation concept

**反模式**：正确 interface 后面 implementation 过宽。`Chat` 作为一个 Behavior 是对的：`send`、`receive`、`join`、`leave`、working copy、legends、prompt templates、signals 都操作 `:chat` slice。拆成多个 Behavior 反而会削弱 RBK 清晰度。问题在 implementation locality。

**提案**：

- `Ezagent.Behavior.Chat.State`
  - Interface：`create(args)`、`activate(state, ctx)`、`read(ctx, key, default)`。
- `Ezagent.Behavior.Chat.Membership`
  - Interface：`join(state, member_uri, facets, ctx)`、`leave(state, member_uri, ctx)`、`handle_down(state, ref, ctx)`。
- `Ezagent.Behavior.Chat.Delivery`
  - Interface：`send_message(msg, ctx)`、`receive_message(msg, ctx)`。
  - 隐藏 MessageStore writes、recipient fan-out、User inbox notifications、AgentBridge delivery。
- `Ezagent.Behavior.Chat.TemplateWorkingCopy`
  - Interface：`set/2`、`set_legends/2`、`set_prompt_templates/2`、`role_name_to_uri/2`。
- `Ezagent.Behavior.Chat.Ring`
  - Interface：`put_recent(state, msg, cursor)`、`message_preview/1`。

public Behavior actions 与 `use Ezagent.Lifecycle, state_slice: :chat` 保留在 `Chat`；helper 处理显式 state map 并返回 effects。

**为什么更深**：保留单一 Behavior seam，同时让每个 state-machine concern 可独立测试，不需要 mock 完整 dispatch。

**风险**：中。触碰 lifecycle transients、sibling-slice reads、delivery fan-out、prompt rendering。第一 PR 应限于机械 helper extraction。

### 3.6 `Entity.Agent` 与 `Entity.Session`：Kind declaration 浅，facade 深

**反模式**：declaration 与 implementation 混在同一 module。Kind module 的 declaration interface（`type_name/0`、`behaviors/0`、`persistence/0`、`supervisor/0`）本来就是浅的。问题是同一个 module 又拥有深 facade。

**Agent 提案**：

- 保持 `Ezagent.Entity.Agent` 作为 Kind declaration 与 public facade。
- 内部移动到：
  - `Ezagent.Entity.Agent.Spawner`：`spawn/4`、`spawn_fresh/4`、`spawn_from_template_content/5`。
  - `Ezagent.Entity.Agent.CredentialCascade`：`resolve/5`、`build/5`、`snapshot/1`。
  - `Ezagent.Entity.Agent.SandboxRecorder`：`record/3`、`cleanup_partial/2`。
  - `Ezagent.Entity.Agent.PostSpawn`：`bind_workspace/2`、`record_lineage/2`、`undo_fresh/1`。

**Session 提案**：

- 保持 `Ezagent.Entity.Session` 作为 Kind declaration 与 Publisher facade。
- 内部移动到：
  - `Ezagent.Entity.Session.Orchestrator`：`ensure/3`、`planned_uri/2`、`read_template_working_copy/1`。
  - `Ezagent.Entity.Session.OrchestratorReadiness`：`await/3`、`kill_on_timeout/1`。
  - `Ezagent.Entity.Session.PublisherFacade`：如果 Publisher behaviour 允许委托且不损害文档清晰度，则放 `subscribe_from/4`、`snapshot/2`、`history/4`。

**为什么更深**：Kind declaration 继续一眼看懂；spawn/orchestrator facade 隐藏真实 workflow。

**风险**：中高。`Agent` 涉及 credential lifecycle 与 lineage；`Session` 涉及 orchestrator readiness 与 Publisher caps。

### 3.7 Core RBK primitives：拆 grammar/policy，不拆 stage

**反模式**：multi-interface module。core 文件不像 UI/domain 那样是普通 god-module；它们 dense 是因为定义 primitive contract。拆坏了会产生 shallow pass-through module，让 RBK 更难学。

**提案**：

- `Ezagent.Behavior`
  - 保持 `use Ezagent.Behavior`、`action/2`、introspection functions 为 public interface。
  - 抽 `Ezagent.Behavior.ActionSpec` 处理 action option validation 与 derived callbacks。
  - 抽 `Ezagent.Behavior.Effects` 处理 `apply_effects/2`、bucket grammar、ref substitution。
  - 风险：中；macro code 对 compile-time 很敏感。
- `Ezagent.Kind.Runtime`
  - 保持 `handle_dispatch/4` public。
  - 抽 `Ezagent.Kind.Runtime.Authz` 与 `Ezagent.Kind.Runtime.WorkspaceIsolation`，因为它们是真 policy 且有独立 invariant。
  - 不要为每个 pipeline step 建 module，除非 interface 真的隐藏 policy。
  - 风险：高；触碰 dispatch chokepoint。
- `Ezagent.Kind`
  - 保持 behaviour callbacks 与 public `spawn/2`、`terminate/1`。
  - 若 line pressure 仍在，抽 `Ezagent.Kind.Lifecycle` 管 spawn/terminate strategies，抽 `Ezagent.Kind.Introspection` 管 `behaviors_of/1` / attach metadata。
  - 风险：中高。
- `Ezagent.Capability`
  - 抽 `Ezagent.Capability.Normalize`、`Ezagent.Capability.Match`、`Ezagent.Capability.Scope`。
  - `Ezagent.Capability` 继续是 public struct + facade。
  - 风险：高；CapBAC 是安全关键。

**为什么更深**：interface 对齐 grammar/policy seam：action specs、effects、authz、workspace isolation、capability normalization/matching。

## 4. 需要保护的 RBK seam

Phase-2 所有工作都要保护这些 seam：

- **RBK dispatch seam**：`Invocation.dispatch/1` 到 `Kind.Runtime.handle_dispatch/4` 仍是语义主干。任何重构都不能加 direct actor-to-actor call。
- **Lifecycle seam**：developer-facing Behavior 仍使用 `use Ezagent.Lifecycle`；`use Ezagent.Behavior` 与 effect execution 保持 engine internals。
- **Template Class seam**：plugin 提供 Template Class adapter；core/domain 定义通用 contract。不得出现 plugin-specific scheme 或 core dependency。
- **SessionTemplate materialization seam**：`SessionCreator.create_session/3` 继续是 lower-level single writer；拆分不能制造第二 writer。
- **Agent config/credential seam**：credential relpaths、secret relpaths、config-home env vars、cascade grants、auth failure signals 都是 shared materialization policy 上的 flavor adapter data。
- **Orchestrator MCP seam**：不可信 wire input 只提供 tool args；session、workspace、owner、parent template、caps 都在 server-side resolve。
- **Capability seam**：输入 normalize 一次，按 kind/behavior/action/instance/workspace 匹配，并保持 scope tuple 语义。
- **ExternalMirror seam**：保持 Publisher -> Worker Kind -> Adapter -> Binding；Binding 不得直接 PubSub subscribe。

## 5. 优先级

| 优先级 | 候选 | 影响 | 安全性 | 为什么现在做 |
|---|---|---|---|---|
| P0 | `AdminLive` state/event extraction | 高 | 高 | 最大 LOC 文件；低 invariant 风险；立即提升 AI-navigability |
| P0 | `SessionCreator` listing / template resolver extraction | 高 | 中 | 从最高价值 domain split 的低风险边缘开始 |
| P0 | `SessionCreator` materializer / rollback / team modules | 很高 | 低 | 必须谨慎审查；关闭主要 audit surface |
| P1 | `Orchestrator.McpServer` codec/catalog/context split | 中高 | 中 | 分离 transport 与 domain tools |
| P1 | `Orchestrator.Tools` team/routing/template split | 高 | 中 | tool 行为可按 concern 审计 |
| P1 | `CcAgent` / `CodexAgent` shared config-home and spawn-plan seam | 很高 | 低 | 去除重复的安全敏感 flavor runtime，但风险高 |
| P1 | `Behavior.Chat` helper extraction | 高 | 中 | 保持 Behavior seam，同时提升 locality |
| P2 | `Agent` / `Session` facade extraction | 中高 | 中 | 等 SessionCreator/tool split 澄清 caller needs 后再做 |
| P2 | Core `Behavior` / `Capability` grammar splits | 中 | 低 | 需要更强 test proof；在 domain/UI 有先例后做 |
| P3 | Core `Kind.Runtime` / `Kind` policy splits | 中 | 低 | blast radius 最高；等 caller 稳定后再做 |

## 6. 推荐 Phase-2 PR 顺序

1. **PR-A：AdminLive session context + rehydrate flash extraction**
   - 机械移动。保持 route、render、assigns、DOM IDs。
   - 测试：touched LiveView tests。

2. **PR-B：AdminLive compose/invite/routing form extraction**
   - 机械移动，加 mention parsing 与 routing form validation helper tests。
   - 测试：LiveView + helper unit tests。

3. **PR-C：SessionCreator listing + template resolver extraction**
   - facade 不变。先移动 tail/listing 和 template lookup。
   - 测试：现有 SessionTemplate/session creation tests。

4. **PR-D：SessionCreator TemplateTeam extraction**
   - 移动 member materialization、role maps、prompt templates、legends、rule sets。
   - 测试：materialization、routing rule、legend/prompt tests。

5. **PR-E：SessionCreator OrchestratorBootstrap + Rollback extraction**
   - 最高风险 session PR。显式 audit rollback write surfaces。
   - 测试：orchestrator startup atomicity、rollback、MCP registry rehydrate。

6. **PR-F：Orchestrator.McpServer catalog/context/codec extraction**
   - 保持 `McpServer` value/process interface。
   - 测试：MCP schema/tool-call/error mapping tests。

7. **PR-G：Orchestrator.Tools team/routing/template modules**
   - 保持 `Tools` facade 委托到更深 module。
   - 测试：tools tests + routing/template update tests。

8. **PR-H：cc/codex shared ConfigHome and SpawnPlan foundation**
   - 引入 shared modules，两个 flavor 作为 adapter；不改行为。
   - 测试：cc + codex template tests、config-dir/cascade/credential tests。

9. **PR-I：Behavior.Chat helper modules**
   - action declarations 保留在 `Chat`；移动 state-machine helpers。
   - 测试：chat behavior、sender/legend/prompt、AgentBridge delivery。

10. **PR-J：Agent/Session facade extraction**
    - 等 SessionCreator 和 Tools 稳定后移动 spawn/orchestrator internals。
    - 测试：agent template spawn、orchestrator readiness、publisher facade。

11. **PR-K/L：Core grammar/policy splits**
    - `Behavior.ActionSpec` + `Behavior.Effects`；再做 `Capability.Normalize/Match/Scope`。
    - 除非有明确 testability gain，否则继续推迟 `Kind.Runtime`。

## 7. 明确不做

- 不为了降低行数而切文件。如果新 module interface 只是 “call next step”，它就是 shallow。
- 不把 `Behavior.Chat` 拆成多个 Behavior，除非真实 slice/interface 改变；否则会改变 RBK 语义。
- 不削弱 `SessionCreator` 的中心性。目标是在同一个 single writer 后面加深内部 materializer。
- 不在 core 引入泛化的 `AgentRuntime`。Flavor runtime 仍属 plugin/domain adapter 领域。
- 不为了测试方便在 CapBAC 或 workspace isolation 上加默认值。

## 8. Phase-2 Review Checklist

每个 refactor PR 都应回答：

- 哪个 interface 变小或变深？
- 哪个 implementation detail 现在获得了 locality？
- 哪些 RBK invariants 可能被触碰？
- diff 是纯 move/split，还是行为改变？
- 哪些 test evidence 证明 behavior preservation？
- static Codex review 是否在不跑 `mix` 的前提下审了 load-bearing seams？

## 9. Phase-1 结论

只有在本文审查通过后才进入 Phase 2。推荐第一个实现目标是 `AdminLive`，然后是 `SessionCreator` 的低风险边缘。`cc/codex` shared runtime seam 架构价值很高，但应等 review 确认 config-home 与 credential boundary 后再做，因为该区域安全敏感，也最容易过度泛化。
