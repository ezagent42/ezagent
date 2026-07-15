# 日报 · ruihua · 2026-07-15

**分支 / PR:** `docs/hire-value-chain-0706` → #1378 · `docs/dealscout-demo` → #1388 · base `main`

## 今天做了什么 / 产出

### ✅ #1378 rebase + 解冲突
- rebase 到最新 main，20 个 commit 无冲突，GitHub 显示 MERGEABLE
- 交 lead 合入

### ✅ #1388 DealScout 撮合原型续（大量迭代）

**交互模式重做：**
- 聊天式交互：初始对话框居中（hero state）→ 发送后对话框消失，底部固定栏出现
- AI 自动判断意图（找钱/项目/合伙人/退出），无需用户手动四选一
- 发送按钮内嵌到输入框右下角，消除不齐问题
- 右侧详情面板仅在用户选中结果后出现

**Mock 数据替换：**
- 从结构化名片改为互联网来源（TechCrunch / 36氪 / Bloomberg / LinkedIn / HuggingFace / 小红书 / CB Insights）
- 每条包含来源域名 + 标题链接 + 摘要文字 + 标签 + 匹配度

**细节修整：**
- 匹配度数字固定于卡片右上角
- 保存搜索的通知改红点数字（替代大标签，降噪）
- 返回按钮全部显式 `index.html`（file:// 兼容）
- 牵线接受后 → world-placeholder.html（参照 flywheel/world-step，列出 W-D1~W-D7 待建功能）

**文档维护：**
- `design-brief.md` 同步聊天式交互 + 互联网数据
- `page-flow.md` 补 dealscout 子页面流转
- `mainsite.html` 描述更新
- `gallery-data.js` tryUrl 修复 + 描述更新
- `service-blueprint.md` 完整服务蓝图（发现腿 / 撮合腿 / 证据链）

### ⬜ 尝试本地部署 hello（未完成）
- 本地跑起 ezagent server（PR #1312 + cherry-pick #1396）
- 发现 admin cross_workspace_denied → seed_hello 改到 system workspace
- PAT_PEPPER 环境变量缺失导致登录不持久
- LLM 对话回复未通（`claude_code` backend 路径/环境问题）
- 结论：需要 coordinator 协助或等 canary 部署

## 设计决策
- 聊天式交互 > 多步表单：DealScout 是"对话式发现"，用户在描述需求的过程中 AI 自动匹配，而非填表格
- 互联网来源数据 > 结构化名片：匹配结果来自爬虫抓取的外部链接，不是平台内的名片
- 红点数字 > 彩色标签：通知类信息不应抢占主流程注意力
- 名片/角色档案应该是独立的 socialware（`uses: ["hello"]`），与 recruit/dealscout 同级——存用户身份/行业/资源/需求，对外暴露公开面让 dealscout 读取。不是平台功能、也不是 plugin。独立 PR

## 下一步计划（必填）
- #1378 等 lead merge
- #1388 可 review merge——原型完整，后续迭代在后续 PR
- Profile socialware 独立 PR（P1）+ Notification plugin 调研（P2）+ Review 审核机制评估（P3）
- 等 W29 demo gaga 测试 → allen 验收 → 我接手从产品角度完善

## 待办 / 阻塞
- hello 本地部署未通 → 等 coordinator 协助或 canary 部署
- W29 demo 完善 → 等待 gaga/allen 前置

## 关联
- Plan 任务 ① #1378 rebase ✅ · ② #1388 续 ✅ · ③ demo 产品完善 ⏳
- #1378 / #1388 pending

---

## 下阶段规划（从今天工作中浮现的独立功能）

以下功能在 flywheel 原型中作为 mock 存在，但从架构角度应独立为 plugin 或 socialware：

### 1. Profile / 名片 — socialware

- **形式**：socialware（`uses: ["hello"]`）
- **理由**：用户产品——存身份/行业/资源/需求，对外暴露公开面。与 recruit/dealscout 同级，被其他 socialware 读取
- **优先级**：P1——dealscout 需要它来做更精准匹配

### 2. Notification / 通知 — plugin

- **形式**：plugin（提供推送/飞书/邮件/浏览器通知机制）
- **理由**：基础设施，多个 socialware 都需要——dealscout（新匹配通知）、kanban（任务分配通知）、hello（页面更新通知）。类比已有的 email plugin
- **优先级**：P2——dealscout 的 "保存搜索 → 新匹配通知" 链路需要

### 3. Review / 审核 — 待评估

- **形式**：待定（可能是 plugin 中的 recipe，也可能是独立 socialware）
- **背景**：W-G6 合规审核流程——发布到 Gallery 的产品需过审核后才能上架。当前 flywheel 原型中标记为待建
- **待评估**：审核是平台级机制（所有发布都走）还是 per-socialware 的流程（每个 socialware 有自己的审核标准）？是谁审——管理员人工审、AI 自动审、还是两者结合？
- **优先级**：P3——Gallery 货架本身还没建（W-G1），审核在 Gallery 之后
