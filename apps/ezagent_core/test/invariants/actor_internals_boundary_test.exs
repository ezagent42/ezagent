defmodule EzagentCore.Invariants.ActorInternalsBoundaryTest do
  @moduledoc """
  Actor-framework extraction boundary gate — chunk C0 (spec §4). Delegates all
  scanning + enforcement to the SHARED `Ezagent.ActorBoundaryScanner` (SSOT,
  §4.5) so this ExUnit gate (PR-gate parity) and `mix ezagent.check_invariants`
  invariant #13 (ci.local parity) enforce the identical ledger.

  Two directions (§4.2): FORWARD — non-framework code must not reach INTO actor
  internals (seeds the §4.4 census); REVERSE — the mover set must not reach UP
  into staying-core (seeds the §3.4 port worklist).

  ## SITE-level ratchet

  The ledger (`Ezagent.ActorBoundaryLedger`) is a set of SITE fingerprints
  `{path, target, content_sha}`. Enforcement = `scanned − ledger == []`, so a
  NEW reach-in — even inside an already-allowlisted file, or naming an
  already-allowlisted module — has a new content SHA, is absent from the ledger,
  and REDs the gate (proven by the enforcement self-tests below). The ledger can
  only shrink: a stale entry fails the exact test.

  ## Re-seeding the ledger

      ACTOR_BOUNDARY_ALLOWLIST=empty mix test \
        apps/ezagent_core/test/invariants/actor_internals_boundary_test.exs

  prints every scanned site; regenerate `Ezagent.ActorBoundaryLedger` from it
  when reach-ins migrate.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActorBoundaryScanner, as: Scanner

  # Committed ledger sizes — the ratchet asserts the live ledger never GROWS past
  # these. Later chunks LOWER them as reach-ins migrate / ports land.
  # C1 lowered forward 259→255: EntityCaps load path off actor internals
  # (KindRegistry self-detect → self?/1; get_slice → read/3 spawn: :never;
  # snapshot_caps SnapshotStore → read_durable/3), −4 sites.
  # C2 lowered forward 255→244: cold/durable reads onto Kind.read/3 +
  # read_durable/3 (session_reads/identity_data/web/uri_query/agent-credential), −11 sites.
  # (recipe_resolver stays: legacy dual-key needs full durable state, deferred.)
  # C3 lowered forward 244→208: KindRegistry/ReadyGate consumers → the §2.2
  # public liveness surface (lookup-for-aliveness → alive?/1; lookup-for-self →
  # self?/1; list_all → list_instances/0; lookup-for-pid → list_instances/0;
  # cap.action_context + tools/cc_seed template reads off raw runtime_view →
  # resolve_action_subject/2 + read/3), −36 sites across 23 files.
  # C4 lowered forward 208→207: the `autonomous_current?/1` process-generation
  # authz-decision branch (`cap/authorize.ex`) is deleted — `principal_current?`
  # collapses to `holder_caps != []`; the two generation-FENCE consumers
  # (`cap.ex`, `entity/token.ex`) survive on the fixed allowlist, −1 site.
  # C6 lowered forward 207→185: session-domain get_slice/get_raw_slice sites
  # migrate onto read/3 (live-only probes → spawn: :never; raw-slice manual
  # two-container unwraps deleted — read/3 normalizes), −22 sites.
  # C6 lowered forward 185→171: plugin get_slice sites → read/3 spawn: :never;
  # curl_agent's hand-rolled SnapshotStore cold fallback DELETED (read/3
  # default spawn rehydrates), −14 sites (13 get_slice + 1 SnapshotStore).
  # C6 lowered forward 171→158: domain/web/core get_slice sites → read/3
  # (socialware, identity, git, external_mirror, agent, ui, web probes →
  # spawn: :never; core sandbox.ex read_persisted_state drops its hand-rolled
  # SnapshotStore fallback → read/3 default spawn), −13 sites (11 get_slice
  # + 2 SnapshotStore). Residual: lifecycle_case.ex get_raw_slice ×2 stays
  # ledgered — raw %{state, transients} introspection has no §2.2 public
  # replacement.
  # C7 chunk-4a lowered forward 158→157: `Kind.get_raw_slice/2` retired from the
  # public surface; lifecycle_case's two raw reach-ins collapse into ONE private
  # `raw_slice!/2` helper calling `Ezagent.Kind.SliceAccess.get_raw_slice/2`
  # directly (−1 site).
  # #189 PR-3 FIX 4 raised forward 157→164 (+7): the GOVERNED Session
  # self-license migration (`SessionSelfLicenseMigration`, 5 sites) + the
  # barrier's session principal-gap scan (`fleet_parity.ex`, 2 sites). A
  # low-level snapshot enumerate/rewrite/persist migration has no §2.2
  # write-surface equivalent, and marker-only detection needs the raw state
  # emptiness `read_durable` normalizes away — same rationale as the ledgered
  # `kind_base_backfill` one-shot migration. Burn-down when a governed
  # snapshot-migration facade lands.
  @forward_frozen 164
  @forward_fixed_frozen 2
  # C5 chunk-1 lowered reverse 123→110: repo injection (§3.4) — snapshot_store
  # + ecto/kind_snapshot `EzagentCore.Repo` refs → the config-resolved
  # `:ezagent_actor, :repo` injection, −13 sites.
  # C5 chunk-1 lowered reverse 110→105: pubsub injection (§3.4) — effects /
  # invocation / slice_change `EzagentCore.PubSub` refs → the config-resolved
  # `:ezagent_actor, :pubsub` injection, −5 sites.
  # C5 chunk-1 lowered reverse 105→101: PersistencePort (§3.4 NEW) — kind/
  # snapshot + snapshot_store workspace derivation, ecto/kind_snapshot
  # scope_by_workspace + TransientRetry → the config-resolved
  # `:ezagent_actor, :persistence` adapter, −4 sites.
  # C5 chunk-1 lowered reverse 101→98: DeadLetterPort (§3.4 NEW) — invocation
  # buffer_full/stale_incarnation + ready_transition drain DLQ writes → the
  # config-resolved `:ezagent_actor, :dead_letter` adapter, −3 sites.
  # C5 chunk-1 lowered reverse 98→93: SagaPort (§3.4 NEW) — router
  # dispatch_saga + effects :saga effect → the config-resolved
  # `:ezagent_actor, :saga` adapter (the ensure_loaded probe + is_struct
  # check MOVE into the core adapter), −5 sites.
  # C5 chunk-1 lowered reverse 93→89: EventLogPort (§3.4 NEW, respec'd) —
  # effects :emit append + Router's 2 dead map-form audit sites onto the
  # single 4-arg contract (adapter derives workspace_uri from the target),
  # −3 sites; the respec also orphaned effects' private Capability-based
  # workspace-derivation helper (deleted with it), −1 site.
  # C5 chunk-2 lowered reverse 89→78: CapabilityPort (§3.4 NEW) — runtime
  # workspace-isolation + receipt emission workspace_of/cross_workspace?/
  # identity_key → the config-resolved `:ezagent_actor, :capability`
  # adapter, −7 sites; the §3.4 opacity typespec demotions
  # (`Ezagent.Capability.t()` → `term()` in behavior/cmd/invocation ctx
  # specs + the receipt maybe_emit spec), −4 sites.
  # C5 chunk-2 lowered reverse 78→68: OutboxPort (§3.4) — the SEVEN
  # `Ezagent.Cap.DeliveryOutbox` functions (dispatch replay?/eligible?/
  # enqueue_and_attempt, server mark_applied/record_handler_failure,
  # ready_transition pending_target?/drain_target) → the config-resolved
  # `:ezagent_actor, :outbox` adapter, −10 sites.
  # C5 chunk-2 lowered reverse 68→58: DispatchPolicyPort (§3.4) — dispatch
  # origin-validate + owner-gate + admin-cap materialization fold into ONE
  # `before_delivery/1` hook (materialize_admin_action_cap +
  # globally_non_cap_action? MOVED into the core adapter), the in-actor
  # origin re-check + spawn/liveness owner gates → the config-resolved
  # `:ezagent_actor, :dispatch_policy` adapter, −8 sites; the
  # `Ezagent.DispatchOrigin.t()` typespec demotions (cmd/invocation origin
  # specs → `term()`), −2 sites.
  # C5 chunk-2 lowered reverse 58→43: AuthzPort (§3.4) — the
  # `holds_cap?/default_holds_cap?` block RELOCATED out of `Ezagent.Kind`
  # into the core spine `Ezagent.Cap.HoldsCap` (reached via the port;
  # `Ezagent.Kind` keeps thin delegates), −11 sites; dispatch step-5.5
  # `Cap.Verifier.authorize` + the `{:cap, :grant}` path (opacity demotion
  # at runtime.ex — plain `cap` binding, adapter validates) →
  # authorize_dispatch/authorize_and_issue_grant, −3 sites;
  # `CapabilityRegistry.data_owner_of` (behavior/introspection), −1 site.
  # C5 chunk-2 lowered reverse 43→24: AuthorityPort (§3.4) — server
  # open/with_current/retire/regenesis (+ the generation field read →
  # `generation/1`, authority now OPAQUE) + the artifact handlers
  # (validate/verify; the `:ezagent_verify_cap_artifact` struct match
  # demoted to a plain binding — adapter validates), runtime's
  # `with_runtime_view` (KEPT AS-IS, full state), snapshot's
  # `verified_set`, lifecycle's destroy-path `retire` → the
  # config-resolved `:ezagent_actor, :authority` adapter, −19 sites.
  # C5 chunk-2 lowered reverse 24→1: §3.4 non-port findings — the
  # `BehaviorSet` `@slice_owners`/`@required_reads` tables (−15) and the
  # `KindBaseBackfill` as-built sets (−8) INVERTED to registration data
  # (values in core-side `wire!/0`, read from app env at runtime; the
  # framework source names no domain/plugin ActionSet). The 5 core POLICY
  # ActionSets STAY; the residual single site is `UniversalBehaviors`'s
  # `Ezagent.ActionSet.Manage` reference (§6.8 config-list inversion
  # deferred — core-policy module, boot-registered).
  @reverse_frozen 1
  @reverse_fixed_frozen 3

  # ── FORWARD (§4.2 "The rule") ──────────────────────────────────────────────

  test "no non-framework code reaches INTO the actor internals (§4.2 forward)" do
    offenders = Scanner.forward_new_offenders()

    assert offenders == [],
           """
           FORWARD reach-in gate (§4.2): a non-framework module touches an actor
           internal directly. Route it through the §2.2 read surface (Kind.read/3,
           read_classified/2, read_durable/3 + read_durable_many/3, alive?/1,
           self?/1, list_instances/0, resolve_action_subject/2). New offenders:

           #{format_sites(offenders)}
           """
  end

  test "the forward ledger only shrinks — no stale entries (§4.2 ratchet)" do
    stale = Scanner.forward_stale()

    assert stale == [],
           "stale forward-ledger entries (migrated — remove them):\n#{format_sites(stale)}"

    assert Scanner.forward_fixed_missing() == [],
           "a fixed process-generation consumer site vanished (door check)"
  end

  test "the forward ledger does not grow past the frozen size" do
    # Sizes are frozen literals; the ratchet may only shrink. (Duplicate
    # identities are legitimate — two byte-identical reach-in lines in one file —
    # and enforcement is by frequency, so no uniqueness assertion here.)
    assert length(Scanner.forward_ratchet()) <= @forward_frozen
    assert length(Scanner.forward_fixed()) <= @forward_fixed_frozen
  end

  test "FORWARD enforcement is SITE-level — a NEW reach-in in an allowlisted FILE REDs" do
    # entity_caps.ex is already in the forward ledger (existing reach-ins).
    allowlisted = "apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex"
    assert Enum.any?(Scanner.forward_ratchet(), &(&1.path == allowlisted))

    ledger = Scanner.forward_ratchet() ++ Scanner.forward_fixed()

    # A NEW, distinct reach-in scanned AS that already-allowlisted file. The
    # distinctive arg guarantees a fresh content SHA absent from the ledger.
    injected =
      Scanner.forward_sites_in_source(
        "defmodule X do\n  def go(u), do: Ezagent.SnapshotStore.latest(u, :gate_teeth_probe)\nend",
        allowlisted
      )

    assert injected != []

    # The ENFORCEMENT decision itself flags the injected site — the file already
    # being in the ledger does NOT cover a new-content reach-in.
    assert Scanner.new_offenders(ledger ++ injected, ledger) == injected
  end

  # ── REVERSE (§4.2 "Reverse direction") ─────────────────────────────────────

  test "the actor framework makes no un-ported upward reference into staying core (§4.2 reverse)" do
    offenders = Scanner.reverse_new_offenders()

    assert offenders == [],
           """
           REVERSE upward gate (§4.2): a mover-set file references a staying-core
           module that is neither in the mover set nor a §3.4 port. Re-shape it
           into a port. New offenders:

           #{format_sites(offenders)}
           """
  end

  test "the reverse ledger only shrinks — no stale entries (§4.2 ratchet)" do
    stale = Scanner.reverse_stale()
    assert stale == [], "stale reverse-ledger entries:\n#{format_sites(stale)}"

    assert length(Scanner.reverse_ratchet()) <= @reverse_frozen
    assert length(Scanner.reverse_fixed()) <= @reverse_fixed_frozen
  end

  test "REVERSE enforcement is SITE-level — a NEW upward ref to an allowlisted MODULE REDs" do
    # Ezagent.Capability is already allowlisted (existing mover-set refs).
    ledger = Scanner.reverse_ratchet() ++ Scanner.reverse_fixed()
    assert Enum.any?(ledger, &(&1.target == "Ezagent.Capability"))

    # A NEW %Ezagent.Capability{} pattern scanned AS a mover file. The distinctive
    # binding guarantees a fresh content SHA absent from the ledger.
    injected =
      Scanner.reverse_sites_in_source(
        "defmodule Ezagent.Kind.Server do\n  def m(%Ezagent.Capability{} = gate_teeth_probe), do: gate_teeth_probe\nend",
        "apps/ezagent_actor/lib/ezagent/kind/server.ex",
        MapSet.new([Ezagent.Kind.Server])
      )

    assert injected != []

    # The ENFORCEMENT decision flags it — the module already being allowlisted
    # does NOT cover a new-content upward reference.
    assert Scanner.new_offenders(ledger ++ injected, ledger) == injected
  end

  # ── raw-scanner teeth + no-false-positives ─────────────────────────────────

  test "the forward scanner flags every banned shape" do
    root = "defmodule W do\n  def go(u), do: Ezagent.SnapshotStore.latest(u)\nend"

    aliased_root =
      "defmodule W do\n  alias Ezagent.KindRegistry\n  def go(u), do: KindRegistry.lookup(u)\nend"

    get_slice = "defmodule W do\n  def go(u), do: Ezagent.Kind.get_slice(u, :s)\nend"
    runtime_view = "defmodule W do\n  def go(p), do: Ezagent.Kind.runtime_view(p)\nend"

    genserver =
      "defmodule W do\n  def go(p), do: GenServer.call(p, {:ezagent_get_slice, :s})\nend"

    genserver_indirect =
      "defmodule W do\n  def go(p) do\n    msg = {:ezagent_get_slice, :s}\n    GenServer.call(p, msg)\n  end\nend"

    ready = "defmodule W do\n  def go(u), do: Ezagent.ReadyGate.await(u)\nend"
    runtime = "defmodule W do\n  def go(x), do: Ezagent.Kind.Runtime.Context.build(x)\nend"

    proc_gen =
      "defmodule W do\n  def go(u), do: Ezagent.Cap.Authority.current_process_generation(u)\nend"

    for src <- [
          root,
          aliased_root,
          get_slice,
          runtime_view,
          genserver,
          genserver_indirect,
          ready,
          runtime,
          proc_gen
        ] do
      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") != [],
             "forward scanner must flag a reach-in:\n#{src}"
    end
  end

  test "the forward scanner has no false positives (read surface, register_external_gate, stdlib)" do
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

    assert Scanner.forward_sites_in_source(benign, "apps/x/lib/fine.ex") == []
  end

  test "the forward scanner flags :sys.get_state / replace_state / get_status (actor-state bypass)" do
    for src <- [
          "defmodule W do\n  def go(pid), do: :sys.get_state(pid)\nend",
          "defmodule W do\n  def go(pid), do: :sys.replace_state(pid, fn s -> s end)\nend",
          "defmodule W do\n  def go(pid), do: :sys.get_status(pid)\nend"
        ] do
      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") != [],
             "a :sys reach into a live process must be flagged:\n#{src}"
    end

    # The Kind pids come from the C0 public surface — the concrete bypass:
    probe =
      "defmodule W do\n  def go do\n    [{_, %{pid: pid}} | _] = Ezagent.Kind.list_instances()\n    :sys.get_state(pid)\n  end\nend"

    assert Scanner.forward_sites_in_source(probe, "apps/x/lib/w.ex") != []
  end

  test "the current PTY/Python sidecar :sys sites are ledgered debt (not new offenders)" do
    sys_sites = Enum.filter(Scanner.forward_ratchet(), &String.starts_with?(&1.target, ":sys"))
    assert length(sys_sites) == 7

    assert Enum.all?(
             sys_sites,
             &(&1.path =~ "ezagent_domain_pty" or &1.path =~ "ezagent_domain_python")
           )

    # they are NOT flagged as new debt (they are in the frozen ledger)
    assert Enum.all?(
             Scanner.forward_new_offenders(),
             &(not String.starts_with?(&1.target, ":sys"))
           )
  end

  test "the forward scanner closes multi-hop message-aliasing evasions" do
    # two-hop alias: msg = {:ezagent_*}; fwd = msg; GenServer.call(pid, fwd)
    two_hop = """
    defmodule W do
      def go(pid) do
        msg = {:ezagent_runtime_view}
        fwd = msg
        GenServer.call(pid, fwd)
      end
    end
    """

    # helper-returned message: msg = build(); GenServer.call(pid, msg)
    helper = """
    defmodule W do
      def go(pid) do
        msg = build_msg()
        GenServer.call(pid, msg)
      end

      defp build_msg, do: {:ezagent_get_slice, :surface}
    end
    """

    for src <- [two_hop, helper] do
      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") != [],
             "an aliased/helper-produced :ezagent_* GenServer message must be flagged:\n#{src}"
    end
  end

  test "the forward scanner closes interprocedural function-argument relay (§C0-hardening a)" do
    # msg is tainted at the caller; it reaches GenServer.call ONLY through the
    # parameter `m` of a local relay helper — pure interprocedural param flow.
    relay = """
    defmodule W do
      def go(pid) do
        msg = {:ezagent_get_slice, :surface}
        relay(pid, msg)
      end

      defp relay(p, m), do: GenServer.call(p, m)
    end
    """

    assert Scanner.forward_sites_in_source(relay, "apps/x/lib/w.ex") != [],
           "an :ezagent_* message relayed through a function parameter must be flagged"
  end

  test "the forward scanner closes access-path field extraction (§C0-hardening b)" do
    # The :ezagent_* message is buried in a tainted container; the call extracts
    # it via dot / index / Map.fetch! / elem — never a bare var nor inline atom.
    mk = fn extract ->
      """
      defmodule W do
        def go(pid) do
          payload = %{m: {:ezagent_get_slice, :surface}}
          GenServer.call(pid, #{extract})
        end
      end
      """
    end

    for extract <- ["payload.m", "payload[:m]", "Map.fetch!(payload, :m)"] do
      assert Scanner.forward_sites_in_source(mk.(extract), "apps/x/lib/w.ex") != [],
             "an :ezagent_* message extracted via #{extract} must be flagged"
    end

    elem_src = """
    defmodule W do
      def go(pid) do
        payload = {:ezagent_get_slice, :surface}
        GenServer.call(pid, elem(payload, 0))
      end
    end
    """

    assert Scanner.forward_sites_in_source(elem_src, "apps/x/lib/w.ex") != [],
           "an :ezagent_* message extracted via elem/2 must be flagged"
  end

  test "the forward scanner closes simple destructuring taint (§C0-hardening b2)" do
    # {:box, msg} = tainted_container — the message is bound by a destructuring
    # match, then relayed.
    for lhs <- ["{:box, msg}", "%{m: msg}"] do
      src = """
      defmodule W do
        def go(pid) do
          payload = #{if lhs == "{:box, msg}", do: "{:box, {:ezagent_get_slice, :s}}", else: "%{m: {:ezagent_get_slice, :s}}"}
          #{lhs} = payload
          GenServer.call(pid, msg)
        end
      end
      """

      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") != [],
             "an :ezagent_* message bound by destructuring (#{lhs}) must be flagged"
    end
  end

  test "the forward scanner closes helper-chains >=2 deep (§C0-hardening c)" do
    # m = a(); a returns b(); b returns {:ezagent_*}. The producer is two hops
    # away — the 1-deep msg_fn heuristic misses it without a call-graph fixpoint.
    deep_chain = """
    defmodule W do
      def go(pid) do
        m = a()
        GenServer.call(pid, m)
      end

      defp a, do: b()
      defp b, do: {:ezagent_runtime_view}
    end
    """

    assert Scanner.forward_sites_in_source(deep_chain, "apps/x/lib/w.ex") != [],
           "an :ezagent_* message from a >=2-deep helper chain must be flagged"
  end

  test "the forward scanner RETAINS origin/main's broad indirect detection (no regression)" do
    # These two shapes are caught by origin/main's scanner. The §C0-hardening
    # protocol-verb allowlist must NOT weaken them (regression guard): an assigned
    # BARE message atom, and a runtime-ASSEMBLED message tuple.
    assigned_bare_atom =
      "defmodule W do\n  def go(pid) do\n    msg = :ezagent_get_slice\n    GenServer.call(pid, msg)\n  end\nend"

    runtime_tuple =
      "defmodule W do\n  def go(pid) do\n    msg = List.to_tuple([:ezagent_get_slice, :surface])\n    GenServer.call(pid, msg)\n  end\nend"

    for src <- [assigned_bare_atom, runtime_tuple] do
      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") != [],
             "a real Kind message reached indirectly must stay flagged:\n#{src}"
    end
  end

  test "the forward scanner does NOT taint on config/app-name :ezagent_* atoms (precision)" do
    # `:ezagent_domain_pty` / `:ezagent_role_registry` share the `ezagent_` prefix
    # but are OTP app / ETS-registry names, never Kind messages. Relaying one to a
    # GenServer.call must NOT be flagged (this is what fixed the 3 spurious sites).
    app_name =
      "defmodule W do\n  def go(pid) do\n    x = Application.get_env(:ezagent_domain_pty, :k)\n    GenServer.call(pid, x)\n  end\nend"

    registry_name =
      "defmodule W do\n  def go(pid) do\n    x = :ezagent_role_registry\n    GenServer.call(pid, x)\n  end\nend"

    for src <- [app_name, registry_name] do
      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") == [],
             "a config/app-name :ezagent_* atom must NOT be treated as a Kind message:\n#{src}"
    end
  end

  test "the forward scanner flags reflective :sys forms (apply/3 + :erlang.apply + var receiver)" do
    bare_apply = "defmodule W do\n  def go(pid), do: apply(:sys, :get_state, [pid])\nend"

    erlang_apply =
      "defmodule W do\n  def go(pid), do: :erlang.apply(:sys, :replace_state, [pid, fn s -> s end])\nend"

    var_receiver =
      "defmodule W do\n  def go(pid) do\n    s = :sys\n    s.get_status(pid)\n  end\nend"

    for src <- [bare_apply, erlang_apply, var_receiver] do
      assert Scanner.forward_sites_in_source(src, "apps/x/lib/w.ex") != [],
             "a reflective :sys reach into a live process must be flagged:\n#{src}"
    end
  end

  test "the reverse scanner flags call / atom / struct shapes; no self-ref/stdlib false positives" do
    call_shape =
      "defmodule Ezagent.Kind.F do\n  def go, do: Ezagent.Cap.DeliveryOutbox.replay?(:x)\nend"

    atom_shape =
      "defmodule Ezagent.Kind.F do\n  @t [Ezagent.SagaRunner.Saga]\n  def t, do: @t\nend"

    struct_shape = "defmodule Ezagent.Kind.F do\n  def m(%Ezagent.Capability{} = c), do: c\nend"

    for src <- [call_shape, atom_shape, struct_shape] do
      assert Scanner.reverse_sites_in_source(src, "apps/x/lib/f.ex", MapSet.new()) != [],
             "reverse scanner must flag an upward reference:\n#{src}"
    end

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

    assert Scanner.reverse_sites_in_source(benign, "apps/x/lib/server.ex", own) == []
  end

  test "the reverse fixed carve-out is real (LegacyCallbacks quotes Ezagent.Capability.cap)" do
    assert Scanner.reverse_fixed() != []

    source =
      File.read!(
        Path.join(
          Scanner.repo_root(),
          "apps/ezagent_actor/lib/ezagent/behavior/legacy_callbacks.ex"
        )
      )

    assert String.contains?(source, "Ezagent.Capability.cap")
  end

  # ── enumerator (re-seeding aid) ────────────────────────────────────────────

  test "the enumerator dumps the current census when ACTOR_BOUNDARY_ALLOWLIST=empty" do
    fwd = Scanner.forward_sites()
    rev = Scanner.reverse_sites()

    if System.get_env("ACTOR_BOUNDARY_ALLOWLIST") == "empty" do
      files = fwd |> Enum.map(& &1.path) |> Enum.uniq() |> length()
      IO.puts("\n=== §4.4 forward census (#{files} files, #{length(fwd)} sites) ===")

      for s <- Enum.sort_by(fwd, &{&1.path, &1.line}),
          do: IO.puts("  #{s.path}:#{s.line}  #{s.target}")

      IO.puts("=== §3.4 reverse worklist (#{length(rev)} sites) ===")

      for s <- Enum.sort_by(rev, &{&1.path, &1.line}),
          do: IO.puts("  #{s.path}:#{s.line}  #{s.target}")
    end

    assert fwd != [] and rev != [], "the scans must be non-empty, or the gate is vacuous"
  end

  defp format_sites([]), do: "(none)"

  # Scanned sites carry `:line`; ledger entries (stale/offender reports) do not —
  # default it so a shrink/stale failure message never itself KeyErrors.
  defp format_sites(sites),
    do:
      Enum.map_join(sites, "\n", fn s ->
        "  #{s.target} — #{s.path}:#{Map.get(s, :line, "?")}"
      end)
end
