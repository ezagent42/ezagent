# 两个 kanban skill 重新规划：与 dev-together(#1012) 对齐 + flow-redesign 一致

> 日期 2026-06-26 · 基线分支 `feat/kanban-agent-e2e` · 作者 sy（项目讨论 skill 已核实事实）
> 目标读者：接手改这两个 skill 的开发者
> 范围：`.claude/skills/kanban-off-ezagent/` 与 `.claude/skills/kanban-on-ezagent/`
> 不动：`dev-together` skill 本体（jjkysy 单写者，见 §6）、`apps/ezagent_plugin_kanban/` 代码（这是 skill 文案改，不是代码改）

---

## 0. 一句话结论

两个 kanban skill 是 dev-together 8 命令的 **board 融合 fork**。dev-together 在 #1012 这一轮升级了 5 件事（CURRENT_DATE 日界 / 数据驱动 HTML / contributing 必读台账 / 三段式 team-facing plan / 硬 scrub），**这 5 件 kanban 一条都没跟上**——因为 kanban 重写了全部 8 命令，dev-together 的升级不会自动传导过来。同时 flow-redesign（07 系列定稿）把「9 棒接力 + 钦定唯一真相源 + 交接即 gate + 测试先行 + 只做该功能 + drop 子树 + 三位一体」钉成了产品流程纪律，kanban 的 board 模型其实就是这条链，但**命令文案没把这几条纪律写进闸门**。这份 replan 给出每个 skill、每个命令的逐条修改清单（带 file:line）。

核心原则三条，贯穿所有修改：
1. **8 命令词锁死，绝不加新命令**（dev-together 6-26 已 grill 锁定，`dev-together-skill-improvement-plan.md:19`）。kanban 所有新增同样只能是「字段 / 章节 / 脚本 / 参考文件」，不能加第 9 个命令。
2. **board 是产品真相源、team-facing 产物是日志**——两条轴不混（off/on SKILL.md 已有「Two axes」段，保留并强化）。dev-together 的升级全落在「时间轴」产物（plan/review 的 HTML、contributing、CURRENT_DATE），kanban 要在自己重写的命令里把这些升级**复刻进来**，外加自己独有的「board 读写接线」。
3. **off 与 on 必须 1:1 平价**（on SKILL.md:155 引 `off-on-parity.md`）。任何一侧加的字段/章节，另一侧等价加；唯一差异永远只是「文件 vs dispatch」这一个 medium 维度。

---

## 1. 三路输入综合：要对齐什么

### 1.1 dev-together #1012 的 5 项升级（A–E，来自 `docs/together/2026-06-26/dev-together-skill-improvement-plan.md:9-13`）

| 代号 | 升级 | dev-together 落点 | kanban 现状 | kanban 要做 |
|---|---|---|---|---|
| **A** | 日界 = lead↔lead-agent 讨论，不是机器时间。`docs/together/CURRENT_DATE` flag + `advance_cycle_date.sh`，所有 `date +%F` 改读 flag | 新增 flag 文件 + 脚本 | off `init.md:8` `new_day.sh`、on `init.md:9` 直接 `<today>`，都隐含机器日期 | 两 skill 的 `<date>` 解析改为「先读 `docs/together/CURRENT_DATE`，无则回落机器日期」 |
| **B** | review 数据驱动 + HTML + 持久化。`gather_stats.sh`→`stats/cycle-data.json`→三章节 HTML | review.md→review.html + stats | off/on `review` 仍只产 `review.md` 纯文字 | review 产物升级为 `review.html`（读 stats json），**统计里加 board 维度**（见 §3/§4） |
| **C** | `contributing/` 跨 cycle 台账 + handoff 前后必读，`contributing_read_through` attestation 硬闸 | 新增 `docs/together/contributing/`（已存在 README.md）+ handoff/return 必填字段 | kanban handoff/return 无此字段 | handoff 下发前、return 返还前都加 `contributing_read_through` attestation |
| **D** | plan 改三段式 team-facing：§1 本周功能点缺口 / §2 缺口开发计划总览 / §3 按开发者→handoff（薄 plan 厚 handoff） | plan.md→plan.html 三段式 | off/on `plan` 是「board 快照 + 冲突图」单段 | plan 产物升级为三段式 `plan.html`，**§1 缺口直接由 board 派生**（board 是缺口的真相源，这正是 kanban 的融合优势） |
| **E** | 硬 scrub：plan/review 禁含 lead↔agent 讨论；内部讨论落 `notes/`，流程摩擦落 `contributing/` | `team-facing-scrub-checklist.md` | kanban plan/review 无 scrub 约束 | plan/review 加 scrub 闸 + 内部讨论分流到 `notes/`、摩擦分流到 `contributing/` |

