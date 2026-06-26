# 实施计划 — Phase 5：kanban 团队流程的统一整理（开发完收口）

> 日期 2026-06-26 ｜ 基线分支 `feat/kanban-agent-e2e`（含 #1004/#1007 kanban-as-role + RF-1..9 + #1012）
> 上位设计（真相源，必读）：
> - SPEC：`docs/discuss/2026-06-26-kanban-team-flow-spec.md` §7「Phase 5 — 统一整理」+ §3 artifact 收敛
> - 流程真相源：`docs/discuss/2026-06-26-kanban-flow-redesign/flow-redesign.md` §3「artifact 模型」+ §6「github 边界」
> - github 入站细节：`docs/discuss/2026-06-26-kanban-flow-redesign/missing-capabilities.md` §2
> - skill 重规划：`docs/discuss/2026-06-26-kanban-flow-redesign/kanban-skills-replan.md`

---

## Goal

把整条 kanban 团队开发流程「开发完」之后散落的零碎收口成一份可维护的最终态。具体五件事：

1. **删 `attach_code_file`**（钉 commit sha 的 github blob 窄特例）——artifact 收敛成 inline content / repo 路径 / uploads URI 三条「读得到」的路后，sha/pr blob 不再需要（flow-redesign §3，`connectors.ex:152`）。
2. **reconcile B1 接力**——核对现有 relay 接力骨架（`post_handle` + `@relay_actions` + `session_dispatch`），复用对的、删过时的、对齐 SPEC §4「接力无环 DAG」。
3. **对齐 2 个 kanban skill**（`kanban-off-ezagent` / `kanban-on-ezagent`）——按 `kanban-skills-replan.md` 追上 dev-together #1012 的产物形态 + 补 board 接线 + 修行号漂移。
4. **收敛本轮 discuss 文档**——把 SPEC + flow-redesign + missing-capabilities + replan 收敛成最终 design + plan + readme 三件套。
5. **删死代码**——删整体流程不再需要的零碎动作/字段/前端入口，全仓 grep 扫干净。

> ⚠️ 范围边界：本计划**只做 Phase 5 收口**。github 抽出独立 plugin（能力 GH/Phase 2）、worker agent 接线（能力 E/Phase 3）、需求自动拆解（能力 F/Phase 4）**不在本计划**——SPEC §7 已把 B2 github 部分划归 Phase 2，本计划不在原地 reconcile github 出站代码。

---

## Architecture

**三层铁律（违反即 stop）**：
- 连接器/Behavior 实现在 **plugin**（`apps/ezagent_plugin_kanban/`）；UI 在 **world**（`apps/ezagent_plugin_world/`）；**core 不碰**。
- 跨 Kind 只能走 `Ezagent.Invocation.dispatch/1`（P14）——禁止 `PubSub.broadcast` 到 inbound topic。已核实 kanban plugin 内**无** `PubSub.broadcast`（grep 为空），B1 relay 走 `Shared.session_dispatch/3` 注入 `{:dispatch}` effect，合规。
- Behavior 只 `use Ezagent.Lifecycle`（kanban.ex 已是），禁止重新引入 `use Ezagent.Behavior` / `init_slice` / `invoke/4`。

**当前 kanban Behavior 形态（已核实）**：
- `Ezagent.Behavior.Kanban`（`kanban.ex`）= `action/3` 宏声明（每个动作含 `args/returns/caps/modes`）+ `def handle_<x>(a,c)` 薄转发。
- 连接器实现体在 `Ezagent.Behavior.Kanban.Connectors`（`connectors.ex`），主模块 `:679` 行薄转发 `handle_attach_code_file → Connectors.attach_code_file`。
- `required_caps/0`（`kanban.ex:255-285`）当前列 **25 个动作**，cap 的 kind 轴声明 `:any`（kanban-as-role：运行时按宿主 `Entity.Agent` type 替换成 `:agent`）。
- B1 relay：`@relay_actions [:claim_node, :set_status, :register_pr]`（`kanban.ex:702`）+ `post_handle/4`（`:705`）+ `board_session/1`（`:719`）+ `relay_text/1`（`:728`）+ `Shared.session_dispatch/3`（`shared.ex:72`）；入口 `bind_session`（`connectors.ex:249`）。已有 `relay_test.exs`（4 tests）+ `shared_test.exs` 覆盖、绿。

