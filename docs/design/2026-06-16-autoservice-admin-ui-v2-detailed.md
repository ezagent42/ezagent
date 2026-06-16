# ezagent AutoService Admin UI v2 — 详细设计

> 基于旧版 AutoService-dev-a 全功能逐页迁移
> 每个组件标注后端数据源、API、存储路径
> 包含完整 UI 线框图

---

## 一、数据架构 (后端对接)

### 1.1 存储层

```
~/.ezagent/default/tenants/<tid>/
├── sandbox/                          ← 编辑区 (所有 admin 操作写这里)
│   ├── config/
│   │   ├── fast_ack_prompt.md        → FastPromptEditorLive 读写
│   │   ├── cc_preamble.md            → SoulEditorLive (慢 agent 前言)
│   │   └── agents.yaml               → TenantConfig
│   ├── souls/
│   │   └── customer.md               → SoulEditorLive 读写
│   ├── slots/
│   │   └── customer.yaml             → SlotEditorLive 读写 ★ 新增
│   ├── skills/                       → SkillManagerLive 读写
│   │   └── <role>/
│   │       └── <name>/
│   │           └── SKILL.md
│   ├── kb/                           → KbManagerLive 读写
│   │   ├── kb.db                     → KbStore (SQLite FTS5)
│   │   ├── kb_entries.json           → KbStore (JSON fallback)
│   │   ├── glossary.json
│   │   └── _sources/
│   │       ├── url/<hash>.html       → URL抓取结果
│   │       └── files/<name>          → 上传文件
│   └── preview/                      → SandboxPreviewLive 读取
│       └── (agent 工作目录 symlink)
├── release/                          ← 发布区 (只读)
│   ├── _current → v<N>/              → VersionTimelineLive 读取
│   └── v<N>/
│       ├── souls/customer.md
│       ├── slots/customer.yaml
│       ├── skills/
│       └── kb/kb.db
└── (ConfigStore 中的 CR 记录)         → CrDashboardLive 读写
    └── cr:<tid>:active               → ConfigStore key
```

### 1.2 后端模块映射

| 前端组件 | 后端读 | 后端写 | CR 追踪 |
|---------|--------|--------|:--:|
| SoulEditorLive | `SoulStore.read` / `SoulRenderer` | `SoulStore.write_slots` via `ContentAdmin.handle_write_soul_slot` | ✅ |
| SlotEditorLive | `File.read(slots/customer.yaml)` | `File.write(slots/customer.yaml)` + `CrEngine.ensure_active_cr` | ✅ |
| SkillManagerLive | `SkillStore.read` / `SkillLoader.list` | `SkillStore.write/delete` via `ContentAdmin.handle_write_skill/delete_skill` | ✅ |
| KbManagerLive | `KbStore.search` / `KbRebuilder` | `KbStore.upsert/delete/fetch_url/ingest_file` | ✅ |
| FastPromptEditorLive | `File.read(config/fast_ack_prompt.md)` | `File.write(config/fast_ack_prompt.md)` + `Refresh.refresh_agents` | ✅ |
| CrDashboardLive | `TenantConfig.read_cr` / `CrEngine` | `CrEngine.publish/cancel` | — |
| VersionTimelineLive | `TenantRuntime.release_path(tid)` 目录扫描 | — (回滚: `CrEngine.rollback`) | — |
| SandboxPreviewLive | `SoulRenderer.full_claude_md` + `SkillIndexer.build` | — (只读) | — |
| TenantOnboardLive | `TenantProvisioner` | `TenantProvisioner.create_tenant` | ✅ |

---

## 二、逐页 UI 线框 + 后端数据绑定

### 2.1 SoulEditorLive — Soul 编辑器

**路由**: `GET /admin/autoservice/tenants/:tid/soul`
**后端读**: `File.read(sandbox/souls/customer.md)`, `File.read(sandbox/slots/customer.yaml)`, `SoulLoader.load(priv_dir, tid, "customer")`
**后端写**: `File.write(sandbox/souls/customer.md, content)` + `CrEngine.ensure_active_cr(tid)`
**组件**: `EzagentPluginLiveview.AutoService.Admin.SoulEditorLive`

