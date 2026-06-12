# PR #731 vs autoservice-dev — 需求实现完成度对比

> 日期: 2026-06-12
> 基线需求: [`2026-06-10-autoservice-v2-design.md`](../specs/2026-06-10-autoservice-v2-design.md) (v3)

---

## 一、后端功能逐项对比

### 1.1 Customer 消息处理

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| 客户发送消息 | ✅ chat.send → Session | ✅ chat.send → Session | 相同 |
| 消息存储 | ✅ MessageStore | ✅ MessageStore | 相同 |
| 消息→agent 路由 | ✅ MentionRouting → CsOrchestrator.receive → fan-out | ✅ MentionRouting → fast+slow agent 直接 | PR 多一跳 |
| 路由规则安装 | ✅ Assembly 步骤 7 | ✅ CustomerSession.install_routing | 相同 |
| 路由规则作用域 | ✅ `{:in_session, session}` | ✅ `{:in_session, session} + {:from, customer}` | dev 更精确 |
| 客户消息回显 | ✅ optimistic echo + merge | ✅ optimistic echo + dedup | 相同 |

**完成度**: PR ✅ 100% | dev ✅ 100%

---

### 1.2 Fast Agent (DeepSeek ACK)

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Fast agent 创建 | ✅ add_template curl.agent | ✅ add_template curl.agent | 相同 |
| System prompt 来源 | ✅ TenantContent.provision_context(tid, "fast") | ✅ load_fast_prompt(tid) — release config | 相同 |
| Model/endpoint 配置 | ✅ agents.yaml → template_data 流入 | ✅ @agents_config 模块属性缓存 | PR 更灵活 |
| API key 注入 | ✅ `$DEEPSEEK_API_KEY` env → api_keys.put_api_key | ✅ `opts[:deepseek_key]` 参数 → identity.put_api_key | PR 更安全 |
| Fast reply 投递 | ✅ Turn.compose → Turn.settle → customer_visible | ✅ chat.send → PubSub → CustomerLive | PR 走 Turn 生命周期 |
| Fast reply 时效 | ✅ 独立 quick turn (< 2s) | ✅ 自然到达（先于 slow） | 相同效果 |

**完成度**: PR ✅ 100% | dev ✅ 100%

---

### 1.3 Slow Agent (Claude Code)

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Slow agent 创建 | ✅ create_agent cc flavor | ✅ create_agent cc flavor | 相同 |
| Work dir | ✅ materialize via TenantPaths | ✅ materialize via TenantRuntime | 相同 |
| CLAUDE.md 渲染 | ✅ TenantContent.provision_context(tid, "slow") → preamble+soul+skill_index | ✅ SoulRenderer.full_claude_md + skill_index | 相同 |
| MCP 配置 | ✅ .mcp.json with <tid>-kb | ✅ KbMcpProvider.config → .mcp.json merge | 相同 |
| KB symlink | ✅ kb.db symlink to release | ✅ kb.db symlink to release | 相同 |
| Skills symlink | ✅ via TenantPaths | ✅ via TenantRuntime.materialize | 相同 |
| Slow reply 投递 | ✅ Turn.compose → Turn.settle → customer_visible | ✅ chat.send → PubSub → CustomerLive | PR 走 Turn，dev 走 chat |
| Slow agent 模型可配 | ✅ agents.yaml → template_data | ❌ agents.yaml 只读，不传入 create_agent | **PR 优** |

**完成度**: PR ✅ 100% | dev ⚠️ 90% (model config 不流入 create_agent)

---

### 1.4 Biphasic 双相模式

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Fast ACK 独立 turn | ✅ orchestrator 分派 fast_cmd + slow_cmd，各自独立 turn | ❌ fast/slow 独立 MentionRouting 分发，无 turn 概念 | PR 显式建模 |
| Fast/slow 不互相等待 | ✅ dispatch_after_commit 并行 | ✅ MentionRouting 并行分发 | 相同效果 |
| Slow 超时处理 | ❌ 无（设计文档中有，代码未实现） | ⚠️ FillerLoop stub（未完成） | 都未完成 |

