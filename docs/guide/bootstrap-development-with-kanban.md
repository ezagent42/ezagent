# 在 kanban 帮助下的自举开发全流程（bootstrap development with kanban）

> 本文讲：怎么用 `dev-together` 这套**团队日常开发 workflow**，把一个产品从想法跑到 PR；
> 以及当这套流程**跑在 ezagent 的 live kanban 看板**上时（`kanban-on-ezagent`），
> pm-coordinator 当 coordinator、work 可以派给**人或 agent**——这就是「自举开发」
> （bootstrap development）：团队（含 agent 成员）用自己的产品来开发自己的产品。
>
> 权威源（写代码/改流程以这些为准，本文是导览）：
> - `.claude/skills/dev-together/SKILL.md` + `commands/*.md` + `references/handoff-standard.md` / `handoff-template.md`
> - `.claude/skills/kanban-on-ezagent/SKILL.md` + `commands/*.md` + `references/live-board-access.md` / `agent-orchestration.md`
> - `.claude/skills/pm-coordinator/SKILL.md`
> - 代码 grounding：`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`、
>   `.../kanban/relay_routing.ex`、`.../kanban/connectors.ex`、`.../ezagent_plugin_kanban/pm_coordinator_seed.ex`

---

## ① 概念：两层东西，别混

这套流程是**两层叠加**，看清楚边界才不会乱。

### dev-together = 团队日常开发的 workflow glue

`dev-together` 是「团队每天怎么把活干完」的**编排胶水**（glue），**不重新发明轮子**：每一步都
**delegate** 给一个成熟 skill，自己只加 4 样东西——**节奏（cadence）+ 角色（roles）+ artifact
布局 + handoff 标准（demonstrable DoD）+ 冲突/merge 管理**。

- 塑形一个设计 → `superpowers:brainstorming`
- 把活拆成步骤 → `superpowers:writing-plans`
- 执行一个 handoff → `superpowers:executing-plans` / `superpowers:subagent-driven-development`
- 对抗式 review → codex-rescue（纯静态，不跑 `mix`）
- 项目规则 → `ezagent-developer` / `ezagent-socialware` / `docs/guide/world-coordination.md`

**两个角色（都是「帽子」，不是「人」——人或 agent 都能戴）：**

| 角色 | 职责 | 关键约束 |
|---|---|---|
| **Lead programmer**（lead） | plan、生成 handoff、是**唯一通往 `main` 的路**（经 `close`） | lead 不集中派活时 work 走 relay；merge 永远集中 |
| **Developer**（dev） | 接 handoff、在**每任务一分支**（per-task branch）上 build、return 结果 | PR 永远 merge 进任务分支，**绝不直接进 `main`** |

> **分支模型**：`main` 是 trunk，是任务分支唯一的 merge 目标。`beta`（smoke）/ `release`
> （stable，带 `vX.Y.Z` tag）是**部署指针**（promotion pointer），只由 deploy flow 推进
> （`git branch -f beta <main-sha>`），`close`/`push` **绝不**往它们 merge。

**8 个命令**构成一个完整的 PDCA 闭环：

```
plan ─ handoff │ dive ─ return │ push ─ close │ review
└── Plan ──────┘└── Do ────────┘└── Check ────┘└─ Act ─┘
```

外加两个让闭环「不返工、不跑偏」的相位：
- **前 — clarify/research（补上缺失的 Study）**：build 任务的 scope/feasibility/DoD 还不
  清楚时，**先发 research handoff**（`clarify_first`），它的产出就是 **DoD + build 切片**；
  没触发 discuss-first trigger 才走 fast path 直接 build。
- **后 — method-writeback（学习回路）**：dev 在 `return` 时**捕获** method-friction，
  lead 在 `review` 时**提升**为 method-deltas（一个 dev-together PR 或 tracked process-debt）。
  dev 永不改 skill（single writer），lead 才改。
- **machine return gate**：「done」不再靠自述——`return` 要求 **CI（`precommit +
  check_invariants`）在 PR head 上绿 + rebased on `main`**（分支保护强制）。