**artifact 收敛后的三条合法路（flow-redesign §3）**：① inline content（≤64KB，进快照）② repo 路径（仓库存证，能力 G）③ uploads URI（`attach_upload`）。`attach_code_file` 的 github blob（sha 钉死）**不在三条里**——删。Excalidraw 内嵌画图走 inline content（②路），不受影响。

---

## Global Constraints

每个任务都遵守：

- **TDD 五步**：写失败测试 → 跑红（确认按预期失败）→ 实现 → 跑绿 → commit。
- **每任务收尾 gate（全绿才 commit）**：
  ```bash
  # 1. 单元/集成测试（umbrella 上下文，经 mise OTP27/1.18 + PG）
  docker compose -f docker-compose.pg.yml up -d
  MIX_ENV=test mise exec -- mix ecto.create && MIX_ENV=test mise exec -- mix ecto.migrate
  mise exec -- mix test apps/ezagent_plugin_kanban/test
  # 2. 不变式 gate
  mise exec -- mix ezagent.check_invariants.lifecycle
  mise exec -- mix ezagent.arch.scan
  # 3. 格式（只 check，不全仓 rewrite；只 format 改过的文件）
  mise exec -- mix format --check-formatted
  ```
- **e2e + 截图**：碰 world UI 的任务用 agent-browser 起 headless Chrome（远程 IP `100.64.0.27`），每个有意义步骤（配置→打开看板→操作→结果）都截图，不只最终态。
- **per-app 隔离测试无效**——必须 umbrella 根 `mix test apps/<app>/test`。
- **commit 信息**：Conventional Commits + 结尾 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。
- **任务依赖**：Task 3 依赖 Task 1（删动作后 action 数 25→24，skill 文案的 action 计数要写最终值 24）；Task 5 在 Task 1-4 之后做全仓死代码 sweep；Task 4 收敛文档放最后但可与 Task 5 并行。

---

## Task 1 — 删 `attach_code_file`（三层全删 + 移出白名单/required_caps）

**为什么**：artifact 收敛成三条「读得到」的路后，sha 钉死的 github blob 窄特例下线（flow-redesign §3「结论：废弃 attach_code_file」）。

### Files（精确路径 + 行号，已核实）

| 文件 | 删除点 |
|---|---|
| `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex` | `:193-199` action 声明块；`:275` required_caps 列表里 `:attach_code_file,` 一行；`:679` `def handle_attach_code_file/2` 薄转发 |
| `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex` | `:150-189` `def attach_code_file/2` 实现体（连同 `:150-151` 注释）；`:8` 与 `:12` moduledoc 里 `attach_code_file` 字样 |
| `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` | `:242` `@kanban_actions` sigil 里 `kanban.attach_code_file` 一项 |
| `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex` | `:150-157` `handle_dispatch(.., "kanban.attach_code_file", ..)` 子句；`:20` moduledoc 字样 |
| `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx` | `:475-487` 「挂代码文件」按钮整块（含 `:480-483` 两个 `window.prompt` + `onAction("kanban.attach_code_file", ...)`） |

> 注：`connectors.ex:173` 的 `kind: "github_file"` 在 attach_code_file 实现体内，随实现体一起删。前端对 artifact 是**通用渲染**（`Kanban.tsx` 无 `"github_file"` 专门分支，grep 为空），已挂的历史 github_file artifact 仍按通用 Paperclip 渲染，不报错；不需要 migration。`Paperclip` import（`Kanban.tsx:2`）在 `:388/:451/:458` 仍用到，**不删 import**。

### Interfaces（删除后不变量）

- `Ezagent.Behavior.Kanban.required_caps/0` 返回的 map **24 个 key**，不含 `:attach_code_file`。
- `function_exported?(Ezagent.Behavior.Kanban.Connectors, :attach_code_file, 2) == false`。
- dispatch `kanban.attach_code_file` 经 world `kanban_actions.ex` 落到 fallback 子句（`:159-160`）返回 `error:unsupported_action`。

### 步骤（bite-sized，TDD）

1. **写失败测试**（新文件或追加到 `apps/ezagent_plugin_kanban/test/behavior/kanban_test.exs`）：
   ```elixir
   test "attach_code_file 已下线：不在 required_caps、Connectors 无该函数" do
     caps = Ezagent.Behavior.Kanban.required_caps()
     refute Map.has_key?(caps, :attach_code_file)
     assert map_size(caps) == 24
     refute function_exported?(Ezagent.Behavior.Kanban.Connectors, :attach_code_file, 2)
   end
   ```
