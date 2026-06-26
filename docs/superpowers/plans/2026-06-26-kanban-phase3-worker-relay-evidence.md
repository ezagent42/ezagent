# Kanban Phase 3 — worker 接力 + 仓库存证 + dev-together 自动挂载 + 板级时间线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: `superpowers:subagent-driven-development` 或 `superpowers:executing-plans` 逐任务实施；动手前 load `ezagent-developer` + `elixir-phoenix-helper`。步骤用 `- [ ]`。
> 上位设计（必读）：
> - SPEC：`docs/discuss/2026-06-26-kanban-team-flow-spec.md`（§6 能力 E/G/T + §7 Phase 3 + §8 待拍板 2/3）
> - 真相源：`docs/discuss/2026-06-26-kanban-flow-redesign/flow-redesign.md`（§3 artifact 三条路 / §4 自动挂载映射 / §5 仓库存证）
> - github 入站细节：`docs/discuss/2026-06-26-kanban-flow-redesign/missing-capabilities.md`（§2 register_pr 断点；本 Phase 不做 github 入站，那是 Phase 2）

**Goal:** 把 ABCD 场景的"chat 全自动"那一段跑通——A 在 chat 派活 → worker agent（真 claude brain）经路由接力收到 → 操作看板/提交；每步产物**两份存证**（看板节点 + 仓库 `docs/together/`）；dev-together 台账缝上 `board_node_id` 并自动回挂；跨多节点的日/周总结挂到新的**板级时间线**通道。**core 不碰**（能力 E 用现成 `Workspace.create_agent` + `RuleStore.add`，**近 core 边界 → 开工前 Allen 确认设计**）。

**Architecture:**
- **能力 E（worker 接力）**：worker = `cc-headless` flavor 的 agent（file-flavor，真 claude brain，`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:111-118`），经现成 `Ezagent.Workspace.create_agent`（`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:310` 同款 facade）创建。接力链路**已存在**：看板动作成功 → `post_handle`（`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:704-716`）经 `Shared.session_dispatch`（`shared.ex:59-119`）把 `[kanban:<event>] by <caller>`（`kanban.ex:728-737`）打进绑定会话 → 重入路由。**缺的是**那条把该公告路由到 worker 的规则 → 用 `Ezagent.Routing.RuleStore.add/5`（`apps/ezagent_core/lib/ezagent/routing/rule_store.ex:94`）+ `load_into_registry/1`（`:170`）写一条 `all_of([in_session(板会话), text_contains("[kanban:claimed]")]) → [worker_uri]` 规则（matcher 见 `apps/ezagent_core/lib/ezagent/routing/matcher.ex:116/106/74`）。**receiver 是字面 worker URI**；**无环 DAG**：规则只匹配看板自己发的 `[kanban:*]` 标记公告，worker 的回复是普通 chat、不带该标记 → 不回灌、A→B→A 不成环。
- **能力 G（仓库存证）**：新 plugin 模块 `EzagentPluginKanban.RepoEvidence` 把某节点的 inline-content / 上传 artifact **落盘**到工作树 `docs/together/<date>/<node-id>/`，回挂一条 `url`=仓库相对路径的 artifact（flow-redesign §3「可读性最强」第 1 条）；经新 Behavior 动作 `archive_node` 收口（走唯一 `Shared.commit/1`，`shared.ex:34`）。文件进工作树 → dev-together `push` 随 PR 进仓库 = 仓库存证。
- **能力 §4（dev-together 自动挂载）**：① dev-together 台账（`.claude/skills/dev-together/commands/{handoff,return}.md` + `references/handoff-template.md`）元数据块加 `board_node_id` 字段；② dev-together「on dispatch 版」命令产出文档后自动 dispatch 回挂——**handoff→该 task 的 issue 节点**、**return→该节点**。CLI 友好的标量参数动作 `attach_node_doc`（id/kind/url 全 string，规避 `attach_artifact` 的 `:map` 参数在 CLI 难传的问题），内部复用 `normalize_artifact`+`Shared.commit`。
- **能力 T（板级时间线）**：tree 加 `:timeline` 字段（与 `:drops` 同构——`empty_tree` 是 `%{nodes, root_id, seq, drops}`，`shared.ex:24`，加 `timeline: []`），新动作 `attach_timeline`（日/周总结/plan/review/stack 按 `<date>`/`<week>` 挂板级，不挂单节点）；`get_tree` 一并返回（`kanban.ex:565-574`）；read-model `KanbanData.board_snapshot` 透传（`apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex:130-143`）；前端 `Kanban.tsx` 侧栏开一个时间线区块（仿 drop 历史 `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx:250-273`）。

**Tech Stack:** Elixir/OTP（kanban plugin + core RuleStore 只读用、不改）、React/TS（world assets）、ExUnit + PostgreSQL（`docker compose -f docker-compose.pg.yml up -d` + `MIX_ENV=test mise exec -- mix ecto.create/migrate`）、Markdown（dev-together skill）。