**完成度**: PR ⚠️ 80% (显式但缺超时) | dev ⚠️ 60% (隐式，FillerLoop stub)

---

### 1.5 Operator 接管

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| 接管触发 | ✅ OperatorLive → orchestrator.operator_claim | ✅ OperatorLive → TurnAdapter.claim + RuleStore.disable | — |
| Turn 生命周期 | ✅ cancel bot turn → open → compose → claim | ❌ synthetic turn_id → claim 不生效 | **PR 优，dev 有 bug** |
| Visibility 门控 | ✅ operator_only (claim) → customer_visible (settle) | ❌ 不生效（synthetic turn_id） | **PR 优** |
| Operator 编辑 | ✅ compose 到 turn | ⚠️ chat.send（不走 Turn） | **PR 优** |
| 接管提交 | ✅ orchestrator.operator_settle → settle | ✅ TurnAdapter.settle (synthetic turn_id) + RuleStore.enable | PR 走 Turn，dev 无效 |
| 接管后 AI 暂停 | ✅ operator_active flag → fan-out 抑制 | ✅ RuleStore.disable | PR 更精细 |
| 接管后恢复 | ✅ operator_active=false → fan-out 恢复 | ✅ RuleStore.enable | — |
| Proactive 接管 (无 bot turn) | ✅ nil open_turn_id → open fresh | ⚠️ 不管 bot turn 状态 | PR 更健壮 |
| Operator 取消接管 | ❌ 无 | ❌ 无 | 都未实现 |

**完成度**: PR ✅ 95% | dev ❌ 40% (核心 Turn 门控不生效)

---

### 1.6 CustomerFeed 门控

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Customer 订阅 | ✅ CustomerFeed.topic → :customer_delivery | ✅ CustomerFeed.topic → :customer_delivery | 相同 |
| Bot 回复门控 | ✅ Turn.settle 后投递 | ❌ chat.send 直接投递（无 Turn） | PR 优 |
| Operator 草稿门控 | ✅ Turn.claim → operator_only → customer 不可见 | ❌ 门控不生效 | **PR 优** |
| Operator 提交门控 | ✅ Turn.settle → customer_visible | ❌ 门控不生效 | **PR 优** |
| 消息去重 | ✅ ChatUI.row id 去重 | ✅ ChatUI.row id 去重 | 相同 |

**完成度**: PR ✅ 100% | dev ⚠️ 50% (bot 回复无门控，operator 门控不生效)

---

### 1.7 Turn 生命周期 (socialware Turn Behavior)

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Turn.open | ✅ 每次 customer msg / operator takeover | ⚠️ 仅 operator takeover（synthetic） | PR 完整 |
| Turn.compose | ✅ bot reply + operator reply | ⚠️ 仅 operator takeover（synthetic） | PR 完整 |
| Turn.settle | ✅ compose 后立即 settle | ⚠️ 仅 operator takeover（synthetic） | PR 完整 |
| Turn.claim | ✅ operator takeover 时 | ⚠️ synthetic turn_id | PR 正确 |
| Turn.cancel | ✅ operator takeover 时 cancel bot turn | ❌ 无 | **PR 独有** |
| Turn 状态追踪 | ✅ orchestrator slice: open_turn_id | ❌ 无状态追踪 | **PR 独有** |

**完成度**: PR ✅ 100% | dev ⚠️ 30% (Turn 仅在 operator 路径使用，且不生效)

---