补充两条方法论（plan §B `:155-161`、`jjkysy-skill-improve.md:13`）：**归属按 work-author**（agent 干的活算它背后管理人的 git 身份，按 PR author 归并回 `team.md` 行）。kanban 的统计章节要按这个口径，尤其 on（owner 可以是 agent）。

### 1.2 flow-redesign（07 定稿）的 7 条流程纪律（`docs/discuss/df-prd/07-定版-自举开发流程-10分钟.md`）

这 7 条是「9 棒接力链」的产品语义，kanban 的 board 模型就是这条链（`positioning→metric→pain→anchor→ux→feature→issue→test→pr`，off `board-format.md:37`），但**命令文案没把纪律写成闸门**：

| # | 纪律 | 该落在哪个命令的闸里 | 现状缺口 |
|---|---|---|---|
| F1 | **钦定唯一真相源**：每棒只把一件「钦定真相源」交下游，其余是它的附件 | `handoff`（交接时标注哪件 artifact 是钦定真相源） | board node 的 `artifact` 不区分「钦定 vs 附件」 |
| F2 | **交接即 gate**：上一棒真相源没过验收，下一棒不放行（如 spec 卡没写验收用例→不许开 issue） | `handoff`（6→7 gate）+ `close`（8→9 gate） | 命令没写「交接前先验上一棒真相源」 |
| F3 | **测试先行、绿才合**：测试用例 = spec 卡 Gherkin，一物三用 | `dive`（test 棒）+ `close`（PR 棒 gate） | dive 只说 TDD，没绑定「用例=上游 Gherkin」 |
| F4 | **只做该功能**：PR 只动 spec 卡范围，超范围砍 | `dive`（scope 闸）+ `push`/`close`（out-of-scope 判定） | 已有 out_of_scope 概念但没绑到「spec 卡范围」 |
| F5 | **不达标 drop 子树**：北极星阈值在 metric 棒钦定，PR 上线后实测，窗口内未达→drop 子树→反哺 pain 棒 | `review`（回收对照阈值 + drop 决策） | review 完全没有「指标回收 / drop 子树」环节 |
| F6 | **三位一体**：每个开发节点（issue/test/pr）必带产品(spec)+运营(changelog)两兄弟节点，缺则显式「待分配」 | `handoff`（建 N+1 节点时同时建两兄弟）+ `plan`（缺口检测） | 没有「三位一体」校验 |
| F7 | **工具供能力、真相落 ezagent**：飞书/Miro/GitHub/PostHog 只当采集器/视图/调用对象 | 贯穿（尤其 on 的 sync_* 投影） | on 已基本符合（board=真相，sync_* 是投影），off 要明确「外部链接是附件不是真相」 |

### 1.3 kanban 代码现状（`apps/ezagent_plugin_kanban/`，已逐文件核实）

on-ezagent 命令里引用的代码 file:line **已漂移**，且有一个人工断点必须在文案里讲清：

- **动作数 25，不是 24**（SKILL.md:30/154 写「24-action」=过时）。
- **on 命令引用的行号大面积漂移**，按当前代码应为：`claim_node` 实现 `kanban.ex:483`、`set_status` `:510`、`set_stage` `:424`/`stage_fits?` `:453`、`attach_artifact` `:531`、`set_metric` `:544`、`get_tree` `:558`（`ci_summaries` `:614`）、`@relay_actions` `kanban.ex:702`、`post_handle` `:705`、`owner_or_admin?` `:715`。连接器：`sync_github`→`connectors.ex:31`、`push_pr`→`:75`、`register_pr`→`:116`、`sync_prs`→`:193`。CI：`check_pr_gate` `ci.ex:22`、`gate_state` `:58`、`requirement_digest` `:83`、`ancestor_chain` `:117`。GitHub 出站：`create_commit_status` `github.ex:117`、`get_pull` `:88`、`create_issue` `:59`。（on 命令现写的 `kanban.ex:469-489`/`496-510`/`439-462` 等需逐条重核。）
- **register_pr 人工断点**（`connectors.ex:116`）：GitHub 侧**没有 inbound webhook**（`github.ex:9` moduledoc 明写），开 PR 发生在 GitHub 侧，ezagent 收不到回声，必须有人肉眼看到 PR 号、手工 dispatch `register_pr` 填进去。这一步同时卡住：硬 CI 门（`push_pr`→`:no_pr_registered`）、自动合并推进（`sync_prs` 跳过未登记节点）、B1 接力唤醒（`register_pr` ∈ `@relay_actions`）。**on 的 `close`/`return` 必须显式写出这个手工步骤**，不能假装自动。
- **agent-orchestration.md 的「待编排 grounding 补全」现在可以落地一半**：B1 接力链已存在——`@relay_actions [:claim_node, :set_status, :register_pr]`（`kanban.ex:702`）→ `post_handle/4`（`:705`）读 `BoardConfig.session_uri`（`board_session/1` `:719`）→ 绑定则 `relay_text/1`（`:728`）发带机器标记的公告 `[kanban:<event>] by <caller>` → `Shared.session_dispatch/3`（`shared.ex:72`，自铸 session-send cap、`reply: :ignore` fire-and-forget）打回 `session.send` 重入路由唤醒下一个 agent。**这就是「chat-@ → kanban-manager agent 驱动 board」缺的那段路由 wiring 的真身**，应把 agent-orchestration.md 里这部分从 placeholder 升级为 grounded。