2. **跑红**：`mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/kanban_test.exs` —— 期望 `refute Map.has_key?` 失败（当前还在）+ `map_size == 25`。
3. **删 plugin 三处**（kanban.ex:193-199 / :275 / :679）+ **删 connectors 实现体**（:150-189 + moduledoc :8/:12）。
4. **跑绿**：同上测试文件 → 绿。
5. **删 world 后端**（world_live.ex:242 白名单项 + kanban_actions.ex:150-157 子句 + :20 moduledoc）。
6. **删 world 前端**（Kanban.tsx:475-487 按钮块）。
7. **格式化改过的 .ex**：`mise exec -- mix format apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex`；前端 `pnpm` 侧按 world 既有 lint。
8. **全仓 grep 验零**（验收）：
   ```bash
   grep -rn "attach_code_file\|github_file" apps/ --include=*.ex --include=*.exs --include=*.tsx --include=*.ts
   ```
   期望 = 空。

### Run + 期望

```bash
mise exec -- mix test apps/ezagent_plugin_kanban/test          # 期望 60 tests（59+1 新）, 0 failures, 7 excluded
mise exec -- mix ezagent.check_invariants.lifecycle            # 绿（未引入 use Ezagent.Behavior 等）
mise exec -- mix ezagent.arch.scan                            # 绿（arch.scan 未硬编码动作数，已核实 :330 只是注释）
mise exec -- mix format --check-formatted                      # 绿
```
**world e2e + 截图**：起 world 前端，打开任一看板节点详情 → 截图证明「挂代码文件」按钮已消失（对比删除前截图）；「加链接 / 上传文件 / 画图」三个按钮仍在。

### commit

`refactor(kanban): 删 attach_code_file（sha/pr blob 下线，artifact 收敛成三条读得到的路）`

---

## Task 2 — reconcile B1 接力（复用对的 / 删过时的，对齐 SPEC §4）

**为什么**：PR #1017 的零碎 B1 提交（bind_session/post_handle 接力）是「整体设计之前」的，SPEC 要求 Phase 5 reconcile：复用对的、删过时的、对齐本 spec（SPEC §7、flow-redesign §6）。

**核实结论（带证据）**：现有 B1 relay 骨架**就是 SPEC §4 要的「接力无环 DAG」形态**，已被 `relay_test.exs`（4 tests，绿）证明，且 flow-redesign §4.10 把它判定为「已 grounded」。所以本任务**以「复用 + 加固验收」为主**，删除面很小：

- **复用（保留，不动逻辑）**：`kanban.ex:699-737`（@relay_actions/post_handle/board_session/relay_text）+ `connectors.ex:249-256`（bind_session）+ `shared.ex:69-79`（session_dispatch）。P14 合规（无 PubSub.broadcast）。
- **要对齐 SPEC §4「精确命中防环」**：relay 公告文本 `relay_text/1`（`kanban.ex:728-737`）当前对 `:set_status` 一律出 `[kanban:status]`，不区分 `doing/done/blocked`。SPEC §4「用 mention/阶段标记精确命中,防 A→B→A 环」要求事件可被路由规则精确匹配。**对齐动作**：让 `:set_status` 的事件标记带上目标 status（`[kanban:status:doing]` 等），使下游路由规则能只命中特定状态、不被自己回写的 status 公告反复唤醒。
- **删过时的**：核实 Phase 2 抽 github 后，`register_pr` 由 github 入站自动 dispatch（SPEC 能力 GH）；`register_pr ∈ @relay_actions` 使「自动登记→relay 唤醒 CI agent」成立，**保留**。要确认的过时点 = **relay 不能 fire 两次**——若 github 入站 plugin 自己也注入了一条 session.send 公告，会和 kanban 的 post_handle relay 重复。本任务加一条守卫测试钉死「一次 register_pr 只注入一条 dispatch」。

### Files

| 文件 | 改动 |
|---|---|
| `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex` | `:728-737` `relay_text/1`：`:set_status` 事件带 status 后缀 |
| `apps/ezagent_plugin_kanban/test/behavior/relay_test.exs` | 加 2 个验收：①status 事件带后缀；②单动作恰一条 dispatch（防重复） |

### Interfaces

