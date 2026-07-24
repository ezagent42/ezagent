# dev-together plan —— 2026-07-23（W30）

**主题**：kanban ⇄ infra 解耦（愿景 = kanban 侵入 infra 全取消 / plugin 自包含 / sw 声明化）。今日切两块，边界已由「先调查再采信」定死（share 后端属 Allen 的 read-plane 授权车道，剥出去交他）。

**Base**：`origin/main` @ `7e3ee6560`。解耦全景 + 逐 PR 路线图见活版 skill-1（`project-discussion-esr-ng` §kanban⇄infra 解耦路线图）。

## 任务表

| # | 任务 | Dev | 类型 | 分支 | Owned surfaces | 冲突 |
|---|------|-----|------|------|----------------|------|
| A | **world 前端去 kanban**：tab 内插件渲染走 #1476 manifest，world SPA 不再直接 import 任何插件组件（含 share 按钮接线保持 dispatch 现有 `kanban.share_board`、world share-link 弹窗通用化）。**纯前端，后端零改动。** | cc/codex（或 Sy 自 dive）| build（fast path，#1476 设计内）| **并进 #1531** `worktree-world-native-render-registry` | `Conversation.tsx`、`Kanban.tsx`(仅 share 按钮/onShare)、`slots.manifest.json`、generated(只读) | 与 B 零文件重叠 |
| B | **统一 share token**：泛化 read-plane `DownloadToken` 到任意 target URI，收敛 kanban 那套平行 `Phoenix.Token`。**→ 给 Allen（他的授权车道）。** | **Allen** | **clarify_first（研究/设计）**——命中 CapBAC/core/活跃架构触发器 | 新分支（Allen 建） | `download_token.ex`、`kanban_share_controller.ex`、`kanban_published_read_adapter.ex`、share_board handler | 与 A 零重叠 |

## 合并序
A 先（前端，独立可合，并进 #1531）。B 是 Allen 的独立 read-plane 工作，节奏由他定；B 落定若改 `kanban.share_board` action 名/签名，回头知会前端跟一次（小）。

## 红线
- Task A **禁碰**任何 share 后端 token/authz（`kanban.share_board` handler、`DownloadToken`、`KanbanShareController`）—— 那是 Task B / Allen 的车道。
- 两个 PR 都走 dev-together：handoff → dive → return（CI green + rebased on main）→ lead close。

## Handoffs
- `handoffs/world-frontend-de-kanban.md`（Task A）
- `handoffs/share-backend-unify-allen.md`（Task B，给 Allen）
