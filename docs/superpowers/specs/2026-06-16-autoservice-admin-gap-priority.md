# AutoService Admin UI — 功能优先级评估

> 对比旧版 AutoService-dev-a，逐功能评估迁移优先级
> 目标：两个 Admin 入口（可视化管理 + Admin Session 会话式管理）
> Dream 放入远期

---

## 评估原则

1. **P0 必须**：可视化管理页核心编辑闭环（创建→编辑→CR追踪→发布→回滚），缺了无法正常使用
2. **P1 应该**：提升编辑效率、数据可见性、AI 辅助定位，旧版有且常用
3. **P2 可以**：完善体验，旧版有但可后补
4. **P3 远期**：独立子系统（Dream/Canary等），另立项

---

## 一、KB 系统

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 1 | 文本 Chunking（段落切分600char/chunk） | ✅ | ❌ | **P0** | 搜索质量的根基，无chunk长文本搜不到 |
| 2 | PDF 语义提取（heading-aware chunking+page number） | ✅ | ⚠️ | **P1** | PDF是主要KB来源，但可用pdftotext临时替代 |
| 3 | XLSX 语义提取（sheet+rate-table检测+region tag） | ✅ | ❌ | **P1** | 通讯行业定价表是核心KB来源 |
| 4 | 异步 Ingest Jobs（URL/文件上传不阻塞UI） | ✅ | ❌ | **P1** | 大文件同步上传会超时，影响体验 |
| 5 | URL 爬虫（BFS同域多页+robots.txt+rate limit） | ✅ | ❌ | **P2** | 单页fetch够基础使用，多页爬虫可后补 |
| 6 | KB Source 元数据（source_url/latest_created_at/enabled） | ✅ | ❌ | **P2** | 列表显示增强，不影响功能 |
| 7 | ~~Flow Directive（intent触发词+enable/disable）~~ | ✅ | 已废弃 | — | 迭代废弃，不需要 |
| 8 | 18列KB Schema（domain/region/language等过滤字段） | ✅ | ❌ | **P2** | 多租户+中文精准查询，当前单租户够用 |
| 9 | FTS5 trigram CJK搜索 | ✅ | ⚠️ | **P1** | 中文搜索精度，当前Python脚本可能未启用trigram |

---

## 二、CR 系统

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 10 | Sandbox Diff 计算（scope item级hash对比） | ✅ | ❌ | **P0** | CR Dashboard看不到改了啥，核心功能缺失 |
| 11 | Per-item Publish（选择性发布部分变更） | ✅ | ❌ | **P1** | 发布灵活性，但全量发布可工作 |
| 12 | Per-item Revert（撤销单个文件的改动） | ✅ | ❌ | **P1** | 与per-item publish配套 |
| 13 | 回滚恢复 Sandbox（release文件→sandbox） | ✅ | ❌ | **P0** | 当前回滚只改symlink，沙箱仍是脏的 |
| 14 | CR 状态机完善（ready_for_review/abandoned） | ✅ | ❌ | **P2** | draft→published基本够用 |
| 15 | CR Actor 追踪（记录谁做的改动） | ✅ | ❌ | **P2** | 审计需求，当前用system://cr-engine |
| 16 | Release Manifest（version/actor/items/parent_version） | ✅ | ❌ | **P2** | 发布记录，方便排查 |
| 17 | Publish Lock（并发发布锁） | ✅ | ❌ | **P2** | 单admin操作场景不太需要 |
| 18 | 原子化发布目录（.partial→rename） | ✅ | ❌ | **P2** | 防止半写release，但cp -r够用 |
| 19 | CR Detail 页面（scope/audit/full view） | ✅ | ❌ | **P2** | CrDashboard已显示基本信息 |

---