### 1.4 接线缺口（来自第 4 路研究，定调修改边界）

- dev-together 本体对 kanban **零感知**，kanban 是它的单向 fork。**本 replan 不试图让 dev-together 反向调用 kanban**（那是 jjkysy 单写者的独立线，且 #1012 改进 plan 里根本没提接 kanban）。我们只改 kanban 两个 skill，让它们「追上」dev-together 6-26 的产物形态 + 补齐自己的 board 接线。
- `handoff-standard.md` 在 dev-together / off / on **各存一份拷贝**。本 replan **不动这份**（跨 skill 抽公共层是另一个 owner 的事），只在 kanban 侧标注「DoD 增量」（board 维度）以局部补丁形式写在命令里，避免改公共文件。

---

## 2. 对齐矩阵（命令 × 要加什么）

「读写看板接线」= 命令必须读 board（work-source）或写 board（write-back sink）。off=改 `docs/board.md` 文件，on=dispatch `kanban.*`。下表「B-读/B-写」列就是接线要求；A–F 列是 §1.1/§1.2 的对齐项。

| 命令 | B-读看板 | B-写看板 | A 日界 | B HTML/stats | C contributing | D 三段plan | E scrub | flow-redesign |
|---|---|---|---|---|---|---|---|---|
| `init` | — | —（off 确认文件存在 / on `get_tree` 探活） | ✅改 date 解析 | — | — | — | — | — |
| `plan` | ✅读全板分类 active/ready/blocked | — | ✅ | ✅产 plan.html | — | ✅三段式 | ✅ | F6 缺口检测 |
| `handoff` | ✅读父节点真相源 | ✅建 N+1 节点(claimable) | ✅ | — | ✅读前必读+attestation | — | — | F1 钦定真相源·F2 6→7 gate·F6 三兄弟 |
| `dive` | ✅读节点+handoff | ✅claim+status=doing | ✅ | — | — | — | — | F3 测试先行·F4 只做该功能 |
| `return` | — | ✅写进度(status/artifact/metric) | ✅ | — | ✅返还前必读+attestation | — | — | F3 |
| `push` | — | —（只读 returns 排栈，不写板） | ✅ | — | — | — | — | F4 out-of-scope 对照 spec |
| `close` | — | ✅推进节点(status/stage/artifact/sync_github) | ✅ | — | — | — | — | F2 8→9 gate·register_pr 断点(on) |
| `review` | ✅读全板对账 | ✅修漂移+刷投影 | ✅ | ✅产 review.html+stats | 摩擦写 contributing | — | ✅ | F5 drop 子树+指标回收 |

---

## 3. kanban-off-ezagent 修改清单

> 路径前缀 `.claude/skills/kanban-off-ezagent/`

### 3.1 SKILL.md

- **[SKILL.md:73-86 命令表]** 在表头注释补一句「产物形态对齐 dev-together 6-26：plan→`plan.html`、review→`review.html`+`stats/`」。`plan` 行 one-liner 改为「三段式 team-facing plan.html（§1 板缺口/§2 总览/§3 per-dev→handoff）」；`review` 行改为「数据驱动 review.html + board 对账 + **drop 子树决策**」。
- **[SKILL.md:88-100 Ledger rules]** 新增三条：
  - 「**CURRENT_DATE 日界**：所有 `<date>` 先读 `docs/together/CURRENT_DATE`，无则回落机器日期（对齐 dev-together A）。」
  - 「**contributing 必读**：`handoff` 下发前、`return` 返还前必读 `docs/together/contributing/`，产物带 `contributing_read_through` attestation（对齐 dev-together C）。」
  - 「**team-facing scrub**：`plan.html`/`review.html` 禁含 lead↔agent 讨论；内部讨论落 `notes/`，流程摩擦落 `contributing/`（对齐 dev-together E）。」
