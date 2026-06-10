# AutoService v2 实施计划

> 基于 [`2026-06-10-autoservice-v2-design.md`](../specs/2026-06-10-autoservice-v2-design.md)
> 状态: **Plan v1** | 日期: 2026-06-11

---

## Phase A: content + cr plugin (本期核心，~22 新文件)

### 目标
提炼通用内容管理 + CR 发布流为独立 plugin，Cinnox 数据迁移到新路径。

### Task A1: ezagent_plugin_content — 基础骨架
**产出**: `apps/ezagent_plugin_content/`
- [ ] `mix.exs` — 依赖 `ezagent_core`, `ezagent_domain_socialware` (ConfigStore)
- [ ] `application.ex` — Plugin contract, OTP app
- [ ] 目录结构: `lib/ezagent_plugin_content.ex` + 子目录 `platform/`, `tenant/`, `soul/`, `skill/`, `kb/`
- [ ] `priv/skeleton/` — soul.md 模板, skills/.gitkeep, kb/.gitkeep
- [ ] `priv/skeleton/config/agents.yaml` — 平台默认 agent 配置
- [ ] `priv/skeleton/config/fast_ack_prompt.md` — 默认 ACK prompt
- [ ] `priv/skeleton/config/cc_preamble.md` — 默认 cc preamble
- [ ] `priv/platform/` — Framework/Platform/Industry soul + skill + templates

**验收**: `mix compile` — plugin 编译通过, priv/ 文件可访问

### Task A2: ezagent_plugin_content — Soul CRUD
**产出**: `soul/` 子模块
- [ ] `soul_loader.ex` — 4 层加载 (tenant runtime > industry > platform > framework), 后覆盖前合并
- [ ] `soul_slot_parser.ex` — 解析 `{{key}}` 占位符, 按 section 分组
- [ ] `soul_renderer.ex` — `render(templates, slot_values)` + `full_claude_md(tid, role, values)` (含 preamble + skill index)
- [ ] `soul_store.ex` — `read_slots(tid, role, :sandbox|:release)` / `write_slots(tid, role, values)` / `defaults(tid, role)` (从模板解析默认值)
- [ ] 单元测试: slot_parser 解析 → section 分组, renderer {{key}} → value, 缺失 key → raw

**验收**: `mix test apps/ezagent_plugin_content/` — soul CRUD 全部绿

### Task A3: ezagent_plugin_content — Skill CRUD
**产出**: `skill/` 子模块
- [ ] `skill_loader.ex` — 4 层扫描, 同名覆盖 (tenant > industry > platform > framework)
- [ ] `skill_indexer.ex` — 扫描文件 → 解析 YAML frontmatter (name, description) → 生成 Skill Index markdown
- [ ] `skill_store.ex` — `list(tid, role, layer)` / `read(tid, role, name)` / `write(tid, role, name, content)` / `delete(tid, role, name)`
- [ ] 单元测试: 4 层同名覆盖, index 生成, CRUD

**验收**: `mix test` — skill CRUD + index 全部绿

### Task A4: ezagent_plugin_content — KB CRUD
**产出**: `kb/` 子模块
- [ ] `kb_store.ex` — `search(tid, query)` / `get(tid, entry_id)` / `upsert(tid, entry)` / `delete(tid, entry_id)`
- [ ] `kb_rebuilder.ex` — 调 Python: `uv run --script kb_search_mcp.py --rebuild`
- [ ] `kb_mcp_provider.ex` — 生成 `.mcp.json` 配置 (参数化 `<tid>-kb`, KB_DB_PATH)
- [ ] `kb_curator_agent.ex` — 从 autoservice 迁移, 更新路径引用
- [ ] `kb_store.ex` — URL 抓取 + 文件上传 wrapper (调 kb_search_mcp.py --fetch-url / --ingest-file)
- [ ] `_sources/` 管理: `kb/_sources/_sources.yaml` — 记录 `{source_id: {type, path, friendly_name, ingested_at, hash}}`
- [ ] 单元测试: CRUD, rebuild, MCP config 生成

**验收**: `mix test` — KB CRUD + rebuild + MCP config 全部绿

### Task A5: ezagent_plugin_content — Tenant 管理
**产出**: `tenant/` 子模块
- [ ] `tenant_runtime.ex` — 运行时路径管理, `path(tid, :sandbox|:release)` / `materialize(tid, role)` (symlink 结构)
- [ ] `tenant_provisioner.ex` — `create_tenant(tid, brand_name, opts)` → 创建 workspace, 复制 skeleton→sandbox, 初始化 kb.db, 创建首个 CR
- [ ] `tenant_config.ex` — 租户配置 CRUD (走 ConfigStore `tenant:<tid>:config`)
- [ ] `platform_soul_store.ex` — L0/L1/L2 soul 模板 CRUD
- [ ] `platform_skill_store.ex` — Platform/Industry skill CRUD