## 三、Soul/Slot 系统

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 20 | ETag 并发控制（If-Match防止覆盖） | ✅ | ❌ | **P1** | 多人编辑场景需要，单人够用但加成本低 |
| 21 | Template声明的Slot验证（拒绝未声明key） | ✅ | ❌ | **P1** | 防止typo key，编辑体验改善 |
| 22 | Per-section Publish（单section原子发布） | ✅ | ❌ | **P2** | 精细化发布，全量发布可工作 |
| 23 | Seed Endpoint（从模板批量初始化section） | ✅ | ❌ | **P1** | InitWizard已实现基础版，需增强 |
| 24 | Section Browser（L0-L3树形视图+inbox计数） | ✅ | ❌ | **P2** | SoulEditor已显示4层，UI优化 |
| 25 | Composed Soul Runtime Preview（字节精确） | ✅ | ⚠️ | **P1** | 当前Preview tab功能有，但路径需验证与runtime一致 |

---

## 四、Skill 系统

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 26 | Frontmatter/Body 分离编辑器 | ✅ | ❌ | **P0** | metadata不可编辑，skill卡片无description/intent显示 |
| 27 | ETag 并发控制 | ✅ | ❌ | **P1** | 同slot |
| 28 | L0/L1 目录分离（framework vs platform） | ✅ | ❌ | **P1** | 当前L0和L1读同一目录，层级混叠 |
| 29 | Shadowed_by 后端解析（非前端计算） | ✅ | ⚠️ | **P2** | 前端计算可工作，后端更可靠 |
| 30 | Skill Reverse Refs（哪些section引用该skill） | ✅ | ❌ | **P2** | SoulEditor已显示skill index |
| 31 | AI Assist（自然语言→skill修改提案） | ✅ | ❌ | **P3** | 远期AI功能 |

---

## 五、发布与版本

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 32 | Lint Severity分级（error阻断/warning记录） | ✅ | ⚠️ | **P1** | 当前5条规则无严重度，error应阻断发布 |
| 33 | Lint Scoped（只检查发布范围内的文件） | ✅ | ❌ | **P2** | 全量检查可工作 |
| 34 | cc_pool Recycle（发布后刷新agent缓存） | ✅ | ⚠️ | **P1** | Refresh.refresh_agents已调用，验证即可 |
| 35 | Rehearsal（虚拟客户测试对话） | ✅ | ❌ | **P3** | 独立子系统 |
| 36 | Compliance Gate（合规检查阻断发布） | ✅ | ❌ | **P3** | 独立子系统 |

---

## 六、初始化与租户管理

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 37 | InitWizard URL Ingest步骤 | ✅ | ❌ | **P1** | 初始化时KB入口，当前可跳过 |
| 38 | InitWizard Doc Upload步骤 | ✅ | ❌ | **P1** | 同上 |
| 39 | Tenant Shell创建（只创建workspace+空sandbox） | ✅ | ✅ | — | 已实现 |
| 40 | Tenant Dashboard 初始化状态检测 | ✅ | ✅ | — | 已实现 |
| 41 | Operators disable/enable | ✅ | ❌ | **P2** | 管理功能，stub状态 |
| 42 | Sandbox Preview 独立页面 | ✅ | ❌ | **P2** | SoulEditor Preview tab可替代 |

---

## 七、AI 辅助编辑（可视化管理页内嵌）

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 43 | AI Assist 面板（SoulEditor右侧聊天式） | ✅ | ⚠️ | **P1** | 已预留tab，需接入LLM调用 |
| 44 | AI Assist 面板（SkillEditor） | ✅ | ❌ | **P2** | Soul优先 |
| 45 | AI 快捷操作（优化语气/检查完整性/翻译/生成测试） | ✅ | ❌ | **P2** | 在AI Assist面板中实现 |
| 46 | AI Accept/Reject diff（显示修改建议+确认） | ✅ | ❌ | **P2** | AI交互核心UX |

---