### 1.8 Content Plugin

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Soul 模板加载 | ✅ TenantContent.provision_context | ✅ SoulLoader (4 层: framework/platform/industry/tenant) | **dev 优** |
| Soul 渲染 ({{key}}) | ✅ SoulRenderer.render/2 | ✅ SoulRenderer.render/2 + full_claude_md/3 | dev 多了 preamble |
| Soul 存储 (slot_values) | ❌ 无独立 Store | ✅ SoulStore + SoulSlotParser | **dev 优** |
| Skill 扫描/索引 | ✅ SkillIndexer.build/2 | ✅ SkillIndexer + SkillLoader + SkillStore | **dev 优** |
| Skill CRUD | ❌ 无 | ✅ SkillStore.write/delete | **dev 优** |
| KB CRUD | ❌ 无 | ✅ KbStore.upsert/delete | **dev 独有** |
| KB 重建 | ❌ 无 | ✅ KbRebuilder | **dev 独有** |
| KB MCP 配置 | ❌ 静态 kb_search_mcp.py | ✅ KbMcpProvider.config/2 | dev 参数化 |
| Agent 配置 (agents.yaml) | ✅ AgentsConfig.load/0 + for_role/1 | ⚠️ @agents_config 模块属性 | PR 更安全(no-raise) |
| 平台级 soul/skill | ❌ 无 | ✅ PlatformSoulStore + PlatformSkillStore | **dev 独有** |
| Tenant 路径管理 | ✅ TenantPaths (sandbox/release/_current) | ✅ TenantRuntime (更完整: materialize) | dev 更完整 |
| Tenant provision | ❌ 无独立模块 | ✅ TenantProvisioner.create_tenant/3 | **dev 独有** |
| Tenant config | ❌ 无 | ✅ TenantConfig (ConfigStore) | **dev 独有** |
| Behavior (CapBAC 门控) | ❌ 无 | ✅ ContentAdmin (Workspace) + TenantAdmin (System) | **dev 独有** |

**完成度**: PR ⚠️ 40% (只读渲染，无 CRUD/Platform/Behavior) | dev ✅ 90%

---

### 1.9 CR Plugin

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| CR 创建 | ✅ CrStore.ensure_active_cr | ✅ CrEngine.ensure_active_cr | 相同 |
| CR 发布 | ✅ Publisher.publish (lint→version→cp_r→flip→mark) | ✅ CrEngine.publish (lint→snapshot→update_current) | — |
| 发布顺序 | ✅ **mark-before-flip** | ❌ snapshot→update_current (无保护) | **PR 优** |
| 崩溃恢复 | ✅ repair_current/1 | ❌ 无 | **PR 独有** |
| 租户初始化 | ✅ init_tenant/2 (幂等, half-init 恢复) | ⚠️ TenantProvisioner.create_tenant (无 half-init 恢复) | PR 更健壮 |
| Lint 检查 | ⚠️ R01, R03 (较少) | ✅ R01-R05 (更全面) | dev 更全面 |
| Lint 跨命名空间 | ✅ cross-ns warning (不阻塞) | ❌ 无此处理 | PR 更友好 |
| Rollback | ✅ rollback/3 | ✅ CrRollback | 相同 |
| Snapshot | ✅ allocate_version + cp_r | ✅ CrSnapshot.snapshot | 相同 |
| Sandbox/Release 双区 | ✅ | ✅ | 相同 |

**完成度**: PR ⚠️ 85% (lint 覆盖少) | dev ⚠️ 80% (缺崩溃恢复)

---

### 1.10 多租户

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| 多租户创建 | ✅ Assembly.provision_session (参数化 tid) | ✅ CustomerSession.provision (参数化 tid) | 相同 |
| URI 命名空间隔离 | ✅ entity://<ws>/user/<name> | ✅ entity://<ws>/user/<name> | 相同 |
| Session 隔离 | ✅ session://<ws>/cs/<name> | ✅ session://<ws>/cs/<name> | 相同 |
| 消息跨租户隔离 | ✅ 验证通过 (multitenant_test) | ❌ 未测试 | PR 已验证 |
| 路由规则隔离 | ✅ per-session {:in_session, session} | ✅ per-session {:in_session, session} + {:from, customer} | 相同 |
| CapBAC 隔离 | ✅ per-workspace cap scoping | ✅ per-workspace cap scoping | 相同 |
| 多租户测试 | ✅ multitenant_test.exs (cinnox+acme) | ❌ 无 | **PR 独有** |

