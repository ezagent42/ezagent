defmodule Ezagent.ExternalMirror.FacadeNonceTable do
  @moduledoc """
  `Ezagent.ExternalMirror.FacadeNonceTable` — forgery-proof handoff between
  `Ezagent.ExternalMirror.bind/4` (the facade) and
  `Ezagent.Behavior.ExternalMirror.invoke(:bind, ...)` (the action body).

  ## Why this exists (codex r3 CRIT fix, 2026-05-25)

  Pre-fix, the facade set `args[:_facade_checks_ok] = true` after running
  Check 2 (per-adapter cap) + Check 3 (target_ownership_check). The action
  body trusted that flag. But `args` is caller-controlled at
  `Ezagent.Invocation.dispatch/1` time — any caller holding the session
  `:bind` cap could dispatch directly with `_facade_checks_ok: true` and
  skip BOTH Check 2 and Check 3.

  That's a real authorization bypass — the very Checks the facade exists
  to enforce are forgeable by an in-VM caller. This module replaces the
  flag with an unforgeable token.

  ## The protected-ETS-nonce pattern

  - A `:protected, :named_table` ETS table whose ONLY writer is this
    GenServer. `:protected` semantics: anyone can `:ets.lookup/2`, only
    the table owner can write. Readers (the action body's
    `consume_nonce/2`) use the GenServer call path which is the only
    legitimate consumer.
  - `claim_nonce/4` (called from the facade after Check 3 passes)
    inserts `{nonce, {session_uri, adapter_id, target_id, caller_uri,
    expires_at_monotonic_ms}}` and returns the nonce. The nonce is
    `:crypto.strong_rand_bytes(32)` — unguessable.
  - `consume_nonce/2` (called from the action body) atomically reads,
    verifies the expected tuple matches, checks expiry, and deletes
    the row — all inside the GenServer so the consume is atomic across
    concurrent attempts. Returns `:ok` on success, `:error` otherwise.
  - Replay protection: the nonce is deleted on first consume, so a
    second dispatch with the same nonce → no row → `:error`.
  - Expiry protection: every claim carries `expires_at_monotonic_ms`;
    consume rejects if `System.monotonic_time(:millisecond) >= expires_at`.

  ## Why not `:public` ETS with raw `:ets.insert/2` from the facade?

  Two reasons:

  1. `:public` lets any in-VM caller forge a nonce (write `{any_nonce,
     {their_session, their_adapter, their_target, their_caller, far_future}}`
     directly). That's the same threat shape as the original
     `_facade_checks_ok` flag — caller controls the bypass.
  2. `:protected` with a GenServer-owned writer is structurally
     unforgeable: the writer process holds the table owner pid, ALL
     inserts go through the GenServer's `handle_call`, and the nonce
     bytes themselves are 32 bytes of `:crypto.strong_rand_bytes` so
     guessing one would require breaking the RNG.

  This pattern mirrors PR-EM-1's `AdapterRegistry` (also ETS-backed)
  but tightens the access mode from `:public` to `:protected` —
  AdapterRegistry tolerates `:public` because its data is non-sensitive
  (display names + module atoms operators may legitimately enumerate);
  the nonce table cannot tolerate forgery so it MUST be `:protected`.

  ## Cleanup

  Expired nonces accumulate if no one consumes them (e.g. facade
  Check 3 succeeds but the subsequent Invocation.dispatch crashes
  before the action body runs). A periodic 30-second sweep deletes
  expired rows so the table doesn't grow unbounded.

  ## Why a 5-second default TTL

  The window between `claim_nonce/4` and the action body's
  `consume_nonce/2` is bounded by `Invocation.dispatch/1` latency
  (typically < 20ms for a slice mutation + Kind.spawn). 5 seconds is
  ~250× that ceiling — enough headroom for slow CI / debug builds /
  contention storms, but tight enough that a stolen nonce is useless
  within the window of practical exploitation.
  """

  use GenServer

  @table :ezagent_external_mirror_facade_nonce_table
  @default_ttl_ms 5_000
  @sweep_interval_ms 30_000

  # ----- Public API ---------------------------------------------------------

  @doc "Start the FacadeNonceTable GenServer. Owned by the Domain Application."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Claim a fresh nonce. Returns `{:ok, nonce}` where `nonce` is a 32-byte
  binary. The facade caller then passes the nonce in
  `args[:_facade_nonce]` when dispatching the `:bind` Invocation; the
  action body atomically consumes it via `consume_nonce/2`.

  `ttl_ms` defaults to 5_000ms (5 seconds — see moduledoc).
  """
  @spec claim_nonce(URI.t(), String.t(), term(), URI.t(), pos_integer()) ::
          {:ok, binary()}
  def claim_nonce(
        %URI{} = session_uri,
        adapter_id,
        target_id,
        %URI{} = caller_uri,
        ttl_ms \\ @default_ttl_ms
      )
      when is_binary(adapter_id) and is_integer(ttl_ms) and ttl_ms > 0 do
    GenServer.call(
      __MODULE__,
      {:claim, session_uri, adapter_id, target_id, caller_uri, ttl_ms}
    )
  end

  @doc """
  Atomically consume a nonce. Returns `:ok` iff:

  - the nonce exists in the table (not yet consumed, not yet swept)
  - the stored tuple matches `expected_tuple` exactly
  - the stored `expires_at` has not passed

  Returns `:error` in all other cases (missing / expired / mismatched
  tuple / replay).

  `expected_tuple = {session_uri, adapter_id, target_id, caller_uri}`.
  """
  @spec consume_nonce(binary(), {URI.t(), String.t(), term(), URI.t()}) :: :ok | :error
  def consume_nonce(nonce, {%URI{}, _, _, %URI{}} = expected_tuple) when is_binary(nonce) do
    GenServer.call(__MODULE__, {:consume, nonce, expected_tuple})
  end

  def consume_nonce(_, _), do: :error

  @doc false
  # Test-only — clears all in-flight nonces. Used by the facade test
  # to set up "no leftover state" between cases.
  @spec __clear_all__() :: :ok
  def __clear_all__ do
    GenServer.call(__MODULE__, :clear_all)
  end

  # ----- GenServer callbacks ------------------------------------------------

  @impl GenServer
  def init(_opts) do
    tid =
      :ets.new(@table, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    schedule_sweep()
    {:ok, %{table: tid}}
  end

  @impl GenServer
  def handle_call({:claim, session_uri, adapter_id, target_id, caller_uri, ttl_ms}, _from, state) do
    nonce = :crypto.strong_rand_bytes(32)
    expires_at = System.monotonic_time(:millisecond) + ttl_ms

    :ets.insert(state.table, {
      nonce,
      {session_uri, adapter_id, target_id, caller_uri, expires_at}
    })

    {:reply, {:ok, nonce}, state}
  end

  def handle_call({:consume, nonce, expected_tuple}, _from, state) do
    result =
      case :ets.lookup(state.table, nonce) do
        [{^nonce, stored}] ->
          # Delete first (replay-protection) so even if the next branch
          # decides the tuple/expiry is wrong, the nonce is single-use.
          :ets.delete(state.table, nonce)
          verify(stored, expected_tuple)

        [] ->
          :error
      end

    {:reply, result, state}
  end

  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:sweep, state) do
    now_ms = System.monotonic_time(:millisecond)

    # `:ets.select_delete/2` is atomic — sweeps all expired rows in one
    # pass. Match spec: select-delete rows whose 5th element of the
    # value tuple (`expires_at`) is <= now_ms.
    match_spec = [
      {{:"$1", {:"$2", :"$3", :"$4", :"$5", :"$6"}}, [{:"=<", :"$6", now_ms}], [true]}
    ]

    _ = :ets.select_delete(state.table, match_spec)
    schedule_sweep()
    {:noreply, state}
  end

  # ----- internals ----------------------------------------------------------

  defp verify({session_uri, adapter_id, target_id, caller_uri, expires_at}, expected_tuple) do
    {exp_session, exp_adapter, exp_target, exp_caller} = expected_tuple
    now_ms = System.monotonic_time(:millisecond)

    cond do
      now_ms > expires_at ->
        :error

      not uri_eq?(session_uri, exp_session) ->
        :error

      adapter_id != exp_adapter ->
        :error

      target_id != exp_target ->
        :error

      not uri_eq?(caller_uri, exp_caller) ->
        :error

      true ->
        :ok
    end
  end

  defp uri_eq?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp uri_eq?(_, _), do: false

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