### kanban = 把这套流跑在看板上，pm 当 coordinator，活可派给人或 agent

`kanban-on-ezagent` 是 dev-together 的**「live 看板」孪生**（twin）：**同一套产品工作流、同一
套 8 命令、同一套角色**，只是**介质**从「文件/roster」换成了一块**活的 ezagent 看板**。
（文件版孪生是 `kanban-off-ezagent`，看板就是 `docs/board.md` 一个文件，无 ezagent；二者
usage-identical，1:1 映射。）

「on」版的看板是一个 **kanban Kind**，URI `resource://<ws>/kanban/<name>`：
- 它是产品的**单一真相源**（single source of truth），**逐日演进**（不是每天一块新板，
  也不是手编 markdown）。
- 你只能通过 **dispatch**（`Ezagent.Invocation.dispatch/1`）读写它（P14 — dispatch is the
  only path between Kinds），状态存在 Kind 的 **snapshot**（durable、multi-writer）。
- 它**既是 work source**（`plan` dispatch `get_tree` 读板）**又是 write-back sink**
  （`dive`/`handoff`/`close` dispatch `claim_node`/`add_node`/`set_status` 推进它）。

**Fusion 原则（为什么不只是 dev-together）**：plain dev-together 只调度 *developers*——读
roster + 上次 return，**从不读产品板**。这里**活的看板是产品真相源**，产品推进和 dev 节奏
合成一个闭环。

**on 版的超能力**：因为每次看板变更都是一次**带 `ctx.caller` 的 dispatch**，一个节点的
`owner` 可以是一个 **agent entity URI**，和 user URI 一样合法——Behavior **从不区分**「人」
还是「agent」，只检查 `caller == node.owner` 或 admin（`kanban.ex:715`）。所以 relay 链可以
（部分或全部）**跑在 agent 上**。这就是 live 板对文件板的超越。

---

## ② 全流程串讲：8 命令逐个过，每步看 kanban 怎么介入

下面把 dev-together 的 8 命令逐个讲清，**每个命令都标出 kanban-on 版怎么介入**（板的每次
touch 都是一次 **dispatch**）。每个命令开工前**先读对应的 `commands/<cmd>.md`**——那里写了
谁跑、delegate 给哪个 skill、输入、产出 artifact。

### 时间轴 vs 产品轴（别 conflate）

- **产品轴** = 那一块 live kanban Kind（跨所有天都存在它的 snapshot 里），只能 dispatch 读写。
- **时间轴** = `docs/together/YYYY-MM-DD/`（每天一个文件夹，dev 节奏的人读日志）：
  ```
  docs/together/YYYY-MM-DD/
  ├── plan.md             # lead (plan):    今日任务、scope、per-task 分支、冲突图
  ├── handoffs/<task>.md  # lead/owner:     一任务一份 reviewed handoff
  ├── returns/<task>.md   # dev:            带时间戳的 done + DoD artifact + merge 请求
  ├── stack.md            # lead (push):    分析过 merge 顺序的 returns
  └── review.md           # lead (review):  日终复盘 + 次日建议
  ```
- 两个**durable 状态文件**（不随天文件夹消失，是真相源，让 plan「derived 而非 guessed」）：
  - `docs/together/team.md` — roster（行身份 = `github_username`；带 `role`/`short_name`/
    `current_track`/`latest_return`/`timezone`）。
  - `docs/together/<ISO-week>/weekly-goals.md` — 这周的目标，每条 daily track 都 ladder 到一个。

### 1. `init`（dev / lead）— 一次性 + 每天搭架子

- **dev-together**：装 handoff-deadline 提醒 hook（`scripts/install_hooks.sh`，幂等，默认
  20:00），`scripts/new_day.sh` 搭出今天的 `docs/together/<date>/{handoffs,returns}/ +
  plan.md + stack.md`。
- **kanban 介入**：**确保 live 看板 Kind 存在**——没有 `new_board.sh`，对一个还没有活 Kind
  的 URI **dispatch 一次 `get_tree`** 就会经 ReadyGate **auto-spawn** 它
  （`kanban_data.ex:113-124` 先 `ensure_spawned` 再 `get_tree`）。板「创建一次」，之后逐日演进。

