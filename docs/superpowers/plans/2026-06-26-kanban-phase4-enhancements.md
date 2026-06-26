# 实施计划 — Kanban Phase 4：增强（按需，可后置）

> 日期 2026-06-26 ｜ 基线 `feat/kanban-agent-e2e`（kanban 测试 59t 绿）。
> 上位设计：`docs/discuss/2026-06-26-kanban-team-flow-spec.md`（SPEC §5/§6 能力 F/H + §7 Phase 4）
> ＋ `docs/discuss/2026-06-26-kanban-flow-redesign/flow-redesign.md`（真相源）
> ＋ `docs/discuss/2026-06-26-kanban-flow-redesign/missing-capabilities.md`（§二 github 入站细节 + §2.5 webhook 取舍）。
> 状态：**计划稿**。本 Phase 三项**各自独立**，按依赖标注，可单独排期开工。

---

## Goal

把 SPEC §7 Phase 4 的三项"增强"落成可执行的开发计划，每项独立可交付：

- **任务 F — 需求自动拆解**：一段 goal 文本 → 自动生成 9 阶段节点树（`positioning→…→pr`），由**编排 LLM agent** 决策，机械建树落在 kanban。
- **任务 H — 多仓库（节点级 repo）**：一块板配一个**默认仓库**，`issue`/`pr` 节点可**覆盖**自己的仓库；改 `BoardConfig` + `register_pr`/`push_pr`/`sync_github`/`sync_prs`/`attach_code_file` 的 repo 解析。
- **任务 W — GitHub webhook 真入站**：Phase 2 轮询的升级——Phoenix 暴露 `/api/github/webhook` 端点收 `pull_request`/`push` 事件、**验签**（X-Hub-Signature-256 HMAC）、幂等、转 dispatch。

---

## Architecture（三层归属 + 依赖图）