- **[SKILL.md:54-66 Roles + 新增 §钦定真相源]** 新增一段「**钦定唯一真相源（F1）**：每个节点的 `artifact` 区分 `canonical:true`（钦定交下游的那一件）与附件；handoff 只认上一棒钦定的那件派生需求（对齐 07 链）。」
- **[SKILL.md 新增 §三位一体]**：「**三位一体（F6）**：开发棒（issue/test/pr）的 `add_node` 必须同时建产品(spec)+运营(changelog)两兄弟节点，缺则建 `status:unassigned` 占位并标『待分配』。」

### 3.2 commands/init.md

- **[init.md:8]** `new_day.sh` 调用前先解析日期：新增「先 `cat docs/together/CURRENT_DATE`（dev-together A 翻篇 flag），取不到再 `date +%F`；用解析出的日期建 `docs/together/<date>/`」。`new_day.sh` 若内部写死 `date +%F`，在脚本里改读 flag（见 §3.7）。

### 3.3 commands/plan.md（升级为三段式 plan.html + board 派生缺口）

- **[plan.md:17-20 写产物]** 产物从 `plan.md` 升级为 `plan.html`，三段式（dev-together D）：
  - **§1 本周功能点缺口** = **直接由 board 派生**：扫 `docs/board.md`，列出「ready（上游 done 待认领）+ blocked + 推进慢的 active」节点作为缺口。这是 kanban 相对纯 dev-together 的融合优势——缺口不靠人脑列，是 board 真相源算出来的。
  - **§2 缺口开发计划总览** = active/ready/blocked 三类的协调视图 + 冲突图（保留现有 `plan.md:11-16` 的分类逻辑）。
  - **§3 按开发者规划** = 每个 active 节点 owner + 指向其 `handoffs/<task>.md`（薄 plan 厚 handoff）。
- **[plan.md:22-29 completeness gate]** 保留现有「board node id 必填」，**新增**：「§1 缺口必须可回指 board 节点 id；§3 每条必须指向一个 handoff 文件」。
- **[plan.md 新增 scrub 闸]** 加一句「plan.html 是 team-facing，禁含 lead↔agent 讨论（dev-together E）；内部权衡落 `docs/together/<date>/notes/`」。
- **[plan.md:36-37]** 「unplanned return」段保留（与 dev-together return 元数据一致）。

### 3.4 commands/handoff.md（F1 钦定真相源 + F2 6→7 gate + F6 三兄弟 + C 必读）

- **[handoff.md:10-13 add_node]** 保留「建 N+1 claimable 节点」；**新增 F6**：「若 N+1 是开发棒（issue/test/pr），同时 `add_node` 建 spec(产品) + changelog(运营) 两兄弟节点，缺则占位 `status:unassigned` 标『待分配』。」
- **[handoff.md:14-20 需求来自节点]** 强化 F1：「需求只从上一棒**钦定真相源**（`artifact` 标 `canonical:true` 的那件）派生，附件不作数。在 handoff 顶部注明『本棒钦定真相源 = <node>.<artifact ref>』。」
- **[handoff.md:21-24 brainstorm+对抗 review 之前]** **新增 F2 交接 gate**：「派活前先验上一棒真相源过没过它自己的验收——例：relay 到 `issue` 棒前，`feature` 节点的钦定 spec 卡必须含 Gherkin（given/when/then 或 当/则/如果）；没写全 → **不许 handoff**，退回上一棒。」（与 on 的 `ci.ex:22` `gherkin` 判据同义，off 用文本检查。）
- **[handoff.md:25-28 DoD]** DoD 增量已含「board 节点推进」，**新增**：「handoff 顶部必带 `contributing_read_through: <commit/mtime>` attestation——下发前必读 `docs/together/contributing/`（dev-together C）。」

### 3.5 commands/dive.md（F3 测试先行 + F4 只做该功能）