- `relay_text(:set_status, ctx)` 返回带 status 的标记。需要 `ctx` 能拿到刚写入的 status——`post_handle/4` 签名是 `(action, result, effects, ctx)`，status 在 `result`（`set_status` 的 `{:ok, result, _}`）或 effects 的 `{:set, :tree, _}` 里。**接口选择**：改 `post_handle` 把 `result` 传进 `relay_text(action, result, ctx)`，从 `result` 取 status（`set_status` handler 返回的 result 形态需先核：读 `kanban.ex` 的 `handle_set_status`/`Shared` 对应实现确认 result 里有无 status；若无则从 effects 的 tree diff 取，或退而求其次保持 `[kanban:status]` 粗粒度但在测试里显式记录「粗粒度是已知取舍」）。
- `post_handle` 返回的 effects 里 `{:dispatch, _}` 恰好 1 条（对每个 relay 动作）。

### 步骤（TDD）

1. **写失败测试**（`relay_test.exs` 追加）：
   ```elixir
   test "set_status relay 事件带 status 后缀（SPEC §4 精确命中防环）", %{board: board, caller: caller} do
     :ok = BoardConfig.write(board, %{session_uri: "session://system/default/main"})
     ctx = %{self_uri: board, caller: caller}
     assert {:ok, _r, effects} =
              Kanban.post_handle(:set_status, %{status: :doing}, [{:set, :tree, %{}}], ctx)
     [{:dispatch, cmd}] = Enum.filter(effects, &match?({:dispatch, _}, &1))
     assert cmd.text =~ "[kanban:status:doing]"
   end

   test "单个 relay 动作恰注入一条 dispatch（防 github 入站二次注入重复）",
        %{board: board, caller: caller} do
     :ok = BoardConfig.write(board, %{session_uri: "session://system/default/main"})
     ctx = %{self_uri: board, caller: caller}
     {:ok, _r, effects} = Kanban.post_handle(:register_pr, %{}, [{:set, :tree, %{}}], ctx)
     assert length(Enum.filter(effects, &match?({:dispatch, _}, &1))) == 1
   end
   ```
   > 写测试前先 `Read` `kanban.ex` 的 `handle_set_status` 实现，确认 `set_status` 返回的 `result` 里 status 字段名（`:status` 还是别的）——按真实字段写断言，不假设。
2. **跑红**：`mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/relay_test.exs`。
3. **实现**：改 `kanban.ex:705-714` `post_handle`，把 `result` 透传给 `relay_text`；改 `relay_text/2-3`：`:set_status` 分支读 status 拼 `[kanban:status:<status>]`，`:claim_node`/`:register_pr` 保持 `claimed`/`pr_registered`。
4. **跑绿** + 全量 kanban test。
5. **审计记录**：把「B1 复用什么、对齐什么、删过时什么」写进 Task 4 的最终 design 文档（不另写 report .md）——证据：relay_test 全绿 + grep 无 PubSub.broadcast + register_pr 单次注入。

### Run + 期望

```bash
mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/relay_test.exs   # 期望 6 tests, 0 failures（4 原 + 2 新）
mise exec -- mix test apps/ezagent_plugin_kanban/test                           # 全绿
grep -rn "PubSub.broadcast\|Phoenix.PubSub" apps/ezagent_plugin_kanban/lib/      # 期望空（P14）
```

### commit

`refactor(kanban): reconcile B1 接力——relay 事件精确化 + 防重复守卫，对齐 SPEC §4`

---

## Task 3 — 对齐 2 个 kanban skill（按 kanban-skills-replan.md）

**为什么**：`kanban-off-ezagent` / `kanban-on-ezagent` 是 dev-together 8 命令的 board 融合 fork，没跟上 dev-together #1012 的 5 项升级（CURRENT_DATE 日界 / 数据驱动 HTML / contributing 台账 / 三段式 plan / 硬 scrub），且 on 命令 file:line 大面积漂移。完整逐条清单见 `kanban-skills-replan.md` §3（off）/§4（on）/§5（速查打勾表）。

> 这是 **skill 文案改，不是代码改**——不动 `apps/ezagent_plugin_kanban/` 代码、不动 dev-together skill 本体（jjkysy 单写者）、不抽 handoff-standard 公共层、不加第 9 个命令（replan §6 边界）。

### Files

