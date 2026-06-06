# PLAN — Soul/Skill/KB Phase 2-4 实施计划

**SPEC:** `docs/superpowers/specs/2026-06-07-soul-skill-kb-full-design.md`
**Branch:** `autoservice-dev`
**状态:** 实施中

---

## Phase 2: Tenant 编辑 + Skill 索引 (~190 LOC, 1 天)

### Task 2a: Skill Index 注入 CLAUDE.md

- **文件**: `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/cinnox_assets.ex`
- **内容**: 
  - `build_skill_index/0` — 扫描 `priv/cinnox/skills/` 目录, 读每个 SKILL.md YAML header 提取 name+description, 生成 markdown index
  - 修改 `build_cc_claude_md_with_slots/1` — 渲染后在末尾追加 skill_index
  - 修改 `build_cc_claude_md/0` — 同上
- **验证**: 编译通过 → `build_skill_index()` 返回包含已知 skill 名的 markdown

### Task 2b: Render slots 集成到 CLAUDE.md 构建

- **文件**: `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/cinnox_assets.ex`
- **内容**:
  - `default_soul_slot_values/0` — MVP 默认值 (从旧 customer.yaml 提取)
  - `render_slots/2` — `{{key}}` → value 替换
  - `build_cc_claude_md_with_slots/1` — soul 模板 + slot_values → 完整 CLAUDE.md
- **验证**: 编译通过 → 手动测试 `render_slots("{{identity.name}}", %{"identity.name" => "test"})` 返回 "test"

### Task 2c: Seed 脚本更新 + customer_session 接入

- **文件**: 
  - `apps/ezagent_plugin_autoservice/lib/mix/tasks/ezagent.demo.seed_autoservice.ex`
  - `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_session.ex`
  - `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`
  - `apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex`
- **内容**:
  - cc/curl: `template_data_extra/1` 加 `"soul_slot_values"` key
  - customer_session.ex: `provision/2` 接受 `:soul_slot_values` opt → 调用 `build_cc_claude_md_with_slots/1`
  - seed: 传入 `CinnoxAssets.default_soul_slot_values()`
- **验证**: 编译通过 → 全部已有测试通过

### Task 2d: LV Slot 编辑面板

- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/soul_slot_editor_live.ex` (新)
- **内容**:
  - `mount/3`: `template.read` 获取当前 slot_values + `File.read!(soul_path)` 解析 `{{key}}`
  - `render/1`: 按 section 分组展示 key → text input 表单
  - `handle_event("save")`: `template.write` 写回
- **路由**: 在 `ezagent_web` router 加 `/admin/soul-editor` 路由 (或挂到现有 admin 下)
- **验证**: LV 可访问 → 展示 slot 列表 → 修改 → 保存 → `template.read` 确认值已更新
- **估算**: ~150 LOC
- **依赖**: Task 2a, 2b, 2c

---

## Phase 3: 初始化入口 (~390 LOC, 2 天)

### Task 3a: 骨架模板文件

- **文件**: 
  - `apps/ezagent_plugin_autoservice/priv/skeleton/soul/soul.md` (新)
  - `apps/ezagent_plugin_autoservice/priv/skeleton/skills/.gitkeep` (新)
- **内容**: soul.md — 6 个通用 section (identity/purpose/gate/escalation/conversation/privacy), 全部标 `{{slot}}`
- **验证**: 文件存在 → `render_slots(skeleton, %{"identity.name" => "test"})` 正确替换

### Task 3b: Authoring Agent seed

- **文件**: `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/authoring_agent.ex` (新)
- **内容**:
  - AgentTemplate soul: "你是 Template Authoring Agent, 帮助 admin 创建和维护 bot 模板。创作流程: 理解需求→建议 section→生成模板草稿→验证→dispatch write。规则: 不要自主决定业务规则, 修改前展示 diff, human confirm。"
  - MCP tools: `template.read/write` + file r/w (薄 dispatch 适配)
  - Seed 时创建此 agent 的 AgentTemplate (system ws)
- **验证**: seed 后 agent 可 spawn → admin 可 dispatch chat.send → agent 响应

### Task 3c: mix ezagent.skill.bootstrap

- **文件**: `apps/ezagent_plugin_autoservice/lib/mix/tasks/ezagent.skill.bootstrap.ex` (新)
- **内容**:
  - 接受 `<domain_name> <description>` 参数
  - fork skeleton → workspace
  - dispatch chat.send 到 Authoring Agent → Agent 分析描述 → 建议 section/slot → human confirm
  - template.write → 打印结果
- **验证**: `mix ezagent.skill.bootstrap test "test bot"` 创建成功 → AgentTemplate 存在 → slot_values 有默认值

### Task 3d: LV 创建 Bot 面板

- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/bot_creator_live.ex` (新)
- **内容**:
  - 展示 system workspace AgentTemplate 列表 (Bot Type 目录)
  - 选择 Bot Type → fork → 跳转到 slot editor
  - "从零创建" → 跳转到 chat panel (与 Authoring Agent 对话)
