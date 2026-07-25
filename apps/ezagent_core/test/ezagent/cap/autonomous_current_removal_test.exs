defmodule Ezagent.Cap.AutonomousCurrentRemovalTest do
  @moduledoc """
  Actor-framework extraction chunk C4 (spec
  `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md`
  §5-C4): removal of the `Ezagent.Cap.Authorize.autonomous_current?/1`
  process-generation authz-decision branch — `principal_current?` collapses to
  `holder_caps(holder) != []`.

  This module lands WITH the deletion and holds:

    * the **precondition-1 enumerator** (Pillar-B): every principal that could
      pass `principal_current?` ONLY via the deleted process-generation branch
      (an internal/ephemeral/autonomous principal authorizing ITSELF while
      inside its own authority compartment, where the DURABLE holder store is
      the source `EntityCaps.load` consults for the self-case) already holds a
      DURABLE current-generation self-license at ready — so the branch is dead
      code. The worklist is EMPTY (asserted per principal type);
    * the **transition tests t1–t5** the spec requires.

  ## Why the durable self-license is the whole proof

  `autonomous_current?/1` was the ONLY `principal_current?` branch that could
  admit a holder whose independently-loaded cap set is empty. That set is empty
  for a self-authorizing principal exactly when its DURABLE holder store lacks a
  current-generation self-license (`EntityCaps.load`'s self-case reads
  `load_persisted/1`). The creation-time mint (`maybe_mint_self_license`,
  gated `create_freshness: :created`) is persisted on the PRE-READY, FAIL-CLOSED
  boot path — snapshot-backed principals via `Kind.Server`'s
  `persist_initial_snapshot/3` (`{:stop, {:persistence_failed, _}}` on error,
  BEFORE `{:continue, :announce_ready}`); user-backed principals via
  `ActionSet.Identity.activate/2`'s marker-gated `UserStore.persist` (a failure
  crashes the pre-ready `:ezagent_activate` continuation, so `ReadyGate` never
  flips). Neither rides the best-effort `commit_post_init/2` (#342). So every
  self-authorizing principal holds a durable current self-license before ready,
  and the process-generation branch never decides an admission that
  `holder_caps` would not.

  The canonical admin's born-empty durable store is NOT a worklist entry: its
  currency is read via the LIVE `:identity` slice (the non-self holder path),
  proven by `EzagentDomainInstanceMessage.Integration.\
  CanonicalAdminBootstrapFreshBootTest` (born-empty admin seeds the default
  template) which stays green under this deletion.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.{Cap, Capability, EntityCaps}
  alias Ezagent.Ecto.KindSnapshot

  defmodule PrincipalKind do
    @moduledoc false
    @behaviour Ezagent.Kind
    @impl true
    def type_name, do: :agent
    @impl true
    def behaviors, do: [Ezagent.ActionSet.Identity]
    @impl true
    def persistence, do: {:snapshot, :on_change}
  end

  # ---------------------------------------------------------------------------
  # Precondition-1 enumerator — the worklist is empty.
  # ---------------------------------------------------------------------------

  describe "precondition-1 enumerator (worklist EMPTY)" do
    test "AGENT: durable current self-license at ready → in-compartment self-gate passes on holder_caps alone" do
      agent = unique_agent("enum")
      spawn_ready_agent(agent)

      # The durable store the in-turn self-case reads holds a CURRENT self-license.
      assert [lic] = self_licenses(EntityCaps.load_persisted(agent))
      assert Authority.verify_against_current(lic, agent, agent)

      # Inside its OWN authority compartment (what the deleted branch keyed on),
      # presenting no candidate cap, the principal gate now passes via
      # holder_caps — `:no_matching_cap` is the target-gate outcome, NOT
      # `:holder_revoked`. This is the branch-independent admission.
      {:ok, authority} = Authority.open(agent, :agent)

      assert {:error, :no_matching_cap} =
               Authority.with_current(authority, fn ->
                 Cap.authorize(agent, [], needed_any())
               end)
    end

    test "USER: durable current self-license at ready → self-gate passes on holder_caps alone" do
      user = unique_user("enum")
      assert {:ok, _} = Ezagent.Users.create(user, nil, [])
      assert :ok = Ezagent.Entity.spawn_principal(user)
      wait_ready(user)

      assert [ulic] = self_licenses(EntityCaps.load_persisted(user))
      assert Authority.verify_against_current(ulic, user, user)

      {:ok, authority} = Authority.open(user, :user)

      assert {:error, :no_matching_cap} =
               Authority.with_current(authority, fn ->
                 Cap.authorize(user, [], needed_any())
               end)
    end

    test "MECHANISM: an empty-holder principal INSIDE its current authority compartment is :holder_revoked (branch removed)" do
      # Before C4, a live process presenting its own URI while executing inside
      # its authority compartment with a matching generation passed
      # `principal_current?` via `autonomous_current?` EVEN WITH an empty holder
      # store. After C4 that admission is gone: `with_current` sets the exact
      # ambient state the branch read, yet the empty-holder principal is denied.
      agent = unique_agent("mech")
      spawn_ready_agent(agent)
      :ok = Ezagent.Kind.terminate(agent)

      # Bump the durable generation: the persisted self-license is now stale, so
      # the holder store loads EMPTY (G-3 gate).
      {:ok, bumped} = Authority.regenesis(agent, :agent)
      assert [] == self_licenses(EntityCaps.load_persisted(agent))

      # `with_current(bumped)` == "executing in the current-generation authority
      # compartment" — the pre-C4 branch would ADMIT here. Post-C4: denied.
      assert {:error, :holder_revoked} =
               Authority.with_current(bumped, fn ->
                 Cap.authorize(agent, [], needed_any())
               end)
    end

    test "REVOCATION GUARD: a gen-bump + `:existed` cold restart keeps the principal revoked (no resurrection)" do
      # The renewal must NEVER fire on a plain `:existed` restart — that would
      # resurrect a revoked principal. Mirrors SelfLicenseMintOnCreateTest.
      agent = unique_agent("guard")
      spawn_ready_agent(agent)

      {:ok, _bumped} = Authority.regenesis(agent, :agent)
      :ok = Ezagent.Kind.terminate(agent)
      :ok = Ezagent.SnapshotStore.delete(agent)
      refute Ezagent.Lifecycle.fresh_create?(agent), "marker intact → :existed restart"

      spawn_ready_agent(agent)

      assert [] == self_licenses(EntityCaps.load_persisted(agent)),
             "an :existed restart of a gen-bumped principal must NOT re-mint"
    end
  end

  # ---------------------------------------------------------------------------
  # Transition tests t1–t5.
  # ---------------------------------------------------------------------------

  describe "C4 transition tests" do
    test "t1: live generation bump makes a live principal inert (self-authorized gate denied)" do
      agent = unique_agent("t1")
      spawn_ready_agent(agent)
      assert [_lic] = self_licenses(EntityCaps.load(agent))

      # Standalone durable bump under the LIVE principal.
      {:ok, bumped} = Authority.regenesis(agent, :agent)

      # Its next self-authorized principal gate is denied — even simulating the
      # live process's own current-generation authority compartment.
      assert {:error, :holder_revoked} =
               Authority.with_current(bumped, fn ->
                 Cap.authorize(agent, [], needed_any())
               end)
    end

    test "t2: cold `:created` reprovision → ready holding a valid current-generation self-license (independent renew)" do
      agent = unique_agent("t2")
      spawn_ready_agent(agent)
      {:ok, first_gen} = Authority.current_generation(agent)

      # Bump, then reprovision as a genuine generation-crossing boot: clear the
      # ever-created marker (KindSnapshot.delete) so the restart is `:created`.
      {:ok, _bumped} = Authority.regenesis(agent, :agent)
      :ok = Ezagent.Kind.terminate(agent)
      :ok = KindSnapshot.delete(URI.to_string(agent))
      assert Ezagent.Lifecycle.fresh_create?(agent), "marker cleared → :created reprovision"

      spawn_ready_agent(agent)

      # Reaches ready holding a self-license valid against the CURRENT (bumped)
      # generation — minted fresh, with no dependence on the pre-bump license.
      {:ok, current_gen} = Authority.current_generation(agent)
      assert current_gen == first_gen + 1
      assert [lic] = self_licenses(EntityCaps.load_persisted(agent))
      assert Authority.verify_against_current(lic, agent, agent)
    end

    test "t3: the self-license is durable BEFORE readiness (ordering, not sleep-based)" do
      # `persist_initial_snapshot/3` runs SYNCHRONOUSLY in `init/1`, before the
      # `{:continue, :announce_ready}` that (through the post-init `:ezagent_\
      # activate` continuation) flips ReadyGate. So the instant `start_link/1`
      # returns, the durable snapshot already carries the current self-license
      # while ReadyGate has NOT yet reported ready — the committed row precedes
      # the observable ready, with no timing window in between.
      agent = unique_agent("t3")
      on_exit(fn -> _ = Ezagent.Kind.terminate(agent) end)

      {:ok, _pid} =
        Ezagent.Kind.Server.start_link({PrincipalKind, %{uri: agent, initial_caps: []}})

      # The durable row committed in init already carries the self-license...
      %KindSnapshot{state_binary: bin} = KindSnapshot.get(URI.to_string(agent))
      snapshot_caps = decode_identity_caps(bin)

      assert [lic] = self_licenses(snapshot_caps)
      assert Authority.verify_against_current(lic, agent, agent)

      # ...and it is committed no later than the moment ready becomes observable.
      wait_ready(agent)
      assert [ready_lic] = self_licenses(EntityCaps.load_persisted(agent))
      assert Authority.verify_against_current(ready_lic, agent, agent)
    end

    test "t4: first dispatch at the earliest observable ready authorizes via the durable self-license" do
      # No `autonomous_current?` remains to mask a window, so the durable
      # self-license MUST already authorize the very first dispatch admitted at
      # ready. Poll to the earliest observable ready, then immediately run the
      # principal gate on the self URI.
      agent = unique_agent("t4")
      spawn_ready_agent(agent)

      {:ok, authority} = Authority.open(agent, :agent)

      # At the earliest observable ready the principal gate is satisfied (target
      # gate, not principal, is the only thing an empty candidate list fails).
      assert {:error, :no_matching_cap} =
               Authority.with_current(authority, fn ->
                 Cap.authorize(agent, [], needed_any())
               end)
    end

    test "t5: the self-license persist is FAIL-CLOSED on the pre-ready path (never best-effort)" do
      # The spec's t5 guards against the self-license persist riding the
      # best-effort `commit_post_init/2` (#342: try/rescue + catch :exit → logs,
      # keeps in-memory, returns :ok, boot proceeds), which would let a persist
      # failure yield a READY principal whose currency exists only in memory.
      #
      # Structural falsifiable proof that it does NOT:
      server = server_source()

      # (a) the self-license reaches durable storage via the fail-closed initial
      #     snapshot persist, which STOPS the boot on error (never reaches ready).
      assert server =~ "persist_initial_snapshot(uri, kind_module, slice_state)"
      assert server =~ "{:stop, {:persistence_failed, reason}}"

      # (b) `persist_initial_snapshot/3` runs in `init/1` BEFORE the
      #     `{:continue, :announce_ready}` that flips ReadyGate.
      [init_head, _rest] = String.split(server, "{:continue, :announce_ready}", parts: 2)
      assert init_head =~ "persist_initial_snapshot"

      # (c) the best-effort `commit_post_init/2` is #342 by design and is NOT the
      #     path any self-license persist depends on (it returns :ok and lets
      #     boot proceed — used only for post-init slice mutations).
      commit_post_init =
        server
        |> String.split("defp commit_post_init(%{uri: uri,", parts: 2)
        |> List.last()
        |> String.split("defp ", parts: 2)
        |> List.first()

      assert commit_post_init =~ "best-effort"
      assert commit_post_init =~ "rescue"
      refute commit_post_init =~ "self_license"

      # (d) the user-backed self-license persist rides `activate/2`'s marker-gated
      #     projection persist (a failure crashes the pre-ready continuation),
      #     NOT a post-ready cast.
      identity =
        File.read!(
          Path.join(
            repo_root(),
            "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
          )
        )

      assert identity =~ "persist_user_caps_after_marker(uri, state.caps)"
      assert identity =~ "with :ok <- persist_user_caps_after_marker(uri, state.caps)"
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp needed_any,
    do: %{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any}

  defp self_licenses(caps),
    do: Enum.filter(caps, &(Capability.action_of(&1) == :self_license))

  defp unique_agent(suffix),
    do: Ezagent.URI.agent("c4-autonomous", "#{suffix}-#{System.unique_integer([:positive])}")

  defp unique_user(suffix),
    do: Ezagent.URI.user("c4-autonomous", "#{suffix}-#{System.unique_integer([:positive])}")

  defp spawn_ready_agent(uri) do
    on_exit(fn -> _ = Ezagent.Kind.terminate(uri) end)
    assert {:ok, _pid} = Ezagent.Kind.spawn(PrincipalKind, %{uri: uri, initial_caps: []})
    wait_ready(uri)
  end

  defp decode_identity_caps(state_binary) do
    state = :erlang.binary_to_term(state_binary)

    case Map.get(state, :identity) do
      %{state: %{caps: caps}} -> as_list(caps)
      %{caps: caps} -> as_list(caps)
      _ -> []
    end
  end

  defp as_list(%MapSet{} = set), do: MapSet.to_list(set)
  defp as_list(list) when is_list(list), do: list
  defp as_list(_), do: []

  defp server_source,
    do: File.read!(Path.join(repo_root(), "apps/ezagent_core/lib/ezagent/kind/server.ex"))

  defp repo_root, do: Path.expand("../../../../..", __DIR__)

  defp wait_ready(uri, attempts \\ 300)
  defp wait_ready(_uri, 0), do: flunk("principal did not become ready")

  defp wait_ready(uri, attempts) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        Process.sleep(10)
        wait_ready(uri, attempts - 1)
    end
  end
end
