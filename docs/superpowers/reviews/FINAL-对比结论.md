# AutoService v2 双分支对比 — 最终结论

> 日期: 2026-06-12 | 基线需求: `2026-06-10-autoservice-v2-design.md` (v3)
> PR #731: `feat/autoservice-phaseB-customer-path` (FatNine 团队, 36 commits)
> autoservice-dev: 本地当前分支 (16 tasks, Phase A-D)

---

## 一、需求 vs 实现矩阵

按设计文档 v2 §1-§9 的功能需求逐项对比。

### §1-2: 总体架构 + Plugin 拆分

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| core/domain 零改动 | ✅ | ✅ | 持平 |
| content plugin (soul/skill/KB管理) | ✅ 18模块 + Behavior层 | ⚠️ ~6模块扁平，无Behavior | **dev 优** |
| cr plugin (发布流) | ✅ Engine/Lint/Snapshot 分离 | ✅ CrStore+Publisher+Lint | 持平 |
| autoservice plugin (容器外壳) | ✅ 精简，~8模块 | ⚠️ 较重，含 LiveView | dev 更纯粹 |
| liveview plugin (Admin UI) | ✅ 分离 | ❌ 混在 autoservice plugin | **dev 优** |

### §3: 数据架构 (Soul/Skill/KB)

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| Soul 4层加载 (L0-L3) | ✅ SoulLoader | ❌ 直接从 skeleton 读 | **dev 优** |
| Soul {{slot}} 渲染 | ✅ SoulRenderer + SoulSlotParser | ✅ SoulRenderer (基础) | dev 更完整 |
| Skill 4层扫描 | ✅ SkillLoader + SkillIndexer | ✅ SkillIndexer (基础) | dev 更完整 |
| Skill CRUD | ✅ SkillStore | ❌ 无 | **dev 独有** |
| KB CRUD | ✅ KbStore + KbRebuilder | ❌ 无 | **dev 独有** |
| KB MCP 配置 | ✅ KbMcpProvider (参数化) | ⚠️ 静态 script | dev 优 |
| Platform 模板 | ✅ PlatformSoulStore + PlatformSkillStore | ❌ 无 | **dev 独有** |
| Agent 配置 (agents.yaml) | ⚠️ @module_attr 缓存 | ✅ AgentsConfig (no-raise合约) | PR 合约更安全 |
| 租户路径管理 | ✅ TenantRuntime (sandbox/release/materialize) | ✅ TenantPaths (基础) | dev 更完整 |
| 租户初始化 | ✅ TenantProvisioner | ❌ 无独立模块 | **dev 独有** |

### §4: 用户管理与权限

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| 4 角色 CapBAC | ✅ Roles + ContentAdmin/TenantAdmin caps | ✅ Roles + cs_orchestrator caps | 持平 |
| Master Admin | ✅ workspace:* (跨租户) | ✅ workspace:* (跨租户) | 持平 |
| Tenant Admin | ✅ ContentAdmin caps (write_soul_slot等) | ✅ tenant_admin caps | 持平 |
| Operator | ✅ session:join/send/receive | ✅ session + cs_orchestrator caps | PR 多了编排权限 |
| Customer | ✅ session:send/receive | ✅ session:send/receive | 持平 |
| CapBAC 门控 (dispatch路径) | ✅ ContentAdmin Behavior (Lifecycle) | ❌ 无 Behavior 层 | **dev 优** |

### §5: CR 发布流

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| 全量发布 (sandbox→release) | ✅ CrEngine.publish | ✅ Publisher.publish | 持平 |
| Lint 检查 | ✅ R01-R05 (5条规则) | ⚠️ R01+R03 (2条规则) | dev 更全面 |
| 原子翻指针 | ✅ update_current (symlink) | ✅ flip_current (tmp+rename) | PR 更安全 |
| 崩溃恢复 | ❌ 无 | ✅ mark-before-flip + repair_current | **PR 优** |
| 租户初始化 (幂等) | ⚠️ TenantProvisioner (无 half-init恢复) | ✅ init_tenant (幂等+half-init恢复) | **PR 优** |
| Rollback | ✅ CrRollback | ✅ rollback/3 | 持平 |
| 跨命名空间 lint | ❌ 无 | ✅ cross-ns warning (不阻塞) | PR 更友好 |

