defmodule Ezagent.SagaRunner do
  @moduledoc """
  Stateless linear saga with forward + compensate steps.

  Used when a Behavior handler returns a `{:saga, %Ezagent.SagaRunner.Saga{}}`
  effect, or when the framework runs a destroy-cascade / lifecycle saga over
  a known step sequence (e.g. Entity destroy → Resource list → walk in
  declared order; Session create → workspace bind → publisher start → ready).

  ## Compensation honesty

  Saga compensation is **best-effort partial restore**, NOT true rollback.

  Plugin authors writing sagas MUST design steps assuming partial-failure
  recovery may require operator intervention. Specifically:

    * Pure-state mutations (slice changes) ARE reversible if the compensate
      function snapshots before forward and restores on rollback.
    * Already-sent PubSub broadcasts, already-dispatched cross-Kind messages,
      already-fired external IO (HTTP calls, file writes), and already-
      terminated Kinds are NOT reversible. A compensate function can attempt
      a *counter-action* (DELETE the file, POST a "rollback") but the
      original side effect happened.
    * Resurrected Kinds after `:terminate` are SEPARATE GenServer instances —
      caps/state from the original are LOST.

  If a compensate function itself fails, the saga writes an
  **operator-repair marker** (a UUID returned in the `:error` tuple and a
  log line at `:error` level) and aborts the remaining compensation walk.
  The error tuple includes the list of steps that compensated successfully
  PLUS the step where compensation failed, so an operator can inspect
  `/admin/saga_history` (or the logs in Phase 1) and decide manually.

  See SPEC `2026-05-28-router-behavior-kind-architecture.md` §5.4 + r2 codex
  HIGH-5 closure for the full compensation contract.

  ## Public API

      Ezagent.SagaRunner.new()
      |> Ezagent.SagaRunner.run(:lock,
           fn ctx, _effects -> {:ok, :locked, [{:set, :locked, true}]} end,
           fn _err, _effects, ctx -> Cache.unlock(ctx.uri); {:ok, :compensated} end)
      |> Ezagent.SagaRunner.run(:transfer,
           fn ctx, _effects -> {:ok, :ok, []} end)
      |> Ezagent.SagaRunner.execute(%{uri: "..."})

  Returns:

      {:ok, %{step_results: %{lock: :locked, transfer: :ok}, events: [...]}}

  Or on forward-step failure with successful compensation:

      {:error, %{
         failed_at: :transfer,
         reason: :insufficient_funds,
         compensated: [:lock],
         operator_repair_marker: nil
       }}

  Or on compensation failure (operator must repair):

      {:error, %{
         failed_at: :transfer,
         reason: :insufficient_funds,
         compensated: [],
         operator_repair_marker: "8b3c…"   # UUID + matching :error log line
       }}

  ## Function signatures

    * **Forward**: `(ctx, effects_so_far) -> {:ok, result, [effect]} | {:error, reason}`
      - `ctx` — the initial context map passed to `execute/2`
      - `effects_so_far` — flat list of `[effect]` accumulated from PRIOR
        successful forward steps (in execution order)
      - `result` — opaque per-step result, stored in `step_results` under
        the step name
      - `[effect]` — list of effect terms (the SagaRunner does NOT
        interpret these; it just accumulates them for downstream steps and
        returns them via the `:events` key on success)

    * **Compensate** (optional, may be `nil`): `(error, effects_so_far, ctx) ->
      {:ok, :compensated} | {:error, :compensation_failed, reason}`
      - `error` — the `reason` returned by the failed forward step
      - `effects_so_far` — flat list of effects from PRIOR steps INCLUDING
        the step being compensated (i.e. the failure point has no effects
        because forward returned `:error`)
      - Steps without a compensate function (`nil`) are silently skipped
        during reverse-walk.

  ## Note on `:ref` substitution

  The SagaRunner does NOT interpret `{:ref, ...}` placeholders or apply
  `bind_as` semantics. That is the `Ezagent.ActionSet` macro's effect-applier
  concern. The SagaRunner just shuttles the `[effect]` list forward.
  """

  require Logger

  alias __MODULE__.Saga

  defmodule Saga do
    @moduledoc """
    A linear saga: an ordered list of `{step_name, forward_fn, compensate_fn}`
    triples. Construct with `Ezagent.SagaRunner.new/0` and `run/3,4`; execute
    with `Ezagent.SagaRunner.execute/2`.

    The struct is intentionally minimal — no name, no command_uuid (the
    framework wraps SagaRunner.execute/2 and supplies its own idempotency
    key via `Ezagent.Idempotency`).
    """

    @type step_name :: atom()
    @type effect :: term()
    @type forward_fn :: (map(), [effect()] -> {:ok, term(), [effect()]} | {:error, term()})
    @type compensate_fn ::
            (term(), [effect()], map() ->
               {:ok, :compensated} | {:error, :compensation_failed, term()})

    @type step :: {step_name(), forward_fn(), compensate_fn() | nil}

    @type t :: %__MODULE__{steps: [step()]}

    defstruct steps: []
  end

  @type ok_result ::
          {:ok, %{step_results: %{Saga.step_name() => term()}, events: [Saga.effect()]}}
  @type error_result ::
          {:error,
           %{
             failed_at: Saga.step_name() | nil,
             reason: term(),
             compensated: [Saga.step_name()],
             operator_repair_marker: String.t() | nil
           }}

  @doc """
  Build a fresh empty saga.

      iex> Ezagent.SagaRunner.new()
      %Ezagent.SagaRunner.Saga{steps: []}
  """
  @spec new() :: Saga.t()
  def new, do: %Saga{}

  @doc """
  Append a step to the saga. Steps execute in the order they were appended;
  on failure, prior steps are compensated in reverse order.

  `compensate_fn` may be `nil`; such steps are skipped during reverse-walk.
  """
  @spec run(Saga.t(), Saga.step_name(), Saga.forward_fn(), Saga.compensate_fn() | nil) ::
          Saga.t()
  def run(%Saga{steps: steps} = saga, step_name, forward_fn, compensate_fn \\ nil)
      when is_atom(step_name) and is_function(forward_fn, 2) and
             (is_nil(compensate_fn) or is_function(compensate_fn, 3)) do
    %{saga | steps: steps ++ [{step_name, forward_fn, compensate_fn}]}
  end

  @doc """
  Execute the saga linearly. See module doc for return shapes.

  Empty saga returns `{:ok, %{step_results: %{}, events: []}}`.
  """
  @spec execute(Saga.t(), map()) :: ok_result() | error_result()
  def execute(%Saga{steps: steps}, ctx) when is_map(ctx) do
    do_execute(steps, ctx, %{}, [], [])
  end

  # Recursive forward walk.
  #
  # Args:
  #   steps        — remaining steps to execute
  #   ctx          — caller-supplied initial context (immutable across steps)
  #   step_results — accumulated per-step results, keyed by step_name
  #   effects      — flat list of effects accumulated from prior steps
  #   done         — reverse-ordered list of {step_name, compensate_fn, effects_at_step}
  #                  triples used during compensation walk
  defp do_execute([], _ctx, step_results, effects, _done) do
    {:ok, %{step_results: step_results, events: effects}}
  end

  defp do_execute(
         [{step_name, forward_fn, compensate_fn} | rest],
         ctx,
         step_results,
         effects,
         done
       ) do
    case safe_forward(forward_fn, ctx, effects) do
      {:ok, result, new_effects} when is_list(new_effects) ->
        do_execute(
          rest,
          ctx,
          Map.put(step_results, step_name, result),
          effects ++ new_effects,
          [{step_name, compensate_fn, effects ++ new_effects} | done]
        )

      {:error, reason} ->
        compensate(step_name, reason, ctx, done)

      other ->
        # Forward function returned the wrong shape — treat as a bug + fail
        # the saga. Triggers compensation of prior steps; this step has no
        # effects to compensate (forward didn't return :ok).
        compensate(step_name, {:bad_forward_return, other}, ctx, done)
    end
  end

  defp safe_forward(forward_fn, ctx, effects) do
    try do
      forward_fn.(ctx, effects)
    rescue
      e ->
        {:error, {:forward_raised, Exception.message(e)}}
    catch
      kind, payload ->
        {:error, {:forward_threw, kind, payload}}
    end
  end

  # Reverse-walk `done` (most-recent-first) invoking each compensate_fn.
  # If a compensate_fn raises OR returns `{:error, :compensation_failed, _}`,
  # we write an operator-repair marker and abort.
  defp compensate(failed_at, reason, ctx, done) do
    do_compensate(done, ctx, reason, [], failed_at)
  end

  defp do_compensate([], _ctx, reason, compensated_acc, failed_at) do
    {:error,
     %{
       failed_at: failed_at,
       reason: reason,
       # `compensated_acc` was built in walk order (most-recent first).
       # Reverse to give caller the order steps were COMPENSATED IN.
       compensated: Enum.reverse(compensated_acc),
       operator_repair_marker: nil
     }}
  end

  defp do_compensate(
         [{_step_name, nil, _effects_at_step} | rest],
         ctx,
         reason,
         compensated_acc,
         failed_at
       ) do
    # No compensate function — silently skip.
    do_compensate(rest, ctx, reason, compensated_acc, failed_at)
  end

  defp do_compensate(
         [{step_name, compensate_fn, effects_at_step} | rest],
         ctx,
         reason,
         compensated_acc,
         failed_at
       ) do
    case safe_compensate(compensate_fn, reason, effects_at_step, ctx) do
      {:ok, :compensated} ->
        do_compensate(rest, ctx, reason, [step_name | compensated_acc], failed_at)

      {:error, :compensation_failed, comp_reason} ->
        marker = write_operator_repair_marker(failed_at, step_name, reason, comp_reason)

        {:error,
         %{
           failed_at: failed_at,
           reason: reason,
           compensated: Enum.reverse(compensated_acc),
           operator_repair_marker: marker
         }}

      other ->
        # Compensate returned the wrong shape — also a repair situation.
        marker =
          write_operator_repair_marker(
            failed_at,
            step_name,
            reason,
            {:bad_compensate_return, other}
          )

        {:error,
         %{
           failed_at: failed_at,
           reason: reason,
           compensated: Enum.reverse(compensated_acc),
           operator_repair_marker: marker
         }}
    end
  end

  defp safe_compensate(compensate_fn, reason, effects_at_step, ctx) do
    try do
      compensate_fn.(reason, effects_at_step, ctx)
    rescue
      e ->
        {:error, :compensation_failed, {:compensate_raised, Exception.message(e)}}
    catch
      kind, payload ->
        {:error, :compensation_failed, {:compensate_threw, kind, payload}}
    end
  end

  # Operator-repair marker — Phase 1 implementation per SPEC §5.4 r2 HIGH-5
  # closure Option A: just a UUID returned in the error tuple + a log line
  # at `:error` level. Phase 2+ may add an ETS-backed registry or DB table
  # (`saga_operator_repair_markers`) that operators can query.
  defp write_operator_repair_marker(failed_at, comp_failed_at, forward_reason, comp_reason) do
    marker = generate_marker_id()

    Logger.error(
      "[SagaRunner] operator-repair marker #{marker}: " <>
        "forward step #{inspect(failed_at)} failed with #{inspect(forward_reason)}; " <>
        "compensation of step #{inspect(comp_failed_at)} failed with #{inspect(comp_reason)}. " <>
        "Manual intervention required."
    )

    marker
  end

  # 128-bit hex UUID; sufficient unique identifier for log correlation.
  defp generate_marker_id do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end
end