- `.claude/skills/kanban-off-ezagent/`：`SKILL.md` / `commands/{init,plan,handoff,dive,return,push,close,review}.md` / `scripts/{new_day.sh,validate_skill.sh}` / `references/board-format.md`
- `.claude/skills/kanban-on-ezagent/`：`SKILL.md` / `commands/*` / `references/{agent-orchestration.md,live-board-access.md,off-on-parity.md}` / `scripts/validate_skill.sh`

### Interfaces（对齐口径，replan §1/§2）

- **action 计数 = 24**（⚠️ 与 replan §4.1「24→25」的修正**反向**）：replan 写于删 attach_code_file **之前**，当时代码 25 个动作。本 Phase 5 Task 1 删掉 attach_code_file 后**最终 = 24**。因此 on `SKILL.md` 的 action 计数写 **24**，并在 skill 里注明「24 = 删 attach_code_file 后的动作集」（不是历史那个 24）。**此项 Task 3 必须在 Task 1 合并后做**。
- **on 命令 file:line 按当前代码重核**（replan §1.3 给了一批，但 Task 1/Task 2 改了行号，需以**改后**代码为准重核）：`claim_node`/`set_status`/`set_stage`/`stage_fits?`/`attach_artifact`/`set_metric`/`get_tree`/`@relay_actions`/`post_handle`/`owner_or_admin?`、连接器 `sync_github`/`push_pr`/`register_pr`/`sync_prs`、`ci.ex` 判据、`github.ex` 出站。
- **off↔on 1:1 平价**：任一侧加的字段/章节，另一侧等价加，差异只在「文件 vs dispatch」。

### 步骤（按 replan §7 落地顺序）

1. **先 on 行号重核 + 24 修正**（事实纠错，无设计风险）：用 `Read`/`grep` 对当前 `kanban.ex`/`connectors.ex`/`ci.ex`/`github.ex` 逐个核行号，更新 on `live-board-access.md` 全表 + 各命令引用；SKILL.md `24-action`（replan 列 :30/64/154 处，以实际 grep 为准）。
2. **A/C/E 机械对齐**（off/on 等价）：
   - A 日界：两 skill `<date>` 解析改「先 `cat docs/together/CURRENT_DATE`，无则回落 `date +%F`」（off `init.md` + `scripts/new_day.sh`；on `init.md`）。
   - C contributing：`handoff` 下发前、`return` 返还前必读 `docs/together/contributing/`，产物带 `contributing_read_through` attestation 字段。
   - E scrub：`plan`/`review` 加 scrub 闸——禁含 lead↔agent 讨论，内部讨论落 `notes/`、流程摩擦落 `contributing/`。
3. **D plan 三段式 + B review HTML/stats**：
   - plan 产物升级三段式 `plan.html`（§1 板缺口由 board 派生：off 扫 `docs/board.md`；on dispatch `get_tree` 读 `result.tree.nodes`）/§2 总览/§3 per-dev→handoff。
   - review 产物升级 `review.html`（读 `stats/cycle-data.json`），统计加 board 维度 + work-author 归属口径。
4. **flow-redesign 7 条纪律 F1–F7 写成命令闸**（replan §1.2，最花脑力）：F1 钦定真相源（artifact `canonical:` 键）/F2 交接即 gate（6→7 gherkin、8→9 test_green）/F3 测试先行（用例=上游 Gherkin）/F4 只做该功能（对照 spec 卡范围）/F5 drop 子树（review 回收北极星实测对照阈值，未达→`drop_subtree`+反哺 pain）/F6 三位一体（issue/test/pr 必带 spec+changelog 两兄弟）/F7 工具供能力真相落 ezagent。
5. **on agent-orchestration grounding 升级 + register_pr 断点写实**：把 B1 relay wiring 从 placeholder 升级为 grounded（引用本 Task 2 后的 `kanban.ex` 行号 + `shared.ex:72`）；`kanban-manager` agent 定义 + 路由规则仍标 placeholder（Phase 3 才建，grep `kanban-manager` 在 lib 里为空已核实）。on `close` 显式写 register_pr 人工断点（GitHub 无 webhook，`github.ex:9`）——**除非 Phase 2 已落地 github 入站自动 register**，则改写「自动登记，人工断点已拔」（按 Task 执行时实际状态二选一，不要假装）。
6. **scrub 校验脚本**：`scripts/validate_skill.sh` 加关键词断言（CURRENT_DATE / contributing_read_through / 三段式 plan / drop 子树 / 钦定真相源），**不断言运行期产物**（`plan.html`/`stats/cycle-data.json` 首个 cycle 前不存在，replan §6.4 已点明此坑）。
7. **全程 off↔on 平价**：每改一处 off 立刻同步 on；`off-on-parity.md` 加 5 行新平价映射。

