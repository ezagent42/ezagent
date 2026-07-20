defmodule Ezagent.ActionSet.CcHeadlessAgent do
  @moduledoc """
  Stateful `cc-headless` behavior on the unified Agent Kind.

  The transport adapter runs the Python Claude Code SDK sidecar and returns a
  synchronous result. This behavior owns the durable post-result mutation and
  dispatches the assistant reply back to the source session.
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.Agent.ErrorSignal

  action(:cc_headless_sync_result,
    args: %{result: :term, source_session: {:option, :uri}, user_text: :string},
    returns: %{ok: :boolean, tokens: :integer, error: :atom},
    caps: [:cc_headless_sync_result],
    modes: [:cast],
    description: "persist the cc-headless SDK result + reply into the session"
  )

  @doc false
  def required_caps do
    %{
      cc_headless_sync_result:
        Ezagent.Capability.cap(:agent, __MODULE__, :cc_headless_sync_result)
    }
  end

  @doc false
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       flavor: "cc-headless",
       conversation: [],
       max_history: Map.get(args, :max_history, 40),
       claude_session_id: Map.get(args, :claude_session_id),
       last_error: nil,
       last_tokens: nil
     }}
  end

  @doc false
  def handle_cc_headless_sync_result(%{result: result} = args, ctx) do
    source_session_uri = Map.get(args, :source_session)
    self_uri = Map.get(ctx, :self_uri)
    max_history = ctx.read.(:max_history, 40)
    current_conv = ctx.read.(:conversation, [])
    user_text = Map.get(args, :user_text, "")
    in_msg_id = Map.get(args, :in_msg_id)
    reply_cap = Map.get(args, :reply_cap)

    case result do
      {:ok, %{content: reply, usage: usage}} ->
        final_conv =
          current_conv
          |> append_turn("user", user_text)
          |> append_turn("assistant", reply)
          |> trim(max_history)

        effects =
          [
            {:set, :conversation, final_conv},
            {:set, :last_error, nil},
            {:set, :last_tokens, usage}
          ] ++ maybe_reply_effect(source_session_uri, self_uri, reply, in_msg_id, reply_cap)

        {:ok, %{ok: true, tokens: usage_total(usage)}, effects}

      {:error, reason} ->
        if is_struct(self_uri, URI) do
          Logger.warning(
            "CcHeadlessAgent #{URI.to_string(self_uri)} SDK error: #{inspect(reason)}"
          )
        end

        effects =
          [
            {:set, :conversation,
             current_conv |> append_turn("user", user_text) |> trim(max_history)},
            {:set, :last_error, reason}
          ] ++ maybe_reply_error(source_session_uri, self_uri, reason, in_msg_id, reply_cap)

        {:ok, %{ok: false, error: error_kind(reason)}, effects}
    end
  end

  defp append_turn(conv, role, content), do: conv ++ [%{role: role, content: content}]

  defp trim(conv, max_history) when length(conv) <= max_history, do: conv
  defp trim(conv, max_history), do: Enum.take(conv, -max_history)

  defp maybe_reply_effect(nil, _self_uri, _text, _in_msg_id, _reply_cap), do: []
  defp maybe_reply_effect("", _self_uri, _text, _in_msg_id, _reply_cap), do: []
  defp maybe_reply_effect(_, nil, _text, _in_msg_id, _reply_cap), do: []

  defp maybe_reply_effect(session_uri, %URI{} = self_uri, text_or_body, in_msg_id, reply_cap) do
    case parse_session_uri(session_uri) do
      nil ->
        []

      %URI{} = session ->
        reply_msg = Message.new(self_uri, reply_body(text_or_body), ref_id: in_msg_id)
        target = Ezagent.URI.with_action(session, :session, :send)

        cmd =
          Cmd.new(target, :send, %{message: reply_msg}, %{
            caller: self_uri,
            caps: MapSet.new(List.wrap(reply_cap)),
            reply: :ignore
          })

        [{:dispatch, cmd}]
    end
  end

  # G5 source 2 — structured error reply (see `Ezagent.ActionSet.CurlAgent`).
  defp maybe_reply_error(session_uri, self_uri, reason, in_msg_id, reply_cap) do
    maybe_reply_effect(
      session_uri,
      self_uri,
      ErrorSignal.reply_body(reason),
      in_msg_id,
      reply_cap
    )
  end

  defp reply_body(text) when is_binary(text), do: %{text: text, attachments: []}
  defp reply_body(%{} = body), do: body

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

  defp usage_total(%{total: total}) when is_integer(total), do: total
  defp usage_total(%{"total" => total}) when is_integer(total), do: total
  defp usage_total(%{"total_tokens" => total}) when is_integer(total), do: total
  defp usage_total(_), do: 0

  defp error_kind({:sdk_worker_error, _}), do: :sdk_worker_error
  defp error_kind(:sdk_sidecar_not_started), do: :sdk_sidecar_not_started
  defp error_kind(:sdk_sidecar_timeout), do: :sdk_sidecar_timeout
  defp error_kind({:sdk_sidecar_exit, _}), do: :sdk_sidecar_exit
  defp error_kind(_), do: :other

  @doc false
  def data_owner(instance), do: Ezagent.ActionSet.ApiKeys.data_owner(instance)
end
