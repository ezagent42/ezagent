defmodule EzagentCore.Invariants.ActorInternalsBoundaryTest do
  @moduledoc """
  Actor-framework extraction boundary gate — chunk **C0** of the extraction
  (spec `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md`
  §4). **Gate first, move nothing:** nothing has moved yet; this gate enumerates
  the leakage at zero risk and freezes it as the migration-debt worklist.

  It runs TWO complementary scans over one AST pass each:

  ## FORWARD — §4.2 "The rule" (the primary C0 gate, seeds the §4.4 census)

  Non-framework code (`apps/*/lib`, EXCLUDING the §1/§3.2 mover set) must not
  reach INTO the actor internals. RED on a reference to a banned internal ROOT
  (`KindRegistry`, `SnapshotStore`, `Ecto.KindSnapshot`, `Snapshot.Writer`,
  `Kind.{StateRebuilder,Snapshot,SliceAccess,Server,Runtime*,BehaviorSet,Spawner,
  ReadyTransition,MountDetach,Termination,DeferredDispatch,CascadeHook,
  LaunchContext*}`, `PendingDelivery`, `Idempotency`), on a banned CALL SHAPE
  (`GenServer.call/cast` whose message carries an `:ezagent_*` atom;
  `:sys.get_state/replace_state`; `Kind.get_slice/get_raw_slice` — ratchet-only,
  flipped to banned at C7), on `ReadyGate.<fn>` other than `register_external_gate`,
  or on `Cap.Authority.current_process_generation/1` outside its fixed consumer
  list. This is the ledger C1–C4 shrink as reach-ins migrate onto the §2.2 public
  read surface (`Kind.read/3`, `read_classified/2`, `read_durable/3` +
  `read_durable_many/3`, `alive?/1`, `self?/1`, `list_instances/0`,
  `resolve_action_subject/2`).

  ## REVERSE — §4.2 "Reverse direction" (companion, seeds the §3.4 port worklist)

  The mover set (the files that will `git mv` into the future `ezagent_actor`
  app) must not reach UP into the staying-core cap/authority/policy spine — after
  the split those references become compile errors, each re-shaped into a §3.4
  port. Scanned at the mover set's current pre-move location.

  ## AST-based, three shapes (§4.2)

  A single `__aliases__` collector covers all three banned shapes — CALLS (the
  receiver is `__aliases__`), bare module ATOMS (data tables / `@spec` remote
  types / quoted code), and STRUCT PATTERNS/constructions (`%Ezagent.Capability{}`,
  `%Ezagent.SagaRunner.Saga{}`) — because each contains an `__aliases__` node.
  Alias resolution handles `alias Foo, as: B` and `alias Foo.{Bar, Baz}`. The
  gate-has-teeth self-tests below prove each shape is caught in both directions.

  ## Empty-allowlist = the worklist enumerator (§4.3)

      ACTOR_BOUNDARY_ALLOWLIST=empty mix test \
        apps/ezagent_core/test/invariants/actor_internals_boundary_test.exs

  runs both scans with EMPTY ledgers and prints every offender. The forward run
  IS the §4.4 census (authoritative); the reverse run IS the §3.4 port worklist.
  CI runs the ratchet form; the empty form is the enumerator that seeded the
  ledgers frozen below.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @core_lib "apps/ezagent_core/lib"

  # ── The §1/§3.2 mover set (verified present on origin/main) ────────────────
  # Paths relative to `apps/ezagent_core/lib`. EXCLUDED per §3.2: `kind/template.ex`
  # + `kind/template/**` (domain policy, stays), the five POLICY ActionSets
  # `behavior/{routing,terminable,manage,notifications,sandbox}.ex`, and
  # `ecto/kind_cap_authority.ex` (cap spine schema, stays). The four behavior
  # CONTRACT modules (effects/kind_base/legacy_callbacks/introspection) move.
  @mover_files ~w(
    ezagent/kind.ex
    ezagent/lifecycle.ex
    ezagent/invocation.ex
    ezagent/router.ex
    ezagent/cmd.ex
    ezagent/kind_registry.ex
    ezagent/ready_gate.ex
    ezagent/pending_delivery.ex
    ezagent/idempotency.ex
    ezagent/idempotency/sweeper.ex
    ezagent/snapshot_store.ex
    ezagent/snapshot/writer.ex
    ezagent/spawn_registry.ex
    ezagent/local_runtime.ex
    ezagent/slice_change.ex
    ezagent/slice_change/cursors.ex
    ezagent/behavior.ex
    ezagent/behavior/effects.ex
    ezagent/behavior/kind_base.ex
    ezagent/behavior/legacy_callbacks.ex
    ezagent/behavior/introspection.ex
    ezagent/behavior_registry.ex
    ezagent/universal_behaviors.ex
    ezagent/interface_validator.ex
    ezagent/uri.ex
    ezagent/uri/scheme_registry.ex
    ezagent/ecto/kind_snapshot.ex
    ezagent/ecto/uri_type.ex
    ezagent/kind/behavior_set.ex
    ezagent/kind/cascade_hook.ex
    ezagent/kind/deferred_dispatch.ex
    ezagent/kind/identity_read_error.ex
    ezagent/kind/introspection.ex
    ezagent/kind/kind_base_backfill.ex
    ezagent/kind/launch_context_init.ex
    ezagent/kind/launch_context_relay.ex
    ezagent/kind/mount_detach.ex
    ezagent/kind/ready_transition.ex
    ezagent/kind/runtime.ex
    ezagent/kind/runtime/context.ex
    ezagent/kind/runtime/effects.ex
    ezagent/kind/runtime/receipt.ex
    ezagent/kind/server.ex
    ezagent/kind/slice_access.ex
    ezagent/kind/snapshot.ex
    ezagent/kind/spawner.ex
    ezagent/kind/state_rebuilder.ex
    ezagent/kind/termination.ex
    ezagent_core/kind_supervisor.ex
  )

  # ══════════════════════════════════════════════════════════════════════════
  # FORWARD scan config (§4.2 "The rule")
  # ══════════════════════════════════════════════════════════════════════════

  # Banned actor-internal module ROOTS. NOT included: `Ezagent.ReadyGate` and
  # `Ezagent.Kind` (handled by call matchers — ReadyGate has a `register_external_gate`
  # exception; `Kind.get_slice` is the ratchet), and the cap spine (which stays).
  @banned_internal_modules MapSet.new([
                             Ezagent.KindRegistry,
                             Ezagent.PendingDelivery,
                             Ezagent.Idempotency,
                             Ezagent.SnapshotStore,
                             Ezagent.Snapshot.Writer,
                             Ezagent.Ecto.KindSnapshot,
                             Ezagent.Kind.StateRebuilder,
                             Ezagent.Kind.Snapshot,
                             Ezagent.Kind.SliceAccess,
                             Ezagent.Kind.Server,
                             Ezagent.Kind.BehaviorSet,
                             Ezagent.Kind.Spawner,
                             Ezagent.Kind.ReadyTransition,
                             Ezagent.Kind.MountDetach,
                             Ezagent.Kind.Termination,
                             Ezagent.Kind.DeferredDispatch,
                             Ezagent.Kind.CascadeHook,
                             Ezagent.Kind.LaunchContextInit,
                             Ezagent.Kind.LaunchContextRelay
                           ])

  # `Ezagent.Kind.Runtime` and any `Ezagent.Kind.Runtime.*` — prefix ban.
  @banned_internal_prefix "Elixir.Ezagent.Kind.Runtime"

  @kind_read_calls [:get_slice, :get_raw_slice]
  @ready_gate_allowed_fn :register_external_gate
  @process_generation_fn :current_process_generation

  # Process-generation containment — a SEPARATE fixed allowlist (§4.2), NOT the
  # ratchet: the three legitimate `Cap.Authority.current_process_generation/1`
  # consumers (re-censused at d9c9a90e7). C4 removes the authorize.ex one.
  @process_generation_consumers MapSet.new([
                                  "apps/ezagent_core/lib/ezagent/cap.ex",
                                  "apps/ezagent_core/lib/ezagent/cap/authorize.ex",
                                  "apps/ezagent_domain_identity/lib/ezagent/entity/token.ex",
                                  # the defining module (self-reference)
                                  "apps/ezagent_core/lib/ezagent/cap/authority.ex"
                                ])

  # ── The frozen FORWARD ledger (§4.4 census) — file-keyed migration debt ─────
  # Seeded from the ACTOR_BOUNDARY_ALLOWLIST=empty forward run at C0 — the
  # exhaustive worklist of non-framework files that reach into actor internals
  # today (Pillar-B completeness: the red build IS the census). Each reason lists
  # the internals the file touches; all migrate onto the §2.2 read surface across
  # C1–C5 (the get_slice/get_raw_slice ratchet flips to banned at C7). Ratchets
  # to []. NOTE: file-keyed (drift-resistant, matches §4.4's per-file counts).
  @forward_allowlist [
    %{
      file: "apps/ezagent_core/lib/ezagent/behavior/sandbox.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Ezagent.SnapshotStore, Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/behavior/terminable.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/cap.ex",
      reason:
        "§4.4 reach-in [Ezagent.Kind.BehaviorSet, Ezagent.KindRegistry, GenServer.call(:ezagent_*), ReadyGate.status] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/cap/target_artifact_validator.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, GenServer.call(:ezagent_*)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/credential/grant_row.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/credential/resolver.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/home/migration.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/lifecycle_case.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Kind.get_raw_slice (ratchet→C7), ReadyGate.status] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/session/slice_migration.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.Kind.Snapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent/stress_metrics.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent_core/application.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Ezagent.Snapshot.Writer] — framework supervision children move to the actor Application (§3.2; C5)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent_core/data_case.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, GenServer.call(:ezagent_*)] — test-support in lib; ActorCase helpers (§4.4; C5)"
    },
    %{
      file: "apps/ezagent_core/lib/ezagent_core/ets_owner.ex",
      reason:
        "§4.4 reach-in [Ezagent.Idempotency, Ezagent.PendingDelivery] — actor ETS tables move to the actor app's ETS owner (§3.2; C5)"
    },
    %{
      file: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.clear.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — framework mix task moves with the app (§3.2; C5)"
    },
    %{
      file: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.dump.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — framework mix task moves with the app (§3.2; C5)"
    },
    %{
      file: "apps/ezagent_core/lib/mix/tasks/ezagent.snapshot.list.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — framework mix task moves with the app (§3.2; C5)"
    },
    %{
      file: "apps/ezagent_core/lib/mix/tasks/ezagent.stress.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, ReadyGate.status] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/agent/credential_status.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore, Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/agent/recipe_resolver.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/agent/retirement_sweeper.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex",
      reason:
        "§4.4 reach-in [Ezagent.Kind.ReadyTransition, Ezagent.KindRegistry, Ezagent.PendingDelivery, ReadyGate.put, ReadyGate.status] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/agent_flavor_resolver.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/domain/agent.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/per_binding_supervisor.ex",
      reason:
        "§4.4 reach-in [Ezagent.Kind.Server] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_git/lib/ezagent/domain_git/task_access_supervisor.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/behavior/user_default_credential_source.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_shared_credential_source.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/entity.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Ezagent.SnapshotStore, Kind.get_slice (ratchet→C7), ReadyGate.await] — C1 removes these (read_classified/2 + self?/1)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.Kind.Snapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/identity/membership_convergence.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/identity/offboarding/reaper.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/identity/operator_reads.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/identity/recipe_cap_binding.ex",
      reason:
        "§4.4 reach-in [ReadyGate.status] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/identity/target_authority.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, GenServer.call(:ezagent_*)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_identity/lib/ezagent/users.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex",
      reason:
        "§4.4 reach-in [:sys.get_state] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex",
      reason:
        "§4.4 reach-in [:sys.get_state] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/behavior/session.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/behavior/template.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex",
      reason:
        "§4.4 reach-in [Kind.get_raw_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/entity/session.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Kind.get_raw_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/orchestrator/health.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Kind.get_raw_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/migration.ex",
      reason:
        "§4.4 reach-in [Kind.get_raw_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/templates.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.KindRegistry, Kind.get_raw_slice (ratchet→C7), Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/session/offboarding_adapter.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/session/template_reads.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/session_config/admission.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/session_config/readiness.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, ReadyGate.status] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex",
      reason:
        "§4.4 reach-in [Ezagent.Kind.BehaviorSet, Ezagent.KindRegistry, Kind.get_slice (ratchet→C7)] — C3 resolve_action_subject/2 + read/3 (§2.3 open question)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex",
      reason:
        "§4.4 reach-in [Kind.get_raw_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/agent_module_resolver.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/presence_fanout.ex",
      reason:
        "§4.4 reach-in [Kind.get_raw_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex",
      reason:
        "§4.4 reach-in [Kind.get_raw_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/listing.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_resolver.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/uri_query_resolvers.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore, Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user/gc.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex",
      reason:
        "§4.4 reach-in [Ezagent.Kind.StateRebuilder, Kind.get_slice (ratchet→C7)] — C2 surface_slice → Kind.read/3 (seed (c))"
    },
    %{
      file: "apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/terminal_view.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, ReadyGate.await, ReadyGate.status] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_workspace/lib/ezagent/workspace/listing.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_workspace/lib/ezagent/workspace/provisioning.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_domain_workspace/lib/ezagent/workspace/responsibility_assignments.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_codex/lib/ezagent/orchestrator/codex_orchestrator_seed.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/bridge_adapter.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file:
        "apps/ezagent_plugin_curl_agent/lib/ezagent/plugin_curl_agent/curl_snapshot_migration.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot, Ezagent.Kind.Snapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore, Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/credential_bridge.ex",
      reason:
        "§4.4 reach-in [Ezagent.SnapshotStore] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_delegation.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/members.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex",
      reason:
        "§4.4 reach-in [Ezagent.Ecto.KindSnapshot] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban_render.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    },
    %{
      file: "apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex",
      reason:
        "§4.4 reach-in [Ezagent.Kind.StateRebuilder] — C2 identity_data → read/3 / alive? (§4.4 world StateRebuilder)"
    },
    %{
      file: "apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Ezagent.SnapshotStore] — C2 web SnapshotStore reads → read/3"
    },
    %{
      file: "apps/ezagent_web/lib/ezagent_web/live/home_live.ex",
      reason:
        "§4.4 reach-in [Ezagent.KindRegistry, Ezagent.SnapshotStore] — C2 web SnapshotStore reads → read/3"
    },
    %{
      file: "apps/ezagent_web/lib/ezagent_web/socialware/anon_takeover.ex",
      reason:
        "§4.4 reach-in [Kind.get_slice (ratchet→C7)] — migrates via §2.2 read surface (C1–C5; get_slice ratchet→C7)"
    }
  ]

  @forward_frozen_size 105

  # ══════════════════════════════════════════════════════════════════════════
  # REVERSE scan config (§4.2 "Reverse direction") — the §3.4 port worklist
  # ══════════════════════════════════════════════════════════════════════════

  # Fixed allowlist (reasoned, NOT the ratchet): exactly one — `LegacyCallbacks`
  # QUOTES `Ezagent.Capability.cap/3` into using modules; the call executes
  # upward, not a framework runtime dep. Dies at C5 (§3.4 non-port findings).
  @reverse_fixed_allowlist [
    %{
      file: "ezagent/behavior/legacy_callbacks.ex",
      module: Ezagent.Capability,
      reason: "quoted Ezagent.Capability.cap/3 injected into using modules (§3.4 non-port)"
    }
  ]

  # The frozen REVERSE ledger — every staying-core module the mover set
  # references today, seeded from the empty-allowlist reverse run (31 modules,
  # 123 sites). Each maps to its §3.4 port / non-port finding. Ratchets to [].
  @reverse_allowlisted_modules [
    %{
      module: Ezagent.Cap.Authority,
      reason: "§3.4 AuthorityPort (open/with_authority/regenesis/retire/generation)"
    },
    %{
      module: Ezagent.Cap,
      reason: "§3.4 AuthorityPort/AuthzPort (validate_for_current_target, admin-materialize)"
    },
    %{
      module: Ezagent.Cap.Verifier,
      reason: "§3.4 AuthzPort/AuthorityPort (authorize_dispatch, verify_artifact)"
    },
    %{
      module: Ezagent.Cap.Grant,
      reason: "§3.4 AuthzPort authorize_and_issue_grant (cap becomes opaque)"
    },
    %{
      module: Ezagent.Cap.DeliveryOutbox,
      reason: "§3.4 OutboxPort (replay?/eligible?/enqueue/mark/drain — 7 fns)"
    },
    %{
      module: Ezagent.Cap.RuntimeView,
      reason: "§3.4 AuthorityPort with_runtime_view (§2.3 open-question 1)"
    },
    %{
      module: Ezagent.Capability,
      reason:
        "§3.4 CapabilityPort (workspace_of/cross_workspace?/identity_key); OPAQUE, no struct match"
    },
    %{
      module: Ezagent.CapabilityRegistry,
      reason: "§3.4 AuthzPort data_owner_of/2 (introspection data-owner resolution)"
    },
    %{
      module: Ezagent.DispatchOrigin,
      reason: "§3.4 DispatchPolicyPort (before_delivery / validate_origin)"
    },
    %{
      module: Ezagent.WorkspaceOwnerGate,
      reason: "§3.4 DispatchPolicyPort (before_delivery / assert_local_owner)"
    },
    %{
      module: Ezagent.EventLog,
      reason: "§3.4 EventLogPort append/4 (adapter derives workspace scope)"
    },
    %{module: Ezagent.DLQ, reason: "§3.4 DeadLetterPort put/2"},
    %{module: Ezagent.SagaRunner, reason: "§3.4 SagaPort execute/2 (:not_configured default)"},
    %{
      module: Ezagent.SagaRunner.Saga,
      reason: "§3.4 SagaPort — saga type OPAQUE; adapter validates representation"
    },
    %{
      module: Ezagent.Persistence,
      reason: "§3.4 PersistencePort (workspace_uri_for/scope_by_workspace)"
    },
    %{
      module: Ezagent.Persistence.TransientRetry,
      reason: "§3.4 PersistencePort with_transient_retry/1"
    },
    %{
      module: EzagentCore.Repo,
      reason: "§3.4 repo config injection (Application.fetch_env!(:ezagent_actor, :repo))"
    },
    %{
      module: EzagentCore.PubSub,
      reason: "§3.4 pubsub config injection (Application.fetch_env!(:ezagent_actor, :pubsub))"
    },
    %{
      module: Ezagent.ActionSet.Session,
      reason:
        "§3.4 non-port: behavior_set/kind_base_backfill legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.Turn,
      reason:
        "§3.4 non-port: behavior_set/kind_base_backfill legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.Surface,
      reason:
        "§3.4 non-port: behavior_set/kind_base_backfill legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.ConfigEvolve,
      reason: "§3.4 non-port: behavior_set legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.Identity,
      reason: "§3.4 non-port: behavior_set legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.Sandbox,
      reason: "§3.4 non-port: behavior_set legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.ApiKeys,
      reason: "§3.4 non-port: behavior_set legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.CcHeadlessAgent,
      reason: "§3.4 non-port: behavior_set legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.ExternalMirror,
      reason:
        "§3.4 non-port: behavior_set/kind_base_backfill legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.CurlAgent,
      reason: "§3.4 non-port: behavior_set legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.Publisher.SessionImpl,
      reason:
        "§3.4 non-port: behavior_set/kind_base_backfill legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.SupervisorApproval,
      reason: "§3.4 non-port: kind_base_backfill legacy table atom → registration data (C5)"
    },
    %{
      module: Ezagent.ActionSet.Manage,
      reason:
        "§3.4 non-port: universal_behaviors references a POLICY ActionSet as data → registration (C5)"
    }
  ]

  @reverse_frozen_size 31

  # ════════════════════════════════════════════════════════════════════════════
  # FORWARD tests
  # ════════════════════════════════════════════════════════════════════════════

  test "no non-framework code reaches INTO the actor internals (§4.2 forward)" do
    allow = forward_active_allowlist()

    offenders =
      forward_offenders()
      |> Enum.reject(&MapSet.member?(allow, &1.file))

    assert offenders == [],
           """
           Actor-internals boundary gate (FORWARD / reach-in, §4.2): a
           non-framework module touches an actor internal directly. Route it
           through the §2.2 public read surface (Kind.read/3, read_classified/2,
           read_durable/3 + read_durable_many/3, alive?/1, self?/1,
           list_instances/0, resolve_action_subject/2) instead. New offenders
           (internal touched — file:line):

           #{format_forward(offenders)}

           Full census: ACTOR_BOUNDARY_ALLOWLIST=empty mix test #{Path.relative_to(__ENV__.file, @repo_root)}
           """
  end

  test "forward empty-allowlist enumerator prints the §4.4 census" do
    offenders = forward_offenders()
    by_file = offenders |> Enum.group_by(& &1.file) |> Enum.sort_by(&elem(&1, 0))

    if enumerator_mode?() do
      IO.puts(
        "\n=== §4.4 census — reach-ins into actor internals " <>
          "(#{length(by_file)} files, #{length(offenders)} sites) ==="
      )

      for {file, hits} <- by_file do
        internals =
          hits |> Enum.map(& &1.internal) |> Enum.uniq() |> Enum.sort() |> Enum.join(", ")

        IO.puts("  #{file}  [#{internals}]")

        for %{line: l, internal: i} <- Enum.sort_by(hits, & &1.line) do
          IO.puts("      :#{l}  #{i}")
        end
      end
    end

    assert offenders != [],
           "non-framework code must reach into internals today, or the gate is vacuous"
  end

  test "the forward ledger is exact — every allowlisted file still reaches in" do
    live = forward_offenders() |> Enum.map(& &1.file) |> MapSet.new()
    stale = Enum.reject(@forward_allowlist, &MapSet.member?(live, &1.file))

    assert stale == [],
           """
           Stale forward-ledger entries (file no longer reaches into internals —
           remove them; the ratchet only shrinks):

           #{Enum.map_join(stale, "\n", &("  " <> &1.file))}
           """

    for entry <- @forward_allowlist do
      assert is_binary(entry.reason) and String.trim(entry.reason) != "",
             "forward ledger entry #{entry.file} must carry a reason"
    end
  end

  test "the forward ledger only shrinks (ratchet, §4.2)" do
    assert length(@forward_allowlist) <= @forward_frozen_size,
           "the forward census GREW (#{length(@forward_allowlist)} > #{@forward_frozen_size}); it may only shrink"

    assert length(Enum.uniq_by(@forward_allowlist, & &1.file)) == length(@forward_allowlist),
           "duplicate file in the forward ledger"
  end

  test "the forward gate has teeth — each banned shape is caught" do
    root_ref = "defmodule W do\n  def go(u), do: Ezagent.SnapshotStore.latest(u)\nend"

    aliased_root =
      "defmodule W do\n  alias Ezagent.KindRegistry\n  def go(u), do: KindRegistry.lookup(u)\nend"

    get_slice = "defmodule W do\n  def go(u), do: Ezagent.Kind.get_slice(u, :s)\nend"

    genserver =
      "defmodule W do\n  def go(p), do: GenServer.call(p, {:ezagent_get_slice, :s})\nend"

    sys = "defmodule W do\n  def go(p), do: :sys.get_state(p)\nend"
    ready = "defmodule W do\n  def go(u), do: Ezagent.ReadyGate.await(u)\nend"
    runtime = "defmodule W do\n  def go(x), do: Ezagent.Kind.Runtime.Context.build(x)\nend"

    for src <- [root_ref, aliased_root, get_slice, genserver, sys, ready, runtime] do
      assert forward_offenses_in_source(src, "apps/x/lib/w.ex") != [],
             "forward gate must flag a reach-in:\n#{src}"
    end
  end

  test "the forward gate has no false positives" do
    # register_external_gate is allowed; the public read surface + dispatch are
    # allowed; stdlib is allowed.
    benign = """
    defmodule Fine do
      def wire, do: Ezagent.ReadyGate.register_external_gate(SomeGate)
      def read(u), do: Ezagent.Kind.read(u, :s)
      def alive(u), do: Ezagent.Kind.alive?(u)
      def dispatch(inv), do: Ezagent.Invocation.dispatch(inv)
      def other(p), do: GenServer.call(p, {:run_tool, :x})
      def std, do: Enum.map([1], & &1)
    end
    """

    assert forward_offenses_in_source(benign, "apps/x/lib/fine.ex") == []
  end

  # ════════════════════════════════════════════════════════════════════════════
  # REVERSE tests (companion — the §3.4 port worklist)
  # ════════════════════════════════════════════════════════════════════════════

  test "the actor framework makes no un-ported upward reference into staying core (§4.2 reverse)" do
    allow = reverse_active_allowlist()
    offenders = reverse_offenders() |> Enum.reject(&(&1.module in allow))

    assert offenders == [],
           """
           Actor-internals boundary gate (REVERSE / upward, §4.2): a mover-set file
           references a staying-core module that is neither in the mover set nor a
           §3.4 port. After the app split this is a compile error. Re-shape it into
           a port. New offenders (module — file:line):

           #{format_reverse(offenders)}
           """
  end

  test "reverse empty-allowlist enumerator prints the §3.4 port worklist" do
    offenders = reverse_offenders()
    by_module = offenders |> Enum.group_by(& &1.module) |> Enum.sort_by(&elem(&1, 0))

    if enumerator_mode?() do
      IO.puts(
        "\n=== §3.4 port worklist — mover-set upward refs " <>
          "(#{length(by_module)} modules, #{length(offenders)} sites) ==="
      )

      for {module, hits} <- by_module do
        IO.puts("  #{inspect(module)}  (#{length(hits)} sites)")
      end
    end

    assert offenders != [],
           "the mover set must reference staying core today, or the gate is vacuous"
  end

  test "the reverse ledger is exact — every allowlisted module is still an offender" do
    live = reverse_offenders() |> Enum.map(& &1.module) |> MapSet.new()
    stale = Enum.reject(@reverse_allowlisted_modules, &MapSet.member?(live, &1.module))

    assert stale == [],
           "stale reverse-ledger entries:\n#{Enum.map_join(stale, "\n", &("  " <> inspect(&1.module)))}"

    for entry <- @reverse_allowlisted_modules do
      assert is_binary(entry.reason) and String.trim(entry.reason) != "",
             "reverse ledger entry #{inspect(entry.module)} must carry a reason"
    end
  end

  test "the reverse ledger only shrinks (ratchet, §4.2)" do
    assert length(@reverse_allowlisted_modules) <= @reverse_frozen_size,
           "the reverse ledger GREW (#{length(@reverse_allowlisted_modules)} > #{@reverse_frozen_size})"

    assert length(Enum.uniq_by(@reverse_allowlisted_modules, & &1.module)) ==
             length(@reverse_allowlisted_modules),
           "duplicate module in the reverse ledger"
  end

  test "the reverse fixed allowlist entry is real (LegacyCallbacks quoted-injection)" do
    entry = hd(@reverse_fixed_allowlist)
    source = File.read!(Path.join([@repo_root, @core_lib, entry.file]))

    assert String.contains?(source, "Ezagent.Capability.cap"),
           "fixed-allowlist file #{entry.file} no longer quotes Ezagent.Capability.cap — remove it"
  end

  test "the reverse gate has teeth — each of call/atom/struct is caught" do
    call_shape =
      "defmodule Ezagent.Kind.F do\n  def go, do: Ezagent.Cap.DeliveryOutbox.replay?(:x)\nend"

    atom_shape =
      "defmodule Ezagent.Kind.F do\n  @t [Ezagent.SagaRunner.Saga]\n  def t, do: @t\nend"

    struct_shape = "defmodule Ezagent.Kind.F do\n  def m(%Ezagent.Capability{} = c), do: c\nend"

    for src <- [call_shape, atom_shape, struct_shape] do
      assert reverse_offenses_in_source(src, "ezagent/kind/f.ex", MapSet.new()) != [],
             "reverse gate must flag an upward reference:\n#{src}"
    end
  end

  test "the reverse gate has no false positives (self-refs, stdlib, __MODULE__)" do
    own = MapSet.new([Ezagent.Kind.Server, Ezagent.Kind.BehaviorSet, Ezagent.URI])

    benign = """
    defmodule Ezagent.Kind.Server do
      alias Ezagent.Kind.BehaviorSet
      def go(uri) do
        _ = BehaviorSet.resolve_action(__MODULE__, :x, %{})
        _ = Ezagent.URI.to_string(uri)
        Enum.map([1, 2], &(&1 + 1))
      end
    end
    """

    assert reverse_offenses_in_source(benign, "ezagent/kind/server.ex", own) == []
  end

  # ════════════════════════════════════════════════════════════════════════════
  # FORWARD scan implementation
  # ════════════════════════════════════════════════════════════════════════════

  defp forward_offenders do
    mover_abs = MapSet.new(@mover_files, &Path.join([@repo_root, @core_lib, &1]))

    @repo_root
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(mover_abs, &1))
    |> Enum.flat_map(fn abs ->
      rel = Path.relative_to(abs, @repo_root)
      forward_offenses_in_source(File.read!(abs), rel)
    end)
  end

  defp forward_offenses_in_source(source, rel) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        aliases = collect_aliases(ast)
        pg_allowed? = MapSet.member?(@process_generation_consumers, rel)

        {_, hits} =
          Macro.prewalk(ast, [], fn node, acc ->
            {node, forward_offense(node, aliases, pg_allowed?) ++ acc}
          end)

        hits
        |> Enum.map(&Map.put(&1, :file, rel))
        |> Enum.uniq()

      {:error, _} ->
        []
    end
  end

  # `:sys.get_state/replace_state` — MUST precede the general call clause below
  # (which would otherwise match `:sys` as the receiver and drop it).
  defp forward_offense({{:., _, [:sys, fun]}, meta, _args}, _aliases, _pg)
       when fun in [:get_state, :replace_state] do
    [forward_hit(":sys.#{fun}", meta)]
  end

  # Qualified calls: get_slice ratchet / ReadyGate-except-register / process-gen /
  # GenServer :ezagent_* / banned-root receiver.
  defp forward_offense({{:., _, [modast, fun]}, meta, args}, aliases, pg_allowed?)
       when is_atom(fun) and is_list(args) do
    module = resolve_ast(modast, aliases)

    cond do
      fun in @kind_read_calls and module == Ezagent.Kind ->
        [forward_hit("Kind.#{fun} (ratchet→C7)", meta)]

      fun != @ready_gate_allowed_fn and module == Ezagent.ReadyGate ->
        [forward_hit("ReadyGate.#{fun}", meta)]

      fun == @process_generation_fn and module == Ezagent.Cap.Authority ->
        if pg_allowed?,
          do: [],
          else: [forward_hit("Cap.Authority.current_process_generation", meta)]

      fun in [:call, :cast] and module == GenServer and args_have_ezagent_atom?(args) ->
        [forward_hit("GenServer.#{fun}(:ezagent_*)", meta)]

      banned_internal_root?(module) ->
        [forward_hit(short(module), meta)]

      true ->
        []
    end
  end

  # Bare/aliased reference to a banned internal root in any non-call position
  # (data tables, specs, struct patterns).
  defp forward_offense({:__aliases__, meta, parts}, aliases, _pg) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = resolve(parts, aliases)
      if banned_internal_root?(module), do: [forward_hit(short(module), meta)], else: []
    else
      []
    end
  end

  defp forward_offense(_node, _aliases, _pg), do: []

  defp forward_hit(internal, meta), do: %{internal: internal, line: Keyword.get(meta, :line, 0)}

  defp banned_internal_root?(nil), do: false

  defp banned_internal_root?(module) do
    MapSet.member?(@banned_internal_modules, module) or
      String.starts_with?(Atom.to_string(module), @banned_internal_prefix)
  end

  defp args_have_ezagent_atom?(args) do
    {_, found?} =
      Macro.prewalk(args, false, fn
        atom, acc when is_atom(atom) ->
          {atom, acc or String.starts_with?(Atom.to_string(atom), "ezagent_")}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp forward_active_allowlist do
    if enumerator_mode?(), do: MapSet.new(), else: MapSet.new(@forward_allowlist, & &1.file)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # REVERSE scan implementation
  # ════════════════════════════════════════════════════════════════════════════

  defp reverse_offenders do
    own = own_modules()

    Enum.flat_map(@mover_files, fn rel ->
      path = Path.join([@repo_root, @core_lib, rel])
      reverse_offenses_in_source(File.read!(path), rel, own)
    end)
  end

  # Every module DEFINED anywhere in the mover set — references to these are
  # self-references, never offenders. Derived, not hand-maintained.
  defp own_modules do
    Enum.reduce(@mover_files, MapSet.new(), fn rel, acc ->
      path = Path.join([@repo_root, @core_lib, rel])

      case Code.string_to_quoted(File.read!(path)) do
        {:ok, ast} ->
          {_, mods} =
            Macro.prewalk(ast, acc, fn
              {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, a ->
                {node, MapSet.put(a, Module.concat(parts))}

              node, a ->
                {node, a}
            end)

          mods

        {:error, _} ->
          acc
      end
    end)
  end

  defp reverse_offenses_in_source(source, rel, own) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        aliases = collect_aliases(ast)

        {_, hits} =
          Macro.prewalk(ast, [], fn node, acc ->
            {node, reverse_reference_hit(node, rel, aliases, own) ++ acc}
          end)

        Enum.reject(hits, &reverse_fixed_allowlisted?/1)

      {:error, _} ->
        []
    end
  end

  defp reverse_reference_hit({:__aliases__, meta, parts}, rel, aliases, own)
       when is_list(parts) do
    if Enum.all?(parts, &is_atom/1) do
      module = resolve(parts, aliases)

      if reverse_staying_core?(module) and not MapSet.member?(own, module) do
        [%{module: module, file: rel, line: Keyword.get(meta, :line, 0)}]
      else
        []
      end
    else
      []
    end
  end

  defp reverse_reference_hit(_node, _rel, _aliases, _own), do: []

  defp reverse_fixed_allowlisted?(%{file: file, module: module}) do
    Enum.any?(@reverse_fixed_allowlist, &(&1.file == file and &1.module == module))
  end

  # Bare umbrella-facade roots (`Ezagent`, `EzagentCore`) are excluded: a
  # length-1 reference is a `alias Ezagent.{…}` brace PREFIX, never a real dep.
  defp reverse_staying_core?(module) do
    s = Atom.to_string(module)
    String.starts_with?(s, "Elixir.Ezagent.") or String.starts_with?(s, "Elixir.EzagentCore.")
  end

  defp reverse_active_allowlist do
    if enumerator_mode?(),
      do: MapSet.new(),
      else: MapSet.new(@reverse_allowlisted_modules, & &1.module)
  end

  # ════════════════════════════════════════════════════════════════════════════
  # Shared helpers
  # ════════════════════════════════════════════════════════════════════════════

  defp enumerator_mode?, do: System.get_env("ACTOR_BOUNDARY_ALLOWLIST") == "empty"

  defp short(module), do: module |> Module.split() |> Enum.join(".")

  defp resolve_ast({:__aliases__, _, parts}, aliases) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: resolve(parts, aliases), else: nil
  end

  defp resolve_ast(mod, _aliases) when is_atom(mod), do: mod
  defp resolve_ast(_other, _aliases), do: nil

  defp resolve([first | rest], aliases) do
    parts =
      case Map.get(aliases, first) do
        nil -> [first | rest]
        full -> full ++ rest
      end

    # An `alias __MODULE__.X` poisons the alias map with a non-atom part; return
    # nil (no cross-boundary module) rather than crash Module.concat.
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  # `alias Foo.Bar` → %{Bar: [:Foo, :Bar]}; `alias Foo.Bar, as: B` → %{B: [...]};
  # `alias Foo.{Bar, Baz}` → both.
  defp collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, kids}]} = node, acc
        when is_list(kids) ->
          acc =
            Enum.reduce(kids, acc, fn
              {:__aliases__, _, [last]}, a -> Map.put(a, last, prefix ++ [last])
              _, a -> a
            end)

          {node, acc}

        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as_name]} -> {node, Map.put(acc, as_name, parts)}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp format_forward([]), do: "(none)"

  defp format_forward(offenders) do
    offenders
    |> Enum.sort_by(&{&1.file, &1.line})
    |> Enum.map_join("\n", fn %{internal: i, file: f, line: l} -> "  #{i} — #{f}:#{l}" end)
  end

  defp format_reverse([]), do: "(none)"

  defp format_reverse(offenders) do
    offenders
    |> Enum.sort_by(&{inspect(&1.module), &1.file, &1.line})
    |> Enum.map_join("\n", fn %{module: m, file: f, line: l} -> "  #{inspect(m)} — #{f}:#{l}" end)
  end
end