- **[dive.md:11-15 claim]** 保留改 `docs/board.md` owner/status；**新增**：「读 handoff 时确认本棒的**钦定真相源 ref**，dive 只围绕它干。」
- **[dive.md:17-22 实现]** **新增 F3**：「若本节点是 `test` 棒，测试用例**不另写**，直接取上游 `feature` 节点钦定 spec 卡的 Gherkin（一物三用：验收=用例=PR gate 判据）。」**新增 F4**：「PR 只动该节点 spec 卡范围内的东西，超范围（顺手美化/改无关页面）一律不做——对照 `plan.md` 冲突图 + spec 卡 scope 自查。」

### 3.6 commands/return.md（C 必读 attestation）

- **[return.md:19-33 元数据块]** 在元数据块加一行 `> **contributing_read_through:** <commit/mtime>`（返还前必读 `contributing/`，dev-together C）。
- **[return.md:8-10 DoD]** 保留「board 节点推进 + artifact 链」。

### 3.7 commands/push.md

- **[push.md 整体]** push 只排栈不写板，**无需加 board 写接线**。仅 **F4 增量**：reconciliation 的 `out-of-scope` 判定改为「对照该节点 spec 卡范围」，超 spec 卡范围的产物标 out-of-scope（push.md:28）。

### 3.8 commands/close.md（F2 8→9 gate）

- **[close.md:11-13 gate 校验]** 已列全套 gate；**新增 F2 8→9**：「合并前确认 `test` 棒节点挂的测试套件对应上游 Gherkin 且全绿——不绿不许合（与 on 的 `check_pr_gate` `test_green` 判据同义）。」
- **[close.md:23-25 advance board]** 保留改 `docs/board.md` 节点 status/stage/artifact。

### 3.9 commands/review.md（B HTML/stats + F5 drop 子树）

- **[review.md:9 产物]** 升级为 `review.html`（读 `docs/together/<date>/stats/cycle-data.json`，dev-together B），三章节：§1 昨日工作统计 / §2 开发效能（dev-time=最早 commit→merge）/ §3 数据统计聚焦 feature-points。
- **[review.md:9-25 covering]** 在「Board reconcile」后**新增 F5 drop 子树环节**：「对已上线（merged）的 `pr` 节点，回收其祖先链 `metric` 棒钦定的北极星实测值；窗口内未达阈值（如 7 天阅读<500）→ 在 board 上 **drop 该功能子树**（off 用 `drop_subtree` 语义=删子树+追加一条到图级 drops 记录），并反哺 `pain` 棒重选痛点。」（对应 on 代码 `drop_subtree` `kanban.ex:130→384`。）
- **[review.md:27-34 Required accounting]** 统计表**新增**：「今日有几个 `pr` 节点回收了指标？几个达标/未达标→drop？」+ 「按 work-author 归并（agent 活算管理人，dev-together 归属口径）」。
- **[review.md 新增]** 摩擦写法：「流程摩擦不写进 review.html，落 `docs/together/contributing/`（dev-together C/E）。」

### 3.10 scripts/ + references/

- **[scripts/new_day.sh]** 改为读 `docs/together/CURRENT_DATE`（无则 `date +%F`）——对齐 dev-together A。若 dev-together 已提供 `advance_cycle_date.sh`，复用其 flag 文件，不自造第二套。
- **[scripts/validate_skill.sh]** 新增断言：命令文案含 `CURRENT_DATE`、`contributing_read_through`、三段式 plan、drop 子树、钦定真相源关键词。**注意**：不要断言运行期产物（`plan.html`/`stats/cycle-data.json` 首个 cycle 前不存在，会误失败——与 dev-together skill-plan 同一坑，`dev-together-skill-improvement-plan.md` 已点明 validate 只断言 skill 自身内容）。
- **[references/board-format.md:58]** `stage_fits?` 行号 `kanban.ex:413-438` 漂移，更新为 `:453`（当前 `stage_fits?`）。`artifact` 字段（`:41-44`）**新增** `canonical:` 可选键（F1 钦定真相源标记）。
- **[references/handoff-standard.md]** 不改文件本体（跨 skill 拷贝，§6）；DoD 的 board 增量以补丁形式写在 handoff.md 命令里（已有）。

---

## 4. kanban-on-ezagent 修改清单

> 路径前缀 `.claude/skills/kanban-on-ezagent/`。**on 与 off 1:1 平价**：off 加什么 on 等价加，差异只在「dispatch vs 文件」。下面只列 on 独有 / 行号漂移 / register_pr 断点 / agent-orchestration grounding。

### 4.1 SKILL.md

