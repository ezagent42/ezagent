# 调研 · agent-contract / agent-schema 已落地（给 intro/ 改稿用）

> 目的：核实 main 上「agent 定义契约（agent-contract / agent-schema）」的真实落地状态，给 intro/ 文档里那些把 world、agent-schema 写成「在建 / future / 未进 main」的过时说法做依据。
> 全程带 file 路径，全部对照真实代码核实过；拿不准的都去读了源码。
> 设计权威：`docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md` + spec-1/2/3（同目录）。

---

## 0. 一句话结论

**agent-contract 已经从设计落到 main 的代码。** 它不是一个新运行时，而是在 ezagent 已有原语（Kind / Lifecycle / flavor / 模板 spawn / CapBAC / 路由）之上，**给「怎么声明一个 agent」补的那层框架契约**。

- 核心数据契约 = `Ezagent.AgentManifest`（`apps/ezagent_core/lib/ezagent/agent_manifest.ex`）——一份**数据 manifest**（YAML/map），不是 Elixir 代码、不是 Python。
- 三个 spec 全部有对应实现 + E2E 场景 + 测试，不再是「在建」。

> intro/ 里凡是说 **agent-schema「还没进 main / 是产品化方向 / 别当已有」** 的（典型见 `docs/discuss/intro/05-编排器与客户界面生成.md:162`），现在**全部过时**，要改成「已落地」。

---

## 1. agent-contract 是什么、解决什么问题

### 1.1 它要解决的痛点（spec design §1）

ezagent 历史上**没有一个规范的方式去「声明」一个 agent**。agent 的形状散落在三处：`AgentTemplate` 的 `:template` slice、没人用的 `Ezagent.Role` 结构、各插件里的 `agent_flavors/0`。结果：

- 没有统一的开发者/作者编辑面；
- 换后端（flavor，比如 cc → codex → curl）不干净；
- 编排器想「凭空造一个新 agent」时没有一等公民的指引。

`autoservice-dev` 分支已经**为单一行业把这套契约硬写出来证明过**（soul markdown + slot YAML + SoulRenderer + CR/release 发版管线）。**agent-contract 就是把那套硬编码抽成框架层契约，让下一个行业是声明式的、不用手搓。**

### 1.2 核心立场（design §2，Allen 拍板）

四个参考（Flue / Cloudflare Agents-SDK / Omnigent / autoservice-dev）叠成四层：

```
① 框架 / 契约层   Flue createAgent · Omnigent agent.yaml   ← 这一层是缺口 = agent-contract
② 后端切换 / flavor                                         ✅ 已有 flavor + AgentFlavorRegistry
③ harness / agentic loop                                    ✅ 已有 cc/codex 子进程
④ 运行时（Kind+Lifecycle+Sandbox+snapshot+dispatch+CapBAC） ✅ 已有，是护城河，永不外包
```

ezagent 占住底下三层，**agent-contract 只补①**。产品取向：**少数几个深度集成的后端 + 厚运行时**。

### 1.3 最关键的设计原则：实体类型透明（design §2.1）

ezagent 核心承诺——**实体类型是透明的**。一个人（`entity://.../user/...`）、一个程序、一个 agent（`entity://.../agent/...`）在主干上是统一的：`Invocation.dispatch/1`、路由 `Resolver`、`chat.join`、`Kind.spawn`、`holds_cap?/2` **都不按类型分叉**。所以：

- manifest 是某实体的「agent 类型 *身体*」，跟 user 的 `password_hash`、echo 的空身体是兄弟，**不是另起炉灶的平行王国**；
- caps 走 Identity 授予、成员资格走 `chat.join`、路由走 `Resolver`、spawn 走 `Kind.spawn`——manifest **只声明，不重新实现**这些。

---

## 2. manifest 工具契约长什么样

### 2.1 manifest 是数据，不是代码（design §4）

形态：**数据 manifest（YAML/JSON）+ 一份 `soul` markdown**。原因：要能持久化、fork、版本化（进 CR/release）、跨 dispatch 传输、由**非开发者在管理 UI 里编辑**——只有数据能同时满足这些。Elixir 只提供**校验 schema struct + loader + flavor.compile**，不把契约表达成代码。（多租户安全：租户写的代码不能 eval 进 BEAM；dispatch 只传数据不传代码。）

