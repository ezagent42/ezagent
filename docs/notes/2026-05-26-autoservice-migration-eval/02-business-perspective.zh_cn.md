# 业务能力迁移评估（subagent 2：business 视角）

> 评估范围：业务能力 / 内容模型 / 权限。会话流程优化（pipeline_v2 / fast+cc / filler）与进程模型（cc_pool 复用语义）已划归其他视角。
>
> 立场：假设要迁，给具体映射方案。

---

## 1. 4 层 Soul/Skill 用 Template Class / Behavior 表达

AutoService 4 层（L0 框架 / L1 平台 / L2 行业 / L3 租户，优先级 100/90/70/50，见 `autoservice/storage/resolver.py:110-149`、`docs/architecture/soul-layer-redesign-2026-05-19.md` §2.1/2.3）的本质是 **"内容优先级合成 + 跨租户复用"**，*不是* 4 套独立资源。映射到 ezagent：

- **L0/L1/L2 → Template Class**（OTP 模块，ezagent_domain_chat 或新 ezagent_plugin_autoservice 装配）。Template Class 是模块级声明（P24），住在工程团队 git 仓——这跟 AutoService L0-L2 都从 git 加载契合。建议：
  - L0 framework → `Ezagent.Template.Class.AutoServiceFramework`（住 plugin tier）
  - L1 platform / L2 industry → **不是**新 Template Class，而是 L0 同一个 Template Class 在 `agent_slots` 上的命名约定（slot prefix 区分），通过 `priority.yaml` 数据声明合成顺序——避免 "industry 多了就多一个 Class" 的爆炸。
- **L3 租户填值 → SessionTemplate 的 fork（config only — 不变式 #10）**。AutoService 的 `master/templates/<role>/<sid>.md` + `.autoservice/data/tenants/<tid>/sections/<role>/<sid>.yaml` 双文件模型（模板 + 槽值），正好对上 `SessionTemplate.agent_slots`：模板 = Template Class，槽值 = SessionTemplate per-tenant 实例的 slot fill。**version_hash 已有**（P26），canonical-hash 这一侧 AutoService 自己写的 `autoservice/storage/canonical_hash.py` 可以删——SessionTemplate 的 `@<hash>` 是内容寻址的唯一 Kind。
- **4 层覆盖优先级（priority.yaml + overrides 白名单，soul-layer-redesign §2.3）**：在 ezagent 里不是 Behavior 关心的事，是 **加载期** 的合成函数。建议放进 Template Class 的 `boot/0` 或 `Ezagent.Workspace.Loader` 钩子里。**绝不要** 在 `Chat` Behavior 里做合成——这会让每个 Behavior 都需要"知道 4 层在哪"，违反 P9（reads what data 决定 tier ownership）。
- **Skill loader**：lazy-load 通过 cc 自己的 Read tool 触发，对 ezagent 而言是 **agent process 内部行为**，不进入 dispatch path。skill index 走 SessionTemplate 的 `working_directory` + MCP config —— 见 commit 18099a7（`--mcp-config` per-agent cwd .mcp.json）。

**风险**：AutoService 的 lint（"L3 不能定义 L1 域的规则"，soul-layer-redesign §2.3）需要落到 Template Class 的 `validate_slot/2` callback。ezagent 当前没有这种声明式 lint hook——是缺口，需要 phase-spec 立项。

---

## 2. 两棵树存储 → workspace_uri-scoped Resource

AutoService 的 unit address grammar（`autoservice/storage/address.py`）：

```
<address>      = <unit-id> "@" <kind>
<unit-id>      = <scope-prefix> "/" <role> "/" <slug>
<scope-prefix> = "tenants/" <tid>
               | "_framework"
               | "_platform"
               | "_industry/" <industry>
<kind>         = "soul_section" | "flow_directive" | "product_knowledge" | "skill"
```

映射到 SPEC v3 6-scheme（不变式 #11）：

