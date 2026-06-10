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
  2. Spawn `node priv/ws_sidecar/main.js` via Port with FEISHU_APP_ID
     + FEISHU_APP_SECRET in the env
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

  @restart_backoff_ms 5_000

  defstruct [
    :port,
    :buffer,
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
    state = %__MODULE__{
      buffer: "",
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
        port =
          Port.open(
            {:spawn_executable, state.node_bin},
            [
              :binary,
              :exit_status,
              {:args, [state.sidecar_path]},
              {:env, env_for_sidecar(app_id, app_secret, domain)},
              {:line, 65_536}
            ]
          )

        Logger.info("EzagentPluginFeishu.WsClient: sidecar started (port=#{inspect(port)})")
        {:noreply, %{state | port: port, app_id: app_id, app_secret: app_secret, domain: domain}}

      {:error, reason} ->
        Logger.warning(
          "EzagentPluginFeishu.WsClient: cannot start (#{inspect(reason)}); retry in #{@restart_backoff_ms}ms"
        )

        Process.send_after(self(), :open_sidecar, @restart_backoff_ms)
        {:noreply, state}
    end
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    full = state.buffer <> line
    handle_json_line(full)
    {:noreply, %{state | buffer: ""}}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "EzagentPluginFeishu.WsClient: sidecar exited status=#{status}; restart in #{@restart_backoff_ms}ms"
    )

    Process.send_after(self(), :open_sidecar, @restart_backoff_ms)
    {:noreply, %{state | port: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.enabled?,
       port_alive: state.port != nil,
       sidecar_path: state.sidecar_path,
       app_id_prefix: state.app_id && String.slice(state.app_id, 0..14)
     }, state}
  end

  # --- Internals ---------------------------------------------------------

  defp sidecar_path do
    :code.priv_dir(:ezagent_plugin_feishu)
    |> Path.join("ws_sidecar/main.js")
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
        body: body
      )
    end

    :ok
  end

  defp handle_event(_header, _other), do: :ok
end