### §6: Customer 路径

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| 客户发消息 | ✅ chat.send → Session → MentionRouting | ✅ chat.send → Session → orchestrator.receive | 相同效果 |
| Fast agent ACK | ✅ MentionRouting → curl.send → chat.send → PubSub | ✅ orchestrator → dispatch_after_commit → curl.send → Turn.compose/settle | PR 走 Turn 生命周期 |
| Slow agent 主回复 | ✅ MentionRouting → cc.send → chat.send → PubSub | ✅ orchestrator → dispatch_after_commit → cc.send → Turn.compose/settle | PR 走 Turn 生命周期 |
| Biphasic (fast ACK + slow reply) | ⚠️ 隐式 (fast/slow 独立路由) | ✅ 显式 (orchestrator 协调两个独立 turn) | PR 更清晰 |
| Turn 生命周期覆盖 | ❌ bot reply 不走 Turn (chat.send) | ✅ 所有消息经过 Turn (open→compose→settle) | **PR 优** |
| CustomerFeed 门控 | ⚠️ bot reply 走 chat_message(无门控) + 双订阅防御 | ✅ settle 后 :customer_delivery (全部门控) | **PR 优** |
| 客户消息乐观回显 | ✅ | ✅ | 持平 |
| Agent fan-out P22 合规 | ❌ MentionRouting 无 dispatch_after_commit | ✅ dispatch_after_commit (dead agent 不 abort) | **PR 优** |
| Agent reply 路由 | ✅ chat.send → PubSub (单一路径) | ⚠️ :receive + :send (双路径, 易遗漏) | dev 更简单 |
| Agent model 配置传递 | ❌ slow cc: create_agent 不传 model/endpoint | ✅ fast: add_template 传；slow: 文档记录 gap | PR 优于 dev |

### §7: Operator 接管

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| 接管触发 | ✅ "接管对话" 按钮 | ✅ "接管" → orchestrator.operator_claim | 持平 |
| Turn.claim (visibility gating) | ❌ **synthetic turn_id → 不生效** | ✅ cancel bot turn → open → compose → claim | **PR 优** |
| Operator 编辑 (compose) | ❌ 走 chat.send (普通消息) | ✅ TurnDriver.compose (写入 turn) | **PR 优** |
| Turn.settle (visibility 翻转) | ❌ synthetic turn_id → 不生效 | ✅ TurnDriver.settle → customer_visible | **PR 优** |
| AI 暂停机制 | ✅ RuleStore.disable | ✅ operator_active flag (抑制 fan-out) | PR 更精细 |
| Proactive 接管 (无bot turn) | ⚠️ 不管 bot 状态 | ✅ nil open_turn_id → open fresh | **PR 优** |
| Cancel bot in-flight turn | ❌ 无 | ✅ TurnDriver.cancel (保留 draft 可查) | **PR 独有** |
| Session rehydrate | ⚠️ SpawnRegistry.spawn (可能错 spawn 为 plain Session) | ✅ Assembly.ensure_socialware_session | **PR 优** |
| 接管状态 UI | ✅ claimed flag + "🔒 已接管" | ✅ operator_active + 状态提示 | 持平 |

### §8: Admin 界面

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| Operations Dashboard | ✅ MasterDashboard(196行)+TenantDashboard(231行) | ❓ 未知 | dev 有 |
| CR 管理 (Publish/Cancel) | ✅ CrDashboardLive(226行) — 真实实现 | ✅ TenantAdminLive 内嵌 CR 面板 | 持平 |
| Operator 管理 | ✅ OperatorsLive(262行) — Add 可用, Disable stub | ❓ 未知 | dev 有 |
| 创建租户 | ✅ TenantOnboardLive(327行) | ❓ 未知 | dev 有 |
| Soul 编辑 | ❌ 无 | ✅ textarea 编辑 sandbox/souls | **PR 独有** |
| Slots 编辑 (YAML) | ❌ 无 | ✅ textarea + YAML 校验 + 保存 | **PR 独有** |
| Skills 列表 | ❌ 无 | ✅ 只读列表 | **PR 独有** |
| Preview 渲染 | ❌ 无 | ✅ [预览渲染] → provision_context(sandbox) → `<pre>` | **PR 独有** |
| Cap 门控 (can_write?) | ❌ 无 | ✅ 只读 textareas + disabled 按钮 + 提示 | **PR 独有** |
| 路由 | ✅ 5 条 `/admin/autoservice/*` | ✅ 1 条 `/autoservice/admin` | dev 路由更多 |