## Global Constraints
- **三层铁律**：连接器/Behavior/存证落盘在 kanban **plugin**，UI 在 **world**，**core 不碰**（`RuleStore`/`Matcher`/`create_agent` 是现成 API，只调用不改）；跨 Kind 一律走 `Ezagent.Invocation.dispatch`（P14）。
- **Behavior 只 `use Ezagent.Lifecycle`**；新动作经 `action/3` 宏声明 + `handle_<action>/2` 返回 `{:ok, result, [effect]}`；树写入**唯一收口** `Shared.commit/1`（`shared.ex:34`，arch.scan set_effect_sites 友好）。
- **新动作三处登记**（缺一则 cap 拒/CLI 不可见）：① `action/3` 宏声明；② `required_caps/0` 的手列 list（`kanban.ex:256-282`）加该 atom；③ recipe 经 `Ezagent.Behavior.Kanban.actions()` 自动覆盖（`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:80`，无需手动）。world 驱动的动作另加 world 白名单。
- **能力 E 近 core 边界 → Phase 3 开工前跟 Allen 确认设计**（SPEC §7 Phase 3 gate / §8 待拍板 2）：worker 接线用 `RuleStore.add` + `create_agent` 是否算"改 core"（判断=不算，纯调用），matcher 形态（in_session+text_contains 防环）请 Allen 过一眼再写 Task 1。
- gate（每任务结束）：`mise exec -- mix ezagent.check_invariants.lifecycle` 无新增违规 + `mise exec -- mix format --check-formatted <touched>` + 相关 `mise exec -- mix test apps/<app>/test` 绿。
- **每任务结束**：单测绿 + **真浏览器/真渠道 e2e** + **每个有意义步骤截图**（配置→chat→操作→结果），存 `docs/e2e/2026-06-26-kanban-phase3/`；拒单元 stub 当 e2e（memory `feedback_e2e_every_step_screenshot`）。
- **无占位**：下文代码块给全，无 TODO/TBD。

---

### Task 1: worker cc-headless agent + 自动 routing 规则（能力 E，近 core，Allen 先确认）

> ⚠️ **开工前置**：把本 Task 的 matcher 设计（`all_of([in_session(板会话), text_contains("[kanban:claimed]")]) → [worker_uri]`，防 A→B→A 环）+ "用 RuleStore.add/create_agent 不算改 core" 的判断发给 Allen 确认，确认后再写。

**Files:**
- New: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/worker_relay.ex`（plugin 模块：建 worker + 加路由规则，两步都调现成 API）
- New: `apps/ezagent_plugin_kanban/test/worker_relay_test.exs`
- 参考（不改）：`apps/ezagent_core/lib/ezagent/routing/rule_store.ex:94`（add）/`:170`（load_into_registry）；`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/default_rules.ex:87`（`alias EzagentDomainInstanceMessage.Routing.MentionRouting`，表名）；`apps/ezagent_core/lib/ezagent/routing/matcher.ex:116/106/74`（all_of/in_session/text_contains）；`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:310`（create_agent facade 形）

**Interfaces:**
- Produces:
  - `EzagentPluginKanban.WorkerRelay.spawn_worker(workspace_uri, name, cwd, caller_ctx) :: {:ok, %{agent_uri: URI.t()}} | {:error, term()}` —— `flavor: "cc-headless"`，**不带 role**（cc-headless 是 file-flavor，`role` 在 file-flavor 上 RF-5b 未落地会 fail-loud，`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex:299` 路径无 role 参）。`cwd` = worker 操作的仓库工作树（claude 在此跑）。
  - `EzagentPluginKanban.WorkerRelay.add_relay_rule(board_session_uri, worker_uri, created_by, workspace_uri, event) :: {:ok, integer()} | {:error, term()}` —— `event`（"claimed"/"status"/"pr_registered"，对齐 `kanban.ex:729-734` 的标记）→ matcher `all_of([in_session(board_session_uri), text_contains("[kanban:#{event}]")])`，receiver = `[worker_uri]`（字面 URI），写完 `load_into_registry(MentionRouting)` 热生效。
- Consumes:
  - `Ezagent.Workspace.create_agent/3`（facade，`kanban_actions.ex:310` 同签名）
  - `Ezagent.Routing.RuleStore.add/5` + `.load_into_registry/1`
  - `Ezagent.Routing.Matcher.{all_of,in_session,text_contains}/1`

- [ ] **Step 1: 写失败测试**
```elixir
# apps/ezagent_plugin_kanban/test/worker_relay_test.exs
defmodule EzagentPluginKanban.WorkerRelayTest do
  use EzagentCore.DataCase, async: false

  alias EzagentPluginKanban.WorkerRelay
  alias Ezagent.Routing.{RuleStore, Matcher}
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  test "add_relay_rule 写一条 in_session+text_contains→[worker] 的字面规则，无环" do
    board_session = "session://default/acme/feat-x"
    worker = "entity://acme/agent/cc_headless_worker_b"
    created_by = Ezagent.URI.new!("entity://acme/user/alice")
    ws = Ezagent.URI.new!("workspace://acme")

    assert {:ok, id} = WorkerRelay.add_relay_rule(board_session, worker, created_by, ws, "claimed")
    assert is_integer(id)

    [rule] = RuleStore.list(MentionRouting) |> Enum.filter(&(&1.id == id))
    {:ok, matcher} = Matcher.from_json(rule.matcher_data)
    # matcher = all_of([in_session(board_session), text_contains("[kanban:claimed]")])
    assert {:and, leaves} = matcher
    assert Matcher.in_session(board_session) in leaves
    assert Matcher.text_contains("[kanban:claimed]") in leaves
    # receiver = 字面 worker URI（防环：worker 回复无 [kanban:*] 标记，不再匹配此规则）
    assert worker in rule.receivers
  end