**完成度**: PR ✅ 100% (已验证) | dev ⚠️ 80% (实现正确但未验证)

---

### 1.11 CapBAC 角色

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Master Admin | ✅ Roles.bundle(:master_admin) | ✅ Roles.bundle(:master_admin) | 相同 |
| Tenant Admin | ✅ Roles.bundle(:tenant_admin) | ✅ Roles.bundle(:admin) | 命名不同 |
| Operator | ✅ 5 caps (含 cs_orchestrator 扩展) | ✅ 3 caps (session:join/send/receive) | PR 更多 |
| Customer | ✅ session:send/receive | ✅ session:send/receive | 相同 |
| 角色授予 | ✅ Assembly.ensure_admin/operator | ✅ seed_role_user | 相同 |
| CapBAC 测试 | ✅ roles_test.exs | ✅ 无 roles 专项测试 | PR 更完整 |

**完成度**: PR ✅ 100% | dev ✅ 90%

---

### 1.12 内容热更新 (CR Publish → Agent Refresh)

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Publish 后 CLAUDE.md 重写 | ✅ Assembly.Refresh.refresh_agents | ❌ 无 | **PR 独有** |
| Fast agent prompt 热更新 | ✅ curl_agent.configure dispatch | ❌ 无 | **PR 独有** |
| Slow agent PTY respawn | ❌ 已删除 (SnapshotStore §11 违规) | ❌ 无 | 都无 |
| Publish+refresh 测试 | ✅ publish_refresh_test.exs | ❌ 无 | **PR 独有** |

**完成度**: PR ✅ 85% (文件级 refresh，无 PTY respawn) | dev ❌ 0%

---

### 1.13 跨 VM 重启

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Fast agent 恢复 | ✅ Workspace.Loader 自动 | ✅ Workspace.Loader 自动 | 相同 |
| Slow agent 恢复 | ✅ Workspace.Loader 自动 | ✅ Workspace.Loader 自动 | 相同 |
| Session 恢复 | ✅ SpawnRegistry.spawn | ✅ SpawnRegistry.spawn | 相同 |
| Orchestrator 恢复 | ⚠️ after_boot 手动重 hydrated flavor cache | N/A | PR 有额外负担 |
| Routing 规则恢复 | ✅ RuleStore.load_into_registry | ✅ RuleStore.load_into_registry | 相同 |
| 消息历史恢复 | ✅ MessageStore (DB) | ✅ MessageStore (DB) | 相同 |

**完成度**: PR ⚠️ 85% (after_boot hack) | dev ✅ 100% (无额外负担)

---

## 二、UI 功能逐项对比

### 2.1 Customer 界面 (`/autoservice`)

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| 页面渲染 | ✅ CustomerLive | ✅ CustomerLive | 相同 |
| Session 自动加入 | ✅ Assembly.ensure_joined | ✅ CustomerSession.ensure_joined | 相同 |
| 消息列表 | ✅ ChatUI.message_list + 空态提示 | ✅ ChatUI.message_list + 空态提示 | 相同 |
| 消息气泡样式 | ✅ 我 / AI 客服 / 人工客服 (三色) | ✅ 我 / AI 客服 / 人工客服 (三色) | 相同 |
| Dark mode | ❓ 未知 | ✅ dark: 变体 | dev 更完整 |
| 消息输入框 | ✅ ChatUI.composer | ✅ ChatUI.composer | 相同 |
| 乐观回显 | ✅ 发送后立即 append | ✅ 发送后立即 append + dedup | 相同 |
| Session 未就绪提示 | ❓ 未知 | ✅ "暂时无法进入会话" 错误提示 | dev 更友好 |

**完成度**: PR ⚠️ 90% | dev ✅ 95%

---

