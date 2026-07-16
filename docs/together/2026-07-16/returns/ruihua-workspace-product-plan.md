# 企业自助开通 workspace 产品计划 · ruihua · 2026-07-16

**分支 / PR:** `docs/workspace-self-service-product-plan` → #1436（draft）· base `main`

## 我做了什么

基于 Allen 在 PR #1427 中的工程缺口清单（10 条缺口，分 P0/P1/P2 三级），逐条撰写了**用户旅程（happy path）+ 验收标准 + 优先级排序**。产出文件：`docs/plans/2026-07-16-workspace-self-service-product-plan.md`。

每条缺口包含：
- **现状**（用户现在遇到什么——从用户视角描述，不写代码位置）
- **Happy path 旅程**（Step 1 → Step N，每步 = 用户动作 + 系统响应）
- **验收标准**（逐条可验证，含冷启动实测视角）
- **情绪曲线**（痛点 → 解决后的状态）

## 和你的 UI 工作最相关的两段

### G6: UI 可读性（P1，第三批）

5 个痛点，每个都有 happy path 和验收标准：

| 痛点 | 现状 | 目标 |
|------|------|------|
| A — Agent 列表裸 UUID | 用户看到 `a1b2c3d4-...`，无法区分 agent | 显示 agent 名称 + flavor 中文标签 + 状态指示 |
| B — 首登 PAT interstitial | 注册后首登弹 PAT 管理，普通用户不理解 | PAT 移至 Settings → Developer，首登不弹 |
| C — Continue 落 404 | 登录后点 Continue 跳 404 死路 | 回到登录前页面，失效时回首页 + toast |
| D — 会话名校验矛盾 | 提示说支持中文，但纯中文名被拒 | 校验规则与提示文案一致 |
| E — 错误裸 atom 直出 | UI 显示 `:invalid_session_name` | 中文错误提示 + 建议操作 |

### G7: onboarding 向导 + gallery 缺失（P1，第三批）

注册后无引导 → 4 步向导（选模板 → 配 key → 发首条消息 → 了解 workspace），每步可跳过、可重访。world 侧边栏加「应用 Gallery」入口。

## 你可以怎么行动

1. **直接看产品计划**：`docs/plans/2026-07-16-workspace-self-service-product-plan.md` 的 §3，G6 和 G7 两段。每条 AC 都是可验证的——你可以逐条确认「这个能做吗 / 需要多少时间」。
2. **拿 G6 的 5 个痛点当 UI 问题清单起点**：06-26 的 FP5 inspection 之后没有更新过的 UI 清单——G6 的 A/B/C/D/E 可以作为当前优先级的起点。
3. **我们一起过一遍**：你过完文档后，我们可以飞书/电话对齐——定优先级、估时间、分哪些今天能动。

## 优先级排序说明

全 10 条按「用户冷启动能走到第几步」分 4 批。G6/G7 在第三批——核心价值链路（注册→配 key→agent 回复）通了之后才有打磨 UI 的意义。但如果 G6 里有低成本快赢（如错误提示去 atom 化、会话名校验修复），可以先做。

## 关联

- PR #1427（工程缺口清单 + 工程效率分析）
- 07-16 plan：ruihua track ① #1427 产品化 + ② 与 zyli UI 对齐