### 2. `plan`（lead）— scope 今日任务，让并行不撞车

- **delegate**：`superpowers:brainstorming`（塑形 fuzzy 任务）→ `superpowers:writing-plans`（拆解）。
- **dev-together**：读 `team.md`、**filter 到 `role: human-dev`**（agent 是 off-plan
  support，进单独一节，不占 track 行）；从每个 dev 的 `current_track` + `latest_return`
  **derive** 今天的增量（continuity——不能凭空发明）；每条 track ladder 到 weekly goal；
  列每个任务的 scope / **owned surfaces-files** / **per-task 分支名** / owner / deadline /
  required reading；建**跨任务冲突图**（碰 `world` 的套 `world-coordination.md`）；写 `plan.md`。
  - **Plan completeness gate**：`plan.md` 不是 scaffold 就算数——必须有 `planned_at`/lead/
    deadline/timezone + 每任务一行 + 冲突图 + handoff 顺序 + 每 track 映射 weekly goal。
- **kanban 介入**：**dispatch `get_tree`**，把 live 板的 **active 节点优先、ready 节点其次**
  快照下来，标出冲突/优先级——这是一个**协调视图，NOT 集中派活**。`plan.md` 每个任务必须
  带它的 **live board node id**（来自 `get_tree`）。
  - **Daily, not per-stage**：一个 stage 的 feature 跨多天；板的 snapshot **每天**变（active
    节点上记进度），但节点**只在该棒活干完时**才推进到下一 stage——**绝不「一天一棒」**。

### 3. `handoff`（lead，kanban-on 里是 **node-owner**）— 生成 handoff（并行，一任务一份）

- **delegate**：`superpowers:brainstorming`（设计每个任务）+ codex-rescue（纯静态对抗 review）。
- **dev-together**（每任务并行，一个 subagent 一任务）：
  0. **build vs research（clarify 前相位 / tiering）**：先判这任务命中**任何 discuss-first
     trigger** 没有？命中 → 发 **research handoff**（`clarify_first`），它的 DoD 就是
     *deliverable*：**findings + 提议的 build 切片 + build DoD**，给 lead 批准；批准后才发
     **build handoff**。没命中 → fast path 直接 build。
  1. 读 assignee 的 `team.md` 行，**裁剪 handoff 深度**（continue 自己 track 的 dev 少给
     context；新上手某 surface 的多给 required-reading + worked example）。标准不变，只有深度 flex。
  2. brainstorm 定下 load-bearing 决策。
  3. 用 `handoff-template.md` 写 handoff，套 `handoff-standard.md`。
  4. **对抗式 review**：Claude 自审 + codex-rescue 静态过一遍，都被告知*攻击设计*而非校对；
     handoff 只有**扛过 review** 才出。
  5. 存到 `handoffs/<task>.md` + 吐一段**可直接粘贴的 dev prompt**。
- **kanban 介入（去中心 relay，不是中心派活）**：刚干完 stage N 的**节点 owner** 把**下一棒
  （stage N+1）** 交出去——**dispatch `add_node`**（`parent_id = 刚完成节点 id`），新节点天生
  `owner: nil, status: :unassigned` 所以**可被 claim**（relay，不是 assign）。N+1 与父不同
  stage 时再 dispatch `set_stage`，Kind 强制**相邻棒推进**（`stage_fits?`，`kanban.ex:439-462`），
  跳棒在 dispatch 处就被拒。**需求从节点来，不从新 spec 来**——读父节点已有的
  `artifacts`/`metrics`（经 `get_tree`），别重写需求。handoff 的 DoD 要含「**live 节点经
  dispatch 推进 + artifact 经 `attach_artifact` 挂上**」。**claim 下一棒的可以是 agent**。

### 4. `dive <handoff>`（dev / contributor，人或 agent）— 接 handoff 并 build

- **delegate**：`superpowers:writing-plans`（拆成 PR 大小）→ `superpowers:executing-plans` /
  `subagent-driven-development`（TDD 执行）+ handoff 列出的项目 skill。