| 任务 | 代码落在哪层 | 主要文件 | 依赖 |
|---|---|---|---|
| F1 机械建树 `seed_chain` | **kanban plugin** Behavior | `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex` | 无（独立） |
| F2 编排拆解 agent | **plugin**（cc orchestrator / cc-headless brain） | 新增 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/decompose.ex`（纯函数 seam）＋ 经 `Invocation.dispatch` 调 F1 | **依赖 F1** |
| H 节点级 repo | **kanban plugin** | `board_config.ex` + `behavior/kanban/connectors.ex` + `behavior/kanban.ex` | 独立；与 **Phase 2（抽 `ezagent_plugin_github`）** reconcile（见各步注） |
| W GitHub webhook | **新 plugin `ezagent_plugin_github`**（HTTP 入站）＋ **transport** `ezagent_web` 路由 1 行 | 新增 `apps/ezagent_plugin_github/lib/.../webhook_plug.ex` + `apps/ezagent_web/lib/ezagent_web/router.ex` | **硬依赖 Phase 2**：`ezagent_plugin_github` 必须已建（当前不存在，`ls apps/ | grep github` = 空） |

**依赖图**：`F1 → F2`；`H` 独立；`W` 依赖 Phase 2 已落地（GH plugin 存在 + 轮询入站就位，W 只加 webhook 升级层）。三任务之间无相互依赖，可并行三条线。

**三层铁律（本 Phase 全程遵守）**：
- 连接器 / Behavior / 入站轮询 / webhook 在 **plugin**；core **不碰**（无新 `apps/ezagent_core` 改动）。
- LLM 决策只在**编排 agent**，kanban 只做机械建树（真相源 + 纯函数），**LLM 永不进 kanban**（flow-redesign §6 "github 边界" 同理类推到 F）。
- 跨 Kind 一律 `Ezagent.Invocation.dispatch/1`（P14）——F2 调 kanban、W 调 kanban 都走 dispatch，禁 `PubSub.broadcast` 到 inbound（CLAUDE.md 不变式 #1）。
- Behavior 只 `use Ezagent.Lifecycle`（kanban.ex:27），禁 `use Ezagent.Behavior` / `init_slice` / `invoke/4`（`mix ezagent.check_invariants.lifecycle` 硬门）。
- webhook 入站走系统 admin 身份 + 幂等原语（仿 `miro_sync.ex:183-184` 的 `sys_caller`/`sys_caps`；幂等用 `ctx.idempotency_key` + `Ezagent.Idempotency.seen?/1`，CLAUDE.md "重复 inbound" 条款）。

---

## Global Constraints

1. **TDD 五步/任务**：写失败测试 → `mix test` 跑红 → 实现 → 跑绿 → commit。测试用例桩 ctx 套现有 idiom（`apps/ezagent_plugin_kanban/test/behavior/kanban_test.exs:12-32` 的 `rd/1`、`admin_ctx/1`、`user_ctx/2`、`committed/1`、`seed/0`）。
2. **新增 kanban action 三处必改**（否则 dispatch 解析或授权挂）：
   - `action/3` 宏声明（kanban.ex:42 起的块内）；
   - `def handle_<action>/2`（薄转发或本体）；
   - `required_caps/0` 的 atom 列表（kanban.ex:256-282）追加该 action——**recipe 的 `requested_caps` 自动从 `actions/0` 派生**（application.ex:80），无需手改 recipe，但 `required_caps/0` 是手列的，漏了会 `:cap_not_held`。
3. **树写入唯一收口**：所有树变更经 `Shared.commit/1`（shared.ex:34）= 全 Behavior 唯一 `{:set, :tree, _}` 字面；arch.scan 的 `set_effect_sites` 守此。F1/H 不得另开 set-effect 站点。
4. **gate（每任务 commit 前）**：
   ```bash
   MIX_ENV=test mise exec -- mix test apps/<app>/test          # 单 app 绿
   mise exec -- mix ezagent.check_invariants.lifecycle          # Lifecycle 硬门
   mise exec -- mix ezagent.arch.scan                           # 架构扫描（set-effect/资源 Kind 等）
   mise exec -- mix format apps/<改动文件>                       # 只格式化触碰文件
   ```
   跑测试**必须经 mise**（OTP27/1.18）+ 先起 PG：`docker compose -f docker-compose.pg.yml up -d` ＋ `MIX_ENV=test mise exec -- mix ecto.create && mix ecto.migrate`。
5. **e2e + 截图**（用户硬性要求，memory `feedback_e2e_every_step_screenshot`）：每项交付跑一条真渠道 e2e（F=chat 发 goal → 看板长出 9 阶段链；H=两仓库各开 PR → 各自登记到对应仓；W=真 GitHub repo 配 webhook → 开 PR → 看板自动 register），**每个有意义步骤截图**（配置→操作→结果），用 `agent-browser` 无头 Chrome（远程 IP `100.64.0.27`）。
6. **无占位**：本计划不留 TODO/TBD；每个改动点带 file:line。
7. **W 的 Phase 2 前置自检**：开工前 `ls apps/ | grep github` 必须非空（GH plugin 已建）；为空则**暂停**，先做 Phase 2，不在 Phase 4 顺手建 plugin（不跨 phase 实施）。

---

## 任务 F — 需求自动拆解（goal → 9 阶段节点树）

> 拆成 **F1（机械建树，kanban，独立）** + **F2（编排拆解，LLM seam，依赖 F1）**。
> 设计要点：LLM 产出的是一份**结构化链规格**（`[{stage, title, parent_index}]`），kanban 用一个**确定性 bulk action** 把它一次建成树。LLM 在编排 agent，建树纯机械、全可单测。

### 任务 F1 — kanban 新增 `seed_chain` 批量建链动作

**Files**
- 改 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（action 声明 + handler + required_caps）。
- 新增测试 `apps/ezagent_plugin_kanban/test/behavior/seed_chain_test.exs`。

**Interface（新动作契约）**
```elixir
action(:seed_chain,
  args: %{spec: :list},                 # [%{stage: string, title: string, parent: integer}]
  returns: %{ids: :list, count: :integer},
  caps: [:seed_chain],
  modes: [:call],
  description: "一次性建一条 9 阶段链（spec=有序节点列表，parent=指向前序节点的 0-based 下标，-1=根）；admin"
)
```
`spec` 元素：`%{"stage" => "positioning", "title" => "...", "parent" => -1}`。`parent` 是**本次 spec 列表内**的下标（不是已有节点 id），`-1` 建根。建树时按列表顺序逐个 `new_node/4`，分配 `n<seq>` id，用一张"列表下标 → 新 id"映射回填 `parent_id`。每个节点的 stage 必须过 `stage_fits?`（kanban.ex:453，相邻棒推进）——校验失败整批回滚（不 commit），返回 `{:error, {:stage_order_violation, idx}}`。

**bite-sized 步骤**

1. **写失败测试**（`seed_chain_test.exs`）。套 `kanban_test.exs` 的 `admin_ctx/1`/`committed/1` idiom：
   ```elixir
   defmodule Ezagent.Behavior.SeedChainTest do
     use ExUnit.Case, async: true
     alias Ezagent.Behavior.Kanban
     @admin_cap Ezagent.Capability.admin_genesis_cap()
     defp rd(tree), do: fn k, d -> Map.get(%{tree: tree}, k, d) end
     defp admin_ctx(tree), do: %{read: rd(tree), caps: MapSet.new([@admin_cap]), caller: nil}
     defp committed(effects), do: Enum.find_value(effects, fn {:set, :tree, t} -> t; _ -> nil end)
     @empty %{nodes: %{}, root_id: nil, seq: 0, drops: []}

     test "建一条 9 阶段直链：根→…→pr，stage 单调、parent 串对" do
       spec =
         ~w(positioning metric pain anchor ux feature issue test pr)
         |> Enum.with_index()
         |> Enum.map(fn {s, i} -> %{"stage" => s, "title" => "棒#{i}", "parent" => i - 1} end)

       assert {:ok, %{ids: ids, count: 9}, e} = Kanban.handle_seed_chain(%{spec: spec}, admin_ctx(@empty))
       t = committed(e)
       assert length(ids) == 9
       assert t.root_id == hd(ids)
       # 串成一条链：第 k 个的 parent_id == 第 k-1 个 id
       Enum.zip(tl(ids), ids) |> Enum.each(fn {child, parent} -> assert t.nodes[child].parent_id == parent end)
       assert t.nodes |> Map.values() |> Enum.map(& &1.stage) |> Enum.sort_by(&Enum.find_index(~w(positioning metric pain anchor ux feature issue test pr)a, fn x -> x == &1 end))
     end

     test "非 admin 拒" do
       assert {:error, :forbidden} = Kanban.handle_seed_chain(%{spec: []}, %{read: rd(@empty), caps: MapSet.new(), caller: Ezagent.URI.new!("entity://system/user/bob")})
     end

     test "跳棒（positioning 下直接挂 feature）违反 stage_fits? → 整批回滚不 commit" do
       spec = [%{"stage" => "positioning", "title" => "根", "parent" => -1},
               %{"stage" => "feature", "title" => "跳", "parent" => 0}]
       assert {:error, {:stage_order_violation, 1}} = Kanban.handle_seed_chain(%{spec: spec}, admin_ctx(@empty))
     end
   end
   ```
2. **跑红**：`MIX_ENV=test mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/seed_chain_test.exs`（期望：`handle_seed_chain/2` undefined）。
3. **实现 action 声明**：在 kanban.ex 的 `action(:import_markmap, ...)`（kanban.ex:154）块后追加上面的 `action(:seed_chain, ...)`。
4. **实现 handler**（放在 `handle_import_markmap`（kanban.ex:631）附近，复用 `new_node/4`(kanban.ex:743)、`stage_fits?/3`、`commit/1`、`admin?/1`）：
   ```elixir
   @doc false
   def handle_seed_chain(%{spec: spec}, ctx) when is_list(spec) do
     if not admin?(ctx) do
       {:error, :forbidden}
     else
       %{nodes: nodes0, seq: seq0, root_id: root0} = t = tree(ctx)

       spec
       |> Enum.with_index()
       |> Enum.reduce_while({nodes0, seq0, root0, %{}, []}, fn {item, idx}, {nodes, seq, root, idx2id, ids} ->
         with {:ok, s} <- parse_enum(Map.get(item, "stage") || Map.get(item, :stage), @stages),
              pidx <- to_int(Map.get(item, "parent") || Map.get(item, :parent), -1),
              {:ok, parent_id} <- resolve_parent(pidx, idx2id) do
           seq = seq + 1
           id = "n" <> Integer.to_string(seq)
           order = Enum.count(nodes, fn {_i, n} -> n.parent_id == parent_id end)
           node = new_node(parent_id, to_string(Map.get(item, "title") || Map.get(item, :title) || ""), order, s)
           nodes = Map.put(nodes, id, node)
           # 增量校验：每加一个就过相邻棒规则（用已写入 nodes 校验本节点）
           if stage_fits?(nodes, id, s) do
             {:cont, {nodes, seq, root || id, Map.put(idx2id, idx, id), [id | ids]}}
           else
             {:halt, {:error, {:stage_order_violation, idx}}}
           end
         else
           _ -> {:halt, {:error, {:bad_spec, idx}}}
         end
       end)
       |> case do
         {:error, _} = err -> err
         {nodes, seq, root, _idx2id, ids} ->
           rev = Enum.reverse(ids)
           {:ok, %{ids: rev, count: length(rev)},
            [commit(%{t | nodes: nodes, seq: seq, root_id: root})]}
       end
     end
   end

   defp resolve_parent(-1, _idx2id), do: {:ok, nil}
   defp resolve_parent(pidx, idx2id) when is_integer(pidx), do: Map.fetch(idx2id, pidx) |> case do
     {:ok, id} -> {:ok, id}
     :error -> :error
   end
   defp to_int(v, _d) when is_integer(v), do: v
   defp to_int(v, d) when is_binary(v), do: (case Integer.parse(v) do {n, _} -> n; _ -> d end)
   defp to_int(_, d), do: d
   ```
   （`parse_enum/2` 已在 kanban.ex:793，复用；`@stages` kanban.ex:38。）
5. **required_caps 追加**：在 kanban.ex:256-282 的 atom 列表里 `:import_markmap,` 后加 `:seed_chain,`。
6. **跑绿**：同步骤 2 命令，期望 3 个测试全过。
7. **跑全 app + gate**：`mix test apps/ezagent_plugin_kanban/test`（期望 59+3=62t 绿、7 excluded）；`mix ezagent.check_invariants.lifecycle`；`mix ezagent.arch.scan`；`mix format apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`。
8. **commit**：`feat(kanban): F1 — seed_chain 批量建 9 阶段链动作（确定性、stage 相邻校验、整批回滚）`。

**Run + 期望**
- `mix test .../seed_chain_test.exs` → `3 tests, 0 failures`。
- `mix test apps/ezagent_plugin_kanban/test` → `62 tests, 0 failures, 7 excluded`。

---

### 任务 F2 — 编排拆解 agent（goal → spec → dispatch seed_chain）

> **依赖 F1**。LLM 在编排 agent；建树规格由纯函数 seam 产出（可单测，不烧真 token），真 brain 是 production 路。

**Files**
- 新增 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/decompose.ex`（纯函数：goal → spec + 一个可注入的 brain seam）。
- 新增测试 `apps/ezagent_plugin_kanban/test/decompose_test.exs`。
- e2e 接线：编排走现成 cc-headless worker（`ezagent_plugin_cc` 的真 claude brain，模块索引 `application.ex:112`）——**不在本 plugin 新建 agent app**；F2 只提供"goal→spec"纯函数 + "spec→dispatch seed_chain"的系统身份 dispatch helper，由编排 agent 在收到 goal inbound 时调用。

