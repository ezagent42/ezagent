defmodule Ezagent.ExternalMirror.TestSupport.MockPublishBinding do
  @moduledoc """
  PR-EM-2 test support — Binding paired with
  `Ezagent.ExternalMirror.TestSupport.MockPublishAdapter`.

  Forwards every `publish/2` call to a test PID. The PID is
  configured in two ways:

  - **Per-target via `:persistent_term`**: tests call
    `MockPublishBinding.register_observer(target_id, test_pid)` in
    setup; `init/1` resolves the test_pid by `target_id` and stores
    it in `state`. This is the common shape — `assert_receive
    {:published, payload, target_id, ref}` in tests where the
    target_id is known.

  - **Per-binding via `init` opts**: when `init/1` is called with
    `%{observer: test_pid}` in opts, that pid is used INSTEAD of
    the persistent_term lookup. Useful for tests that want to
    plumb their own pid directly.

  ## Failure-injection knobs

  Tests can configure these via `init` opts:

  - `:fail_init` — `init/1` returns `{:error, opts[:fail_init]}`
    (causes the Worker's `handle_continue/3` to RAISE per SPEC
    §6.2 → PerBindingSupervisor restart-loop tests).
  - `:fail_publish` — `publish/2` returns `{:error, opts[:fail_publish],
    state}` for every call (recoverable-error path tests).
  - `:raise_publish` — `publish/2` raises `RuntimeError` with that
    reason (UNrecoverable / let-it-crash path tests; trips the
    PerBindingSupervisor's 3/30s budget after 3 raises).

  ## State shape

      %{
        target_id: term(),
        observer:  pid() | nil,
        opts:      map(),         # original opts for failure-injection lookup
        publish_count: non_neg_integer()
      }
  """

  @behaviour Ezagent.ExternalMirror.Binding

  @ptm_table __MODULE__

  @impl true
  def adapter_module, do: Ezagent.ExternalMirror.TestSupport.MockPublishAdapter

  @impl true
  def init({target_id, _adapter, opts}) do
    if reason = Map.get(opts, :fail_init) do
      {:error, reason}
    else
      observer = Map.get(opts, :observer) || lookup_observer(target_id)

      {:ok,
       %{
         target_id: target_id,
         observer: observer,
         opts: opts,
         publish_count: 0
       }}
    end
  end

  @impl true
  def publish(payload, %{opts: opts} = state) do
    cond do
      reason = Map.get(opts, :raise_publish) ->
        raise RuntimeError, message: "MockPublishBinding raise_publish: #{inspect(reason)}"

      reason = Map.get(opts, :fail_publish) ->
        new_state = %{state | publish_count: state.publish_count + 1}
        {:error, reason, new_state}

      true ->
        if is_pid(state.observer) and Process.alive?(state.observer) do
          send(state.observer, {:published, payload, state.target_id, state.publish_count + 1})
        end

        {:ok, %{state | publish_count: state.publish_count + 1}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.observer) and Process.alive?(state.observer) do
      send(state.observer, {:terminated, state.target_id, state.publish_count})
    end

    :ok
  end

  # ----- per-target observer table -----------------------------------------

  @doc """
  Register `test_pid` as the observer for publishes targeting
  `target_id`. Subsequent `init/1` calls for that target_id pull
  the observer from this table.

  Idempotent — repeat with a new pid overwrites. Tests should clear
  the table in setup via `clear_observers/0` (called from
  `Ezagent.ExternalMirror.TestSupport.MockPublishBinding.clear_observers/0`
  in shared test setup).
  """
  @spec register_observer(target_id :: term(), test_pid :: pid()) :: :ok
  def register_observer(target_id, test_pid) when is_pid(test_pid) do
    :persistent_term.put({@ptm_table, target_id}, test_pid)
    :ok
  end

  @doc "Drop the observer for `target_id` (test cleanup)."
  @spec unregister_observer(target_id :: term()) :: :ok
  def unregister_observer(target_id) do
    _ = :persistent_term.erase({@ptm_table, target_id})
    :ok
  end

  defp lookup_observer(target_id) do
    :persistent_term.get({@ptm_table, target_id}, nil)
  end
end