```
┌─ Soul 编辑 ──── [Role: customer ▾] ─────────────────────────────┐
│                                                                    │
│  ┌────── Tabs ──────────────────────────────────────────────────┐ │
│  │ [Source ▾]  [Diff]  [Preview]  [AI Assist]                  │ │
│  ├──────────────────────────────────────────────────────────────┤ │
│  │                                                              │ │
│  │  ▸ Source Tab (当前选中):                                     │ │
│  │                                                              │ │
│  │  ┌─ 层级信息 ─────────────────────────────────────────────┐  │ │
│  │  │ L0 Framework: agents/customer/soul.md       (只读)     │  │ │
│  │  │ L1 Platform:  master/platform/customer.md   (只读)     │  │ │
│  │  │ L2 Industry:  master/industry/零售/customer.md (只读)  │  │ │
│  │  │ L3 Tenant:    sandbox/souls/customer.md      ★ 编辑    │  │ │
│  │  └────────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌─ {{slot}} 占位符 ──────────────────────────────────────┐  │ │
│  │  │ [brand_name] [industry] [hotline] [service_hours]     │  │ │
│  │  │ 点击 slot 标签 → 跳转到 Slot 编辑器                     │  │ │
│  │  └────────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ┌─ 编辑器 ──────────────────────────────────────────────┐  │ │
│  │  │ # {{brand_name}} 智能客服 Agent                       │  │ │
│  │  │                                                      │  │ │
│  │  │ 你是 {{brand_name}} 的智能客服助手，                  │  │ │
│  │  │ 专注于 {{industry}} 行业。                            │  │ │
│  │  │                                                      │  │ │
│  │  │ ## 服务范围                                           │  │ │
│  │  │ 1. 订单查询与跟踪                                     │  │ │
│  │  │ 2. 退换货处理 ...                                     │  │ │
│  │  └──────────────────────────────────────────────────────┘  │ │
│  │                                    [保存到 Sandbox] [重置]  │ │
│  │                                                              │ │
│  │  ▸ Diff Tab:                                                 │ │
│  │  ┌─ Sandbox ←→ Release 对比 ───────────────────────────┐   │ │
│  │  │ - 原第3行: "服务时间: 9:00-18:00"                    │   │ │
│  │  │ + 新第3行: "服务时间: 7×24小时"                       │   │ │
│  │  │ Files changed: 1, Lines: +1 -1                        │   │ │
│  │  └──────────────────────────────────────────────────────┘   │ │
│  │                                                              │ │
│  │  ▸ Preview Tab:                                              │ │
│  │  ┌─ 合成预览 (L0+L1+L2+L3 + Slot 替换) ───────────────┐    │ │
│  │  │ # Acme Corp 智能客服 Agent                           │   │ │
│  │  │ 你是 Acme Corp 的智能客服助手，专注于 零售电商 行业。  │   │ │
│  │  │ ...                                                   │   │ │
│  │  │ ---                                                   │   │ │
│  │  │ ## Skills Index                                      │   │ │
│  │  │ - order-lookup: 订单查询 Skill                        │   │ │
│  │  │ - refund-policy: 退换货政策 Skill                     │   │ │
│  │  │ Byte: 2,048  Lines: 85                                │   │ │
│  │  └──────────────────────────────────────────────────────┘   │ │
│  │                                                              │ │
│  │  ▸ AI Assist Tab (未来):                                     │ │
│  │  ┌─ 描述你想要的修改 ───────────────────────────────────┐   │ │
│  │  │ [增加一个投诉处理流程...]                 [提交]      │   │ │
│  │  ├──────────────────────────────────────────────────────┤   │ │
│  │  │ AI 建议:                                              │   │ │
│  │  │ + ## 投诉处理                                         │   │ │
│  │  │ + 1. 记录投诉内容                                     │   │ │
│  │  │ + 2. 升级到人工客服                                   │   │ │
│  │  │                               [Accept] [Reject]       │   │ │
│  │  └──────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

**后端数据绑定**:
- L0: `Application.app_dir(:ezagent_plugin_content, "priv/skeleton/soul/")` (不存在则从 agents 目录读)
- L1: `master/platform/<role>.md` (PlatformSoulStore)
- L2: `master/industry/<industry>/<role>.md` (PlatformSoulStore)
- L3: `sandbox/souls/<role>.md` (直接文件读写)
- Slots: `sandbox/slots/<role>.yaml` → `YamlElixir.read_from_string` 解析
- Slot keys: `SoulSlotParser.parse_slots(template)` 提取 `{{key}}` 占位符
- Preview: `SoulRenderer.full_claude_md(templates, slot_values, skill_index)`
- Diff: `diff(release_file, sandbox_file)` 字符串对比
- CR 追踪: 保存时调用 `CrEngine.ensure_active_cr(tid)` + `CrEngine.record_file_change(tid, "souls/customer.md")`

---

### 2.2 SlotEditorLive — Slot 值编辑器 ★ 新增

**路由**: `GET /admin/autoservice/tenants/:tid/soul/slots`
**后端**: `sandbox/slots/customer.yaml` 文件读写
**组件**: `EzagentPluginLiveview.AutoService.Admin.SlotEditorLive`

```
┌─ Slot 值编辑 ──── [Role: customer ▾] ───────────────────────────┐
│                                                                    │
│  ┌─ Slot Keys (从 Soul 模板解析) ─────────────────────────────┐  │
│  │ ┌─────────────┬──────────────────────────────┬───────────┐ │  │
│  │ │ Key         │ Value                        │ Used In   │ │  │
│  │ ├─────────────┼──────────────────────────────┼───────────┤ │  │
│  │ │ brand_name  │ [Acme Corp_______________]   │ L3 Soul   │ │  │
│  │ │ industry    │ [零售电商________________]   │ L3 Soul   │ │  │
│  │ │ hotline     │ [400-888-9999____________]   │ L3 Soul   │ │  │
│  │ │ service_hrs │ [7×24小时________________]   │ L3 Soul   │ │  │
│  │ └─────────────┴──────────────────────────────┴───────────┘ │  │
│  │                                                            │  │
│  │ [+ 新增 Slot]                               [保存全部]     │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ 原始 YAML 预览 (高级用户) ─────────────────────────────────┐  │
│  │ brand_name: "Acme Corp"                                    │  │
│  │ industry: "零售电商"                                        │  │
│  │ hotline: "400-888-9999"                                    │  │
│  │ service_hours: "7×24小时"                                   │  │
│  │                                         [切换为 YAML 编辑]   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ Diff: Sandbox ←→ Release ────────────────────────────────┐  │
│  │ brand_name: "Cinnox" → "Acme Corp"                        │  │
│  │ industry:  未设置 → "零售电商"                              │  │
│  └────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**后端数据绑定**:
- Slot keys: 扫描 `sandbox/souls/customer.md` 提取所有 `{{key}}` 占位符
- Slot values: `sandbox/slots/customer.yaml` → YAML parse → map
- 保存: `File.write(sandbox/slots/customer.yaml, yaml_string)` + `CrEngine.ensure_active_cr(tid)`
- Diff: `diff(YamlElixir.read(release/slots), YamlElixir.read(sandbox/slots))`

---

### 2.3 SkillManagerLive — Skill 管理器

**路由**: `GET /admin/autoservice/tenants/:tid/skills`
**后端**: `SkillStore` (read/write/delete) + `SkillLoader` (4层扫描)
**组件**: `EzagentPluginLiveview.AutoService.Admin.SkillManagerLive`

