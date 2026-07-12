# 分析记录 — socialware 数据跨 session 共享 + 授权（深挖 + 弯路 + 结论）

> **日期**：2026-07-12 · **记录人**：jjkysy 席位 agent · **状态**：讨论中，未实施（board 先不改）
> **用途**：本次 session 过长需重启，本文档保存完整分析脉络，让新 session / Allen 能接着讨论，不用重查。
> **配套**：给 Allen 的结论见同目录 `../handoffs/socialware-data-mount-model.md`。

---

## 0. 一句话

kanban / crawler 这类"管一份数据的 agent"，现在把**数据焊在 agent 自己身上**（Decision #155）。当需求变成"另一个 session 的 AI 助手也来操作同一份数据"时，就撞墙了。我们绕了好几圈补丁，最后回到一个更简单统一的模型：**把"操作数据的 agent"像 U 盘一样挂载（mount）进一个房间（session），房间里的人就能操作它——前提是过权限检查**。数据仍在 agent 身上（#155 不动），公开则复用 hello 现成的匿名机制。

---

## 1. 怎么撞出这个讨论

在做 kanban 的 `DispatchVerbKanbanTest`（证明"assistant 持 board-scoped cap → 能 dispatch 到 board / 越权被拒"）时，发现一个更根本的问题：**kanban assistant 根本没有指向 board 的 cap，也没有任何机制给它**。往上追，发现这是 dealscout、autoservice、hello 共同的兜底缺口，而且比我原来 #1355 handoff 说的更深。用户由此发起从架构层重新想。

---

## 2. 坐实的事实（带出处，新 session 别重查）

### 2.1 CapBAC Phase 3 已落 main（和本问题正交）
- main 落了一串 "cap self-store" commit（`dec0bc134..fa72d36ba`），把发 cap 从"发行方直接写被授方数据"改成 **ISSUE → STORE → VERIFY**，加了不变量 **I12 `cap_self_store_paradigm_lock`**。权威文档 = `.claude/skills/ezagent-developer/references/capbac.md` §4.5。
- **关键**：它改的是"cap 怎么存/防伪造"，**不是"cap 指向谁"**——跟我们要解决的"数据跨 session 共享"是**两条正交轴**。
- **硬约束**：今后任何授 cap 必须走 `Cap.issue`+`absorb`（COLD 走 `RecipeCapBinding` 自存 / LIVE 走 `Identity.absorb_cap`），老写法（`Identity.Grant` / `mode: :call` / `await_ready` 后 grant / 直接写别人 `{:set,:caps}`）撞 I12 CI 红。团队 handoff：`docs/together/2026-07-12/handoffs/cbac-done-right-landed.md`。

### 2.2 #1355 / #1357 是什么
- **#1355**（我开的 handoff，PR open，分支 `docs/authz-composition-cap-gap`）：报"socialware 缺'组合关系→成员级窄 cap'通用授权车道"。文件 `docs/together/2026-07-11/handoffs/socialware-composition-cap-gap.md`。
- **#1357**（Allen 把 #1355 写成的 SPEC，PR open，分支 `docs/socialware-composition-cap-lane`）：文件 `git show origin/docs/socialware-composition-cap-lane:docs/specs/2026-07-12-socialware-composition-cap-lane.md`。方案 = 加 `operates` 声明 + `Cap.issue({:rule,:socialware_composition,owner})` + absorb。

### 2.3 #1357 覆盖不到 kanban board（关键）
- `operates` 的 target 只能是**同一 Definition 里、且本 session 物化成成员**的角色名（SPEC §3.1、§8 "Reject any operates.role not present in roles"）。
- `role_name_to_uri`（`apps/ezagent_domain_session/lib/ezagent/behavior/session/members.ex:84-108`）**只在本 session 成员 map 里找**。
- 但 kanban board 是**workspace 级、不进任何 session 成员边**的独立 actor → operates **解析不到它**。
- #1357 对这个更广场景的唯一答复 = "把 board 改成 Definition 里的 role slot"（§5决策3/§9 PR-3）—— 但那样**每 session 各物化一份 board**，丢掉"workspace 共享单板"语义，**跟 kanban 现行 S2 决策直接冲突**。