- **dev-together**：读 handoff + 它「required reading」全部；在**最新 `main` 上切任务分支**
  （`plan.md` 里那个名）；拆 PR 大小的步骤、对照 `plan.md` + 冲突图确认 scope；TDD 实现；
  **所有 PR merge 进任务分支、绝不进 `main`**；常 rebase on `main`；驱向 handoff 的 **DoD artifact**。
- **kanban 介入**：**dispatch `claim_node`**（owner=你、status→claimed）+ **`set_status doing`**，
  然后切分支干这一棒的活。claimer 可以是 **agent**（它的 `claim_node` 让 agent entity URI
  成为 owner，first-class）。

### 5. `return [branch]`（dev / contributor）— 在 deadline 前把成品交回

- **dev-together**：
  1. **machine return gate（不是散文）**：return 无效，除非 PR 的 **CI（`precommit +
     check_invariants`）在 PR head 上绿** 且分支 **rebased onto 当前 `main`**——把 **CI run
     URL + status** 和 **rebase-base SHA** 写进 return，「gates green」当声明**不被接受**。
  2. **DoD reconciliation——逐行过 handoff 的 DoD**。每行说：met（附 proof 链接）/ deferred
     （→ §3）/ not-met。DoD 是**闭集**——可 defer 一行，**绝不删**一行。divergence 在
     `return` 暴露，不是在 `close`。
  3. **defer 是 lead 的判断**：defer 任何 DoD 行 → 设 `deadline_status: deferred`、把每条
     deferred 列为**给 lead 的 open decision**——**绝不自述「READY TO MERGE」**。把**已完成**
     部分干净 split 到自己的分支（gates 绿）交出去；绝不返回纠缠的半成品。
  4. **method-writeback 捕获**：记下你撞到的 **method friction**（流程里哪块本该先 clarify）。
     便宜 + 新鲜，lead 在 `review` 提升。（你**不**自己改 skill。）
  5. 写 `returns/<task>.md`：metadata · 干了啥 · 逐行 DoD reconciliation · DoD proofs ·
     分支 + gate status（CI URL + rebase SHA）· 干净 split 的 deferred follow-up + open
     decision · method-friction · **merge 请求**。
  6. 吐一段发给 lead 的消息。
  - **必填 metadata**：`returned_at` / `deadline` / `deadline_status`
    （`on_time`/`late`/`deferred`/`out_of_scope`）。
- **kanban 介入**：return 是一份**节点进度报告**，不一定是 stage-advance（多天节点每天 return
  但停在同一 stage）。**把进度 dispatch 到节点上**（ctx = 你的 caller URI，只有 owner/admin
  能 mutate）：同棒进度 → `set_status`；挂 demonstrable artifact → `attach_artifact`；
  价值/ops movement → `set_metric`（按 name upsert）。metadata 额外带 **board node id + 这次
  dispatch 了什么**。
  - **relay-back 在这里自动发生**（kanban 特有，见 §③）：dev 把 return 经 `session send` 发回
    会话，一条 **sender-locked 路由规则** 自动把它路由回 pm——**不靠 `@pm` 文本 parse，靠路由规则**。

### 6. `push`（lead）— 把 returns 叠成 merge stack 并分析顺序（**只分析+排序，不 merge**）

- **dev-together**：读 `returns/*`；跨 returns 分析 inter-task **依赖**、安全 **merge 顺序**、
  **跨分支冲突检查**（碰 world 套 `world-coordination.md`）；跑 **Returned-vs-stacked
  reconciliation**——`stack.md` 必须**account 每个** `returns/` 文件，按行 stacked / superseded
  / late / out-of-scope / blocked，没一个能因不方便或迟到而消失；维护 `stack.md`（有序 merge
  stack + 每条 ready/needs-rebase/blocked）。
- **kanban 介入**：每条 return 映射到它的 **live board node id**（`stack.md` 每条必须带 node id）。

### 7. `close`（lead only）— review/test stack，merge 到 `main`（**唯一通往 main 的路**）