### Run + 期望

```bash
bash .claude/skills/kanban-off-ezagent/scripts/validate_skill.sh   # 绿（断言 skill 自身内容，不断言运行期产物）
bash .claude/skills/kanban-on-ezagent/scripts/validate_skill.sh    # 绿
# 行号核对（抽样验证 on 引用与当前代码一致）：
grep -n "claim_node\|set_status\|get_tree\|@relay_actions\|post_handle" apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex
```
**e2e（文案级，不需起服务）**：人读 off/on 两侧 `§5 速查打勾表`（replan）逐项确认勾完；用 `diff` 思路核对 off↔on 平价（同一升级两侧都在）。

### commit

`docs(kanban-skills): 对齐 dev-together #1012 + flow-redesign 7 纪律 + on 行号/24-action 重核`

---

## Task 4 — 收敛本轮 discuss 文档成最终 design + plan + readme

**为什么**：SPEC §7 Phase 5「统一文档（本轮 discuss 收敛成最终 design+plan+readme）」。本轮四份 discuss 文档（SPEC / flow-redesign / missing-capabilities / replan）是讨论稿，开发完要收敛成可维护的最终态。

> 个人偏好（全局 CLAUDE.md）：文档含开发前 design、开发计划 plan、开发后 memory、最后 Readme。本 plan 本身充当 plan；本任务产出 design + readme（+ 把 B1 reconcile 审计结论写进 design）。

### Files（产出，绝对路径）

| 产物 | 路径 | 内容来源 |
|---|---|---|
| 最终 design | `docs/superpowers/specs/2026-06-26-kanban-team-flow-design.md` | 收敛 SPEC（两轴模型/9 阶段链/能力表 A-T）+ flow-redesign（artifact 三条路/§4 自动挂载映射/github 边界）+ missing-capabilities（register_pr 断点/B1 接力链证据）+ Task 2 的 B1 reconcile 审计结论 |
| 本 plan | `docs/superpowers/plans/2026-06-26-kanban-phase5-consolidation.md` | 已存在（本文件）|
| Readme | `docs/kanban/README.md` + `docs/kanban/README.zh_cn.md` | 双语（项目 bilingual 约定）：kanban 团队流程怎么用——建板/认领/派活/PR/CI/合并/评估全链，含 dev-together↔kanban 缝合键 `board_node_id` + 两个 skill 入口 |

> 双语约定（SKILL「Project conventions」）：`docs/<name>.md`（英）+ `docs/<name>.zh_cn.md`（中）平行；同步改两边。

### 步骤

1. **建目录**（若不存在）：`docs/superpowers/specs/`、`docs/kanban/`（先 `ls` 确认，缺则建）。
2. **写 design**：以 flow-redesign（真相源）为骨架，SPEC 的能力表 + Phase 划分作章节，把四份 discuss 去重收敛；明确标注「已交付（Phase 5）/ 后续（Phase 2/3/4）」边界；把 Task 2 的 B1 reconcile 结论（复用 relay 骨架 + relay 事件精确化 + 防重复守卫）写进 design 的「接力」一节。
3. **写 readme 双语**：面向使用者的 quickstart——怎么建一块 kanban board（role `kanban-manager`×flavor `native`）、怎么在 chat 里派活/认领、artifact 三条「读得到」的路、两个 skill（off/on）何时用哪个。
4. **discuss 文档归档标注**：在四份 discuss 文档顶部各加一行「> 已收敛进 `docs/superpowers/specs/2026-06-26-kanban-team-flow-design.md`（最终态），本文转为历史讨论稿」——保留不删（考古价值），但指向最终态。

### Run + 期望

```bash
ls docs/superpowers/specs/2026-06-26-kanban-team-flow-design.md docs/kanban/README.md docs/kanban/README.zh_cn.md   # 三件齐
# 双语一致性抽查（章节数对齐）：
grep -c '^##' docs/kanban/README.md docs/kanban/README.zh_cn.md
```

### commit

`docs(kanban): 收敛本轮 discuss 成最终 design + 双语 readme（Phase 5 收口）`

---

## Task 5 — 删死代码（全仓 sweep）