```
┌─ Skill 管理 ──── [Role: customer ▾] ─────────────────────────────┐
│                                                                    │
│  ┌─ Filters ──────────────────────────────────────────────────┐  │
│  │ [搜索 skill 名称...]  [Layer: 全部 ▾]  [类型: 全部 ▾]      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ L0 Framework (只读) ──────────────────────────────────────┐  │
│  │ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐        │  │
│  │ │ order-lookup │ │ refund-policy│ │ greeting     │        │  │
│  │ │ 安全 ✓       │ │ 安全 ✓       │ │ 普通         │        │  │
│  │ │ (被 L3 覆盖)  │ │              │ │              │        │  │
│  │ └──────────────┘ └──────────────┘ └──────────────┘        │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ L1 Platform (Master 编辑) ─────────────────────────────────┐  │
│  │ ┌──────────────┐ ┌──────────────┐                           │  │
│  │ │ product-qa   │ │ price-query  │                           │  │
│  │ │ 安全 ✓       │ │ 普通         │                           │  │
│  │ └──────────────┘ └──────────────┘                           │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ L2 Industry: 零售电商 (Master 编辑) ───────────────────────┐  │
│  │ ┌──────────────┐                                             │  │
│  │ │ vip-service  │                                             │  │
│  │ │ 普通         │                                             │  │
│  │ └──────────────┘                                             │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ L3 Tenant: demo-acme ★ (可编辑) ──────────────────────────┐  │
│  │ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐        │  │
│  │ │ order-lookup │ │ refund-policy│ │ custom-skill │        │  │
│  │ │ 安全 ✓       │ │ 安全 ✓       │ │ 普通         │        │  │
│  │ │ [编辑][删除]  │ │ [编辑][删除]  │ │ [编辑][删除]  │        │  │
│  │ └──────────────┘ └──────────────┘ └──────────────┘        │  │
│  │                                    [+ 新建 Skill]          │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ Skill Editor (点击 Skill 卡片后弹出，替换 L3 区域) ───────┐  │
│  │ Skill: order-lookup                                         │  │
│  │ ┌────────────────────────────────────────────────────────┐  │  │
│  │ │ # 订单查询 Skill                                       │  │  │
│  │ │                                                       │  │  │
│  │ │ ## 触发条件                                           │  │  │
│  │ │ 用户询问订单状态、提供订单号                            │  │  │
│  │ │                                                       │  │  │
│  │ │ ## 处理流程                                           │  │  │
│  │ │ 1. 询问用户订单号                                      │  │  │
│  │ │ 2. 查询订单系统                                        │  │  │
│  │ │ 3. 返回状态+预计送达                                   │  │  │
│  │ └──────────────────────────────────────────────────────┘  │  │
│  │                                    [保存] [取消] [删除]    │  │
│  │                                                            │  │
│  │ ┌─ 被以下 Section 引用 ───────────────────────────────┐   │  │
│  │ │ L3 customer: 服务范围 (§5)                           │   │  │
│  │ │ L1 customer: 默认 skill index                        │   │  │
│  │ └──────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**后端数据绑定**:
- L0 扫描: `SkillLoader.list(base_dir, tid, role, :framework)` → `agents/<role>/skills/*/SKILL.md`
- L1 扫描: `SkillLoader.list(base_dir, tid, role, :platform)` → `master/skills/<role>/*/SKILL.md`
- L2 扫描: `SkillLoader.list(base_dir, tid, role, :industry)` → `master/skills/<industry>/<role>/*/SKILL.md`
- L3 扫描: `SkillLoader.list(base_dir, tid, role, :tenant)` → `sandbox/skills/<role>/*/SKILL.md`
- 读取: `SkillStore.read(base_dir, tid, role, name)`
- 写入: `SkillStore.write(base_dir, tid, role, name, content)` + `CrEngine.ensure_active_cr(tid)`
- 删除: `SkillStore.delete(base_dir, tid, role, name)` + `CrEngine.ensure_active_cr(tid)`
- 反向引用: 解析 Soul 模板中的 skill 引用

---

### 2.4 KbManagerLive — KB 管理器

**路由**: `GET /admin/autoservice/tenants/:tid/kb`
**后端**: `KbStore` (search/upsert/delete/fetch_url/ingest_file) + `KbRebuilder`
**组件**: `EzagentPluginLiveview.AutoService.Admin.KbManagerLive`

```
┌─ KB 管理 ─────────────────────────────────────────────────────────┐
│                                                                    │
│  ┌────── Tabs ──────────────────────────────────────────────────┐ │
│  │ [Sources 列表]  [URL 抓取]  [文件上传]  [手动添加]  [搜索]   │ │
│  ├──────────────────────────────────────────────────────────────┤ │
│  │                                                              │ │
│  │  ▸ Sources Tab:                                              │ │
│  │  ┌────────────────────────────────────────────────────────┐  │ │
│  │  │ Type    │ Source              │ Chunks │ Updated       │  │ │
│  │  │─────────┼─────────────────────┼────────┼───────────────│  │ │
│  │  │ url     │ docs.cinnox.com     │  12    │ 2026-06-15    │  │ │
│  │  │ url     │ m800.com/faq        │   5    │ 2026-06-15    │  │ │
│  │  │ file    │ product-guide.pdf   │   8    │ 2026-06-14    │  │ │
│  │  │ manual  │ kb-001 (退换货)      │   1    │ 2026-06-16    │  │ │
│  │  │ manual  │ kb-002 (VIP权益)     │   1    │ 2026-06-16    │  │ │
│  │  └────────────────────────────────────────────────────────┘  │ │
│  │                                              [重建 KB]        │ │
│  │                                                              │ │
│  │  ▸ URL 抓取 Tab:                                             │ │
│  │  ┌────────────────────────────────────────────────────────┐  │ │
│  │  │ URL 列表 (每行一个):                                   │  │ │
│  │  │ [https://docs.cinnox.com/faq                      ]    │  │ │
│  │  │ [https://www.cinnox.com/products                   ]    │  │ │
│  │  │                                        [开始抓取]      │  │ │
│  │  └────────────────────────────────────────────────────────┘  │ │
│  │  ┌─ 抓取任务状态 ───────────────────────────────────────┐    │ │
│  │  │ ● docs.cinnox.com: 3/15 页面, 2 已索引               │    │ │
│  │  │ ✓ cinnox.com/products: 完成 (5 chunks)               │    │ │
│  │  └──────────────────────────────────────────────────────┘    │ │
│  │                                                              │ │
│  │  ▸ 文件上传 Tab:                                             │ │
│  │  ┌────────────────────────────────────────────────────────┐  │ │
│  │  │                                                        │  │ │
│  │  │   [📁 拖拽文件到此处 或 点击选择文件]                    │  │ │
│  │  │                                                        │  │ │
│  │  │   支持: .pdf .xlsx .txt .md .csv .json (最大 50MB)     │  │ │
│  │  │                                                        │  │ │
│  │  └────────────────────────────────────────────────────────┘  │ │
│  │  ┌─ 上传历史 ───────────────────────────────────────────┐    │ │
│  │  │ product-guide.pdf   ████████████ 100%  ✓ 8 chunks     │    │ │
│  │  └──────────────────────────────────────────────────────┘    │ │
│  │                                                              │ │
│  │  ▸ 手动添加 Tab:                                             │ │
│  │  ┌────────────────────────────────────────────────────────┐  │ │
│  │  │ ID:     [kb-003________________]                       │  │ │
│  │  │ Title:  [支付方式说明____________]                      │  │ │
│  │  │ Content:                                                │  │ │
│  │  │ [支持支付方式：微信、支付宝、银联..._______________]    │  │ │
│  │  │                                        [添加条目]      │  │ │
│  │  └────────────────────────────────────────────────────────┘  │ │
│  │                                                              │ │
│  │  ▸ 搜索 Tab:                                                 │ │
│  │  [退款________________] [搜索]                               │ │
│  │  ┌─ Results ────────────────────────────────────────────┐   │ │
│  │  │ kb-001: 退换货流程说明                                │   │ │
│  │  │   客户申请退换货后，系统自动生成退换货单号...          │   │ │
│  │  │ kb-xxx: ...                                          │   │ │
│  │  └──────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                    │
│  ┌─ Actions ──────────────────────────────────────────────────┐  │
│  │ [重建 KB 索引]        [发布 KB 变更 (通过 CR)]              │  │
│  └────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**后端数据绑定**:
- Source 列表: `KbStore.search(kb_dir, "")` → 返回所有条目，按 source_id 聚合
- URL 抓取: `KbStore.fetch_url(kb_dir, url)` → curl 下载 → strip HTML → upsert
- 文件上传: LiveView `allow_upload` → `consume_uploaded_entry` → `KbStore.ingest_file(kb_dir, path)`
- 重建: `KbRebuilder.rebuild(kb_dir)` → 扫描 `_sources/` + `glossary.json`
- CR 追踪: `CrEngine.ensure_active_cr(tid)` (每次新增/删除操作后)

---

### 2.5 CrDashboardLive — CR 管理 (增强版)

**路由**: `GET /admin/autoservice/tenants/:tid/cr`
**后端**: `TenantConfig` (CR 记录) + `CrEngine` (publish/cancel) + `CrLint`
**组件**: 增强已有

```
┌─ Change Request: demo-acme ───────────────────────────────────────┐
│                                                                    │
│  ┌─ Active CR ────────────────────────────────────────────────┐  │
│  │ CR ID: cr-a1b2c3d4e5f6                                     │  │
│  │ Status: [draft]  Created: 2026-06-16 10:30                 │  │
│  │ Created by: entity://system/user/admin                     │  │
│  │                                                            │  │
│  │ ┌─ Tracked Changes (sandbox_diff) ────────────────────┐    │  │
│  │ │ ☑ souls/customer.md          +12 lines  +0 -1       │ [↩]│  │
│  │ │ ☑ slots/customer.yaml        +3 lines   +0 -1       │ [↩]│  │
│  │ │ ☑ skills/customer/refund     new file   +0 -1       │ [↩]│  │
│  │ │ ☑ kb: source added (kb-003)  1 chunk    +0 -1       │ [↩]│  │
│  │ │ ☑ config/fast_ack_prompt.md  +5 lines   +0 -1       │ [↩]│  │
│  │ └──────────────────────────────────────────────────────┘    │  │
│  │ Files changed: 5  │  Lines: +21 -1  │  KB sources: 1         │  │
│  │                                                            │  │
│  │ ┌─ Actions ───────────────────────────────────────────┐    │  │
│  │ │ [Refresh Lint]  [Publish CR]  [Cancel CR]            │    │  │
│  │ └──────────────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ CR History ───────────────────────────────────────────────┐  │
│  │ ┌──────────────────────────────────────────────────────┐    │  │
│  │ │ CR ID          │ Status    │ Version │ Date          │    │  │
│  │ │ cr-xxx         │ published │ v3      │ 2026-06-15    │    │  │
│  │ │ cr-yyy         │ cancelled │ —       │ 2026-06-14    │    │  │
│  │ │ cr-zzz         │ published │ v2      │ 2026-06-13    │    │  │
│  │ └──────────────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ Lint Results ─────────────────────────────────────────────┐  │
│  │ ✓ R01: No broken symlinks in sandbox                       │  │
│  │ ✓ R02: All required files present (soul, slots, skills/)   │  │
│  │ ✓ R03: No empty skill directories                          │  │
│  │ ⚠ R04: Slot key 'phone' referenced in soul but not in      │  │
│  │        slots/customer.yaml → will render as {{phone}}       │  │
│  │ ✓ R05: KB database integrity check passed                  │  │
│  └────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

**后端数据绑定**:
- Active CR: `TenantConfig.read_cr(tid, "active")` → `{:ok, cr_map}`
- CR History: `CrEngine.list_crs(tid)` (需要新增 API) 或 `TenantConfig.read_cr(tid, cr_id)` 遍历
- Tracked Changes: CR 记录的 `sandbox_diff` JSON 字段（需要后端实现 `record_path_changed`）
- Lint: `CrLint.check(tid)` → `{:ok, warnings}` or `{:error, reasons}`
- Publish: `CrEngine.publish(tid)` → `{:ok, published}` → 显示版本号
- Cancel: `CrEngine.cancel(tid)` → `:ok`
- Revert item: 从 CR diff 中移除单个 path，恢复 sandbox 文件到 release 版本

---

### 2.6 SandboxPreviewLive — 沙箱预览 (+ Customer/Operator 入口)

**路由**: 
- Admin: `GET /admin/autoservice/tenants/:tid/preview`
- **Customer 入口**: 在 CustomerLive 页面增加 "预览沙箱" 按钮
- **Operator 入口**: 在 OperatorLive 页面增加 "预览沙箱" 按钮

**后端**: `SoulRenderer.full_claude_md` + `SkillIndexer.build`
**组件**: `EzagentPluginLiveview.AutoService.Admin.SandboxPreviewLive`

```
┌─ Sandbox Preview — demo-acme ────────────────────────────────────┐
│  [Source: sandbox ▾]  [Role: customer ▾]                         │
│                                                                    │
│  ┌─ Customer 入口 ───────────────────────────────────────────┐   │
│  │ CustomerLive → 右上角 [👁️ 预览沙箱] 按钮                   │   │
│  │ OperatorLive → 右上角 [👁️ 预览沙箱] 按钮                   │   │
│  │ Admin → 独立页面 /admin/autoservice/tenants/:tid/preview    │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  ┌─ 渲染结果 ────────────────────────────────────────────────┐   │
│  │                                                            │   │
│  │ # Acme Corp 智能客服 Agent                                 │   │
│  │                                                            │   │
│  │ 你是 Acme Corp 的智能客服助手，专注于 零售电商 行业。        │   │
│  │                                                            │   │
│  │ ## 品牌信息                                                │   │
│  │ - 品牌名称：Acme Corp                                      │   │
│  │ - 行业：零售电商                                            │   │
│  │ - 服务时间：7×24小时                                        │   │
│  │ - 客服热线：400-888-9999                                    │   │
│  │                                                            │   │
│  │ ## 服务范围                                                │   │
│  │ 1. 订单查询与跟踪                                          │   │
│  │ 2. 退换货处理                                              │   │
│  │ 3. 产品咨询                                                │   │
│  │ 4. 价格与优惠查询                                          │   │
│  │ 5. 投诉与建议                                              │   │
│  │                                                            │   │
│  │ ---                                                        │   │
│  │ ## Skills Index                                            │   │
│  │ - **order-lookup**: 订单查询 Skill (L3, 安全)              │   │
│  │ - **refund-policy**: 退换货政策 Skill (L3, 安全)           │   │
│  │ - **product-recommend**: 产品推荐 Skill (L3, 普通)         │   │
│  │                                                            │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  ┌─ 统计 ────────────────────────────────────────────────────┐   │
│  │ Byte count: 2,048  │  Line count: 85  │  Slots resolved: 4  │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  [复制到剪贴板]  [下载 .md]  [对比 Release 版本]                  │
└────────────────────────────────────────────────────────────────────┘
```

**后端数据绑定**:
- 合成渲染: `SoulRenderer.full_claude_md(soul_loader_output, slot_values, skill_index)`
  - `soul_loader_output` = `SoulLoader.load(priv_dir, tid, role)` → 4 个 layer 的模板列表
  - `slot_values` = `YamlElixir.read_from_string(File.read(slots_path))` → map
  - `skill_index` = `SkillIndexer.build(base_dir, tid, role)` → markdown 字符串
- Release 对比: 指向 `release/_current/` 目录读取 release soul/slots/skills

---

### 2.7 VersionTimelineLive — 版本历史

**路由**: `GET /admin/autoservice/tenants/:tid/versions`

```
┌─ 版本历史 — demo-acme ───────────────────────────────────────────┐
│                                                                    │
│  ┌─ Version Timeline ─────────────────────────────────────────┐   │
│  │                                                            │   │
│  │  ● v4  2026-06-16 14:20  cr-a1b2c3d4  ← CURRENT           │   │
│  │  │                                                         │   │
│  │  ○ v3  2026-06-15 10:30  cr-xxx       [回滚到此版本]       │   │
│  │  │                                                         │   │
│  │  ○ v2  2026-06-14 09:00  cr-yyy       [回滚到此版本]       │   │
│  │  │                                                         │   │
│  │  ○ v1  2026-06-13 08:00  (初始发布)                         │   │
│  │                                                            │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  回滚说明: 回滚会创建一个新的 CR (类型: rollback)，将 release 指   │
│  针切换到选中的版本，并自动关闭当前 active CR。                     │
└────────────────────────────────────────────────────────────────────┘
```

**后端数据绑定**:
- 版本列表: `File.ls(TenantRuntime.release_path(tid))` → 过滤 `v<N>` 目录 → sort
- 当前版本: `File.read_link(TenantRuntime.current_release_path(tid))`
- 回滚: 需要新增 `CrEngine.rollback(tid, version)` → 翻转 `_current` symlink

---

### 2.8 TenantOnboardLive — 租户创建向导 (完整 5 步)

**路由**: `GET /admin/autoservice/tenants/new`

```
Step 1: 基本信息
┌─ 新建租户 — Step 1/5 ────────────────────────────────────────────┐
│ [████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  20%          │
│                                                                    │
│  Tenant ID:       [demo-acme____________] (唯一标识，不可更改)     │
│  Brand Name:      [Acme Corp___________]                          │
│  Industry:        [零售电商 ▾___________]                          │
│  Service Hours:   [7×24小时____________]                          │
│  Hotline:         [400-888-9999________]                          │
│                                                                    │
│                                    [下一步 →]                      │
└────────────────────────────────────────────────────────────────────┘

Step 2: Admin 账号
┌─ 新建租户 — Step 2/5 ────────────────────────────────────────────┐
│ [████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  40%                │
│                                                                    │
│  Admin Handle:    [demo-admin___________]                         │
│  Password:        [••••••______________]                          │
│  Confirm:         [••••••______________]                          │
│                                                                    │
│                              [← 上一步]  [下一步 →]                │
└────────────────────────────────────────────────────────────────────┘

Step 3: KB 初始化 (URL 抓取)
┌─ 新建租户 — Step 3/5 ────────────────────────────────────────────┐
│ [████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  60%                  │
│                                                                    │
│  输入网站 URL (可选，可跳过):                                      │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │ [https://docs.cinnox.com/faq                         ]     │   │
│  │ [https://www.cinnox.com/products                      ]     │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                        [开始抓取]  [跳过此步]       │
│                                                                    │
│  ┌─ 抓取状态 ───────────────────────────────────────────────┐    │
│  │ (抓取完成后显示 results)                                   │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                    │
│                              [← 上一步]  [下一步 →]                │
└────────────────────────────────────────────────────────────────────┘

Step 4: 文件上传
┌─ 新建租户 — Step 4/5 ────────────────────────────────────────────┐
│ [████████████████░░░░░░░░░░░░░░░░░░░░░░]  80%                    │
│                                                                    │
│  上传产品文档 (可选，可跳过):                                      │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │   [📁 拖拽文件到此处 或 点击选择]                            │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                        [跳过此步]                  │
│                                                                    │
│                              [← 上一步]  [下一步 →]                │
└────────────────────────────────────────────────────────────────────┘

Step 5: 预览发布
┌─ 新建租户 — Step 5/5 ────────────────────────────────────────────┐
│ [████████████████████████████████████████████]  100%              │
│                                                                    │
│  ┌─ Summary ──────────────────────────────────────────────────┐   │
│  │ Tenant: demo-acme (Acme Corp)                              │   │
│  │ Industry: 零售电商                                          │   │
│  │ Admin: demo-admin                                           │   │
│  │ Soul: ✓ Generated from template                            │   │
│  │ Slots: ✓ Prefilled with brand info                         │   │
│  │ Skills: ✓ 3 platform skills inherited                      │   │
│  │ KB: ✓ 0 URLs fetched, 0 files uploaded                     │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│                              [← 上一步]  [创建并初始化]             │
└────────────────────────────────────────────────────────────────────┘
```

---

### 2.9 Admin Session (未来 — Agent 对话式管理)

**路由**: `GET /admin/autoservice/agent`
**概念**: 一个特殊的 ezagent Session，Admin + Admin Agent 对话完成管理操作

```
┌─ Admin Session ───────────────────────────────────────────────────┐
│  [Admin Agent: online]              [Session: admin-session-1]     │
├──────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌─ [Admin] ──────────────────────────────────────────────────┐  │
│  │ 帮我检查 demo-acme 的当前状态                                 │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ [Agent] ──────────────────────────────────────────────────┐  │
│  │ demo-acme 当前状态:                                          │  │
│  │                                                              │  │
│  │ ┌─ Tenant Status Card ──────────────────────────────────┐   │  │
│  │ │ Tenant: demo-acme (Acme Corp)                         │   │  │
│  │ │ Industry: 零售电商                                      │   │  │
│  │ │ CR: cr-xxx (draft), 5 files changed                    │   │  │
│  │ │ Current Release: v4 (2026-06-16)                       │   │  │
│  │ │ KB Entries: 15                                         │   │  │
│  │ │ Skills (L3): 3                                         │   │  │
│  │ └───────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ [Admin] ──────────────────────────────────────────────────┐  │
│  │ 发布这个 CR                                                   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌─ [Agent] ──────────────────────────────────────────────────┐  │
│  │ Lint 检查通过 ✓                                              │  │
│  │                                                              │  │
│  │ ┌─ Publish Result Card ─────────────────────────────────┐   │  │
│  │ │ ✅ Published v5 at 2026-06-16 14:30                    │   │  │
│  │ │ Version: v5                                            │   │  │
│  │ │ Files published: 5                                     │   │  │
│  │ │ Agent refresh: triggered for demo-acme                 │   │  │
│  │ └───────────────────────────────────────────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ [输入管理命令...]                                  [发送] │  │
│  └────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

---

## 三、组件独立化机制

每个 Admin 组件使用统一的 Phoenix.Component 接口：

```elixir
# 组件声明
defmodule EzagentPluginLiveview.AutoService.Admin.SoulEditor do
  use Phoenix.Component

  attr :tid, :string, required: true
  attr :role, :string, default: "customer"
  attr :embedded, :boolean, default: false

  def soul_editor(assigns) do
    ~H"""
    <div class={[@embedded && "border rounded-xl p-4 bg-white shadow-sm", "admin-component soul-editor"]}>
      <.soul_toolbar tid={@tid} role={@role} embedded={@embedded} />
      <.soul_tabs>
        <:tab name="source"><.soul_source_editor tid={@tid} role={@role} /></:tab>
        <:tab name="diff"><.soul_diff_view tid={@tid} role={@role} /></:tab>
        <:tab name="preview"><.soul_preview tid={@tid} role={@role} /></:tab>
      </.soul_tabs>
    </div>
    """
  end
end
```

**嵌入模式**: 在 Admin Session 中渲染为卡片
```heex
<.soul_editor tid="demo-acme" role="customer" embedded={true} />
```

---

## 四、实施优先级

| 优先级 | 功能 | 新增页面 | 后端改动 |
|:--:|------|:--:|:--:|
| **P0-1** | SoulEditorLive | 1 新页面 | Slot keys 解析、Diff 计算 |
| **P0-2** | SlotEditorLive | 1 新页面 | YAML 读写 + CR 追踪 |
| **P0-3** | SkillManagerLive | 1 新页面 | 4层扫描显示 |
| **P0-4** | KbManagerLive | 1 新页面 | URL抓取状态、文件上传进度 |
| **P0-5** | CrDashboardLive 增强 | 增强已有 | sandbox_diff 追踪 |
| **P0-6** | FastPromptEditorLive | 1 新页面 | 已有后端 |
| **P0-7** | 侧边栏导航 | 已有 router | 路由注册 |
| **P1-1** | SandboxPreviewLive | 1 新页面 | SoulRenderer 集成 |
| **P1-2** | VersionTimelineLive | 1 新页面 | release 目录扫描 |
| **P1-3** | TenantOnboardLive 完整5步 | 增强已有 | 已有 TenantProvisioner |
| **P2** | Platform 管理 | 3 新页面 | PlatformStore 已有 |
| **P3** | Admin Session + AI Agent | 1 新页面 + 1 Agent Behavior | Agent dispatch + card renderer |

---

---

## 五、后端实现方案 (每个功能的前后端数据流)

### 5.1 新增/修改的后端模块

| 模块 | 文件路径 | 说明 |
|------|---------|------|
| `CrEngine` 增强 | `apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_engine.ex` | 新增 `record_file_change/3`, `list_crs/1` |
| `SlotStore` | `apps/ezagent_plugin_content/lib/ezagent_plugin_content/soul/soul_store.ex` | 新增 `read_slots_map/3`, YAML 解析 |
| `DiffEngine` | `apps/ezagent_plugin_content/lib/ezagent_plugin_content/diff_engine.ex` | **NEW** — sandbox vs release 文本对比 |
| `KbSourceTracker` | `apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/source_tracker.ex` | **NEW** — KB source 列表聚合 |
| `ContentAdmin` 增强 | `apps/ezagent_plugin_content/lib/ezagent_plugin_content/behavior/content_admin.ex` | 新增 action: `rebuild_kb`, `fetch_url`, `list_sources` |

### 5.2 逐功能数据流验证

#### Flow 1: Soul 编辑 → 保存 → CR 追踪 → Publish

```
[Admin 在 SoulEditorLive 编辑 soul content]
        │
        ├─ 读: File.read("sandbox/<tid>/souls/customer.md") → @soul_content
        │      SoulLoader.load(priv_dir, tid, "customer") → 4层模板列表
        │      SoulSlotParser.parse_slots(L3_template) → {{key}} 列表
        │
        ├─ Diff: DiffEngine.diff(
        │        File.read("release/_current/souls/customer.md"),
        │        @soul_content)
        │      ) → %{added: [...], removed: [...]}
        │
        ├─ Preview: SoulRenderer.full_claude_md(
        │        templates, slot_values, skill_index)
        │      ) → 完整 CLAUDE.md 字符串
        │
        ├─ 写: File.write("sandbox/<tid>/souls/customer.md", content)
        │      → :ok | {:error, reason}
        │
        ├─ CR 追踪: CrEngine.ensure_active_cr(tid)
        │      → {:ok, cr} (创建或返回已有 draft CR)
        │      CrEngine.record_file_change(tid, "souls/customer.md",
        │        %{lines_added: n, lines_removed: m})
        │      → :ok (更新 CR 的 sandbox_diff JSON)
        │
        └─ Publish: CrEngine.publish(tid)
              → CrLint.check(tid) → :ok | {:error, reasons}
              → CrSnapshot.snapshot(tid) → {:ok, version}
              → update_current(tid, version) → :ok
              → Refresh.refresh_agents(tid) → :ok
              → {:ok, %{"published_version" => "vN"}}
```

**验证点**:
- [ ] `SoulRenderer.full_claude_md/3` 接受 4-layer templates + slot_values + skill_index
- [ ] `DiffEngine.diff/2` 返回 `%{added: [line], removed: [line], unchanged: [line]}`
- [ ] `CrEngine.record_file_change/3` 写入 `sandbox_diff` JSON 到 ConfigStore
- [ ] `CrEngine.publish/1` 完整流程：lint → snapshot → flip → refresh

#### Flow 2: Slot 编辑 → 保存 → Soul 预览联动

```
[Admin 在 SlotEditorLive 编辑 slot values]
        │
        ├─ 读: File.read("sandbox/<tid>/slots/customer.yaml")
        │      → YamlElixir.read_from_string(content) → {:ok, map}
        │
        ├─ Slot keys: SoulSlotParser.parse_slots(
        │        File.read("sandbox/<tid>/souls/customer.md"))
        │      ) → [%SlotSection{section: "...", keys: ["brand_name", ...]}]
        │
        ├─ Diff: DiffEngine.diff_yaml(
        │        YamlElixir.read("release/_current/slots/customer.yaml"),
        │        YamlElixir.read("sandbox/<tid>/slots/customer.yaml"))
        │      ) → %{added_keys: [...], removed_keys: [...], changed_keys: [...]}
        │
        ├─ 写: File.write("sandbox/<tid>/slots/customer.yaml", yaml_string)
        │      → :ok
        │
        └─ CR 追踪: CrEngine.record_file_change(tid, "slots/customer.yaml")
              → :ok
```

**验证点**:
- [ ] `SoulSlotParser.parse_slots/1` 正确解析所有 `{{key}}` 占位符并按 section 分组
- [ ] YAML 读写保持格式（注释、顺序）不丢失
- [ ] Slot 修改后，Soul Preview 中的 `{{key}}` 替换反映最新值

#### Flow 3: Skill 创建/编辑/删除 → CR 追踪

```
[Admin 在 SkillManagerLive 操作]
        │
        ├─ 4层扫描: SkillLoader.list(base_dir, tid, role, layer)
        │      → [%SkillLoader.Entry{name: "...", path: "...", layer: :l3}]
        │
        ├─ 读: SkillStore.read(base_dir, tid, role, name)
        │      → {:ok, content} | :not_found
        │
        ├─ 创建/编辑: SkillStore.write(base_dir, tid, role, name, content)
        │      → :ok (写 sandbox/skills/<role>/<name>/SKILL.md)
        │
        ├─ 删除: SkillStore.delete(base_dir, tid, role, name)
        │      → :ok | {:error, :not_found}
        │
        └─ CR 追踪: CrEngine.record_file_change(tid, "skills/<role>/<name>/SKILL.md")
              → :ok
```

**验证点**:
- [ ] L0/L1/L2 的 `SkillLoader.list` 正确读取对应目录
- [ ] L3 创建路径为 `sandbox/skills/<role>/<name>/SKILL.md`
- [ ] 覆盖逻辑: L3 > L2 > L1 > L0（同名 skill 高层覆盖低层）

#### Flow 4: KB URL 抓取 → 文件上传 → Source 管理

```
[Admin 在 KbManagerLive 操作]
        │
        ├─ URL 抓取: KbStore.fetch_url(kb_dir, url)
        │      ├─ curl -sL <url> → html
        │      ├─ strip_html → text
        │      ├─ save _sources/url/<hash>.html
        │      ├─ upsert(text as kb entry)
        │      └─ → :ok | {:error, reason}
        │
        ├─ 文件上传: LiveView allow_upload → consume_entry
        │      ├─ save _sources/files/<name>
        │      ├─ read content
        │      └─ KbStore.upsert(kb_dir, entry)
        │      └─ → :ok | {:error, reason}
        │
        ├─ Source 列表: KbStore.search(kb_dir, "")
        │      → [%{id: "url:abc", title: "...", source_type: "url"}, ...]
        │      → 按 source_type 和 source_id 聚合为 Source 列表
        │
        ├─ 删除 Source: KbStore.delete(kb_dir, id)
        │      → :ok
        │
        ├─ 重建: KbRebuilder.rebuild(kb_dir)
        │      → 扫描 _sources/url/ + _sources/files/ + glossary.json
        │      → 重新生成 kb_entries.json
        │
        └─ CR 追踪: CrEngine.record_file_change(tid, "kb/sources")
              → :ok
```

**验证点**:
- [ ] `KbStore.fetch_url/2` 能正确下载 URL 并提取文本
- [ ] LiveView `allow_upload` 正确配置（max_size, accept types）
- [ ] `consume_uploaded_entry` 正确处理临时文件路径
- [ ] Source 列表正确去重和聚合

#### Flow 5: CR 生命周期 (Draft → Publish → History)

```
[CR 生命周期]
        │
        ├─ 创建 (自动): 任何 sandbox 写入触发 CrEngine.ensure_active_cr(tid)
        │      → 查找已有 draft CR → 如无则创建
        │      → {:ok, cr}
        │
        ├─ 变更追踪: CrEngine.record_file_change(tid, path, diff)
        │      → 读取 CR 的 sandbox_diff JSON
        │      → merge: files_changed += 1, paths += [path], lines += n
        │      → 写回 ConfigStore
        │
        ├─ Lint: CrLint.check(tid)
        │      → R01-R05 规则检查
        │      → {:ok, warnings} | {:error, reasons}
        │
        ├─ Publish: CrEngine.publish(tid)
        │      ├─ Lint check (gate)
        │      ├─ CrSnapshot.snapshot(tid) → {:ok, "vN"}
        │      │   └─ cp -r sandbox/ → release/vN/
        │      ├─ update_current(tid, "vN") → symlink flip
        │      ├─ CR status → "published"
        │      └─ Refresh.refresh_agents(tid)
        │
        ├─ Cancel: CrEngine.cancel(tid)
        │      → CR status → "cancelled"
        │
        ├─ CR History: 读取 ConfigStore 中所有 `cr:<tid>:*` 记录
        │      → 按 updated_at 排序
        │      → 返回列表
        │
        └─ Rollback (VersionTimelineLive):
               → File.rm(link) → File.ln_s(version_path, link)
               → 创建 rollback CR 记录
```

**验证点**:
- [ ] `ensure_active_cr` 幂等：同 tenant 同时只有一个 draft CR
- [ ] `record_file_change` 正确 merge sandbox_diff JSON
- [ ] `publish` 完整流程: lint → snapshot → flip → refresh → status change
- [ ] `cancel` 正确关闭 CR 并保持 sandbox 不变
- [ ] CR History 能列出所有历史 CR 及其状态

#### Flow 6: Fast Agent Prompt 编辑

```
[Admin 在 FastPromptEditorLive 编辑]
        │
        ├─ 读: File.read("sandbox/<tid>/config/fast_ack_prompt.md")
        │      → string (默认从 skeleton 复制)
        │
        ├─ 写: File.write("sandbox/<tid>/config/fast_ack_prompt.md", content)
        │      → :ok
        │
        ├─ Release 读取: Refresh.refresh_agents(tid)
        │      → 从 release/_current/config/fast_ack_prompt.md 读取
        │      → 调用 dispatch 写入 fast agent 的 system_prompt
        │
        └─ CR 追踪: CrEngine.record_file_change(tid, "config/fast_ack_prompt.md")
```

#### Flow 7: Tenant Onboard (5步向导)

```
Step 1: 输入 tid, brand_name, industry → 前端暂存
Step 2: 输入 admin_handle, password → 前端暂存
Step 3: URL 列表 → 暂存，可选跳过
Step 4: 文件上传 → 暂存，可选跳过
Step 5: 确认 → 一键创建

[Step 5 提交时后端流程]:
        │
        ├─ TenantProvisioner.create_tenant(tid, brand_name, industry: industry)
        │      ├─ 创建 sandbox 目录结构
        │      ├─ 复制 skeleton soul → sandbox/souls/customer.md
        │      ├─ 复制 skeleton skills → sandbox/skills/
        │      ├─ 创建空 slots/customer.yaml (根据 soul template)
        │      ├─ 创建空 kb/ 目录
        │      ├─ 复制 fast_ack_prompt.md → sandbox/config/
        │      └─ 写 tenant config 到 ConfigStore
        │
        ├─ WorkspaceUserAdmin.create_user(workspace, admin_handle, password)
        │      → {:ok, %{user_uri: ...}}
        │
        ├─ (如果 Step 3 有 URL) → KbStore.fetch_url 批量抓取
        ├─ (如果 Step 4 有文件) → KbStore.ingest_file 批量入库
        │
        └─ CrEngine.ensure_active_cr(tid)
              → {:ok, cr} (初始 CR，追踪所有初始化变更)
```

---

## 六、后端新增/修改模块详细实现

### 6.1 CrEngine 增强

```elixir
# apps/ezagent_plugin_cr/lib/ezagent_plugin_cr/cr_engine.ex

defmodule EzagentPluginCr.CrEngine do
  # ... 现有 publish/cancel/ensure_active_cr/repair_current ...

  @doc """
  Record a sandbox file change on the active CR.
  Called by every admin write handler after a successful sandbox write.
  """
  def record_file_change(tid, path, opts \\ []) do
    with {:ok, cr} <- ensure_active_cr(tid) do
      diff = %{
        "files_changed" => 1,
        "paths" => [path],
        "lines_added" => Keyword.get(opts, :lines_added, 0),
        "lines_removed" => Keyword.get(opts, :lines_removed, 0)
      }
      merge_sandbox_diff(tid, cr, diff)
    end
  end

  @doc "List all CRs for a tenant, sorted by updated_at desc."
  def list_crs(tid) do
    # Scan ConfigStore for keys matching "cr:#{tid}:*"
    # Return list of CR maps with status, version, created_at
    # Implementation: query ConfigPointer/SQL
    ...
  end

  # Private: merge diff into CR's sandbox_diff JSON field
  defp merge_sandbox_diff(tid, cr, diff) do
    existing = cr["sandbox_diff"] || %{}
    merged = %{
      "files_changed" => (existing["files_changed"] || 0) + Map.get(diff, "files_changed", 0),
      "lines_added" => (existing["lines_added"] || 0) + Map.get(diff, "lines_added", 0),
      "lines_removed" => (existing["lines_removed"] || 0) + Map.get(diff, "lines_removed", 0),
      "paths" => Enum.uniq((existing["paths"] || []) ++ Map.get(diff, "paths", []))
    }
    # Write back to ConfigStore
    TenantConfig.update_cr(tid, cr["cr_id"], Map.put(cr, "sandbox_diff", merged))
    :ok
  end
end
```

### 6.2 DiffEngine (新增)

```elixir
# apps/ezagent_plugin_content/lib/ezagent_plugin_content/diff_engine.ex

defmodule EzagentPluginContent.DiffEngine do
  @moduledoc "Simple text diff for sandbox vs release comparison."

  def diff(release_text, sandbox_text) when is_binary(release_text) and is_binary(sandbox_text) do
    release_lines = String.split(release_text, "\n")
    sandbox_lines = String.split(sandbox_text, "\n")
    # Simple line-by-line diff using List.myers_difference if available
    # or a basic implementation
    do_diff(release_lines, sandbox_lines)
  end

  def diff_yaml({:ok, release_map}, {:ok, sandbox_map}) do
    # Compare two YAML maps key by key
    all_keys = Map.keys(release_map) ++ Map.keys(sandbox_map) |> Enum.uniq()
    changes = Enum.reduce(all_keys, %{added: [], removed: [], changed: [], unchanged: []}, fn key, acc ->
      r = Map.get(release_map, key)
      s = Map.get(sandbox_map, key)
      cond do
        is_nil(r) and not is_nil(s) -> %{acc | added: [key | acc.added]}
        not is_nil(r) and is_nil(s) -> %{acc | removed: [key | acc.removed]}
        r != s -> %{acc | changed: [key | acc.changed]}
        true -> %{acc | unchanged: [key | acc.unchanged]}
      end
    end)
    {:ok, changes}
  end

  defp do_diff(old, new) do
    # Simplified: mark lines only in sandbox as added
    old_set = MapSet.new(old)
    new_set = MapSet.new(new)
    %{
      added: MapSet.difference(new_set, old_set) |> Enum.to_list(),
      removed: MapSet.difference(old_set, new_set) |> Enum.to_list()
    }
  end
end
```

### 6.3 KbSourceTracker (新增)

```elixir
# apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/source_tracker.ex

defmodule EzagentPluginContent.Kb.SourceTracker do
  @moduledoc "Aggregates KB entries into Source list for display."

  def list_sources(kb_dir) do
    entries = KbStore.search(kb_dir, "")
    entries
    |> Enum.group_by(& &1["source_type"] || "manual")
    |> Enum.flat_map(fn {type, group} ->
      group
      |> Enum.group_by(& &1["source_id"] || &1["id"])
      |> Enum.map(fn {source_id, chunks} ->
        %{
          source_type: type,
          source_id: source_id,
          title: List.first(chunks)["title"] || source_id,
          chunk_count: length(chunks),
          latest: Enum.max_by(chunks, & &1["created_at"] || "", fn -> "" end)
        }
      end)
    end)
  end
end
```

---

## 七、前端组件文件结构

```
apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/autoservice/admin/
├── soul_editor_live.ex           ← SoulEditorLive (P0-1)
├── slot_editor_live.ex           ← SlotEditorLive (P0-2)
├── skill_manager_live.ex         ← SkillManagerLive (P0-3)
├── kb_manager_live.ex            ← KbManagerLive (P0-4)
├── fast_prompt_editor_live.ex    ← FastPromptEditorLive (P0-6)
├── sandbox_preview_live.ex       ← SandboxPreviewLive (P1-1)
├── version_timeline_live.ex      ← VersionTimelineLive (P1-2)
├── tenant_onboard_live.ex        ← 完整 5步向导 (P1-3)
├── operator_manager_live.ex      ← Operator 管理增强 (P1)
├── platform/
│   ├── platform_soul_live.ex
│   ├── platform_skill_live.ex
│   └── platform_priority_live.ex
└── components/                   ← 可复用子组件
    ├── soul_diff_view.ex         ← Diff 视图 (SoulEditor 用)
    ├── soul_preview.ex           ← Preview 视图
    ├── skill_card.ex             ← Skill 卡片
    ├── skill_editor.ex           ← Skill 编辑器
    ├── kb_source_list.ex         ← KB Source 列表
    ├── kb_url_ingest.ex          ← KB URL 抓取
    ├── kb_file_upload.ex         ← KB 文件上传
    ├── cr_tracked_changes.ex     ← CR 变更追踪列表
    ├── cr_lint_panel.ex          ← CR Lint 面板
    ├── slot_form.ex              ← Slot 编辑表单
    └── version_card.ex           ← 版本信息卡片
```

---

## 八、路由注册

```elixir
# apps/ezagent_web/lib/ezagent_web/router.ex

# === AutoService v2 Admin (Tenant) ===
live "/admin/autoservice/tenants/:tid/soul",        AutoService.Admin.SoulEditorLive
live "/admin/autoservice/tenants/:tid/soul/slots",  AutoService.Admin.SlotEditorLive
live "/admin/autoservice/tenants/:tid/skills",      AutoService.Admin.SkillManagerLive
live "/admin/autoservice/tenants/:tid/kb",          AutoService.Admin.KbManagerLive
live "/admin/autoservice/tenants/:tid/cr",          Tenant.CrDashboardLive       ← 增强
live "/admin/autoservice/tenants/:tid/versions",    AutoService.Admin.VersionTimelineLive
live "/admin/autoservice/tenants/:tid/preview",     AutoService.Admin.SandboxPreviewLive
live "/admin/autoservice/tenants/:tid/prompt",      AutoService.Admin.FastPromptEditorLive
live "/admin/autoservice/tenants/:tid/operators",   Tenant.OperatorsLive         ← 增强

# === AutoService v2 Admin (Platform) ===
live "/admin/autoservice/platform/soul",     AutoService.Admin.Platform.PlatformSoulLive
live "/admin/autoservice/platform/skills",   AutoService.Admin.Platform.PlatformSkillLive
live "/admin/autoservice/platform/priority", AutoService.Admin.Platform.PlatformPriorityLive

# === Future ===
live "/admin/autoservice/agent",             AutoService.Admin.AdminSessionLive
```

---

## 九、验证 Checklist

实施每个模块后，必须验证以下数据流：

- [ ] **SoulEditorLive**: 读取4层模板 → 显示 → 编辑 L3 → 保存 → CR 追踪 → Lint → Publish → Release
- [ ] **SlotEditorLive**: 从 Soul 解析 slot keys → 读取 YAML values → 编辑 → 保存 → Soul Preview 联动
- [ ] **SkillManagerLive**: 4层扫描 → 显示卡片 → 创建 L3 skill → 编辑 → 删除 → 反向引用检查
- [ ] **KbManagerLive**: Source 列表 → URL 抓取 → 文件上传 → 搜索 → 删除 → 重建
- [ ] **CrDashboardLive**: 变更追踪列表 → Lint 结果 → Publish → History 列表
- [ ] **VersionTimelineLive**: 版本列表 → 回滚 → symlink 验证
- [ ] **SandboxPreviewLive**: SoulRenderer 合成 → 统计 → Release 对比
- [ ] **TenantOnboardLive**: 5步 → 一键创建 → sandbox 验证 → CR 验证
- [ ] **FastPromptEditorLive**: 读取 → 编辑 → 保存 → 验证 Refresh 生效

---

> 请 Review 并确认优先级，开始实施 P0。