**验收**: `mix test` — provision 创建租户, 文件就位, kb.db 可用

### Task A6: ezagent_plugin_cr — CR 引擎
**产出**: `apps/ezagent_plugin_cr/`
- [ ] `mix.exs` — 依赖 content plugin (读 sandbox 状态)
- [ ] `application.ex`
- [ ] `cr_engine.ex` — `ensure_active_cr(tid)` / `track_change(tid, resource)` / `lock_scope(cr_id)` / `publish(cr_id)` / `cancel(cr_id)`
- [ ] `cr_lint.ex` — R01-R05 规则 (引用检查, 模板版本, cross-tenant impact)
- [ ] `cr_snapshot.ex` — `snapshot(tid, scope)` → 生成 release/v<N>/
- [ ] `cr_rollback.ex` — `rollback(tid, target_version)` → 翻 _current 指针
- [ ] CR 数据模型: ConfigStore key `cr:<tid>:<cr_id>` (yaml)
- [ ] 单元测试: CR lifecycle, lint rules, snapshot, rollback

**验收**: `mix test apps/ezagent_plugin_cr/` — CR 完整流程绿

### Task A7: CinnoxAssets/Runtime 重构 → content plugin
**产出**: autoservice plugin 改动
- [ ] `customer_session.ex` — `CinnoxAssets.build_cc_claude_md` → `soul_renderer.full_claude_md(tid, role, values)`
- [ ] `customer_session.ex` — `CinnoxRuntime.materialize_cinnox_cc!` → `tenant_runtime.materialize(tid, role)`
- [ ] `customer_session.ex` — `CinnoxRuntime.kb_mcp_servers` → `kb_mcp_provider.config(tid)`
- [ ] `customer_session.ex` — `CinnoxAssets.build_fast_ack_prompt` → 读 `sandbox/config/fast_ack_prompt.md`
- [ ] `customer_session.ex` — agent 配置从 `priv/skeleton/config/agents.yaml` 读取 (不再硬编码)
- [ ] `customer_session.ex` — 租户参数化: 所有 `cinnox` → `tid` 参数
- [ ] `KbCuratorAgent` → 迁移到 content plugin
- [ ] 重构 `ezagent.demo.seed_autoservice.ex` → `ezagent.tenant.seed.ex` (通用)
- [ ] 旧 CinnoxAssets/CinnoxRuntime 标记 `@deprecated`

**验收**: `mix test` — 现有 autoservice test 绿, demo seed 可创建租户

### Task A8: cinnox 数据迁移
**产出**: 一次性迁移脚本
- [ ] `mix ezagent.content.migrate_cinnox` — `priv/cinnox/` → `~/.ezagent/<profile>/tenants/cinnox/`
- [ ] soul → sandbox/souls/customer_soul.md
- [ ] skills → sandbox/skills/customer/ (flat .md, 统一 flow_chunks + references)
- [ ] kb.db, glossary, escalation_keywords → sandbox/kb/
- [ ] fast_ack prompt → sandbox/config/fast_ack_prompt.md
- [ ] 初始 slot_values → sandbox/slots/customer.yaml (从旧 CinnoxAssets.default_soul_slot_values)
- [ ] 创建首个 CR + Publish v1

**验收**: 迁移后 `mix compile` + agent provision 可用 cinnox 租户

---

## Phase B: autoservice 精简 + Turn 接入 (~10 文件改动)

### 目标
autoservice 精简为容器外壳, Customer 路径接入 Turn + CustomerFeed, Operator 接管完善。

### Task B1: autoservice_assembly.ex
**产出**: autoservice plugin
- [ ] `autoservice_assembly.ex` — 组装协调 (wiring only)
  - `provision_agent(tid, role)` → 调 content plugin + workspace.create_agent
  - `write_slot(tid, role, key, val)` → 调 content.soul_store.write + cr_engine.track_change
- [ ] 单元测试: assembly 各函数调用链正确

### Task B2: Turn 接入 (Customer 路径)
**产出**: autoservice + socialware 集成
- [ ] `turn_adapter.ex` — `open_turn/2`, `compose_turn/3`, `settle_turn/2` (内部通过 Router.dispatch 调 Turn Behavior)
- [ ] `customer_session.ex` — provision 时接入 Turn.open (客户消息到达 → open turn)
- [ ] `customer_live.ex` — 消息流: Turn.open → fast agent ACK → cc agent → Turn.compose → Turn.settle
- [ ] loom 集成接口: `TurnAdapter` 暴露给 loom 调用 (Phase B 先用 CustomerLive 验证)
- [ ] 单元测试: Turn lifecycle (open→compose→settle)