end
```
- [ ] **Step 2: 跑测试确认失败**
Run: `docker compose -f docker-compose.pg.yml up -d && MIX_ENV=test mise exec -- mix ecto.create && MIX_ENV=test mise exec -- mix ecto.migrate && mise exec -- mix test apps/ezagent_plugin_kanban/test/worker_relay_test.exs`
Expected: FAIL（`WorkerRelay` 未定义）
- [ ] **Step 3: 实现**
```elixir
# apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/worker_relay.ex
defmodule EzagentPluginKanban.WorkerRelay do
  @moduledoc """
  能力 E（worker 接力）的两步接线，**全用现成 API、不改 core**：

  1. `spawn_worker/4` —— 经 `Ezagent.Workspace.create_agent`（同 world `kanban_actions.ex:310`
     的 facade）建一个 `cc-headless` flavor 的 worker agent（真 claude brain）。cc-headless
     是 file-flavor，**不带 role**（RF-5b 未落地，role 在 file-flavor 上 fail-loud）。`cwd`
     = worker 操作的仓库工作树。
  2. `add_relay_rule/5` —— 经 `Ezagent.Routing.RuleStore.add/5` 写一条**字面 receiver** 路由规则：
     `all_of([in_session(板会话), text_contains("[kanban:<event>]")]) → [worker_uri]`，写完
     `load_into_registry/1` 热生效。

  ## 无环 DAG（防 A→B→A）
  规则只匹配**看板自己发**的 `[kanban:<event>] by <caller>` 标记公告（`kanban.ex:728-737`）。
  worker 收到后真 claude 决策、回复是**普通 chat（无 [kanban:*] 标记）**，不会再匹配本规则、
  不回灌看板会话的接力规则 → 链路是单向 DAG，不成环。`in_session` 把规则锁在该板绑定会话，
  不污染别的会话（`matcher.ex:88-108`）。

  > Allen 设计闸（SPEC §7 Phase 3 / §8.2）：本模块用 RuleStore.add + create_agent 是 KIND
  > 之间的现成调用，不新增 core 概念/不写 core 模块——开工前已与 Allen 确认。
  """

  alias Ezagent.Routing.{Matcher, RuleStore}
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

  @doc "建一个 cc-headless worker agent（真 claude brain）。`caller_ctx` = %{caller, caps}。"
  @spec spawn_worker(URI.t(), String.t(), String.t(), map()) ::
          {:ok, %{agent_uri: URI.t()}} | {:error, term()}
  def spawn_worker(%URI{scheme: "workspace"} = workspace_uri, name, cwd, caller_ctx)
      when is_binary(name) and is_binary(cwd) and is_map(caller_ctx) do
    Ezagent.Workspace.create_agent(
      workspace_uri,
      %{flavor: "cc-headless", name: name, cwd: cwd, with_pty: false},
      caller_ctx
    )
  end

  @doc """
  写一条把看板接力公告路由到 worker 的规则。`event` ∈ "claimed"|"status"|"pr_registered"
  （对齐 `Kanban.relay_text/2`）。receiver = 字面 worker URI（防环，见 moduledoc）。
  """
  @spec add_relay_rule(
          URI.t() | String.t(),
          URI.t() | String.t(),
          URI.t() | nil,
          URI.t() | nil,
          String.t()
        ) :: {:ok, integer()} | {:error, term()}
  def add_relay_rule(board_session_uri, worker_uri, created_by, workspace_uri, event)
      when is_binary(event) do
    matcher =
      Matcher.all_of([
        Matcher.in_session(to_str(board_session_uri)),
        Matcher.text_contains("[kanban:#{event}]")
      ])

    case RuleStore.add(MentionRouting, matcher, [to_str(worker_uri)], created_by,
           workspace_uri: workspace_uri
         ) do
      {:ok, %RuleStore{id: id}} ->
        :ok = RuleStore.load_into_registry(MentionRouting)
        {:ok, id}

      {:error, _} = err ->
        err
    end
  end

  defp to_str(%URI{} = u), do: URI.to_string(u)
  defp to_str(s) when is_binary(s), do: s
end
```
- [ ] **Step 4: 跑测试确认通过 + format + 不变式**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/worker_relay_test.exs && mise exec -- mix format --check-formatted apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/worker_relay.ex && mise exec -- mix ezagent.check_invariants.lifecycle`
Expected: PASS（gate 无新增；本模块非 Behavior、不触 NP 规则）
- [ ] **Step 5: e2e + 截图**（真 claude，要 `claude` CLI + cc-headless 凭证）：
  1. 起 server（`iex -S mix phx.server`），world 建一块板 + `bind_session` 绑一个会话；**截图**配置面板回显 session。
  2. iex 里 `EzagentPluginKanban.WorkerRelay.spawn_worker(ws, "worker_b", "/path/to/repo", %{caller: alice, caps: caps})` + `add_relay_rule(板会话, worker_uri, alice, ws, "claimed")`；**截图** `RuleStore.list(MentionRouting)` 含新规则 + `KindRegistry.lookup(worker_uri)` live。
  3. 在 chat 里对板 agent dispatch `claim_node`（owner=alice）→ 看板 `post_handle` 发 `[kanban:claimed] by ...` → **截图** worker 会话收到该公告（真 claude 回了一条），证明接力到达 worker。
  4. 存 `docs/e2e/2026-06-26-kanban-phase3/task1-*.png`。
- [ ] **Step 6: commit**
```bash
git add apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/worker_relay.ex apps/ezagent_plugin_kanban/test/worker_relay_test.exs docs/e2e/2026-06-26-kanban-phase3
git commit -m "feat(kanban): WorkerRelay — cc-headless worker + 字面 receiver 接力路由规则(Phase3 E)"
```

---