## 八、Admin Session（会话式管理，新入口）

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 47 | Admin Agent Behavior | — | ❌ | **P2** | 新功能，接收自然语言→dispatch管理操作 |
| 48 | Admin Session LiveView（聊天界面+卡片渲染） | — | ❌ | **P2** | ChatUI复用 |
| 49 | 管理操作卡片渲染（CR Status Card/Publish Card等） | — | ❌ | **P2** | 独立组件复用 |
| 50 | 自然语言→管理操作意图解析 | — | ❌ | **P2** | 核心NL理解 |

---

## 九、其他功能

| # | 功能 | 旧版 | 当前 | 优先级 | 理由 |
|---|------|:--:|:--:|:--:|------|
| 51 | Sandbox Preview 独立页面 | ✅ | ❌ | **P2** | |
| 52 | Test Console（干运行测试） | ✅ | ❌ | **P3** | 独立子系统 |
| 53 | Gap Analysis（AI缺口分析） | ✅ | ❌ | **P3** | 独立子系统 |
| 54 | Response Settings（ACK/progress/filler prompt编辑） | ✅ | ❌ | **P3** | 独立子系统 |
| 55 | Dream Engine + Dream Scheduler | ✅ | ❌ | **P3** | 远期，另立项 |
| 56 | Proposal/Inbox 系统 | ✅ | ❌ | **P3** | 远期 |
| 57 | Canary（灰度发布） | ✅ | ❌ | **P3** | 远期 |
| 58 | Compliance Engine | ✅ | ❌ | **P3** | 远期 |
| 59 | Billing/SLA/Metrics | ✅ | ❌ | **P3** | 远期 |
| 60 | Management Chat（/命令式管理） | ✅ | ❌ | **P3** | Admin Session替代 |
| 61 | Master Platform/Industry/Templates Soul管理 | ✅ | ❌ | **P2** | Platform管理页面 |
| 62 | Master Skills管理（L0/L1/L2） | ✅ | ❌ | **P2** | Platform管理页面 |
| 63 | Glossary编辑器 | — | ✅ | — | Ezagent独有，已实现 |

---

## 优先级汇总

### P0 — 必须立即修复（4项）

| # | 功能 | 影响 |
|:--:|------|------|
| 1 | KB 文本 Chunking | 搜索不可用 |
| 10 | Sandbox Diff 计算 | CR 看不到变更 |
| 13 | 回滚恢复 Sandbox | 回滚无效 |
| 26 | Skill Frontmatter 解析 | Skill metadata不可编辑 |

### P1 — 应该尽快实现（14项）

| # | 功能 |
|:--:|------|
| 2 | PDF 语义提取 |
| 3 | XLSX 语义提取 |
| 4 | 异步 Ingest Jobs |
| 9 | FTS5 trigram CJK搜索 |
| 11 | Per-item Publish |
| 12 | Per-item Revert |
| 20 | ETag 并发控制（Soul/Slot） |
| 21 | Template Slot 验证 |
| 23 | Seed Endpoint 增强 |
| 25 | Composed Soul Preview 验证 |
| 27 | ETag 并发控制（Skill） |
| 28 | L0/L1 目录分离 |
| 32 | Lint Severity 分级 |
| 37-38 | InitWizard URL/Doc Upload 步骤 |
| 43 | AI Assist 面板（SoulEditor） |

### P2 — 可以后续实现（16项）

| # | 功能 |
|:--:|------|
| 5 | URL Crawler |
| 6-8 | KB Source 元数据/Schema/Flow |
| 14-19 | CR 完善（状态机/actor/manifest/lock/detail） |
| 22,24,29-30 | Soul/Skill 增强 |
| 41-42 | Operators/Sandbox Preview |
| 44-46 | AI Assist 扩展（Skill/快捷操作/diff accept） |
| 47-50 | Admin Session |
| 61-63 | Platform管理/Flow/Glossary |

### P3 — 远期/另立项（20项）

| # | 功能 |
|:--:|------|
| 31 | Skill AI Assist |
| 35-36 | Rehearsal/Compliance |
| 52-60 | Test Console/Gap Analysis/Response Settings/Dream/Proposal/Canary/Billing/SLA/Management Chat |
