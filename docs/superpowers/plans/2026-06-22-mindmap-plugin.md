# ezagent_plugin_mindmap 实施计划（增量1 · 思维导图双向打通）

> **For agentic workers:** 用 superpowers:executing-plans 逐任务实施。步骤用 `- [ ]`。
> 设计 spec：`docs/superpowers/specs/2026-06-22-mindmap-plugin-design.md`。

**Goal:** 一个纯 plugin，让思维导图节点树住在 ezagent（真相源），与 markmap markdown 文件双向同步。

**Architecture:** 走 echo 的"插件自带 Kind"模式——`EzagentPluginMindmap.Mindmap`（`use Ezagent.Kind, pattern: :entity`）+ `Ezagent.Behavior.Mindmap`（`use Ezagent.Lifecycle` + `action` 宏）+ 纯函数 `Markmap`（render/parse）+ 两个 mix 任务。不碰 core/domain。

**Tech Stack:** Elixir/OTP（mise OTP27/1.18），`use Ezagent.Plugin` / `use Ezagent.Kind` / `use Ezagent.Lifecycle`。

## Global Constraints
- 工具链：所有 mix 命令前缀 `mise exec --`，在 worktree 根 `/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech`。
- 纯 plugin：只新增 `apps/ezagent_plugin_mindmap/`，不改 core/domain 任何文件。
- P14：跨 Kind 只走 `Ezagent.Invocation.dispatch/1`。
- 不手写 `def init/1`；插件不 import EventLog/SnapshotStore/StateRebuilder/Router internals/SagaRunner.execute/2。
- node_id 确定性（`"n"<>seq`，禁 Math.random/时间）。
- 每步后跑 `mise exec -- mix test <文件>`；任务末跑 `mise exec -- mix compile`（触发 `:ezagent_plugin_check`）。
- PR gate（全绿才算完）：`mix compile --force` → `mix ezagent.arch.scan` → `mix ezagent.check_invariants && .lifecycle` → `mix ezagent.doc.scan` → `mix test`。

---

### Task 1: 脚手架 app（能 compile）

**Files:**
- Create: `apps/ezagent_plugin_mindmap/mix.exs`
- Create: `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/application.ex`

**Interfaces:**
- Produces: OTP app `:ezagent_plugin_mindmap`，contract 模块 `EzagentPluginMindmap.Application`。

- [ ] mix.exs：照抄 echo mix.exs，改 app 名为 `:ezagent_plugin_mindmap`、mod 为 `EzagentPluginMindmap.Application`、`env: [ezagent_plugin: EzagentPluginMindmap.Application]`、`compilers: Mix.compilers() ++ [:ezagent_plugin_check]`，deps 仅 `{:ezagent_core, in_umbrella: true}`。
- [ ] application.ex：`use Application` + `use Ezagent.Plugin`；`start(_,_) = Ezagent.Plugin.boot(__MODULE__)`；`plugin_info/0` 返回 `%{slug: "mindmap", name: "Mindmap", description: "...", version: "0.1.0"}`。先不声明 kinds/behaviors（下一任务加）。
- [ ] 跑 `mise exec -- mix compile`，期望：新 app 编译通过（plugin_check 对一个只有 plugin_info 的插件应放行；若报缺 kinds/behaviors 则按报错补空，记录）。
- [ ] Commit。

---

### Task 2: Markmap 纯函数（render/parse 往返）— 先做，零 ezagent 依赖

**Files:**
- Create: `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/markmap.ex`
- Test: `apps/ezagent_plugin_mindmap/test/markmap_test.exs`

**Interfaces:**
- Produces:
  - `Markmap.render(%{nodes: map, root_id: id}) :: String.t()`（markdown，标题层级=树深）
  - `Markmap.parse(String.t()) :: {:ok, %{nodes: map, root_id: id, seq: int}} | {:error, {:parse_failed, line :: integer}}`
  - 节点 map 形状：`%{id => %{parent_id: id|nil, title: String.t(), order: int}}`

- [ ] **失败测试**：往返 `parse(render(tree)) == tree`（3 层树、含中文标题）；空 markdown → `{:error, {:parse_failed, _}}`；单根。
- [ ] 跑 `mise exec -- mix test apps/ezagent_plugin_mindmap/test/markmap_test.exs`，期望 FAIL（函数未定义）。
- [ ] 实现 `render/1`：DFS 从 root，深度 d→`String.duplicate("#", d+1)<>" "<>title`，按 order 排兄弟。`parse/1`：按行扫 `^#+\s`，`#` 数=深度，用栈维护 parent，重编号 `seq`。畸形（首行非单个 `#` 根、空）→ `{:error,{:parse_failed,line}}`。
- [ ] 跑测试，期望 PASS。
- [ ] Commit。

---

### Task 3: Mindmap Kind + Behavior（节点动作，dispatch 可达）

