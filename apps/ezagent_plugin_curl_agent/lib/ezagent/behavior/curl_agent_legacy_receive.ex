defmodule Ezagent.Behavior.CurlAgentLegacyReceive do
  @moduledoc """
  Legacy `:receive` for the OLD `Ezagent.Entity.CurlAgent` Kind ONLY
  (codex P1, PR-6 rollback window).

  ## Why this exists

  PR-6 folded curl into `Ezagent.Entity.Agent`: NEW curl agents spawn on the
  unified Agent Kind and receive via `agent.receive` → `AgentBridge` → the
  curl `:in_process_sync` adapter. As part of that fold, the `:receive` action
  was DROPPED from `Ezagent.Behavior.CurlAgent` (`actions/0` is now
  `[:sync_result, :reset_conversation, :configure]`).

  But EXISTING `curl_agent` snapshots still resolve to their `kind_type`
  `Ezagent.Entity.CurlAgent`, and session delivery dispatches inbound chat as
  action `:receive`. Without a `:receive` binding on the legacy Kind, a
  pre-migration curl agent would hit `{:unknown_action, :receive}` and go MUTE
  for the whole rollback window (until PR-7 migrates the snapshots onto
  `Entity.Agent`).

  This Behavior restores the OLD inline-completion `:receive` (the pre-fold
  `Ezagent.Behavior.CurlAgent.handle_receive/2` + `run_completion/6` +
  `ApiClient`) — bound EXCLUSIVELY to `{Entity.CurlAgent, :receive}` (the
  legacy path). It carries NO `state_slice` of its own; it shares the
  `:curl_agent` slice the legacy Kind already materializes via
  `Ezagent.Behavior.CurlAgent` and reads the agent's OWN key from the
  `:api_keys` sibling slice (same as pre-fold). `:reset_conversation` /
  `:configure` / `:sync_result` stay on `Ezagent.Behavior.CurlAgent`; only
  `:receive` lives here, so there is no double-registration on either Kind.

  PR-7 deletes this module together with `Entity.CurlAgent` once the snapshots
  are migrated.
  """

  # Share the legacy Kind's existing `:curl_agent` slice (do NOT auto-derive
  # `:curl_agent_legacy_receive`, which would orphan an empty slice on a
  # snapshot-on-change agent). This handler reads that slice + writes it via
  # `{:set, …}` effects, exactly as the pre-fold `:receive` did.
  use Ezagent.Lifecycle, state_slice: :curl_agent

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

  # The legacy Kind keys on the `:curl_agent` axis (type_name :curl_agent),
  # matching the pre-fold `Ezagent.Behavior.CurlAgent.required_caps/0`. The
  # unified Agent Kind never binds THIS Behavior, so the axis stays legacy-only.
  def required_caps do
    %{receive: Ezagent.Capability.cap(:curl_agent, __MODULE__, :receive)}
  end

  # Same sibling read as the pre-fold receive — the agent's OWN api key.
  reads_siblings([:api_keys])

  # No `create/1`: this Behavior owns no fresh state. The shared `:curl_agent`
  # slice is built by `Ezagent.Behavior.CurlAgent.create/1` on the same Kind.

  # ---------------------------------------------------------------
  # handle_receive/2 — VERBATIM pre-fold inline-completion path
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

  # --- internals (lifted from the pre-fold Behavior.CurlAgent) -----------

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
            "CurlAgent (legacy) #{URI.to_string(self_uri)} provider=#{provider} model=#{model} " <>
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

  # Fetch the agent's OWN api_key from its `:api_keys` sibling state (same as
  # the pre-fold receive). Reads via the Lifecycle `ctx.siblings` surface.
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

  defp maybe_reply_effect(nil, _self_uri, _text), do: []
  defp maybe_reply_effect("", _self_uri, _text), do: []
  defp maybe_reply_effect(_, nil, _text), do: []

  defp maybe_reply_effect(session_uri, %URI{} = self_uri, text) do
    case parse_session_uri(session_uri) do
      nil ->
        []

      %URI{} = session ->
        reply_msg = Message.new(self_uri, %{text: text, attachments: []})
        target = Ezagent.URI.with_action(session, :session, :send)

        cmd =
          Cmd.new(target, :send, %{message: reply_msg}, %{
            caller: self_uri,
            caps: "chat-reply" |> Ezagent.SystemPrincipal.uri() |> Ezagent.SystemPrincipal.caps(),
            reply: :ignore
          })

        [{:dispatch, cmd}]
    end
  end

  defp parse_session_uri(%URI{scheme: "session"} = u), do: u

  defp parse_session_uri(s) when is_binary(s) do
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

  # caps-data-ownership-v2 (SPEC #306 §7) — a Behavior with caps MUST declare
  # data_owner/1. Shares the legacy `:curl_agent` slice; same grant authority as
  # the reparented `Ezagent.Behavior.CurlAgent` (the `:api_keys` `:creator_uri`).
  def data_owner(arg), do: Ezagent.Behavior.CurlAgent.data_owner(arg)

  defp error_kind({:http, _, _}), do: :http_error
  defp error_kind({:transport, _}), do: :transport_error
  defp error_kind({:decode, _}), do: :decode_error
  defp error_kind(_), do: :other

  defp format_error({:http, status, _body}), do: "HTTP #{status}"
  defp format_error({:transport, reason}), do: "transport: #{inspect(reason)}"
  defp format_error({:decode, _}), do: "could not decode response"
  defp format_error(other), do: inspect(other)
end