manifest 字段分三组：

- **author 字段**（后端无关，可复用的「角色」）：`soul` + `skills` + `tools` + `caps` + `lifecycle`；
- **`executor`**（唯一跟后端耦合的组）：`flavor`（候选列表 + fallback 策略）+ `params`；
- **compiled config**（`flavor.compile` 的产物）：作者**永远不写、不看、不存进 manifest**。

### 2.2 落地的 schema（`apps/ezagent_core/lib/ezagent/agent_manifest.ex`）

`%Ezagent.AgentManifest{}` struct（`agent_manifest.ex:17-33`）字段：`name / soul / skills / tools / caps / lifecycle(:persistent|:ephemeral) / executor`。

- **loader**：`AgentManifest.load/1`（`agent_manifest.ex:41-74`）吃 YAML 串或 map，校验必填、`executor.flavor` 非空、**拒绝 author 字段里出现 flavor 类字段**（`@forbidden_author_fields = [:flavor, :derived_config, :compiled_config]`，`agent_manifest.ex:36`、`reject_forbidden_author_fields/1` `:186`）——这是「flavor 不许漏进 author bucket」不变式的运行时孪生。
- **slot 渲染**：`AgentManifest.render/2`（`agent_manifest.ex:82-104`）把 `soul.md` 里的 `{{slot}}` 用 slot 值填掉，**缺 slot 直接报错（fail loud，`{:missing_slot, name}`）**，渲染结果是 spawn 期派生物，**不写回 manifest**。这是 flavor 无关的共享预编译步。
- **tools[] 校验**：`normalize_tool_decl/1`（`agent_manifest.ex:310-344`）实现两类工具声明：`:action`（要 `action` + `caps`）和 `:participant`（要 `ref`，可选 `role_name`），都支持 `optional: true`。

### 2.3 tools[] 是 dispatch 撑起来的、类型透明（design §7 + spec-2）

- `skills[]` = 注入上下文的指令，**不是可调用工具**。
- `tools[]` = MCP 工具，工具体是一次**被授权的 ezagent dispatch**（复用编排器 MCP 工具的既有机制）。
  - `:action` → dispatch 到某 Behavior action；
  - `:participant` → 「加一个参与者」，泛化 `add_managed_member`：ref 是 manifest 就 spawn+join，ref 是已有实体 URI（人/程序）就只 join。
- **CapBAC 铁律（codex P1-1）**：工具 dispatch 携带 **`ctx.caps = []`**。manifest 声明的 `caps` 是在 spawn 时授予到 agent 的 Identity slice、走 `holds_cap?` 校验，**绝不注入进 dispatch 的 ctx**（运行时信任 ctx.caps 先于 Identity slice，注进去等于租户 YAML 自我授权）。**manifest YAML 声明的是「想要」，从来不是「授权」**。
- 落地证据：`Ezagent.AgentManifest.Tools.dispatch_action/4`（`apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex:18-33`）——dispatch 时 `ctx: %{caller: agent_uri, caps: MapSet.new(), ...}`，注释明确写「Manifest caps are declarations only ... carries an empty `ctx.caps` set so authorization falls through to `holds_cap?/2`」。
- `:participant` 落地：`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/participants.ex` —— `add_participant/3`（`:9`），ref 是 manifest 走 `Ezagent.Entity.Agent.spawn_from_manifest`（`:117`），已有实体走 `Membership.provision_invited_join_authority`（`:68`），两条路都落到类型盲的 join + **会话作用域**的参与权限（不给 workspace-wide）。

### 2.4 flavor.compile —— 泛化 SoulRenderer（design §5 + spec-1）

每个 flavor 的 Template Class 实现 `compile/2` callback：

- callback 声明在 `apps/ezagent_core/lib/ezagent/kind/template.ex:72`（`@callback compile(resolved_manifest(), params) :: {:ok, derived_config} | {:error, _}`）；
- cc 实现：`apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex:271`（`@behaviour Ezagent.Kind.Template`，`:188`）；
- curl 实现：`apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex:104`；
- codex 也有 spawn_from_manifest 路径（`apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex`）。
- **不变式**：`compile/2` 是**纯渲染**——不写盘、不起 PTY、不授权；author 字段不含 flavor 字段；derived_config 不漏回 manifest（CI grep-gate + loader 双重把关）。