### 2.2 Operator 界面 (`/autoservice/operator`)

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| Session 列表 | ✅ 侧栏，live + dormant | ✅ 侧栏，live + dormant | 相同 |
| Session 过滤 | ✅ /cs/ path segment | ✅ /cs/ path segment | 相同 |
| Session 选择 | ✅ 点击进入 | ✅ 点击进入 + 高亮 | 相同 |
| 消息加载 | ✅ CustomerFeed + MessageStore | ✅ Chat.session_events_topic + MessageStore | PR 走 Feed |
| 接管按钮 | ✅ "接管" → orchestrator.operator_claim | ✅ "接管对话" → TurnAdapter.claim + RuleStore.disable | PR 正确 |
| 接管状态 UI | ✅ operator_active flag + "已接管" 状态 | ✅ claimed flag + "🔒 已接管" 提示 | 相同 |
| 接管后输入 | ✅ compose 到 turn | ⚠️ chat.send（不走 Turn） | PR 正确 |
| 提交按钮 | ✅ "提交" → orchestrator.operator_settle | ✅ "结束人工对话" → TurnAdapter.settle + RuleStore.enable | PR 正确 |
| 接管时消息刷新 | ✅ CustomerFeed.topic 订阅 | ✅ CustomerFeed.topic 订阅 | 相同 |
| Proactive 接管 | ✅ nil turn_id → 允许接管 | ❌ turn_id 为空时 disabled | **PR 优** |
| Session rehydrate | ✅ Assembly.ensure_socialware_session (SocialwareSession Kind) | ⚠️ SpawnRegistry.spawn (可能 rehydrate 为普通 Session) | **PR 优** |

**完成度**: PR ✅ 95% | dev ⚠️ 60% (接管 bug + rehydrate 风险)

---

### 2.3 Admin 界面

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| **Tenant Admin** | ✅ TenantAdminLive (`/autoservice/admin`) | ❌ 无 | **PR 独有** |
| Soul 编辑面板 | ✅ textarea for sandbox/souls/customer.md | ❌ 无 | **PR 独有** |
| Slots 编辑面板 | ✅ textarea + YAML 校验 + 保存 | ❌ 无 | **PR 独有** |
| CR 面板 | ✅ 版本 + lint 结果 + [发布] 按钮 | ❌ 无 | **PR 独有** |
| Skills 列表 | ✅ 只读列表 | ❌ 无 | **PR 独有** |
| 预览渲染 | ✅ [预览渲染] → provision_context(sandbox) → <pre> | ❌ 无 | **PR 独有** |
| Cap 门控 | ✅ can_write? → 只读模式 | ❌ 无 | **PR 独有** |
| **Master Admin** | ❌ 无 | ❌ 无 (设计中有，未实现) | 都无 |
| **Tenant Dashboard** | ❌ 无 | ❌ 无 (设计中有，未实现) | 都无 |

**完成度**: PR ✅ 85% (TenantAdminLive 完整) | dev ❌ 0%

---

### 2.4 页面路由

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| `/autoservice` | ✅ CustomerLive | ✅ CustomerLive | 相同 |
| `/autoservice/operator` | ✅ OperatorLive | ✅ OperatorLive | 相同 |
| `/autoservice/admin` | ✅ TenantAdminLive | ❌ 无 | **PR 独有** |
| `/admin/*` (Master/Tenant dashboard) | ❌ 无 | ❌ 无 | 都未实现 |
| `/login` | ❓ 未知 | ✅ DevAutoLogin (开发用) | — |

**完成度**: PR ✅ 85% | dev ✅ 70%

---

### 2.5 共享 UI 组件 (ChatUI)

| 子需求 | PR #731 | autoservice-dev | 差距 |
|---|---|---|---|
| 消息气泡 | ✅ 三色 (我/AI/人工) | ✅ 三色 (我/AI/人工) | 相同 |
| 发送者标签 | ✅ label_for (URI type 判断) | ✅ label_for (URI type 判断) | 相同 |
| 输入框 | ✅ composer component | ✅ composer component | 相同 |
| 空态提示 | ✅ empty_hint | ✅ empty_hint | 相同 |
| Dark mode | ❓ 未知 | ✅ dark: 变体 | dev 更完整 |
| 响应式 | ❓ 未知 | ✅ max-w-2xl, flex | — |

