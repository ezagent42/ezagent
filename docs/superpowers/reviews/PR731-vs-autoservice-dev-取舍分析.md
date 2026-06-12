# PR #731 vs autoservice-dev — 优缺点与取舍

> 日期: 2026-06-12
> 配套: [PR731-vs-autoservice-dev-comparison.md](PR731-vs-autoservice-dev-comparison.md)
> 后续: [operator-takeover-fix-options.md](operator-takeover-fix-options.md)

---

## 一、总体评价

| | PR #731 (FatNine 团队) | autoservice-dev (本地) |
|---|---|---|
| **一句话** | 功能完整但架构偏重 — 引入专用 Kind，经过 Live E2E 打磨 | 架构简洁但细节粗糙 — 复用平台能力，operator 接管有 bug |
| **成熟度** | Live E2E 验证，6 bugs fixed，录屏证明可用 | 未做 Live E2E，operator takeover Turn 门控实际不生效 |
| **复杂度** | 高 — 3 个 plugin，CsOrchestrator Kind + TurnDriver | 中 — 3 个 plugin，无新 Kind，18 模块 content plugin |
| **可维护性** | 中 — 编排逻辑集中在 CsOrchestrator，但 flavor cache hack 脆弱 | 中高 — 架构简单但 Turn 使用不一致 |

---

## 二、分模块优缺点

### 2.1 编排层 (最核心的分歧)

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **方案** | CsOrchestrator Lifecycle Kind | Plain Session + MentionRouting |
| **customer → bot** | customer → MentionRouting → orchestrator.receive → open turn → fan-out | customer → chat.send → MentionRouting → fast+slow agent |
| **bot reply** | bridge → orchestrator.send → compose → settle → customer_visible | agent → chat.send → PubSub → CustomerLive |
| **operator 接管** | orchestrator.operator_claim → cancel bot turn → reopen → compose → claim | RuleStore.disable + synthetic turn_id.claim |
| **进程数** | Session + CsOrchestrator + fast + slow = 4 | Session + fast + slow = 3 |

**PR #731 优点**:
- ✅ Turn 生命周期完整覆盖所有消息 → CustomerFeed 门控统一
- ✅ cancel+reopen 接管模式精细
- ✅ `dispatch_after_commit`：dead agent 不 abort turn (P22)
- ✅ 状态可观测 (open_turn_id, operator_active)

**PR #731 缺点**:
- ❌ 新 Kind 类型 → flavor cache 跨 VM 重启丢失 (after_boot hack)
- ❌ Agent reply 双路径 (:receive + :send) → 易遗漏
- ❌ 跨 Kind Turn 协调可能不一致
- ❌ 多一个进程 per customer

**autoservice-dev 优点**:
- ✅ 简单 — 复用 Session + MentionRouting，无新抽象
- ✅ 无跨 VM 重启问题
- ✅ Agent reply 走标准 chat.send → PubSub，路径清晰
- ✅ 少一个进程

**autoservice-dev 缺点**:
- ❌ **Operator 接管 Turn 门控不生效** — synthetic turn_id 对应不到真实 Turn
- ❌ Bot 回复不走 Turn → 无 CustomerFeed gating（但 bot 不需要 draft）
- ❌ 无双相显式协调
- ❌ RuleStore.disable 粒度不够精细（虽每个 session 一个规则，但仍是全局开关思维）

**取舍**: ✅ **保留 autoservice-dev 架构** (Session + MentionRouting)，\+ 用 PR #731 的 cancel+reopen 思路做 operator 接管的最小修正（见 [operator-takeover-fix-options.md](operator-takeover-fix-options.md) 方案 A）。不引入 CsOrchestrator Kind 或 Behavior。

---

### 2.2 Content Plugin

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **模块数** | ~6 | ~18 |
| **分层** | 扁平 (全部在 lib/ 根) | 深层 (behavior/ kb/ platform/ skill/ soul/ tenant/) |
| **Behavior** | ❌ 无 | ✅ ContentAdmin (Lifecycle, 注册在 Workspace) + TenantAdmin (System) |
| **核心入口** | `TenantContent.provision_context/3` | `TenantRuntime.materialize/3` + `SoulRenderer.full_claude_md/3` |
| **AgentsConfig** | `AgentsConfig.load/0` → `{:ok, map}` | 无独立模块，在 `CustomerSession` 用 `@agents_config` 模块属性缓存 |
| **Soul 存储** | 无 SoulStore (直接从 skeleton 读文件) | SoulStore + SoulLoader + SoulSlotParser |
| **Skill 存储** | 无 SkillStore (SkillIndexer 直接扫描) | SkillStore + SkillLoader + SkillIndexer |
| **KB 管理** | 静态 kb.db + script | KbStore + KbMcpProvider + KbRebuilder (动态管理) |
| **Platform 层** | 无 | PlatformSoulStore + PlatformSkillStore |
| **Tenant 管理** | TenantPaths (路径解析) | TenantRuntime (完整 path 管理) + TenantConfig (ConfigStore) + TenantProvisioner |