### 2.5 后端 fallback —— 作者可配的规则（design §6 + spec-1 §3.4）

`executor.flavor: [cc, codex, curl]` = 有序候选，spawn 期逐个试，任一 spawn 失败就 fall-through；`fallback` 可给每候选指定「在哪种失败下落到下一个」；全失败 → `on_exhausted`（默认 `:notify_orchestrator`），**fail-closed，不留孤儿 agent**。这是 **spawn 期、不是 per-message** 的。schema 里 `executor` 含 `fallback` + `on_exhausted`（`agent_manifest.ex:10-15, 242-262`）。落地在 `Ezagent.Entity.Agent.spawn_from_manifest`（`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:422` defdelegate → `template_spawn.ex`），复用既有 `spawn_from_template_content/4` 的失败自清理回滚。

---

## 3. versioned artifact pin + migrate_session 是什么（spec-3，gate G4）

这是「编辑模板会话 → 发布 → 新会话采用新版、老会话手动迁移」的语义，**复用 autoservice 已有的 CR/release 管线**，main 上落地的是 **version-pin + migrate 的语义**。

### 3.1 版本钉（pin）——复用已有的不可变 URI（design §9 + spec-3 §3.1）

- 一个会话持有的 `template_working_copy.session_template_uri` 本来就是**不可变的 `@version_hash` URI**（SHA-256 over slice content，`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex`）。
- **mutable tag**：`Ezagent.TemplateTags`（`apps/ezagent_core/lib/ezagent/template_tags.ex`）—— `(name, tag) → version_hash`，类似 git：tag 会动，hash 不动。
- **发布 = 造一个新 hash 行 + 移一个 tag，绝不改老行**。所以老会话（持旧不可变 URI）**结构上完全不受发布影响**。没有新增 pin 字段。
- **adopt-on-create**：新会话在 `create_session/3` 把 tag 解析成不可变 hash 并钉住；老会话保持冻结的 hash。**发布只影响未来的 create，不动任何活会话。**

### 3.2 AgentTemplate 也补了内容哈希（核实代码，比 spec 文字更新）

spec-3 §3.3 提了「soul/slot 编辑必须 mint 新的 AgentTemplate 版本（新 source_template_uri），否则会撞 `update_member_template` 拒绝同 URI 的路径」。main 上 `AgentTemplate` 已经加了哈希支持：`compute_version_hash/1`（`apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex:188`）+ `build_versioned_uri/3`（`:198`，`template://<ws>/agent/<name>@<hash>`）。注意根 URI 仍是 versionless（`agent_template.ex:29-30`），哈希是为迁移服务的。

### 3.3 migrate_session —— 账本追踪的会话级迁移（design §9 + spec-3 §3.3）

- 落地：`Ezagent.Orchestrator.Tools.Migration.migrate_session/2`（`apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/migration.ex:9-31`），也作为编排器工具暴露（`tool_catalog.ex` 里有 `migrate_session`）。
- `update_member_template/3` 是**逐成员**的（本地补偿）、且**拒绝同 URI 交换**，所以 `migrate_session` 是在它之上的编排，带**显式 ledger（账本）**：先把迁移账本写进 working_copy（`%{target, members: %{role => :pending}}`，`ensure_ledger/3` `:86`、`new_ledger/2` `:108`），逐成员 swap 后 checkpoint（`:done | :failed`），最后整体成功才把 pin 指到 target、清账本；部分失败时账本留存，**re-run 从 :pending/:failed 续跑（幂等收敛）**。
- 不变式（spec-3 §4）：迁移复用 `update_member_template`（不新建活 PTY 改写路径）；只动目标会话自己的路由（`created_by == session_uri`）；fork/版本只带配置不带消息历史；部分迁移可恢复（账本是恢复锚）。
- E2E 场景：`apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex` —— Part A 验 adopt-on-create + 发布后老会话冻结，Part B 验 `migrate_session` 含中途注入故障后续跑收敛。