**Interface**
```elixir
# 纯函数：把 brain 吐的 JSON（或 fallback 骨架）规整成 seed_chain 的 spec
@spec to_spec(map() | binary()) :: {:ok, [map()]} | {:error, term()}
# 默认 9 阶段骨架（brain 不可用时的确定性兜底；title 用 goal 摘要）
@spec skeleton(binary()) :: [map()]
# 系统身份 dispatch：把 spec 灌进某块板（仿 miro_sync.ex:171 do_dispatch）
@spec seed_board(URI.t(), [map()]) :: {:ok, map()} | {:error, term()}
```

**bite-sized 步骤**

1. **写失败测试**（`decompose_test.exs`）：
   ```elixir
   defmodule EzagentPluginKanban.DecomposeTest do
     use ExUnit.Case, async: true
     alias EzagentPluginKanban.Decompose

     test "skeleton/1 生成 9 阶段直链 spec，parent 串对、stage 顺序固定" do
       spec = Decompose.skeleton("让客服响应更快")
       assert length(spec) == 9
       assert Enum.map(spec, & &1["stage"]) ==
                ~w(positioning metric pain anchor ux feature issue test pr)
       assert Enum.map(spec, & &1["parent"]) == Enum.to_list(-1..7)
     end

     test "to_spec/1 接受 brain JSON（list of {stage,title,parent}）并校验形状" do
       json = ~s([{"stage":"positioning","title":"A","parent":-1}])
       assert {:ok, [%{"stage" => "positioning", "title" => "A", "parent" => -1}]} = Decompose.to_spec(json)
     end

     test "to_spec/1 拒非法 stage" do
       assert {:error, _} = Decompose.to_spec(~s([{"stage":"nope","title":"A","parent":-1}]))
     end
   end
   ```
