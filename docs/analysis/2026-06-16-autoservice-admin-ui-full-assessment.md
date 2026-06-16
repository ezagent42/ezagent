# AutoService Admin UI 全功能评估

> 参考: `D:\Work\h2os.cloud\AutoService-dev-a` (旧版 autoservice, React+Python/FastAPI)
> 目标: 在 ezagent (Phoenix LiveView+Elixir) 中重新实现

---

## 一、旧版 Admin 页面全景

### Tenant 侧边栏导航（租户管理）

| # | 页面 | 路由 | 功能描述 |
|---|------|------|---------|
| 1 | **Tenant Overview** | `/tenants/:tid` | 租户仪表盘：Active CR 数量、最新发布版本、最近发布的 CR、Dream 提案数 |
| 2 | **CR List** | `/tenants/:tid/crs` | CR 列表：所有 CR，active CR 置顶，键盘导航 |
| 3 | **CR Detail** | `/tenants/:tid/crs/:crid` | CR 详情：描述、Diff 视图、Tracked Changes（可逐项 revert）、状态流转、sandbox 文件编辑器、Audit Log、Impact 面板 |
| 4 | **Sandbox Preview** | `/tenants/:tid/preview` | 沙箱预览 |
| 5 | **Versions** | `/tenants/:tid/versions` | 版本时间线：历史版本 + 回滚 |
| 6 | **Soul (Section Browser)** | `/tenants/:tid/soul` | Soul 区域浏览器：4层(L0-L3)树形视图，per-section inbox 计数，Role tabs |
| 7 | **Soul Section Editor** | `/tenants/:tid/soul/:role/:sid` | Soul 区段编辑器：3 tabs (Source/Expanded/Runtime), Diff 视图, AI Assist, ETag 并发 |
| 8 | **Soul Inbox** | `/tenants/:tid/soul/inbox` | 待处理 CR 提案：按 target_kind 分组，Accept/Reject |
| 9 | **Soul Test Console** | `/tenants/:tid/soul/test` | 干运行测试：客户消息输入，sandbox vs release 对比 |
| 10 | **Soul Regen** | `/tenants/:tid/soul/regen` | Soul 重新生成 |
| 11 | **Skills Manager** | `/tenants/:tid/skills/:role` | 4层 Skill 网格：搜索、层级/安全过滤、SkillCard |
| 12 | **Skill Editor** | `/tenants/:tid/skills/:role/:name` | Skill 编辑器：frontmatter+body 编辑，ETag 并发，AI Assist |
| 13 | **KB Manager** | `/tenants/:tid/kb` | KB 管理：3 tabs (Sources列表/URL抓取/文件上传)，Publish 按钮 |
| 14 | **Response Settings** | `/tenants/:tid/response-settings` | PV2 提示词覆盖：ack/progress/filler 三段式，provenance badge |
| 15 | **Operators** | `/tenants/:tid/operators` | 租户操作员管理 |
| 16 | **Dream** | `/tenants/:tid/dream` | Dream 面板：状态卡片 + 触发按钮 + 运行历史 |
| 17 | **Gap Analysis** | `/tenants/:tid/gap-analysis` | 缺口分析：NL输入 → AI推荐 → 选择 |
| 18 | **Dashboard** | `/tenants/:tid/dashboard` | 数据分析面板 |
| 19 | **Billing** | `/tenants/:tid/billing` | 账单 |

### Master 侧边栏导航（平台管理）

