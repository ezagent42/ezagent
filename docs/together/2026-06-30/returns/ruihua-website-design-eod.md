# Return: T4 官网设计 — ruihua 当日收尾（EOD）

> **Task:** T4 官网（ruihua 设计部分）—— 方向输入 unblock zhaomato + 官网优化方向梳理 + dogfooding 案例 demo
> **Branch:** `docs/website-0630`
> **PR:** https://github.com/ezagent42/ezagent/pull/1103 (draft)
> **Dev:** ruihua (designer)
> **returned_at:** 2026-06-30 (Tue) EOD
> **deadline:** 2026-06-30 19:00 +0800（T4）
> **deadline_status:** on_time
> **对接人:** zhaomato（官网框架落地）；lead（度量口径待提）

## What's done（今日全部交付）

1. **官网方向 return**（给 zhaomato）`docs/together/2026-06-30/returns/t4-ruihua-website-content.md`
   —— 栏目 / 内容优先级 / 交互方向 + hello↔backend/world 联通对接点 + ruihua follow-up list。
   群通知留档 `docs/together/2026-06-30/group-notification-t4.md`。
2. **官网优化方向与优先级 v1** `docs/website-demo/version/2026-06-30-website-roadmap-v1.md`
   —— grill 定稿：核心目标=dogfood-usable 产品、官网=次要门面「真实可信 > 花活」、锚点 A；
   Value/Effort 排序（P0 真实 hello 试玩 + "能用"叙事 / P1 真数据进度·团队·登录·品牌一致）；
   花活四件套（押注/驾照/成就/办公室）移出主站 + **阶段闸 G0–G3 上线时机**；
   新增 **P1★ dogfooding 效率成果**（依赖 G0、真实度量护栏）。
3. **UI/UX 体验审查清单 v1** `docs/website-demo/version/2026-06-30-website-uiux-audit-v1.md`
   —— ui-ux-pro-max 规则 + 逐文件审查：A 旅程断裂 / B 转化漏斗 / C a11y 细节，含 Value/Effort 修复顺序。
4. **dogfooding 效率度量口径 DRAFT** `docs/website-demo/version/dogfooding-metrics/metrics-spec-draft.md`
   —— X(用 ezagent 做研发,主) / Y(组织自举,辅) 两层、归因护栏、before/after 基线方案、待 Allen 拍板项。
   **🚧 未提 Allen**（内部敲定后再 promote 到 returns）。
5. **dogfooding 案例 demo**（`docs/website-demo/version/dogfooding-metrics/`）
   - `index.html` —— 原 `docs/website-demo/index.html` 忠实复制 + nav 加一个 Cases tab（仅此最小改动）
   - `cases.html` —— 飞书客户案例页 IA 版（横向锚点子导航，完整内容）
   - `cases-v2.html` —— 另一版：纵向左栏目录（主内容区内 sticky）+ 精简直白文案 + 点击跳转标题闪烁两次
   - `styles.css` —— 复用原 index.html 通用构件与样式（两页共享）
   - 数据:真实（git+dev-together 现算,标数据源/窗口:1.8× 吞吐 / 194 PR / 7 人 / 228 commits）+ 示例（待度量,明确标注）

## 关键决策（grill / ui-ux-pro-max 驱动）

- **IA:** 主菜单用 **Cases · 案例**（非 Industry/Solutions:过早/名不副实），dogfooding 为 case #1；首页保留精简 proof teaser（demo 中已撤回，按"忠实复制原首页+仅加 tab"重做）。
- **诚实护栏:** 官网可信度不超过产品成熟度；效率数字只展真实可复算的，弱基线用案例叙事不编。
- **分支:** 原 `docs/website-demo` 陈旧未 rebase（直接开 PR 会回退 #1083/specs ~5000 行），故新开 `docs/website-0630`（基于最新 main），只搬运官网内容。

## DoD reconciliation

| # | DoD 行 | 状态 | 证据 |
|---|--------|------|------|
| 1 | 给 zhaomato 官网栏目/内容/交互方向，unblock 框架上线 | met | `returns/t4-ruihua-website-content.md` §1–§3 |
| 2 | ruihua follow-up list | met | 同上 §4 + roadmap v1 |
| 3 | 风格/栏目与 app 一致 | met | demo 复用 #1083 FP4 token / ezagent-design-system |
| 4 | 官网优化方向梳理 + 优先级 | met | `version/2026-06-30-website-roadmap-v1.md` |
| 5 | dogfooding 效率成果可视化 demo | met | `version/dogfooding-metrics/`（index + cases + cases-v2） |
| 6 | 度量口径可提 Allen | deferred | DRAFT 已成型,**待内部敲定后 promote**（lead 流程决策,见 spec §7） |

**Method friction:**
- 今日 handoff 文件（`t4-ruihua-website-content.md`）在 lead 发 plan.html 时尚未落库，据 plan.html task/DoD 直接产出；建议 handoff 与 plan 同步 push，避免据图猜。
- `docs/website-demo` 长分支陈旧未 rebase，险些回退团队工作；建议官网类长分支定期 rebase on main（写进 contributing 红线？）。
- cases 页视觉迭代了多轮（首页变体→Cases 专页→飞书 IA→纵向目录+精简）；**建议先确认 IA/信息架构再做视觉**，可省往返。

## Gate status

- 分支 `docs/website-0630` @ origin（已同步）；PR #1103 **draft**（lead 经 close 合并；ruihua 不自合/不自标 ready）。
- 内容均为 `docs/`（设计/文档/静态 demo），无 core/app 代码改动，不触发 CI 不变式。

## 待续 / open

- [ ] 明天:P0-2 hero「能用」终稿文案（双语，锚点 A）。
- [ ] 度量草案内部敲定（指标三选 + 纳入边界）→ promote 到 returns 提 Allen。
- [ ] cases v1 / v2 二选一定稿，删另一版。
- [ ] 真站点 `docs/website-demo/index.html` 加 Cases 菜单 —— 属 zhaomato 框架落地，ruihua 出方向不改主站代码。
