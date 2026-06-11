defmodule EzagentPluginAutoservice.TurnDriver do
  @moduledoc """
  Drive socialware Behavior.Turn on a SocialwareSession via
  `%Invocation{target: "<session>?action=turn.<a>", mode: :call}` (v2 §6.6.1).

  Each function dispatches one turn action and normalises the response.
  Orchestration (open → compose → settle flow) belongs to the Lifecycle
  Kind in the next task — this module is stateless and directly callable.

  ## Invocation ctx shape

  Every dispatch carries:

      %{
        caller: URI.t() | String.t(),   # the turn-driving principal
        caps:   term(),                  # capability bundle
        reply:  {:caller_inbox, pid()}   # `:call` inbox — Invocation requires this
      }

  `reply` is always `{:caller_inbox, self()}` for synchronous `:call` dispatch.
  The `caller` and `caps` fields are supplied by the caller via the `ctx`
  argument to each function.
  """

  alias Ezagent.Invocation

  @typedoc "Turn-driving principal — `%{required(:caller) => URI.t() | String.t(), required(:caps) => term()}`."
  @type ctx :: %{required(:caller) => URI.t() | String.t(), required(:caps) => term()}

  @doc """
  Open a degenerate turn on `session_uri`.

  Dispatches `turn.open` with `args = %{trigger: trigger_map, opened_at: <ms>}`.
  Returns `{:ok, %{turn_id: id}}` on success, extracting `turn_id` from the
  result map. Unexpected status shapes map to `{:error, {:unexpected_turn_status, other}}`.
  """
  @spec open(URI.t(), map(), ctx()) :: {:ok, %{turn_id: String.t()}} | {:error, term()}
  def open(%URI{} = session_uri, trigger_map, ctx) when is_map(trigger_map) do
    args = %{trigger: trigger_map, opened_at: now_ms()}

    case dispatch(session_uri, :turn, :open, args, ctx) do
      {:ok, %{turn_id: turn_id}} -> {:ok, %{turn_id: turn_id}}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Compose a result ref on an open turn.

  Dispatches `turn.compose` with `result_refs: [%{kind: :chat, text: text}]`.
  Returns `{:ok, result_map}` on success.
  """
  @spec compose(URI.t(), String.t(), String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def compose(%URI{} = session_uri, turn_id, text, ctx)
      when is_binary(turn_id) and is_binary(text) do
    args = %{
      turn_id: turn_id,
      result_refs: [%{kind: :chat, text: text}]
    }

    case dispatch(session_uri, :turn, :compose, args, ctx) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Settle an open (or awaiting_human) turn.

  Dispatches `turn.settle` with `%{turn_id: turn_id}`.
  Returns `{:ok, result_map}` on success.
  """
  @spec settle(URI.t(), String.t(), ctx()) :: {:ok, map()} | {:error, term()}
  def settle(%URI{} = session_uri, turn_id, ctx) when is_binary(turn_id) do
    case dispatch(session_uri, :turn, :settle, %{turn_id: turn_id}, ctx) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:ok, other} -> {:error, {:unexpected_turn_status, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Claim an open (composing) turn for a human operator.

  Dispatches `turn.claim` with `%{turn_id: turn_id, by: by}` where `by` is the
  operator's URI. Moves the turn to `:awaiting_human` (copilot mode) — the
  composed draft is held `:operator_only` until a subsequent `settle/3` flips
  it `:customer_visible`.
  """
  @spec claim(URI.t(), String.t(), URI.t() | String.t(), ctx()) ::
          {:ok, map()} | {:error, term()}
  def claim(%URI{} = session_uri, turn_id, by, ctx) when is_binary(turn_id) do
    case dispatch(session_uri, :turn, :claim, %{turn_id: turn_id, by: by}, ctx) do
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

  defp now_ms, do: System.system_time(:millisecond)
end
