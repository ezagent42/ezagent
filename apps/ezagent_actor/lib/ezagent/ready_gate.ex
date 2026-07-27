defmodule Ezagent.ReadyGate do
  @moduledoc """
  ReadyGate — ETS-backed three-state map per Kind instance URI.

  States: `:unknown` (default for unseen URIs), `:not_ready` (registered
  but not yet announced ready — see `Ezagent.Kind.Server` init), `:ready`
  (announced), `:failed` (readiness gate exhausted).

  Used by `Ezagent.Invocation.dispatch/1` to decide:
  - `:not_ready` + `:cast` → buffer to `Ezagent.PendingDelivery`
  - `:not_ready` + `:call` → fail-fast (hard invariant #3)
  - `:ready` → proceed to GenServer.call/cast

  Owned by `EzagentActor.EtsOwner` (single shared GenServer per
  DECISIONS implementation-decision §ETS table owner — Option B).
  """

  @table :ezagent_ready_gate
  @external_gates_key {__MODULE__, :external_gates}

  @type status :: :unknown | :not_ready | :ready | :failed

  @doc "ETS table name — for `EzagentActor.EtsOwner` to create at boot."
  def table, do: @table

  @doc """
  Current status of a URI. Returns `:unknown` if no entry exists.

  Accepts a `%URI{}` or its string form; both normalise to the string key.
  """
  @spec status(URI.t() | String.t()) :: status()
  def status(uri) do
    case :ets.lookup(@table, key(uri)) do
      [{_, s}] -> s
      [] -> :unknown
    end
  end

  @doc "Set a URI's status. Idempotent."
  @spec put(URI.t() | String.t(), status()) :: :ok
  def put(uri, status) when status in [:unknown, :not_ready, :ready, :failed] do
    :ets.insert(@table, {key(uri), status})
    :ok
  end

  @doc "Convenience for `put(uri, :ready)`."
  @spec mark_ready(URI.t() | String.t()) :: :ok
  def mark_ready(uri), do: put(uri, :ready)

  @doc "Convenience for `put(uri, :failed)`."
  @spec mark_failed(URI.t() | String.t()) :: :ok
  def mark_failed(uri), do: put(uri, :failed)

  @doc """
  Register a module that can defer a Kind's ready flip on an external condition.

  Gate modules implement `defer_ready?/1` and return `:ready` or
  `{:defer, timeout_ms}`. They may also implement `await_transport_or_fail/1`;
  `Kind.Server` uses that when a gate defers.
  """
  @spec register_external_gate(module()) :: :ok
  def register_external_gate(module) when is_atom(module) do
    gates = external_gates()
    :persistent_term.put(@external_gates_key, Enum.uniq([module | gates]))
    :ok
  end

  @doc false
  @spec external_gate(URI.t() | String.t()) :: :ready | {:defer, module(), pos_integer()}
  def external_gate(uri) do
    Enum.find_value(external_gates(), :ready, fn module ->
      if Code.ensure_loaded?(module) and function_exported?(module, :defer_ready?, 1) do
        case module.defer_ready?(uri) do
          :ready -> false
          {:defer, ms} when is_integer(ms) and ms > 0 -> {:defer, module, ms}
          _ -> false
        end
      else
        false
      end
    end)
  end

  defp external_gates do
    :persistent_term.get(@external_gates_key, [])
  end

  @doc """
  Block (with bounded polling) until `uri` reaches `:ready` status.

  Returns `:ok` when the URI flips to `:ready`, or `{:error, :timeout}`
  if the bound is exhausted. The bound is expressed in milliseconds;
  polling is a 10ms `Process.sleep` loop (low overhead, the wait is
  expected to be short).

  This is the canonical helper for callers that just spawned a Kind
  (e.g. via `SpawnRegistry.spawn_detailed/1`) and need to dispatch a
  follow-up `:call`-mode action against it BEFORE the dispatch path's
  `{:not_ready, :call}` fail-fast (hard invariant #3) fires. The
  post-spawn `handle_continue` chain (post_init Behaviors + ReadyGate
  flip) runs asynchronously after `start_link` returns; this helper
  closes the timing gap structurally instead of forcing every caller
  to re-implement the same `:not_ready` retry loop (the duplicated
  pattern in `Ezagent.Identity.await_ready/2` motivated lifting this
  into a public helper, codex E2E fix v2 Bug A 2026-05-29).

  ## Why call-mode + `:not_ready` is a race, not a contract violation

  - Step 1 — `Kind.Server.init/1` synchronously registers the URI in
    `KindRegistry` and calls `ReadyGate.put(uri, :not_ready)`.
  - Step 2 — `init/1` returns `{:ok, state, {:continue, :announce_ready}}`
    BEFORE the post-init Behaviors run.
  - Step 3 — `start_link` returns `{:ok, pid}` to the spawner.
  - Step 4 — the spawner now holds the pid AND the URI but
    `ReadyGate.status(uri)` is still `:not_ready`. A `:call` dispatch
    here fails fast with `{:error, :not_ready}` even though the Kind
    is fully constructed and the message would have succeeded a few
    ms later.

  Bounded waits are the structural answer — `:call` cannot buffer
  (the caller is synchronously waiting on the result, so there's no
  receiver for a delayed reply if the call has already returned).

  ## Bound

  Default `500ms` matches the empirical bound used by
  `Ezagent.Identity.await_ready/2` (50 × 10ms). post_init handlers
  do a single DB PK lookup + slice mutation, so 500ms is generous
  even under contention.

  Test environments can override (`await(uri, 5_000)`) when the
  ExUnit sandbox / DBConnection checkout can stretch handle_continue.
  """
  @spec await(URI.t() | String.t(), timeout_ms :: pos_integer()) ::
          :ok | {:error, :timeout}
  def await(uri, timeout_ms \\ 500) when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(uri, deadline)
  end

  defp do_await(uri, deadline) do
    case status(uri) do
      :ready ->
        :ok

      _ ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :timeout}
        else
          # 10ms poll — short enough that the typical 1-2ms post_init
          # finishes inside one iteration; long enough that we don't
          # burn CPU.
          Process.sleep(10)
          do_await(uri, deadline)
        end
    end
  end

  defp key(%URI{} = uri), do: URI.to_string(uri)
  defp key(uri) when is_binary(uri), do: uri
end
