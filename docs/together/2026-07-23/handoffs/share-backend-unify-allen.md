# Handoff（research/design，给 Allen）: 统一 share token —— 把 kanban.share_board 收敛到 read-plane 的 person-bound token 底座

> **Date:** 2026-07-23 · **From:** Sy Yao（lead）· **To:** Allen（read-plane 授权车道 owner）
> **Tracking:** 新独立 PR（待 Allen 建）· **Base:** `origin/main` @ `7e3ee6560`
> **Status:** clarify_first —— **命中 discuss-first 触发器（CapBAC/授权 + core + 你正在改的 read-plane 架构）**。这是**设计 handoff**：DoD 由你定，不是替你实现。

## 0. Mission
main 上有**两套平行的签名-token 分享机制**——这是"重复造轮子"：
- **通用**：`Ezagent.Uploads.DownloadToken`（core，你的 read-plane **PR-3**）—— person-bound（`:grantee` 必填）+ URI 绑定 + 短 TTL + mint-behind-chokepoint。**但硬锁在 `resource://<ws>/uploads/<name>`**，非 uploads URI 直接 raise。
- **kanban 专属**：分享一块**板**（agent/session URI，非 upload）用不了 DownloadToken，于是 `KanbanShareController` 自己一套 `Phoenix.Token`（`@share_board_salt "world_kanban_share"`）。

本任务的**方向**：把 person-bound token 底座**从 uploads-only 泛化到任意 target URI**，让 board-share / 附件 / 未来会话消息-share **都收敛到一个 token + 一个 mint chokepoint**，消掉 kanban 那套平行实现。**因为它动的正是你的 read-plane 授权 chokepoint 模型，所以交给你定设计，我们前端那边（`world-frontend-de-kanban.md`）绝不碰后端 token/authz。**

## 1. Required reading
1. Skill `ezagent-developer`、`ezagent-socialware`。
2. **你自己的** `docs/superpowers/plans/2026-07-19-read-plane-authz-chokepoint-plan.md`（**PR-3 = Attachment plane: person-bound DownloadToken**）+ `docs/superpowers/specs/2026-07-19-read-plane-authz-chokepoint-design.md` + `docs/together/2026-07-18/handoffs/read-plane-authz.md`。
3. `dev-together` skill —— handoff 标准。

## 2. 现状证据（file:line，已核）
- `apps/ezagent_core/lib/ezagent/uploads/download_token.ex`：`mint!(%URI{scheme:"resource"}=uri,...)` 只收 `resource://<ws>/uploads/<name>`，其它 raise；`:grantee` 必填（read-plane PR-3）；"minted only after authorization —— 本模块不授权，issuing chokepoint MUST authorize before mint!"。
- `apps/ezagent_web/lib/ezagent_web/controllers/socialware/kanban_share_controller.ex`：`@share_board_salt "world_kanban_share"` + `Phoenix.Token.verify`（平行第二套 token）。
- `apps/ezagent_web/lib/ezagent_web/socialware/kanban_published_read_adapter.ex`：`WorldActions.share_link` → `issue_receive_ref`（hello↔kanban 组合走 kanban 的 share 契约）。
- 底下的只读挂载 `Ezagent.Socialware.Mount`（"零 kanban 字面"）——**通用**，两套 share 都落在它上。

## 3. 待你裁的设计问题（这就是本 handoff 的产物 = 设计决策 + build slices + DoD）
1. **DownloadToken 泛化到非-uploads URI？** target URI 该开到哪些 scheme（`resource://.../uploads`、board=`entity://.../agent/*`、`session://...`、`message`?）。stable_key 绑定 + FsResolver 那套对非-uploads target 怎么处理。
2. **mint chokepoint 怎么授权一个 board/session share**？uploads 的 chokepoint 是 cap-gated read；board-share 的授权口径（板主人？成员？）在你 M-1（membership 收口 tier-1 cap）后怎么接。
3. **kanban.share_board 的归宿**：退化成通用 mint 的 caller（生 link 走通用 token），还是保留 kanban 侧 action、只换底层 signer？`KanbanShareController` 收链侧同样归并到通用 receive 控制器？（这跟前端解耦路线图 ⑥ 的 `kanban_share_controller` 泛化呼应。）
4. **person-binding 语义**：uploads 是「serve-time caller==grantee」；board-share 的接收方是**匿名/跨 session 拿链接的人**——person-bound 在 share 链接场景怎么定义（一次性铸给谁？）。
5. **是否借这次把「会话消息也能 share」一并纳入接口**（你之前提的横切能力），还是先只除 kanban 的重复轮子、消息 share 作后续。

## 4. 建议范围（你可推翻）
- **最小**：DownloadToken 泛化 + kanban.share_board 换用它（只除重复造轮子，share 产品形态不变）。
- **完整**：加通用 share 动作（如 `session.share <target>`），消息/其它插件都能用（碰 dispatch/授权面，更大）。

## 5. Definition of Done —— **由你（Allen）在设计落定后写**
本 handoff 是 `clarify_first`：交付物 = §3 的设计决策 + build slices + **你写的 DoD**（四性质：从契约枚举 · 带证据 · user-facing · closed）。占位约束（无论怎么设计都要满足）：
- [ ] main 上**只剩一套** person-bound share token（`git grep "@share_board_salt"` == ∅，kanban 那套 Phoenix.Token 删除）。
- [ ] 泄露 token 被非-grantee 重放 → 两条 serve 路径都拒（沿用 PR-3 acceptance）。
- [ ] 现有 kanban board-share e2e（分享 → 只读接收 → 数据回流）**行为不回归**。
- [ ] All gates + CI green + rebased on main。

## 6. Discuss-first vs Deferred
**Clarify-first：是**（本文件即研究/设计 handoff）。build handoff 待你的设计落定后再发。
**Never deferred**：授权 chokepoint 正确性、单 mint 收口不变式。

## 7. Conflict-avoidance
Owned：`download_token.ex`、`kanban_share_controller.ex`、`kanban_published_read_adapter.ex`、kanban share_board handler、通用 receive 控制器（新）。**与 Task A（world 前端）零重叠**（A 只碰 `.tsx`/manifest）。前端 A 保持 dispatch 现有 `kanban.share_board`，你后端归并时 action 名/签名若变，回头知会前端跟一次（小）。

## 8. Merge model
新任务分支（你建）；rebased on main；DoD（你写）满足后 lead 合 → main。

## 9. Open questions for lead（Sy）
- 范围取「最小」还是「完整」（§4）？消息 share 现在纳入还是后续？
- 这块要不要直接并进你 read-plane 5-PR 计划（作 PR-3 的延伸），而非另起？
