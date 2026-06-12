defmodule EzagentPluginAutoservice.TurnAdapter do
  @moduledoc """
  Builds and dispatches `%Ezagent.Invocation{}` structs for turn lifecycle actions.

  The TurnAdapter is the canonical entry point for the customer-service turn
  lifecycle (open, compose, settle, claim). Each function constructs a fully-formed
  `%Invocation{}` with a `system://turn-adapter` principal context and dispatches
  synchronously (`:call` mode) against the target Session URI.

  ## Turn lifecycle

  - `open_turn/2` — customer initiates a turn (carries message text + customer URI)
  - `compose_turn/3` — an agent contributes a response for an open turn
  - `settle_turn/2` — mark a turn as complete (committed to message store)
  - `claim_turn/2` — operator claims a turn (direct human intervention)
  - `cancel_turn/2` — cancel a non-terminal turn
  """

  alias Ezagent.Invocation

  @doc """
  Open a turn: customer message triggers the turn lifecycle on a Session.

  Returns the dispatch result (typically `{:ok, _}` or `{:error, reason}`).
  """
  @spec open_turn(URI.t(), %{customer_uri: URI.t(), text: String.t()}) :: term()
  def open_turn(session_uri, %{customer_uri: cu, text: text}) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.open"),
      mode: :call,
      args: %{trigger: %{msg: text, from: cu}, opened_at: System.system_time(:second)},
      ctx: system_ctx()
    })
  end

  @doc """
  Compose a turn: an agent contributes a response for an open turn.
  """
  @spec compose_turn(URI.t(), String.t(), %{agent_uri: URI.t(), text: String.t()}) :: term()
  def compose_turn(session_uri, turn_id, %{agent_uri: au, text: text}) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.compose"),
      mode: :call,
      # `kind: :chat` is REQUIRED: `Turn.handle_compose` only writes a chat
      # message (and records its id for settlement → customer delivery) for refs
      # whose kind is :chat/:message. Without it the reply is never persisted as
      # a customer-deliverable message, the settlement has no target_message_ids,
      # and the operator reply silently never reaches the customer feed.
      args: %{turn_id: turn_id, result_refs: [%{kind: :chat, agent: au, text: text}]},
      ctx: system_ctx()
    })
  end

  @doc """
  Settle (commit) a turn. Completes the turn and persists results.
  """
  @spec settle_turn(URI.t(), String.t()) :: term()
  def settle_turn(session_uri, turn_id) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.settle"),
      mode: :call,
      args: %{turn_id: turn_id},
      ctx: system_ctx()
    })
  end

  @doc """
  Claim a turn: an operator takes over a turn (direct human intervention).
  """
  @spec claim_turn(URI.t(), String.t(), %{operator_uri: URI.t()}) :: term()
  def claim_turn(session_uri, turn_id, %{operator_uri: op}) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.claim"),
      mode: :call,
      args: %{turn_id: turn_id, by: op},
      ctx: system_ctx()
    })
  end

  @doc """
  Cancel a non-terminal turn (open, composing, or awaiting_human).
  """
  @spec cancel_turn(URI.t(), String.t()) :: term()
  def cancel_turn(session_uri, turn_id) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.cancel"),
      mode: :call,
      args: %{turn_id: turn_id},
      ctx: system_ctx()
    })
  end

  # --- internals ---

  defp system_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("turn-adapter"),
      caps: Ezagent.SystemPrincipal.caps("system://turn-adapter"),
      reply: {:caller_inbox, self()}
    }
  end
end