- **dev-together**：按分析顺序，对 `stack.md` 每条：① 确认 `stack.md` reconcile 了每个
  `returns/` 文件（缺一个就停）；② 验 **DoD artifact 在 + 所有 gate 绿**（`arch.scan` /
  `doc.scan` / `uri_query.scan` / `check_invariants` / `format` / `test` /
  `:ezagent_plugin_check` + 这活自己的 invariant test）；③ 按分析重 review/test；④ 需要就
  rebase on `main`；⑤ 调 **`superpowers:finishing-a-development-branch`** 做实际 merge（normal
  lead 选择是 gate 过后 local merge 进 `main`）；⑥ 跑 **PR closure loop**（merged 记 PR# +
  SHA；local merge 的在原 PR 评论 `main` SHA 后 `gh pr close`；无 PR 记 `PR: none`——绝不留
  代码已落地却还开着的 PR）；⑦ 把结果记回 `stack.md`。任何 DoD/gate 不满足的——**停，别 merge**。
  - **deploy 指针守卫**：`beta`/`release`/`vX.Y.Z` 不是任务分支，`close` 绝不往它们 merge、
    也绝不当 stale 分支删。
- **kanban 介入**：merge 进 `main` 后，**dispatch 推进 live 节点**：`set_status done`；
  `set_stage <next>`（**仅当这一棒完成**，相邻棒推进强制）；`attach_artifact`（merged PR 链接）；
  `sync_github`（节点 → GitHub issue + 回挂）/ `register_pr` / `sync_prs`（poll 已注册 PR，
  merged/closed → status done，让板与 GitHub 诚实）。

### 8. `review`（lead）— 日终复盘，喂给次日 `plan`

- **dev-together**：写 `review.md`，覆盖：**what landed**（merged 到 `main`，带 SHA）/
  **效率统计**（planned vs returned vs stacked vs merged，cycle time，并行 vs 串行）/ **gaps**
  （deferred、跳过的 gate、撞的冲突、需要人却卡住的步、滑成「tests pass」的 DoD）/ **次日规划
  建议**。
  - **Method deltas（强制一节——promote，不只收集）**：读每条 return 的 DoD-reconciliation +
    method-friction，triage：每个真流程缺口 → 一个 **dev-together PR**（lead 是 contract 的
    single writer）或一条 tracked **process-debt**。**即使是「none」也要写这节**——缺这节 =
    学习步被跳过、必须可见。这是闭环的 *Act* 相位。
  - **更新 roster（single writer）**：给每个 human dev 设 `current_track` + `latest_return`
    —— `review` 是这两个字段的**唯一**写者，`return`/`close` 不碰。
- **kanban 介入**：**dispatch `get_tree` 把 live 板对账 `main` + stack**（修 drift，dispatch
  纠正）；刷新 projection（`export_markmap` / `sync_miro`）。

---

## ③ kanban 特有功能（off 版没有的）

### 9 阶段 stage 流（the 9-stage relay chain）

固定 9 棒（`@stages`，`kanban.ex:38`；中文/英文对照）：

```
定位        北极星      痛点      认领       线框     功能卡      issue   测试      PR
positioning → metric → pain → anchor → ux → feature → issue → test → pr
└────────── 产品端（pm/设计带）────────┘        └──── dev 端（dev-together 带）────┘
```

- 节点模型（snapshot 里的 shape，`kanban.ex:13-24` + `new_node/4`）：
  ```
  %{parent_id, title, order,
    stage:   :positioning|:metric|:pain|:anchor|:ux|:feature|:issue|:test|:pr,
    owner:   user_uri | agent_uri | nil,   # nil ⟺ status==:unassigned（不变式）
    status:  :unassigned | :claimed | :doing | :done,
    artifacts: [%{tool, kind, ref, url, content}],
    metrics:   [%{name, target, current, unit}]}
  ```
- **相邻棒推进**（`stage_fits?`，`kanban.ex:439-462`）：child = parent stage 或 next stage，
  跳棒在 dispatch 处被拒——**不靠约定，靠 Kind 强制**。