**PR #731 优点**:
- ✅ 简单直接，够用（对 cinnox 单租户场景）
- ✅ `provision_context/3` 入口清晰
- ✅ `AgentsConfig.for_role/1` 返回 `{:ok, map}` — 不抛异常

**PR #731 缺点**:
- ❌ 无 Behavior 层 — admin 操作不能通过 dispatch 调用 → 无 CapBAC 门控、无审计
- ❌ 无 Skill/KB/Soul Store — 缺少 CRUD 抽象，调用方需要自己读文件
- ❌ 无 Platform 层 — 不能跨租户共享 soul/skill 模板
- ❌ 无 KbRebuilder — kb.db 重建逻辑不在 plugin 内

**autoservice-dev 优点**:
- ✅ Behavior 层 → CapBAC + 审计 + 幂等
- ✅ 完整 CRUD Store → 其他 plugin/LiveView 通过 dispatch 操作
- ✅ Platform 层 → 跨租户模板管理
- ✅ TenantRuntime 完整 (sandbox/release/materialize)
- ✅ KbRebuilder + KbMcpProvider

**autoservice-dev 缺点**:
- ❌ 可能过度分层 — 18 个模块对当前阶段偏多
- ❌ 部分 Store 模块是薄 wrapper（如 SkillStore 就是 File.read/File.write）

**取舍**: ✅ **完整保留 autoservice-dev 的 content plugin**。Behavior 层是 PR #731 最缺的能力。分层即使多，也是合理的关注点分离。PR #731 的 `AgentsConfig` 非异常合约 (`{:ok, map}` / `{:error, reason}`) 值得采纳。

---

### 2.3 CR Plugin

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **存储后端** | `CrStore` → `Ezagent.Socialware.ConfigStore` | `CrEngine` → `TenantConfig` (也是 ConfigStore) |
| **发布顺序** | mark_published **在** flip_current **之前** (crash 可恢复) | snapshot → update_current (无 crash 保护) |
| **自愈能力** | `repair_current/1` | 无 |
| **初始化** | `init_tenant/2` (skeleton → sandbox → publish v1) | `TenantProvisioner.create_tenant/3` |
| **Lint** | R01(placeholder), R03(missing-skill, cross-ns warning) | R01-R05 (更全面) |
| **Rollback** | `rollback/3` (pointer move) | `CrRollback` 模块 |
| **Snapshot** | `allocate_version` + `cp_r` + `flip_current` | `CrSnapshot.snapshot/1` |

**PR #731 优点**:
- ✅ **mark-before-flip 顺序** — crash 后可 repair
- ✅ `repair_current/1` — 检测 CR 状态与 \_current 指针不一致并修复
- ✅ `init_tenant/2` — 幂等初始化，half-init 可恢复
- ✅ 跨 namespace lint warning（而非 fatal error）

**PR #731 缺点**:
- ❌ Lint 规则覆盖少（只有 R01/R03）
- ❌ `CrStore` 直接依赖 `ConfigStore`（无中间层）

**autoservice-dev 优点**:
- ✅ 模块分离清晰 (Engine/Lint/Snapshot/Rollback)
- ✅ Lint 规则更全面 (R01-R05)
- ✅ 通过 `TenantConfig` 间接访问 ConfigStore

**autoservice-dev 缺点**:
- ❌ 无 crash 恢复 — publish 中途 crash 可能丢失状态
- ❌ 无 `repair_current`
- ❌ 无 `init_tenant`（在 TenantProvisioner 中，耦合不紧）

**取舍**: ✅ **保留 autoservice-dev 的模块结构** (Engine/Lint/Snapshot/Rollback)，\+ **采纳 PR #731 的发布流程** (mark-before-flip + repair_current + init_tenant 幂等初始化)。

---

### 2.4 Operator 接管

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **接管方式** | orchestrator.operator_claim → cancel bot turn → reopen → compose → claim | synthetic turn_id → TurnAdapter.claim → RuleStore.disable |
| **Turn 使用** | ✅ 真实 Turn (open → compose → claim → settle) | ❌ synthetic turn_id (Turn 不存在) |
| **恢复** | operator_settle → settle → operator_active=false | RuleStore.enable |
| **AI 暂停** | operator_active flag (抑制 fan-out) | RuleStore.disable (禁用整个规则) |