- **[SKILL.md:30/64/154 「24-action」]** 全部改为 **25-action**（当前代码 25 个动作，`kanban.ex:42-247` 声明）。
- **[SKILL.md:119-132 命令表]** 与 off §3.1 等价升级（plan→plan.html 三段式、review→review.html+stats+drop）；命令表注释补「产物对齐 dev-together 6-26」。
- **[SKILL.md:134-149 Ledger rules]** 与 off 等价加 CURRENT_DATE / contributing / scrub 三条。
- **[SKILL.md:100-117 on superpower / chat-orchestration]** 把「**待编排 grounding 补全**」从纯 placeholder 升级：补一句「relay wiring 已 grounded——`@relay_actions`（`kanban.ex:702`）+ `post_handle`（`:705`）+ `BoardConfig.session_uri` 绑定（`board_session/1` `:719`）+ `relay_text`（`:728`）+ `Shared.session_dispatch/3`（`shared.ex:72`）构成『动作完成→公告→重入 session.send 唤醒下一个 agent』的接力链。剩 placeholder 仅『kanban-manager agent 定义 + 路由规则』」（详见 §4.10）。

### 4.2 commands/init.md

- **[init.md:9]** 与 off 等价加 CURRENT_DATE 日期解析。**[init.md:12-17]** `get_tree` 探活 + 行号核对（`get_tree` 当前 `kanban.ex:558`，`KanbanData.board_snapshot` 引用核对）。

### 4.3 commands/plan.md（三段式 + get_tree 缺口派生）

- 与 off §3.3 等价，差异：§1 缺口由 **dispatch `get_tree`**（`kanban.ex:558`）读 `result.tree.nodes` 派生，而非读文件。
- **[plan.md:11-14 get_tree dispatch]** 行号核对：`get_tree` `:558`；保留 `target = with_action(uri, :kanban, :get_tree)`。
- **[plan.md:20-24 产物]** 升级 plan.html 三段式 + scrub 闸（等价 off）。

### 4.4 commands/handoff.md（F1/F2/F6 + C + 行号）

- 与 off §3.4 等价，写接线用 **dispatch `add_node`**（`kanban.ex` 声明 `:42`→impl `:299`；on 现写 `kanban.ex:686-697 new_node` 需重核为当前 `add_node` 路径）。
- **F2 6→7 gate 用代码判据**：「relay 到 issue 棒前，dispatch 后端的 `ci.ex:22 check_pr_gate` 的 `gherkin` 判据（`ci.ex` 正则查 given/when/then/当/则/如果）必须对 feature 节点为真。」
- **F1 钦定真相源**：on 的 `requirement_digest`（`ci.ex:83`）已沿祖先链汇总产品上下文——handoff 注明「钦定真相源 = `requirement_digest` 入选的那件 artifact」。
- **C attestation**：等价加 `contributing_read_through`。
- **[handoff.md:34-36 claimer 可为 agent]** 保留，并指向 §4.10 grounded relay。

### 4.5 commands/dive.md（F3/F4 + 行号）

- 与 off §3.5 等价，写接线 **dispatch `claim_node` + `set_status doing`**。**行号漂移修正**：`claim_node` `kanban.ex:483`（on 现写 `:469-489`）、`set_status` `:510`（现写 `:496-510`）、`owner_or_admin?` `:715`（正确）。
- F3/F4 等价加（test 棒用上游 Gherkin、PR 只动 spec 范围）。

### 4.6 commands/return.md（C + 行号 + dispatch 写接线）

- 与 off §3.6 等价加 `contributing_read_through`。
- **行号漂移修正**：`set_status` `:510`、`attach_artifact` `:531`（现写 `:517-518`）、`set_metric` `:544`（现写 `:530-537`）、`owner_or_admin?` `:715`。

### 4.7 commands/push.md

- 与 off §3.7 等价（只排栈、F4 对照 spec 卡）。on 的 push 本就「file-only 不 dispatch」（push.md:5-7），保留。

### 4.8 commands/close.md（F2 8→9 gate + register_pr 人工断点 + 行号）

- **[close.md:23-33 advance by dispatch]** 行号漂移修正：`set_status` `:510`、`set_stage` `:424`/`stage_fits?` `:453`（现写 `:439-462`）、`attach_artifact` `:531`、`sync_github` 声明 `:169`→impl `connectors.ex:31`（现写 `:169/:656` 需重核）。
- **[close.md 新增 register_pr 人工断点]** **这是 on 独有、必须显式写出的现实**：「GitHub 无 inbound webhook（`github.ex:9`），开 PR 后 ezagent 收不到 PR 号回声。leader 在 close 时必须**人工 dispatch `register_pr`**（`connectors.ex:116`，传 `%{id, pr:"#NN"}`）把 PR 号填回节点——否则 `push_pr` 硬 CI 门返回 `:no_pr_registered`、`sync_prs` 跳过该节点、B1 接力不唤醒下一个 agent。这是当前已知人工断点，不要假装自动。」
- **[close.md:23 F2 8→9 gate]** 「dispatch `push_pr`（`connectors.ex:75`）→ 后端 `check_pr_gate`（`ci.ex:22`）算 `test_green` 等 4 判据 → `gate_state`（`ci.ex:58`）映射成 GitHub commit status（`create_commit_status` `github.ex:117`，context `ezagent/ci-gate`）。配了 branch protection 才真能挡合并；不绿不合。」

