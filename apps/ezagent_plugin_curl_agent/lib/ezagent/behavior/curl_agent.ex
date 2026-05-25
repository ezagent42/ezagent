defmodule Ezagent.Behavior.CurlAgent do
  @moduledoc """
  CurlAgent Behavior — receives chat messages, accumulates a
  conversation, calls a remote LLM completion API per :receive, and
  dispatches the reply back into the originating session.

  Registered for `(Ezagent.Entity.CurlAgent, :receive)` in
  `EzagentPluginCurlAgent.Application`. The chat router targets
  `entity://agent/team-alpha/curl_<name>?action=chat.receive`; the dispatcher pattern-
  matches behavior_module to land here.

  ## Slice (state_slice :curl_agent)

  See `Ezagent.Entity.CurlAgent` moduledoc for the schema. This
  behavior:
  - reads `provider / api_url / model / system_prompt / max_history / owner_uri`
    for the outbound call (set at instantiate via the Template Class)
  - appends to `conversation`
  - records `last_error / last_tokens`

  ## Per-receive flow

  1. Append `{role: "user", content: msg.body.text}` to conversation
  2. Trim conversation to last `max_history` entries (paired user/assistant)
  3. Build messages = [system?, ...conversation]
  4. Dispatch `identity/get_api_key` against `owner_uri` with `provider`
     → fetch the user's key
  5. POST `api_url` with `{model, messages}` → assistant reply
  6. Append `{role: "assistant", content: reply}` to conversation
  7. Dispatch `chat/send` back into the originating session with the
     reply text (so other members see it)

  ## Failure modes

  - **No key for provider** → set `last_error: {:no_api_key, provider}`,
    dispatch a chat/send back saying "@owner please configure your
    `<provider>` API key at /admin/users/<uri>/api-keys" so the
    operator notices.
  - **HTTP non-2xx** → set `last_error`, dispatch a chat/send with
    the error code (rate limit / bad model / etc.), don't append a
    fake assistant turn.
  - **Transport / decode** → same as HTTP non-2xx.

  ## Caller cap reuse

  The reply dispatch runs under `Ezagent.SystemPrincipal` (`system://chat-reply`)
  (matches the Chat `:reply_received` pattern pre-PR #118). v1
  scope: trust system-routed replies. Phase 7+ may give CurlAgent
  its own caps via Generator scope-bounded delegation.
  """

  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.PluginCurlAgent.ApiClient

  @impl Ezagent.Behavior
  def actions, do: [:receive, :reset_conversation, :configure]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # CurlAgent is registered on Entity.CurlAgent Kind (type_name
  # :curl_agent) — kind axis is `:curl_agent`.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      receive: Ezagent.Capability.cap(:curl_agent, __MODULE__, :receive),
      reset_conversation: Ezagent.Capability.cap(:curl_agent, __MODULE__, :reset_conversation),
      configure: Ezagent.Capability.cap(:curl_agent, __MODULE__, :configure)
    }
  end

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:receive,
       "receive a session message and call the configured curl endpoint (LLM API mirror)"},
      {:reset_conversation, "clear the curl agent's conversation history"},
      {:configure, "set or update the curl agent's endpoint config (URL, headers, prompt)"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :curl_agent

  @impl Ezagent.Behavior
  def init_slice(args) do
    %{
      provider: Map.get(args, :provider, "deepseek"),
      api_url: Map.get(args, :api_url, "https://api.deepseek.com/chat/completions"),
      model: Map.get(args, :model, "deepseek-chat"),
      system_prompt: Map.get(args, :system_prompt),
      max_history: Map.get(args, :max_history, 20),
      owner_uri: Map.get(args, :owner_uri, URI.parse("entity://user/system/admin")),
      conversation: [],
      last_error: nil,
      last_tokens: nil
    }
  end

  @impl Ezagent.Behavior
  def invoke(:receive, slice, %{message: %Ezagent.Message{} = msg}, ctx) do
    # Loop prevention: ignore messages we sent ourselves. Without this,
    # an `{:always}` routing rule pointing at this agent would feed
    # the agent's own reply back in → infinite chat-completion loop.
    # (Belt + suspenders to operator using `{:from, entity://user/...}` rules
    # which would also break the cycle on the routing side.)
    self_uri_str = URI.to_string(ctx.self_uri)
    sender_str = URI.to_string(msg.sender)

    if sender_str == self_uri_str do
      {:ok, slice, %{ok: true, ignored: :self_message}}
    else
      do_receive(slice, msg, ctx)
    end
  end

  def invoke(:reset_conversation, slice, _args, _ctx) do
    new_slice = %{slice | conversation: [], last_error: nil}
    {:ok, new_slice, %{ok: true}}
  end

  def invoke(:configure, slice, args, _ctx) when is_map(args) do
    # Mutable per-slice settings (provider/model/system_prompt/max_history).
    # owner_uri is intentionally NOT mutable post-instantiate — changing it
    # would let the new owner's key be used by a conversation the old owner
    # built up. Re-create the instance via Template if owner needs to change.
    new_slice = %{
      slice
      | provider: Map.get(args, :provider, slice.provider),
        api_url: Map.get(args, :api_url, slice.api_url),
        model: Map.get(args, :model, slice.model),
        system_prompt: Map.get(args, :system_prompt, slice.system_prompt),
        max_history: Map.get(args, :max_history, slice.max_history)
    }

    {:ok, new_slice, %{ok: true}}
  end

  # Helper for invoke(:receive) — kept below the invoke/4 clauses so
  # they group contiguously (Elixir clause-grouping warning).
  defp do_receive(slice, %Ezagent.Message{} = msg, ctx) do
    user_text = msg.body[:text] || msg.body["text"] || ""
    source_session_uri = ctx[:caller]

    appended_conv = append_turn(slice.conversation, "user", user_text)
    trimmed_conv = trim(appended_conv, slice.max_history)

    case run_completion(slice, trimmed_conv) do
      {:ok, %{content: reply, usage: usage}} ->
        final_conv = append_turn(trimmed_conv, "assistant", reply)
        new_slice = %{slice | conversation: final_conv, last_error: nil, last_tokens: usage}

        send_reply_to_session(source_session_uri, ctx.self_uri, reply)

        {:ok, new_slice, %{ok: true, tokens: usage.total}}

      {:error, {:no_api_key, provider}} ->
        new_slice = %{slice | conversation: trimmed_conv, last_error: {:no_api_key, provider}}

        send_reply_to_session(
          source_session_uri,
          ctx.self_uri,
          "⚠️  no API key for provider `#{provider}` — owner #{URI.to_string(slice.owner_uri)} please add one at " <>
            "/admin/users/#{URI.encode_www_form(URI.to_string(slice.owner_uri))}/api-keys"
        )

        {:ok, new_slice, %{ok: false, error: :no_api_key}}

      {:error, reason} ->
        Logger.warning(
          "CurlAgent #{URI.to_string(ctx.self_uri)} provider=#{slice.provider} model=#{slice.model} " <>
            "completion error: #{inspect(reason)}"
        )

        new_slice = %{slice | conversation: trimmed_conv, last_error: reason}

        send_reply_to_session(
          source_session_uri,
          ctx.self_uri,
          "⚠️  upstream API error: #{format_error(reason)}"
        )

        {:ok, new_slice, %{ok: false, error: error_kind(reason)}}
    end
  end

  @impl Ezagent.Behavior
  def interface do
    %{
      receive: %{
        description: "Call the remote LLM with the conversation and reply into the session",
        args: %{message: :map},
        returns: %{ok: :boolean, tokens: :integer, error: :atom},
        modes: [:cast]
      },
      reset_conversation: %{
        description: "Clear the agent's accumulated conversation history",
        args: %{},
        returns: %{ok: :boolean},
        modes: [:call]
      },
      configure: %{
        description: "Update the agent's provider, model, prompt, and history settings",
        args: %{
          provider: :string,
          api_url: :string,
          model: :string,
          system_prompt: :string,
          max_history: :integer
        },
        returns: %{ok: :boolean},
        modes: [:call]
      }
    }
  end

  # --- internals --------------------------------------------------------

  defp append_turn(conv, role, content), do: conv ++ [%{role: role, content: content}]

  defp trim(conv, max_history) when length(conv) <= max_history, do: conv
  defp trim(conv, max_history), do: Enum.take(conv, -max_history)

  defp run_completion(slice, conversation) do
    with {:ok, api_key} <- fetch_owner_api_key(slice.owner_uri, slice.provider) do
      messages = build_messages(slice.system_prompt, conversation)

      ApiClient.chat_completion(%{
        api_url: slice.api_url,
        api_key: api_key,
        model: slice.model,
        messages: messages
      })
    end
  end

  defp fetch_owner_api_key(%URI{} = owner_uri, provider) when is_binary(provider) do
    target = URI.new!("#{URI.to_string(owner_uri)}?action=identity.get_api_key")

    invocation = %Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{provider: provider},
      ctx: %{
        caller: owner_uri,
        # SPEC caps-cleanup-v1 §4.4 — agent-internal data access
        # (reading owner's API key on behalf of the agent) runs
        # under `system://agent-internal` per the closed Catalog.
        caps: Ezagent.SystemPrincipal.caps("system://agent-internal"),
        reply: :ignore
      }
    }

    case Ezagent.Invocation.dispatch(invocation) do
      {:ok, %{key: key}} -> {:ok, key}
      {:error, {:no_api_key, _}} = err -> err
      {:error, reason} -> {:error, {:api_key_lookup_failed, reason}}
    end
  end

  defp build_messages(nil, conversation), do: conversation

  defp build_messages(system_prompt, conversation) when is_binary(system_prompt) do
    [%{role: "system", content: system_prompt} | conversation]
  end

  defp send_reply_to_session(nil, _, _), do: :ok
  defp send_reply_to_session("", _, _), do: :ok

  defp send_reply_to_session(session_uri, agent_uri, text) do
    session = parse_session_uri(session_uri)

    if session do
      msg =
        Ezagent.Message.new(agent_uri, %{text: text, attachments: []})

      target = URI.new!("#{URI.to_string(session)}?action=chat.send")

      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: agent_uri,
          # SPEC caps-cleanup-v1 §4.4 — agent reply path uses
          # `system://chat-reply` per Catalog.
          caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
          reply: :ignore
        }
      })
    else
      :ok
    end
  end

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
    case URI.new(s) do
      {:ok, %URI{scheme: "session"} = u} -> u
      _ -> nil
    end
  end

  defp parse_session_uri(_), do: nil

  defp error_kind({:http, _, _}), do: :http_error
  defp error_kind({:transport, _}), do: :transport_error
  defp error_kind({:decode, _}), do: :decode_error
  defp error_kind(_), do: :other

  defp format_error({:http, status, _body}), do: "HTTP #{status}"
  defp format_error({:transport, reason}), do: "transport: #{inspect(reason)}"
  defp format_error({:decode, _}), do: "could not decode response"
  defp format_error(other), do: inspect(other)

  # PR-OWN-4 round-2 (codex MED fix): CurlAgent has per-instance
  # `owner_uri` (the user whose API key funds the agent + whose
  # conversation history persists). Owner-derived grants follow
  # the Chat pattern — read the live `:curl_agent` slice via
  # `Ezagent.Kind.get_slice/2`. Returns `:no_owner` for missing
  # Kind (test paths) so §5.2 falls back to bootstrap admin.
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "entity", host: "agent"} = agent_uri) do
    case Ezagent.Kind.get_slice(agent_uri, :curl_agent) do
      {:ok, %{owner_uri: %URI{} = owner}} -> owner
      _ -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
