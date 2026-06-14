defmodule EzagentPluginAutoservice.TurnDriver do
  @moduledoc """
  Same-process Turn driver for Session + Behavior architecture.

  Calls `Ezagent.Behavior.Turn.handle_*` directly — does NOT go through
  `Invocation.dispatch`. This is the v3 design §6.6.1 requirement:
  TurnDriver is a pure function module that directly calls Turn internal
  functions within the Session process, avoiding cross-process dispatch
  overhead and cross-Kind coordination inconsistency.

  Each function returns a 3-tuple `{:ok, result, turn_effects}` where
  `turn_effects` are the Turn Behavior's effect list (e.g. `{:set, :turns, ...}`).
  The caller (CsOrchestrator) must merge these effects into its own effect list
  so the Lifecycle framework processes them atomically with the orchestrator's
  own state changes.

  Ported from PR #731, rewritten for same-process direct calls.
  """

  require Logger

  @typedoc "Turn result with effects to be merged by caller"
  @type turn_result(result) :: {:ok, result, [term()]} | {:error, term()}

  # Enrich ctx with default :read/:siblings if not present (for tests
  # that construct minimal ctx without the full Lifecycle injection).
  defp enrich_ctx(ctx) do
    ctx
    |> Map.put_new(:read, fn key, default -> Map.get(ctx, key, default) end)
    |> Map.put_new(:self_uri, Map.get(ctx, :self_uri, :system))
  end

  @doc "Open a turn. Returns {:ok, %{turn_id: id}, effects}."
  @spec open(URI.t(), map(), map()) :: turn_result(%{turn_id: String.t()})
  def open(%URI{} = _session_uri, trigger_map, ctx) when is_map(trigger_map) do
    args = %{trigger: trigger_map, opened_at: System.system_time(:millisecond)}

    case Ezagent.Behavior.Turn.handle_open(args, enrich_ctx(ctx)) do
      {:ok, %{turn_id: turn_id}, effects} -> {:ok, %{turn_id: turn_id}, effects}
      {:ok, other, effects} -> {:ok, other, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Compose a result ref on an open turn. Returns {:ok, result, effects}."
  @spec compose(URI.t(), String.t(), String.t(), map()) :: turn_result(map())
  def compose(%URI{} = _session_uri, turn_id, text, ctx)
      when is_binary(turn_id) and is_binary(text) do
    args = %{turn_id: turn_id, result_refs: [%{kind: :chat, text: text}]}

    case Ezagent.Behavior.Turn.handle_compose(args, enrich_ctx(ctx)) do
      {:ok, result, effects} when is_map(result) -> {:ok, result, effects}
      {:ok, other, effects} -> {:ok, other, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Settle a turn. Returns {:ok, result, effects}."
  @spec settle(URI.t(), String.t(), map()) :: turn_result(map())
  def settle(%URI{} = _session_uri, turn_id, ctx) when is_binary(turn_id) do
    case Ezagent.Behavior.Turn.handle_settle(%{turn_id: turn_id}, enrich_ctx(ctx)) do
      {:ok, result, effects} when is_map(result) -> {:ok, result, effects}
      {:ok, other, effects} -> {:ok, other, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Claim a composing turn. Returns {:ok, result, effects}."
  @spec claim(URI.t(), String.t(), URI.t() | String.t(), map()) :: turn_result(map())
  def claim(%URI{} = _session_uri, turn_id, by, ctx) when is_binary(turn_id) do
    case Ezagent.Behavior.Turn.handle_claim(%{turn_id: turn_id, by: by}, enrich_ctx(ctx)) do
      {:ok, result, effects} when is_map(result) -> {:ok, result, effects}
      {:ok, other, effects} -> {:ok, other, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Cancel a non-terminal turn. Returns {:ok, result, effects}."
  @spec cancel(URI.t(), String.t(), map()) :: turn_result(map())
  def cancel(%URI{} = _session_uri, turn_id, ctx) when is_binary(turn_id) do
    case Ezagent.Behavior.Turn.handle_cancel(%{turn_id: turn_id}, enrich_ctx(ctx)) do
      {:ok, result, effects} when is_map(result) -> {:ok, result, effects}
      {:ok, other, effects} -> {:ok, other, effects}
      {:error, reason} -> {:error, reason}
    end
  end
end
