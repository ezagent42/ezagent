defmodule EzagentPluginFeishu.WsClient do
  @moduledoc """
  Phase 6 PR 15 — Feishu long-connect (WSS) client via a Node.js
  sidecar (`priv/ws_sidecar/main.js`).

  ## Why a sidecar

  The lark long-connect WSS protocol (handshake / heartbeat / event
  framing / dedup) is encapsulated in `@larksuiteoapi/node-sdk` and
  not publicly documented. The sidecar reuses the SDK; the Elixir
  side just reads JSON lines off stdout.

  ## Flow

  1. Read credentials from `system://credentials/feishu.yaml` via
     `Ezagent.System.FsResolver.read_yaml/1`
  2. Spawn `node priv/ws_sidecar/main.js` via `Ezagent.Runtime.OsProcess`
     (erlexec: {group,0}+:kill_group → no orphan node subtree) with
     FEISHU_APP_ID + FEISHU_APP_SECRET in the env
  3. Read newline-delimited JSON events from stdout
  4. For each event: hand off to `EzagentPluginFeishu.InboundDispatcher`
     using the SAME shape as the HTTP webhook (`build_message_body`
     in `WebhookPlug`, called via the public test helper)
  5. On sidecar exit: log + auto-restart (5s backoff)

  ## Disabling

  Set `EZAGENT_FEISHU_WS=0` to skip the WsClient. The plugin still boots
  with HTTP-only webhook support. Useful when the operator's deployment
  has a webhook reverse-proxy already set up.
  """

  use GenServer
  require Logger

  alias EzagentPluginFeishu.InboundDispatcher
  alias Ezagent.Runtime.LineBuffer
  alias Ezagent.Runtime.OsProcess

  @restart_backoff_ms 5_000
  @line_buffer_max 1_048_576
  @sidecar_plugin "feishu-ws"

  # SPEC §3.4: reap prior-incarnation feishu-ws orphans at boot. Skipped in
  # `:test` by default (the test BEAM has an empty registry, so every orphan
  # from a prior run looks reapable). Mirrors cc's `@default_reap_enabled?`
  # gate; operators can flip it in dedicated e2e via
  # `config :ezagent_plugin_feishu, reap_orphans_on_boot: true`.
  @compile_env Mix.env()
  @default_reap_enabled? @compile_env != :test

  defstruct [
    :exec_pid,
    :os_pid,
    :line_buffer,
    :app_id,
    :app_secret,
    :domain,
    :sidecar_path,
    :node_bin,
    enabled?: true
  ]

  # --- public API --------------------------------------------------------

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Status report for operator/debug."
  def status, do: GenServer.call(__MODULE__, :status)

  # --- callbacks ---------------------------------------------------------

  @impl true
  def init(_) do
    # SPEC §3.1 caller contract: trap_exit BEFORE any spawn so a supervisor
    # `:shutdown` runs terminate/2 (→ OsProcess.stop + cleanup) instead of
    # orphaning the node sidecar.
    Process.flag(:trap_exit, true)

    # SPEC §3.4: reap a prior-incarnation feishu-ws orphan HERE (in the owner,
    # before the deferred `:open_sidecar` spawn) rather than in the plugin's
    # `after_boot/0`. WsClient is a supervision-tree child that spawns the node
    # sidecar ASYNCHRONOUSLY, so an `after_boot` reap would race the fresh spawn
    # and could group-kill the just-started sidecar. Running it before the first
    # spawn is ordering-safe; `URI.SchemeRegistry` (needed to parse the
    # `system://feishu/ws` pid-file key) is already seeded because `ezagent_core`
    # boots before this plugin.
    _ = maybe_reap_feishu_orphans()

    state = %__MODULE__{
      line_buffer: LineBuffer.new(@line_buffer_max),
      sidecar_path: sidecar_path(),
      node_bin: System.find_executable("node"),
      enabled?: System.get_env("EZAGENT_FEISHU_WS") != "0"
    }

    cond do
      not state.enabled? ->
        Logger.info("EzagentPluginFeishu.WsClient: EZAGENT_FEISHU_WS=0 — staying idle")
        {:ok, state}

      is_nil(state.node_bin) ->
        Logger.warning("EzagentPluginFeishu.WsClient: node not found in PATH — WS disabled")
        {:ok, %{state | enabled?: false}}

      not File.exists?(state.sidecar_path) ->
        Logger.warning("EzagentPluginFeishu.WsClient: sidecar missing at #{state.sidecar_path}")
        {:ok, %{state | enabled?: false}}

      true ->
        send(self(), :open_sidecar)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:open_sidecar, state) do
    case load_credentials() do
      {:ok, app_id, app_secret, domain} ->
        case OsProcess.spawn([state.node_bin, state.sidecar_path],
               cd: File.cwd!(),
               env: env_for_sidecar(app_id, app_secret, domain),
               stderr: :separate,
               pid_file: {@sidecar_plugin, pidfile_key()}
             ) do
          {:ok, %{exec_pid: exec_pid, os_pid: os_pid}} ->
            Logger.info("EzagentPluginFeishu.WsClient: sidecar started (os_pid=#{os_pid})")

            {:noreply,
             %{
               state
               | exec_pid: exec_pid,
                 os_pid: os_pid,
                 line_buffer: LineBuffer.new(@line_buffer_max),
                 app_id: app_id,
                 app_secret: app_secret,
                 domain: domain
             }}

          {:error, reason} ->
            Logger.warning(
              "EzagentPluginFeishu.WsClient: spawn failed (#{inspect(reason)}); retry in #{@restart_backoff_ms}ms"
            )

            Process.send_after(self(), :open_sidecar, @restart_backoff_ms)
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning(
          "EzagentPluginFeishu.WsClient: cannot start (#{inspect(reason)}); retry in #{@restart_backoff_ms}ms"
        )

        Process.send_after(self(), :open_sidecar, @restart_backoff_ms)
        {:noreply, state}
    end
  end

  # erlexec delivers arbitrary stdout chunks (not native Port `{:line, N}`
  # frames); LineBuffer reassembles complete newline-delimited JSON lines.
  def handle_info({:stdout, os_pid, bytes}, %{os_pid: os_pid} = state) do
    {new_lb, lines} = LineBuffer.feed(state.line_buffer, bytes)
    Enum.each(lines, &handle_json_line/1)
    {:noreply, %{state | line_buffer: new_lb}}
  end

  # stderr is a SEPARATE stream (never merged into the JSON stdout channel) —
  # log and drop.
  def handle_info({:stderr, os_pid, bytes}, %{os_pid: os_pid} = state) do
    Logger.debug("EzagentPluginFeishu.WsClient sidecar stderr: #{String.trim(to_string(bytes))}")
    {:noreply, state}
  end

  # Child exit via the run_link BEAM link (no `:monitor`). Reason taxonomy:
  # `:normal` (clean) | `{:exit_status, n}` | `:port_closed`. Clean up the pid
  # file and auto-restart with backoff (preserved from the Port era).
  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    Logger.warning(
      "EzagentPluginFeishu.WsClient: sidecar exited (#{inspect(reason)}); restart in #{@restart_backoff_ms}ms"
    )

    OsProcess.cleanup_pid_file(@sidecar_plugin, pidfile_key())
    Process.send_after(self(), :open_sidecar, @restart_backoff_ms)
    {:noreply, %{state | exec_pid: nil, os_pid: nil}}
  end

  # Defensive: an EXIT from any other linked process (the parent supervisor's
  # exit is handled by gen_server itself, not delivered here).
  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.enabled?,
       port_alive: state.os_pid != nil,
       sidecar_path: state.sidecar_path,
       app_id_prefix: state.app_id && String.slice(state.app_id, 0..14)
     }, state}
  end

  @impl true
  def terminate(_reason, %__MODULE__{exec_pid: exec_pid}) when not is_nil(exec_pid) do
    OsProcess.stop(exec_pid)
    OsProcess.cleanup_pid_file(@sidecar_plugin, pidfile_key())
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Internals ---------------------------------------------------------

  # The pid-file key for the feishu node sidecar. A `system://feishu/ws` URI
  # (node-global singleton — there is no per-agent/per-tenant feishu ws sidecar).
  # Carried in the pid-file body (line 3) since it cannot be reversed from the
  # sanitised filename (SPEC §3.4 invariant).
  defp pidfile_key, do: Ezagent.URI.system("feishu", "ws")

  defp maybe_reap_feishu_orphans do
    if Application.get_env(:ezagent_plugin_feishu, :reap_orphans_on_boot, @default_reap_enabled?) do
      Ezagent.Runtime.OrphanReaper.reap(@sidecar_plugin)
    end
  end

  defp sidecar_path do
    # Test-only override seam (prod: env unset → the vendored priv main.js).
    Application.get_env(:ezagent_plugin_feishu, :ws_sidecar_path) ||
      :code.priv_dir(:ezagent_plugin_feishu) |> Path.join("ws_sidecar/main.js")
  end

  defp env_for_sidecar(app_id, app_secret, domain) do
    extras = [
      {~c"FEISHU_APP_ID", String.to_charlist(app_id)},
      {~c"FEISHU_APP_SECRET", String.to_charlist(app_secret)},
      {~c"FEISHU_DOMAIN", String.to_charlist(domain || "https://open.feishu.cn")}
    ]

    extras
  end

  defp load_credentials do
    # Resource-unification P3 (SPEC §10 OI-3): the global feishu app credential is
    # a node-global system artifact → `system://credentials/feishu.yaml`. BOTH the
    # operational read and the operator-facing error path flow through the
    # `system://` seam — no raw `Ezagent.Home` dependency remains in this caller.
    cred_uri = Ezagent.URI.system("credentials", "feishu.yaml")
    cred_path = Ezagent.System.FsResolver.path!(cred_uri)

    case Ezagent.System.FsResolver.read_yaml(cred_uri) do
      {:ok, %{"app_id" => app_id, "app_secret" => app_secret} = creds}
      when is_binary(app_id) and is_binary(app_secret) ->
        if String.contains?(app_id, "REPLACE_ME") or String.contains?(app_secret, "REPLACE_ME") do
          {:error, :credentials_unfilled}
        else
          {:ok, app_id, app_secret, Map.get(creds, "domain")}
        end

      {:error, :not_found} ->
        {:error, :credentials_not_found}

      err ->
        Logger.warning("WsClient load_credentials: #{cred_path} → #{inspect(err)}")
        {:error, err}
    end
  end

  defp handle_json_line(""), do: :ok

  defp handle_json_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "event", "event" => event} = env} ->
        handle_event(env["header"] || %{}, event)

      {:ok, %{"type" => "connected"}} ->
        Logger.info("EzagentPluginFeishu.WsClient: WSS connected")

      {:ok, %{"type" => "disconnected"} = m} ->
        Logger.info("EzagentPluginFeishu.WsClient: WSS disconnected: #{inspect(m["reason"])}")

      {:ok, %{"type" => "error", "message" => msg}} ->
        Logger.warning("EzagentPluginFeishu.WsClient sidecar error: #{msg}")

      {:ok, _other} ->
        :ok

      {:error, _} ->
        Logger.debug("EzagentPluginFeishu.WsClient: non-JSON line from sidecar: #{inspect(line)}")
    end
  end

  defp handle_event(_header, %{"message" => msg, "sender" => sender}) do
    chat_id = Map.get(msg, "chat_id")
    message_id = Map.get(msg, "message_id")

    if chat_id do
      body = EzagentPluginFeishu.EventDecoder.build_body(msg)

      InboundDispatcher.dispatch(
        chat_id: chat_id,
        message_id: message_id,
        sender: sender,
        body: body,
        origin: :authenticated_external
      )
    end

    :ok
  end

  defp handle_event(_header, _other), do: :ok
end