2. **跑红**：`mix test apps/ezagent_plugin_kanban/test/decompose_test.exs`。
3. **实现 `decompose.ex`**：
   - `@stages ~w(positioning metric pain anchor ux feature issue test pr)`；
   - `skeleton/1`：`@stages |> Enum.with_index() |> Enum.map(fn {s,i} -> %{"stage"=>s,"title"=>title_for(s, goal),"parent"=>i-1} end)`；
   - `to_spec/1`：`Jason.decode/1`（已是 list 则跳过）→ 逐项断言 `stage ∈ @stages`、`title` 是字符串、`parent` 是整数，任一不符 `{:error, {:bad_item, idx}}`；
   - `seed_board/2`：照 `miro_sync.ex:171-184` 构造系统身份 dispatch：
     ```elixir
     def seed_board(%URI{} = board, spec) do
       target = Ezagent.URI.with_action(board, :kanban, "seed_chain")
       Ezagent.Invocation.dispatch(%Ezagent.Invocation{
         target: target, mode: :call, args: %{spec: spec},
         ctx: %{caller: Ezagent.URI.user(:system, :admin),
                caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                reply: {:caller_inbox, self()}}})
     end
     ```
4. **跑绿** → 3 测试过。
5. **编排 agent 接线（production 路，非单测）**：cc-headless worker 收到 goal inbound（chat 文本 `[decompose] <goal>`）时，prompt 让真 claude 吐"9 阶段 JSON"，worker 调 `Decompose.to_spec/1` → `Decompose.seed_board/2`。brain 不可用/解析失败 → 落 `Decompose.skeleton/1` 兜底（不静默失败：telemetry `[:kanban, :decompose, :fallback]`）。**这步不写死在 plugin，配进编排 agent 的 system prompt + 一条 routing 规则（`[decompose]` → 编排 agent）**，对齐 SPEC §4 "接力无环 DAG"。
6. **gate + commit**：`feat(kanban): F2 — goal→9阶段链编排拆解（纯函数 seam + 系统身份 dispatch seed_chain；brain fallback 骨架）`。

