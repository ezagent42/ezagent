defmodule Ezagent.Behavior.ExternalMirror do
  @moduledoc """
  `Ezagent.Behavior.ExternalMirror` — the bind/unbind/list Behavior on
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

  Standard CapBAC step 5.5 (`Kind.Runtime.authz_check/4`) enforces
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

  We read the owner via `Ezagent.Kind.get_slice/2` rather than
  `Ezagent.Entity.Session.owner/1` to avoid a runtime call into
  `:ezagent_domain_chat` (Mix-dep cycle — see
  `apps/ezagent_domain_external_mirror/mix.exs` moduledoc).
  """

  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRow, FacadeNonceTable, WorkerSpawn}

  # ----- Ezagent.Behavior contract ----------------------------------------

  @impl Ezagent.Behavior
  def actions, do: [:bind, :unbind, :list_bindings]

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # ExternalMirror is registered on Session Kind only — kind axis is
  # `:session`.
  @impl Ezagent.Behavior
  def required_caps do
    %{
      bind: Ezagent.Capability.cap(:session, __MODULE__, :bind),
      unbind: Ezagent.Capability.cap(:session, __MODULE__, :unbind),
      list_bindings: Ezagent.Capability.cap(:session, __MODULE__, :list_bindings)
    }
  end

  @impl Ezagent.Behavior
  def state_slice, do: :external_mirror

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:bind, "Bind this session's slice changes to an external adapter target."},
      {:unbind, "Remove an (adapter_id, target_id) binding from this session."},
      {:list_bindings, "List all external-mirror bindings on this session."}
    ]
  end

  @impl Ezagent.Behavior
  def init_slice(args) do
    # Per §3.1 r4 HIGH-3 fix: rehydrate the binding LIST on init. The
    # WORKER spawn loop is deferred to handle_continue/3 below
    # (post_init returns `{:continue, :reconcile_external_mirror_workers}`).
    session_uri = Map.fetch!(args, :uri)

    bindings =
      session_uri
      |> BindingRow.list_for_session()
      |> Enum.map(&row_to_slice_binding/1)

    %{bindings: bindings}
  rescue
    # DB unavailable at boot (Ecto Sandbox not checked out, repo not
    # started, etc.) — start with an empty list. The :on_change
    # snapshot path repopulates on first mutation; if the DB comes
    # back later, rows survive on disk but are NOT auto-replayed
    # until Session Kind restarts. This matches the existing
    # `bind_session_workspace/1` boot tolerance pattern in
    # `EzagentDomainChat.Application`.
    _ ->
      %{bindings: []}
  end

  @impl Ezagent.Behavior
  def post_init(_args, %{bindings: []}), do: :ok

  def post_init(_args, %{bindings: _bindings}),
    do: {:continue, :reconcile_external_mirror_workers}

  def post_init(_args, _slice), do: :ok

  # Allen 2026-05-26 task #34 — `init_slice/1` reads the DB
  # projection at fresh-init time, but `Ezagent.Kind.Snapshot.
  # load_or_init/3` MERGES the snapshot over the fresh state, so
  # the DB-read result is shadowed. Rows inserted AFTER the last
  # snapshot but BEFORE the next Kind restart are silently lost
  # from the live slice.
  #
  # `reconcile_after_load/2` runs AFTER the snapshot merge.
  # We re-read the projection rows for this session and union
  # them with the loaded slice's bindings, dedupe by binding id.
  # The normal-path bind (where the snapshot already captured
  # the binding) is a no-op union; the bypass paths (SQL insert,
  # snapshot/DB write race) get the new binding pulled into
  # slice for `handle_continue/3` to spawn the worker.
  @impl Ezagent.Behavior
  def reconcile_after_load(%URI{} = session_uri, %{bindings: existing} = slice) do
    db_bindings =
      session_uri
      |> BindingRow.list_for_session()
      |> Enum.map(&row_to_slice_binding/1)

    existing_ids = MapSet.new(existing, & &1.binding_id)

    additions =
      Enum.reject(db_bindings, fn b -> MapSet.member?(existing_ids, b.binding_id) end)

    %{slice | bindings: existing ++ additions}
  rescue
    # DB unavailable — keep snapshot's bindings. Matches init_slice's
    # rescue branch; same tolerance pattern.
    _ -> slice
  end

  def reconcile_after_load(_uri, slice), do: slice

  @doc """
  §3.1 reconciliation — runs AFTER `:announce_ready` for Sessions
  whose `init_slice/1` rebuilt non-empty `bindings`.

  **Important:** during this `handle_continue/3`, the Session Kind
  is still `:not_ready` per the post-init invariant
  (`Ezagent.Kind.Server` moduledoc — round-2 HIGH-1 fix). If we
  synchronously `Kind.spawn/2` the Workers here, each Worker's OWN
  post-init `handle_continue` would call back into the Session
  Publisher's `subscribe_from` (a `GenServer.call` against the
  Session) and get `{:error, :not_ready}` — crashing the Worker.

  Workaround: defer the actual spawn loop via `Process.send_after(
  self(), {:ezagent_em_reconcile, bindings}, 0)`. The mailbox
  message is processed by `handle_kind_message/3` AFTER the
  Kind.Server completes its post-init phase + marks `:ready`. At
  that point, Worker spawns succeed because the Session is alive +
  ready to service subscribe calls.

  Slice itself is unchanged — return `:ignore` so `Kind.Server` skips
  the snapshot-commit path.
  """
  @impl Ezagent.Behavior
  def handle_continue(:reconcile_external_mirror_workers, slice, _ctx) do
    # `self()` is the Kind.Server pid — the same process that will
    # be `:ready` by the time the mailbox drains.
    send(self(), {:ezagent_em_reconcile, slice.bindings})
    :ignore
  end

  @doc """
  Mailbox handler for the deferred reconciliation message scheduled
  from `handle_continue/3`. Walks the binding list + idempotently
  spawns each Worker. By the time this runs, the Session is
  `:ready` so the Workers' subscribe calls succeed.

  Skips rows whose adapter isn't (yet) in `AdapterRegistry` — the
  Worker's `handle_continue` would raise on `AdapterRegistry.lookup!/1`
  per SPEC §5.2, exhaust the PerBindingSupervisor budget, and
  potentially cascade up to RootSupervisor. Plugin authors expecting
  their adapter to be registered must ensure the plugin boots BEFORE
  any session referencing it rehydrates — V1 single-node, the
  umbrella's mix.exs dep edges control this.
  """
  def handle_kind_message({:ezagent_em_reconcile, bindings}, _slice, %{self_uri: session_uri}) do
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

  def handle_kind_message(_other, _slice, _ctx), do: :ignore

  # ----- The :bind action ---------------------------------------------------

  @impl Ezagent.Behavior
  def invoke(:bind, slice, args, ctx) do
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
        do_bind(slice, args, ctx)

      :error ->
        # Let-it-crash-style refusal: bind MUST go through the
        # `Ezagent.ExternalMirror.bind/4` facade so Checks 2 + 3
        # (per-adapter cap + target ownership) are enforced. A
        # direct dispatch bypasses those — refuse loudly.
        {:error, :bind_must_go_through_facade}
    end
  end

  def invoke(:unbind, slice, %{adapter_id: aid, target_id: tid}, ctx) do
    session_uri = Map.get(ctx, :self_uri) || Map.fetch!(ctx, :target_uri)
    do_unbind(slice, aid, tid, session_uri)
  end

  def invoke(:list_bindings, slice, _args, _ctx) do
    {:ok, slice, %{bindings: slice.bindings}}
  end

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

    case Enum.find(slice.bindings, fn b -> b.binding_id == binding_id end) do
      %{} = existing ->
        # Already bound — idempotent success (concurrent :bind for
        # the same triple lands here on the second call). Confirm
        # the worker is alive (defensive — if it died between
        # rehydrate + this dispatch, respawn now).
        case spawn_worker_idempotently(session_uri, existing) do
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
            do_spawn_after_persist(session_uri, binding, slice, aid, tid, binding_id)

          {:ok, :idempotent_unique_conflict} ->
            # Concurrent :bind from another caller for the SAME triple
            # beat us — the row already exists, and (per the
            # idempotency contract) some worker is either alive or
            # will be spawned by the racing caller's `:ok` path. Try
            # an idempotent spawn here so this caller also returns
            # success; `{:already_started, _}` from the racing winner
            # is the expected path.
            do_spawn_after_persist(session_uri, binding, slice, aid, tid, binding_id)

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
  defp do_spawn_after_persist(session_uri, binding, slice, aid, tid, binding_id) do
    case spawn_worker_idempotently(session_uri, binding) do
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
        # a changeset error is suspicious but we still surface the
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

          {:error, %Ecto.Changeset{} = cs} ->
            Logger.error(
              "Behavior.ExternalMirror.do_bind: compensating delete FAILED " <>
                "for #{URI.to_string(session_uri)}/#{aid}/#{inspect(tid)}: " <>
                "#{inspect(cs.errors)} — row will remain until manual cleanup"
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
        # Graceful worker shutdown — `WorkerSpawn.terminate/3` calls
        # `DynamicSupervisor.terminate_child(RootSupervisor, _)`
        # which bypasses the `:permanent` restart strategy per
        # PR-EM-2 codex round-1 CRIT moduledoc.
        :ok = WorkerSpawn.terminate(session_uri, aid, tid)

        # codex r1 CRIT fix (2026-05-25): delete by the FULL natural
        # key (session_uri + adapter_id + target_id) — NOT the
        # session-unscoped `binding_id`.
        #
        # Task #53 (2026-05-27): assert the projection deletion
        # SUCCEEDED rather than silently accepting `:ok` for the
        # not-found case. Allen 2026-05-27 02:53 repro — facade
        # returned `unbound: true` but the row stayed in DB,
        # producing `:ambiguous_chat_binding` on next inbound. The
        # slice JUST said the binding exists, so a not-found row
        # means the slice and projection are out of sync. Refuse
        # rather than papering over.
        case BindingRow.delete_by_natural_key(session_uri, aid, tid) do
          {:ok, :deleted} ->
            new_slice = %{slice | bindings: keep}
            {:ok, new_slice, %{ok: true, unbound: true}}

          {:ok, :not_found} ->
            # Slice had the binding but projection didn't. Either:
            # (a) row_id derivation drift (session_uri stringified
            #     differently at bind vs unbind), or
            # (b) external SQL delete bypassing the action path.
            # Either way the slice mutation would lie if we proceeded.
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
                "but projection row was not found — slice/projection desync"
            )

            {:error, :projection_desync}

          {:error, %Ecto.Changeset{} = cs} ->
            # `Repo.delete/1` failed (stale entry / constraint /
            # connection error). Slice mutation would lie about
            # durability. Surface the failure.
            Logger.error(
              "Behavior.ExternalMirror.do_unbind: BindingRow.delete failed " <>
                "for #{URI.to_string(session_uri)}/#{aid}/#{inspect(tid)}: " <>
                "#{inspect(cs.errors)}"
            )

            {:error, {:projection_delete_failed, cs}}
        end
    end
  end

  # ----- data_owner/1 (caps-data-ownership §3.3) ----------------------------

  @doc """
  Session URI → that session's owner. Per SPEC §4.1, an
  external-mirror binding on session S is owned by S's owner; only
  the owner may grant `Behavior.ExternalMirror` caps on S.

  Reads via `Ezagent.Kind.get_slice/2` on the `:chat` slice's
  `:owner_uri` field (the SoT for session ownership per caps-
  data-ownership PR-OWN-2 #308). Reading the slice avoids a runtime
  call into `Ezagent.Entity.Session.owner/1` which would form a
  reverse Mix-dep edge from `:ezagent_domain_external_mirror` to
  `:ezagent_domain_chat` (cycle — chat already depends on this app
  for the Publisher contract).

  `:any` (class-wide caps) → workspace admin grants (per §5.2
  three-branch enforcement).
  """
  @impl Ezagent.Behavior
  def data_owner(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{owner_uri: %URI{} = owner_uri}} -> Ezagent.URI.instance(owner_uri)
      _ -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner({:within_workspace, %URI{}}), do: :any
  def data_owner({:within_session, %URI{} = s}), do: {:scope, :within_session, s}
  def data_owner(_), do: :no_owner

  @impl Ezagent.Behavior
  def interface do
    %{
      bind: %{
        description: "Add an external-mirror binding to this session.",
        args: %{adapter_id: :string, target_id: :string, opts: :map},
        returns: %{ok: :boolean, binding_id: :string, worker_uri: :uri},
        modes: [:call]
      },
      unbind: %{
        description: "Remove an external-mirror binding from this session.",
        args: %{adapter_id: :string, target_id: :string},
        returns: %{ok: :boolean, unbound: :boolean},
        modes: [:call]
      },
      list_bindings: %{
        description: "Read every binding on this session.",
        args: %{},
        returns: %{bindings: {:list, :map}},
        modes: [:call]
      }
    }
  end

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
  defp spawn_worker_idempotently(%URI{} = session_uri, %{} = binding, retries \\ 3) do
    worker_uri =
      WorkerSpawn.worker_uri_for(session_uri, binding.adapter_id, binding.target_id)

    params = %{
      uri: worker_uri,
      session_uri: session_uri,
      adapter_id: binding.adapter_id,
      target_id: binding.target_id,
      opts: Map.get(binding, :opts, %{})
    }

    case Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      # Transient inner race — retry after a tiny backoff.
      {:error, {:shutdown, {:failed_to_start_child, _, {:already_registered, _}}}}
      when retries > 0 ->
        Process.sleep(5)
        spawn_worker_idempotently(session_uri, binding, retries - 1)

      # codex r4 HIGH-2 (2026-05-25): the inner `KindRegistry.put_new`
      # surface returns the bare `{:error, {:already_registered, _}}`
      # shape (no `{:shutdown, {:failed_to_start_child, _, _}}`
      # wrapper) when the URI is held by a foreign pid. Treat as
      # transient retry so test + production cover the same branch.
      {:error, {:already_registered, _}} when retries > 0 ->
        Process.sleep(5)
        spawn_worker_idempotently(session_uri, binding, retries - 1)

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
    opts_json = encode_opts(binding.opts)

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
      target_id: stringify_target(binding.target_id),
      opts_json: opts_json,
      bound_by: URI.to_string(binding.bound_by),
      bound_at: binding.bound_at,
      workspace_uri: workspace_uri
    }

    case BindingRow.insert(attrs) do
      {:ok, _row} ->
        {:ok, :persisted}

      {:error, %Ecto.Changeset{} = cs} ->
        if unique_constraint_violation?(cs) do
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

  # codex r5 HIGH-B: discriminate "unique-constraint violation"
  # (idempotency success path) from every other changeset error
  # (real failure). The changeset shape from `BindingRow.insert/1`
  # carries the constraint metadata in the error opts list:
  #
  #   {:adapter_id, {"binding already exists",
  #     [constraint: :unique, constraint_name: "..."]}}
  #
  # Match on `constraint: :unique` ANYWHERE in the changeset errors —
  # the same triple can fire either the PK constraint OR the
  # natural-key unique index depending on race timing; both are
  # idempotency cases.
  defp unique_constraint_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} when is_list(opts) ->
        Keyword.get(opts, :constraint) == :unique

      _ ->
        false
    end)
  end

  defp row_to_slice_binding(%BindingRow{} = row) do
    # codex r1 CRIT fix detail: the slice's `binding_id` is the
    # session-local human-readable key (`"<adapter>/<target>"`) —
    # NOT the DB row's `:id` (which is the session-scoped hash).
    # `:unbind` action body looks up by the human-readable key, so
    # rehydration must reconstruct it from (adapter_id, target_id)
    # rather than reading row.id (the hash is opaque to the slice).
    %{
      binding_id: BindingRow.binding_id(row.adapter_id, row.target_id),
      adapter_id: row.adapter_id,
      target_id: row.target_id,
      opts: decode_opts(row.opts_json),
      bound_by: URI.parse(row.bound_by),
      bound_at: row.bound_at
    }
  end

  defp encode_opts(opts) when is_map(opts) do
    case Jason.encode(opts) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  defp encode_opts(_), do: "{}"

  # codex r1 HIGH fix (2026-05-25): NO `String.to_atom/1` on
  # JSON-decoded caller-controlled data. The previous `atomize_keys`
  # was an unbounded atom-generation DoS vector — a caller with
  # bind permission could submit `opts: %{<random key>: _}` and
  # leak unique atoms on every restart/rehydrate. Atoms are not
  # garbage collected; this would eventually exhaust the VM's
  # atom table.
  #
  # Adapters that need to read `opts` get a string-keyed map. If
  # they want atom keys they MUST convert via `String.to_existing_atom/1`
  # against a fixed allowlist of expected option keys (see SPEC
  # §6 adapter contract — adapters own this layer of validation).
  defp decode_opts(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode_opts(_), do: %{}

  defp stringify_target(t) when is_binary(t), do: t
  defp stringify_target(t) when is_atom(t), do: Atom.to_string(t)
  defp stringify_target(t) when is_integer(t), do: Integer.to_string(t)
  defp stringify_target(t), do: inspect(t)

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
