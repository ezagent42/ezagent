# 官网 UI/UX 体验审查与优化清单 v1

> **日期:** 2026-06-30 · **作者:** ruihua (designer) · **状态:** v1（审查定稿）
> **方法:** ui-ux-pro-max 规则库（§1 Accessibility → §10 Charts，priority 1–10）+ 逐文件代码审查
> **范围:** `docs/website-demo/` 静态站全量页面（index / driver-license / achievement-center / login + site-nav.js / demo-state.js）
> **关联:** 内容/优先级见同目录 `2026-06-30-website-roadmap-v1.md`（那份管"做什么内容"，本份管"体验怎么落地"）

---

## 0. 整体判断

骨架健康，问题不在"坏"，而在"polished 的外观"与"顺滑的漏斗"之间的差距。

**已经做对的（不要回退）:**
- 语义化设计 token + 成对的 light/dark 变体（非反相）
- 全站 `prefers-reduced-motion` 降级
- 纯 SVG 图标，零 emoji 当结构图标
- `.btn` 有 `:focus-visible`、表单有 `<label>`、modal 有遮罩+×关闭
- localStorage 跨页状态机（驾照 ↔ 成就中心单一 schema 源 `demo-state.js`）

**问题集中三类:** (A) 跨页旅程断裂 · (B) 转化漏斗发现性 · (C) a11y/对比度细节。

---

## A. 旅程级断裂（最高优先 — "官网体验"核心）

### A1. 主题不持久化 → 每次跨页被打回浅色 ★最高性价比
- **现象:** `index.html:431` 与 `site-nav.js:57` 的主题切换只改 `data-theme`，**未写 localStorage、未读 `prefers-color-scheme`**。介绍页切暗色 → 进 driver-license / achievement-center / login → 全部变回浅色。
- **为何重要:** 一个认真做了暗色模式的站，体验上却从不连续；§4 `dark-mode-pairing` 形同虚设。
- **修:** `EZD` 加 `theme()/setTheme()`；各页 `<head>` 顶部内联一行在首屏渲染前套用主题（避免暗色闪白 FOUC）。

### A2. 计划中的"介绍页 hero 钩子卡"从未实现 ★漏斗断点
- **现象:** `用户旅程方案-驾照与成就中心.md` 写明 3 入口含「介绍页 hero 下钩子卡」，但 `index.html` intro 面板（`:320-380`）**无任何指向驾照测试的入口**——hookline 仅在 worldcup 面板（`:389`）。首屏访客只能靠右下角 **~10 秒后自动缩成 62px 小球**（`:706 collapse()`）的浮卡发现核心互动。
- **为何重要:** 介绍页是流量入口，核心转化钩子被藏起来。
- **修:** hero `.cta`(`:328`) 下补一张 hookline 卡（复用 worldcup 样式），文案统一「测测你能同时指挥几个 agent？」。

### A3. 介绍页首屏零社会证明
- **现象:** 驾照页有「已 4,127 人测过」(`driver-license.html:151`)、团队页有真人办公室，但 **hero 一个信任锚点都没有**（GitHub stars / contributors / 已测人数）。
- **为何重要:** 落地页规律 = social proof before CTA；开源开发者工具首屏信任锚点关键。
- **修:** hero badge 区或 foundation 条加一行轻量证明（"N contributors · M 人已测段位 · ⭐ GitHub"）。**护栏:数字真实**（对齐 roadmap "真实可信 > demo 花活"）。

---

## B. 转化与反馈（§8 Forms / §4 Primary-action）

### B1. 结果页 CTA 过载
- **现象:** `driver-license.html:187-205` 一屏 6 个动作（看成就 / 复制 / 保存 / 去投票 / 看产品 / 重测）。主 CTA 明确（✓ 看全部成就），但密度稀释了它。
- **修:** softcta 两个 ghost 按钮折叠或降一级；保持"一屏一个主 CTA"。

### B2. 表单错误只用 toast、不在字段旁
- **现象:** Profile / Feedback 校验失败走 `toast('填一下职业')`(`achievement-center.html:218,225`)，违反 §8 `error-placement`（错误应在相关字段下方）；toast 也无 `aria-live`，读屏收不到（`toast-accessibility`）。
- **修:** 字段下方渲染 inline error；toast 容器加 `role="status"` / `aria-live="polite"`。

