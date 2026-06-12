defmodule EzagentPluginAutoservice.TurnAdapter do
  @moduledoc """
  Builds and dispatches `%Ezagent.Invocation{}` structs for turn lifecycle actions.

  The TurnAdapter is the canonical entry point for the customer-service turn
  lifecycle (open, compose, settle, claim). Each function constructs a fully-formed
  `%Invocation{}` and dispatches synchronously (`:call` mode) against the target
  Session URI.

  ## Caller authority (B-minimal P0)

  The takeover lifecycle is driven by the **operator's own authority**: during a
  takeover the operator legitimately opens/composes/claims/settles their OWN Turn,
  so each function takes a `caller` URI + `caps` (the operator's granted caps, as
  surfaced by `OperatorLive` via `Ezagent.Identity.list_caps_for/1`). The dispatch
  ctx is built from those — there is NO hardcoded `system://turn-adapter` principal
  (which held only `cap(:session, Chat, :any)` and could not authorize the Turn
  behavior's `:open`/`:compose`/`:claim`/`:settle` caps, so it returned
  `{:error, :unauthorized}` against a live session). The operator role's cap bundle
  (`EzagentPluginAutoservice.Roles.bundle(:operator, ws)`) now grants exactly those
  Turn caps, so this path authorizes + is auditable.

  `OperatorLive` is the sole caller, so the arity carries `caller`+`caps` cleanly.

  ## Turn lifecycle

  - `open_turn/3` — customer initiates a turn (carries message text + customer URI)
  - `compose_turn/4` — an agent contributes a response for an open turn
  - `settle_turn/3` — mark a turn as complete (committed to message store)
  - `claim_turn/4` — operator claims a turn (direct human intervention)
  - `cancel_turn/3` — cancel a non-terminal turn
  """

  alias Ezagent.Invocation

  @type caps :: MapSet.t() | [Ezagent.Capability.t()]

  @doc """
  Open a turn: customer message triggers the turn lifecycle on a Session.

  Returns the dispatch result (typically `{:ok, _}` or `{:error, reason}`).
  """
  @spec open_turn(URI.t(), %{customer_uri: URI.t(), text: String.t()}, URI.t(), caps()) :: term()
  def open_turn(session_uri, %{customer_uri: cu, text: text}, caller, caps) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.open"),
      mode: :call,
      args: %{trigger: %{msg: text, from: cu}, opened_at: System.system_time(:second)},
      ctx: caller_ctx(caller, caps)
    })
  end

  @doc """
  Compose a turn: an agent contributes a response for an open turn.
  """
  @spec compose_turn(
          URI.t(),
          String.t(),
          %{agent_uri: URI.t(), text: String.t()},
          URI.t(),
          caps()
        ) ::
          term()
  def compose_turn(session_uri, turn_id, %{agent_uri: au, text: text}, caller, caps) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.compose"),
      mode: :call,
      # `kind: :chat` is REQUIRED: `Turn.handle_compose` only writes a chat
      # message (and records its id for settlement → customer delivery) for refs
      # whose kind is :chat/:message. Without it the reply is never persisted as
      # a customer-deliverable message, the settlement has no target_message_ids,
      # and the operator reply silently never reaches the customer feed.
      args: %{turn_id: turn_id, result_refs: [%{kind: :chat, agent: au, text: text}]},
      ctx: caller_ctx(caller, caps)
    })
  end

  @doc """
  Settle (commit) a turn. Completes the turn and persists results.
  """
  @spec settle_turn(URI.t(), String.t(), URI.t(), caps()) :: term()
  def settle_turn(session_uri, turn_id, caller, caps) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.settle"),
      mode: :call,
      args: %{turn_id: turn_id},
      ctx: caller_ctx(caller, caps)
    })
  end

  @doc """
  Claim a turn: an operator takes over a turn (direct human intervention).
  """
  @spec claim_turn(URI.t(), String.t(), %{operator_uri: URI.t()}, URI.t(), caps()) :: term()
  def claim_turn(session_uri, turn_id, %{operator_uri: op}, caller, caps) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.claim"),
      mode: :call,
      args: %{turn_id: turn_id, by: op},
      ctx: caller_ctx(caller, caps)
    })
  end

  @doc """
  Cancel a non-terminal turn (open, composing, or awaiting_human).
  """
  @spec cancel_turn(URI.t(), String.t(), URI.t(), caps()) :: term()
  def cancel_turn(session_uri, turn_id, caller, caps) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.cancel"),
      mode: :call,
      args: %{turn_id: turn_id},
      ctx: caller_ctx(caller, caps)
    })
  end

  # --- internals ---

  # Build the dispatch ctx from the caller-supplied authority. The operator
  # drives their own takeover Turn; `reply: {:caller_inbox, self()}` routes the
  # synchronous `:call` reply back to the calling process.
  defp caller_ctx(%URI{} = caller, caps) do
    %{
      caller: caller,
      caps: caps,
      reply: {:caller_inbox, self()}
    }
  end
end