- 24-action 契约（grouped，全在 `kanban.ex`，每个 action 都 `modes: [:call]` 同步返回，每个
  都要匹配 cap `Ezagent.Capability.cap(:kanban, Kanban, action)`，`kanban.ex:242-271`）：
  read/project（`get_tree`/`export_markmap`/`import_markmap`）、topology（`add_node`/
  `rename_node`/`move_node`/`remove_node`/`set_stage`/`drop_subtree`）、claim/status
  （`claim_node`/`unclaim_node`/`set_status`）、artifacts/metrics（`attach_artifact`/
  `detach_artifact`/`set_metric`）、outbound（`sync_github`/`push_pr`/`register_pr`/
  `attach_code_file`/`sync_prs`/`sync_miro`/`set_board_config`/`save_*_creds`）。

### pm-coordinator 配置先行机制（config-first）

pm 是 **9 阶段团队开发流的 coordinator**（流程管家）——一个 `cc` 大脑，挂成 `pm-coordinator`
recipe（role × flavor）。它的工作不是干专家活，而是**判 gate / 帮编辑 / 提醒缺啥 / 按 role
分流派活**（`pm-coordinator/SKILL.md`）。

**「配置先行」= 关系在 bind 时建立，而非临时 special-case**：当 operator **`bind_session`**
把一个 kanban-flow 会话绑到某块板时（`connectors.ex:306`），这是 **establishment point**：

1. **顺序** materialize 两个 per-session 角色大脑（`connectors.ex:382-384`，**串行**——pm 先、
   dev-together 后，绝不两个 cc 冷启并发）：
   - **pm-coordinator** per-session 大脑 `entity://<ws>/agent/pm-coordinator-<sess-disc>`
     （`PmCoordinatorSeed.materialize/4`）——pm 是 per-session 的（与 orchestrator 同，user
     decision 2026-06-29）。它的 `kanban.*` caps 经 `cap_instance_overrides` **scope 到这块
     board 实例**（`%{Ezagent.Behavior.Kanban => board_uri}`），因为 Behavior.Kanban 活在
     board host 上、不在 pm 上。
   - **dev-together** per-session 大脑（一份 workflow recipe，role-as-data 住 domain_agent 的
     `Ezagent.Agent.DefaultRecipes`、经 `DefaultRecipeSeed` 统一入口 boot-seed，kanban 按 role
     NAME 经 registry reach，零编译依赖，`connectors.ex:420-428`）。
2. **wire relay-back 路由规则**（`wire_relay_back_routing`，`connectors.ex:463`）——**在大脑还
   不存在时就 wire**（路由规则只 reference URI，不 call 它们）。

pm 怎么操作板和 GitHub：**只经 ezagent CLI 的一个泛型 verb**（看板是 per-instance、role-mounted
Behavior，**没有** `mix ezagent kanban.*` 子命令）：

```
mix ezagent dispatch <board-uri> --action <behavior>.<action> --args '<json>'
```

CapBAC 授权每一次调用——**没有后门**；缺某个 cap 就 fail closed，pm 把它当 blocker 暴露，不提权。

### dev→pm sender-locked relay-back（自动接力）

**问题**：dev 干完活把产出交回 pm 这一棒**没有框架公告**——dev 的 return 是一条**自由文本**
chat（经 `session send` 投递），它正文里的 `@pm` 是否被 parse 成结构化 mention **不稳定**
（T11 surface F：dev 节点内发的 @mention 解析为空 → pm 没被唤醒）。

**正解 = sender-locked 路由规则**（`relay_routing.ex:95-158`，与 core E2E Scenario 34「传话
游戏」同一已验原语 `{:from, X} → Y`）：

```
matcher  = in_session(<session>) AND from(dev-together-<sess>)
receiver = [pm-coordinator-<sess>]          # 单接收者，满足 rule-set 不变式
```

- 消息的 **sender 字段由 transport 结构化写入**（`message.sender`），**不读正文**——所以
  `from(dev)` **永远命中**，无论 dev 的 `@pm` 文本 parse 成不成功。这正是「**不靠 @mention
  parse，靠路由规则**」的稳健性来源。