### Task 2: 仓库存证 connector（能力 G — 节点 artifact 落 docs/together/<date>/<node>/ 随 PR 进仓库）

**Files:**
- New: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/repo_evidence.ex`（FS 落盘 + 算仓库相对路径）
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（加 `archive_node` action 声明 `:212` 区附近 + `required_caps` list `:256-282` 加 `:archive_node` + `handle_archive_node/2` 薄转发）
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex`（加 `archive_node/2` 实现体，复用 `Shared.commit/1`）
- New: `apps/ezagent_plugin_kanban/test/behavior/archive_node_test.exs`

**Interfaces:**
- Produces:
  - `EzagentPluginKanban.RepoEvidence.write(node_id, artifact, date) :: {:ok, String.t()} | {:error, term()}` —— 把一条 inline-content artifact 写到 `docs/together/<date>/<node_id>/<safe-ref>.<ext>`，返回**仓库相对路径**（artifact `url` 用它，flow-redesign §3 第 1 条「最强存证」）。无 content（外链/上传）→ 写一个含 `url` 的占位 `.md`（flow-redesign §3 第 5 条「外链必须镜像进仓库」）。
  - Behavior action `archive_node`（args `%{id: :string}`, modes `[:call]`, caps `[:archive_node]`）—— 遍历该节点 artifacts，逐条落盘 + 回挂一条 `tool:"repo", kind:"<原kind>", url:<仓库路径>` artifact（经唯一 `Shared.commit/1`）。
- Consumes: `Shared.{tree,owner_or_admin?,normalize_artifact,commit}`（`shared.ex:27/37/122/34`）；仓库根经 `File.cwd!()`（运行节点的工作树）。

- [ ] **Step 1: 写失败测试**
```elixir
# apps/ezagent_plugin_kanban/test/behavior/archive_node_test.exs
defmodule Ezagent.Behavior.Kanban.ArchiveNodeTest do
  use ExUnit.Case, async: false
  alias EzagentPluginKanban.RepoEvidence

  @date "2026-06-26"

  test "write 把 inline-content artifact 落盘到 docs/together/<date>/<node>/ 返回仓库相对路径" do
    art = %{tool: "world", kind: "spec", ref: "feature-x", url: nil, content: "# Gherkin\nGiven ..."}
    assert {:ok, rel} = RepoEvidence.write("n6", art, @date)
    assert rel == "docs/together/#{@date}/n6/feature-x.md"
    assert File.read!(Path.join(File.cwd!(), rel)) =~ "Given ..."
  after
    File.rm_rf!(Path.join(File.cwd!(), "docs/together/#{@date}/n6"))
  end

  test "write 对外链 artifact 写含 url 的占位 md（仓库里能查到）" do
    art = %{tool: "feishu", kind: "doc", ref: "wireframe", url: "https://feishu/x", content: nil}
    assert {:ok, rel} = RepoEvidence.write("n7", art, @date)
    assert File.read!(Path.join(File.cwd!(), rel)) =~ "https://feishu/x"
  after
    File.rm_rf!(Path.join(File.cwd!(), "docs/together/#{@date}/n7"))
  end
end
```
- [ ] **Step 2: 跑测试确认失败**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/archive_node_test.exs`
Expected: FAIL（`RepoEvidence` 未定义）
- [ ] **Step 3: 实现**
  1. `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/repo_evidence.ex`：
```elixir
defmodule EzagentPluginKanban.RepoEvidence do
  @moduledoc """
  能力 G（仓库存证）的落盘半边：把一条节点 artifact 写进工作树
  `docs/together/<date>/<node-id>/`，返回**仓库相对路径**——文件进工作树后由
  dev-together `push` 随 PR 进仓库（flow-redesign §3 第 1 条「最强存证」、§5）。

  - inline content（≤64KB，真相源自带）→ 写正文文件，扩展名按 kind 推断。
  - 无 content 的外链/上传 → 写一个含 `url` 的占位 `.md`（§3 第 5 条「外链必须镜像进仓库」，
    保证「仓库里能查到」）。
  """

  @doc "落盘一条 artifact，返回仓库相对路径（`docs/together/<date>/<node>/<ref>.<ext>`）。"
  @spec write(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def write(node_id, artifact, date)
      when is_binary(node_id) and is_map(artifact) and is_binary(date) do
    kind = to_string(sget(artifact, :kind) || "artifact")
    ref = safe(to_string(sget(artifact, :ref) || kind))
    content = sget(artifact, :content)
    url = sget(artifact, :url)

    {body, ext} =
      cond do
        is_binary(content) and content != "" -> {content, ext_for(kind)}
        is_binary(url) and url != "" -> {"# #{kind}: #{ref}\n\n<#{url}>\n", "md"}
        true -> {"# #{kind}: #{ref}\n\n(无内容)\n", "md"}
      end

    rel = Path.join(["docs", "together", date, node_id, "#{ref}.#{ext}"])
    abs = Path.join(File.cwd!(), rel)
    _ = File.mkdir_p(Path.dirname(abs))

    case File.write(abs, body) do
      :ok -> {:ok, rel}
      err -> err
    end
  end

  defp ext_for("html"), do: "html"
  defp ext_for("excalidraw"), do: "json"
  defp ext_for("json"), do: "json"
  defp ext_for(_), do: "md"

  defp safe(s), do: s |> String.replace(~r/[^\w\-]/u, "-") |> String.slice(0, 80)
  defp sget(m, k), do: Map.get(m, k) || Map.get(m, Atom.to_string(k))
end
```
  2. `kanban.ex` —— action 声明（放在 `:set_board_config`/`:bind_session` 之后，连接器动作区）：
```elixir
  action(:archive_node,
    args: %{id: :string},
    returns: %{archived: :integer},
    caps: [:archive_node],
    modes: [:call],
    description: "把节点 artifacts 落盘到 docs/together/<date>/<node>/ 随 PR 进仓库（能力 G），回挂仓库路径 artifact"
  )
```
   `required_caps/0` 的 list（`kanban.ex:256-282`）加一行 `:archive_node,`；加薄转发：
```elixir
  @doc false
  def handle_archive_node(args, ctx), do: Connectors.archive_node(args, ctx)
```
  3. `connectors.ex` —— 实现体（节点级，`owner_or_admin?` 闸；落盘后回挂仓库路径 artifact，经唯一 `Shared.commit/1`）：
```elixir
  # 能力 G：把节点 artifacts 落盘进仓库 docs/together/<date>/<node>/，回挂仓库路径 artifact。
  @doc false
  def archive_node(%{id: id}, ctx) do
    t = Shared.tree(ctx)
    date = Date.utc_today() |> Date.to_iso8601()

    cond do
      not Map.has_key?(t.nodes, id) -> {:error, :node_not_found}
      not Shared.owner_or_admin?(ctx, t.nodes[id]) -> {:error, :forbidden}
      true ->
        n = t.nodes[id]

        repo_arts =
          for a <- n.artifacts, a.tool != "repo" do
            case EzagentPluginKanban.RepoEvidence.write(id, a, date) do
              {:ok, rel} ->
                Shared.normalize_artifact(%{tool: "repo", kind: a.kind, ref: a.ref, url: rel})

              {:error, _} ->
                nil
            end
          end
          |> Enum.reject(&is_nil/1)

        new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ repo_arts})
        {:ok, %{archived: length(repo_arts)}, [Shared.commit(%{t | nodes: new_nodes})]}
    end
  end