**PR #731 优点**:
- ✅ Turn visibility 门控**真正生效**
- ✅ cancel 保留 bot draft 可供 operator 查阅
- ✅ operator_active flag 精细控制

**autoservice-dev 问题**:
- ❌ synthetic turn_id (`:erlang.unique_integer`) → Turn.claim 找到不存在的 Turn → no-op
- ❌ Turn 的 visibility 门控**从未生效**
- ❌ operator 消息走 chat.send → 和 bot 回复无法区分

**取舍**: ✅ **采纳 PR #731 的 cancel+reopen 思路，做最小修正** (方案 A，见 [operator-takeover-fix-options.md](operator-takeover-fix-options.md))。不引入 Behavior，只修复 OperatorLive 的 Turn 用法。

---

### 2.5 LiveView

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **文件位置** | autoservice plugin 内 (`lib/ezagent_plugin_autoservice/`) | ezagent_plugin_liveview 内 (`lib/ezagent_plugin_liveview/autoservice/`) |
| **CustomerLive** | Feed-gated + optimistic echo + dedup | Feed-gated + optimistic echo + dedup (几乎相同) |
| **OperatorLive** | orchestrator-routed dispatch, proactive takeover, SocialwareSession ensure | TurnAdapter + RuleStore, synthetic turn_id |
| **AdminLive** | ✅ TenantAdminLive (soul/slots/CR/skills/preview) | ❌ 无 |
| **Router** | `/autoservice` + `/autoservice/operator` + `/autoservice/admin` | `/autoservice` + `/autoservice/operator` |

**PR #731 优点**:
- ✅ Admin LiveView 完整 (soul/slots 编辑 + CR 发布 + skills 列表 + inline 预览)
- ✅ OperatorLive 更健壮 (proactive takeover, SocialwareSession ensure, orchestrator-routed)
- ✅ Live E2E 验证过的 UI 交互

**PR #731 缺点**:
- ❌ LiveView 在 autoservice plugin 内 → 关注点混合

**autoservice-dev 优点**:
- ✅ LiveView 在独立 plugin → 关注点分离

**autoservice-dev 缺点**:
- ❌ 无 Admin LiveView
- ❌ OperatorLive 接管 bug

**取舍**: ✅ **保留 autoservice-dev 的 LiveView 分离** (在 ezagent_plugin_liveview)，\+ **从 PR #731 移植 Admin LiveView** (TenantAdminLive)，\+ **修复 OperatorLive** (方案 A 最小修正)。

---

### 2.6 Seed Task

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **名称** | `mix ezagent.tenant.seed` | `mix ezagent.demo.seed_autoservice` |
| **定位** | 运维工具 (operator-facing) | Demo 工具 (开发用) |
| **参数** | `--tenant`, `--customer`, `--operator`, `--admin`, `--no-agents` | `--customers`, `--with-slow`, `--deepseek-key` |
| **多租户** | ✅ 支持任意 tenant 名 | ❌ 硬编码 cinnox |

**取舍**: ✅ **保留 autoservice-dev 的 seed task**（当前用于开发验证），后续迭代升级为 PR #731 的参数化版本（`--tenant` + `--admin` + `--operator`）。

---

### 2.7 错误处理与边界场景

| 场景 | PR #731 | autoservice-dev |
|---|---|---|
| **Dead fast agent** | `dispatch_after_commit` 失败 → log，不 abort turn | MentionRouting 无匹配 → 消息进 DLQ |
| **Dead slow agent** | 同上 | 同上 |
| **Fast ACK 无 api_key** | provision 时 dispatch `api_keys.put_api_key` from env | provision 时参数传入 `deepseek_key` → `identity.put_api_key` |
| **Operator 接管时有 bot turn** | cancel bot turn → reopen | 不管 bot turn (synthetic turn_id) |
| **Operator 接管时无 bot turn** | nil guard → open fresh turn (proactive) | 直接 claim synthetic turn_id |
| **Customer 连续发消息** | 新 receive → cancel 旧 open_turn_id → open 新 turn | 每条消息独立 routing |
| **Session 重启后** | after_boot 重 hydrated flavor cache | 不需要 (无 orchestrator) |
| **Agent reply 消息** | bridge → orchestrator.send → compose+settle | agent → chat.send → PubSub → LV |

**PR #731 优点**:
- ✅ dispatch_after_commit — 失败隔离 (P22)
- ✅ api_key from env — secrets 不进 config 文件
- ✅ 连续消息 cancel 旧 turn — 避免 turn 堆积
- ✅ Proactive operator takeover — 不依赖已有 bot turn

**autoservice-dev 优点**:
- ✅ 无 after_boot 问题

