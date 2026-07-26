defmodule EzagentPluginKanban.MiroSync do
  @moduledoc """
  kanban ↔ Miro 双向同步器（**plugin 自有进程**，不复用 session 锁死的
  external_mirror 域；全程 `Ezagent.Invocation.dispatch/1`，零越界）。

  每次 `sync_now/1`：
  1. **入站（非破坏性）**：GET Miro → `Sync.detect_inbound`（人新增）→ `dispatch add_node`
     回 ezagent（P14）。Miro 端删除**不**回删 ezagent。
  2. **出站**：重读 ezagent 树（**真相源**，含刚入站的）→ `Sync.sync_out` 复用同板 →
     更新 `ez_id↔miro_id` 映射（入站回声基线）。

  生命周期（真相源=ezagent、CapBAC 域不同）：
  - ezagent 删 kanban / 停 poller（含 seam `terminate_child`）→ `terminate/2`
    联动删 Miro 板。
  - Miro 删板（GET 404）→ 返回 `:board_gone` 告警，**不动 ezagent**（下次重建自愈）。

  dispatch 身份 = 系统 admin（受信后台集成，对齐 EM Worker 用系统 cap 的先例）。

  ## V5 pid-closure A1b — resolver-seam registration

  Every MiroSync poller SELF-registers under `{kanban_uri, :ezagent_plugin_kanban,
  :miro_sync}` in the unified `Ezagent.Runtime.SidecarRegistry` (the retired
  private `EzagentPluginKanban.MiroSyncRegistry` is gone), and every reach
  converges on the pid-free `Ezagent.Runtime.Resolver` face (`call/3`) — no
  caller looks up a pid any more.

  V5 A1b-rest chunk3 (audit teardown peculiarity): `delete_board` moved from
  `handle_call(:teardown)` into `terminate/2` so it runs on ANY stop — the old
  `restart: :permanent` RESPAWNED the poller after the `:teardown` stop
  (non-durable unbind), and a plain seam `terminate_child` would have DROPPED
  the board deletion (a non-trapping GenServer dies without `terminate/2`).
  Now: `restart: :transient` (no respawn on graceful stop) + `trap_exit` (the
  supervisor's `:shutdown` reaches `terminate/2`). Dropped dead faces: the
  `:tick` poller (`interval: 0` everywhere — never fired), the public
  `board_id/1` (kept as an internal seam call), and the tests-only public
  `teardown/1` / `unbind/1` (stopping the poller IS the teardown now).
  """

  # `restart: :transient` (V5 A1b chunk3): a GRACEFUL stop — the seam
  # `terminate_child` unbind, or the registry-collision loser below — must NOT
  # be restarted (the board is already deleted / the key is owned by the
  # replacement). An ABNORMAL stop still restarts under
  # `EzagentPluginKanban.MiroSyncSupervisor` as before.
  use GenServer, restart: :transient

  require Logger

  alias EzagentPluginKanban.Miro
  alias EzagentPluginKanban.Miro.Sync
  alias Ezagent.Runtime.Resolver
  alias Ezagent.Runtime.SidecarRegistry

  # V5 pid-closure A1b — this sidecar's resolver-seam identity. The key is
  # the address, never a pid (PTY-pilot pattern).
  @plugin :ezagent_plugin_kanban
  @role :miro_sync

  @supervisor EzagentPluginKanban.MiroSyncSupervisor

  @doc false
  def start_link(opts) do
    opts = Map.new(opts)
    GenServer.start_link(__MODULE__, opts, name: via(Map.fetch!(opts, :uri)))
  end

  @doc """
  The resolver-seam key for a kanban board's MiroSync poller:
  `{kanban_uri, :ezagent_plugin_kanban, :miro_sync}`. Public so callers build
  the SAME key — the key is the address, never a pid.
  """
  @spec resolver_key(URI.t()) :: {URI.t(), atom(), atom()}
  def resolver_key(%URI{} = uri), do: {uri, @plugin, @role}

  # The `:via` tuple this poller SELF-registers under (the unified
  # `Ezagent.Runtime.SidecarRegistry`, plugin-qualified key).
  defp via(%URI{} = uri), do: SidecarRegistry.via(uri, @plugin, @role)

  @doc """
  绑定一个 kanban↔Miro 板的双向同步：在 plugin 监督树下起同步进程，按
  `{kanban_uri, :ezagent_plugin_kanban, :miro_sync}` seam key 唯一自注册。
  """
  @spec bind(URI.t(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def bind(uri, board_id, opts \\ []) do
    spec = {__MODULE__, Keyword.merge([uri: uri, board_id: board_id], opts)}
    DynamicSupervisor.start_child(@supervisor, spec)
  end

  @doc """
  立刻跑一轮双向同步（kanban URI，经 resolver seam）。未绑定 →
  `{:error, :not_bound}`；否则 `{:ok, %{inbound: n}}` | `{:error, _}`。
  """
  @spec sync_now(URI.t()) :: {:ok, map()} | {:error, term()}
  def sync_now(%URI{} = uri) do
    case Resolver.call(resolver_key(uri), :sync_now, 30_000) do
      {:ok, reply} -> reply
      {:error, :no_such_actor} -> {:error, :not_bound}
      {:error, reason} -> {:error, reason}
    end
  end

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
             {:ok, _} <- bind(uri, board),
             {:ok, r} <- sync_now(uri) do
          {:ok, Map.put(r, :board_id, board)}
        end
    end
  end

  # INTERNAL（V5 A1b: 不再是 public face）— 返回某 kanban 已绑定的 Miro board
  # id，未绑定 `:not_bound`。经 seam `Resolver.call`；seam 对缺失 key 返回
  # `:no_such_actor`（替代旧的 `catch :exit` not-bound 检测，行为不变）。
  defp board_id(%URI{} = uri) do
    case Resolver.call(resolver_key(uri), :board_id, 30_000) do
      {:ok, board} -> {:ok, board}
      {:error, :no_such_actor} -> :not_bound
      {:error, _} -> :not_bound
    end
  end

  @impl true
  def init(opts) do
    # V5 A1b chunk3: trap_exit so the supervisor's `:shutdown` (seam
    # `terminate_child`) REACHES `terminate/2` — without it the poller would
    # die without deleting the Miro board (the audit's teardown peculiarity).
    Process.flag(:trap_exit, true)

    state = %{
      uri: Map.fetch!(opts, :uri),
      board_id: Map.fetch!(opts, :board_id),
      mapping: %{},
      # V5 A1b codex #5 — the `SidecarRegistry.watch/0` monitor ref. The
      # registry lives in ANOTHER app's supervision tree; if it restarts,
      # this poller's :via entry dies with it, and the poller re-registers
      # ITSELF on the :DOWN (see the :DOWN clause + `reregister_with_registry/1`).
      registry_ref: SidecarRegistry.watch(),
      # Test seams (network-free teardown tests): default to the real Miro
      # client; a test injects fakes to observe the board deletion.
      read_creds: Map.get(opts, :read_creds, &Miro.read_creds/0),
      delete_board: Map.get(opts, :delete_board, &Miro.delete_board/2)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    {result, state} = sync(state)
    {:reply, result, state}
  end

  def handle_call(:board_id, _from, state), do: {:reply, state.board_id, state}

  # ─── registry watch: SidecarRegistry restart → self re-register ───────────

  # V5 A1b codex #5 — the unified SidecarRegistry restarted (it lives in
  # ANOTHER app's supervision tree); our :via entry died with it. Re-register
  # THIS process and re-arm the watch so the poller stays resolvable through
  # the seam. Matched BEFORE any generic stale-:DOWN clause (chunk1 gotcha).
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{registry_ref: ref} = state)
      when is_reference(ref) do
    Logger.warning(
      "kanban MiroSync: SidecarRegistry DOWN (#{inspect(reason)}) — re-registering " <>
        URI.to_string(state.uri)
    )

    reregister_with_registry(state)
  end

  def handle_info(:retry_registry_registration, %{registry_ref: nil} = state),
    do: reregister_with_registry(state)

  def handle_info(:retry_registry_registration, state), do: {:noreply, state}

  # V5 A1b codex blocker B (collision policy) — `{:error, :already_registered}`
  # means a REPLACEMENT poller won the key during the registry's empty-restart
  # window. This original is now unreachable through the seam, and two live
  # pollers for one kanban must never coexist: LOSE GRACEFULLY — stop;
  # `restart: :transient` keeps the supervisor from resurrecting the loser.
  defp reregister_with_registry(state) do
    case SidecarRegistry.re_register(resolver_key(state.uri)) do
      :ok ->
        {:noreply, %{state | registry_ref: SidecarRegistry.watch()}}

      {:error, :already_registered} ->
        Logger.warning(
          "kanban MiroSync: SidecarRegistry key for #{URI.to_string(state.uri)} " <>
            "is owned by a replacement that won the restart race — this losing " <>
            "original is terminating gracefully"
        )

        {:stop, {:shutdown, :registry_collision}, state}

      {:error, why} ->
        Logger.error(
          "kanban MiroSync: SidecarRegistry re-register failed for " <>
            "#{URI.to_string(state.uri)} (#{inspect(why)}) — retrying"
        )

        Process.send_after(self(), :retry_registry_registration, 200)
        {:noreply, %{state | registry_ref: nil}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # V5 A1b chunk3 (audit teardown peculiarity): `delete_board` lives HERE —
    # moved from the dropped `handle_call(:teardown)` — so it runs on ANY stop
    # (graceful `terminate_child` unbind, registry-collision loss, shutdown),
    # and `restart: :transient` keeps the supervisor from respawning the
    # poller afterwards (the old `:permanent` made every unbind non-durable).
    # 真相源=ezagent：Miro 板只是镜像，删除后下次 `sync_or_bind` 重建自愈。
    case state.read_creds.() do
      {:ok, %{token: t}} -> _ = state.delete_board.(t, state.board_id)
      _ -> :ok
    end

    :ok
  end

  # --- 同步核心 ---------------------------------------------------------

  defp sync(state) do
    with {:ok, token} <- token(state),
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

  defp token(state) do
    case state.read_creds.() do
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