| # | 页面 | 路由 | 功能描述 |
|---|------|------|---------|
| 20 | **Tenant List** | `/tenants` | 所有租户列表 |
| 21 | **Onboard Wizard** | `/onboard/:wizid/:step` | 5步向导：URL抓取→文件上传→生成Soul→预览→发布 |
| 22 | **Master Resources** | `/master` | 主资源中心 |
| 23 | **Platform Soul** | `/master/soul/platform` | L1 平台级 Soul 编辑（per-role） |
| 24 | **Industry Soul** | `/master/soul/industry` | L2 行业级 Soul 编辑（per-industry+role） |
| 25 | **Soul Templates** | `/master/soul/templates` | L3 模板编辑（per-role+sid） |
| 26 | **Priority YAML** | `/master/soul/priority` | 4层优先级 + Override 规则 |
| 27 | **Master Skills** | `/master/skill/...` | L0/L1/L2 Skill 管理 |
| 28 | **Master Operators** | `/master/operators` | 平台操作员管理 |
| 29 | **Master Dream** | `/master/dream` | 平台级 Dream |
| 30 | **Response Settings** | `/master/response-settings` | 平台级提示词覆盖 |

---

## 二、后端能力清单

### CR 系统
- [x] CR 生命周期：draft → ready_for_review → publishing → published → rolled_back
- [x] CR 状态机：严格的状态转换验证
- [x] CR sandbox_diff：自动累积 files_changed / paths / ingest_summary
- [x] CR Audit Log：每次状态变更和编辑都记录
- [x] CR Publish：lint gate + 构建 release snapshot + 原子指针翻转
- [x] CR Rollback：版本回滚 + 创建 inverse CR
- [x] Active CR：lazy create，per-tenant 唯一 active CR
- [x] Per-section publish：单区段原子发布
- [x] Per-item revert：撤销 CR 中的单项变更

### Soul 系统
- [x] 4层 Soul：L0(framework) → L1(platform) → L2(industry) → L3(tenant)
- [x] Section Slot 编辑：per-section YAML 存储，ETag 并发控制
- [x] Soul 模板：frontmatter `{{slot}}` 声明
- [x] Soul 生成器：从 brand_name/industry/tone 用 LLM 生成
- [x] Soul 预览：L0+L1+L2+L3 合成预览，含 byte/line count
- [x] AI Assist：NL 意图 → AI 提议 slot diff（advisory，不自动保存）

### Skill 系统
- [x] 4层 Skill：L0(framework) → L1(platform) → L2(industry) → L3(tenant)
- [x] 层覆盖：低层 shadow 高层同名 skill
- [x] Skill 编辑：frontmatter + body，ETag 并发
- [x] Skill 反向引用：查看哪些 section 引用了该 skill
- [x] AI Assist：NL → 提议 skill 内容

### KB 系统
- [x] KB 存储：SQLite FTS5（trigram tokenizer，CJK 支持）
- [x] KB 条目 CRUD：search / upsert / delete / clear_source
- [x] URL 抓取：BFS 爬虫（requests+trafilatura），robots.txt 遵守，rate limiting
- [x] 文件上传：PDF/XLSX/TXT 解析 + chunking
- [x] Source 管理：source_index 追踪来源，multi_source_dedup
- [x] KB Rebuild：从 _sources 目录重建 kb.db
- [x] Flow Directive：kb_type='flow_directive'，enable/disable

### 发布系统
- [x] V1 发布：tarball + freeze + archive
- [x] V2 发布：CR-based，lint gate，release snapshot
- [x] 回滚：版本指针翻转 + CR 审计

### 其他
- [x] Auth：Magic-link + Session + RBAC (master/tenant tiers)
- [x] Dream：后台 LLM 分析对话，发现缺口，生成提案
- [x] Gap Analysis：NL 输入 → AI 分析 4层资源 → 推荐
- [x] Impact Evaluation：CR 变更影响评估（轻量/重量级）
- [x] Test Console：干运行测试 triage + system prompt 预览
- [x] Version Timeline：发布版本历史 + 回滚
- [x] Response Settings：PV2 提示词 3段式覆盖（ack/progress/filler）
- [x] Onboarding Wizard：5步向导（URL→文件→Soul→预览→发布）

---

## 三、ezagent 当前实现 vs 旧版差距

