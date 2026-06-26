# 产品开发协作流程重设计（dev-together × kanban × ezagent）

> 日期：2026-06-26
> 范围：把三件东西接成一条流水线——9 阶段产品接力链（positioning→…→pr）、dev-together 的每日 8 命令节奏、ezagent 上的 live kanban board（kanban-as-role agent）。
> 立场：本文给"真正应该的流程"，每一步落到"谁做 / 读什么 / 产什么 / 用 kanban 哪个动作 / 用 dev-together 哪个命令"，并指出现状缺口和最小修复。所有论断带 file:line。

---

## 0. 一句话结论

现状是**三套各转各的轮子**：

1. **9 阶段接力链**是产品语义（一条"真相源接力"，每个箭头一道 gate），权威源 `docs/discuss/df-prd/07-定版-自举开发流程-10分钟.md`；
2. **dev-together** 是纯开发节奏胶水，只围着 `team.md` 花名册转，**对产品 board 零感知**（`grep -rl kanban .claude/skills/dev-together` = 空，见 `.claude/skills/dev-together/SKILL.md:36-43` 的委托链里没有 kanban）；
3. **kanban 插件**有 25 个动作、能把 board 当 live 真相源跑（`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:42`），但**和 dev-together 之间没有任何代码/文件级接线**——kanban-off/on 两个 skill 是 dev-together 的 fork，各自重写了全部 8 个命令，靠各自描述里单向 reference dev-together 挂接。

**真正应该的样子**：一条流水线、两根轴。

- **产品轴**（空间）= 一块 live kanban board（一个产品一块，URI `resource://<ws>/kanban/<name>`，跨天持久，存在 Kind snapshot 里，见 `kanban-on-ezagent/SKILL.md:57-66`）。它同时是**活源**（plan 读它）和**回写汇**（dive/handoff/return/close 写它）。9 阶段接力链就是这块 board 的节点树。
- **时间轴**（节奏）= `docs/together/<date>/` 每日日志 + dev-together 8 命令（`kanban-on-ezagent/SKILL.md:68-77`）。

把两根轴用 **board node id** 这个字段缝起来：dev-together 每个 plan 任务 / return / stack 条目都必填它指向的 board 节点，节奏的每一步都顺手 dispatch 一个 `kanban.*` 动作回写产品轴。**产品状态和开发节奏从此是一个闭环，不是两条不相干的轨。**

---

## 1. 两根轴的职责切分（别混）

| | 产品轴（kanban board） | 时间轴（dev-together） |
|---|---|---|
| 是什么 | 一块 live Kind，9 阶段节点树 | `docs/together/<date>/` 每日文件夹 |
| 单位 | 一个产品一块，跨天持久 | 一天一个文件夹 |
| 真相源 | **产品状态的唯一真相源**（每个节点的 stage/owner/status/artifacts/metrics） | 当天**开发动作的流水账**（plan/returns/stack/review） |
| 谁读谁写 | 只能经 dispatch 读写（`Ezagent.Invocation.dispatch/1`） | 文件读写 |
| 推进节律 | **节点级、按完成推进**——一个节点在一棒里待几天正常，活干完才进下一棒（不是"一天一棒"，`kanban-on-ezagent/SKILL.md:51-55`） | **天级 PDCA**——每天一轮 plan→…→review |

关键：**board 每天都在动**（活跃节点上记进度），但**节点只在该棒工作 done 才晋级**。这条"daily-progress-not-per-stage"是把多天功能跟每日节奏对齐的核心（`kanban-on-ezagent/SKILL.md:51-55`、`kanban-off-ezagent/SKILL.md:31-35`）。

---

## 2. 9 阶段接力链 = board 的节点树（产品语义）