### 4.9 commands/review.md（B HTML/stats + F5 drop + agent 归属 + 行号）

- 与 off §3.9 等价升级 review.html + stats + drop 子树（on 用 dispatch `drop_subtree`，`kanban.ex:130`→`:384`）。
- **[review.md:21-24 刷投影]** 保留 `export_markmap`/`sync_miro`/`sync_prs`；行号核对（`export_markmap` `:146`→`:621`、`sync_prs` `:201`→`connectors.ex:193`；现写 `:201/:668` 需重核）。
- **[review.md:25-27 stats]** on 独有：统计「agent 驱动 vs 人驱动节点数」，且按 work-author 归并（agent 活算管理人，dev-together 归属口径）。
- **F5 指标回收**：review dispatch `get_tree` 读 `pr` 节点 `metrics` 实测值对照 `metric` 棒钦定阈值，未达→`drop_subtree`+反哺 `pain` 棒。

### 4.10 references/agent-orchestration.md（placeholder → 半 grounded）

- **[agent-orchestration.md:52-63 待编排 grounding 补全]** 把「routing rule」这一条**从 placeholder 升级为 grounded**：B1 接力 wiring 已存在——
  - `@relay_actions [:claim_node, :set_status, :register_pr]`（`kanban.ex:702`）：这三个动作返回 `{:ok}` 后触发接力。
  - `post_handle/4`（`kanban.ex:705`）：引擎在 handler 成功后调用，读 `BoardConfig.read(self_uri).session_uri`（`board_session/1` `:719`）。
  - 绑定了 session → `relay_text/1`（`:728`）生成机器标记公告 `[kanban:<event>] by <caller>`（claimed/status/pr_registered）→ `Shared.session_dispatch/3`（`shared.ex:72`：自铸 session-send cap、caller=self_uri、`reply: :ignore`）打到 `session.send` 重入路由，唤醒下一个 agent。
  - 被唤醒的 agent 经 `get_tree` 读真相源——消息只是触发器。
  - 绑定入口：`bind_session`（`connectors.ex:249`）。
- **仍是 placeholder（继续标注）**：`kanban-manager` agent 的**定义**（system prompt / 允许的 `kanban.*` caps）+ 「chat-@ 怎么路由到这个 agent」的路由规则——repo 里 grep `kanban-manager` 仍为空，这块未建。
- **[agent-orchestration.md:14-15]** `kanban_actions.ex:321-327` ctx 构造行号核对（world 前端 `apps/ezagent_plugin_world/.../kanban_actions.ex`）。

### 4.11 references/live-board-access.md + off-on-parity.md + scripts

- **[live-board-access.md]** 「24-action」→「25-action」；全表 file:line 按 §1.3 当前值重核（这是 on 行号漂移的集中地）。
- **[off-on-parity.md]** 新增 5 行平价映射：CURRENT_DATE 日界、plan.html 三段式、review.html+stats、contributing attestation、drop 子树——证明两 skill 加的对齐项仍 1:1。
- **[scripts/validate_skill.sh]** 与 off 等价加断言（同样**不**断言运行期产物）。

---

## 5. 每个 skill 的修改清单速查（给执行者打勾用）

### kanban-off-ezagent
- [ ] SKILL.md：命令表注释 + Ledger 加 3 条（CURRENT_DATE/contributing/scrub）+ 钦定真相源段 + 三位一体段
- [ ] init.md：CURRENT_DATE 日期解析
- [ ] plan.md：升级 plan.html 三段式（§1 缺口由 board 派生）+ scrub 闸
- [ ] handoff.md：F1 钦定真相源 + F2 6→7 gate + F6 三兄弟 + contributing_read_through
- [ ] dive.md：F3 测试先行（用上游 Gherkin）+ F4 只做 spec 范围
- [ ] return.md：contributing_read_through 元数据行
- [ ] push.md：out-of-scope 对照 spec 卡
- [ ] close.md：F2 8→9 gate（测试绿才合）
- [ ] review.md：review.html+stats + F5 drop 子树 + 指标回收 + work-author 归属 + 摩擦落 contributing
- [ ] scripts/new_day.sh：读 CURRENT_DATE；validate_skill.sh：加关键词断言（不断言运行期产物）
- [ ] references/board-format.md：`stage_fits?`→`:453`、artifact 加 `canonical:` 键