### 2.4 S2 决策不权威，可重开
- "S2 fix"（board 不进 role slot、留 workspace 级）是 **jjkysy 2026-07-08 写的**（commit `cd7f5a599`, #1248），`manifest.yaml:15-18`。
- **不在 GLOSSARY Decision Log、未经 Allen grill**，是实施期"自包含取舍"（只碰 kanban plugin + config，刻意不动平台）。源：`docs/together/2026-07-05/handoffs/kanban/spec.md` "S2 建模修正"。
- **结论：S2 可以正当重开**，它不构成"禁止 board 进群"的权威约束。

### 2.5 RF-6 是权威安全门，不能破
- passive-join gate：`session.ex:787` 返回 `{:passive_actor_cannot_join}`；`passive_actor?/1` `session.ex:836`。
- 关闭 **principal 泄漏**（把 chat 投递给 passive 数据 actor = 白得 `:receive` cap）。是 Allen grill 过、关闭 codex HIGH-C 的。`role-foundation-plan.md:50`。**必须守。**

### 2.6 成员模型 + "进群≠授权"现状
- 成员 = 成员 map 里的一个 `member_uri`（URI 引用）。**单实例可进多群**平台已支持：`:reuse` install-mode（`definition_agents.ex:332`）接受 `reuse_agent_uri`、不 spawn、直接 add_participant。
- **但**：published Definition **不能声明** reuse（role_slot 无 reuse 字段 + #1180 `reject_participant_instance_uris` `definition.ex:85,328-366`）；只能运行时经 editor/orchestrator。
- **且**：reuse 也过 passive gate → **带不进 passive board**。
- **且**：今天 join 只给**加入者本人**一个 within-session cap（`definition_agents.ex:451`），**不会**把宿主数据 cap 发给群里其它成员 → "进群=授权"**当前没接线**。

### 2.7 Decision #155 = 复杂度的根
- 业务运行态数据 → per-instance L3 snapshot slice = SoT。ARCHITECTURE §6.0 四层 taxonomy。大 blob 才走 L4 文件 + `resource://` ref。
- **结构化业务数据（board tree）明确属于 L3 = 焊在 agent 上**。"数据独立于 operator 被多方共享"与 #155 直接冲突。
- **但 upload 本身就是 #155 的已存在例外**（见 2.9）。

### 2.8 kanban-as-a-role 最初怎么想的（考古 1）
- Decision #127。board = `kanban-manager` agent × `native` flavor，数据在 agent 的 `:kanban` slice。源：`docs/together/2026-07-05/handoffs/kanban/spec.md`。
- 当初理由：**消掉一个独立 Kind + 复用 RF-1 per-instance 行为挂载 + RF-8 native 通用宿主 + snapshot/rehydrate**。
- **在"board 只被 world UI 里的人类操作"的前提下，这是对的、干净的简化**。
- **但"数据独立于操作它的 agent"这条路当初从没被摆上桌**——问题被框成"board 该不该是独立 Kind"（答"收进 agent"），而非"数据该不该独立于 operator"。#155 又把"数据焊 agent"立成原则，制度性排除了这条路。
- **复杂度不是 kanban-as-role 造成的（那步对）**，是**后来 socialware 要"跨 session 操作同一份数据"时撞上了 #155**。