```
  （`alias EzagentPluginKanban.RepoEvidence` 已可经全名调用；connectors.ex 顶部 alias 区可加 `alias EzagentPluginKanban.RepoEvidence` 省略全名。）
- [ ] **Step 4: 跑测试确认通过 + format + 不变式**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/archive_node_test.exs apps/ezagent_plugin_kanban/test && mise exec -- mix format --check-formatted apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/repo_evidence.ex apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex && mise exec -- mix ezagent.check_invariants.lifecycle`
Expected: PASS（kanban 套件 59→61t；set_effect_sites gate 不报——树写入仍只经 `Shared.commit/1`）
- [ ] **Step 5: e2e + 截图**：world 看板某节点 `attach_artifact`（inline Gherkin）→ dispatch `archive_node` → **截图** 节点多出一条 `tool:repo` artifact（url=`docs/together/<date>/<node>/...`）；**截图** `git status` 工作树出现该文件。存 `docs/e2e/2026-06-26-kanban-phase3/task2-*.png`。
- [ ] **Step 6: commit**
```bash
git add apps/ezagent_plugin_kanban docs/e2e/2026-06-26-kanban-phase3
git commit -m "feat(kanban): RepoEvidence + archive_node — 节点 artifact 落仓库随 PR 存证(Phase3 G)"
```

---

### Task 3: dev-together 自动挂载 + board_node_id 字段（§4 — handoff→issue 节点 / return→该节点）

**Files:**
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（加 CLI 友好的标量参数动作 `attach_node_doc` 声明 + `required_caps` list 加 `:attach_node_doc` + `handle_attach_node_doc/2`）
- Modify: `.claude/skills/dev-together/commands/return.md`（元数据块加 `board_node_id` + 第 6 步加自动挂载）
- Modify: `.claude/skills/dev-together/commands/handoff.md`（输出加 `board_node_id` + handoff 落地后自动挂 issue 节点）
- Modify: `.claude/skills/dev-together/references/handoff-template.md`（模板元数据加 `board_node_id`）
- New: `apps/ezagent_plugin_kanban/test/behavior/attach_node_doc_test.exs`

**Interfaces:**
- Produces: Behavior action `attach_node_doc`（args `%{id: :string, kind: :string, url: :string}`, caps `[:attach_node_doc]`, modes `[:call]`）—— **全标量参数**（规避 `attach_artifact` 的 `:map` 参数在 CLI/dispatch 边界难传），内部 `normalize_artifact(%{tool: "dev-together", kind, ref: <url末段>, url})` + `Shared.commit`。这是 dev-together「on 版」命令自动回挂的 CLI 入口（`mix ezagent agent attach_node_doc --uri <板agent> --id <node> --kind handoff --url docs/together/<date>/handoffs/<task>.md`，经 `EzagentCli` 自动命令树 `apps/ezagent_cli/lib/ezagent_cli/exec.ex:164-177` 解析 `agent <action>`）。
- Consumes: `Shared.{tree,owner_or_admin?,normalize_artifact,commit}`。
- **挂载映射**（flow-redesign §4a）：**handoff→该 task 的 issue 节点**（handoff=节点 spec）；**return→该节点**（return=交付物）。节点 id 来自 dev-together 台账新增的 `board_node_id` 字段。