**为什么**：SPEC §7 Phase 5 gate「无遗留死代码」。Task 1-4 改完后做一遍全仓扫描，删整体流程不再需要的零碎动作/字段/引用。

### 步骤

1. **attach_code_file 残留验零**（Task 1 已删，复核）：
   ```bash
   grep -rn "attach_code_file\|github_file" apps/ docs/ .claude/ --include=*.ex --include=*.exs --include=*.tsx --include=*.ts --include=*.md
   ```
   期望：仅历史 discuss 文档可能提及（作为「已删」记录），代码/skill 0 命中。
2. **未引用的 helper sweep**：删 attach_code_file 后，检查 `connectors.ex` 是否有只被 attach_code_file 用过的私有 helper 变成死代码（已核实 `attach_code_file` 用的是共享 `board_creds/1` + `Shared.normalize_artifact`，无独占 helper；复核确认）。
3. **编译告警当死代码信号**：
   ```bash
   mise exec -- mix compile --warnings-as-errors
   ```
   期望：无「function X is unused」「variable X is unused」告警。
4. **on/off skill 死引用**：Task 3 改完后，`grep` 两个 skill 里是否还有指向已删动作/旧行号的引用（attach_code_file、漂移行号、24/25 计数）。
5. **arch.scan + check_invariants 终审**：全套 gate 跑一遍。

### Run + 期望（最终 gate，全绿才算 Phase 5 收口）

```bash
docker compose -f docker-compose.pg.yml up -d
MIX_ENV=test mise exec -- mix ecto.create && MIX_ENV=test mise exec -- mix ecto.migrate
mise exec -- mix test                                    # 全量 26-app（耗时；Phase 5 gate 要求全量绿）
mise exec -- mix ezagent.check_invariants.lifecycle      # 绿
mise exec -- mix ezagent.arch.scan                       # 绿
mise exec -- mix format --check-formatted                # 绿
mise exec -- mix compile --warnings-as-errors            # 无告警
```
> ⚠️ 本仓无 CI（无 `.github/workflows`），「CI 绿」= 人工跑全套 gate 绿。全量 `mix test` 历史上有跨进程 PG 沙箱 flaky，红的要先判 flaky（重跑/看是否沙箱可见性）再定论，不把 flaky 当真失败、也不把真失败当 flaky 放过。

### commit

`chore(kanban): Phase 5 死代码 sweep + 全量 gate 收口`

---

## Self-Review

- **三层铁律**：Task 1 删动作覆盖 plugin（Behavior/Connectors）+ world（后端 dispatch 白名单 + 前端按钮）三处，core 不碰 ✅；Task 2 B1 走 `session_dispatch` 注入 `{:dispatch}` effect、无 PubSub.broadcast（P14）✅；Task 3 纯 skill 文案、不动代码 ✅。
- **TDD**：Task 1/Task 2 都先写失败测试（required_caps 24 断言 / relay 事件后缀 + 防重复）再实现 ✅。
- **依赖顺序明确**：Task 3 的「action 计数=24」显式依赖 Task 1；Task 5 在最后做全仓 sweep；Task 4 可与 Task 5 并行 ✅。
- **无占位**：所有改动点带已核实 file:line（kanban.ex:193-199/275/679、connectors.ex:150-189、world_live.ex:242、kanban_actions.ex:150-157、Kanban.tsx:475-487、kanban.ex:702-737 relay、shared.ex:69-79）✅。
- **已知取舍显式标注**：① replan「24→25」与本 Phase「25→24」反向，已在 Task 3 显式说明并钉死最终值 24；② Task 2 relay status 后缀若 `set_status` result 无 status 字段，退回粗粒度并在测试里记录取舍（不假设字段名，要求执行时先 Read 实现核对）；③ on `close` register_pr 断点写实 vs 「已拔」二选一，按 Phase 2 实际状态定，不假装 ✅。
- **gate 完整**：每任务都列 `check_invariants.lifecycle` / `arch.scan` / `format --check-formatted`；Phase 5 总 gate 要求全量 `mix test` 绿（本仓无 CI，人工跑）✅。
- **e2e + 截图**：Task 1 world UI 删按钮要 agent-browser 截图对比 ✅。
- **风险点**：Task 2 改 `post_handle` 透传 `result` 时，需先核实 `handle_set_status` 返回的 result 形态——已在步骤里要求「写测试前先 Read 实现」，避免基于假设的断言。