### 2.9 upload/download 是"数据独立"的现成样板（考古 2）
- `Ezagent.Entity.Uploads`（`apps/ezagent_domain_uploads/lib/ezagent/entity/uploads.ex`），URI `uploads://<ws>/<id>`，**workspace 级独立 Kind**，数据在它自己的 `:blobs` slice，**不焊任何 agent/session**。
- 授权 = 签名 grant token（`Phoenix.Token`，salt `"world_attach"`，TTL 86400）+ CapBAC。
- **天然跨 session 复用**：URI 引用 + cap，数据一份多处引用（`kanban_actions.ex:261-262` 注释明说"kanban 节点是资源、非会话绑定"）。
- 公开 = 签名 download href（per-blob 可过期）——**"公开链接=签名授权"的现成先例**。
- **关键差异**：upload blob 是**静态 immutable**；board 是**可变 + 有行为**（20 个 mutation + 并发 + per-node owner + 不变式）。所以 board 若独立成资源，它仍要是"有行为的 Kind"，不能是纯 blob。

### 2.10 hello 公开机制（"公开链接 cap"的参考）
- `visibility_policy`（`scope` / `publish_policy` / `web_anon_access`）在 manifest 声明。运行时 `Installation.web_anon_access?/1`（`installation.ex:275`）。
- **匿名访问 = anon-User + instance-scoped render-cap**（`anon_view_caps/1` `installation.ex:305`，形态 `cap(:session, view_module, action, instance, workspace)`，granter=owner，#154）。**这已经就是"公开访问是一种 cap"**。
- 两层门：粗 `web_anon_access` 开关 + 细 per-view render cap。
- **差距**：hello 的"分享链接"只是 chat 里一行**裸 URL**（`hello_sharer.ex:38`），无 token/无过期/无 per-link 撤销。授权粒度停在"整个 session 公开与否"。

### 2.11 kanban assistant→board 现状（缺口实证）
- board discovery = `list_by_recipe("kanban-manager", ws)`（`kanban_render.ex`），workspace 级枚举，**读跨 session 可用**。
- assistant skill 里 `BOARD_URI` = **硬编码占位** `"entity://system/agent/loop-board-r2"`（`kanban_dispatch.exs:13`），**零生产注入**。
- assistant recipe system_prompt（`application.ex:162-166`）明写"owner 建了口头告诉你 URI、你持有 cap"——**但 assistant 并不真持有指向 board 的 cap**（物化只给 self-scope）。这就是缺口。

---

## 3. 走过的弯路（记录下来，别重走）

1. **以为 CapBAC Phase 3 解决了 #1355** → 错。它是正交轴（改"cap 怎么存"不是"cap 指向谁"）。发现方式：读 commit diff + capbac.md §4.5。

2. **接受调查报告的"imperative Step A"（world 建 board 后授 assistant）** → 站不住。因为 board↔assistant 无声明关联、BOARD_URI 是硬编码占位、world 建 board 时场景里根本没有 assistant。

3. **把问题框成 A/B 二选一**（A=每 session 一份 board / B=workspace 通用可读共享）→ 用户纠正：A 丢共享、B 的"workspace 通用可读"违反 CBAC（数据不该通用可读）。

4. **提了一堆越加越复杂的机制**：external-actor 车道 → data-member 非-principal 进群车道 → link-token 层。**每一步都是在给"数据焊 agent（#155）"这个前提打补丁。**

5. **用户踩刹车"越来越复杂"** → 回头考古（kanban-as-role 最初意图 + upload 机制），发现 #155 是根、upload 是现成的更简单样板。

6. **一度想走"路 B"（把 board 数据抽成独立 Kind `kanbandata://`）** → 被用户的"挂载 agent 本身"超越：不用抽新 Kind、不用迁数据、#155 不动，直接把"操作数据的 agent"挂进房间。更简单。

**教训**：复杂度的根不在表层机制，在 **Decision #155"数据焊 agent"** 撞上"跨 session 操作同一份数据"。不解决根，任何表层补丁都会越加越复杂。

---

## 4. 当前结论：mount（挂载）模型

**把"操作数据的 agent"像 U 盘/硬盘分区一样挂载进房间（session）。**