- [ ] **Step 1: 写失败测试**
```elixir
# apps/ezagent_plugin_kanban/test/behavior/attach_node_doc_test.exs
defmodule Ezagent.Behavior.Kanban.AttachNodeDocTest do
  use Ezagent.LifecycleCase, async: true
  alias Ezagent.Behavior.Kanban

  test "attach_node_doc 用标量参数把仓库路径文档挂到节点（dev-together 自动挂载入口）" do
    admin_ctx = %{caller: "entity://acme/user/lead", caps: admin_caps()}
    tree = %{nodes: %{"n6" => node("n6")}, root_id: "n6", seq: 1, drops: []}
    ctx = read_ctx(admin_ctx, %{tree: tree})

    assert {:ok, %{}, effects} =
             Kanban.handle_attach_node_doc(
               %{id: "n6", kind: "handoff", url: "docs/together/2026-06-26/handoffs/feat-x.md"},
               ctx
             )

    assert [{:set, :tree, new_tree}] = effects
    [art] = new_tree.nodes["n6"].artifacts
    assert art.kind == "handoff"
    assert art.url == "docs/together/2026-06-26/handoffs/feat-x.md"
    assert art.tool == "dev-together"
  end

  # node/1, admin_caps/0, read_ctx/2 复用 kanban test 既有 helper（见 test/support）
end
```
> 注：`read_ctx/2`/`node/1`/`admin_caps/0` 用 kanban 套件已有 helper（参照 `test/behavior/` 邻近文件——加测前先看邻近 idiom，沙箱/ctx 构造不统一）。
- [ ] **Step 2: 跑测试确认失败**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/attach_node_doc_test.exs`
Expected: FAIL（`handle_attach_node_doc` 未定义）
- [ ] **Step 3: 实现**
  1. `kanban.ex` action 声明（挂载动作区，`attach_artifact` 之后）：
```elixir
  action(:attach_node_doc,
    args: %{id: :string, kind: :string, url: :string},
    returns: %{},
    caps: [:attach_node_doc],
    modes: [:call],
    description: "标量参数挂一条仓库路径文档到节点（dev-together 自动挂载入口：handoff→issue节点/return→该节点）"
  )
```
   `required_caps/0` list 加 `:attach_node_doc,`；handler（节点级 owner_or_admin，经唯一 commit）：
```elixir
  @doc false
  def handle_attach_node_doc(%{id: id, kind: kind, url: url}, ctx)
      when is_binary(kind) and is_binary(url) do
    ref = url |> String.split("/") |> List.last()
    update_node(ctx, id, fn n ->
      art = Shared.normalize_artifact(%{tool: "dev-together", kind: kind, ref: ref, url: url})
      %{n | artifacts: n.artifacts ++ [art]}
    end)
  end
```
  2. `.claude/skills/dev-together/references/handoff-template.md` 元数据块加一行 `> **board_node_id:** <该 task 对应的 issue 节点 id，如 n6>`。
  3. `.claude/skills/dev-together/commands/handoff.md` 的 **Output** 段加：
     > **on dispatch 版**：handoff 落地后，按其 `board_node_id` 自动回挂到该 **issue 节点**（handoff=节点 spec）：
     > `mix ezagent agent attach_node_doc --uri <板agent URI> --id <board_node_id> --kind handoff --url docs/together/<date>/handoffs/<task>.md`
     > （off 文件版：人/脚本写完文件后跑同一命令。）
  4. `.claude/skills/dev-together/commands/return.md`：
     - **Required metadata block**（`:36-44`）加一行 `> **board_node_id:** <该 task 的节点 id>`。
     - 第 6 步后加：
       > **自动挂载（on 版）**：return 落地后按 `board_node_id` 自动回挂到**该节点**（return=交付物）：
       > `mix ezagent agent attach_node_doc --uri <板agent> --id <board_node_id> --kind return --url docs/together/<date>/returns/<task>.md`；
       > 再 dispatch `register_pr`（PR 出现后；Phase 2 github 入站自动化后此步由入站代劳）。
- [ ] **Step 4: 跑测试确认通过 + format + 不变式**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/attach_node_doc_test.exs apps/ezagent_plugin_kanban/test && mise exec -- mix format --check-formatted apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex && mise exec -- mix ezagent.check_invariants.lifecycle`
Expected: PASS
- [ ] **Step 5: e2e + 截图**：
  1. world 建板 + 建一个 issue 节点（记其 id，如 n6）；填进一份 handoff 的 `board_node_id`。
  2. 跑 `mix ezagent agent attach_node_doc --uri <板agent> --id n6 --kind handoff --url docs/together/2026-06-26/handoffs/feat-x.md --token <t> --uri <user>`；**截图** CLI 成功 + world 节点 n6 多出 `kind:handoff` artifact（url=仓库路径）。
  3. 同样验 return→该节点。存 `docs/e2e/2026-06-26-kanban-phase3/task3-*.png`。
- [ ] **Step 6: commit**
```bash
git add apps/ezagent_plugin_kanban .claude/skills/dev-together docs/e2e/2026-06-26-kanban-phase3
git commit -m "feat(kanban): attach_node_doc + dev-together board_node_id 自动挂载(Phase3 §4)"
```

---

### Task 4: 板级时间线 :timeline 字段 + world UI 时间线侧栏（能力 T）

**Files:**
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/shared.ex`（`empty_tree` 加 `timeline: []` `:24`；`commit/1` 补 `Map.put_new(:timeline, [])` `:34`；加 `timeline/1` reader）
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（加 `attach_timeline` action + `required_caps` + handler；`get_tree` 返回加 `timeline:` `:565-574`）
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex`（`board_snapshot` 的 tree map 加 `"timeline"` `:135-143`）
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex`（加 `kanban.attach_timeline` 子句）
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`（`@kanban_actions` 白名单加 `kanban.attach_timeline`）
- Modify: `apps/ezagent_plugin_world/assets/src/components/Kanban.tsx`（`Tree` 类型加 `timeline?`；侧栏加时间线区块，仿 drop 历史 `:250-273`）
- New: `apps/ezagent_plugin_kanban/test/behavior/timeline_test.exs`

