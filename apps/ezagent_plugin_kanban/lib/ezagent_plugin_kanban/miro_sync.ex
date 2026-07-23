defmodule EzagentPluginKanban.MiroSync do
  @moduledoc """
  kanban ↔ Miro 双向同步轮询器（**plugin 自有进程**，不复用 session 锁死的
  external_mirror 域；全程 `Ezagent.Invocation.dispatch/1`，零越界）。

  每 tick（或 `sync_now/1`）：
  1. **入站（非破坏性）**：GET Miro → `Sync.detect_inbound`（人新增）→ `dispatch add_node`
     回 ezagent（P14）。Miro 端删除**不**回删 ezagent。
  2. **出站**：重读 ezagent 树（**真相源**，含刚入站的）→ `Sync.sync_out` 复用同板 →
     更新 `ez_id↔miro_id` 映射（入站回声基线）。

  生命周期（真相源=ezagent、CapBAC 域不同）：
  - ezagent 删 kanban → 调 `teardown/1` 联动删 Miro 板。
  - Miro 删板（GET 404）→ 返回 `:board_gone` 告警，**不动 ezagent**（下次重建自愈）。

  dispatch 身份 = 系统 admin（受信后台集成，对齐 EM Worker 用系统 cap 的先例）。
  """
  use GenServer

  alias EzagentPluginKanban.Miro
  alias EzagentPluginKanban.Miro.Sync

  @default_interval 30_000
  @registry EzagentPluginKanban.MiroSyncRegistry
  @supervisor EzagentPluginKanban.MiroSyncSupervisor

  @doc false
  def start_link(opts) do
    opts = Map.new(opts)
    GenServer.start_link(__MODULE__, opts, name: via(opts.uri))
  end

  @doc """
  绑定一个 kanban↔Miro 板的双向同步：在 plugin 监督树下起轮询器，按 kanban URI
  唯一注册。`opts` 可带 `interval:`（ms，默认 30s；`0` 关周期、只手动 `sync_now`）。
  """
  @spec bind(URI.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def bind(uri, board_id, opts \\ []) do
    spec = {__MODULE__, Keyword.merge([uri: uri, board_id: board_id], opts)}
    DynamicSupervisor.start_child(@supervisor, spec)
  end

  @doc "解绑：拆镜像（删 Miro 板）+ 停轮询。等同 ezagent 删 kanban 的联动。"
  @spec unbind(URI.t()) :: :ok | {:error, term()}
  def unbind(uri), do: teardown(uri)

  @doc "立刻跑一轮双向同步（`ref` = pid 或 kanban URI）。`{:ok, %{inbound: n}}` | `{:error, _}`。"
  def sync_now(ref), do: GenServer.call(server(ref), :sync_now, 30_000)

  @doc """
  一键推 Miro：已绑定则直接 `sync_now`；未绑定则**新建一块板 + bind + sync**。返回
  `{:ok, %{inbound, board_id}}`——供 world 操作面"推 Miro"按钮（用户不必管 board）。
  """
  @spec sync_or_bind(URI.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def sync_or_bind(uri, board_name) do
    case board_id(uri) do
      {:ok, board} ->
        with {:ok, r} <- sync_now(uri), do: {:ok, Map.put(r, :board_id, board)}

      :not_bound ->
        with {:ok, %{token: t}} <- Miro.read_creds(),
             {:ok, board} <- Miro.create_board(t, board_name),
             {:ok, _} <- bind(uri, board, interval: 0),
             {:ok, r} <- sync_now(uri) do
          {:ok, Map.put(r, :board_id, board)}
        end
    end
  end

  @doc "返回某 kanban 已绑定的 Miro board id，未绑定 `:not_bound`。"
  @spec board_id(URI.t()) :: {:ok, String.t()} | :not_bound
  def board_id(uri) do
    {:ok, GenServer.call(server(uri), :board_id, 30_000)}
  catch
    :exit, _ -> :not_bound
  end

  @doc "拆镜像：删 Miro 板 + 停轮询（`ref` = pid 或 kanban URI）。"
  def teardown(ref), do: GenServer.call(server(ref), :teardown, 30_000)

  defp server(pid) when is_pid(pid), do: pid
  defp server(%URI{} = uri), do: via(uri)
  defp via(uri), do: {:via, Registry, {@registry, URI.to_string(uri)}}

  @impl true
  def init(opts) do
    state = %{
      uri: Map.fetch!(opts, :uri),
      board_id: Map.fetch!(opts, :board_id),
      mapping: %{},
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

  def handle_call(:board_id, _from, state), do: {:reply, state.board_id, state}

  def handle_call(:teardown, _from, state) do
    res =
      case Miro.read_creds() do
        {:ok, %{token: t}} -> Miro.delete_board(t, state.board_id)
        err -> err
      end

    {:stop, :normal, res, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, state} = sync(state)
    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  # --- 同步核心 ---------------------------------------------------------

  defp sync(state) do
    with {:ok, token} <- token(),
         {:ok, miro_nodes} <- read_miro(token, state.board_id) do
      # 入站（非破坏性）：人新增 → dispatch add（P14）
      inbound = Sync.detect_inbound(miro_nodes, state.mapping)
      Enum.each(inbound, fn op -> add_node(state.uri, op.parent_ez_id, op.content) end)

      # 出站：重读真相源（含刚入站的）→ sync_out 复用同板 → 更新映射
      case Sync.sync_out(read_tree(state.uri), state.board_id) do
        {:ok, %{mapping: m}} -> {{:ok, %{inbound: length(inbound)}}, %{state | mapping: m}}
        err -> {err, state}
      end
    else
      # 板被人删了：真相源=ezagent，不回删 ezagent（下次重建自愈）
      {:error, :board_gone} -> {{:error, :board_gone}, state}
      err -> {err, state}
    end
  end

  defp read_miro(token, board_id) do
    case Miro.get_nodes(token, board_id) do
      {:ok, nodes} -> {:ok, nodes}
      {:error, {:http_status, 404, _}} -> {:error, :board_gone}
      err -> err
    end
  end

  defp token do
    case Miro.read_creds() do
      {:ok, %{token: t}} -> {:ok, t}
      err -> err
    end
  end

  # --- ezagent dispatch（系统身份）-------------------------------------

  defp read_tree(uri) do
    case do_dispatch(uri, "get_tree", %{}) do
      {:ok, %{tree: %{nodes: nodes, root_id: root}}} -> %{nodes: nodes, root_id: root}
      _ -> %{nodes: %{}, root_id: nil}
    end
  end

  defp add_node(uri, parent_ez_id, content),
    do: do_dispatch(uri, "add_node", %{parent_id: parent_ez_id || "", title: content})

  defp do_dispatch(uri, action, args) do
    # sanctioned 构造（过 uri_query.scan）：with_action 而非裸 `?action=` 串。
    target = Ezagent.URI.with_action(uri, :kanban, action)

    caller = sys_caller()

    with {:ok, signed_cap} <-
           Ezagent.Cap.issue_for_action({:admin, caller}, caller, target) do
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :call,
        args: args,
        ctx: %{
          caller: caller,
          authenticated_principal: caller,
          caps: MapSet.new([signed_cap]),
          reply: {:caller_inbox, self()}
        },
        origin: :trusted_internal
      })
    end
  end

  defp sys_caller, do: Ezagent.URI.user(:system, :admin)
end