**Files:**
- Create: `apps/ezagent_plugin_mindmap/lib/ezagent_plugin_mindmap/mindmap.ex`（Kind）
- Create: `apps/ezagent_plugin_mindmap/lib/ezagent/behavior/mindmap.ex`（Behavior）
- Modify: `application.ex`（加 `kinds/0` + `behaviors/0` + `children/0`）
- Test: `apps/ezagent_plugin_mindmap/test/behavior/mindmap_test.exs`

**Interfaces:**
- Produces:
  - Kind `EzagentPluginMindmap.Mindmap`（`use Ezagent.Kind, pattern: :entity, type_name: :mindmap, supervisor: EzagentPluginMindmap.InstanceSupervisor` + `attach(Ezagent.Behavior.Mindmap)` + `behaviors/0` + `persistence/0`）
  - Behavior `Ezagent.Behavior.Mindmap`（`use Ezagent.Lifecycle`；actions: add_node/rename_node/move_node/remove_node/get_tree/export_markmap/import_markmap；`create/1 → {:ok, %{nodes: %{}, root_id: nil, seq: 0}}`；`required_caps/0`；`data_owner(_) → :no_owner`）

- [ ] **失败测试**（直接测 Behavior handler，仿 echo behavior 测法）：`handle_add_node(%{parent_id: nil, title: "根"}, ctx)` 返回 `{:ok, %{id: "n1"}, [{:set,:nodes,_},{:set,:root_id,"n1"},{:set,:seq,1}]}`；parent 不存在 → `{:error,:parent_not_found}`；`handle_export_markmap` 读树渲染；`handle_import_markmap` 覆盖。ctx 用 `%{read: fn k,d -> Map.get(state,k,d) end}` 桩。
- [ ] 跑测试期望 FAIL。
- [ ] 实现 Behavior（action 宏 + handlers，对照 `Ezagent.Behavior.Echo` 语法）+ Kind（对照 `Ezagent.Entity.Echo`）+ application.ex 声明 `kinds/0=[…Mindmap]`、`behaviors/0=[{Mindmap,:add_node,Behavior.Mindmap},…每动作一条]`、`children/0=[{DynamicSupervisor,name: …InstanceSupervisor,strategy: :one_for_one}]`。
- [ ] 跑测试 PASS + `mise exec -- mix compile`（plugin_check 绿）。
- [ ] Commit。

---

### Task 4: e2e — spawn→dispatch 双向往返（增量1 验收 gate）

**Files:**
- Test: `apps/ezagent_plugin_mindmap/test/e2e/roundtrip_test.exs`

- [ ] **e2e 测试**：`setup` checkout Repo sandbox（仿 EchoAgentTest）；spawn `Ezagent.Kind.spawn(EzagentPluginMindmap.Mindmap, %{uri: URI.new!("entity://system/mindmap/t1")})`（或 SpawnRegistry，按编译/运行真相调整）；dispatch `add_node`×3（caps `MapSet.new([Ezagent.Capability.admin_genesis_cap()])`，仿 04 文档 echo dispatch）；dispatch `export_markmap` → 拿 markdown → 写 `/tmp/mm_e2e.md` → 断言含 3 个标题；改文件（加一行 `## 新节点`）→ 读 → dispatch `import_markmap` → dispatch `get_tree` → 断言含"新节点"。
- [ ] 跑 `mise exec -- mix test apps/ezagent_plugin_mindmap/test/e2e/roundtrip_test.exs`，期望 PASS。
- [ ] Commit。

---

### Task 5: mix 任务 export/import（CLI 包装，走 dispatch）

**Files:**
- Create: `apps/ezagent_plugin_mindmap/lib/mix/tasks/ezagent.mindmap.export.ex`
- Create: `apps/ezagent_plugin_mindmap/lib/mix/tasks/ezagent.mindmap.import.ex`
- Test: 复用/扩 e2e

- [ ] export 任务：`mix ezagent.mindmap.export <uri> <file>` → 起 app → dispatch `export_markmap`(:call) → 写文件；`{:error,_}` → `Mix.raise`。import 同理读文件→`import_markmap`。
- [ ] `mise exec -- mix compile` 绿。
- [ ] Commit。

---

### Task 6: 全 PR gate + 证据文档 + 修改记录

- [ ] 跑全 gate：`mise exec -- mix compile --force` / `mix ezagent.arch.scan` / `mix ezagent.check_invariants && mix ezagent.check_invariants.lifecycle` / `mix ezagent.doc.scan` / `mix test apps/ezagent_plugin_mindmap`。逐条记录真实输出。
- [ ] 合规 grep 自查（P14/init/import 禁用项/Math.random）。
- [ ] 写证据文档 `docs/superpowers/evidence/2026-06-22-mindmap-e2e-evidence.md`：e2e 步骤+真实输出+gate 结果。
- [ ] 修改记录留存：`.artifacts/eval-docs/`（dev-loop skill-6）记录本次开发。
- [ ] 任何 gate 红/需越界才能过 → **暂停、如实记录、不伪造绿**。