- **方向性 = 配置先行**：因为这条规则在 bind 时随 pm + dev 一起 materialize 进**这个**会话，
  所以 dev 在本会话的**任何产出/return 自动路由回 pm**。**人直接找 dev（没经 kanban-flow bind
  建立这层关系）→ 没这条规则 → 不接力回 pm。** 规则是**声明式配置**，不是 dispatch 代码里的
  special-case。
- **幂等**：同会话 re-bind 经 `find_by_identity`（`created_by = session_uri`，`rule_set =
  "kanban_relay_back"`，position 0）reconcile，不重复建行。**best-effort + non-blocking**：
  wire 失败**绝不**让 operator 的 bind 失败——经 Logger/telemetry 暴露（cast-mode「谁知道它失败了」）。

> 对比 `wire_relay_rule`（**marker** 触发 `text_contains([kanban:<event>])`）：那是框架在
> 接力**动作**（`claim_node`/`set_status`/`register_pr`）成功后注入的机器可读公告，唤醒**下
> 一棒** agent。relay-back 走的是 **from** 触发，专治「自由文本 return 没有公告」这一棒。

### board 单一真相源（single source of truth）

- 板的所有 tree 写入都过单一 `commit/1`（`kanban.ex:704` → `Shared.commit/1`），读经
  `Shared.tree(ctx)`；框架把 committed state 存进 Kind snapshot——**multi-writer by
  construction**，每次写都是一次**已鉴权的 dispatch**。
- projection 按需产出：`export_markmap`（byte-for-byte 等于 off 板的 `board.md` 格式，可互转）、
  `sync_github`/`sync_prs`、`sync_miro`、`get_tree` 还回 `ci` map（per-`pr`-node CI 裁决）。

---

## ④ 人 / agent 混合：哪步谁做

`dev-together` 的角色都是「帽子」（人或 agent 都能戴）；kanban-on 让 contributor relay 可以
跑在 agent 上。一个务实的混合分工（pm-coordinator 当 coordinator 时）：

| 步骤 | 典型由谁做 | 说明 |
|---|---|---|
| `init` 装 hook / 起板 | 人（一次性）或 pm agent | 板 auto-spawn |
| `plan` 协调视图 | **pm agent** 判 gate + 提醒缺啥；lead 拍板 | pm `get_tree` 读板 |
| 产品端 ①-⑥棒（定位…功能卡） | 人（设计带）+ pm 编辑协助 | 需求/判断重，人主导 |
| `handoff`（relay 下一棒） | **node owner**（人或 agent） | dispatch `add_node` |
| `dive`/`build`（⑦issue⑧test⑨PR） | **dev-together developer agent**（cc 大脑） | 只产 artifact，**不碰板/GitHub、不持板 caps** |
| `return` | developer agent | `session send` 回 pm，relay-back 自动路由 |
| `push`/`close`（merge + 推进节点） | **lead（人）/ pm（board+GitHub 接力）** | merge 集中、唯一通往 main |
| `review` | lead（人）+ pm 协助统计 | method-deltas 必写 |

**严格分工（pm-coordinator 的铁律）**：
- **pm 拥有板和 GitHub**——claim/advance 节点、register PR、开 issue，全在**它自己的 caps**下
  经 `dispatch` 跑。
- **developer 只产 artifact**（分支/代码/return 文档），**不碰板/GitHub、持有零板 caps**。
  若你看见 developer 试图 `dispatch <board> --action kanban.*`——**那是错的模型**，会（正确地）
  CapBAC 失败。developer 的产出当作 chat `return` 回到 pm，**pm 才把它写上板**。

**chat-orchestration（高层目标形态，部分 grounding 待补）**：lead 可以 `@`/route 一条消息给
一个 **kanban-manager agent**，让它代为驱动板（管节点、派活给人或 agent、kick CI、review），
极限是全自动开发。「Behavior 不区分人/agent caller」是 grounded + load-bearing
（`agent-orchestration.md`）；但**具体路由规则 + kanban-manager agent 契约的 file:line 仍是
placeholder（待编排 grounding 补全）**——目前 8 个 `commands/` 是给**人或 agent contributor 直
接 invoke** 写的。

---

## ⑤ 一个完整示例：把「auth 功能线」从板上跑到 PR

