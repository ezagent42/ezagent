# Handoff：通用 socialware 分享/接收机制（设计讨论 → Allen 拍板）

- **类型**：`clarify_first` / 平台设计决策（不是 build 任务；要 Allen 定方向）
- **来源**：kanban 示范 plugin 重构（PR #1474）——重构时识别出的可泛化点
- **触发**：Sy（用户）—— "担心之后有别的数据宿主的 agent 分享之类的，我们必须要抽象一个通用机制，才能保证快速自举开发"

---

## 一句话

kanban 现在有一条**它专属的** web 分享落点（`/socialware/kanban/receive` + `KanbanShareController`）。将来任何**数据宿主类 agent**（不止 kanban）都会需要"发一个受控分享链接 → 别人点开 → 铸只读/操作钥匙给点击者"。**要不要现在抽象一个通用 `/socialware/:kind/receive` 机制**，让下一个数据宿主 plugin 零 web 代码就能分享？请 Allen 拍方向。

---

## 现状（实证，非猜测）

**已经通用的（"发钥匙"那半）**：
- `Ezagent.Socialware.CompositionCaps.mint_cap/4`（domain_session）—— 唯一 mint chokepoint，任何 plugin 都能用来铸实例精确 cap。
- 跨 workspace 守卫（`ShareReceive.ws_policy/3` 模式）可复用。

**还是 kanban 专属的（"web transport 落点"那半）**：
- 路由 `apps/ezagent_web/.../router.ex:278` `get "/socialware/kanban/receive"`。
- controller `KanbanShareController`：`Phoenix.Token.verify`（web 层职责）→ 调 `EzagentPluginKanban.ShareReceive.receive_shared_board/2` → 302 到深链。
- **三个 kanban 专属常量**散在两处，靠"两侧手动对齐"（改一处漏一处 → 静默 403）：
  - salt `"world_kanban_share"`（sign 侧 `world_share_actions.ex` + verify 侧 controller）
  - path `/socialware/kanban/receive`
  - behavior 字符串 `"Ezagent.ActionSet.Kanban"`（token payload 里，`Module.concat` 反解）

**现状不是 proliferation**：全库只有 kanban 一个 `_share_controller`，而且 **hello 分享看板是复用它**（`kanban_published_read_adapter` 产出的就是 `/socialware/kanban/receive?token=` 链接），不是各造一个。所以焦虑是**预防性**的，不是当下的痛。

---

## 为什么必须是通用机制（Sy 的论点）

数据宿主 agent 是 ezagent 的一等公民模式（kanban 只是第一个）。"发出去一个读写链接就等于发布消息"是**人本位数据资产的通用交互**，不该每加一个宿主 plugin 就在 `ezagent_web` 手写一个 controller + 一条路由 + 一套 salt 对齐。**快速自举** = 新 plugin 声明"我是可分享的数据宿主"就够，web transport 零改动。

浏览器直开（无 socket、进不了 world dispatch chokepoint）决定了**必须有一个 HTTP 落点**——问题不是"要不要落点"，而是"落点要不要 per-plugin"。

---

## 提议方向（供 Allen 评判，非既定方案）

通用 `/socialware/:kind/receive` + 一个 web 层 receiver 注册表：

1. **salt 统一**：`"socialware_share:" <> kind`（或 salt 里带 kind），消掉"两侧手动对齐"的静默 403 隐患。**低难度**。
2. **receiver 分派注册表**：`kind → receiver 模块`。web 层不能直接 compile-dep plugin，得走 **behaviour**（现成样板 = `EzagentPluginHello.KanbanPublishedRead` 已用的 behaviour 注入模式）。**主要工作量在这**，中难度。
3. **token payload 契约**：已经半通用（behavior 在 payload 里 `Module.concat` 反解），不是障碍。
4. **cap-mint / ws-policy**：已在 domain_session 通用，重活已完成。

难度评估：**低到中**。主要是抽一个 receiver-registry + 统一 salt 约定。

---

## 待 Allen 决策的问题

1. **现在做，还是等第二个真实用例？** 论据两面：
   - *现在做*：Sy 要的"快速自举"——下一个数据宿主 plugin 零 web 代码分享。
   - *等一等*：只有 1 个 controller、hello 已复用，过早抽象容易照 kanban 一家定型（错抽象比不抽象贵）。真出现第二个**语义不同**的分享落点时，才有足够差异设计对的抽象。
2. **归属哪条轨**？这跟 Allen 的 read-plane / share 后端统一车道（此前提过 handoff）是否是同一件事？
3. **本次 PR #1474 要不要顺手铺路**？低风险的两件：把 kanban 的 salt/path/behavior 三常量**收口成一处**（消静默 403 隐患）+ 把 receiver 分派做成 behaviour。即便通用机制推迟，这两步也让 kanban 示范更干净、且为将来通用化铺好路。**建议做**（除非 Allen 认为连这个也该等）。

---

## DoD（本 handoff 的完成 = 拿到 Allen 的方向）

- [ ] Allen 决定：现在抽通用机制 / 等第二用例 / 本 PR 只做三常量收口
- [ ] 若做通用：确定归属轨（独立 PR / 并入 read-plane 车道）+ receiver-registry 的 behaviour 契约草案
- [ ] 若推迟：在 kanban 示范里加一条注释指向本 handoff，标记"已知可泛化点"