**e2e + 截图**：起 dev server，chat 里发 `[decompose] 让客服首响应<30s`；截图①路由命中编排 agent ②看板页长出 9 阶段直链 ③每节点 stage 徽章正确。brain 路用真 cc-headless（需凭证）；无凭证时验 fallback 骨架同样建成链并截图（标注 fallback）。

**Run + 期望**
- `mix test apps/ezagent_plugin_kanban/test/decompose_test.exs` → `3 tests, 0 failures`。
- e2e：goal 文本进 → 看板 9 节点链出（root=positioning、leaf=pr）。

---

## 任务 H — 多仓库（节点级 repo 覆盖）

> 独立任务。现状：`BoardConfig` 一块板配**一个** `github_repo`（board_config.ex:22）；`board_creds/1`（connectors.ex:287）只读板级 repo。
> 目标（SPEC §5 候选①）：board 配**默认 repo**，`issue`/`pr` 节点可**覆盖**自己的 repo；`register_pr`/`push_pr`/`sync_github`/`sync_prs`/`attach_code_file` 全部按"节点 repo || 板默认 repo"解析。
> **Phase 2 reconcile 注**：Phase 2 会把 github 出站抽进 `ezagent_plugin_github`，`board_creds/repo 解析` seam 会搬家。本任务对**当前 connectors.ex** 写；若 Phase 2 先落地，把"节点 repo 解析"逻辑跟着搬进 GH plugin 的 repo-resolver，契约（node.repo 覆盖 board 默认）不变。

**Files**
- 改 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`：node 加 `:repo` 字段（`new_node/4` kanban.ex:743）＋ 新动作 `set_node_repo`（声明 + handler + required_caps）。
- 改 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex`：`board_creds/1` → `board_creds/2`（带 node），5 个出站点改按节点解析 repo；`advance_merged_prs`（connectors.ex:341）按节点 repo 逐个查。
- 新增测试 `apps/ezagent_plugin_kanban/test/behavior/multi_repo_test.exs`。

**Interface**
```elixir
action(:set_node_repo,
  args: %{id: :string, repo: :string},   # repo="owner/name"；""=清除覆盖回落板默认
  returns: %{repo: :string},
  caps: [:set_node_repo],
  modes: [:call],
  description: "给 issue/pr 节点设/清仓库覆盖（owner/name）；节点 owner 或 admin"
)
```
node 结构新增 `repo: nil`（默认继承板级）。repo 解析新口径：`node.repo || BoardConfig.read(board).github_repo`。

**bite-sized 步骤**

1. **写失败测试**（`multi_repo_test.exs`）。覆盖：
   - `new_node` 默认 `repo == nil`；
   - `set_node_repo` 写覆盖 + owner/admin 授权（非 owner 非 admin → `:forbidden`）；清空（`repo: ""`）回 nil；
   - `board_creds/2` 解析：节点有 repo 用节点的、无则用板默认（用 mock/真 `BoardConfig`，桩 `ctx[:self_uri]` 指一块写过 board 默认 repo 的板）。
   ```elixir
   test "set_node_repo 覆盖；非 owner 拒；清空回落板默认" do
     {t, _r, c} = seed()                       # c = 子节点
     # 先认领 c 给 alice
     {:ok, _, e} = Kanban.handle_claim_node(%{id: c}, user_ctx(t, "entity://system/user/alice"))
     t = committed(e)
     assert {:ok, %{repo: "me/front"}, e2} =
              Kanban.handle_set_node_repo(%{id: c, repo: "me/front"}, user_ctx(t, "entity://system/user/alice"))
     assert committed(e2).nodes[c].repo == "me/front"
     assert {:error, :forbidden} =
              Kanban.handle_set_node_repo(%{id: c, repo: "x/y"}, user_ctx(t, "entity://system/user/bob"))
     assert {:ok, %{repo: nil}, e3} =
              Kanban.handle_set_node_repo(%{id: c, repo: ""}, user_ctx(committed(e2), "entity://system/user/alice"))
     assert committed(e3).nodes[c].repo == nil
   end
   ```
2. **跑红**。
3. **实现 node `:repo` 字段**：`new_node/4`（kanban.ex:743-754）map 加 `repo: nil`；`enrich_parsed/1`（kanban.ex:756）经 `new_node` 自然带上。**注意**：`new_node` 改字段后，`seed_chain`（F1）/import 自动继承，无额外改。
4. **实现 `set_node_repo` 动作**：声明（接 `set_board_config` 块后，kanban.ex:217 附近）＋ handler（复用 `update_node/3` kanban.ex:765 做授权 + commit）：
   ```elixir
   @doc false
   def handle_set_node_repo(%{id: id} = args, ctx) do
     repo = case String.trim(to_string(Map.get(args, :repo, ""))) do "" -> nil; r -> r end
     with {:ok, _, eff} <- update_node(ctx, id, &%{&1 | repo: repo}) do
       {:ok, %{repo: repo}, eff}
     end
   end
   ```
   （`update_node/3` 返回 `{:ok, %{}, effects}`，这里把 `repo` 填进返回 map。）