| AutoService unit | ezagent URI（3-segment 强制 — 不变式 #11） |
|---|---|
| `tenants/cinnox/customer/persona@soul_section` | `template://soul_section/cinnox/customer.persona` |
| `tenants/cinnox/customer/refund-tier-1@flow_directive` | `resource://flow_directive/cinnox/customer.refund-tier-1` |
| `tenants/cinnox/customer/acme-brand-voice@skill` | `resource://skill/cinnox/customer.acme-brand-voice` |
| `tenants/cinnox/-/kb-chunk-abc@product_knowledge` | `resource://kb_chunk/cinnox/abc` |
| `_framework/customer/identity@soul_section` | `template://soul_section/system/customer.identity` |
| `_platform/customer/dt-protocol@soul_section` | `template://soul_section/system/customer.dt-protocol-platform` |
| `_industry/cloud-comms/customer/kyc@soul_section` | `template://soul_section/system/customer.kyc-industry` |

**为什么 soul_section → `template://` 而 flow_directive/skill/product_knowledge → `resource://`**：

- soul_section 是 **slot 模板 + 实例化** 的产物 = Template（P26 fork=config）
- flow_directive / skill / product_knowledge 是 **内容资产**（被引用、被 prefetch、被 lazy-load）= Resource（P10 shared-referent needs identity）

**L0-L2 框架/平台/行业资源放 `workspace://system`**（不变式 #13）——它们是 cross-cutting、不属于任何租户。`workspace://system` 已经是 ezagent 的结构性 sink（`visible: false`，bootstrap admin 是 canonical 成员）。

**不入 git 怎么对应**：AutoService 的 "git 仓库 vs `.autoservice/data/`" 二分在 ezagent 里 **不直接成立**——所有 per-tenant 数据都进 SQLite，由不变式 #14（`workspace_uri TEXT NOT NULL`）+ `Persistence.scope_by_workspace/2` 强制隔离。git 这棵树消失，只剩 ezagent_plugin_autoservice 的 OTP app 代码自身在 git。`released/<tid>/<sha>/` 快照变成 `kind_snapshots` 表里 `kind_uri = template://soul_section/cinnox/...` 的 on-change snapshot 行。**GDPR right-to-erasure 反而更干净**——drop workspace 等于 delete from per-tenant tables where workspace_uri = ?，没有 git 历史包袱。

---

## 3. CR 流程：能直接搬 / 需重新建模 / 必须废弃

CR 在 ezagent 是 **`entity://` Kind**（不是 session）：

- URI 形如 `entity://cr/cinnox/cr_abc123`
- 注册 Behaviors：`CR.create` / `CR.edit` / `CR.publish` / `CR.revert`（query-string action）

为什么是 entity 而不是 session：CR 没有 Chat 语义（不是人话对话），是一个持久聚合，跨多次 admin 操作存活——这就是 ezagent 对 entity 的定义（P10 shared-referent + 多 caller 引用）。

**逐项映射**：

| AutoService 当前行为 | ezagent 重新建模 |
|---|---|
| `ensure_active_cr(tid)` lazy-create + UNIQUE (tenant_id, status='draft') | `Ezagent.Kind.spawn/2`（P16，唯一入口），UNIQUE 约束改成 `WorkspaceRegistry` + spawn idempotency |
| 沙箱写入触发 CR auto-create | LV `handle_event :edit_soul_section` → dispatch `template://...?action=edit` → 该 Behavior 里 ensure CR by side-dispatch |
| `compute_sandbox_diff(tid)` 实时 diff | 用 `kind_snapshots` 的 `current snapshot` vs `released pointer snapshot` 比对，不用建独立 diff table |
| Publish 红色二次确认 | LV-side UX 约束（不进入 dispatch）；服务端 `?action=publish` 调用前由 LV 收一次手动 confirm |
| flip pointer | `?action=publish` 写新一行 `kind_snapshots` + 更新 `released_pointers` 表的 workspace 行 |
| **recycle cc_pool** | **重新建模**：ezagent 没有 pool 概念。等价是 agent Kind 重启——dispatch `entity://agent/cinnox/cc_customer?action=reload_soul` 由该 agent 的 Behavior 自己处理（kill PTY + respawn）。**不要**让 CR Behavior 直接重启 agent process（违反 P14 单一 dispatch path） |
| **必须废弃**：`sandbox_locks` 表 + `sandbox_snapshot.py` 整模块（cr-lifecycle-redesign §4.3 已经废了） | 不存在等价物，不要带进 ezagent |
| **必须废弃**：CRSource.DOCS_REGEN | 不引入 |