### §9: 租户生命周期 + 非功能需求

| 需求 | dev 实现 | PR 实现 | 优劣 |
|---|---|---|---|
| 多租户创建 | ✅ 参数化 tid | ✅ 参数化 tid | 持平 |
| 多租户隔离验证 | ❌ 无测试 | ✅ multitenant_test (cinnox+acme) | **PR 优** |
| 跨 VM 重启 | ✅ 无需额外处理 | ⚠️ after_boot hack (flavor cache) | **dev 优** |
| 内容热更新 | ❌ 无 (只翻指针) | ✅ Assembly.Refresh (CLAUDE.md+curl) | **PR 优** |
| FillerLoop | ⚠️ stub (send_soothing 是 no-op) | ❌ 无 | dev 有概念但未实现 |
| Seed task | ⚠️ `@workspace_name "cinnox"` 硬编码 | ✅ `--tenant/--customer/--admin` 参数化 | **PR 优** |
| api_key 管理 | ⚠️ 参数传入 | ✅ `$PROVIDER_API_KEY` env | PR 更安全 |

---

## 二、方案优劣总评

### dev 方案优势 (架构层面)

| 优势 | 影响 |
|---|---|
| **无新 Kind 类型** — 复用 Session + MentionRouting | 零跨 VM 重启问题，零 flavor cache hack |
| **Content Plugin 工程化** — Behavior 层 + 18 模块 + 914 行测试 | CapBAC 门控、审计、幂等，admin 操作可 dispatch |
| **LiveView 分离** — 在 ezagent_plugin_liveview | 关注点分离，plugin 职责清晰 |
| **Admin Operations UI** — 5 个 LV 1242 行 | Dashboard/CR/Operators/Onboard 已可用 |
| **架构简洁** — 消息路径短 (customer → Session → MentionRouting → agent) | 易理解、易调试、易维护 |

### dev 方案劣势 (功能层面)

| 劣势 | 严重程度 | 证据 |
|---|---|---|
| **Operator 接管 Turn 门控不生效** | 🔴 功能bug | `operator_live.ex:102` `:erlang.unique_integer` |
| **Bot reply 不走 Turn 生命周期** | 🟡 设计缺失 | bot reply 走 `chat_message` PubSub，无 visibility gating |
| **Slow agent model config 不传入** | 🟡 功能gap | `customer_session.ex:337` create_agent 缺 model/endpoint |
| **无内容热更新** | 🟡 功能gap | `cr_engine.ex:30-43` publish 只翻指针 |
| **无 Content Admin UI** | 🟡 功能gap | 无 soul/slots/skills 编辑界面 |
| **测试覆盖薄弱** | 🟡 质量gap | autoservice 仅 131 行测试 vs PR 2538 行 |
| **Seed task 硬编码 cinnox** | 🟢 开发体验 | `@workspace_name "cinnox"` |

### PR 方案优势 (功能层面)

| 优势 | 影响 |
|---|---|
| **Operator 接管正确** — cancel+reopen + Turn 生命周期 | 核心功能正确，visibility gating 生效 |
| **Turn 生命周期全覆盖** — 所有消息经过 Turn | CustomerFeed 门控统一，审计完整 |
| **dispatch_after_commit** — dead agent 不 abort | P22 合规，健壮性高 |
| **内容热更新** — Assembly.Refresh | CR publish 后 agent 自动更新 |
| **Content Admin UI** — soul/slots/skills/preview | Admin 可在线编辑内容 |
| **测试覆盖全面** — ~3672 行 | 多租户隔离、operator 接管 e2e、publish+refresh |
| **Live E2E 验证** — 6 bugs found & fixed | 真实验证过，可信度高 |

