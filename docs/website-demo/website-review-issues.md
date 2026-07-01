# 官网评审问题记录 — ruihua review zhaomato Website

> **Reviewer:** ruihua（designer） · **Date:** 2026-07-01
> **被评审:** zhaomato Website / Hello（#1107 已合 + T2 `feat/website-hello-ruihua-0701`）
> **评审依据（gate）:** `docs/website-demo/design-ui-convergence.md` §2 共通品牌层 / §3 差异 / §4 Website P0
> **角色:** T1 DoD「其他 UI PR 以此作为 review gate」——本文件是 Website 一侧的 gate 落地记录。

## 怎么打开对照看
- **zhaomato 实现（真渲染）:** `http://localhost:10042/socialware/chat?session_uri=session://system/hello/site`（需 `:10042` 栈）
- **ruihua 设计参照（静态）:** `docs/website-demo/v1/index.html`（`python3 -m http.server`）
- **zhaomato 截图存证:** `docs/together/2026-07-01/evidence/`（截图往这放，问题编号对应）

## 评审对照清单（gate 关键项，逐条核）
- [ ] 动作色**唯一钴蓝 `#0B5CFF`**，无第二动作色、**无渐变**
- [ ] 浅灰底 `#E8E8EB` + 白卡，非纯白通铺
- [ ] 字体 Noto Serif SC(标题)/Noto Sans SC + Inter(正文)/Space Mono(数据)
- [ ] 圆角/卡间距 22、柔性阴影、pill 控件
- [ ] world.cup **真 GitHub 数据**（非 mock）
- [ ] nav 全站一致 + 登录态切换 + 主题切换不破样式
- [ ] 双语 `中文 · English`、英文 Sentence case、**无 emoji**
- [ ] hero「组织的 IDE」+ 唯一钴蓝 CTA
- [ ] 官网 `tokens.css` 与上游 design-system 对齐（不另立标准）

## 问题记录

| # | 严重度 | 位置/页面 | 问题描述 | 违反的 gate 规则 | 建议修法 | 证据 | 状态 |
|---|---|---|---|---|---|---|---|
| W1 | 🔴 | 全站 nav / hero | **logo 不对** | A · logo / 品牌 | 换成 `github.com/ezagent42/design-system/tree/main` **最新 demo** 里的 logo | | 待提 zhaomato |
| W2 | 🟠 | 首页 | 「研发进度与公开路线图」+「核心团队」现在是**首页的两个 section** | §3/§4 · IA | **做成 tab**：`world.cup`（研发进度）/ `团队`——参考 `v1/index.html` 的三页 tab 结构，不放首页平铺 | | 待提 zhaomato |
| W3 | 🟠 | hero CTA | 点「开始使用」按钮无正确跳转 | §4 · 导航一致 | 点「开始使用」→ **进 GitHub**（与右上角 github 按钮同效） | | 待提 zhaomato |
| W4 | 🟠 | hero CTA | 点「看看进度」无正确跳转 | §4 · 导航一致 | 点「看看进度」→ **进 `world.cup` tab**（研发进度与公开路线图） | | 待提 zhaomato |
| W5 | 🟠 | 全站底部 | 底部对话框**遮挡了部分页面底部内容** | UX · 可读性 / 布局 | 页面底部预留对话框高度的 padding，确保底部内容不被遮挡 | | 待提 zhaomato |
| W6 | 🟠 | 登录流程 | 从官网**登录后进入了 world**，而不是回到官网继续浏览 | UX · 流程 | 登录后应**返回官网继续浏览**（而非跳进 world 操作台） | | ⚠️ **非 zhaomato 可改**（world/app 侧登录后跳转，需 zyli/lead 协调） |

> 严重度：🔴 阻塞上线 / 🟠 影响体验 / 🟡 打磨项。状态：待确认 / 已提 zhaomato / 修复中 / 已修 / 搁置。

## 小结（评审结论）
- 〔看完后填：整体是否达 gate、几个 🔴 阻塞、是否可上线 app.ezagent.chat〕