**关键洞察**：CR 流程跟 ezagent 的 `kind_snapshots`（per-Kind on-change snapshot，core 提供，P22）天然契合。AutoService 自己写的 sandbox-vs-released diff 机器，在 ezagent 里"白送"——这是 P8（少发明多装配）的明确收益点。

---

## 4. 多通道 + per-channel overlay 不违反 P12 的做法

AutoService 通道：web chat（SSE/WS）、voice（WS + ASR/TTS）、第三方 SSE。每通道有 `channels/<channel>.yaml`（如 `voice.yaml` filler 词表、TTS 参数、deepseek 专属 prompt）+ per-role overlay `<role>.<channel>.yaml`（如 `customer.voice.yaml`）。

**ezagent 里通道是 Adapter（plugin），不是 Kind**（P12 + P13）。每条通道：

- `ezagent_plugin_autoservice_web_chat`（HTTP SSE plug — P13 Plug-level，非 MVC）
- `ezagent_plugin_autoservice_voice`（WS plug + 自己的 PCM/ASR/TTS bridge）

每个 plugin 做且只做两件事（P12 hard test）：(1) parse inbound 成 `%Invocation{}`，(2) 通过 `ctx.reply` 写回。

**per-channel overlay 怎么不漏进 Behavior**：

- voice filler 词表 / TTS 参数 → 完全 plugin 内部状态，**不出 Adapter 边界**。Chat Behavior 不需要知道有没有 filler。
- deepseek 通道专属 prompt → 加进 `entity://agent/<ws>/deepseek_<role>` 这个 agent 的 SessionTemplate slot，**用通道是哪个来选择哪个 agent**，不是 Chat Behavior 内部分支。
- **绝不**写 `if ctx.channel == :voice` 这种代码——这是把 transport 知识漏进 domain 的典型反模式（P12 + anti-pattern "abstract generic 'channel'"）。

`autoservice/storage/overlay.py` 的合成函数迁过来后，应该住在 plugin 的 `boot/0` 加载阶段，**不是**运行时 Chat Behavior 里。

**关于通道 vs CC Channel 术语消歧**（CLAUDE.md 提示）：AutoService 说的 "channel" 是业务通道（web/voice），跟 CC Channel（MCP 协议 `notifications/claude/channel`，不变式 #3）是两码事——不要把 voice TTS 配置塞进 cc channel notification meta，meta 是 `Record<string, string>`。

---

## 5. RBAC → CapBAC 映射

AutoService 现状（overview §8.3）：master_admin / tenant_admin RBAC，router-level 鉴权（section/flow/master_soul）+ per-endpoint 鉴权（skill 路由 mild gap，待统一）。

CapBAC 等价（不变式 #5 narrow never broaden + cap-check chokepoint）：

| AutoService 概念 | ezagent cap |
|---|---|
| master_admin | `workspace://system` 成员（不变式 #13）。**不**用 `:any` cap（anti-pattern：admin_caps() bypass）。所有 master_admin 用户是 `entity://user/system/<name>` |
| tenant_admin | per-workspace cap：`%Capability{kind: Ezagent.Entity.User, behavior: :any, instance: {:within_workspace, workspace_uri}}` —— 但 ezagent 暂时只有 `{:within_session, _}` / `{:spawned_by, _}` 形状。**需要扩展**：加 `{:within_workspace, _}` 到 `Ezagent.Capability` 的 scope-bounded 集合（P15）。这是一个非 trivial 的核心改动，需要走 brainstorm |
| 普通客服 operator | 单 session 内 chat cap：`%Capability{kind: Ezagent.Session, behavior: Ezagent.Behavior.Chat, instance: {:within_session, session_uri}}` |
| Section / Flow / Skill / KB 编辑操作 | CR Kind 的对应 action cap：`%Capability{kind: AutoServiceCR, behavior: AutoService.Behavior.CRPublish, instance: {:within_workspace, ws_uri}}` |
| Publish 红色二次确认通过 | **不**是 cap—— UX 层确认，不进 dispatch；cap 只管 "能不能 publish"。"是否需要二次确认" 是 LV 自己的事 |