### PR 方案劣势 (架构层面)

| 劣势 | 严重程度 | 证据 |
|---|---|---|
| **CsOrchestrator Kind 过重** | 🟡 架构复杂度 | 新 Kind 类型，4进程/customer |
| **flavor cache 跨 VM 丢失** | 🔴 需 framework 修 | `after_boot/0` hack (commit `802132f`)，Allen 建议放 core |
| **Agent reply 双路径** | 🟡 易出错 | :receive + :send 两个 action，遗漏一个 → 静默丢消息 |
| **Content Plugin 无 Behavior** | 🟡 缺 CapBAC | admin 操作无法通过 dispatch 调用 |
| **无 Platform 层** | 🟢 缺跨租户模板 | 无法共享 soul/skill 模板 |
| **LiveView 混在 autoservice plugin** | 🟢 关注点混合 | 与 dev 的分离原则不一致 |

---

## 三、核心分歧: 编排模型

这是两个方案最根本的差异，决定了其他所有差异。

```
dev 方案:  Chat App 模型
  customer → chat.send → Session(存储) → MentionRouting → fast+slow agent
  agent reply → chat.send → PubSub → CustomerLive
  operator takeover → RuleStore.disable + chat.send
  特点: 消息驱动，Turn 可选

PR 方案:  Turn Orchestrator 模型
  customer → chat.send → Session(存储) → MentionRouting → orchestrator → Turn.open → fast+slow agent
  agent reply → bridge → orchestrator.send → Turn.compose → Turn.settle → customer_visible
  operator takeover → orchestrator.operator_claim → Turn.cancel → Turn.open → Turn.compose → Turn.claim
  特点: Turn 驱动，每个交互都是 Turn
```

**Trade-off**: Chat App 模型简单但 Turn 门控缺失；Turn Orchestrator 模型完整但架构重。

---

## 四、最终评分

| 需求领域 (权重) | dev | PR | 说明 |
|---|---|---|---|
| 架构设计 (20%) | **90** | 65 | dev 复用平台能力，PR 引入新 Kind |
| Customer 路径 (20%) | 70 | **95** | PR Turn 全覆盖 + biphasic + P22 |
| Operator 接管 (15%) | 20 | **95** | dev 核心功能 bug |
| Content Plugin (15%) | **90** | 40 | dev Behavior 层 + CRUD + Platform |
| CR Plugin (10%) | 80 | **85** | PR 崩溃恢复，dev lint 更全 |
| Admin UI (10%) | 60 | 70 | 互补：dev Operations，PR Content |
| 测试质量 (5%) | 20 | **95** | dev 131行 vs PR 3672行 |
| 运维健壮性 (5%) | **100** | 85 | dev 无跨 VM 问题 |
| **加权总分** | **66** | **79** | — |

---

## 五、结论

**PR #731 总分更高 (79 vs 66)**，因为它正确实现了 v2 最核心的两个需求——Customer 路径的 Turn 生命周期和 Operator 接管——而 dev 在这两项上分别有功能 bug 和设计缺失。

**但 PR 的架构方案 (CsOrchestrator Kind) 不是最优解**。dev 的 Chat App 模型 (Session + MentionRouting) 更简洁，只需要：

1. **修复 operator 接管** (从 PR 移植 cancel+reopen，最小修正方案)
2. **添加 Content Admin UI** (从 PR 移植 TenantAdminLive)
3. **添加内容热更新** (从 PR 移植 Assembly.Refresh)
4. **补充测试** (从 PR 移植 multitenant / operator_flow / publish_refresh)
5. **保持 dev 的所有优势**: content plugin Behavior 层、Admin Operations UI、跨 VM 简洁性

这样可以得到两个方案的优点：**dev 的架构简洁性 + PR 的功能完整性**。总分预估可以从 66 提升到 ~88。