### kanban-on-ezagent
- [ ] SKILL.md：24→25 action（3 处）+ 命令表/Ledger 等价升级 + superpower 段标 relay 已 grounded
- [ ] init.md：CURRENT_DATE + get_tree 行号核对
- [ ] plan.md：三段式 plan.html（§1 缺口 dispatch get_tree 派生）+ scrub
- [ ] handoff.md：F1/F2(ci.ex:22 gherkin)/F6 + contributing_read_through + add_node 行号
- [ ] dive.md：F3/F4 + claim_node`:483`/set_status`:510` 行号修正
- [ ] return.md：contributing_read_through + attach`:531`/set_metric`:544` 行号修正
- [ ] push.md：out-of-scope 对照 spec 卡
- [ ] close.md：F2 8→9（push_pr→ci.ex:22→github.ex:117 ci-gate）+ **register_pr 人工断点显式写出** + 行号修正
- [ ] review.md：review.html+stats + F5 drop_subtree`:384` + agent/人归属 + 投影行号核对
- [ ] references/agent-orchestration.md：relay wiring 升级为 grounded（kanban.ex:702/705/719/728 + shared.ex:72），kanban-manager agent 定义仍 placeholder
- [ ] references/live-board-access.md：24→25 + 全表 file:line 重核
- [ ] references/off-on-parity.md：加 5 行新平价映射
- [ ] scripts/validate_skill.sh：等价断言

---

## 6. 不做的事（边界，避免越界）

1. **不改 dev-together skill 本体**。dev-together 是 jjkysy 单写者，在 `chore/dev-together-skill-improve` 分支续做（`jjkysy-skill-improve.md`）。#1012 是 docs-only，skill 本体最后改动是 #965。我们让 kanban **追上** dev-together 6-26 的产物形态，不反向改 dev-together、不让 dev-together 调用 kanban（其改进 plan 根本没提接 kanban）。
2. **不抽 handoff-standard.md 公共层**。三份拷贝（dev-together/off/on）抽公共来源是另一个 owner 的事；kanban 侧的 board DoD 增量以命令内补丁形式承载，不动公共文件。
3. **不加第 9 个命令**。8 命令词锁死（dev-together grill 结论）。所有新增 = 字段/章节/脚本/参考文件。
4. **不在 validate_skill.sh 断言运行期产物**。`plan.html`/`stats/cycle-data.json`/`CURRENT_DATE` 首个 cycle 前不存在，断言会误失败（与 dev-together skill-plan 同坑）。validate 只断 skill 自身内容。
5. **不改 kanban 代码**（`apps/ezagent_plugin_kanban/`）。本 replan 全是 skill 文案/参考/脚本改。register_pr 人工断点是**如实写进文案**，不是去补 webhook（补 GitHub inbound 是独立的代码工作，另立 issue）。
6. **CURRENT_DATE flag 复用 dev-together 的**，不自造第二套 flag/脚本——避免两套日界打架。

---

## 7. 落地顺序建议

1. 先 **on 行号重核 + 24→25 修正**（`live-board-access.md` + 各命令 file:line）——这是事实纠错，无设计风险，先做掉。
2. 再 **A/C/E 三项机械对齐**（CURRENT_DATE 解析、contributing_read_through 字段、scrub 闸）——off/on 等价加，纯加字段/句子。
3. 再 **D plan 三段式 + B review HTML/stats**——产物形态升级，工作量集中在 plan/review 两个命令 + validate 断言。
4. 再 **flow-redesign 7 条纪律**（F1–F7）——这是把 07 定稿的产品纪律写成命令闸门，需要对照 `ci.ex`/`kanban.ex` 判据，最花脑力（尤其 F5 drop 子树 + F2 gate）。
5. 最后 **agent-orchestration grounding 升级 + register_pr 断点写实**——把已存在的 B1 接力链 wiring 落成 grounded 文档，把 register_pr 人工断点如实写进 on `close`。
6. 全程保持 **off↔on 平价**：每改一处 off，立刻同步等价的 on（反之亦然），改完跑两侧 `validate_skill.sh`。