**关键**：cap-check 只在 dispatch 5.5 chokepoint 发生（anti-pattern "cap-check inside LV"）。AutoService 当前 router-level 鉴权 → 迁移后由 ezagent dispatch 自动 + LV 端只做"隐藏按钮的 defense in depth"（用 `holds_cap?/2` 查询，不作为 source of authority）。

**master_admin 是 `system://`-scoped principal**：是的，且是 `workspace://system` 成员。**不要** 给 master_admin 发 `:any` cap，那是 anti-pattern。

---

## 6. lead / output directive → ExternalMirror Domain

AutoService 的 `[线索]` SIDE-channel directive（LLM 输出 → lead_store aggregator → `<known_facts>` 注入）+ `autoservice/output_directives/` registry（集中注册 `[标签]` / `<标签/>`）—— 这是 **典型的 outbound mirror 场景**：Session 的 chat slice 有 lead 字段更新 → 必须同步到外部 lead CRM 系统。

**不变式 #15 + anti-pattern "duplicate Feishu one-off outbound"** 直接命中。lead 同步 **必须**通过 ExternalMirror Domain：

- `Ezagent.ExternalMirror.Adapter.AutoServiceLeadCRM`（无状态 — `event_to_payload/1` pure，`target_ownership_check/2` 校验 lead 归属 workspace，`cap_subject/0` 是 lead 写权限）
- `Ezagent.ExternalMirror.Binding.AutoServiceLeadCRM`（per-target GenServer — `publish/2` 调 CRM API，`init/1` 校验 API key）
- plugin module 声明 `adapters/0` 返回 `[{AutoServiceLeadCRM.Adapter, AutoServiceLeadCRM.Binding}]`

**直接收益**：per-binding crash isolation（一个 lead 同步失败不会拖垮其他租户）、FacadeNonceTable 转发保护、两级监督树、eager spawn + restart adoption、rehydration —— **全部白送**。AutoService 当前 lead_store aggregator 是同步路径里的 best-effort 写，没有这些保证。

**output_directives registry 留在 plugin 内部**：它解析 LLM 文本输出里的 `[线索]` 标签，是 cc adapter 的 parser，跟 ezagent dispatch 无关。**不要** 把它做成 Behavior——它没有 cross-Kind dispatch 需求。`<handoff/>` 则不同：handoff 是 Session 状态变更（agent 转人），应该 dispatch `session://...?action=handoff`，由 Behavior 处理（这是 P14 的应用场景）。

**wire 契约**：lead summary 作为 Session 的 chat slice 一个字段（`lead_fields: %{name, phone, intent, ...}`），ExternalMirror Adapter 的 `event_to_payload/1` 把它序列化为 CRM JSON。**不**是单独的 Resource Kind——lead 是 session 的属性，不是 cross-session shared referent。

---

## 7. 业务侧迁移风险与遗弃物清单

**直接遗弃（不带进 ezagent）**：

1. `runtime/sandbox/<tid>/`、`.autoservice/sandbox/<tid>/`、`.autoservice/released/<tid>/v<N>/`、`.autoservice/current/`、`plugins/<tid>/skills/`（autoservice-overview §3.3 + 附录 A）
2. `PLACEHOLDER_ENABLED` / `SOOTHE_PLACEHOLDER_ENABLED`
3. `sandbox_locks` 表、`autoservice/sandbox_snapshot.py` 整模块（cr-lifecycle-redesign §4.3 已废）
4. `CRSource.DOCS_REGEN` + 三层 fork 架构所有残留
5. Feishu legacy 通道（legacy 停止同步）—— ezagent 已经有 ezagent_plugin_feishu 用 ExternalMirror 重做，没有迁移价值
6. `autoservice/storage/canonical_hash.py` —— SessionTemplate `@<hash>` 内置内容寻址
7. `autoservice/storage/snapshot.py` —— ezagent `kind_snapshots` 表 + Persistence 层替代

