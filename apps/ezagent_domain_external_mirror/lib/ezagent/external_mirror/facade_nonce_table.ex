defmodule Ezagent.ExternalMirror.FacadeNonceTable do
  @moduledoc """
  `Ezagent.ExternalMirror.FacadeNonceTable` — forgery-proof handoff between
  `Ezagent.ExternalMirror.bind/5` (the facade) and
  `Ezagent.ActionSet.ExternalMirror.invoke(:bind, ...)` (the action body).

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

  ## The `:private`-ETS-nonce pattern (audit-SPEC CRIT-1 corrected shape)

  Per the audit SPEC
  `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
  §3.3, the pre-audit shape used `:protected` ETS + a freely-callable
  `claim_nonce/5` mint operation. Both had structural bypasses:

  1. **`:protected` is world-readable.** Any in-VM caller could
     `:ets.lookup/2` to enumerate live nonces (steal-for-direct-dispatch
     OR consume-delete to DoS the legitimate facade caller). `:private`
     denies all non-owner reads AND writes — only the GenServer owner
     pid can touch the table. External enumeration becomes structurally
     impossible.

  2. **Freely-callable `claim_nonce` was itself a bypass.** Any in-VM
     caller holding ONLY the session bind cap (Gate 1) could call
     `claim_nonce/5` directly to mint a nonce for any
     `(session, adapter, target, caller)` tuple, then direct-dispatch
     `external_mirror.bind` with that nonce, skipping Gates 2+3+4. The
     audit-SPEC CRIT-1 fix: `claim_nonce/4` is no longer a freely-callable
     mint operation — it is THE gate-enforcing entry point. It internally
     runs Gates 1+2+3+4 against the supplied `caller_ctx`. A nonce is
     returned ONLY if ALL four gates pass; otherwise the gate's
     `{:error, reason}` propagates out.

  ## Trust-transfer contract (the corrected shape)

  - `claim_nonce(session_uri, ctx, adapter_module, target_id)` — the
    PUBLIC entry point. Internally calls
    `Ezagent.ExternalMirror.Gates.check_session_bind_cap/2` +
    `check_adapter_allow_cap/3` + `check_workspace_iso/2` +
    `run_target_ownership_check/3` against the caller. Mints +
    inserts a 32-byte nonce ONLY if all 4 gates pass. Returns the
    gate's `{:error, reason}` shape on miss (`:unauthorized` /
    `:adapter_not_authorized` / `:cross_workspace_denied` /
    `{:target_ownership_denied, _}` / `:target_check_timeout` /
    `{:target_check_crashed, _}`).
  - `consume_nonce(nonce, expected_tuple)` — called from the action
    body. Atomically reads + verifies + deletes the row in one
    `handle_call`. Returns `:ok` on success, `:error` otherwise.
    Single-use semantics + replay protection ONLY — NOT a sole
    authorization gate (gates have already run by definition).

  ## Why `:private` ETS + GenServer-only access

  - `:private` lets ONLY the owner pid read AND write. Even the
    BEAM's in-process introspection (`:ets.lookup/2` from another pid)
    is denied. This closes the "steal-a-live-nonce" attack the
    pre-audit `:protected` shape allowed.
  - All reads + writes go through the GenServer's `handle_call`. The
    `consume_nonce/2` path is naturally serialized — two concurrent
    consume attempts for the same nonce: exactly one returns `:ok`,
    the other returns `:error`.
  - `:crypto.strong_rand_bytes(32)` gives 256 bits of entropy.
    Guessing one within the 5-second TTL is infeasible.

  ## Why a 5-second SPEC-pinned TTL (NOT configurable)

  Per the audit SPEC §3.3 / §8.4: TTL is SPEC-pinned at 5 seconds
  and intentionally NOT exposed as a per-deployment config knob (per
  `feedback_let_it_crash_no_workarounds` — config knobs ARE
  workarounds; a deployment needing a different TTL has a structural
  problem in dispatch latency that the SPEC would address by
  changing the dispatch path).

  The window between `claim_nonce/4` and the action body's
  `consume_nonce/2` is bounded by `Invocation.dispatch/1` latency
  (typically < 20ms for a slice mutation + Kind.spawn). 5 seconds is
  ~250× that ceiling — enough headroom for slow CI / debug builds /
  contention storms, but tight enough that a stolen nonce is useless
  within the window of practical exploitation.

  An `@doc false` 5-arity form keeps the `ttl_ms` override available
  for the §6 invariant test (which needs millisecond-level TTLs to
  run in CI). Production callers MUST use the 4-arity form.

  ## Cleanup

  Expired nonces accumulate if no one consumes them (e.g. gates pass
  but the subsequent `Invocation.dispatch` crashes before the action
  body runs). A periodic 30-second sweep deletes expired rows so the
  table doesn't grow unbounded.
  """

  use GenServer

  alias Ezagent.ExternalMirror.Gates

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
  Claim a fresh nonce after running ALL four bind gates against
  `ctx`. Returns `{:ok, nonce}` (32-byte binary) on full pass, or
  the FIRST gate's `{:error, reason}` on miss.

  This is the audit-SPEC CRIT-1 corrected shape: `claim_nonce/4` is
  no longer a "freely callable nonce minter" — it IS the gate
  enforcement entry point. An in-VM caller calling this directly
  must satisfy the same 4 gates as a caller going through the
  `Ezagent.ExternalMirror.bind/5` facade.

  ## codex PR-AUDIT r1 CRIT fix (2026-05-25) — adapter module trust

  The `adapter_id` parameter is a STRING — we resolve it to the real
  `adapter_module` via `AdapterRegistry.lookup/1` here instead of
  trusting a caller-supplied module. Pre-fix, the caller passed in
  the module directly; an in-VM caller could supply a spoof module
  whose `adapter_id/0` returned a real adapter's ID, whose
  `cap_subject/0` named a cap they already hold, and whose
  `target_ownership_check/2` returned `:ok`. The gates passed against
  the spoof, the nonce was minted for the REAL adapter's ID, and the
  action body bound to the real adapter — bypassing its real Cap 2
  + Gate 4. The fix: only the registry's resolved module participates
  in gates 2 and 4.

  See moduledoc + `Ezagent.ExternalMirror.Gates` for the gate
  definitions and `Ezagent.ExternalMirror.bind/5` for the canonical
  caller. The facade is now a thin wrapper that calls this function
  then dispatches with the returned nonce.

  Default TTL is SPEC-pinned at 5 seconds. For test-only millisecond
  TTLs, use the `@doc false` 5-arity form below.
  """
  @spec claim_nonce(URI.t(), Gates.caller_ctx(), String.t(), term()) ::
          {:ok, binary()}
          | {:error,
             :unknown_adapter
             | :unauthorized
             | :adapter_not_authorized
             | :cross_workspace_denied
             | :target_check_timeout
             | {:target_ownership_denied, term()}
             | {:target_check_crashed, term()}}
  def claim_nonce(%URI{} = session_uri, ctx, adapter_id, target_id)
      when is_map(ctx) and is_binary(adapter_id) do
    # codex PR-AUDIT r1 CRIT fix (2026-05-25): resolve adapter_module
    # via AdapterRegistry — never trust the caller. A spoof module
    # whose `adapter_id/0` lies about its identity cannot pass through
    # this path because Gate 2 + Gate 4 run against the REGISTRY-
    # resolved module, not the caller's input.
    #
    # Gates 1+0+2+3+4 in canonical order per Gates.run_all/4 (same
    # ordering as the facade) — the unified Gates SoT means an in-VM
    # caller bypassing the facade by calling claim_nonce/4 directly
    # still cannot get a nonce without passing all 4 gates against
    # the real registry-resolved module.
    do_claim_nonce(session_uri, ctx, adapter_id, target_id, @default_ttl_ms)
  end

  # codex PR-AUDIT r2 HIGH fix (2026-05-25): the TTL-override form
  # is no longer a callable production API. Pre-fix, `claim_nonce/5`
  # was `@doc false` but still publicly callable; a caller currently
  # passing all gates could mint a nonce with arbitrarily long TTL
  # and direct-dispatch later AFTER target membership had been revoked
  # — defeating the SPEC-pinned 5-second stale-authorization bound.
  #
  # Post-fix, the 5-arity form is compile-gated to `Mix.env() == :test`
  # via the conditional `def`/no-op approach below. In production
  # builds (`prod` / `dev`) the 5-arity function clause is NOT defined
  # at all — the BEAM raises `UndefinedFunctionError` on the call.
  # The test suite still has the 5-arity form for the nonce-expiry
  # scenarios that need millisecond TTLs.
  if Mix.env() == :test do
    @doc false
    # Test-only 5-arity form — see audit SPEC §3.3 note + codex r2
    # HIGH. Production callers (`Mix.env() != :test`) cannot invoke
    # this function — it does NOT exist in production binaries.
    @spec claim_nonce(URI.t(), Gates.caller_ctx(), String.t(), term(), pos_integer()) ::
            {:ok, binary()} | {:error, term()}
    def claim_nonce(%URI{} = session_uri, ctx, adapter_id, target_id, ttl_ms)
        when is_map(ctx) and is_binary(adapter_id) and is_integer(ttl_ms) and ttl_ms > 0 do
      do_claim_nonce(session_uri, ctx, adapter_id, target_id, ttl_ms)
    end
  end

  defp do_claim_nonce(%URI{} = session_uri, ctx, adapter_id, target_id, ttl_ms)
       when is_binary(adapter_id) and is_integer(ttl_ms) and ttl_ms > 0 do
    caller_uri = Map.fetch!(ctx, :caller)

    with {:ok, _adapter_module} <-
           Gates.run_all(session_uri, ctx, adapter_id, target_id) do
      GenServer.call(
        __MODULE__,
        {:claim, session_uri, adapter_id, target_id, caller_uri, ttl_ms}
      )
    end
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
        # Audit-SPEC CRIT-1: `:private` denies all non-owner reads
        # AND writes. Pre-fix `:protected` was world-readable, letting
        # any in-VM caller enumerate live nonces.
        :private,
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