- kanban / crawler 等 = **管一份数据的 agent**，数据在自己 slice（**#155 不动，不抽新 Kind、不迁数据**）。
- **mount(agent, room, permission)**：把这个 agent 挂进一个房间。房间里的人就能操作它——**过权限检查**。
- 一个招式统一三件事：
  - **自己团队操作** = 挂进团队房间，permission=operate。
  - **借给别的团队** = 同一个 agent 也挂进另一个房间（Unix bind-mount：一份数据、多个挂载点）。
  - **对外公开** = 挂进"陌生人也能进"的房间（`web_anon_access:true`），permission=read → 复用 hello 匿名 render cap。

**为什么这是目前最好的**：复用"房间（session）"这个系统里已有的共享+可见性+成员单元，不重新发明；#155 不动；把三种共享收成一个概念。

### 4.1 两条铁律 / 待定

- **★铁律：mount ≠ 进群聊天。** 挂进来的 agent 是"被操作的工具"，不是"聊天成员"。房间要分两轴：**聊天成员** 和 **挂载的工具**。只要 mount 不是"join 聊天"，就永远不触发 RF-6（没人 join 聊天路径）。搞混就塌回成员语义之争。

- **★给 Allen 的选择题：房间成员怎么获得"操作挂载 agent"的权限**：
  - **做法 (a) 用的时候临时查**：授权点（`runtime.ex` step 5.5）加一条判定——"caller 是房间 R 的成员 AND 目标 agent 挂载在 R 且权限≥所需"。像 Unix 开文件时查挂载表 + 权限。生命周期最干净（卸载=删一条记录，权限立即消失），但**动最核心最敏感的授权代码**。
  - **做法 (b) 挂载时发钥匙**：挂进来那一刻用 `Cap.issue`+absorb 给房间成员发 cap，卸载/退群 revoke。复用现成 I12 合规发钥匙机制、不动核心，但要管好"谁进来发、谁走了收"的同步。
  - 倾向 (a)（贴合 Unix 挂载表心智、生命周期干净），但 (a) 碰授权核心——**这是 Allen 该拍的**。

- **待验证**：mount 授权必须**实例精确**（你能操作 A 是因为 A 挂在你的房间，不是因为你能拼出 A 的 URI）——confused-deputy 防护必须活着。提交前确认授权点能表达这个。

### 4.2 是不是最简单

**是想法上最简单、最统一的**（一个招式打通所有场景，#155 不动，比"抽独立 Kind"和"data-member 车道"都简单）。**但不是零工作量**：要给房间加一个"挂载表"，还要动授权（选择题两条路之一）。**简单是架构干净，不是没活干。**

---

## 5. 当前代码 / PR 状态

- **kanban**：`DispatchVerbKanbanTest` 未写（为架构讨论暂停）。Step C（#1309 `host_login_dir`）已在 main 修好（`cc_headless_agent.ex:44`）。worktree `kanban-i12`，分支 `feat/sw-kanban-i12`，未提交代码。**board 先不改**（用户指示）。
- **dealscout**（`feat/sw-dealscout-rework`, #1301 open）：已 rebase 到 main、gate 全绿（invariants 349/0、architecture 102/0、crawler 94/0）、已 push（`66f6d5838`）。零 cap-granting、纯"车道①（角色自执行+routing）"。核心闭环卡两个平台 gap：**L1** CLI busy-Kind reentrancy、**L2** session-scoped cap（= 本讨论的机制）。
- **#1355** open（我的原始 gap handoff）。**#1357** open（Allen 的 SPEC）。
- **main** = `720913ad6`（讨论期间无变动）。

---

## 6. 下一步（重启 session 后从这里接）

1. 把结论写成给 Allen 的 handoff（已写：`../handoffs/socialware-data-mount-model.md`）。
2. 等 Allen 拍：认不认 mount 模型 / 选择题 (a) vs (b) / 铁律"mount≠进群"认不认。
3. Allen 拍板后：公开那半（复用 hello）可先做；操作/借用那半走 mount 新机制。
4. kanban board、crawler 数据面**先不改**，等机制定了再接。
