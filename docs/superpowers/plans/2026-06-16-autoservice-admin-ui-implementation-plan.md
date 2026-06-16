# AutoService Admin UI v2 — 实施计划

> 基于设计文档 `docs/design/2026-06-16-autoservice-admin-ui-v2-detailed.md`
> 预览: `docs/design/admin-ui-preview.html`
> 分支: `autoservice-dev`
> 日期: 2026-06-16

---

## 设计变更摘要 (vs 上一版设计)

| 变更 | 说明 |
|------|------|
| ❌ Priority 管理 | 移除独立页面，沿用 L3>L2>L1>L0 层级覆盖 |
| ✅ Glossary Editor | 新增术语表编辑器（sandbox/kb/glossary.json 读写） |
| ✅ AI Assistant 面板 | 每个编辑器右侧可展开 AI 助手（chat + diff + quick actions） |
| ✅ Admin Session | 对话式管理（Admin Agent + 结果卡片渲染） |
| ✅ 初始化入口 | Tenant Dashboard pending 状态显示 "开始初始化" CTA + 侧边栏状态标记 |

---

## Phase 0: 初始化入口 (P0-0, 1 task)

**目标**: 租户创建后，Dashboard 根据状态显示初始化引导。

### T0.1 — TenantDashboardLive 初始化引导
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/tenant_dashboard_live.ex`
- **后端**: 检查 `TenantConfig.read_cr(tid, "active")` 是否为 nil（无发布版本 → pending）
- **UI**: 
  - Pending → 显示大号 CTA 卡片 "租户未初始化" + 步骤说明 + "开始初始化" / "稍后再说" 按钮
  - Active → 正常 Dashboard
- **侧边栏**: Overview 项根据状态显示 `⚡ init` 或 `vN active` badge，各子页面的数据计数
- **测试**: LiveView mount 验证 pending/active 两种状态

---

## Phase 1: 初始化向导 (P0-1, 2 tasks)

**目标**: 3 步初始化向导（品牌信息→KB→预览发布），集成 Soul gen + slot prefill + skill inherit。

### T1.1 — InitWizardLive (3步向导)
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/init_wizard_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/init`
- **Step 1**: Brand Info → Soul 自动生成
  - 输入: brand_name, industry (下拉选择), service_hours, hotline
  - 后端: 
    1. 写 brand/industry 到 ConfigStore
    2. `SoulLoader.load(priv_dir, tid, "customer")` → L0+L1+L2 模板
    3. 合成 L3 模板（含 `{{key}}` 占位符）→ 写 `sandbox/souls/customer.md`
    4. `SoulSlotParser.parse_slots(L3_template)` → 提取 key 列表
    5. 从用户输入预填 slot 值 → 写 `sandbox/slots/customer.yaml`
    6. 复制 `skeleton/config/fast_ack_prompt.md` → `sandbox/config/`
    7. `CrEngine.ensure_active_cr(tid)` → 创建初始 CR
  - UI: 右侧实时预览生成的 Soul
- **Step 2**: KB 初始化（可选，可跳过）
  - URL 抓取、文件上传、手动添加（复用 KbManagerLive 的子组件）
- **Step 3**: 预览 + Lint + Publish
  - `SoulRenderer.full_claude_md(...)` → 完整 CLAUDE.md 预览
  - `CrLint.check(tid)` → Lint 结果
  - `CrEngine.publish(tid)` → v1 发布 + `Refresh.refresh_agents(tid)`
- **测试**: 3 步全流程 E2E 测试