**业务侧迁移风险**（按严重度排）：

1. **HIGH — Workspace cap 形状扩展**：`{:within_workspace, _}` 不在当前 ezagent capability 形状里（只有 `{:within_session, _}` / `{:spawned_by, _}`）。tenant_admin 权限语义无法表达。**必须先在 ezagent 立项 brainstorm + 加 P15 不变式测试再开始迁移**——否则 admin portal 第一天就要绕过 cap，触发 anti-pattern。
2. **HIGH — 4 层 priority lint 缺失**：AutoService `master/priority.yaml` + lint（soul-layer-redesign §2.3）防 L3 越权改 L1 域规则。ezagent Template Class 当前无声明式 cross-layer lint hook。需要新增。
3. **MEDIUM — 通道术语漂移**：AutoService 的 "channel" vs ezagent 的 CC Channel vs Phoenix.Channel 三重同名。代码迁移中应在 plugin 命名上消歧（如 `ezagent_plugin_autoservice_voice_transport`）。
4. **MEDIUM — Pipeline v2 fast+cc 编排**：fast_phase（deepseek 30 字内安抚）+ cc_phase（FillerLoop + cc 主循环 + 45s 硬超时）的 **编排是 LLM-driven orchestrator**（anti-pattern "make orchestrator deterministic — write in Elixir" 明确禁止用 Elixir 写编排）。AutoService 当前 Python 里硬编码——迁过去要重新建模为 orchestrator Template Class 的 LLM tool calls。这是最大业务行为变化点，需要单独 phase。
5. **MEDIUM — voice 通道不能套 Pipeline v2**（`PIPELINE_V2_CHANNELS` 默认排除 voice）—— voice 在 ezagent 里需要独立的 agent flavor（不复用 cc orchestrator），或者用 ExternalMirror 把 ASR/TTS 设为外部 SFU（ROADMAP §9c 已确认 media bytes 走外部 SFU，不进 ezagent dispatch）。
6. **LOW — skill lazy-load 是 cc 内部行为**：通过 `--mcp-config` per-agent cwd `.mcp.json` 已经支持（commit 18099a7），SKILL.md 文件物理位置走 SessionTemplate 的 `working_directory`，skill loader 不进 ezagent dispatch path。这一侧迁移最干净。
7. **LOW — Dream / 半自动改进**：当前是 admin portal 一个独立子系统，本质是后台 batch agent。迁过去就是另一个 agent flavor（如 `entity://agent/<ws>/dream_<role>`）+ 自己的 Behavior。无架构难点。

**整体判断**：AutoService 业务模型迁到 ezagent **总体可行且会变得更干净**——CR / snapshot / per-tenant 隔离这三块都能用 ezagent 核心原语替换掉自己造的轮子（P8 收益最大点）。但有 2 个 **HIGH 风险** 必须先在 ezagent 侧立项解决（workspace cap shape、cross-layer lint）才能开始业务迁移，否则会触发不变式违反。

---

## 参考文件路径

- `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\autoservice-overview.md`
- `D:\Work\h2os.cloud\AutoService-dev-a\autoservice\storage\address.py`、`resolver.py`、`unit.py`
- `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\soul-layer-redesign-2026-05-19.md`
- `D:\Work\h2os.cloud\AutoService-dev-a\docs\architecture\skill-extraction-phase-e-2026-05-20.md`
- `D:\Work\h2os.cloud\AutoService-dev-a\docs\superpowers\specs\2026-05-25-cr-lifecycle-redesign-design.md`
- `d:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\design-principles.md`（P1-P27）
- `d:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\architecture-invariants.md`（17 不变式）
- `d:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\three-tier-structure.md`
- `d:\Work\h2os.cloud\ezagent\.claude\skills\ezagent-developer\references\anti-patterns.md`
