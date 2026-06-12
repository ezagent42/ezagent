# PR #731 vs autoservice-dev — 全量对比分析

> 分析时间: 2026-06-12
> PR: [#731](https://github.com/ezagent42/ezagent/pull/731) `feat/autoservice-phaseB-customer-path` (FatNine 团队)
> 本地分支: `autoservice-dev` (当前)
> 基线分支: `autoservice`

---

## 0. PR 描述 vs 实际内容

**PR 描述说**: "本 PR 不含实现代码"、"docs-only"、"Phase B customer 路径(loom-defer)"、"单租户 cinnox、customer-only"

**实际代码**: 36 个 commits，实现 autoservice v2 的**全量功能**:

| 实际包含 | PR 描述声称 |
|---|---|
| 3 个新/重写 plugin (content/cr/autoservice) | ❌ 描述说只有 docs |
| CustomerLive + OperatorLive + TenantAdminLive | ❌ 描述说 customer-only |
| 多租户隔离测试 (cinnox + acme) | ❌ 描述说单租户 |
| CapBAC 角色 (4 roles) | ❌ 描述说 customer-only |
| CR 发布 + refresh agents | ❌ 描述说 out-of-scope |
| Operator 接管 (cancel+reopen) | ❌ 描述说 out-of-scope |
| Live E2E 验证 (6 bugs fixed) | ❌ 描述说 docs-only |

**结论**: PR 描述严重不准确，实际是 autoservice v2 的**全量端到端实现**。

---

## 1. 顶层架构差异 (最关键)

### 1.1 编排模型: Lifecycle Kind vs Plain Session + RuleStore

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **编排者** | `CsOrchestrator` Lifecycle Kind | Plain `Session` Kind (Ezagent.Entity.Session) |
| **消息路径** | customer → MentionRouting → CsOrchestrator → fan-out fast+slow | customer → MentionRouting → fast+slow agents (直接) |
| **状态管理** | orchestrator 持有 `open_turn_id`, `operator_active` 等 | 无中心状态，Session 只管 chat 消息 |
| **Turn 驱动** | orchestrator 通过 `dispatch_after_commit` effects 驱动 Turn | TurnAdapter 直接 dispatch 到 Session 的 turn.* actions |
| **Agent 回复** | 子 agent reply → bridge 分发 `chat.send` → orchestrator 处理 | agent reply → MentionRouting → 直接进入 session chat |
| **双相(biphasic)** | ✅ Fast ACK 即时 turn + slow cc 主回复，orchestrator 协调 | ❌ 无显式 biphasic，greeting 在 seed 时 post，后续是普通 agent 回复 |

**这是最核心的差异**。PR #731 引入了专用 `CsOrchestrator` Kind 作为编排中枢，而 autoservice-dev 复用了平台的 Session + MentionRouting。

### 1.2 Operator 接管机制

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **接管方式** | orchestrator 的 `operator_claim` action，内部 cancel+reopen 模式 | `RuleStore.disable` 禁用路由规则 + `TurnAdapter.claim_turn` |
| **接管目标** | 通过 orchestrator，bot 的 in-flight turn 被 cancel 再 reopen | 禁用规则使 AI 不再回复，通过 TurnAdapter 操作 Session turn |
| **恢复方式** | `operator_settle` action，settle 后清 `operator_active` 标志 | `RuleStore.enable` 恢复规则 |
| **Operator 消息** | compose + claim (operator text → held `:operator_only` → settle 后 `:customer_visible`) | chat.send 直接作为 operator user 发送，不经过 turn 生命周期 |

PR 的接管更精细（cancel bot turn → reopen → compose operator text → claim → settle），但依赖 orchestrator Kind 存在。autoservice-dev 的实现更简单但 RuleStore enable/disable 是粗糙的开关。

---

## 2. Plugin 结构对比

### 2.1 ezagent_plugin_content

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **模块数** | ~6 (扁平结构) | ~18 (深层分层: behavior/ kb/ platform/ skill/ soul/ tenant/) |
| **核心入口** | `TenantContent.provision_context/3` | `TenantRuntime` + `SoulRenderer` + `SoulStore` + 各 Store 模块 |
| **Behavior** | 无 (纯函数库) | `ContentAdmin` (Lifecycle, 注册在 Workspace) + `TenantAdmin` (注册在 System) |
| **AgentsConfig** | `AgentsConfig.load/0` → `{:ok, map}`, `for_role/2` → `{:ok, map}` | 无独立模块，agents.yaml 在 `CustomerSession` 中 `@agents_config` 模块属性缓存 |
| **SoulRenderer** | `render/2` ({{key}} 替换) | `render/2` + `full_claude_md/3` (preamble + soul + skill_index) |
| **SkillIndexer** | `build/2` 扫描 SKILL.md, YAML frontmatter | `SkillIndexer` + `SkillLoader` + `SkillStore` 三层 |
| **TenantPath** | `TenantPaths` (sandbox/release/_current 解析) | `TenantRuntime` (更多: materialize, base_dir, sandbox/release/current paths) |
| **KB** | kb.db + kb_search_mcp.py 静态资产 | `KbStore` + `KbMcpProvider` + `KbRebuilder` (动态管理) |
| **额外能力** | 无 | `PlatformSkillStore` + `PlatformSoulStore` (平台级模板) |

**评估**: autoservice-dev 的 content plugin 更加工程化、分层清晰，引入了 Behavior 层使 admin 操作可通过 dispatch 调用（支持 CapBAC、审计、幂等）。PR 的版本更精简，是纯函数式工具库，但缺少 CapBAC 门控。

### 2.2 ezagent_plugin_cr

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **存储后端** | `CrStore` → `Ezagent.Socialware.ConfigStore` | `CrEngine` → `TenantConfig` (也是 ConfigStore) |
| **发布流程** | `Publisher.publish/2`: lint → ensure_active_cr → allocate_version → cp_r → flip_current → mark_published | `CrEngine.publish/1`: ensure_active_cr → CrLint.check → CrSnapshot.snapshot → update_current |
| **关键区别** | `mark_published` **在** `flip_current` **之前** (crash-after-mark 可恢复) | `update_current` 在 snapshot 之后 (无 mark-before-flip 保护) |
| **初始化** | `Publisher.init_tenant/2` (skeleton cp_r + publish as v1, idempotent) | 无 (tenant provisioning 在其他模块) |
| **Rollback** | `Publisher.rollback/3` (pointer move only) | `CrRollback` 模块 |
| **修复能力** | `Publisher.repair_current/1` (CR-says-published-vN / _current-lags 修复) | 无 |
| **Lint** | R01 placeholder warnings, R03 fatal missing-skill, cross-namespace warning | `CrLint.check/1` |

**评估**: PR 的 CR 发布更健壮（mark-before-flip 顺序、repair_current 自愈、init_tenant 幂等初始化）。autoservice-dev 的版本流程更简单但缺少 crash 恢复机制。

### 2.3 ezagent_plugin_autoservice

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **核心编排** | `CsOrchestrator` (Lifecycle Kind) + `TurnDriver` | `CustomerSession` (assembly) + `TurnAdapter` (invocation builder) |
| **Assembly** | `Assembly.provision_session/3` (8-step, content-fed, biphasic agents, orchestrator-routed) | `CustomerSession.provision/2` (direct Session + fast/slow agents, no orchestrator) |
| **Agent 配置** | Fast: `add_template` curl (config flows via template_data), Slow: cc with `work_dir` | Fast: `add_template` curl (module-attr cached agents.yaml), Slow: cc with materialized work_dir |
| **API Key** | 从 `$<PROVIDER>_API_KEY` env 读取，dispatch `api_keys.put_api_key` | 从 `opts[:deepseek_key]` 参数，dispatch `identity.put_api_key` |
| **FillerLoop** | 无 | ✅ `FillerLoop` (Task-based, 周期性安抚消息, Phase D, 当前 stub) |
| **LiveView** | CustomerLive + OperatorLive + TenantAdminLive **在 autoservice plugin 内** | CustomerLive + OperatorLive **在 ezagent_plugin_liveview 内** |
| **Router** | `/autoservice` + `/autoservice/operator` + `/autoservice/admin` | `/autoservice` + `/autoservice/operator` (无 admin) |
| **Seed task** | `mix ezagent.tenant.seed` (operator-facing, `ezagent.tenant.*`) | `mix ezagent.demo.seed_autoservice` (demo-only, `ezagent.demo.*`) |
| **Refresh** | `Assembly.Refresh.refresh_agents/1` (publish 后重写 CLAUDE.md, curl configure) | 无 |
| **after_boot** | ✅ Orchestrator flavor cache rehydration (跨 VM 重启存活) | ❌ 无 (不适用，因为没有 orchestrator Kind) |

**评估**: 
- PR 的 autoservice plugin 更"重"——引入了专用 Kind、更完整的 Assembly、Live E2E 验证过的代码路径
- autoservice-dev 更"轻"——复用平台 Session/MentionRouting、LiveView 分离到 liveview plugin
- PR 的 after_boot 修复了一个关键的跨 VM 问题（flavor cache 在重启后丢失）
- autoservice-dev 有 FillerLoop（PR 没有），但当前是 stub

---

## 3. 关键代码模式对比

### 3.1 Customer 消息处理

**PR #731** — CsOrchestrator Lifecycle Kind:
```elixir
# 1. customer sends message → MentionRouting → orchestrator.receive
# 2. orchestrator handle_receive:
#    - open turn via TurnDriver.open/3
#    - dispatch_after_commit to fast agent
#    - dispatch_after_commit to slow agent
# 3. fast agent reply → bridge → orchestrator.send → handle_fast_reply
#    - compose + settle on open_turn_id
# 4. slow agent reply → bridge → orchestrator.send → handle_slow_reply
#    - compose + settle on open_turn_id (nil-guard self-heal)
```

**autoservice-dev** — Plain Session + MentionRouting:
```elixir
# 1. customer sends message → CustomerLive → chat.send dispatch
# 2. Message → MentionRouting → fast agent (in_session + from matcher)
# 3. fast agent reply → chat.send → appears in session
#    (via CustomerFeed or chat_message PubSub → CustomerLive)
```

### 3.2 Turn 生命周期

**PR #731**: Turn 由 `TurnDriver` 驱动，dispatch 到 SocialwareSession 的 `turn.open/compose/settle/claim/cancel` actions。

**autoservice-dev**: Turn 由 `TurnAdapter` 构建 Invocation 并 dispatch，但 operator takeover 时不使用完整的 turn 生命周期（直接 chat.send）。

### 3.3 状态管理

**PR #731**: Orchestrator Kind 持有:
- `open_turn_id` — 当前活跃 turn
- `operator_active` — 是否被 operator 接管
- `customer_uri` / `session_uri` / `fast_uri` / `slow_uri` — 拓扑引用

**autoservice-dev**: 无集中状态。Session 只管理 chat 消息。CustomerSession 是无状态的 assembly 函数。

---

## 4. 测试覆盖对比

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **测试文件数** | 11 test files (autoservice) + 5 (content) + 7 (cr) = **23** | 4 (autoservice) + 18 (content) + 5 (cr) = **27** |
| **autoservice 测试** | cs_orchestrator_test (764行), operator_flow_test (438行), multitenant_test (377行), assembly_test (297行), roles_test (276行), turn_driver_test (148行), customer_live_test (121行), publish_refresh_test (117行) | autoservice_assembly_test, filler_loop_test, turn_adapter_test (较小) |
| **关键测试** | ✅ 多租户隔离测试 (cinnox+acme) | ❌ 无多租户测试 |
| | ✅ Operator 接管 e2e 测试 | ❌ 无 operator 接管 e2e 测试 |
| | ✅ Orchestrator 集成测试 (ghost fast/slow URIs) | ❌ 无 (无 orchestrator) |
| | ✅ Publish→refresh 集成测试 | ❌ 无 |
| | ✅ chat.send 回归测试 (bridge reply settling) | ✅ `:chat_message` PubSub 去重测试 |

---

## 5. 已知问题与修复 (PR #731 Live E2E 发现)

PR #731 经过 Live E2E 验证，发现并修复了 6 个关键 bug:

| # | Bug | 根因 | 修复 |
|---|---|---|---|
| 1 | **Orchestrator flavor cache 丢失** | `AgentFlavorAttributes` 是 ETS 非持久, 重启后 `flavor=none` → `no_such_actor` | `after_boot/0` 从 durable snapshot 重 hydrated |
| 2 | **Sub-agent reply 丢弃** | Bridge 用 `chat.send` 分发, orchestrator 只声明了 `:receive` | 添加 `:send` action 委托给 `handle_receive` |
| 3 | **操作员接管无效** | 多个问题: UI 禁用 + nil turn_id bail + session rehydrated 为错误 Kind + settle target 过时 | cancel+reopen 模式 + SocialwareSession ensure + orchestrator tracked turn |
| 4 | **Fast ACK 不执行** | Fast curl agent 缺少 api_key → `{:no_api_key, provider}` | Provision 时 dispatch `api_keys.put_api_key` from env |
| 5 | **操作员 session 列表为空** | 过滤器用 `session://cs/` PREFIX 但 URI 是 `session://<ws>/cs/<name>` | 改为过滤 `/cs/` path segment |
| 6 | **Ensure_customer 吞没创建失败** | `Users.create` 结果被丢弃, 后续操作无条件执行 | 用 `with :ok <- create_result` gate |

**这些 bug 揭示了 PR 方案的关键弱点**: orchestrator Kind 的生命周期管理（跨 VM 重启、agent flavor 注册、reply 消息路由）需要大量额外处理，而这些在 autoservice-dev 的 plain Session 方案中天然不存在。

---

## 6. 优劣势总结

### PR #731 (Orchestrator Kind 方案)

**优势**:
- ✅ 编排逻辑集中在 CsOrchestrator，职责清晰
- ✅ 双相(biphasic)支持：fast ACK + slow reply 显式建模
- ✅ Operator 接管精细（cancel bot turn → reopen → compose operator text）
- ✅ 经过 Live E2E 验证（6 bugs fixed, 真实 claude 2.1.169 测试）
- ✅ 多租户隔离验证通过
- ✅ CR 发布有 crash 恢复机制 (mark-before-flip + repair_current)
- ✅ 完整的 admin LiveView (soul/slots/CR/skills/preview)

**劣势**:
- ❌ 引入专用 Kind 增加复杂度（跨 VM 重启需要 after_boot rehydration hack）
- ❌ Agent reply 路由需要双 action (:receive + :send)，容易遗漏
- ❌ Content plugin 无 Behavior 层（无 CapBAC 门控）
- ❌ Content plugin 模块较少，缺少 KB/Platform 管理等能力
- ❌ 无 FillerLoop 等用户体验增强

### autoservice-dev (Plain Session + RuleStore 方案)

**优势**:
- ✅ 复用平台能力最大化（Session, MentionRouting, RuleStore）
- ✅ 无需专用 Kind → 无跨 VM 重启问题
- ✅ Content plugin 工程化程度高：Behavior 层、深层分层、Platform 管理
- ✅ CR plugin 结构清晰（Engine/Lint/Snapshot/Rollback 分离）
- ✅ 有 FillerLoop 设计（虽然当前 stub）
- ✅ Content plugin 有 Behavior（ContentAdmin/TenantAdmin），支持 CapBAC + 审计
- ✅ LiveView 在独立 plugin (ezagent_plugin_liveview)，关注点分离

**劣势**:
- ❌ 无显式编排层 → customer message → agents 的路径是隐式的(MentionRouting)
- ❌ Operator 接管通过 RuleStore enable/disable，粒度粗糙
- ❌ 无双相(biphasic)显式支持
- ❌ 无 Live E2E 验证记录（可能还有隐 bug）
- ❌ 无多租户隔离测试
- ❌ CR 发布流程缺少 crash 恢复保护
- ❌ 无 admin LiveView（无法在线编辑 soul/slots/CR）

---

## 7. 推荐融合方向

两个方案各有优劣,建议融合而非二选一:

### 从 PR #731 取:
1. **Orchestrator Kind** — 考虑引入但简化（例如 plain Session + Behavior 而非新 Kind type）
2. **Biphasic 模式** — fast ACK quick turn 的概念值得保留
3. **CR 发布 crash 恢复** — mark-before-flip + repair_current
4. **多租户隔离测试** — 直接移植 multitenant_test.exs
5. **Operator takeover cancel+reopen** — 比 RuleStore enable/disable 更精细
6. **Admin LiveView** — TenantAdminLive (soul/slots/CR/skills/preview)
7. **after_boot 通用化** — 向 Allen 提 framework-level 的 AgentFlavorAttributes 重 hydrated

### 从 autoservice-dev 保留:
1. **Content plugin Behavior 层** — ContentAdmin + TenantAdmin (CapBAC + 审计)
2. **Content plugin 深层分层** — kb/platform/skill/soul/tenant 结构
3. **FillerLoop** — 完善实现（需要真实 latency 数据后）
4. **LiveView 分离** — 保持在 ezagent_plugin_liveview
5. **TurnAdapter 作为 invocation builder** — 纯函数无状态，与 orchestrator 互补

### 需要讨论的架构问题:
1. **Orchestrator Kind 是必要的吗？** PR 方案解决了实际问题（编排显式化），但引入了跨 VM 重启的复杂性。autoservice-dev 方案更简单但编排是隐式的。是否需要中间方案（例如 Session + Behavior）？
2. **Content plugin 的 Behavior 是否应该保留？** PR 无 Behavior，autoservice-dev 有。Behavior 带来 CapBAC/审计/幂等，但也增加了复杂度。
3. **Seed task 命名** — `ezagent.tenant.*` vs `ezagent.demo.*`，取决于目标用户。

---

## 8. 文件级差异速查

### PR #731 有但 autoservice-dev 没有:
```
apps/ezagent_plugin_autoservice/lib/ezagent/behavior/cs_orchestrator.ex  (569 lines)
apps/ezagent_plugin_autoservice/lib/ezagent/entity/cs_orchestrator.ex     (44 lines)
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/admin/tenant_admin_live.ex (525 lines)
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/assembly/refresh.ex (195 lines)
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_live.ex (203 lines)
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/operator_live.ex (434 lines)
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/turn_driver.ex (138 lines)
apps/ezagent_plugin_autoservice/lib/mix/tasks/ezagent.tenant.seed.ex (227 lines)
apps/ezagent_plugin_autoservice/test/cs_orchestrator_test.exs (764 lines)
apps/ezagent_plugin_autoservice/test/operator_flow_test.exs (438 lines)
apps/ezagent_plugin_autoservice/test/multitenant_test.exs (377 lines)
apps/ezagent_plugin_autoservice/test/customer_live_test.exs (121 lines)
apps/ezagent_plugin_autoservice/test/publish_refresh_test.exs (117 lines)
apps/ezagent_plugin_content/lib/ezagent_plugin_content/agents_config.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/tenant_content.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/tenant_paths.ex
apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_store.ex
```

### autoservice-dev 有但 PR #731 没有:
```
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/filler_loop.ex
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/uris.ex
apps/ezagent_plugin_autoservice/lib/mix/tasks/ezagent.content.migrate_cinnox.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/behavior/content_admin.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/behavior/tenant_admin.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/kb_mcp_provider.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/kb_rebuilder.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/kb_store.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/platform/platform_skill_store.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/platform/platform_soul_store.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/skill/skill_loader.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/skill/skill_store.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/soul/soul_loader.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/soul/soul_slot_parser.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/soul/soul_store.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/tenant/tenant_config.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/tenant/tenant_provisioner.ex
apps/ezagent_plugin_content/lib/ezagent_plugin_content/tenant/tenant_runtime.ex
apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_engine.ex
apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_snapshot.ex
apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_rollback.ex
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/customer_live.ex
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/operator_live.ex
```

### 同名但不同实现的文件:
```
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/application.ex     (PR: 148 lines vs dev: 55 lines)
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/roles.ex           (PR: 234 lines vs dev: 130 lines)
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/chat_ui.ex         (PR: 95 lines vs dev: 99 lines)
apps/ezagent_plugin_content/lib/ezagent_plugin_content/application.ex            (PR: simpler vs dev: Behavior injection)
apps/ezagent_plugin_content/lib/ezagent_plugin_content/soul_renderer.ex          (PR: render/2 vs dev: render/2 + full_claude_md/3)
apps/ezagent_plugin_content/lib/ezagent_plugin_content/skill_indexer.ex          (PR: build/2 flat vs dev: with SkillLoader/Store)
apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/application.ex                      (PR: simpler vs dev: Supervisor)
```

---

## 9. 关键结论

1. **PR #731 是全量 v2 实现，不是 docs/design-only**。PR 描述需要更正。

2. **两个方案的核心分歧在编排层**: PR 引入专用 `CsOrchestrator` Lifecycle Kind，autoservice-dev 复用平台 Session + MentionRouting。这是后续融合决策的第一优先级。

3. **PR 经过了 Live E2E 验证**，暴露了 orchestrator 方案的 6 个关键 bug 并修复。autoservice-dev 还缺少这个级别的验证。

4. **autoservice-dev 的 content plugin 工程化程度更高**（Behavior 层、深层分层、Platform 管理），但缺少 Live E2E 打磨。

5. **两个方案的 CR plugin 发布流程都需要完善**：PR 的 mark-before-flip 更安全，autoservice-dev 的结构更清晰（Engine/Lint/Snapshot 分离）。

6. **融合 ≠ 简单 merge**。需要在以下问题上做架构决策：
   - 是否需要 `CsOrchestrator` Kind？
   - Content plugin 是否保留 Behavior 层？
   - LiveView 放在哪个 plugin？
   - CR 发布采用哪种流程？