### T1.2 — TenantOnboardLive 精简为壳创建
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/tenant/tenant_onboard_live.ex`
- **修改**: 简化为单步表单（Tenant ID + Brand Name），创建空壳租户
- **后端**: `TenantProvisioner.create_tenant(tid, brand_name)` — 只创建 workspace + admin 用户 + 空 sandbox 目录
- **测试**: 创建后验证 workspace 存在、sandbox 目录存在、无 soul/slots 文件

---

## Phase 2: Soul Editor + Slot Editor (P0-2, 2 tasks)

### T2.1 — SoulEditorLive
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/soul_editor_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/soul`
- **4 Tabs**: Source | Diff | Preview | AI Assist
- **后端读**: 
  - L0-L3 templates: `SoulLoader.load(priv_dir, tid, role)`
  - L3 content: `File.read(sandbox/souls/<role>.md)`
  - Slot values: `YamlElixir.read_from_string(File.read(slots_path))`
- **后端写**: `File.write(sandbox/souls/<role>.md, content)` + `CrEngine.record_file_change(tid, "souls/<role>.md")`
- **Diff**: `DiffEngine.diff(release_text, sandbox_text)` → added/removed lines
- **Preview**: `SoulRenderer.full_claude_md(templates, slot_values, skill_index)`
- **{{slot}} 标签**: 点击跳转到 SlotEditorLive
- **测试**: mount + save + diff + preview 流程验证

### T2.2 — SlotEditorLive
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/slot_editor_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/soul/slots`
- **后端读**: 
  - Slot keys: `SoulSlotParser.parse_slots(File.read(sandbox/souls/<role>.md))`
  - Slot values: `YamlElixir.read_from_string(File.read(slots_path))`
- **后端写**: `File.write(slots_path, yaml_string)` + `CrEngine.record_file_change(tid, "slots/<role>.yaml")`
- **UI**: 表单式 key-value 编辑 + YAML 原始编辑切换 + Diff 对比
- **测试**: 编辑 slot → 保存 → 验证 Soul Preview 中 `{{key}}` 替换正确

---

## Phase 3: Skill Manager (P0-3, 1 task)

### T3.1 — SkillManagerLive
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/skill_manager_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/skills`
- **后端**: 
  - 4层扫描: `SkillLoader.list(base_dir, tid, role, layer)` → `[%Entry{}]`
  - 读: `SkillStore.read(base_dir, tid, role, name)`
  - 写: `SkillStore.write(base_dir, tid, role, name, content)` + CR 追踪
  - 删: `SkillStore.delete(base_dir, tid, role, name)` + CR 追踪
- **UI**: 4层卡片网格 + 搜索过滤 + 新建/编辑/删除
- **SkillCard 组件**: 独立可复用（未来 Admin Session 中作为卡片渲染）
- **测试**: 4层扫描 → 创建 L3 skill → 编辑 → 删除 → 验证反向引用

---

## Phase 4: KB Manager + Glossary (P0-4, 2 tasks)

### T4.1 — KbManagerLive
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/kb_manager_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/kb`
- **5 Tabs**: Sources 列表 | URL 抓取 | 文件上传 | 手动添加 | 搜索
- **后端**: 
  - Sources: `KbSourceTracker.list_sources(kb_dir)` → 聚合列表
  - URL 抓取: `KbStore.fetch_url(kb_dir, url)` → curl 下载 → strip HTML → upsert
  - 文件上传: LiveView `allow_upload` → `consume_uploaded_entry` → `KbStore.ingest_file(kb_dir, path)`
  - 删除: `KbStore.delete(kb_dir, id)` + CR 追踪
  - 重建: `KbRebuilder.rebuild(kb_dir)`
- **测试**: URL 抓取 → 文件上传 → 手动添加 → 搜索 → 删除 → 重建

### T4.2 — GlossaryEditor (集成在 KbManagerLive 或独立)
- **文件**: 可作为 KbManagerLive 的一个 tab，或独立 LiveView
- **后端**: `sandbox/kb/glossary.json` JSON 文件读写
- **UI**: 术语列表 + hover 显示编辑/删除按钮 + 新增表单
- **测试**: 增/删/改 glossary 条目 → 验证 rebuild 后 KB 包含 glossary 内容

---

## Phase 5: CR Dashboard 增强 + Version Timeline (P0-5, 2 tasks)

### T5.1 — CrDashboardLive 增强
- **文件**: 增强已有 `cr_dashboard_live.ex`
- **后端新增**: 
  - `CrEngine.record_file_change(tid, path, opts)` — 每次 sandbox 写入后调用
  - `CrEngine.list_crs(tid)` — CR 历史列表
- **UI 增强**: 
  - Tracked Changes 列表（sandbox_diff 读取 + per-item revert）
  - Lint 结果面板（R01-R05）
  - CR History 列表
- **测试**: 编辑 soul → 验证 CR 追踪 → lint → publish → history 列表

### T5.2 — VersionTimelineLive
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/version_timeline_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/versions`
- **后端**: `File.ls(TenantRuntime.release_path(tid))` → 过滤 `v<N>` → 排序
- **回滚**: `CrEngine.rollback(tid, version)` — 翻转 `_current` symlink
- **测试**: 版本列表显示 → 回滚 → 验证 symlink

