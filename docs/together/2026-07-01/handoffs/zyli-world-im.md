# Handoff → zyli（李震宇） · World UI 向 IM 收敛

> **From:** ruihua（designer） · **Date:** 2026-07-01
> **Ladder:** lead 2026-07-01「产品形态收口」问①——World UI 改动，目标像 IM、不像后台管理平台
> **权威文档:** `docs/website-demo/design-ui-convergence.md`

## 先读文档这几段

1. **§1③ World UI** —— 定义 + **方向变更（lead 定调）**：当前生产版（nightly.ezagent.chat）不够像聊天软件，最新方向 = **IM 三栏聊天式**。
2. **§3 各面差异表** —— world 行：交互范式 = IM 三栏（Sessions·会话·详情），版式骨架 Chat/Agents/Manage + New chat。
3. **§4 逐面 P0** —— world 今日方向：往 IM 三栏收敛 + 壳套上游 token。
4. **§5.1 World UI（with zyli）** —— 我们已对齐的方向记录。
5. **§2 共通** —— 品牌唯一权威源 `ezagent-design-system`（rev `ebce041`），world 壳的 token 以它为准。

## 你要做什么（延续我们已沟通的方向）

1. **梳理"当前页面中不该给普通 IM 用户展示的东西"** —— 后台/运维味重的元素（URI、routing 内部、snapshot、authz audit 等）哪些对普通 IM 用户是噪声。
2. **优化这些表达** —— 该隐藏的收进高级/管理入口，该改说法的换成聊天软件的说法（像 Slack/Telegram，不像控制台）。
3. **IM 三栏聊天式** —— 你最新原型 `docs/together/2026-06-30/evidence/world-ui-im-refactor-live/`（22-chat-default / 25-conversation / 30-mobile-chat）已基本做到，**请对照收敛方向自查一遍**是否还有不够像 IM 的地方。
4. **品牌对齐** —— 壳的 token 已大体对上，**请检查**是否全部用上游 design-system（钴蓝唯一动作色、白卡浅灰底、禁渐变、Noto/Inter 字体），有 hardcode 的换成 token。

## 请回给我什么
- "不该给普通 IM 用户看的元素"梳理清单 + 各自的优化方式。
- 若大家看 OK → 按 lead 指示先实施合并（with zyli）；截图更新后指给我，我据此收敛 §1③/§3。

## 关联
- lead 已和你沟通 world 修改方向（本 handoff 是把它落进收敛文档）
- 你昨天的 IM 重构截图 = `world-ui-im-refactor-live/`（AUDIT.md 有覆盖说明）