5. **required_caps 追加** `:set_node_repo`（kanban.ex:256-282）。
6. **改 `board_creds`**（connectors.ex:287）为带节点版，解析节点 repo 覆盖：
   ```elixir
   # 旧 board_creds/1 → board_creds/2（node 可为 nil = 图级动作走板默认）
   defp board_creds(ctx, node \\ nil) do
     case Github.read_creds() do
       {:ok, %{token: token}} ->
         board_repo = case ctx[:self_uri] do %URI{} = u -> BoardConfig.read(u).github_repo; _ -> nil end
         repo = (node && Map.get(node, :repo)) || board_repo
         {:ok, %{token: token, repo: repo}}
       err -> err
     end
   end
   ```
7. **5 个出站点传节点 repo**：
   - `sync_github`（connectors.ex:42）：`board_creds(ctx, t.nodes[id])`；
   - `push_pr`（connectors.ex:80）：with 链改 `board_creds(ctx, node)`；
   - `register_pr`（connectors.ex:127）：`board_creds(ctx, t.nodes[id])`；
   - `attach_code_file`（connectors.ex:164）：`board_creds(ctx, t.nodes[id])`；
   - `sync_prs`（connectors.ex:193 → `advance_merged_prs` connectors.ex:341）：**逐节点解析 repo**——把 `advance_merged_prs(nodes, token, repo)` 改成 `advance_merged_prs(nodes, token, board_repo)`，循环内 `repo = Map.get(node, :repo) || board_repo`，再 `Github.get_pull(token, repo, pr)`（连接每个节点用各自仓库）。
8. **跑绿** + 全 app（期望 62+H 测试绿）。
9. **gate + commit**：`feat(kanban): H — 节点级 repo 覆盖（board 默认 + issue/pr 节点 set_node_repo；register_pr/push_pr/sync_* 按节点解析）`。

**e2e + 截图**：一块板配默认仓 `me/back`；给一个 `pr` 节点 `set_node_repo me/front`。两个 worker 各在 `me/front`/`me/back` 开 PR → 各自 `register_pr` → 截图①节点 repo 覆盖已写 ②前端 PR 链接指向 `me/front` ③后端节点 PR 指向 `me/back`。

**Run + 期望**
- `mix test apps/ezagent_plugin_kanban/test/behavior/multi_repo_test.exs` → 全绿。
- 节点有覆盖 → PR url = `https://github.com/me/front/pull/N`；无覆盖 → 板默认仓。

---

## 任务 W — GitHub webhook 真入站（Phase 2 轮询的升级）

> **硬依赖 Phase 2**：`ezagent_plugin_github`（含 github 出站 + 轮询入站 `register_pr`）已落地。开工前自检 `ls apps/ | grep github` 非空、`sync_open_prs`/轮询入站存在；否则暂停做 Phase 2。
> 本任务**只加 webhook 升级层**：Phoenix 暴露端点收事件 → 验签 → 幂等 → 复用 Phase 2 已有的"入站 → dispatch register_pr/push_pr"逻辑（不重写入站语义，只把"拉"升级成"推"）。
> 取舍依据 missing-capabilities §2.5：先轮询后 webhook；webhook 要 Phoenix 端点 + 验签 + 公网可达 + 幂等。

**Files**
- 新增 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/webhook_plug.ex`（Plug，仿 `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/webhook_plug.ex`）。
- 新增 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/webhook_verify.ex`（HMAC SHA-256 验签纯函数，便于单测）。
- 改 `apps/ezagent_web/lib/ezagent_web/router.ex`：在 feishu forward（router.ex:186）旁加一行 `forward "/api/github/webhook", EzagentPluginGithub.WebhookPlug`（**唯一**对 ezagent_web 的触碰，对齐 feishu 先例注释 router.ex:183-185）。
- 新增测试 `apps/ezagent_plugin_github/test/webhook_verify_test.exs` + `apps/ezagent_plugin_github/test/webhook_plug_test.exs`。

**Interface**
```elixir
# 纯函数验签：用 webhook secret 算 HMAC，与 X-Hub-Signature-256 头常量时间比对
@spec verify(raw_body :: binary(), signature_header :: String.t() | nil, secret :: String.t()) :: :ok | {:error, :bad_signature | :missing_signature}
```
GitHub 头格式：`X-Hub-Signature-256: sha256=<hex(hmac_sha256(secret, raw_body))>`。secret 存 Phase 2 的 github 凭证（`system://credentials/github.yaml` 加一个 `webhook_secret`，仿 `Github.read_creds` github.ex:19）。

