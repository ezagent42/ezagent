defmodule EzagentPluginGithub.PrSync do
  @moduledoc """
  GitHub open-PR 入站轮询器（**plugin 自有进程**，仿 kanban `EzagentPluginKanban.MiroSync`
  骨架；全程 `Ezagent.Invocation.dispatch/1`，跨插件零编译依赖 kanban）。

  每 tick（或 `sync_now/1`）：`Gh.list_open_prs(repo)` → 对每个 open PR，按**分支名约定**
  解析出 kanban 节点 id → 未去重过则系统身份 dispatch 回 `kanban.register_pr`（把 PR 挂到
  该节点）→ 经 `Ezagent.Idempotency` 记 seen 防重复登记。

  ## 分支名 ↔ 节点匹配约定（命门）

  kanban 的 `register_pr` 只接受显式 `%{id: 节点id, pr: PR号}`——**它自身不做匹配**。入站
  轮询拿到的 open PR 只有 `head_ref`（分支名）/`head_sha`/`number`，节点结构里也**不预存**
  期望分支，所以 PR↔节点的匹配键 = **分支名约定**：分支名形如 `kanban/<node_id>`（其后可跟
  `/` 或 `-` 加任意 slug），其中 `<node_id>` = kanban 节点 id（`n` + 数字，见 kanban
  `add_node`）。例：

    * `kanban/n7`            → 节点 `n7`
    * `kanban/n7-login-form` → 节点 `n7`
    * `kanban/n12/feature-x` → 节点 `n12`
    * `main` / `feature/x`   → 无匹配（跳过，非 kanban 跟踪的 PR）

  board 由本 poller 轮询的 repo 锁定（一个 poller 一块 board + 一个 repo），node id 在
  board 内唯一，故分支名只需编码 node id。

  ## 绑定（按板 bind，仿 MiroSync；无 boot 竞态）

  **boot 不主动轮询任何板**：github 插件读不到 kanban 的 per-board 配置（跨插件零编译
  依赖），且避免 boot 竞态。由能依赖本插件的编排层（world / e2e 驱动）按板调
  `bind(kanban_uri, repo, opts)` 起一个 poller，poller 持 `kanban_uri` + `repo`。
  `interval: 0` 关周期、只手动 `sync_now/1`（仿 MiroSync 懒种思路）。

  ## 去重

  `Ezagent.Idempotency.seen?/record`（ETS LRU）：key =
  `{:github_pr_registered, repo, node_id, number}`，是 poller 侧的**快速防重**（省掉重复
  dispatch）。**仅在 dispatch 成功后 record**——失败不记，下个 tick 重试（poller 语义，非
  webhook 一次性投递；失败经 `Logger.warning` surface，**不静默丢**）。

  > kanban 侧 `register_pr` 现已**自幂等**（按 (repo, node_id, pr) 查节点现有 artifacts 去
  > 重，见 `Ezagent.Behavior.Kanban.Connectors.pr_already_registered?/2`），是真相源侧的权威
  > 防重。两层叠加：ETS 非持久，节点重启后本 seen 清空、同一 open PR 会再 dispatch 一次，但
  > kanban 自幂等会吞掉它（不再产生重复 artifact）——故重启不再有重复 artifact 风险。

  dispatch 身份 = 系统 admin（受信后台集成，对齐 MiroSync 用 `admin_genesis_cap` 的先例）。
  """

  use GenServer

  require Logger

  alias EzagentPluginGithub.Gh

  @default_interval 30_000
  @registry EzagentPluginGithub.PrSyncRegistry
  @supervisor EzagentPluginGithub.PrSyncSupervisor

  @doc false
  def start_link(opts) do
    opts = Map.new(opts)
    GenServer.start_link(__MODULE__, opts, name: via(opts.uri))
  end

  @doc """
  绑定一块 kanban 板的 open-PR 入站轮询：在 plugin 监督树下起 poller，按 kanban URI 唯一
  注册。`opts` 可带 `interval:`（ms，默认 30s；`0` 关周期、只手动 `sync_now/1`）。
  """
  @spec bind(URI.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def bind(uri, repo, opts \\ []) do
    spec = {__MODULE__, Keyword.merge([uri: uri, repo: repo], opts)}
    DynamicSupervisor.start_child(@supervisor, spec)
  end

  @doc "解绑：停该板的轮询 poller（`ref` = pid 或 kanban URI）。"
  @spec unbind(URI.t() | pid()) :: :ok
  def unbind(ref), do: GenServer.call(server(ref), :stop)

  @doc """
  立刻跑一轮入站轮询（`ref` = pid 或 kanban URI）。返回 `{:ok, %{registered: n}}`（本轮新
  登记的 PR 数）| `{:error, reason}`（list_open_prs 失败）。
  """
  @spec sync_now(URI.t() | pid()) :: {:ok, %{registered: non_neg_integer()}} | {:error, term()}
  def sync_now(ref), do: GenServer.call(server(ref), :sync_now, 60_000)

  @doc """
  从 PR 分支名解析 kanban 节点 id（PR↔节点匹配约定）。分支形如 `kanban/<node_id>`（其后可
  跟 `/` 或 `-` 加任意 slug），node_id = `n` + 数字。返回 `{:ok, node_id}` | `:none`。

  Public 以便纯逻辑单测断言约定（匹配键解析），不必起进程/打真网。

      iex> EzagentPluginGithub.PrSync.node_id_for_branch("kanban/n7-login")
      {:ok, "n7"}

      iex> EzagentPluginGithub.PrSync.node_id_for_branch("main")
      :none
  """
  @spec node_id_for_branch(String.t() | nil | term()) :: {:ok, String.t()} | :none
  def node_id_for_branch(branch) when is_binary(branch) do
    case Regex.run(~r{^kanban/(n\d+)(?:[-/].*)?$}, branch) do
      [_, node_id] -> {:ok, node_id}
      _ -> :none
    end
  end

  def node_id_for_branch(_), do: :none

  @doc """
  去重键（`Ezagent.Idempotency` 用）：`{:github_pr_registered, repo, node_id, number}`。

  Public 以便纯逻辑单测断言键稳定且区分 repo/node/pr（去重契约）。
  """
  @spec dedup_key(String.t(), String.t(), integer()) ::
          {:github_pr_registered, String.t(), String.t(), integer()}
  def dedup_key(repo, node_id, number), do: {:github_pr_registered, repo, node_id, number}

  defp server(pid) when is_pid(pid), do: pid
  defp server(%URI{} = uri), do: via(uri)
  defp via(uri), do: {:via, Registry, {@registry, URI.to_string(uri)}}

  @impl true
  def init(opts) do
    state = %{
      uri: Map.fetch!(opts, :uri),
      repo: Map.fetch!(opts, :repo),
      interval: Map.get(opts, :interval, @default_interval)
    }

    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    {result, state} = sync(state)
    {:reply, result, state}
  end

  def handle_call(:stop, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info(:tick, state) do
    {_result, state} = sync(state)
    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  # --- 轮询核心 -------------------------------------------------------

  defp sync(state) do
    case Gh.list_open_prs(state.repo) do
      {:ok, prs} when is_list(prs) ->
        registered =
          Enum.reduce(prs, 0, fn pr, acc -> acc + register_pr(state.uri, state.repo, pr) end)

        {{:ok, %{registered: registered}}, state}

      {:error, reason} = err ->
        # 不静默丢：list 失败 surface 出来（下个 tick 重试）。
        Logger.warning(
          "github pr_sync: list_open_prs failed repo=#{state.repo} reason=#{inspect(reason)}"
        )

        {err, state}

      other ->
        {{:error, {:unexpected_response, other}}, state}
    end
  end

  # 处理一个 open PR：解析节点 → 去重 → dispatch register_pr → 记 seen。返回新登记数（0|1）。
  defp register_pr(uri, repo, pr) do
    case node_id_for_branch(Map.get(pr, :head_ref)) do
      {:ok, node_id} -> maybe_register(uri, repo, node_id, Map.get(pr, :number))
      # 分支名不符约定 → 非 kanban 跟踪的 PR，正常跳过（非错误，不告警）。
      :none -> 0
    end
  end

  defp maybe_register(uri, repo, node_id, number) when is_integer(number) do
    key = dedup_key(repo, node_id, number)

    if Ezagent.Idempotency.seen?(key) do
      # 已登记过 → 不重复 dispatch（快速防重；kanban 侧 register_pr 另有自幂等兜底）。
      0
    else
      case dispatch_register(uri, node_id, number) do
        {:ok, _result} ->
          :ok = Ezagent.Idempotency.record(key)
          1

        {:error, reason} ->
          # 不静默丢：dispatch 失败 surface（不记 seen，下个 tick 重试）。
          Logger.warning(
            "github pr_sync: register_pr dispatch failed uri=#{URI.to_string(uri)} " <>
              "node=#{node_id} pr=##{number} reason=#{inspect(reason)}"
          )

          0
      end
    end
  end

  # number 非整数（异常 gh 输出）→ 跳过。
  defp maybe_register(_uri, _repo, _node_id, _number), do: 0

  # 跨插件 dispatch 回 kanban（系统身份，:call 同步拿结果）。sanctioned 构造（过
  # uri_query.scan）：`with_action` 而非裸 query 串；caller/caps 走系统 admin。
  defp dispatch_register(uri, node_id, number) do
    target = Ezagent.URI.with_action(uri, :kanban, :register_pr)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{id: node_id, pr: Integer.to_string(number)},
      ctx: %{caller: sys_caller(), caps: sys_caps(), reply: {:caller_inbox, self()}}
    })
  end

  defp sys_caller, do: Ezagent.URI.user(:system, :admin)
  defp sys_caps, do: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
end