**完成度**: PR ⚠️ 90% | dev ✅ 95%

---

## 三、总体完成度矩阵

| 功能模块 | PR #731 | autoservice-dev | 胜出 |
|---|---|---|---|
| **Customer 消息处理** | 100% | 100% | 持平 |
| **Fast Agent (DeepSeek)** | 100% | 100% | 持平 |
| **Slow Agent (CC)** | 100% | 90% | PR |
| **Biphasic 双相** | 80% | 60% | PR |
| **Operator 接管** | **95%** | **40%** | **PR** |
| **CustomerFeed 门控** | **100%** | **50%** | **PR** |
| **Turn 生命周期** | **100%** | **30%** | **PR** |
| **Content Plugin** | 40% | **90%** | **dev** |
| **CR Plugin** | 85% | 80% | 持平 |
| **多租户** | **100%** | 80% | PR |
| **CapBAC 角色** | 100% | 90% | 持平 |
| **内容热更新** | **85%** | **0%** | **PR** |
| **跨 VM 重启** | 85% | **100%** | dev |
| **Customer UI** | 90% | 95% | 持平 |
| **Operator UI** | **95%** | 60% | **PR** |
| **Admin UI** | **85%** | **0%** | **PR** |
| **共享 UI 组件** | 90% | 95% | 持平 |

### 加权总分

| | PR #731 | autoservice-dev |
|---|---|---|
| **后端功能 (13 项)** | **90%** | 70% |
| **UI 功能 (4 项)** | **91%** | 65% |
| **总体 (17 项)** | **90%** | 69% |

---

## 四、关键差距解读

### PR #731 明显优于 autoservice-dev 的 5 项

1. **Operator 接管 (95% vs 40%)** — dev 的 Turn visibility 门控不生效，这是功能性 bug
2. **CustomerFeed 门控 (100% vs 50%)** — dev 的 bot 回复不走 Turn，operator 门控失效
3. **Turn 生命周期 (100% vs 30%)** — dev 只在 operator 路径使用且不生效
4. **Admin UI (85% vs 0%)** — dev 完全没有 admin 管理界面
5. **内容热更新 (85% vs 0%)** — dev 无 CR publish → agent refresh 机制

### autoservice-dev 明显优于 PR #731 的 3 项

1. **Content Plugin (90% vs 40%)** — dev 有 Behavior 层、完整 CRUD Store、Platform 管理
2. **跨 VM 重启 (100% vs 85%)** — dev 无 orchestrator → 无 flavor cache 问题
3. **Dark mode / 边界 UI** — dev 更完整

### 结构性差异 (不是谁优谁劣，是不同选择)

- **编排模型**: PR 用 CsOrchestrator Kind (Turn 完整但架构重) vs dev 用 Session + MentionRouting (简单但 Turn 不完整)
- **Content Plugin 深度**: PR 薄 (~6 模块) vs dev 厚 (~18 模块 + Behavior)
- **LiveView 位置**: PR 在 autoservice plugin vs dev 在 liveview plugin

---

## 五、结论

**PR #731 整体完成度更高 (90% vs 69%)**，核心差距在: operator 接管正确性、Turn 生命周期完整性、Admin UI、内容热更新。这些是"能跑"和"跑对了"的区别。

**autoservice-dev 的优势在 content plugin 工程化**和架构简洁性，但 operator 接管有一个功能 bug 需要修复。

**推荐路径**: 保留 autoservice-dev 的架构骨架 + content plugin，从 PR #731 移植 operator 接管逻辑、Admin UI、CR 崩溃恢复、多租户测试、内容热更新。详见 [取舍分析](PR731-vs-autoservice-dev-取舍分析.md)。
