defmodule Ezagent.ActionSet.ExternalMirror do
  @moduledoc """
  `Ezagent.ActionSet.ExternalMirror` — the bind/unbind/list Behavior on
  the Session Kind.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §4.1 / §4.2 / §8.2 (r6 facade) / §3.1 (rehydration) / §9 PR-EM-3.

  ## Three actions

  | Action          | Mode  | Purpose                                                       |
  |-----------------|-------|---------------------------------------------------------------|
  | `:bind`         | `:call` | Append `(adapter_id, target_id, opts)` to the session slice |
  | `:unbind`       | `:call` | Remove a binding + tear down its Worker process             |
  | `:list_bindings`| `:call` | Read all bindings on this session                            |

  ## Two-step bind flow (r6 HIGH-2 fix + r3 CRIT fix)

  `:bind` is dispatched ONLY AFTER `Ezagent.ExternalMirror.bind/4`
  (the facade in `Ezagent.ExternalMirror`) has run Check 2 (per-adapter
  allow cap) + Check 3 (`target_ownership_check/2` in a supervised
  Task with bounded timeout). The facade then claims a single-use
  nonce from `Ezagent.ExternalMirror.FacadeNonceTable` (32 random
  bytes, 5-second TTL, bound to the exact
  `(session_uri, adapter_id, target_id, caller_uri)` tuple) and
  injects it as `args[:_facade_nonce]`. This Behavior atomically
  consumes the nonce; ANY of {missing, expired, tuple-mismatch,
  replay} → `{:error, :bind_must_go_through_facade}`.

  ### codex r3 CRIT fix (2026-05-25) — why a nonce, not a flag

  Pre-fix, the facade used `args[:_facade_checks_ok] = true`. But
  `args` is caller-controlled at `Invocation.dispatch/1` time — any
  caller holding the session `:bind` cap could dispatch directly with
  the flag set and SKIP Checks 2 and 3. Real auth bypass.

  The nonce is forgery-proof: the FacadeNonceTable's ETS is
  `:protected` (only the FacadeNonceTable GenServer can insert), the
  nonce is 32 bytes of `:crypto.strong_rand_bytes`, and it's bound to
  the exact tuple the facade validated — so an attacker can't reuse
  one nonce for a different (target_id, adapter_id) pair.

  The central `Ezagent.Cap.Verifier` enforces
  Check 1 (session-level `Behavior.ExternalMirror` bind cap) BEFORE
  the action body runs — that's the dispatch-side gate every
  Behavior naturally inherits. Step 5.6 handles cross-workspace
  denial (test g).

  ## Slice — `:external_mirror` on Session

      %{
        bindings: [
          %{
            binding_id:  String.t(),   # "<adapter_id>/<target_id>" (slice key)
            adapter_id:  String.t(),
            target_id:   term(),
            opts:        map(),
            bound_by:    URI.t(),
            bound_at:    DateTime.t()
          },
          ...
        ]
      }

  Per **P3** (single source of truth), this slice IS the source of
  truth for bindings; `external_mirror_bindings` (DB) is the
  projection written by `:bind` / `:unbind` action bodies.

  ## Rehydration (§3.1 r4 HIGH-3 fix)

  `init_slice/1` reads the projection table on Session Kind init and
  populates `slice.bindings`. It ALSO returns
  `{:continue, :reconcile_external_mirror_workers}` from `post_init/2`
  to schedule the worker spawn loop AFTER `:announce_ready`; the
  `handle_continue/3` callback walks the slice and idempotently
  `Kind.spawn/2`s each Worker. Per P16, `Kind.spawn/2` is idempotent —
  a Worker already running is a no-op; a Worker absent (post-restart)
  spawns under the two-tier RootSupervisor → PerBindingSupervisor.

  ## data_owner/1 (caps-data-ownership)

  Session URI → that session's owner (`:owner_uri` in the `:chat`
  slice). Per the SPEC §4.1: an external-mirror binding on session S
  is owned by S's owner, so only the owner can grant
  `Behavior.ExternalMirror` caps on S.

  We read the owner via `Ezagent.Kind.read/3` (`spawn: :never`) rather than
  `Ezagent.Entity.Session.owner/1` to avoid a runtime call into
  `:ezagent_domain_session` (Mix-dep cycle — see
  `apps/ezagent_domain_external_mirror/mix.exs` moduledoc).
  """

  use Ezagent.Lifecycle

  require Logger

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRow, FacadeNonceTable, WorkerSpawn}
  alias Ezagent.ActionSet.ExternalMirror.Codec

  # ----- Ezagent.Lifecycle contract (Phase B lifecycle migration) ---------
  #
  # SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §2.3
  # / §5 / §10-R1. Converted from `use Ezagent.ActionSet`.
  #
  # Two-container split (SPEC §0.1 / §2.1):
  #
  #   - `state` (PERSISTENT): `bindings` — the binding list. Per P3 this
  #     slice IS the source of truth in memory; `external_mirror_bindings`
  #     (DB) is the projection it caches (OQ-8 DB-projection Behavior).
  #   - `transients`: NONE. This Behavior holds no live handle of its own
  #     — it SPAWNS Worker Kinds (whose pids the supervisor owns) but never
  #     caches one. So `activate/2` returns an empty transients map.
  #
  # `create/1` ← `init_slice/1`: re-read the DB projection on first-ever
  # existence (auto-persisted thereafter).
  #
  # `activate/2` (SPEC §5 step 5 / OQ-8) UNIFIES the old `init_slice` DB
  # read + `reconcile_after_load/2`: re-read the SoT projection every start
  # and union it (idempotent, by binding_id — invariant 20) into the
  # rehydrated `state.bindings`, returning the reconciled state via the
  # 3-arity `{:ok, transients, state}` form. This SUBSUMES
  # `reconcile_after_load/2` (which no longer exists as an engine callback);
  # the reconcile LOGIC lives in `reconcile_bindings/2` (callable directly
  # for the unit test).
  #
  # §10-R1 (CRITICAL — self-deferred post-ready work): the old
  # `handle_continue/3` did `send(self(), {:ezagent_em_reconcile, …})` to
  # DEFER the worker-spawn loop past `:ready` (the workers' subscribe
  # `:call` hits the SESSION which must be `:ready`). That defer is
  # PRESERVED: `activate/2` (pre-`:ready`) reconciles state and then
  # `send(self(), {:ezagent_em_reconcile, bindings})`; the mailbox message
  # drains AFTER the host is `:ready` and is handled by `handle_signal/2`,
  # which runs the idempotent `Kind.spawn/2` loop. The worker-spawn does
  # NOT go in `activate` (which is pre-`:ready`).
  #
  # `handle_<action>/2` reads state via `ctx.read.(:key, default)` and
  # returns `{:ok, result, [effect]}` with `{:set, :bindings, _}` for the
  # slice mutation (SPEC §4.4 effect grammar).

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # ExternalMirror is registered on Session Kind only — kind axis is
  # `:session`. We use atom `:caps` here so the macro generates a clean
  # `actions/0` + `interface/0` + `cap_subjects/0`; the kind axis lives
  # in our explicit `required_caps/0` override below (the macro's
  # auto-derived version defaults to `kind: :any` and would lose the
  # `:session` scoping the dispatcher enforces at step 5.5).
  action(:bind,
    args: %{adapter_id: :string, target_id: :string, opts: :map},
    returns: %{ok: :boolean, binding_id: :string, worker_uri: :uri},
    caps: [:bind],
    modes: [:call],
    description: "Bind this session's slice changes to an external adapter target."
  )

  action(:unbind,
    args: %{adapter_id: :string, target_id: :string},
    returns: %{ok: :boolean, unbound: :boolean},
    caps: [:unbind],
    modes: [:call],
    description: "Remove an (adapter_id, target_id) binding from this session."
  )

  action(:list_bindings,
    args: %{},
    returns: %{bindings: {:list, :map}},
    caps: [:list_bindings],
    modes: [:call],
    description: "List all external-mirror bindings on this session."
  )

  # Remediation SPEC 2026-05-30 (C-A): `:bind` reads the SESSION's
  # `:publisher` sibling slice to capture its CURRENT cursor at bind time,
  # so the freshly-spawned Worker subscribes FROM that cursor. The Worker's
  # subscribe is now deferred off its GenServer (to avoid the unbind
  # deadlock — see ExternalMirrorWorker.activate/2), which opens a small
  # spawn→subscribe window where a slice change could land in the Publisher
  # ring before the Worker is in the subscribers map. Subscribing from the
  # bind-point cursor REPLAYS exactly that window (cursor-based catch-up) —
  # no first-event loss. `ctx.siblings[:publisher][:cursor]` is the
  # T3-normalized persistent cursor (invariant 18 — declared key only).
  reads_siblings([:publisher])

  # Explicit override — the macro's auto-derived `required_caps/0` would
  # use `kind: :any` per `build_required_cap_ast/3`. ExternalMirror is
  # registered on Session Kind only; pin `:session` so step 5.5's
  # axis-derivation matches the dispatch shape.
  def required_caps do
    %{
      bind: Ezagent.Capability.cap(:session, __MODULE__, :bind),
      unbind: Ezagent.Capability.cap(:session, __MODULE__, :unbind),
      list_bindings: Ezagent.Capability.cap(:session, __MODULE__, :list_bindings)
    }
  end

  # state_slice/0 is AUTO-DERIVED: `Ezagent.ActionSet.ExternalMirror` →
  # `:external_mirror` — identical to the pre-migration explicit
  # `def state_slice, do: :external_mirror`. Snapshot key unchanged; no
  # override needed (SPEC §5 step 2 / A5 verdict).

  # `create/1` ← `init_slice/1`: rehydrate the binding LIST from the DB
  # projection on first-ever existence (§3.1 r4 HIGH-3 fix). The WORKER
  # spawn loop is deferred (§10-R1) to `handle_signal/2` via the
  # self-message that `activate/2` sends.
  @impl Ezagent.Lifecycle
  def create(args) do
    session_uri = Map.fetch!(args, :uri)

    bindings =
      session_uri
      |> BindingRow.list_for_session()
      |> Enum.map(&Codec.row_to_slice_binding/1)

    {:ok, %{bindings: bindings}}
  rescue
    # DB unavailable at boot (Ecto Sandbox not checked out, repo not
    # started, etc.) — start with an empty list. The snapshot path
    # repopulates on first mutation; activate/2's reconcile re-reads the
    # SoT on the next start. Matches the existing `bind_session_workspace/1`
    # boot tolerance pattern in `EzagentDomainInstanceMessage.Application`.
    _ ->
      {:ok, %{bindings: []}}
  end

  @doc """
  `activate/2` (SPEC §5 step 5 / OQ-8 / §10-R1) — the UNIFIED start hook.

  1. RECONCILE (subsumes the old `reconcile_after_load/2`): re-read the DB
     projection SoT and idempotently union it into the rehydrated
     `state.bindings` (dedupe by binding_id — invariant 20). On a cold-load
     the snapshot merge has already shadowed `create/1`'s state with the
     rehydrated `state`; we re-read here because rows inserted between the
     last snapshot and this restart would otherwise be lost.
  2. DEFER the worker-spawn loop past `:ready` (§10-R1): `send(self(),
     {:ezagent_em_reconcile, bindings})`. activate is PRE-`:ready`, so we
     must NOT `Kind.spawn/2` here — each Worker's own activate subscribes
     to THIS Session's Publisher (`:call`), which would hit `:not_ready`.
     The mailbox message drains AFTER the host is `:ready` and is handled
     by `handle_signal/2`.

  No transients → returns `{:ok, %{}, reconciled_state}` (3-arity, so the
  reconciled `state.bindings` is committed).
  """
  @impl Ezagent.Lifecycle
  def activate(state, %{self_uri: session_uri}) do
    reconciled = reconcile_bindings(session_uri, state)

    # §10-R1: defer the worker-spawn loop to post-`:ready`. The zero-delay
    # `Signal.send_after/2` self-signal (V5 use-side B2) targets `self()`
    # directly — the Kind.Server pid — `:ready` by the time the mailbox
    # drains; the envelope clause unwraps it back to
    # `{:ezagent_em_reconcile, reconciled.bindings}`.
    EzagentActor.Signal.send_after({:ezagent_em_reconcile, reconciled.bindings}, 0)

    {:ok, %{}, reconciled}
  end

  @doc """
  Reconcile the binding list against the DB projection SoT (Task #34 /
  OQ-8 / invariant 20). This is the reconcile LOGIC that was the
  `reconcile_after_load/2` engine callback pre-migration; under Lifecycle
  it is folded into `activate/2` (which calls this) but kept as a public
  function with the same `(session_uri, state)` arg order so the reconcile
  unit test calls it directly. Re-reads the projection rows for the
  session and unions them into the slice, deduping by `binding_id`
  (idempotent — a normal-path bind where the snapshot already captured the
  binding is a no-op union; bypass paths get the new binding pulled in for
  `handle_signal/2` to spawn the worker).
  """
  def reconcile_bindings(%URI{} = session_uri, state) when is_map(state) do
    # The DB projection (`external_mirror_bindings`) is the SoT (P3); the
    # `:bindings` slice key is the in-memory CACHE of it. On a cold-load of
    # an OLD-shape snapshot the rehydrated `state` may LACK `:bindings`
    # entirely (the key was added after the snapshot, or the slice persisted
    # as empty `%{}`). `create/1` is skipped on `ever_created?`, so this is
    # the ONLY place the slice shape is re-established — reconcile must
    # materialize `:bindings` from the SoT rather than pass through a
    # `:bindings`-less map (which made `activate/2`'s `reconciled.bindings`
    # raise KeyError — Track #14). Treating an absent cache as `[]` is the
    # correct reconcile semantics: union the full SoT in. This is NOT a
    # defaulting shim — it is the materialize-from-SoT contract (SPEC OQ-8).
    existing = Map.get(state, :bindings, [])

    db_bindings =
      session_uri
      |> BindingRow.list_for_session()
      |> Enum.map(&Codec.row_to_slice_binding/1)

    existing_ids = MapSet.new(existing, & &1.binding_id)

    additions =
      Enum.reject(db_bindings, fn b -> MapSet.member?(existing_ids, b.binding_id) end)

    Map.put(state, :bindings, existing ++ additions)
  rescue
    # DB unavailable — keep whatever cache the snapshot held, but still
    # guarantee the `:bindings` key exists so `activate/2` never crashes
    # on `reconciled.bindings`. Same boot tolerance as `create/1`'s rescue.
    _ -> Map.put_new(state, :bindings, [])
  end

  # Non-URI session arg (no SoT to read) — guarantee the slice carries a
  # `:bindings` key without touching the DB.
  def reconcile_bindings(_session_uri, state) when is_map(state),
    do: Map.put_new(state, :bindings, [])

  def reconcile_bindings(_session_uri, state), do: state

  @doc """
  Mailbox handler (`handle_signal/2`, the `handle_kind_message/3`
  successor) for the deferred reconciliation message scheduled from
  `activate/2` (§10-R1). Walks the binding list + idempotently spawns each
  Worker. By the time this runs, the Session is `:ready` so the Workers'
  subscribe calls succeed.

  Skips rows whose adapter isn't (yet) in `AdapterRegistry` — the Worker's
  `activate/2` would raise on `AdapterRegistry.lookup!/1` per SPEC §5.2,
  exhaust the PerBindingSupervisor budget, and potentially cascade up to
  RootSupervisor. Plugin authors expecting their adapter to be registered
  must ensure the plugin boots BEFORE any session referencing it
  rehydrates — V1 single-node, the umbrella's mix.exs dep edges control
  this.

  Returns `:ignore` (no slice mutation) — the spawn loop is pure side
  effect (idempotent `Kind.spawn/2`); the binding list is already
  committed by `activate/2`'s reconcile.
  """
  @impl Ezagent.Lifecycle
  def handle_signal({:ezagent_em_reconcile, bindings}, %{self_uri: session_uri}) do
    Enum.each(bindings, fn binding ->
      case AdapterRegistry.lookup(binding.adapter_id) do
        {:ok, _module} ->
          # codex r4 HIGH-2 (2026-05-25): spawn may return
          # `{:error, :worker_spawn_failed}` after retry exhaustion.
          # In the rehydration path we just log + skip — the next
          # adapter install or admin retry will re-attempt. The
          # binding row already exists in the projection table.
          case spawn_worker_idempotently(session_uri, binding) do
            :ok ->
              :ok

            {:error, :worker_spawn_failed} ->
              Logger.warning(
                "Behavior.ExternalMirror: rehydration spawn failed for " <>
                  "#{URI.to_string(session_uri)}/#{binding.adapter_id}/" <>
                  "#{inspect(binding.target_id)} — will retry on next event"
              )
          end

        :error ->
          Logger.debug(
            "Behavior.ExternalMirror: skipping rehydration for unregistered adapter " <>
              "#{inspect(binding.adapter_id)} on #{URI.to_string(session_uri)} — " <>
              "adapter not in registry (plugin not booted?)"
          )
      end
    end)

    :ignore
  end

  def handle_signal(_other, _ctx), do: :ignore

  # ----- The :bind action ---------------------------------------------------

  # `invoke/4` was replaced (pre-Lifecycle) by per-action
  # `handle_<action>/2` handlers. Each handler reads state via
  # `ctx.read.(:key, default)` and returns `{:ok, result, [effect]}` where
  # slice mutations are encoded as `{:set, key, value}` effects per the
  # SPEC §4.4 grammar.
  #
  # The pre-migration body shape (slice in, new_slice out) is preserved
  # internally by `do_bind` / `do_unbind` for diff-minimisation; the
  # action handlers reconstruct the slice from `ctx.read` and translate the
  # new_slice return into `{:set, :bindings, _}` effects.

  def handle_bind(args, ctx) do
    # codex r3 CRIT fix (2026-05-25): atomic single-use nonce check
    # replaces the forgeable `_facade_checks_ok` flag. The facade
    # (Ezagent.ExternalMirror.bind/4) is the ONLY legitimate
    # claim_nonce caller; we verify the nonce matches the EXACT tuple
    # (session_uri, adapter_id, target_id, caller_uri) the facade
    # validated. Any divergence (forgery / expiry / replay / tuple
    # mismatch) → refuse.
    aid = Map.get(args, :adapter_id)
    tid = Map.get(args, :target_id)
    caller_uri = Map.get(ctx, :caller)
    session_uri = Map.get(ctx, :self_uri) || Map.get(ctx, :target_uri)
    nonce = Map.get(args, :_facade_nonce)

    expected = {session_uri, aid, tid, caller_uri}

    case nonce_consume(nonce, expected) do
      :ok ->
        slice = read_slice(ctx)
        translate_invoke_return(do_bind(slice, args, ctx))

      :error ->
        # Let-it-crash-style refusal: bind MUST go through the
        # `Ezagent.ExternalMirror.bind/4` facade so Checks 2 + 3
        # (per-adapter cap + target ownership) are enforced. A
        # direct dispatch bypasses those — refuse loudly.
        {:error, :bind_must_go_through_facade}
    end
  end

  def handle_unbind(%{adapter_id: aid, target_id: tid}, ctx) do
    session_uri = Map.get(ctx, :self_uri) || Map.fetch!(ctx, :target_uri)
    slice = read_slice(ctx)
    translate_invoke_return(do_unbind(slice, aid, tid, session_uri))
  end

  def handle_list_bindings(_args, ctx) do
    bindings = ctx.read.(:bindings, [])
    {:ok, %{bindings: bindings}, []}
  end

  # Reconstruct the in-memory slice shape `do_bind` / `do_unbind`
  # expect (a map with `:bindings`). The runtime's `ctx.read` is a
  # `(key, default) -> value` accessor over the persistent `state`; only
  # `:bindings` is in this Behavior's state.
  defp read_slice(ctx) do
    %{bindings: ctx.read.(:bindings, [])}
  end

  # Remediation SPEC 2026-05-30 (C-A) — read the SESSION's current publisher
  # cursor from the `:publisher` sibling slice (declared via
  # `reads_siblings`). `ctx.siblings[:publisher]` is the T3-normalized
  # persistent view (`%{cursor, ring, retention}`). Defaults to `:latest`
  # when the publisher slice isn't present yet (brand-new Session) or
  # siblings weren't injected (unit-test ctx) — "from now", correct since
  # there are no prior events to miss.
  defp sibling_publisher_cursor(ctx) do
    case Map.get(ctx, :siblings, %{}) do
      %{publisher: %{cursor: cursor}} when is_integer(cursor) -> cursor
      _ -> :latest
    end
  end

  # Translate the legacy `{:ok, new_slice, result} | {:error, _}` shape
  # `do_bind` + `do_unbind` return into the new-contract
  # `{:ok, result, [effect]} | {:error, _}` shape. The single slice
  # mutation is encoded as `{:set, :bindings, new_slice.bindings}` —
  # the only slice field this Behavior owns.
  defp translate_invoke_return({:ok, new_slice, result}) when is_map(new_slice) do
    {:ok, result, [{:set, :bindings, Map.get(new_slice, :bindings, [])}]}
  end

  defp translate_invoke_return({:error, _reason} = err), do: err

  defp nonce_consume(nonce, {%URI{}, aid, _tid, %URI{}} = expected)
       when is_binary(nonce) and is_binary(aid) do
    FacadeNonceTable.consume_nonce(nonce, expected)
  end

  defp nonce_consume(_, _), do: :error

  defp do_bind(slice, args, ctx) do
    aid = Map.fetch!(args, :adapter_id)
    tid = Map.fetch!(args, :target_id)
    opts = Map.get(args, :opts, %{})
    caller_uri = Map.fetch!(ctx, :caller)

    # `ctx.self_uri` is the canonical access pattern for the dispatched
    # Kind's own URI (e.g. `Chat.invoke(:join, _, _, ctx)` reads it the
    # same way at chat.ex:385). For PR-EM-3 this IS the session URI
    # since the Behavior is registered against `Ezagent.Entity.Session`.
    session_uri = Map.fetch!(ctx, :self_uri)
    binding_id = BindingRow.binding_id(aid, tid)

    # Remediation SPEC 2026-05-30 (C-A): capture the SESSION's CURRENT
    # publisher cursor (sibling read, declared via `reads_siblings`) so the
    # freshly-spawned Worker subscribes FROM this cursor — replaying any
    # slice change that lands during the Worker's deferred-subscribe window
    # (no first-event loss, no old-history replay). `:latest` when there is
    # no publisher slice / cursor yet (brand-new Session — nothing to miss).
    initial_cursor = sibling_publisher_cursor(ctx)

    case Enum.find(slice.bindings, fn b -> b.binding_id == binding_id end) do
      %{} = existing ->
        # Already bound — idempotent success (concurrent :bind for
        # the same triple lands here on the second call). Confirm
        # the worker is alive (defensive — if it died between
        # rehydrate + this dispatch, respawn now).
        case spawn_worker_idempotently(session_uri, existing, initial_cursor) do
          :ok ->
            worker_uri = WorkerSpawn.worker_uri_for(session_uri, aid, tid)

            {:ok, slice,
             %{ok: true, binding_id: binding_id, worker_uri: worker_uri, idempotent: true}}

          {:error, :worker_spawn_failed} = err ->
            # codex r4 HIGH-2: don't claim idempotent success when
            # the worker is actually dead. Slice already carries the
            # binding row; the next bind attempt will retry spawn.
            err
        end

      nil ->
        bound_at = DateTime.utc_now()

        binding = %{
          binding_id: binding_id,
          adapter_id: aid,
          target_id: tid,
          opts: opts,
          bound_by: caller_uri,
          bound_at: bound_at
        }

        # codex r5 HIGH-B (2026-05-25): persist-FIRST, spawn-AFTER
        # with explicit changeset error discrimination + compensating
        # delete on spawn failure.
        #
        # PRE-FIX (r4): spawn → persist. Two latent bugs:
        # (1) Worker spawn succeeded, then DB insert failed →
        #     orphan worker with no DB row; after restart the
        #     rehydration path (init_slice) couldn't see this
        #     binding → silent loss.
        # (2) `persist_binding_row` swallowed ANY `{:error, changeset}`
        #     as `:ok` for unique-constraint idempotency, but the
        #     mapping was BLANKET — a NOT NULL / FK / other changeset
        #     error also returned `:ok` → row never created, bind
        #     claimed success, observably broken state.
        #
        # POST-FIX:
        #   - Persist FIRST. DB-level atomicity guarantees either the
        #     row exists (then we spawn) or we have a clear error to
        #     return (no worker leaked because no worker spawned yet).
        #   - Match ONLY unique-constraint errors as idempotency
        #     success. Every other changeset error → return
        #     `{:error, {:db_insert_failed, _}}`.
        #   - If spawn fails AFTER persist succeeded, run a
        #     compensating delete on the row so the projection table
        #     stays consistent with the live worker population (no
        #     "binding row but no worker" state).
        case insert_binding_row(session_uri, binding) do
          {:ok, :persisted} ->
            do_spawn_after_persist(
              session_uri,
              binding,
              slice,
              aid,
              tid,
              binding_id,
              initial_cursor
            )

          {:ok, :idempotent_unique_conflict} ->
            # Concurrent :bind from another caller for the SAME triple
            # beat us — the row already exists, and (per the
            # idempotency contract) some worker is either alive or
            # will be spawned by the racing caller's `:ok` path. Try
            # an idempotent spawn here so this caller also returns
            # success; `{:already_started, _}` from the racing winner
            # is the expected path.
            do_spawn_after_persist(
              session_uri,
              binding,
              slice,
              aid,
              tid,
              binding_id,
              initial_cursor
            )

          {:error, {:db_insert_failed, _cs}} = err ->
            # Real DB error (NOT NULL / FK / etc.) — NOT an
            # idempotency case. Slice unchanged; no worker spawned.
            # Caller sees the honest failure.
            err
        end
    end
  end

  # codex r5 HIGH-B (2026-05-25): post-persist spawn + compensating
  # delete on spawn failure. Extracted so the two callers (fresh
  # insert AND concurrent-race insert that hit the unique constraint)
  # share the same spawn + rollback logic.
  defp do_spawn_after_persist(session_uri, binding, slice, aid, tid, binding_id, initial_cursor) do
    case spawn_worker_idempotently(session_uri, binding, initial_cursor) do
      :ok ->
        new_slice = update_in(slice.bindings, &[binding | &1])
        worker_uri = WorkerSpawn.worker_uri_for(session_uri, aid, tid)
        {:ok, new_slice, %{ok: true, binding_id: binding_id, worker_uri: worker_uri}}

      {:error, :worker_spawn_failed} = err ->
        # Compensating delete: row was persisted but the worker
        # spawn race settled to NO live worker. Delete the row so
        # the projection table doesn't carry a binding the system
        # can't service. The next bind attempt will re-persist +
        # re-spawn cleanly.
        #
        # Only the FRESH-insert caller needs this — but it's also
        # safe for the concurrent-race caller because
        # `delete_by_natural_key/3` is idempotent. If the racing
        # winner is happily alive, our compensating delete on
        # exhaustion still removes the row, which is wrong for the
        # winner. BUT: if our spawn exhausted with `:worker_spawn_failed`,
        # the winner's spawn would have exhausted too (same
        # `KindRegistry.put_new` foreign-pid blocker). So either both
        # exhaust and the row is correctly deleted, or one succeeds
        # and the other gets `{:already_started, _}` (== `:ok`,
        # which lands in the success branch above). Belt-and-
        # suspenders: log so an unexpected combination is observable.
        Logger.warning(
          "Behavior.ExternalMirror.do_bind: worker spawn failed after row " <>
            "persisted for #{URI.to_string(session_uri)}/#{aid}/#{inspect(tid)} — " <>
            "running compensating delete"
        )

        # Task #53 (2026-05-27) — `delete_by_natural_key/3` now returns
        # `{:ok, :deleted | :not_found} | {:error, _}` (silent-success
        # removal). For the compensating-delete path both `:deleted`
        # (we cleaned up the row we inserted) and `:not_found` (the
        # racing winner's compensating delete beat us) are correct;
        # an error here is suspicious but we still surface the
        # ORIGINAL spawn-failure to the caller — log + continue.
        case BindingRow.delete_by_natural_key(session_uri, aid, tid) do
          {:ok, :deleted} ->
            :ok

          {:ok, :not_found} ->
            Logger.debug(
              "Behavior.ExternalMirror.do_bind: compensating delete found " <>
                "no row for #{URI.to_string(session_uri)}/#{aid}/#{inspect(tid)} " <>
                "— racing caller already cleaned up"
            )

          {:error, reason} ->
            Logger.error(
              "Behavior.ExternalMirror.do_bind: compensating delete FAILED " <>
                "for #{URI.to_string(session_uri)}/#{aid}/#{inspect(tid)}: " <>
                "#{inspect(reason)} — row will remain until manual cleanup"
            )
        end

        err
    end
  end

  defp do_unbind(slice, aid, tid, session_uri) do
    binding_id = BindingRow.binding_id(aid, tid)

    case Enum.split_with(slice.bindings, fn b -> b.binding_id == binding_id end) do
      {[], _} ->
        # Not bound — idempotent success (matches `:unbind` semantics
        # on a missing row).
        {:ok, slice, %{ok: true, unbound: false}}

      {_removed, keep} ->
        # codex PR #418 r1 HIGH (2026-05-27) — order is delete-then-
        # terminate. Pre-r1 ordering was terminate-then-delete, which
        # left the worker dead and the slice mutation rolled back if
        # the projection delete returned `:not_found` or `{:error, _}`
        # — observable as "active binding with no live worker". The
        # delete is the only operation that can return a non-:ok
        # outcome under normal load (terminate is idempotent + bypasses
        # the :permanent restart strategy), so do that first and only
        # commit the destructive worker-shutdown + slice mutation AFTER
        # the projection row is confirmed gone.
        #
        # codex r1 CRIT fix (2026-05-25): delete by the FULL natural
        # key (session_uri + adapter_id + target_id) — NOT the
        # session-unscoped `binding_id`.
        #
        # Task #53 (2026-05-27): assert the projection deletion
        # SUCCEEDED rather than silently accepting `:ok` for the
        # not-found case. Allen 2026-05-27 02:53 repro — facade
        # returned `unbound: true` but the row stayed in DB,
        # producing `:ambiguous_chat_binding` on next inbound.
        case BindingRow.delete_by_natural_key(session_uri, aid, tid) do
          {:ok, :deleted} ->
            # Projection row gone. Now safe to terminate the worker
            # (idempotent — `DynamicSupervisor.terminate_child` calls
            # bypass :permanent per PR-EM-2 codex round-1 CRIT
            # moduledoc) and commit the slice mutation.
            :ok = WorkerSpawn.terminate(session_uri, aid, tid)
            new_slice = %{slice | bindings: keep}
            {:ok, new_slice, %{ok: true, unbound: true}}

          {:ok, :not_found} ->
            # Slice had the binding but projection didn't. Either:
            # (a) row_id derivation drift (session_uri stringified
            #     differently at bind vs unbind — historically the
            #     dominant failure mode; codex PR #418 r1 HIGH moved
            #     the delete to natural-key columns so this case is
            #     now narrow), or
            # (b) external SQL delete bypassing the action path, or
            # (c) the projection row was hand-deleted to test recovery.
            #
            # Worker NOT terminated (post-r1 ordering) — the binding
            # remains usable; slice mutation is refused so the
            # operator sees an honest error instead of a lying
            # success.
            :telemetry.execute(
              [:ezagent, :external_mirror, :unbind, :projection_desync],
              %{},
              %{
                session_uri: URI.to_string(session_uri),
                adapter_id: aid,
                target_id: tid,
                row_id: BindingRow.row_id(session_uri, aid, tid),
                slice_binding_count: length(slice.bindings)
              }
            )

            Logger.error(
              "Behavior.ExternalMirror.do_unbind: slice had binding " <>
                "#{aid}/#{inspect(tid)} on #{URI.to_string(session_uri)} " <>
                "but projection row was not found — slice/projection desync " <>
                "(worker NOT terminated, binding remains usable)"
            )

            {:error, :projection_desync}

          {:error, reason} ->
            # `Repo.delete_all/2` raised or returned an error
            # (connection error, DB offline, etc.). Worker NOT
            # terminated — bind state is fully preserved so the
            # operator can retry once the DB is back.
            Logger.error(
              "Behavior.ExternalMirror.do_unbind: BindingRow.delete failed " <>
                "for #{URI.to_string(session_uri)}/#{aid}/#{inspect(tid)}: " <>
                "#{inspect(reason)} (worker NOT terminated)"
            )

            {:error, {:projection_delete_failed, reason}}
        end
    end
  end

  # ----- data_owner/1 (caps-data-ownership §3.3) ----------------------------

  @doc """
  Session URI → that session's owner. Per SPEC §4.1, an
  external-mirror binding on session S is owned by S's owner; only
  the owner may grant `Behavior.ExternalMirror` caps on S.

  Reads via `Ezagent.Kind.read/3` (`spawn: :never` — live-only, same
  semantics as the old `get_slice/2`) on the `:chat` slice's
  `:owner_uri` field (the SoT for session ownership per caps-
  data-ownership PR-OWN-2 #308). Reading the slice avoids a runtime
  call into `Ezagent.Entity.Session.owner/1` which would form a
  reverse Mix-dep edge from `:ezagent_domain_external_mirror` to
  `:ezagent_domain_session` (cycle — chat already depends on this app
  for the Publisher contract).

  `:any` (class-wide caps) → workspace admin grants (per §5.2
  three-branch enforcement).
  """
  def data_owner(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, %{owner_uri: %URI{} = owner_uri}} -> Ezagent.URI.instance(owner_uri)
      _ -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner({:within_workspace, %URI{}}), do: :any
  def data_owner({:within_session, %URI{} = s}), do: {:scope, :within_session, s}
  def data_owner(_), do: :no_owner

  # `interface/0`, `actions/0`, `cap_subjects/0` are auto-derived by
  # `use Ezagent.ActionSet` from the `action :name, ...` declarations at
  # the top of this module. The legacy explicit versions were removed
  # as part of the Phase 2-d r3 migration. The macro's
  # `@before_compile` runs `maybe_inject_legacy_callbacks/5` which
  # synthesises identical-shape returns from the action specs.

  # ----- internals ----------------------------------------------------------

  # Idempotent worker spawn — `{:ok, _pid}` (fresh) and
  # `{:error, {:already_started, _pid}}` (concurrent winner /
  # restart adoption) count as success.
  #
  # The `{:shutdown, {:failed_to_start_child, _, {:already_registered, _}}}`
  # shape is a TRANSIENT inner race: the outer Registry-keyed
  # PerBindingSupervisor name succeeded, but the inner Kind.Server
  # crashed during init because the URI was already registered in
  # KindRegistry by a sibling racing PerBindingSupervisor. When this
  # happens, BOTH racing PerBindingSupervisors die (one because its
  # init failed; the other gets brought down when its child dies
  # under :one_for_one). The WorkerRegistry entry for the URI is
  # released. We retry up to 3 times — by the third retry the storm
  # has settled and either {:ok, _} or {:already_started, _} resolves.
  #
  # This keeps the 10-way concurrent bind idempotency test (test j)
  # green: after the storm, EXACTLY ONE Worker is alive (the last
  # successful spawn), and all 10 callers see :ok.
  #
  # ## codex r4 HIGH-2 fix (2026-05-25) — let-it-crash on exhaustion
  #
  # Pre-fix, retry exhaustion fell through to `:ok` — a `:warning +
  # degrade` pattern that violates
  # `feedback_let_it_crash_no_workarounds`. Worse, `do_bind` then
  # treated this as success and persisted the binding row + mutated
  # the slice → silent "binding exists but no worker" state.
  #
  # Post-fix, retry exhaustion returns `{:error, :worker_spawn_failed}`.
  # `do_bind` MUST propagate the error so the slice + row are NOT
  # mutated. Callers (`:bind` action body, `handle_kind_message`
  # rehydration loop) decide what to do per-context. The `:bind`
  # action body returns the error to the facade caller. The
  # rehydration loop logs at warning and skips — the next adapter
  # install or admin retry will re-attempt.
  # `initial_cursor` (remediation SPEC 2026-05-30 C-A) — the publisher cursor
  # the freshly-spawned Worker's `create/1` seeds as `publisher_cursor`, so
  # its (deferred, off-process) first subscribe replays any slice change that
  # landed during the spawn→subscribe window. `:latest` for the cold-load
  # rehydration path (`:ezagent_em_reconcile`), where `create/1` does NOT run
  # (the Worker already existed) and the persisted snapshot cursor drives
  # catch-up instead — so the value is inert there.
  defp spawn_worker_idempotently(session_uri, binding, initial_cursor \\ :latest, retries \\ 3)

  defp spawn_worker_idempotently(%URI{} = session_uri, %{} = binding, initial_cursor, retries) do
    worker_uri =
      WorkerSpawn.worker_uri_for(session_uri, binding.adapter_id, binding.target_id)

    params = %{
      uri: worker_uri,
      session_uri: session_uri,
      adapter_id: binding.adapter_id,
      target_id: binding.target_id,
      opts: Map.get(binding, :opts, %{}),
      initial_publisher_cursor: initial_cursor
    }

    # derivation-edge: non-principal ephemeral mirror worker
    case Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      # Transient inner race — retry after a tiny backoff.
      {:error, {:shutdown, {:failed_to_start_child, _, {:already_registered, _}}}}
      when retries > 0 ->
        Process.sleep(5)
        spawn_worker_idempotently(session_uri, binding, initial_cursor, retries - 1)

      # codex r4 HIGH-2 (2026-05-25): the inner `KindRegistry.put_new`
      # surface returns the bare `{:error, {:already_registered, _}}`
      # shape (no `{:shutdown, {:failed_to_start_child, _, _}}`
      # wrapper) when the URI is held by a foreign pid. Treat as
      # transient retry so test + production cover the same branch.
      {:error, {:already_registered, _}} when retries > 0 ->
        Process.sleep(5)
        spawn_worker_idempotently(session_uri, binding, initial_cursor, retries - 1)

      {:error, {:shutdown, {:failed_to_start_child, _, {:already_registered, _}}}} ->
        # codex r4 HIGH-2: retries exhausted with NO live worker —
        # return error so do_bind aborts BEFORE persisting any row.
        Logger.warning(
          "Behavior.ExternalMirror: spawn_worker_idempotently exhausted retries " <>
            "for #{URI.to_string(worker_uri)} — no live worker after storm settled"
        )

        {:error, :worker_spawn_failed}

      {:error, {:already_registered, _}} ->
        Logger.warning(
          "Behavior.ExternalMirror: spawn_worker_idempotently exhausted retries " <>
            "for #{URI.to_string(worker_uri)} — URI registered to foreign pid"
        )

        {:error, :worker_spawn_failed}

      {:error, reason} ->
        throw({:external_mirror_worker_spawn_failed, reason})
    end
  end

  # codex r5 HIGH-B (2026-05-25): replaces `persist_binding_row/2`.
  # Returns a discriminated tuple so the caller can distinguish:
  #
  #   - `{:ok, :persisted}`                — fresh insert
  #   - `{:ok, :idempotent_unique_conflict}` — natural-key unique-index
  #     collision (concurrent :bind from another caller for the SAME
  #     `(session_uri, adapter_id, target_id)` triple). Per the
  #     idempotency contract this is success.
  #   - `{:error, {:db_insert_failed, %Ecto.Changeset{}}}` — any other
  #     changeset error (NOT NULL, FK, validation, etc.). Pre-r5 the
  #     mapping was BLANKET-to-`:ok` which silently lost real failures;
  #     post-r5 the caller propagates the error and the slice + worker
  #     are NOT mutated.
  defp insert_binding_row(%URI{} = session_uri, %{} = binding) do
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)
    opts_json = Codec.encode_opts(binding.opts)

    # codex r1 CRIT fix (2026-05-25): use `BindingRow.row_id/3` (which
    # hashes session_uri + adapter_id + target_id) NOT the in-memory
    # slice's `binding_id` (which is only `adapter_id/target_id`).
    # The former is unique across all sessions; the latter would
    # collide on the primary key for two sessions binding the same
    # adapter target.
    db_id = BindingRow.row_id(session_uri, binding.adapter_id, binding.target_id)

    attrs = %{
      id: db_id,
      session_uri: URI.to_string(session_uri),
      adapter_id: binding.adapter_id,
      target_id: BindingRow.stringify_target(binding.target_id),
      opts_json: opts_json,
      bound_by: URI.to_string(binding.bound_by),
      bound_at: binding.bound_at,
      workspace_uri: workspace_uri
    }

    case BindingRow.insert(attrs) do
      {:ok, _row} ->
        {:ok, :persisted}

      {:error, %Ecto.Changeset{} = cs} ->
        if Codec.unique_constraint_violation?(cs) do
          Logger.debug(
            "external_mirror_bindings.insert idempotent unique-conflict for " <>
              "#{URI.to_string(session_uri)}/#{binding.adapter_id}/" <>
              "#{inspect(binding.target_id)}: #{inspect(cs.errors)}"
          )

          {:ok, :idempotent_unique_conflict}
        else
          # Real changeset error — NOT NULL, FK, validation, etc.
          # Pre-r5 this was silently mapped to `:ok` and the bind
          # claimed success with no row created. Post-r5 the caller
          # propagates this and the slice + worker stay untouched.
          Logger.warning(
            "external_mirror_bindings.insert FAILED (non-unique error) for " <>
              "#{URI.to_string(session_uri)}/#{binding.adapter_id}/" <>
              "#{inspect(binding.target_id)}: #{inspect(cs.errors)}"
          )

          {:error, {:db_insert_failed, cs}}
        end
    end
  end

  # Pure data-mapping / opts-codec helpers (row_to_slice_binding,
  # encode_opts, decode_opts, unique_constraint_violation?) live in
  # `Ezagent.ActionSet.ExternalMirror.Codec`; `stringify_target` is the
  # canonical copy on `BindingRow` (#25 Phase-3 PR-3N extraction/dedup).

  @doc false
  # Used by `Ezagent.ExternalMirror.list_adapters_for/1` (PR-EM-3
  # facade helper — given a session URI, find the per-adapter cap
  # subjects registered against that session). Public to the
  # Domain; not for plugin/operator use.
  def known_adapter_cap_subjects do
    AdapterRegistry.list()
    |> Enum.map(fn %{module: mod} ->
      try do
        mod.cap_subject()
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end
end