### B3. Modal 缺逃生与焦点管理
- **现象:** `achievement-center.html:208` modal 可点遮罩/× 关闭 ✓，但**无 Esc 键、无焦点移入、无焦点陷阱、关闭后焦点不归还**。
- **为何重要:** §1 `escape-routes`（critical）+ `focus-management`。
- **修:** 加 Esc 监听、打开时移焦到首字段、关闭时焦点归还触发元素。

---

## C. 视觉 / a11y 细节（§1 §6）

### C1. `--ink-3 (#8A8A92)` 在浅底 `#E8E8EB` 上 ≈ 2.8:1，未过 AA
- **现象:** 大量 11–12px 小字微文案用它：`.over` 标签、`.tc-meta`、`.pnum`、footer、`.meta`。对比 `--ink-2 (#56565E)` ≈ 5.9:1（达标）。
- **为何重要:** §1 `color-contrast` / §6 `color-accessible-pairs`，小字正是最该达标 4.5:1 的。
- **修:** 小字微文案 ink-3 → ink-2，或把 ink-3 调深到 ~`#6C6C74`。

### C2. 键盘焦点环覆盖不全
- **现象:** `.btn` 有 `:focus-visible`(`index.html:125`)，但 `.opt`(测验选项)、`.tab`、`.vote`、`.fn-row`、`.how` 只有 `:hover` 态。
- **为何重要:** §1 `focus-states`（High）；键盘/读屏用户做完整测验时看不到停在哪。
- **修:** 给所有可交互元素补 `:focus-visible{box-shadow:0 0 0 3px var(--focus-ring)}`。

### C3. 测验换题不移焦、不通报
- **现象:** `show()`/`renderQ()`(`driver-license.html:274,279`) 切 section 后只 `scrollTo(0,0)`，未移焦、无 aria-live。
- **修:** 换题后把焦点移到题目标题（`tabindex="-1"`）；进度区 `aria-live="polite"`。

### C4. nav logo 是 542KB PNG
- **现象:** `ezagent-logo.png` 在 nav 只渲染 26px 高，文件却 **542KB**（实测）；每页首屏都加载。
- **为何重要:** §3 `image-optimization`，纯性能浪费。
- **修:** 导出 ~2KB SVG 或 ≤10KB 2x PNG（dark 版仅 45KB，可参照重导）。

---

## D. 修复顺序（Value/Effort）

| 优先 | 项 | 工作量 | 体验增益 |
|---|---|---|---|
| 🔴 P0 | A1 主题持久化 · A2 hero 钩子卡 · C4 logo 瘦身 | 各 <30min | 高（连续性 + 发现性 + 性能） |
| 🟠 P1 | C1 对比度 · C2 焦点环 · B3 modal Esc/焦点 | 小 | 高（合规 + 可用） |
| 🟡 P2 | A3 社会证明 · B1 CTA 收敛 · B2 字段内错误 | 中 | 中（转化） |
| ⚪ P3 | C3 换题通报 · 移动端 nav 拥挤复核 | 中 | 中（a11y / 窄屏） |

**推荐执行:** 先打 P0 三件（低风险、改动小、增益大）→ P1 合规批 → P2 转化批。

---

## E. 与内容 roadmap 的边界

- 本份 = **执行层 UI/UX 缺陷**（怎么落地体验）。
- `2026-06-30-website-roadmap-v1.md` = **内容/优先级层**（做什么、上线时机、阶段闸）。
- 交叉点: A3 社会证明 ⊂ roadmap P1★ dogfooding 证据；C1/C2 ⊂ roadmap P1-4 品牌一致性+响应式。本份给后者的可执行 checklist。

---

## F. 待办（建卡后逐张推进）

> 按 kanban-first：上述 A–C 各条应落 `.devtool/features/` 单卡，带验收点（对比度过 4.5:1 / 焦点环可见 / Esc 可关 / 主题跨页保持 / logo ≤10KB）。

- [ ] 把 A1–C4 拆成 kanban 卡（P0/P1/P2/P3 分级）
- [ ] P0 三件先做：主题持久化 + hero 钩子卡 + logo 瘦身
- [ ] P1 a11y 合规批：对比度 + 焦点环 + modal 焦点管理