---

## Phase 6: Sandbox Preview + Fast Prompt (P1, 2 tasks)

### T6.1 — SandboxPreviewLive
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/sandbox_preview_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/preview`
- **后端**: `SoulRenderer.full_claude_md(templates, slot_values, skill_index)`
- **入口**: 
  - Admin: 独立页面
  - CustomerLive: 右上角 [👁️ 预览沙箱] 按钮
  - OperatorLive: 右上角 [👁️ 预览沙箱] 按钮
- **测试**: mount → 渲染预览 → 统计 (byte/line count) → Release 对比

### T6.2 — FastPromptEditorLive
- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/fast_prompt_editor_live.ex` **NEW**
- **路由**: `/admin/autoservice/tenants/:tid/prompt`
- **后端**: `sandbox/config/fast_ack_prompt.md` 文件读写 + `Refresh.refresh_agents(tid)`
- **UI**: textarea 编辑器 + slot 参考面板 + "重置为默认" 按钮
- **测试**: mount → 编辑 → 保存 → 验证 Refresh 调用

---

## Phase 7: Operator 管理增强 + CR 后端完善 (P1, 2 tasks)

### T7.1 — OperatorsLive 增强
- **文件**: 增强已有 `operators_live.ex`
- **新增**: disable/enable 操作员功能
- **后端**: `WorkspaceUserAdmin.disable_user(workspace, user_handle)`

### T7.2 — CR 后端完善
- **文件**: `apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_engine.ex`
- **新增函数**: 
  - `record_file_change/3` — sandbox_diff 追踪
  - `list_crs/1` — CR 历史
  - `rollback/2` — 版本回滚
- **新增模块**: 
  - `DiffEngine` (`apps/ezagent_plugin_content/lib/ezagent_plugin_content/diff_engine.ex`)
  - `KbSourceTracker` (`apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/source_tracker.ex`)

---

## Phase 8: Platform 管理 (P2, 2 tasks)

### T8.1 — PlatformSoulLive + PlatformSkillLive
- **文件**: 
  - `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/platform/platform_soul_live.ex` **NEW**
  - `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/platform/platform_skill_live.ex` **NEW**
- **后端**: `PlatformSoulStore` / `PlatformSkillStore` (已存在)
- **UI**: Master 管理 L1/L2 Soul 和 L0/L1/L2 Skills

---

## Phase 9: AI Assistant + Admin Session (P3 未来)

### T9.1 — AI Assistant 面板
- **组件**: 可复用的 `AiAssistantPanel` LiveComponent
- **功能**: 聊天式交互 + diff 显示 + Accept/Reject + 快捷操作
- **集成**: 在 SoulEditorLive / SlotEditorLive / SkillEditor 右侧可展开

### T9.2 — Admin Session
- **文件**: 
  - `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/admin_session_live.ex` **NEW**
  - `apps/ezagent_plugin_autoservice/lib/ezagent/behavior/admin_agent.ex` **NEW**
- **概念**: ezagent Session + Admin Agent Behavior
- **卡片渲染**: CR Status Card / Publish Result Card / Tenant Overview Card

