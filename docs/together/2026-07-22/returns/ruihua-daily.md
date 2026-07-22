# 日报 · ruihua · 2026-07-22

**分支 / PR:** `docs/workspace-self-service-product-plan-v2` → 新 PR（待创建）· base `main`

## 今天做了什么 / 产出

### 信息协会 demo（#1499 已合入 main）

- `docs/website-demo/ciia/index.html` → `docs/rh/ciia-demo/demo/index.html`（v3→v4 迭代）
  - 从侧边栏导航改为 Carousel 卡片 + Bottom Sheet 的全屏架构
  - 6 个 socialware 内容填充（关于协会 / 入会申请 / 行业研究院 / 合作对接 / 会员专区 / 管理后台）
  - Session 全屏覆盖（固定动画：scale+blur→clear，450ms）
  - 登录 + 产品录入 + 产品详情 modal 完整接入
  - 部署到 http://100.64.0.17:8888/visual-tests/carousel-socialware.html
- `docs/rh/ciia-demo/platform-analysis.md` — 用户矩阵 / IA 树 / CIIA vs ezagent 边界表
- `docs/rh/ciia-demo/ciia-content-analysis.md` — CIIA 网站爬取 + Gap 分析 + 5 个洞察
- `docs/rh/ciia-demo/PORTABILITY.md` — 移植手册（下一个机构 18 项替换 + 6 步操作）
- `docs/rh/ciia-demo/page-flow.md` — 页面流 + 状态机 + 用户旅程
- `docs/rh/ciia-demo/dial-concept.md` — 拨号盘几何分析
- `docs/rh/ciia-demo/dial-prototype.html` / `carousel-sheet-demo.html` / `split-panel-prototype.html` — 交互原型
- `docs/together/2026-07-22/returns/ruihua-ciia-demo-v4.md` — 设计交付 return

### Signature Interaction 筛选标准（#1436）

- `docs/rh/ciia-demo/signature-interactions.md` — 从"组织即服务"产品价值出发，建立 Signature Interaction 筛选漏斗：
  - **A** · 我在和一个组织交互，不是一个软件（Agent 角色交接）
  - **C** · 这个组织在为我调动资源（Session 创建）
  - **D** · 我不是录入了一个产品，而是为这个组织创造了新的接口（产品录入成功）
  - **B** · 这个组织记得我（Session 回归，A/C 的记忆变体）
  - 明确排除了功能性交互（button hover / input focus 等），聚焦 2 个 P0 签名动效
- 已 rebase 到最新 main → 新分支 `docs/workspace-self-service-product-plan-v2`
- 提交到 PR #1436 分支 → 因旧分支落后 main 17 commits，新建 v2 分支 rebase 后 cherry-pick

### 全栈设计体系对照

- `~/Downloads/ezagent-fullstack-design-system.md` — 10 层设计体系对照表，每层 4 列（DS 已有 / CIIA demo 做了什么 / 还可以做什么）
  - 补充了 `ezagent42/design-system` 仓库的完整资产清单（7 文件 token × 20 组件 × 18 guidelines × 7 logo）
  - 当前完成度评估 + 4 周成长路线

## 设计决策

- **Session ≠ Socialware**：Session 是平台级通信原语，不属于任何一个 socialware。从侧边栏会员区分出，放在个人区作为全局收件箱
- **Sidebar → Carousel 架构迁移**：传统 SaaS 侧边栏 → 卡片轮播 + Bottom Sheet。后续目标：Hello Builder 对话式导航
- **Signature Interaction 筛选标准**：不以频率/差异化/情感为单轴，而从产品核心价值（"组织即服务"）出发——只有让用户感受到"组织在和我交互"的瞬间才值得签名级动效
- **Bento 设计语言 vs DS 对齐**：CIIA demo 自建了 Bento token（如 `r-card:20px`），与 DS 的 `r-lg:22px` 略有差异——W3 计划做对齐

## 下一步计划

- 等待 #1436 新 PR 创建 + lead 审阅
- Signature Interaction 原型制作（P0 的 Agent 角色交接 + Session 创建）
- CIIA demo 的 token 与 ezagent DS 对齐
- 企业自助开通 workspace 产品化（等 cap-signing + #1476 解卡后继续）

## 待办 / 阻塞

- 企业自助开通：等 cap-signing 实现 + #1476（zyli 插件 UI 分层）解卡
- #1436 旧分支有待提交的 returns 文件未迁移到 v2

## 关联

- PR #1499（信息协会 demo）— 已合入 main
- PR #1436（企业自助开通产品计划）— signature-interactions.md 提交至此分支 v2
- handoff: off-plan 设计工作（信息协会 demo + 全栈设计体系整理）
