# UI Review Gate — 各 surface 自查清单（提 PR 前自己跑）

> **From:** ruihua（designer） · **Date:** 2026-07-01
> **来源:** `docs/website-demo/design-ui-convergence.md`（设计收敛 gate）
> **性质:** 这不是"ruihua 逐个 review 你的 PR"，而是**把 gate 变成一份自查清单**——
> 每个 UI PR **提交前 owner 自己对着跑一遍**，把结果 + 截图贴进 PR，lead 据此合并。
> 卡壳/拿不准的设计问题再 @ruihua；日常达标靠自查，不靠我做瓶颈。

## 怎么用（每个 UI PR）
1. 提 PR 前，对照下面 **A 通用** + **B 你那条 surface** 逐项打勾。
2. PR 描述里贴：**自查结果**（哪几条过/不过）+ **before/after 截图**（plan 要求：UI PR 除 CI 外必须给截图和产品验收口径）。
3. 不过的项要么当条 PR 修掉，要么在 PR 里写明"为何暂缓 + 何时补"。
4. 只有设计判断拿不准（不是达标问题）才 @ruihua。

---

## A. 通用品牌层（所有 surface 一律过）

> 唯一权威源 = `ezagent-design-system` rev `ebce041`；一律引 token，不 hardcode、不猜色值。

- [ ] **动作色唯一钴蓝 `#0B5CFF`**；无第二动作色
- [ ] **绝不用渐变**
- [ ] 底=浅灰 `#E8E8EB` + 白卡 `#FFFFFF`（非纯白通铺）；发丝线 `#E2E2E6`
- [ ] 三原色/翠仅作**语义色**（红 `#D81830`/墨蓝 `#0048A8`/黄 `#FFD400`/翠 `#0FA06E`）
- [ ] 字体：Inter（拉丁）· Noto Serif SC（中文标题）· Noto Sans SC（中文 UI）· Space Mono（数据）
- [ ] 圆角/卡间距 22、柔性阴影、pill 控件
- [ ] 图标用 Lucide（几何 glyph）；**无 emoji 当图标**
- [ ] 文案双语 `中文 · English`；英文 UI = Sentence case；ALL-CAPS 只给 mono overline
- [ ] 深浅色切换（`data-theme="dark"`）不破对比度
- [ ] 你的 `tokens.css`/局部样式与上游对齐，没另立一套色值

## B. 逐 surface 自查

### B1. Website（zhaomato · T2）
- [ ] hero「组织的 IDE」+ **唯一钴蓝 CTA**
- [ ] world.cup **真 GitHub 数据**（不 mock）
- [ ] nav 全站一致 + 登录态切换 + 主题切换不破样式
- [ ] **诚实护栏**：数字只展真实可复算的
- [ ] hello ↔ backend/world 联通验证过（附 refresh 命令证据）
- [ ] 明确结论：是否可上线 `app.ezagent.chat`（须与 Allen/T6 协调）
- 对照记录：`docs/website-demo/v1/website-review-issues.md`

### B2. Hello builder（zhaomato · T2）
- [ ] 官网对话框 = **门户助手·导航式副驾**（切页面/滚动 + 短文字，非纯文字问答）
- [ ] grounding 锚三源：页面文案 + world.cup 真数据 + `team.md`；范围外 fallback（如定价→留资页）
- [ ] 只读官网：不生成/改/发布内容、无后台变更、无跨 session 读
- 见 §5.2 主题清单 + 留资页字段

### B3. World UI shell（zyli · T3）
- [ ] 往 **IM 三栏聊天式**收敛（Sessions·会话·详情），不再开宽泛重构
- [ ] 梳理并收起"不该给普通 IM 用户看"的后台元素（URI/routing/snapshot/authz 等）
- [ ] 壳 token 全用上游 design-system（无 hardcode）
- [ ] before/after 截图 + 对照 ruihua 方向 checklist（plan T3 DoD）

### B4. Agent Console → 招聘（fatnine · T4）
- [ ] **一条完整 prototype path**（不并行多 IA 分支）
- [ ] 端用户流程零技术感：描述角色 → **候选人 profile 卡** → Onboard；flavor/caps 藏「高级配置」
- [ ] 推荐路径：花名册空位（蓝）→ 发职位 → 应聘 → 录用（见 demo `docs/website-demo/vx/agent-hire-demo/`）
- [ ] Invite（人）与 招 agent 两个入口分清
- [ ] session delete/archive 按**设计问题**处理，未定语义不硬补按钮

### B5. Socialware / AutoService 客户页（gaga · T5）
- [ ] 客户侧生成页扣**同一通用品牌层**（A 段），与 world 的 dual-surface 差异是交互范式、不是品牌
- [ ] 窄修 UI/content gap，不改 core dispatch
- [ ] E2E transcript / 截图

---

## 达标线（DoD）
一个 UI PR 视为"过 gate"当且仅当：**A 段全过 + B 段你那条全过（或不过项写明缓修理由）+ 附 before/after 截图 + 一句产品验收口径（能否上线/差什么）**。CI 绿只是底线，不等于过 gate。