**Interfaces:**
- Produces: Behavior action `attach_timeline`（args `%{kind: :string, date: :string, url: :string, content: :string}`, caps `[:attach_timeline]`, modes `[:call]`）—— 板级（**任意持 cap 成员**，对齐图级动作；不挂单节点），追加 `%{kind, date, url, content}` 到 `tree.timeline`，经唯一 `Shared.commit/1`。`get_tree` 返回 `timeline: Map.get(t, :timeline, [])`（与 `drops` 并列）。
- Consumes: `Shared.{tree,timeline,commit}`；前端经 `world:state` 的 `tree.timeline` 渲染。
- **挂载映射**（flow-redesign §4b）：日/周总结、plan、stack、review 这类跨多节点产物挂这里，键=`<date>`/`<ISO-week>`，**不污染 9 阶段画布**。

- [ ] **Step 1: 写失败测试**
```elixir
# apps/ezagent_plugin_kanban/test/behavior/timeline_test.exs
defmodule Ezagent.Behavior.Kanban.TimelineTest do
  use Ezagent.LifecycleCase, async: true
  alias Ezagent.Behavior.Kanban
  alias Ezagent.Behavior.Kanban.Shared

  test "empty_tree/commit 带 timeline（与 drops 同构）" do
    assert %{timeline: []} = Shared.empty_tree()
    assert {:set, :tree, %{timeline: []}} = Shared.commit(%{nodes: %{}, root_id: nil, seq: 0})
  end

  test "attach_timeline 板级追加一条日总结（不挂单节点），get_tree 一并返回" do
    ctx = read_ctx(%{caller: "entity://acme/user/dee", caps: member_caps()}, %{tree: Shared.empty_tree()})

    assert {:ok, %{}, [{:set, :tree, t}]} =
             Kanban.handle_attach_timeline(
               %{kind: "review", date: "2026-06-26", url: "docs/together/2026-06-26/review.html", content: ""},
               ctx
             )

    assert [%{kind: "review", date: "2026-06-26"}] = t.timeline

    gctx = read_ctx(%{caller: "entity://acme/user/dee", caps: member_caps()}, %{tree: t})
    assert {:ok, %{timeline: [%{kind: "review"}]}, []} = Kanban.handle_get_tree(%{}, gctx)
  end
end
```
- [ ] **Step 2: 跑测试确认失败**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/timeline_test.exs`
Expected: FAIL（`timeline` 字段/`handle_attach_timeline` 未定义）
- [ ] **Step 3: 实现**
  1. `shared.ex`：
```elixir
  # :24
  def empty_tree, do: %{nodes: %{}, root_id: nil, seq: 0, drops: [], timeline: []}

  # :34 — commit 归一 drops + timeline（旧树/字面量缺这两个板级字段时补 []）
  def commit(tree),
    do: {:set, :tree, tree |> Map.put_new(:drops, []) |> Map.put_new(:timeline, [])}

  @doc "经 `ctx[:read]` 读板级时间线（缺省 [])。"
  def timeline(tree), do: Map.get(tree, :timeline, [])
```
  2. `kanban.ex`：action 声明（图级动作区）：
```elixir
  action(:attach_timeline,
    args: %{kind: :string, date: :string, url: :string, content: :string},
    returns: %{},
    caps: [:attach_timeline],
    modes: [:call],
    description: "板级时间线追加一条（日/周总结/plan/review/stack，按 date/week 键，不挂单节点）"
  )
```
   `required_caps/0` list 加 `:attach_timeline,`；handler（板级，任意持 cap 成员；经唯一 commit）：
```elixir
  @doc false
  def handle_attach_timeline(%{kind: kind, date: date} = args, ctx)
      when is_binary(kind) and is_binary(date) do
    t = tree(ctx)
    entry = %{
      kind: kind,
      date: date,
      url: Shared.normalize_artifact(%{url: Map.get(args, :url)}).url,
      content: Shared.normalize_artifact(%{content: Map.get(args, :content)}).content
    }
    {:ok, %{}, [commit(%{t | timeline: Shared.timeline(t) ++ [entry]})]}
  end
```
   `get_tree` 返回 map（`:565-574`）加一行 `timeline: Map.get(t, :timeline, []),`（与 `drops:` 并列）。
  3. `kanban_data.ex` `board_snapshot`（`:135-143` 的 `"tree"` map）加：
```elixir
            "timeline" => Enum.map(Map.get(res, :timeline, []), &jsonable_map/1)
```
   （`jsonable_map/1` 已存在 `:228`，atom→string。）
  4. `kanban_actions.ex` 加子句：
```elixir
  def handle_dispatch(socket, "kanban.attach_timeline", %{"kanban_uri" => u} = a),
    do:
      act(socket, u, :attach_timeline, %{
        kind: Map.get(a, "kind", "summary"),
        date: Map.get(a, "date", ""),
        url: Map.get(a, "url", ""),
        content: Map.get(a, "content", "")
      })
