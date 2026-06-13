defmodule EzagentPluginCurlAgent.BridgeAdapter do
  @moduledoc """
  Curl flavor AgentBridge adapter — the `:in_process_sync` TRANSPORT.

  ## Why this exists (im/session/agent decomposition — PR-6, codex HIGH-1)

  curl is STATEFUL; the adapter is NOT. SPEC
  `docs/superpowers/specs/2026-06-12-im-session-agent-decomposition-design.md`
  §3.5 / §OQ-1 splits the old `Ezagent.Behavior.CurlAgent` into:

    * the **STATE** half — REPARENTED onto `Ezagent.Entity.Agent` for the
      `curl` flavor: the `:curl_agent` slice + `reset_conversation` /
      `configure` + the durable `{:set, :conversation/:last_error/
      :last_tokens}` effects + the `session.send` reply. Stays a Behavior.

    * the **TRANSPORT** half — THIS adapter. It does ONLY the in-process
      HTTP round-trip (the old `run_completion/6` + `ApiClient`) and
      RETURNS the result. It PERSISTS NOTHING and emits NO effects.

  ## Transport class — `:in_process_sync`

  There is NO subprocess and NO WebSocket. `Ezagent.AgentBridge.deliver`
  routes the `:in_process_sync` class straight here (skipping the Channel,
  the Registry lookup, and the `ensure_ready` readiness gate — §3.3) and
  hands `nil` for the channel ref. `deliver/2` performs the HTTP call
  SYNCHRONOUSLY and returns `{:ok, result}` / `{:error, reason}` — the
  result the curl **Behavior** persists via `{:set, …}` effects (NOT this
  adapter; the adapter is stateless).

  ## How the request is assembled WITHOUT a self-call deadlock

  The adapter runs INSIDE the agent Kind's dispatch process (reached via
  `agent.receive` → `AgentBridge.deliver` synchronously). Reading the
  agent's OWN live slice via `Ezagent.Kind.get_slice/2` here would be a
  `GenServer.call(self)` deadlock — the SAME constraint
  `Ezagent.AgentBridge.default_heal/1` faces. So the adapter reads the
  agent's PERSISTED `:curl_agent` + `:api_keys` slices from the SNAPSHOT
  STORE (a DB read, not a Kind call). Because the curl Kind persists
  `{:snapshot, :on_change}`, the latest snapshot reflects committed state.
  The incoming user text + the agent URI travel in the `payload`.

  The adapter reads state ONLY to MAKE the call. It never WRITES — the
  durable mutation (append the user + assistant turns, set tokens / error)
  is the curl Behavior's job, applied via `{:set, …}` when `agent.receive`
  re-dispatches the adapter's result to it (`Behavior.CurlAgent`'s
  `:sync_result` action).

  ## Return shape

  `deliver/2 :: {:ok, %{content: String.t(), usage: map()}} | {:error,
  term()}`. The Behavior owns conversation state — it appends BOTH the user
  turn (which it already has from the inbound message) and the assistant
  turn in one commit; the adapter only relays the round-trip. A `{:error,
  _}` carries the upstream failure verbatim (`{:no_api_key, provider}` /
  `{:http, …}` / `{:transport, …}` / `{:decode, …}`) so the Behavior maps
  it to the same chat-visible reply the pre-fold curl agent produced.
  """

  @behaviour Ezagent.AgentBridge.Adapter

  require Logger

  alias Ezagent.AgentBridge.Payload
  alias Ezagent.PluginCurlAgent.ApiClient

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "curl"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :in_process_sync

  @impl Ezagent.AgentBridge.Adapter
  def deliver(%Payload{} = payload, nil) do
    with {:ok, agent_uri} <- agent_uri_from_payload(payload),
         {:ok, curl_slice} <- snapshot_slice(agent_uri, :curl_agent),
         {:ok, api_keys_slice} <- snapshot_slice(agent_uri, :api_keys) do
      do_round_trip(payload, curl_slice, api_keys_slice)
    end
  end

  # ── request assembly + HTTP round-trip (the old run_completion/6) ──────

  defp do_round_trip(%Payload{} = payload, curl_slice, api_keys_slice) do
    provider = Map.get(curl_slice, :provider, "deepseek")
    api_url = Map.get(curl_slice, :api_url, "https://api.deepseek.com/chat/completions")
    model = Map.get(curl_slice, :model, "deepseek-chat")
    system_prompt = Map.get(curl_slice, :system_prompt)
    max_history = Map.get(curl_slice, :max_history, 20)
    conversation = Map.get(curl_slice, :conversation, [])

    user_text = payload.text || ""

    # Build the request conversation = stored history + this user turn,
    # trimmed to max_history (the same window the Behavior persists). This
    # is a READ-ONLY assembly — the durable append happens in the Behavior.
    request_conv =
      conversation
      |> append_turn("user", user_text)
      |> trim(max_history)

    case fetch_api_key(api_keys_slice, provider) do
      {:ok, api_key} ->
        messages = build_messages(system_prompt, request_conv)

        case ApiClient.chat_completion(%{
               api_url: api_url,
               api_key: api_key,
               model: model,
               messages: messages
             }) do
          {:ok, %{content: content, usage: usage}} ->
            {:ok, %{content: content, usage: usage}}

          {:error, reason} ->
            Logger.warning(
              "EzagentPluginCurlAgent.BridgeAdapter: provider=#{provider} model=#{model} " <>
                "completion error: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, {:no_api_key, _} = reason} ->
        {:error, reason}
    end
  end

  # The adapter only reads the OWN api key, exactly as the pre-fold
  # `Behavior.CurlAgent.fetch_self_api_key/2` did — but from the snapshot
  # slice (deadlock-safe) instead of `ctx.siblings`.
  defp fetch_api_key(api_keys_slice, provider) when is_binary(provider) do
    keys = Map.get(api_keys_slice, :keys, %{})

    case Map.fetch(keys, provider) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:no_api_key, provider}}
    end
  end

  defp append_turn(conv, role, content), do: conv ++ [%{role: role, content: content}]

  defp trim(conv, max_history) when length(conv) <= max_history, do: conv
  defp trim(conv, max_history), do: Enum.take(conv, -max_history)

  defp build_messages(nil, conversation), do: conversation

  defp build_messages(system_prompt, conversation) when is_binary(system_prompt) do
    [%{role: "system", content: system_prompt} | conversation]
  end

  # ── snapshot reads (deadlock-safe; never a Kind.get_slice self-call) ───

  defp agent_uri_from_payload(%Payload{meta: meta}) when is_map(meta) do
    case Map.get(meta, "agent_uri") do
      uri_str when is_binary(uri_str) and uri_str != "" ->
        {:ok, Ezagent.URI.new!(uri_str)}

      _ ->
        {:error, :no_agent_uri_in_payload}
    end
  rescue
    ArgumentError -> {:error, :malformed_agent_uri}
  end

  defp agent_uri_from_payload(_), do: {:error, :no_agent_uri_in_payload}

  defp snapshot_slice(%URI{} = agent_uri, slice_key) when is_atom(slice_key) do
    case Ezagent.SnapshotStore.latest(agent_uri) do
      {:ok, %{state: state}} when is_map(state) ->
        case Map.get(state, slice_key) do
          slice when is_map(slice) -> {:ok, Ezagent.Kind.normalize_slice_view(slice)}
          _ -> {:ok, %{}}
        end

      {:error, :not_found} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:snapshot_unavailable, reason}}
    end
  end
end
