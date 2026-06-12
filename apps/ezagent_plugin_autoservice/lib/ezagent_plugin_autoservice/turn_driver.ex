defmodule EzagentPluginAutoservice.TurnDriver do
  @moduledoc """
  Drive socialware Behavior.Turn on a SocialwareSession via
  `%Invocation{target: "<session>?action=turn.<a>", mode: :call}`.

  Each function dispatches one turn action and normalises the response.
  Orchestration (open → compose → settle flow) belongs to CsOrchestrator
  Behavior — this module is stateless and directly callable.

  Ported from PR #731 (commit 23b9974), Live E2E verified.
  """

  alias Ezagent.Invocation

  @typedoc "Turn-driving principal ctx"
  @type ctx :: %{
    required(:caller) => URI.t() | String.t(),
    required(:caps) => term()
  }

  @doc "Open a turn on session_uri. Returns {:ok, %{turn_id: id}} on success."
  @spec open(URI.t(), map(), ctx()) :: {:ok, %{turn_id: String.t()}} | {:error, term()}
  def open(%URI{} = session_uri, trigger_map, ctx) when is_map(trigger_map) do
    args = %{trigger: trigger_map, opened_at: System.system_time(:millisecond)}

    case dispatch(session_uri, :turn, :open, args, ctx) do
      {:ok, %{turn_id: turn_id}} -> {:ok, %{turn_id: turn_id}}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Compose a result ref on an open turn. Returns {:ok, result_map} on success."
  @spec compose(URI.t(), String.t(), String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def compose(%URI{} = session_uri, turn_id, text, ctx)
      when is_binary(turn_id) and is_binary(text) do
    args = %{turn_id: turn_id, result_refs: [%{kind: :chat, text: text}]}

    case dispatch(session_uri, :turn, :compose, args, ctx) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Settle an open (or awaiting_human) turn. Returns {:ok, result_map} on success."
  @spec settle(URI.t(), String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def settle(%URI{} = session_uri, turn_id, ctx) when is_binary(turn_id) do
    case dispatch(session_uri, :turn, :settle, %{turn_id: turn_id}, ctx) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Claim a composing turn for a human operator."
  @spec claim(URI.t(), String.t(), URI.t() | String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def claim(%URI{} = session_uri, turn_id, by, ctx) when is_binary(turn_id) do
    case dispatch(session_uri, :turn, :claim, %{turn_id: turn_id, by: by}, ctx) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Cancel a non-terminal turn."
  @spec cancel(URI.t(), String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def cancel(%URI{} = session_uri, turn_id, ctx) when is_binary(turn_id) do
    case dispatch(session_uri, :turn, :cancel, %{turn_id: turn_id}, ctx) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp dispatch(session_uri, behavior, action, args, ctx) do
    target =
      Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")

    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: Map.fetch!(ctx, :caller),
        caps: Map.fetch!(ctx, :caps),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