| 功能模块 | ezagent 后端 | ezagent 前端 | 旧版完整度 |
|---------|:---:|:---:|:---:|
| **租户创建** | ✅ TenantProvisioner | ⚠️ TenantOnboardLive (3步，缺步骤) | 5步向导完整 |
| **CR 管理** | ⚠️ CrEngine (publish/cancel) | ⚠️ CrDashboard (无 CR list/history) | 完整 CR 生命周期 |
| **CR Diff/变更追踪** | ❌ 无 sandbox_diff | ❌ | 自动追踪每次编辑 |
| **Soul 编辑** | ✅ SoulStore (文件读写) | ✅ TenantAdminLive (textarea) | 4层+slot+AI assist |
| **Soul Diff** | ❌ 无 sandbox vs release 对比 | ❌ | 完整 Diff 视图 |
| **Soul Preview** | ✅ SoulRenderer | ⚠️ 内联渲染（简单） | 完整 L0-L4 合成 |
| **Skill 管理** | ✅ SkillStore (CRUD) | ⚠️ TenantAdminLive (列表+编辑) | 4层+过滤+AI assist |
| **KB URL 抓取** | ✅ KbStore.fetch_url | ✅ TenantAdminLive (刚加) | 异步 job+polling |
| **KB 文件上传** | ✅ KbStore.ingest_file | ⚠️ 表单存在但 LiveView upload 未完全实现 | 拖拽上传+进度条 |
| **KB Source 管理** | ❌ 无 source list/clear | ❌ | Source 列表+删除 |
| **KB Rebuild** | ✅ KbRebuilder | ✅ TenantAdminLive (刚加) | 完整 |
| **Fast Agent Prompt** | ✅ 文件读写 | ⚠️ TenantAdminLive (textarea) | per-section prompt editor |
| **Operator Console** | ✅ CustomerSession | ✅ OperatorLive | 功能完整 |
| **Version History** | ❌ | ❌ | 版本时间线+回滚 |
| **Sandbox Preview** | ❌ | ❌ | 独立沙箱预览页 |
| **Test Console** | ❌ | ❌ | 干运行测试 |
| **AI Assist** | ❌ | ❌ | NL → slot/skill diff |
| **Dream/Proposal** | ❌ | ❌ | 后台 gap 分析+提案 |
| **Gap Analysis** | ❌ | ❌ | NL 输入+推荐 |
| **Response Settings** | ❌ | ❌ | PV2 prompt 覆盖 |
| **Master Platform Soul** | ✅ PlatformSoulStore | ❌ | L1/L2/L3 编辑 |
| **Master Skills** | ✅ PlatformSkillStore | ❌ | L0/L1/L2 管理 |
| **Priority/Override** | ❌ | ❌ | 4层优先级配置 |

---

## 四、建议优先级

### P0 — 必须（租户日常管理核心闭环）
1. **Soul 编辑完整化**：diff 视图、L1-L3 模板显示
2. **Skill 管理完整化**：4层显示、创建/编辑/删除完整流程
3. **KB 管理完整化**：URL 抓取(含状态提示)、文件上传(含进度)、source 列表+删除
4. **Fast Agent Prompt 编辑**：显示现有内容+编辑保存
5. **CR 变更追踪**：每次编辑自动关联到 active CR，显示变更列表
6. **CR Publish 流程完整**：lint gate + 发布确认 + 结果展示

### P1 — 重要（提升效率和管理可见性）
7. **CR History/List**：历史 CR 列表
8. **Version Timeline**：发布版本历史
9. **Sandbox Preview**：独立预览页
10. **Operator 管理完整化**：禁用/启用、权限编辑

### P2 — 增强（平台级管理）
11. **Master Platform Soul 编辑**：L1 平台 Soul
12. **Master Industry Soul 编辑**：L2 行业 Soul  
13. **Master Skills 管理**：L0/L1/L2 Skills
14. **Test Console**：干运行测试

### P3 — 远期（AI 辅助 + 自动化）
15. **AI Assist**：NL 编辑 Soul/Skill
16. **Dream/Proposal**：后台 gap 分析
17. **Gap Analysis**：NL 缺口分析
18. **Response Settings**：Prompt 覆盖

---

> 请挑选需要优先实现的功能，我基于你的选择重新设计 ezagent Admin UI 布局和实现方案。
