defmodule Ezagent.Behavior.CurlAgent do
  @moduledoc """
  CurlAgent Behavior — receives chat messages, accumulates a
  conversation, calls a remote LLM completion API per :receive, and
  dispatches the reply back into the originating session.

  ## Phase B migration (2026-05-29) — Lifecycle API

  Migrated from `use Ezagent.Behavior` to `use Ezagent.Lifecycle`
  per SPEC `2026-05-29-lifecycle-hooks-design.md` §2.3 (representative
  example A — the simple, no-transients case). The CQRS engine
  (slice / invocation / snapshot) is hidden behind two state
  containers + lifecycle moments:

  - `create/1` builds the PERSISTENT `state` (was `init_slice/1`).
  - There are NO transients (no PID / ETS / port / subprocess /
    monitor), so `activate/2` is the macro-injected no-op default —
    omitted here.
  - `handle_<action>/2` is byte-identical except `ctx[:read]` →
    `ctx.read` and the sibling read `ctx[:sibling_slices]` →
    `ctx.siblings` (with `reads_sibling_slices/0` → `reads_siblings/0`).

  The `:receive` handler builds the chat reply via a
  `{:dispatch, %Cmd{}}` effect; `:reset_conversation` and `:configure`
  mutate the persistent `state` via `{:set, _, _}` effects.

  `required_caps/0` is still manually exported to preserve the
  kind axis `:curl_agent` (the macro auto-derives uses `:any`).

  The auto-derived `state_slice/0` (last module segment `CurlAgent`
  → `:curl_agent`) equals the historical snapshot key, so NO
  `state_slice:` override is needed (SPEC §5 step 2 / §7 OQ-7).

  Registered for `(Ezagent.Entity.CurlAgent, :receive)` in
  `EzagentPluginCurlAgent.Application`. The chat router targets
  `entity://agent/team-alpha/curl_<name>?action=chat.receive`; the dispatcher
  pattern-matches behavior_module to land here.

  ## Persistent state (auto-derived state_slice :curl_agent)

  All fields are PERSISTENT (no transients). See
  `Ezagent.Entity.CurlAgent` moduledoc for the schema. This
  behavior:
  - reads `provider / api_url / model / system_prompt / max_history`
    for the outbound call (set at instantiate via the Template Class)
  - appends to `conversation`
  - records `last_error / last_tokens`

  ## Per-receive flow

  1. Append `{role: "user", content: msg.body.text}` to conversation
  2. Trim conversation to last `max_history` entries (paired user/assistant)
  3. Build messages = [system?, ...conversation]
  4. Read this agent's OWN api key from the `:api_keys` sibling slice
     (post ApiKeys-to-Agent flip)
  5. POST `api_url` with `{model, messages}` → assistant reply
  6. Append `{role: "assistant", content: reply}` to conversation
  7. Dispatch `chat.send` back into the originating session with the
     reply text

  ## Failure modes

  - **No key for provider** → set `last_error: {:no_api_key, provider}`,
    dispatch a chat reply telling the operator to configure the key
  - **HTTP non-2xx** → set `last_error`, dispatch a chat reply with
    the error code, don't append a fake assistant turn
  - **Transport / decode** → same as HTTP non-2xx

  ## Caller cap reuse

  The reply dispatch runs under `Ezagent.SystemPrincipal`
  (`system://chat-reply`) per SPEC caps-cleanup-v1 §4.4.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.PluginCurlAgent.ApiClient

  action(:receive,
    args: %{message: :map},
    returns: %{ok: :boolean, tokens: :integer, error: :atom},
    caps: [:receive],
    modes: [:cast],
    description:
      "receive a session message and call the configured curl endpoint (LLM API mirror)"
  )

  action(:reset_conversation,
    args: %{},
    returns: %{ok: :boolean},
    caps: [:reset_conversation],
    modes: [:call],
    description: "clear the curl agent's conversation history"
  )

  action(:configure,
    args: %{
      provider: :string,
      api_url: :string,
      model: :string,
      system_prompt: :string,
      max_history: :integer
    },
    returns: %{ok: :boolean},
    caps: [:configure],
    modes: [:call],
    description: "set or update the curl agent's endpoint config (URL, headers, prompt)"
  )

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # CurlAgent is registered on Entity.CurlAgent Kind (type_name
  # :curl_agent) — kind axis is `:curl_agent`. Manually exported to
  # override the macro's `:any` default.
  def required_caps do
    %{
      receive: Ezagent.Capability.cap(:curl_agent, __MODULE__, :receive),
      reset_conversation: Ezagent.Capability.cap(:curl_agent, __MODULE__, :reset_conversation),
      configure: Ezagent.Capability.cap(:curl_agent, __MODULE__, :configure)
    }
  end

  # Allen 2026-05-26 — declare the sibling state this Behavior reads
  # in-process. `:api_keys` lives on the SAME Agent Kind; reading it
  # via dispatch back to `ctx.self_uri` would be a `GenServer.call(self)`
  # deadlock. The Runtime injects the declared sibling into
  # `ctx.siblings[:api_keys]` as a read-only O(1) lookup. Renamed from
  # `reads_sibling_slices/0` per SPEC §2.2 (same opt-in semantics).
  reads_siblings([:api_keys])

  # `init_slice/1` → `create/1` (SPEC §3 mapping). Build the initial
  # PERSISTENT `state` once, on first-ever existence. No transients
  # here (all fields survive restart), so `activate/2` is the
  # macro-injected no-op default.
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       provider: Map.get(args, :provider, "deepseek"),
       api_url: Map.get(args, :api_url, "https://api.deepseek.com/chat/completions"),
       model: Map.get(args, :model, "deepseek-chat"),
       system_prompt: Map.get(args, :system_prompt),
       max_history: Map.get(args, :max_history, 20),
       conversation: [],
       last_error: nil,
       last_tokens: nil
     }}
  end

  # ---------------------------------------------------------------
  # handle_<action>/2 (new contract)
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    # Loop prevention: ignore messages we sent ourselves.
    self_uri = Map.get(ctx, :self_uri)
    self_uri_str = if is_struct(self_uri, URI), do: URI.to_string(self_uri), else: ""
    sender_str = sender_string(msg.sender)

    if sender_str == self_uri_str do
      {:ok, %{ok: true, ignored: :self_message}, []}
    else
      do_receive_effects(msg, ctx)
    end
  end

  def handle_reset_conversation(_args, _ctx) do
    {:ok, %{ok: true},
     [
       {:set, :conversation, []},
       {:set, :last_error, nil}
     ]}
  end

  def handle_configure(args, ctx) when is_map(args) do
    provider = ctx.read.(:provider, "deepseek")
    api_url = ctx.read.(:api_url, "https://api.deepseek.com/chat/completions")
    model = ctx.read.(:model, "deepseek-chat")
    system_prompt = ctx.read.(:system_prompt, nil)
    max_history = ctx.read.(:max_history, 20)

    {:ok, %{ok: true},
     [
       {:set, :provider, Map.get(args, :provider, provider)},
       {:set, :api_url, Map.get(args, :api_url, api_url)},
       {:set, :model, Map.get(args, :model, model)},
       {:set, :system_prompt, Map.get(args, :system_prompt, system_prompt)},
       {:set, :max_history, Map.get(args, :max_history, max_history)}
     ]}
  end

  # --- internals --------------------------------------------------------

  defp do_receive_effects(%Message{} = msg, ctx) do
    user_text = msg.body[:text] || msg.body["text"] || ""
    source_session_uri = ctx[:caller]
    self_uri = Map.get(ctx, :self_uri)

    provider = ctx.read.(:provider, "deepseek")
    api_url = ctx.read.(:api_url, "https://api.deepseek.com/chat/completions")
    model = ctx.read.(:model, "deepseek-chat")
    system_prompt = ctx.read.(:system_prompt, nil)
    max_history = ctx.read.(:max_history, 20)
    current_conv = ctx.read.(:conversation, [])

    appended_conv = append_turn(current_conv, "user", user_text)
    trimmed_conv = trim(appended_conv, max_history)

    case run_completion(provider, api_url, model, system_prompt, trimmed_conv, ctx) do
      {:ok, %{content: reply, usage: usage}} ->
        final_conv = append_turn(trimmed_conv, "assistant", reply)

        effects =
          [
            {:set, :conversation, final_conv},
            {:set, :last_error, nil},
            {:set, :last_tokens, usage}
          ] ++ maybe_reply_effect(source_session_uri, self_uri, reply)

        {:ok, %{ok: true, tokens: usage.total}, effects}

      {:error, {:no_api_key, provider}} ->
        reply_text =
          "no API key for provider `#{provider}` — please add one at " <>
            "/identities/agents/#{maybe_encode_uri(self_uri)}/api-keys"

        effects =
          [
            {:set, :conversation, trimmed_conv},
            {:set, :last_error, {:no_api_key, provider}}
          ] ++ maybe_reply_effect(source_session_uri, self_uri, reply_text)

        {:ok, %{ok: false, error: :no_api_key}, effects}

      {:error, reason} ->
        if is_struct(self_uri, URI) do
          Logger.warning(
            "CurlAgent #{URI.to_string(self_uri)} provider=#{provider} model=#{model} " <>
              "completion error: #{inspect(reason)}"
          )
        end

        reply_text = "upstream API error: #{format_error(reason)}"

        effects =
          [
            {:set, :conversation, trimmed_conv},
            {:set, :last_error, reason}
          ] ++ maybe_reply_effect(source_session_uri, self_uri, reply_text)

        {:ok, %{ok: false, error: error_kind(reason)}, effects}
    end
  end

  defp append_turn(conv, role, content), do: conv ++ [%{role: role, content: content}]

  defp trim(conv, max_history) when length(conv) <= max_history, do: conv
  defp trim(conv, max_history), do: Enum.take(conv, -max_history)

  defp run_completion(provider, api_url, model, system_prompt, conversation, ctx) do
    with {:ok, api_key} <- fetch_self_api_key(ctx, provider) do
      messages = build_messages(system_prompt, conversation)

      ApiClient.chat_completion(%{
        api_url: api_url,
        api_key: api_key,
        model: model,
        messages: messages
      })
    end
  end

  # Allen 2026-05-26 — fetch the agent's OWN api_key from its `:api_keys`
  # sibling state (post ApiKeys-to-Agent flip). Reads via the Lifecycle
  # `ctx.siblings` surface (SPEC §2.2 — renamed from `ctx.sibling_slices`).
  defp fetch_self_api_key(ctx, provider) when is_binary(provider) do
    api_keys_sibling = ctx |> Map.get(:siblings, %{}) |> Map.get(:api_keys, %{})
    keys = Map.get(api_keys_sibling, :keys, %{})

    case Map.fetch(keys, provider) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, {:no_api_key, provider}}
    end
  end

  defp build_messages(nil, conversation), do: conversation

  defp build_messages(system_prompt, conversation) when is_binary(system_prompt) do
    [%{role: "system", content: system_prompt} | conversation]
  end

  # Build a single `{:dispatch, %Cmd{}}` effect when source session +
  # self URI are both well-formed; otherwise emit nothing.
  defp maybe_reply_effect(nil, _self_uri, _text), do: []
  defp maybe_reply_effect("", _self_uri, _text), do: []
  defp maybe_reply_effect(_, nil, _text), do: []

  defp maybe_reply_effect(session_uri, %URI{} = self_uri, text) do
    case parse_session_uri(session_uri) do
      nil ->
        []

      %URI{} = session ->
        reply_msg = Message.new(self_uri, %{text: text, attachments: []})
        target = Ezagent.URI.with_action(session, :chat, :send)

        cmd =
          Cmd.new(target, :send, %{message: reply_msg}, %{
            caller: self_uri,
            # SPEC caps-cleanup-v1 §4.4 — agent reply path uses
            # `system://chat-reply` per Catalog.
            caps: "chat-reply" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps(),
            reply: :ignore
          })

        [{:dispatch, cmd}]
    end
  end

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
    # SPEC 2026-05-27-uri-canonicalization §3.3 — canonical chokepoint
    # with try/rescue keeping the nil fallback for malformed input.
    try do
      case Ezagent.URI.new!(s) do
        %URI{scheme: "session"} = u -> u
        _ -> nil
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp parse_session_uri(_), do: nil

  defp sender_string(%URI{} = u), do: URI.to_string(u)
  defp sender_string(s) when is_binary(s), do: s
  defp sender_string(_), do: ""

  defp maybe_encode_uri(%URI{} = u), do: URI.encode_www_form(URI.to_string(u))
  defp maybe_encode_uri(_), do: "unknown"

  defp error_kind({:http, _, _}), do: :http_error
  defp error_kind({:transport, _}), do: :transport_error
  defp error_kind({:decode, _}), do: :decode_error
  defp error_kind(_), do: :other

  defp format_error({:http, status, _body}), do: "HTTP #{status}"
  defp format_error({:transport, reason}), do: "transport: #{inspect(reason)}"
  defp format_error({:decode, _}), do: "could not decode response"
  defp format_error(other), do: inspect(other)

  # Allen 2026-05-26 — `:owner_uri` on the curl_agent slice is gone
  # (post ApiKeys-to-Agent flip). CurlAgent caps now follow the
  # standard agent-creator model: the data owner is the entity URI
  # recorded in the `:api_keys` slice's `:creator_uri`.
  def data_owner(%URI{scheme: "entity"} = agent_uri) do
    if Ezagent.URI.type?(agent_uri, :agent) do
      case Ezagent.Kind.get_slice(agent_uri, :api_keys) do
        {:ok, %{creator_uri: %URI{} = creator}} -> creator
        _ -> :no_owner
      end
    else
      :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