**验收**: `mix test` — Turn 状态机串联绿, 客户消息 → agent 回复 → settle

### Task B3: Operator 接管完善
**产出**: autoservice plugin
- [ ] `operator_live.ex` — Turn.claim → Route disable → 编辑 → Turn.settle → Route enable
- [ ] Route 调整: 用已有 `RuleStore.disable/1` + `RuleStore.enable/1`
- [ ] 通知: `PubSub.broadcast` → loom 感知 operator 接管/结束
- [ ] 集成测试: operator 接管 → customer 看不到草稿 → settle 后 customer 看到

**验收**: `mix test` — 接管流程完整绿

### Task B4: CustomerFeed 订阅替换 session_events_topic
**产出**: autoservice + loom
- [ ] `customer_live.ex` — 订阅从 `Chat.session_events_topic` → `CustomerFeed.topic`
- [ ] `operator_live.ex` — 同上
- [ ] visibility 门控: `:customer_visible` (默认) / `:operator_only` (接管期间)

**验收**: customer 只收到 settle 后的消息, operator 接管期间 customer 看不到草稿

---

## Phase C: Admin UI 补齐 (~8 新文件)

### 目标
Master Admin 和 Tenant Admin 完整管理界面。

### Task C1: Master Admin 页面
**产出**: liveview plugin
- [ ] `master_dashboard_live.ex` — 全平台概览 (租户数, CR 数, 最近发布)
- [ ] `tenant_onboard_live.ex` — 创建租户向导 (Step 1: 基本信息 → Step 2: Admin 账号 → Step 3: 初始化)
- [ ] `platform_content_live.ex` — 平台级 soul/skill 模板编辑 (L0/L1/L2)

**验收**: master admin 可创建租户, 编辑平台模板

### Task C2: Tenant Admin 页面
**产出**: liveview plugin
- [ ] `tenant_dashboard_live.ex` — 租户概览 (当前版本, Active CRs, 悬挂改动, Operator 在线数)
- [ ] `skill_editor_live.ex` — 4 层浏览 + 创建/编辑/删除 Skill
- [ ] `kb_manager_live.ex` — KB 条目搜索/编辑 + URL 抓取 + 文件上传 + escalation keywords 编辑
- [ ] `cr_dashboard_live.ex` — CR 列表/详情/发布 (scope diff 视图, lint 结果)
- [ ] `operators_live.ex` — 管理租户 operator (添加/禁用)

**验收**: tenant admin 可完整管理 soul/skill/KB/CR/operator

---

## Phase D: FillerLoop + 优化 (可 defer)

### 目标
Customer 体验优化, 后续迭代。

### Task D1: FillerLoop
**产出**: loom plugin (or autoservice)
- [ ] `filler_loop.ex` — 协程, 每 N 秒 deepseek 安抚 (text 10s, voice 4s), 最多 3 次
- [ ] cc 超时处理: 45s 硬超时 → 静态道歉 + persist source=cc_timeout
- [ ] 集成测试: filler 在 cc 慢时出现, cc 快时不出现

### Task D2: 其他优化
- [ ] cc 模型切换 (v4-pro → v4-flash, effort=medium)
- [ ] deepseek 连续失败熔断
- [ ] agent 预热 (prewarm)

---

## 文件统计

```
Phase A: 2 新 plugin, ~22 新文件 + ~4 autoservice 改动
Phase B: ~6 autoservice 改动 + ~2 loom 改动
Phase C: ~8 liveview 新文件
Phase D: ~2 新文件
─────────────────────────────────
合计: 2 新 plugin, ~42 文件
core: 0 / domain: 0
```

---

## 依赖关系

```
Phase A (本期) → Phase B → Phase C → Phase D
                  ↓
          Phase A 完成前不开始 Phase B
          Phase A 可并行: A1-A5 (content) || A6 (cr) 独立开发
          A7-A8 依赖 A1-A6 完成
```

---

## 测试策略

```
Phase A:   每个 plugin 独立 ExUnit + content/cr 集成测试
Phase B:   autoservice 集成测试 (CustomerLive + OperatorLive)
Phase C:   LiveView 集成测试 + agent-browser E2E
Phase D:   FillerLoop 单元测试 + 集成测试
```

---

*配套设计: [`2026-06-10-autoservice-v2-design.md`](../specs/2026-06-10-autoservice-v2-design.md)*