**bite-sized 步骤**

1. **写失败测试**（`webhook_verify_test.exs`）：
   ```elixir
   defmodule EzagentPluginGithub.WebhookVerifyTest do
     use ExUnit.Case, async: true
     alias EzagentPluginGithub.WebhookVerify

     test "正确签名通过" do
       body = ~s({"action":"opened"})
       sig = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, "s3cret", body), case: :lower)
       assert :ok = WebhookVerify.verify(body, sig, "s3cret")
     end
     test "篡改 body → bad_signature" do
       sig = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, "s3cret", "x"), case: :lower)
       assert {:error, :bad_signature} = WebhookVerify.verify("y", sig, "s3cret")
     end
     test "缺签名头 → missing_signature" do
       assert {:error, :missing_signature} = WebhookVerify.verify("x", nil, "s3cret")
     end
   end
   ```
2. **跑红** → `mix test apps/ezagent_plugin_github/test/webhook_verify_test.exs`。
3. **实现 `webhook_verify.ex`**：
   ```elixir
   defmodule EzagentPluginGithub.WebhookVerify do
     @spec verify(binary(), String.t() | nil, String.t()) :: :ok | {:error, atom()}
     def verify(_body, nil, _secret), do: {:error, :missing_signature}
     def verify(_body, "", _secret), do: {:error, :missing_signature}
     def verify(body, "sha256=" <> hex, secret) do
       expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
       if Plug.Crypto.secure_compare(expected, String.downcase(hex)), do: :ok, else: {:error, :bad_signature}
     end
     def verify(_body, _other, _secret), do: {:error, :bad_signature}
   end
   ```
   （`Plug.Crypto.secure_compare/2` 常量时间比对，防时序侧信道。）
4. **实现 `webhook_plug.ex`**（仿 feishu webhook_plug.ex:31，但 **必须读 raw body 验签**——Plug.Parsers 已消费 body 时验签会失败，故在 endpoint 用 `cache_body_reader` 缓存原始字节，或对此 forward 路径配 `Plug.Parsers` 的 `body_reader` 留原文；最简：在 plug 内 `read_body` 拿原文且 router 该 forward 不经 JSON parser pipeline）：
   ```elixir
   defmodule EzagentPluginGithub.WebhookPlug do
     import Plug.Conn
     require Logger
     alias EzagentPluginGithub.WebhookVerify

     def init(opts), do: opts

     def call(%Plug.Conn{method: "POST"} = conn, _opts) do
       {:ok, raw, conn} = read_body(conn, length: 2_000_000)
       sig = get_req_header(conn, "x-hub-signature-256") |> List.first()
       event = get_req_header(conn, "x-github-event") |> List.first()
       delivery = get_req_header(conn, "x-github-delivery") |> List.first()  # 幂等键

       with {:ok, secret} <- webhook_secret(),
            :ok <- WebhookVerify.verify(raw, sig, secret),
            {:ok, payload} <- Jason.decode(raw) do
         handle_event(event, delivery, payload)
         send_resp(conn, 202, "{}")
       else
         {:error, :bad_signature} -> send_resp(conn, 401, "bad signature")
         {:error, :missing_signature} -> send_resp(conn, 401, "missing signature")
         {:error, reason} -> Logger.warning("github webhook: #{inspect(reason)}"); send_resp(conn, 400, "bad payload")
       end
     end
     def call(conn, _opts), do: send_resp(conn, 405, "method not allowed")

     # pull_request.opened/reopened → 入站登记（复用 Phase 2 的"分支名→节点"匹配 + 系统身份 register_pr）
     # push/synchronize → 触发 push_pr 重算 CI status
     defp handle_event("pull_request", delivery, %{"action" => action, "pull_request" => pr} = p)
          when action in ["opened", "reopened", "synchronize"] do
       if EzagentPluginGithub.Inbound.seen?(delivery) do  # 幂等：delivery id 记过就跳（仿 ctx.idempotency_key）
         :ok
       else
         EzagentPluginGithub.Inbound.on_pull_request(p)   # Phase 2 已有：按 head.ref 匹配节点 → dispatch register_pr / push_pr（系统 admin）
         EzagentPluginGithub.Inbound.mark_seen(delivery)
       end
     end
     defp handle_event(_other, _delivery, _payload), do: :ok

     defp webhook_secret do
       case EzagentPluginGithub.Github.read_creds() do
         {:ok, %{webhook_secret: s}} when is_binary(s) and s != "" -> {:ok, s}
         _ -> {:error, :webhook_secret_missing}
       end
     end
   end
   ```
   **复用边界**：`on_pull_request/1`（按 `head.ref` 分支名匹配看板节点 → 系统身份 `Invocation.dispatch` 调 kanban `register_pr`/`push_pr`）是 **Phase 2 已交付**的入站逻辑（missing-capabilities §2.3 做项 2/3）；W **不重写**，webhook 只是把它从"轮询触发"换成"事件触发"。幂等 `seen?/mark_seen` 走 ezagent 幂等原语（`Ezagent.Idempotency`，CLAUDE.md "重复 inbound"），W 用 `X-GitHub-Delivery` 作键。