```
  5. `world_live.ex` `@kanban_actions` 白名单加 `"kanban.attach_timeline"`。
  6. `Kanban.tsx`：`Tree` 类型（`:25`）加 `timeline?: TimelineEntry[]`（`type TimelineEntry = {kind: string; date: string; url?: string; content?: string}`）；侧栏 `<aside>`（`:206`）drop 历史区块后加：
```tsx
{(tree.timeline || []).length > 0 && (
  <div className="rounded-md border p-2">
    <div className="mb-1.5 text-xs font-semibold text-muted-foreground">
      时间线 / 日周总结（{(tree.timeline || []).length}）
    </div>
    <ul className="space-y-1">
      {(tree.timeline || []).map((e, i) => (
        <li key={i} className="text-xs">
          <span className="text-muted-foreground">{e.date}</span> · {e.kind}
          {e.url ? <> · <a className="underline" href={e.url}>{e.url}</a></> : null}
        </li>
      ))}
    </ul>
  </div>
)}
```
- [ ] **Step 4: 跑测试确认通过 + format + 不变式**
Run: `mise exec -- mix test apps/ezagent_plugin_kanban/test/behavior/timeline_test.exs apps/ezagent_plugin_kanban/test && mise exec -- mix format --check-formatted apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/shared.ex apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex && mise exec -- mix ezagent.check_invariants.lifecycle`
Expected: PASS（旧快照缺 `:timeline` 经 `commit/1` 的 `put_new` 自愈，不破坏既有 board）
- [ ] **Step 5: e2e + 截图**：
  1. world 建板 → dispatch `attach_timeline`（kind=review, date=2026-06-26, url=docs/together/2026-06-26/review.html）；**截图** 侧栏「时间线/日周总结」区块出现该条 + 链接可点。
  2. 验**不污染画布**：9 阶段画布**截图**无新增节点。
  3. 存 `docs/e2e/2026-06-26-kanban-phase3/task4-*.png`。
- [ ] **Step 6: commit**
```bash
git add apps/ezagent_plugin_kanban apps/ezagent_plugin_world docs/e2e/2026-06-26-kanban-phase3
git commit -m "feat(kanban): 板级 :timeline 字段 + attach_timeline + world 时间线侧栏(Phase3 T)"
```

---

## Self-Review（writing-plans）
- **Spec 覆盖**：Phase 3 四能力一一对应 4 任务——E(worker 接力 Task1) / G(仓库存证 Task2) / §4(dev-together 自动挂载 Task3) / T(板级时间线 Task4)。SPEC §7 Phase 3 列的就这四项 ✓。
- **三层铁律**：所有新代码在 kanban **plugin**（worker_relay/repo_evidence/Behavior 动作）或 **world**（kanban_data/kanban_actions/Kanban.tsx）；**core 零改**——`RuleStore.add`/`Matcher`/`Workspace.create_agent` 是现成 API 仅调用（Task1 已标 Allen 设计闸）。跨 Kind 全走 dispatch / facade（P14）✓。
- **唯一写收口**：Task2/3/4 的树写入全经 `Shared.commit/1`（`shared.ex:34`）——未新开 `{:set, :tree}` 站点，arch.scan set_effect_sites 不报 ✓。
- **新动作三处登记齐**：每个新动作（archive_node/attach_node_doc/attach_timeline）都 ① `action/3` 声明 ② `required_caps/0` list 加 atom（`kanban.ex:256-282`）③ recipe 经 `actions()` 自动覆盖（`application.ex:80`）；world 驱动的 attach_timeline 另加 world 白名单 ✓。
- **无环 DAG（防 A→B→A）**：Task1 receiver 是字面 worker URI，matcher 只命中看板自发的 `[kanban:*]` 标记 + `in_session` 锁定板会话；worker 回复无标记 → 不回灌（moduledoc 写死论证）✓。
- **board_node_id 缝合键**：Task3 落到 dev-together 台账（handoff/return/template 三文件）+ `attach_node_doc` CLI 入口；handoff→issue 节点、return→该节点的映射对齐 flow-redesign §4a ✓。
- **artifact「读得到」**：Task2 落盘 = flow-redesign §3 第 1 条「仓库路径=最强」；外链写占位 md = 第 5 条「镜像进仓库」✓。
- **占位扫描**：无 TBD/TODO；代码块给全；test helper 复用处显式标注「看邻近 idiom」（沙箱写法项目不统一）✓。
- **向后兼容**：Task4 `empty_tree` 改形 + 旧快照缺 `:timeline` 经 `commit/1` 的 `Map.put_new` 自愈，不破坏既有 board ✓。
- **类型一致**：`create_agent/3` 签名对齐 `kanban_actions.ex:310`；`RuleStore.add/5` 对齐 `template_team.ex:236`；`get_tree` 返回 `timeline:` 与 `drops:` 同构、read-model `jsonable_map` 复用 ✓。
- **待拍板未阻塞本 Phase**：多仓库（SPEC §5/H）是 Phase 4，本 Phase 仓库存证按一图一仓（`BoardConfig.github_repo`）落盘，不依赖多仓库决议 ✓。

## dev-together 对齐
- **board_node_id** 是 SPEC 缺口 B 的落实点（Task3）——dev-together 台账缝看板节点的唯一键。
- **两份存证，一次产出**（flow-redesign §4 结论）：Task2 落 `docs/together/`（随 PR 进仓库）+ Task3 自动回挂看板节点；节点级挂节点（attach_node_doc）、板级挂时间线（attach_timeline）。
- **gate 全集含 `uri_query.scan`**（dev-together 约定）：本 Phase 新动作用 `?action=kanban.<a>` query-string，跑 push 前确认该 gate 绿。