设一块已建好的板 `resource://system/kanban/kbflow`，绑定会话 `session://system/default/kbflow`，
已 bind 过（故 pm-coordinator-kbflow + dev-together-kbflow 两个 per-session 大脑已 materialize，
relay-back 规则 `from(dev-together-kbflow) AND in_session(kbflow) → [pm-coordinator-kbflow]`
已 wire）。

1. **init**（早上）：人跑 `new_day.sh` 出 `docs/together/2026-06-30/`；dispatch 一次 `get_tree`
   确认板活着（auto-spawn 幂等）。

2. **plan**（pm + lead）：pm `dispatch get_tree`，看到 `auth` 功能线最深的 active 节点 `n7`
   停在 `feature`（功能卡）棒、`status: done`。今日增量 = relay 出 `issue` 棒。`plan.md` 写一行：
   task `auth-issue`、node id `n7`、分支 `auth-issue`、DoD = issue 节点带可执行 issue body +
   build 切片，deadline 20:00。

3. **handoff**（n7 owner，relay）：owner `dispatch add_node`（`parent_id: n7`，title「auth:
   issue ⑦」）→ 新节点 `n8` 天生 unassigned；`dispatch set_stage`（`n8` → `issue`，相邻棒，
   过）。需求从 `n7` 的 `artifacts`（功能卡）读，不重写。brainstorm + codex-rescue review 后，
   写 `handoffs/auth-issue.md`，吐 dev prompt。
   - pm **派活**（①）：`dispatch claim_node {id: n8}`（pm 成 owner，accountable）+
     `set_status {id: n8, status: doing}`；`session send --session …/kbflow --message
     "@dev-together-kbflow dive this handoff: auth issue. Scope/DoD/Branch:…. Return when CI green."`

4. **dive**（dev-together-kbflow agent，人或 agent）：读 handoff + required reading；切
   `auth-issue` 分支 off `main`；TDD 写 issue body + 测试切片；PR 进任务分支、常 rebase。
   （注意：developer **不** dispatch 板——它没有板 caps。）

5. **return**（dev agent）：CI 绿（`precommit + check_invariants`）on PR head + rebased；逐行
   DoD reconciliation；写 `returns/auth-issue.md`（带 `returned_at`/`deadline`/
   `deadline_status: on_time` + board node `n8`）；`session send` 把 return 发回会话。
   - **relay-back 自动发生**：消息 sender = dev-together-kbflow → 命中 `from(dev) AND
     in_session(kbflow)` 规则 → **自动路由回 pm-coordinator-kbflow**，pm 收到 return（无论
     `@pm` 文本 parse 成不成功）。

6. **收 return + push**（pm + lead，②）：pm 读 return，DoD 满足。lead `push`：分析 merge 顺序，
   `stack.md` 把 `auth-issue` 映射到 node `n8`，标 ready。

7. **close**（lead only，③接力）：gate 全绿，调 `finishing-a-development-branch` local merge
   `auth-issue` → `main`（记 merge SHA）；跑 PR closure loop（评论 `main` SHA + `gh pr close`）。
   pm **接力**：`dispatch github.create_issue {id: n8,…}` / `register_pr {id: n8, pr: "#NN"}` /
   `set_stage {id: n8, stage: issue→test}`（仅当这棒完成）/ `set_status {id: n8, status: done}` /
   `attach_artifact`（merged PR 链接）/ `sync_github`。板与 GitHub 对齐。

8. **review**（lead + pm）：写 `review.md`——landed（merge SHA）、效率统计、gaps；**method-deltas**
   一节（哪怕 none）；更新 `team.md` 的 `current_track`/`latest_return`。pm `dispatch get_tree`
   对账板与 `main`，`export_markmap` 刷 projection。次日 `plan` 从 `n8`（现在停在 `test` 棒）继续。

至此 auth 功能线推进了一棒（feature → issue → 下一棒 test），全程板是单一真相源、每次变更都是
一次已鉴权 dispatch、dev 与 pm 的接力靠声明式路由规则自动完成、merge 集中且唯一通往 `main`。