5. **router 加 1 行**（router.ex:186 旁）：
   ```elixir
   # Phase 4 W: GitHub webhook receiver（唯一对 ezagent_web 的触碰，对齐 feishu 先例）。
   forward "/api/github/webhook", EzagentPluginGithub.WebhookPlug
   ```
   raw-body 验签需求：确认该 forward 不在 `:api` JSON-parser pipeline 内（feishu forward 同样裸在 scope 外，router.ex:186），plug 内 `read_body` 能拿原文。若 endpoint 全局挂了 `Plug.Parsers`，给 endpoint 配 `body_reader: {Ezagent.CacheBodyReader, :read_body, []}` 缓存 raw（标准 GitHub webhook idiom）——此项在接线时按 endpoint 实际配置二选一，写进 commit 说明。
6. **写 plug 测试**（`webhook_plug_test.exs`）：用 `Plug.Test.conn(:post, "/", body)` 带正确/错误签名头，断言 202/401；mock `Inbound.on_pull_request` 验被调用 + 幂等（同 delivery 两次只调一次）。
7. **跑绿** + `mix test apps/ezagent_plugin_github/test`。
8. **gate**：`mix ezagent.check_invariants.lifecycle`（webhook plug 非 Behavior，但确保没违反）；`mix ezagent.arch.scan`；`mix format`。
9. **commit**：`feat(github): W — pull_request webhook 真入站（HMAC SHA-256 验签 + delivery 幂等 + 复用 Phase2 入站 dispatch）`。

**e2e + 截图**：真 `test-ezagent` repo Settings→Webhooks 配 `https://100.64.0.27/api/github/webhook` + secret；开一个 PR → 截图①GitHub webhook delivery 200/202 ②ezagent 日志收到 `pull_request opened` ③看板对应节点自动挂上 `kind="pr"` artifact（无人手填 `register_pr`）④push 新 commit → CI status check 自动刷新（绿/红）。再发一次重复 delivery 验幂等不重复挂。

**Run + 期望**
- `mix test apps/ezagent_plugin_github/test` → 验签 3t + plug 测试全绿。
- 真 PR 事件 → 看板节点自动 register（拔掉 missing-capabilities §2.1 的人工断点）。

---

## Self-Review

- [x] **三层铁律**：F1/H 在 kanban plugin；F2 纯函数 seam 在 kanban plugin + 编排走 cc-headless agent（LLM 不进 kanban）；W 在新 `ezagent_plugin_github` plugin + ezagent_web 仅 1 行 forward（transport，P13）；**core 零改动**。
- [x] **P14 dispatch-only**：F2 `seed_board`、W `on_pull_request` 都经 `Ezagent.Invocation.dispatch/1` 系统身份调 kanban，无 `PubSub.broadcast` 到 inbound。
- [x] **Lifecycle 契约**：新动作走 `action/3` + `handle_<action>/2`，不碰 `use Ezagent.Behavior`/`invoke/4`；`required_caps/0` 同步追加（防 `:cap_not_held`）。
- [x] **树写入唯一收口**：F1/H 全经 `Shared.commit/1`，无新 set-effect 站点。
- [x] **可靠性原语**：W 入站走幂等（`X-GitHub-Delivery` + `Idempotency`）+ 系统身份；验签失败显式 401（非静默丢）；brain fallback 出 telemetry（非静默成功）。
- [x] **依赖标注**：F1→F2；H 独立（+Phase2 reconcile 注）；W 硬依赖 Phase 2（开工自检 `ls apps/ | grep github`）。
- [x] **不跨 phase**：W 不在 Phase 4 顺手建 GH plugin——若 Phase 2 未落地则暂停。
- [x] **TDD + gate + e2e + 截图**：每任务五步 + 单 app 绿 + check_invariants.lifecycle + arch.scan + format + 真渠道 e2e 每步截图。
- [x] **无占位**：每改动点带 file:line（kanban.ex:38/256/424/453/743、connectors.ex:287/341、board_config.ex:22、github.ex:19、router.ex:186、feishu webhook_plug.ex），无 TODO/TBD。
- [ ] **待 Allen/用户拍板**：F2 编排 agent 是否用真 cc-headless brain（凭证 + 成本）vs 先 fallback 骨架跑通机械链（SPEC §8 问 5）；H 节点级 repo 是否就是最终方案 vs board repo 列表（SPEC §8 问 1）；W 是否纳入本轮（SPEC §7 标"按需，可后置"）。