---

## 路由汇总

```elixir
# === P0 ===
live "/admin/autoservice/tenants/:tid/init",          Admin.InitWizardLive          ← T1.1
live "/admin/autoservice/tenants/:tid/soul",          Admin.SoulEditorLive          ← T2.1
live "/admin/autoservice/tenants/:tid/soul/slots",    Admin.SlotEditorLive          ← T2.2
live "/admin/autoservice/tenants/:tid/skills",        Admin.SkillManagerLive        ← T3.1
live "/admin/autoservice/tenants/:tid/kb",            Admin.KbManagerLive           ← T4.1
live "/admin/autoservice/tenants/:tid/cr",            Tenant.CrDashboardLive        ← T5.1 增强

# === P1 ===
live "/admin/autoservice/tenants/:tid/preview",       Admin.SandboxPreviewLive      ← T6.1
live "/admin/autoservice/tenants/:tid/prompt",        Admin.FastPromptEditorLive    ← T6.2
live "/admin/autoservice/tenants/:tid/versions",      Admin.VersionTimelineLive     ← T5.2

# === P2 ===
live "/admin/autoservice/platform/soul",              Admin.Platform.PlatformSoulLive  ← T8.1
live "/admin/autoservice/platform/skills",            Admin.Platform.PlatformSkillLive ← T8.1

# === P3 (Future) ===
live "/admin/autoservice/agent",                      Admin.AdminSessionLive        ← T9.2
```

---

## 后端新增/修改清单

| 文件 | 操作 | Phase |
|------|:--:|:--:|
| `cr_engine.ex` — `record_file_change/3`, `list_crs/1`, `rollback/2` | 新增函数 | P0-5 |
| `diff_engine.ex` | **NEW** | P0-2 |
| `kb/source_tracker.ex` | **NEW** | P0-4 |
| `content_admin.ex` — `rebuild_kb`, `fetch_url`, `list_sources` actions | 新增 action | P0-4 |
| `tenant_provisioner.ex` — 支持空壳创建模式 | 修改 | P0-1 |
| `soul_renderer.ex` — 确保 `full_claude_md/3` 可用 | 验证/修改 | P0-2 |
| `cr_lint.ex` — R01-R05 规则完善 | 修改 | P0-5 |

---

## 文件结构 (前端)

```
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/
├── autoservice/
│   └── admin/
│       ├── init_wizard_live.ex          ← T1.1
│       ├── soul_editor_live.ex          ← T2.1
│       ├── slot_editor_live.ex          ← T2.2
│       ├── skill_manager_live.ex        ← T3.1
│       ├── kb_manager_live.ex           ← T4.1
│       ├── fast_prompt_editor_live.ex   ← T6.2
│       ├── sandbox_preview_live.ex      ← T6.1
│       ├── version_timeline_live.ex     ← T5.2
│       ├── admin_session_live.ex        ← T9.2 (未来)
│       ├── platform/
│       │   ├── platform_soul_live.ex    ← T8.1
│       │   └── platform_skill_live.ex   ← T8.1
│       └── components/
│           ├── soul_diff_view.ex
│           ├── soul_preview.ex
│           ├── skill_card.ex
│           ├── skill_editor.ex
│           ├── kb_source_list.ex
│           ├── kb_url_ingest.ex
│           ├── kb_file_upload.ex
│           ├── cr_tracked_changes.ex
│           ├── cr_lint_panel.ex
│           ├── slot_form.ex
│           ├── ai_assistant_panel.ex    ← T9.1 (未来)
│           └── admin_card_renderer.ex   ← T9.2 (未来)
├── tenant/
│   ├── tenant_dashboard_live.ex         ← T0.1 增强
│   ├── tenant_onboard_live.ex           ← T1.2 精简
│   └── tenant_admin_live.ex             ← 已有（聚合视图）
└── master/
    └── master_dashboard_live.ex         ← 已有
```