---

## 4. 跟「编排器动态生成客户界面」的关系（给 intro/05 改稿用）

这是 intro/ 最需要更正的一处认知。两件事的分工：

- **intro/05 讲的链路**（编排器用 9 个 MCP 工具塑造会话形态 → Turn 把成员产出的 page tree 定格 → CustomerFeed 投影 → 浏览器 json_render 渲染）**依然成立、依然是 main 上的运行机制**。
- **agent-contract 给这条链路补的是「agent 怎么被声明出来」那一端**：编排器要「招一个成员 agent」时，那个成员现在可以由一份**声明式 manifest** spawn 出来（`spawn_from_manifest` / `:participant` 工具），而不必依赖硬编码的 AgentTemplate slice。
  - design §10 明确：「NL → SessionTemplate」的分解能力是**编排器的一个 skill**，不是契约层特性；契约层的职责只是**让那个产出可表达**（members + relay-chain 路由规则 + legend entry + prompt templates）。
  - 也就是说：**编排器「设计这台机器」的能力 + agent-contract「让机器里的零件（agent）可声明、可换后端、可版本化、可迁移」**——两者合起来才是「编排器动态生成 / 演化客户产品形态」的完整闭环。

**改稿要点**：`docs/discuss/intro/05-编排器与客户界面生成.md:162` 那段「产品化方向（还没进 main，别当已有）：world + agent-schema」必须改写——

1. **world 已落地**：`apps/ezagent_plugin_liveview` 已删，新增 `apps/ezagent_plugin_world`（统一 React 前端，复刻并取代原 LiveView 管理面）；不再是「过渡形态 / future」。
2. **agent-schema（= agent-contract）已落地**：`Ezagent.AgentManifest` + `flavor.compile` + `executor` fallback + `tools[]`/`:participant` + versioned pin + `migrate_session` 全在 main，有 E2E gate（G1-G5）。
3. socialware skill 已同步到 world + agent-contract（PR #882）。

---

## 5. 一句话给改稿的人

> agent-contract / agent-schema = **「怎么声明一个 agent」的数据契约**，已落到 main：`Ezagent.AgentManifest`（schema+loader+slot render）+ 每 flavor 的 `flavor.compile`（纯渲染、泛化 SoulRenderer）+ `executor` 后端 fallback（spawn 期、fail-closed）+ dispatch 撑起的 `tools[]`（`:action`/`:participant`，CapBAC 用空 ctx.caps）+ 复用不可变 `@hash` pin 的 adopt-on-create + 账本追踪可恢复的 `migrate_session`。它跟编排器动态生成界面是互补两端：编排器塑造会话形态，agent-contract 让会话里的 agent 零件可声明、可换后端、可版本化、可迁移。**intro/ 里所有把 world / agent-schema 写成「在建/future/未进 main」的话都过时了。**

---

## 附：核实过的 file 锚点清单

| 概念 | file:line |
|---|---|
| manifest schema + loader + render + tools 校验 | `apps/ezagent_core/lib/ezagent/agent_manifest.ex` |
| manifest 工具 dispatch（空 ctx.caps） | `apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex:18-33` |
| flavor.compile callback 声明 | `apps/ezagent_core/lib/ezagent/kind/template.ex:72` |
| cc / curl compile 实现 | `apps/ezagent_plugin_cc/.../cc_agent.ex:271`、`apps/ezagent_plugin_curl_agent/.../curl_agent.ex:104` |
| spawn_from_manifest 入口 | `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:422` → `.../entity/agent/template_spawn.ex` |
| CLI facade（manifest → spawn） | `apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex` |
| `:participant` 加成员 | `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/participants.ex` |
| 版本 tag（mutable） | `apps/ezagent_core/lib/ezagent/template_tags.ex` |
| SessionTemplate 不可变 @hash pin | `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex` |
| AgentTemplate 内容哈希 | `apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex:188,198` |
| migrate_session（账本） | `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/migration.ex` |
| G4 E2E 场景 | `apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex` |
| 设计权威 | `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md` + spec-1/2/3 |