- **验证**: LV 可访问 → 展示 Bot Type 列表 → 点击创建 → 新 bot 可用

---

## Phase 4: System 编辑 + 传播 (~300 LOC, 1.5 天)

### Task 4a: 模板编辑 Chat Panel

- **文件**: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/template_editor_live.ex` (新)
- **内容**:
  - 左侧: chat panel (dispatch 到 Authoring Agent session)
  - 右侧: soul 模板预览 + diff 视图
  - Agent 工具: file r/w + template.read/write
- **验证**: LV 可访问 → 发送消息 → Agent 响应 → 修改模板 → 预览更新

### Task 4b: 模板更新通知 + merge

- **文件**: 扩展已有 LV
- **内容**:
  - LV 检测 `parent_template_uri` 对应模板是否更新 (读 system template 的 slot_values vs 当前值)
  - 展示 diff → 手动 merge (保留 tenant 值 / 采用 system 值 / 自定义)
- **验证**: system 更新后 → tenant LV 显示更新提示 → merge → 正确合并

### Task 4c: KBCurator Agent seed

- **文件**: `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/kb_curator_agent.ex` (新)
- **内容**: cc agent, system ws, MCP tools: kb.search/add_entry/update_entry/delete_entry + escalation_keywords 编辑
- **验证**: seed 后 agent 可 spawn → 可编辑 KB

---

## 验证矩阵

| Phase | Task | 编译 | 已有测试 | 新增测试 | E2E |
|-------|------|------|---------|---------|-----|
| 2a | Skill Index | ✅ | ✅ | 手动 | — |
| 2b | Render slots | ✅ | ✅ | 手动 | — |
| 2c | Seed + customer_session | ✅ | ✅ | — | — |
| 2d | LV Slot editor | ✅ | ✅ | — | 手动 |
| 3a | Skeleton | ✅ | ✅ | — | — |
| 3b | Authoring Agent | ✅ | ✅ | — | 手动 |
| 3c | Bootstrap CLI | ✅ | — | ✅ | ✅ |
| 3d | LV Bot Creator | ✅ | — | — | 手动 |
| 4a | Chat Panel | ✅ | — | — | 手动 |
| 4b | Diff + merge | ✅ | — | — | 手动 |
| 4c | KBCurator | ✅ | ✅ | — | — |

---

## 不变式自查 (per task gate)

每个 task 完成后:
- [ ] `mix format --check-formatted` 通过
- [ ] `mix compile` 通过 (无新 warning)
- [ ] `mix test` 无新失败 (预存 7 个允许)
- [ ] 不碰 `apps/ezagent_core/`
- [ ] 不新建 Kind/Behavior module
- [ ] 所有操作走 dispatch (LV: `template.read`/`template.write`, Agent: dispatch)