**取舍**:
- `dispatch_after_commit` — ✅ 采纳 (用于 agent fan-out)
- `api_key from env` — ✅ 采纳 (安全最佳实践)
- 连续消息 cancel — ✅ 采纳 (加在 CustomerSession 或 routing 逻辑中)
- after_boot — N/A (不引入 orchestrator Kind 则不需要)

---

### 2.8 测试

| 维度 | PR #731 | autoservice-dev |
|---|---|---|
| **autoservice 测试文件** | 8 files, ~2700 lines | 4 files, ~200 lines |
| **content 测试文件** | 5 files (~530 lines) | 17 files (更完整) |
| **cr 测试文件** | 7 files (~560 lines) | 5 files (~400 lines) |
| **多租户隔离** | ✅ multitenant_test.exs (377 lines) | ❌ 无 |
| **Operator 接管 e2e** | ✅ operator_flow_test.exs (438 lines) | ❌ 无 |
| **Publish+refresh** | ✅ publish_refresh_test.exs | ❌ 无 |
| **CsOrchestrator 集成** | ✅ 764 lines | ❌ 无 (无需) |

**取舍**: ✅ **保留 autoservice-dev 的 content/cr 测试**，\+ **从 PR #731 移植**: multitenant_test, operator_flow_test, publish_refresh_test。CsOrchestrator 相关测试不适用（无 orchestrator）。

---

## 三、取舍汇总

### ✅ 从 autoservice-dev 保留

| 项 | 原因 |
|---|---|
| **架构**: Session + MentionRouting | 简单，复用平台能力，无跨 VM 重启问题 |
| **Content plugin**: 18 模块 + Behavior 层 | CapBAC 门控 + 审计，PR #731 最缺的能力 |
| **CR plugin**: Engine/Lint/Snapshot/Rollback 结构 | 模块分离清晰 |
| **FillerLoop** | 用户体验，完成实现 |
| **LiveView 分离**: ezagent_plugin_liveview | 关注点分离 |
| **Uris 模块** | 集中化 URI 推导 |
| **TenantRuntime** | 完整 sandbox/release path 管理 |

### ✅ 从 PR #731 采纳

| 项 | 方式 |
|---|---|
| **operator 接管**: cancel+reopen | 最小修正 (方案 A) — 修复 OperatorLive 的 Turn 使用 |
| **dispatch_after_commit** | 加入 agent fan-out 路径 (P22 合规) |
| **CR 发布**: mark-before-flip + repair_current | 合并到 CrEngine |
| **CR 初始化**: init_tenant 幂等 + half-init 恢复 | 合并到 TenantProvisioner/CrEngine |
| **api_key from env** | 替换参数传入方式 |
| **Admin LiveView**: TenantAdminLive | 移植到 ezagent_plugin_liveview |
| **多租户测试**: multitenant_test.exs | 直接移植 |
| **Operator 接管测试**: operator_flow_test.exs | 移植并适配 |
| **Publish+refresh 测试**: publish_refresh_test.exs | 移植 |
| **连续消息 cancel 旧 turn** | 加入 CustomerSession |
| **AgentsConfig 非异常合约** | 采纳 `{:ok, map}` / `{:error, reason}` |

### ❌ 不采纳

| 项 | 原因 |
|---|---|
| **CsOrchestrator Kind** | 不引入新 Kind — 架构过重，flavor cache 问题 |
| **CsOrchestrator Behavior** | 当前不需要 — operator 接管用最小修正，bot reply 不需要 Turn |
| **after_boot flavor rehydration** | 无 orchestrator Kind 则不需要 |
| **Agent reply 双路径 (:send action)** | 不改变 agent reply 路由 (保持 chat.send → PubSub) |
| **Seed task 改名** | 当前保持 `ezagent.demo.seed_autoservice`，后续升级 |

### ⏸️ 待定

| 项 | 触发条件 |
|---|---|
| **CsOrchestrator Behavior** | bot draft 审核、biphasic 协调、Turn 超时管理需要时 |
| **biphasic 显式建模** | fast/slow 之间有依赖关系时 |
| **Seed task 参数化** | 需要支持非 cinnox 租户时 |

---

## 四、实施优先级

```
P0 (立刻 — 修复 bug):
  1. Operator 接管最小修正 (方案 A)
  2. api_key from env (替换参数传入)

P1 (本周 — 移植 PR #731 已验证的能力):
  3. CR 发布: mark-before-flip + repair_current
  4. 多租户测试移植
  5. Operator 接管测试移植
  6. dispatch_after_commit for agent fan-out

P2 (下次迭代):
  7. Admin LiveView 移植 (TenantAdminLive)
  8. Publish+refresh 测试移植
  9. Seed task 参数化

P3 (按需):
  10. CsOrchestrator Behavior (bot draft 审核等高级功能触发)
```