链是 `positioning→metric→pain→anchor→ux→feature→issue→test→pr`（`kanban-on-ezagent/SKILL.md:8`，stage 枚举见 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/ci.ex:63-73`）。

每个箭头 = **一次真相源交接 = 一道 gate**：下游只认上游"钦定的那一件唯一真相源"，上游没过自己的验收，下游不放行（`07-定版-自举开发流程-10分钟.md` §核心设计意图 2-3）。

| # | 阶段 | 谁做（角色） | 读什么（上游真相源） | 产什么 | **钦定给下游的唯一真相源** | board 动作 | gate（不过不放行） |
|---|---|---|---|---|---|---|---|
| 1 | positioning 定位 | 产品负责人 | 团队产品意图 | 价值主张·PR/FAQ·交易公式 | **一页定位稿** | `add_node`(根, stage=:positioning) + `attach_artifact` | 定位稿成形 |
| 2 | metric 验证/运营 | 运营 | 一页定位稿 | 北极星指标定义 + drop 阈值 | **北极星指标** | `add_node`(stage=:metric) + `set_metric` | 指标+阈值已定（先定度量后收数据） |
| 3 | pain 痛点 | 产品 | 北极星指标 | 多张痛点卡 + 优先级 | **排序后痛点清单**（每痛点指向北极星） | `add_node`×N(stage=:pain) + `attach_artifact` | 痛点都挂得上北极星 |
| 4 | anchor 用户锚定 | 产品负责人 | 痛点清单 | 画像·零教育成本评估·岗位↔层映射 | **岗位↔认领层映射表** | `add_node`(stage=:anchor) + `attach_artifact` | 映射表决定谁认领后续 |
| 5 | ux 体验主张 | 产品 + 设计 | 痛点清单 | 四条 UX 承诺·线框/原型 | **主界面线框/原型** | `add_node`(stage=:ux) + `attach_artifact` | 线框成形 |
| 6 | feature 功能/模块 | 产品 + 研发 | 线框/原型 | 模块·spec 卡·用户故事·**Gherkin 验收**·ICE·价值卡 | **功能 spec 卡** | `add_node`(stage=:feature) + `attach_artifact`(content 含 Gherkin) | **Gherkin 验收写全**，否则不许开 issue（`ci.ex:34` `has_gherkin?`） |
| 7 | issue | 研发 | 功能 spec 卡 | issue（含范围/不做/验收用例） | **issue 本身** | `add_node`(stage=:issue) + `sync_github`(`connectors.ex:31` 建 issue+回挂) | issue 挂上 kind="issue" 产物（`ci.ex:35`） |
| 8 | test 测试 | 研发 | issue（携带 spec 卡 Gherkin） | 测试代码 + 绿/红，用例=Gherkin不另写 | **可跑且对应 Gherkin 的测试套件（必绿）** | `add_node`(stage=:test) + `attach_artifact`(kind="test_suite", ref="green") | 测试套件挂 kind="test_suite" 且 ref="green"（`ci.ex:36` `test_green?`） |
| 9 | pr | 研发 | 测试套件（写实现让它变绿） | PR·测试通过·过 gate | **合并后的 PR**（上线→实测回收→回 ②对北极星阈值） | `add_node`(stage=:pr) + `register_pr` + `push_pr`(软留言+硬 CI 门) + `sync_prs` | **4 条判据全绿**（`ci.ex:28-37`），`gate_state`→GitHub commit status 挡合并（`ci.ex:58`、`github.ex:117`） |

角色映射（`07-demo` `ROLES`）：产品负责人[1,4]、运营[2]、产品[3,5,6]、设计[5]、研发[6,7,8,9]；共担：⑤产品+设计、⑥产品+研发。

**回收闭环 ⑨→②**：PR 上线→实测指标回收→回 ② 对北极星阈值→窗口内不达标 → `drop_subtree`（`kanban.ex:130`→`:384`，砍 ⑥→⑦⑧⑨ 子树并追一条到 `tree.drops`）→反哺 ③ 重选痛点。开发与验证错位（这周开发、下周验证）。

**为什么强制"钦定唯一真相源"**：①定位、②验证、⑥功能这种环节天然产出一堆，必须钦定一件为唯一真相源、其余降级成附件，否则下游无所适从（`07-定版` §关键决策）。这正好对应 board 上每个节点钦定一个主 artifact。

---

## 3. dev-together 8 命令 × 9 阶段：真正的接线

dev-together 8 命令本身**不变**（命令词表已 grill 锁死，`dev-together-skill-improvement-plan.md:19`：所有新增都是脚本/flag/目录，绝不加新命令）。改的是：**每个命令多读/多写 board 一次**，且 plan/return/stack 的台账多一个必填字段 `board_node_id`。

下面是**一天**里 8 命令怎么和 9 阶段 board 缝在一起（命令定义见 `.claude/skills/dev-together/SKILL.md:112-121`，融合点见 `kanban-on-ezagent/SKILL.md:119-149`）：

### init（任何人）
- 现状：`scripts/install_hooks.sh` + `new_day.sh` → 产 `docs/together/<date>/{handoffs,returns}/ + plan.md + stack.md`（`dev-together/commands/init.md:6-12`）。
- **加**：确保 live board Kind 存在——dispatch 一次 `get_tree`（`kanban.ex:138`→`:558`），ReadyGate 会自动 spawn（`kanban-on-ezagent/SKILL.md:125`）。
- 产物：当天空文件夹骨架 + 确认 board 在线。

### plan（lead）
- 现状：只读 `team.md` 花名册（过滤 `role: human-dev`）+ 每人 `latest_return` + `weekly-goals.md`，**不读任何 board**（`dev-together/commands/plan.md:9-31`、`SKILL.md:63-84`）。**这是最大缺口**。
- **改**：先 dispatch `get_tree` 快照 board 的**活跃节点优先、ready 节点其次**（`kanban-on-ezagent/SKILL.md:126`），形成"今天推哪些节点"的协调视图——**不是中心派活**，派活是去中心化接力。
- **台账新字段**：`plan.md` 每个任务必填 `board_node_id`（来自 get_tree），外加现有的 owner/branch/scope/required-reading/DoD/deadline。无此字段 = 空 plan = 这天没开始（沿用 `kanban-on-ezagent/SKILL.md:135-137` 的 No-empty-plan + dev-together `SKILL.md:88-91`）。
- 产物：`plan.md`（团队向三段式：①本周目标功能点缺口 ②缺口开发计划总览 ③按开发者指向各 handoff，`dev-together-skill-improvement-plan.md:9-13` D 条）。

### handoff（node-owner，**不再是 lead 中心派**）
- 现状：lead 读 assignee 的 `team.md` row + handoff 模板，写 `handoffs/<task>.md`（`dev-together/commands/handoff.md:8-36`），含 clarify-first 分流（research vs build）。
- **改**：handoff = **接力下一棒**——节点 owner 完成第 N 棒后，dispatch `add_node` 建第 N+1 棒节点（`kanban.ex:42`→`:299`，子 stage 必须 ≥ 父 stage，`kanban.ex:352-355` 单调闸），handoff spec 从该节点的 artifact/metric 派生（`kanban-on-ezagent/SKILL.md:127`），留着 claimable。这是**去中心化接力**，不是从中心下发。
- clarify-first 保留：第 6 棒（feature）若 spec/可行性/DoD 未知，先发 research handoff 产出 DoD+slices，再发 build handoff（`dev-together/SKILL.md:133-147`）——DoD 往往要研究完才写得出。
- 产物：`handoffs/<task>.md`（自包含 spec + 贴好的 dev prompt）+ board 上新建的下一棒节点。

### dive（contributor，**人或 agent**）
- 现状：读 handoff + required reading，从 main 切 per-task 分支，在分支写代码（`dive.md:9-19`）。
- **改**：先 dispatch `claim_node`（`kanban.ex:82`→`:483`，owner=caller、status→claimed）+ `set_status doing`（`kanban.ex:98`→`:510`），再切分支干活（`kanban-on-ezagent/SKILL.md:128`）。
- **on-ezagent 超能力**：因为每次 mutation 都带 `ctx.caller`，节点 owner 可以是 **agent entity URI**，Behavior 只查 `caller == node.owner` 或 admin（`kanban.ex:715` `owner_or_admin?`、`shared.ex` / `kanban_actions.ex:321-327`），**不区分人和 agent**。所以接力链可以（部分或全部）跑在 agent 上（`kanban-on-ezagent/SKILL.md:100-108`）。
- 产物：per-task 分支 + 节点 status=doing。

### return（contributor）
- 现状：机器闸——要求 PR CI（precommit + check_invariants）green + rebase on main（`dev-together/commands/return.md:6-9`、`SKILL.md:148-151`）；逐行 DoD 对账；写 `returns/<task>.md`（含 returned_at/deadline_status/method-friction）。
- **改**：把进度 dispatch 回节点——`set_status`/`attach_artifact`/`set_metric`（`kanban-on-ezagent/SKILL.md:129`）。第 8 棒挂 `kind="test_suite", ref="green"` 的测试产物；第 7 棒挂 `kind="issue"` 产物——**这些正是第 9 棒 CI gate 的判据数据**（`ci.ex:35-36`）。
- **台账新字段**：`returns/<task>.md` 记 `board_node_id` + 这次 dispatch 了什么进度（`kanban-on-ezagent/SKILL.md:138-139`）。
- 产物：`returns/<task>.md` + board 节点状态/产物前移。

### push（lead）
- 现状：读 `returns/*`，算依赖/合并序/冲突，写 `stack.md`，**只分析不合并**（`dev-together/commands/push.md:6-16`）。
- **改**：排序时每个 return 映射到它的 board 节点 id（`kanban-on-ezagent/SKILL.md:130`）。对账要覆盖每个 return：stacked / superseded / late / out-of-scope / blocked（`SKILL.md:140-141`）。
- 产物：`stack.md`（有序合并栈 + returned-vs-stacked 对账，每行带 board_node_id）。

### close（**仅 lead，唯一进 main 的路径**）
- 现状：读 `stack.md` + 校 gates，委托 `superpowers:finishing-a-development-branch` + PR closure loop，回写 `stack.md`（`dev-together/commands/close.md:6-22`）。
- **改**：合 main 后 dispatch 推进节点——`set_status done`/`set_stage`（推进到下一棒）/`attach_artifact` + `sync_github`（`kanban-on-ezagent/SKILL.md:131`）。第 9 棒 close 时 `register_pr`+`push_pr` 把 requirement_digest 软留言到 PR + `gate_state` 推成 commit status 硬门（`connectors.ex:75`、`ci.ex:58`）。
- **Close PR state**：合并后每个相关 PR 要么 merged 要么显式 closed/subsumed，节点反映结果（`sync_github`/`sync_prs` 保持 GitHub 侧诚实，`kanban-on-ezagent/SKILL.md:142-144`）。
- 产物：main 上的合并 SHA + board 节点晋级 + GitHub 同步。

### review（lead）
- 现状：读 `stack.md` + 各 return 的 method-friction，写 `review.md`（retro+stats+method-deltas），**唯一写者**回写 `team.md` 的 `current_track`/`latest_return`（`dev-together/commands/review.md:5-27`、`SKILL.md:74`）。
- **改**：dispatch `get_tree` 把 **live board 对账到 main + stack**，修漂移（dispatch 纠正），刷投影 `export_markmap`/`sync_miro`（`kanban-on-ezagent/SKILL.md:132`、`148-149`）。
- 6-26 升级：review 是**数据驱动 HTML**——`gather_stats.sh`→`stats/cycle-data.json`→渲染三章节（①昨日工作统计 ②昨日开发效能含 dev-time=最早commit→merge ③数据统计聚焦 feature-points），见 `dev-together-skill-improvement-plan.md:9-13` B 条。review 写的是**对昨天 cycle 的回顾**（"2026-06-25 review.html" 落在 6-26 目录）。
- 产物：`review.html`（团队向，scrub 掉内部讨论）+ 回写 team.md + board 对账修漂移。

---

## 4. 关键缺口与必须的修复（不补，流水线就断在这几处）

### 缺口 A —— register_pr 是整条自动 CI 链的人工断点（最痛）
**断在哪**：`register_pr(%{id, pr})` 的 `pr` 是**调用方手填**的字符串（`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex:116`），`to_pr_number/1`（`connectors.ex:331`）解析 "#42" 拼 URL 挂 kind="pr" 产物。没有任何代码自动发现 PR 号——`github.ex` 只有出站，moduledoc 明写"无 inbound webhook"（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:9`）。

**堵死的三件事**（全卡在这一步之后）：
- `push_pr` 经 `node_pr/1`（`connectors.ex:316`）抠 PR 号，没登记就返回 `:no_pr_registered`（`connectors.ex:94`）→ 软留言 + 硬 CI 门全发不出；
- `sync_prs` 经 `advance_merged_prs`（`connectors.ex:341`）靠 `node_pr` 找已登记 PR，未登记节点直接跳过 → merged→done 自动推进不发生；
- B1 接力：`register_pr` 是 `@relay_actions` 之一（`kanban.ex:702`），登记成功才 fire `[kanban:pr_registered]` 唤醒下一个（CI）agent。

**对称缺口**：Miro 侧有非破坏入站（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro/sync.ex:166` `detect_inbound/2` + `miro_sync.ex` GenServer 轮询→dispatch add_node），**GitHub 侧完全没有**。

**修复**：给 `github.ex` 补一条 inbound——webhook（监听 pull_request 事件）或轮询 `list PRs` 按 head_ref/分支名自动匹配节点 → 自动 `register_pr`。这一条补上，硬 CI 门 + 自动合并推进 + B1 接力唤醒同时通，**且接力链才能真正无人值守跑在 agent 上**（否则每次都要人肉看 PR 号手工 dispatch）。

> 这条修复让第 9 棒 close 不再需要人插一脚，是"全自动开发"（kanban-manager agent 驱动）的前置。

### 缺口 B —— dev-together 台账没有 board_node 字段
dev-together 的 plan completeness gate（`dev-together/commands/plan.md:32-46`）和 return 元数据块（`return.md:33-44`）**没有 board_node 字段**。即使有 board，dev-together 产物也回指不到节点。
**修复**：把 `board_node_id` 下沉成 plan/return/stack 的**可选台账列**（有 board 时必填，无 board 时省略）——这样一套 dev-together 既能跑纯开发（无 board），又能跑产品流水线（有 board），不必 fork 出两个 kanban skill。

### 缺口 C —— dev-together 不指向 kanban（单向接线）
两 kanban skill reference 了 dev-together（`kanban-off-ezagent/SKILL.md:22-29`、`kanban-on-ezagent/SKILL.md:44-49`），但 **dev-together 委托链里没有 kanban**（`dev-together/SKILL.md:36-43`）。接线只活在 kanban 一侧的描述文字里。
**修复**：在 dev-together SKILL 委托链/路由处加一句指针——"若存在产品 board（`docs/board.md` 或 `resource://…/kanban/…`），用 kanban-off/on-ezagent 取代本 skill 的 plan/review 读写"。

### 缺口 D —— handoff-standard 三份拷贝
`handoff-standard.md` 在 dev-together 和两 kanban skill 各存一份（复制非引用）。dev-together 改标准不会传导到 kanban。
**修复**：抽成单一来源（dev-together 持有，kanban 两 skill 引用）。

### 缺口 E —— 三套 skill 是 fork，不是组合
kanban-off/on **各自重写了全部 8 命令**，而非"dev-together 若有 board 就切换读写源"。维护三份会持续漂移。
**修复方向**（更大、需 Allen 拍板）：让 kanban-on/off 只覆写 plan/handoff/return/close/review 里"碰 board"的那几个动作，其余继承 dev-together。短期可先靠缺口 B/C/D 把接线做实，长期收敛成"一套节奏 + board 适配层"。

---

## 5. 每阶段产物清单（落到文件/动作）

**产品轴产物**（都活在 board 节点的 artifacts 里，经 `attach_artifact` dispatch，`kanban.ex:106`→`:531`）：
| 阶段 | 产物文件/工具 | 钦定真相源（节点主 artifact） |
|---|---|---|
| 1 定位 | 飞书 docx / Miro 根节点 | 一页定位稿 |
| 2 验证 | 飞书 OKR + 指标采集落库 | 北极星指标 + drop 阈值（`set_metric`，`kanban.ex:122`→`:544`） |
| 3 痛点 | 飞书 bitable / Miro 机会树 | 排序后痛点清单 |
| 4 锚定 | 飞书 bitable | 岗位↔认领层映射表 |
| 5 体验 | excalidraw / Lovable / Zeplin | 主界面线框/原型 |
| 6 功能 | 飞书 docx / markmap（spec 卡模板 06·G-r） | 功能 spec 卡（含 Gherkin） |
| 7 issue | GitHub（`sync_github`→建 issue+回挂） | issue（kind="issue" 产物） |
| 8 测试 | dev-loop: test-plan-generator→test-code-writer→test-runner；mix test | 测试套件（kind="test_suite", ref="green"） |
| 9 PR | GitHub + reviewer 过 gate 清单 | 合并后 PR（commit status=success） |

**时间轴产物**（每天，`docs/together/<date>/`，见 `dev-together/SKILL.md:51-59`）：
- `plan.md` / `plan.html`（lead，三段式团队向，每任务带 board_node_id）
- `handoffs/<task>.md`（lead/node-owner，自包含 spec）
- `returns/<task>.md`（dev，带 returned_at/deadline_status/board_node_id/dispatch 进度）
- `stack.md`（lead，有序合并栈，每行 board_node_id）
- `review.html`（lead，数据驱动三章节，读 `stats/cycle-data.json`，scrub 内部讨论）

**跨 cycle 持久产物**（6-26 新增，`dev-together-skill-improvement-plan.md:9-13` C/E 条）：
- `docs/together/team.md`（花名册，row identity=github_username）
- `docs/together/CURRENT_DATE`（日界 flag，lead↔lead-agent 讨论决定翻日，不是机器时间；4 前置全满足才 `advance_cycle_date.sh` 翻篇）
- `docs/together/contributing/`（跨 cycle 台账，累积原则违例/潜在问题/流程摩擦；handoff 下发和返还前**必读**，用 `contributing_read_through` attestation 字段做机械闸）
- `docs/together/<ISO-week>/weekly-goals.md`（周目标，每日 track 往上对齐）

---

## 6. CI gate 机制（第 8→9 棒的硬闸，已实现）

第 9 棒不是软提醒，是真能挡合并的硬门，已在代码里：

- 判据（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/ci.ex:22` `check_pr_gate/2`，纯函数沿祖先链算 4 条）：
  1. `upstream_done`——链上各棒 done（`ci.ex:30-33`）
  2. `gherkin`——feature 节点 artifact content 含 Gherkin（`ci.ex:34` `has_gherkin?`）
  3. `issue`——issue 节点挂 kind="issue" 产物（`ci.ex:35`）
  4. `test_green`——test 节点挂 kind="test_suite" 且 ref="green"（`ci.ex:36`）
- `gate_state/1`（`ci.ex:58-61`）：全过=`success`（绿放行）/ 有未过=`failure`（红挡合并）/ max=0=`pending`（中性）。
- 推到 GitHub：`connectors.ex:100` `push_ci_status/4` → `github.ex:117` `create_commit_status` POST `/repos/{repo}/statuses/{sha}`，context=`ezagent/ci-gate`。配上 branch protection 的 required status check（context=`ezagent/ci-gate`），failure 真能挡合并。
- 软留言：`requirement_digest/2`（`ci.ex:83`）沿祖先链把每棒文档+指标拼成"本 PR 产品上下文" markdown，`push_pr` post 到 PR（`connectors.ex:75`）——确定性汇总，非 LLM。

**含义**：测试用例不另写，就是第 6 棒 spec 卡的 Gherkin（一物三用=验收标准=测试用例=PR 过 gate 判据，`07-定版` §核心设计意图 3）。测试不绿，第 9 棒 commit status 就是 failure，PR 合不进——"green tests, broken product" 和"自称 done"都过不了。

---

## 7. 落地顺序（最小可执行）

按"先接线、后自动化"排：

1. **缺口 B**（台账加 `board_node_id` 列）——纯 skill 文档改，dev-together plan/return/stack 模板加可选字段。**当天就能做，无代码。**
2. **缺口 C+D**（dev-together 委托链加 kanban 指针 + handoff-standard 抽单一来源）——纯 skill 文档改。
3. **缺口 A**（github.ex 补 inbound 自动 register_pr）——**有代码**，是去掉人工断点的关键。建议 webhook 优先、轮询兜底（对称 Miro 的 `detect_inbound` 已有先例）。这条做完，第 9 棒 close 可无人值守，接力链可整段跑在 agent 上。
4. **验证 e2e**：起一块 live board，从 positioning 一路 dispatch 到 pr，观察 CI gate 由 failure→success、PR 自动 register、sync_prs 自动 merged→done、B1 relay 自动唤醒下一棒 agent。每个有意义步骤留浏览器/真渠道截图（个人规矩：拒单元 stub 当 e2e）。
5. **缺口 E**（收敛三 fork 为一套节奏+适配层）——较大重构，需 Allen 拍板，放最后。

---

## 8. 待 Allen 拍板的开放问题

1. **feature-point 口径**未正式定义（6-26 已用 FP1–FP6 编号但单位未定，约定自 6-27 起在 plan 阶段先约定再排期，`plan.html:45`、`dev-together-skill-improvement-plan.md` 开放问题①）。FP 口径直接决定 board 上 feature 节点的粒度。
2. **缺口 E 的收敛形态**：三 fork 合一 vs 维持双子 skill？影响长期维护成本。
3. **缺口 A 的 inbound 形态**：webhook（要公网回调）vs 轮询（无需回调但有延迟）——选型影响部署。
4. **agent 作为节点 owner 的编排契约**：kanban-manager agent 怎么经 session-orchestrator 路由到 `kanban.*` dispatch，目前是 grounding placeholder（`kanban-on-ezagent/SKILL.md:110-117`，references/agent-orchestration.md 标"待编排 grounding 补全"）。
5. **痛点真相源"导图 vs 库"分歧**（`07-定版` §待补，待与 sy 当面对齐）。

---

## 附：本文核实过的事实（带 file:line）

- dev-together 8 命令定义：`.claude/skills/dev-together/SKILL.md:112-121`；委托链无 kanban：`:36-43`；台账规则：`:86-105`；机器返回闸：`:148-151`。
- kanban-on 融合原则（board 既是 work-source 又是 sink）：`.claude/skills/kanban-on-ezagent/SKILL.md:44-49`；8 命令融合表：`:119-149`；agent 可当 owner：`:100-108`。
- 9 阶段链 stage 枚举：`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/ci.ex:63-73`；CI 4 判据：`:22-37`；gate_state：`:58-61`；requirement_digest：`:83`。
- register_pr 人工断点：`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex:116`；github 无 inbound：`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex:9`；create_commit_status：`:117`。
- B1 relay actions：`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:702`；claim/owner 闸：`:483`/`:715`。
- Miro 有 inbound（对称缺口）：`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro/sync.ex:166`。
- 产品语义权威源：`docs/discuss/df-prd/07-定版-自举开发流程-10分钟.md` + `07-demo-接力链-多角色视角.html`。
- 6-26 流程升级（CURRENT_DATE/HTML/contributing/scrub/三段式 plan）：`docs/together/2026-06-26/dev-together-skill-improvement-plan.md:9-19`。
