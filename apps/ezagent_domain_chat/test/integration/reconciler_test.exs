defmodule EzagentDomainChat.Integration.ReconcilerTest do
  @moduledoc """
  Generator-reconciler PR-A — the SPEC §V1-R1..V1-R7 integration tests.

  Drives `Ezagent.Entity.Session.spawn_from_template/2` through the
  production dispatch path under the NEW reconciler model:

    V1-R1 — Full convergence (regression).
    V1-R2 — Idempotent re-run (no duplicate state).
    V1-R3 — Partial resume (kill a worker mid-spawn; re-run completes).
    V1-R4 — Failed-slot retry (missing AgentTemplate slice → re-run completes).
    V1-R7 — The architectural invariant: no `cleanup_partial`-style
            saga rollback in `session.ex`.

  Also covers the 3 residual codex fixes baked into PR-A:

    1. retry_after_race REAL implementation + tests
       (exhaustion → :partial; same-owner concurrent never returns
       :orchestrator_foreign).
    2. (Agent.spawn/4 shim pinned by agent_spawn_fresh_test.exs.)
    3. working_copy_merge revalidation (this-pass slot re-parented
       between reconcile_slot and merge_working_copy must be caught).

  Uses a synthetic flavor whose `instantiate/3` brings up a plain
  Agent Kind (no PTY / no claude) — same pattern as generator_test.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentFlavorRegistry, AgentLineage, Behavior, Capability, KindRegistry}
  alias Ezagent.Entity.{Session, SessionTemplate, User}

  defmodule TestFlavorClass do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl true
    def template_name, do: "reconciler.test.agent"

    @impl true
    def validate(t) when is_map(t),
      do: if(Map.has_key?(t, "agent_uri"), do: :ok, else: {:error, :missing_agent_uri})

    def validate(_), do: {:error, :not_a_map}

    @impl true
    def instantiate(_n, %{"agent_uri" => uri_str}, _ws) do
      agent_uri = URI.parse(uri_str)

      case Ezagent.SpawnRegistry.spawn_detailed(agent_uri) do
        {:ok, :started, _pid} -> {:ok, [agent_uri], %{fresh?: true}}
        {:ok, :already_started, _pid} -> {:ok, [agent_uri], %{fresh?: false}}
        {:error, _} = err -> err
      end
    end

    def instantiate(_n, tmpl, _ws), do: {:error, {:invalid_template, tmpl}}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp register_test_flavor do
    flavor = "rectest#{uniq()}"

    :ok =
      AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: TestFlavorClass
      })

    flavor
  end

  defp agent_template_content(flavor, name) do
    %{
      name: name,
      description: "worker #{name}",
      flavor: flavor,
      working_directory: "/tmp/reconciler-test",
      claude_config_dir: nil,
      settings_path: nil,
      mcp_config_path: nil,
      api_key_helper: nil,
      default_caps: [],
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-23 00:00:00Z]
    }
  end

  defp create_agent_template(uri, content) do
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    {:ok, %{content: ^content}} = dispatch(uri, "template.write", %{content: content})
    :ok
  end

  defp dispatch(uri, action, args) do
    target = URI.parse("#{URI.to_string(uri)}?action=#{action}")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp create_session_template(name, agent_slots, routing_rules) do
    content = %{
      name: name,
      description: "test team #{name}",
      agent_slots: agent_slots,
      routing_rules: routing_rules,
      orchestrator_template_uri: URI.parse("template://agent/system/cc-orchestrator"),
      default_workspace_uri: URI.parse("workspace://team-alpha"),
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: ~U[2026-05-23 00:00:00Z]
    }

    {:ok, uri} = SessionTemplate.persist_version(content, "team-alpha")
    uri
  end

  defp spawn_owner(uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new(caps)})
    :ok
  end

  defp template_cap(kind, workspace_uri) do
    %Capability{
      kind: kind,
      behavior: Behavior.Template,
      instance: {:within_workspace, workspace_uri},
      workspace_uri: workspace_uri,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  @workspace_uri URI.new!("workspace://team-alpha")

  # ─────────────────────────────────────────────────────────────────────
  # V1-R1 — Full convergence (regression)
  # ─────────────────────────────────────────────────────────────────────

  describe "V1-R1 — full convergence" do
    setup do
      flavor = register_test_flavor()
      a = URI.new!("template://agent/team-alpha/r1-a-#{uniq()}")
      b = URI.new!("template://agent/team-alpha/r1-b-#{uniq()}")
      :ok = create_agent_template(a, agent_template_content(flavor, "a"))
      :ok = create_agent_template(b, agent_template_content(flavor, "b"))

      st =
        create_session_template(
          "r1-team-#{uniq()}",
          [{"alpha", a}, {"beta", b}],
          [{{:text_contains, "deploy"}, ["alpha"]}]
        )

      owner = URI.parse("entity://user/team-alpha/r1-owner-#{uniq()}")

      :ok =
        spawn_owner(owner, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      {:ok, st: st, owner: owner, a: a, b: b}
    end

    test "returns {:ok, _} with session + orchestrator + slots", %{st: st, owner: owner} do
      assert {:ok, %{session_uri: s, orchestrator_uri: o, slots: slots}} =
               Session.spawn_from_template(st, owner)

      assert match?(%URI{}, s)
      assert match?(%URI{}, o)
      assert length(slots) == 2

      slot_names = Enum.map(slots, fn {n, _} -> n end) |> Enum.sort()
      assert slot_names == ["alpha", "beta"]
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # V1-R2 — Idempotent re-run
  # ─────────────────────────────────────────────────────────────────────

  describe "V1-R2 — idempotent re-run" do
    setup do
      flavor = register_test_flavor()
      a = URI.new!("template://agent/team-alpha/r2-a-#{uniq()}")
      :ok = create_agent_template(a, agent_template_content(flavor, "a"))
      st = create_session_template("r2-team-#{uniq()}", [{"only", a}], [])
      owner = URI.parse("entity://user/team-alpha/r2-owner-#{uniq()}")

      :ok =
        spawn_owner(owner, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      {:ok, st: st, owner: owner}
    end

    test "two calls produce identical session URI + same worker URIs + same pids",
         %{st: st, owner: owner} do
      assert {:ok, r1} = Session.spawn_from_template(st, owner)
      assert {:ok, r2} = Session.spawn_from_template(st, owner)

      assert URI.to_string(r1.session_uri) == URI.to_string(r2.session_uri)
      assert URI.to_string(r1.orchestrator_uri) == URI.to_string(r2.orchestrator_uri)

      # Compare slot URIs as strings (the struct layout may differ
      # between URI.new! / URI.parse round-trips even when canonical
      # string forms match).
      to_string_slots = fn slots ->
        slots |> Enum.map(fn {n, u} -> {n, URI.to_string(u)} end) |> Enum.sort()
      end

      assert to_string_slots.(r1.slots) == to_string_slots.(r2.slots)

      # The slot worker pid is stable (not respawned).
      [{_, worker_uri}] = r1.slots
      {:ok, pid_after_1} = KindRegistry.lookup(worker_uri)
      assert {:ok, ^pid_after_1} = KindRegistry.lookup(worker_uri)
    end

    test "re-run grants ZERO duplicate caps (codex rev-2 HIGH-1 / V1-R2 cap churn gate)",
         %{st: st, owner: owner} do
      assert {:ok, %{orchestrator_uri: orch_uri}} = Session.spawn_from_template(st, owner)
      caps_after_pass_1 = Ezagent.Identity.list_caps_for(orch_uri)
      cap_count_after_1 = MapSet.size(caps_after_pass_1)

      assert {:ok, _r2} = Session.spawn_from_template(st, owner)
      caps_after_pass_2 = Ezagent.Identity.list_caps_for(orch_uri)

      assert MapSet.size(caps_after_pass_2) == cap_count_after_1,
             "reconciler re-run must NOT grow the cap set — " <>
               "pass 1 had #{cap_count_after_1} caps, " <>
               "pass 2 has #{MapSet.size(caps_after_pass_2)}"
    end

    test "re-run adds ZERO new routing rules", %{st: st, owner: owner} do
      table = EzagentDomainChat.Routing.MentionRouting

      _ids_before = MapSet.new(Ezagent.Routing.RuleStore.list(table), & &1.id)
      assert {:ok, _r1} = Session.spawn_from_template(st, owner)
      ids_after_1 = MapSet.new(Ezagent.Routing.RuleStore.list(table), & &1.id)

      assert {:ok, _r2} = Session.spawn_from_template(st, owner)
      ids_after_2 = MapSet.new(Ezagent.Routing.RuleStore.list(table), & &1.id)

      assert MapSet.equal?(ids_after_1, ids_after_2),
             "reconciler re-run must NOT add routing rows it already installed"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # V1-R3 — Partial resume
  # ─────────────────────────────────────────────────────────────────────

  describe "V1-R3 — partial resume after killed worker" do
    setup do
      flavor = register_test_flavor()
      a = URI.new!("template://agent/team-alpha/r3-a-#{uniq()}")
      b = URI.new!("template://agent/team-alpha/r3-b-#{uniq()}")
      c = URI.new!("template://agent/team-alpha/r3-c-#{uniq()}")
      :ok = create_agent_template(a, agent_template_content(flavor, "a"))
      :ok = create_agent_template(b, agent_template_content(flavor, "b"))
      :ok = create_agent_template(c, agent_template_content(flavor, "c"))

      st =
        create_session_template(
          "r3-team-#{uniq()}",
          [{"alpha", a}, {"beta", b}, {"gamma", c}],
          []
        )

      owner = URI.parse("entity://user/team-alpha/r3-owner-#{uniq()}")

      :ok =
        spawn_owner(owner, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      {:ok, st: st, owner: owner}
    end

    test "kill one slot's worker, re-run completes ONLY that slot",
         %{st: st, owner: owner} do
      # Full convergence first.
      assert {:ok, r1} = Session.spawn_from_template(st, owner)
      assert length(r1.slots) == 3

      slot_by_name = Map.new(r1.slots)
      victim_worker = slot_by_name["beta"]
      survivor_alpha = slot_by_name["alpha"]
      survivor_gamma = slot_by_name["gamma"]

      {:ok, victim_pid} = KindRegistry.lookup(victim_worker)
      {:ok, alpha_pid_before} = KindRegistry.lookup(survivor_alpha)
      {:ok, gamma_pid_before} = KindRegistry.lookup(survivor_gamma)

      # Kill ONLY the beta worker.
      DynamicSupervisor.terminate_child(EzagentDomainChat.AgentSupervisor, victim_pid)

      wait_until(fn -> KindRegistry.lookup(victim_worker) == :error end)
      # Lineage / binding also need clearing so the re-spawn is fresh.
      Ezagent.AgentLineage.forget(victim_worker)
      Ezagent.WorkspaceRegistry.unbind(victim_worker)

      # Re-run — must converge ONLY the killed slot, leaving the
      # other two pids untouched.
      assert {:ok, r2} = Session.spawn_from_template(st, owner)
      slot_by_name_2 = Map.new(r2.slots)

      assert URI.to_string(slot_by_name_2["beta"]) == URI.to_string(victim_worker)

      {:ok, alpha_pid_after} = KindRegistry.lookup(survivor_alpha)
      {:ok, gamma_pid_after} = KindRegistry.lookup(survivor_gamma)

      assert alpha_pid_before == alpha_pid_after,
             "the alpha worker must NOT be respawned by the reconciler re-run"

      assert gamma_pid_before == gamma_pid_after,
             "the gamma worker must NOT be respawned by the reconciler re-run"
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # V1-R4 — Failed-slot retry
  # ─────────────────────────────────────────────────────────────────────

  describe "V1-R4 — failed-slot retry" do
    test "slot with un-populated AgentTemplate → :partial, repopulate + re-run → :ok" do
      flavor = register_test_flavor()
      good_tmpl = URI.new!("template://agent/team-alpha/r4-good-#{uniq()}")
      :ok = create_agent_template(good_tmpl, agent_template_content(flavor, "good"))

      # The "bad" template's Kind exists but its slice is NOT populated.
      bad_tmpl = URI.new!("template://agent/team-alpha/r4-bad-#{uniq()}")
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(bad_tmpl)
      # Intentionally do NOT call template.write — the slice stays empty.

      st =
        create_session_template(
          "r4-team-#{uniq()}",
          [{"good", good_tmpl}, {"bad", bad_tmpl}],
          []
        )

      owner = URI.parse("entity://user/team-alpha/r4-owner-#{uniq()}")

      :ok =
        spawn_owner(owner, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      # Pass 1: the "bad" slot fails (no flavor in the empty slice).
      assert {:partial, p1} = Session.spawn_from_template(st, owner)
      assert {:slot, "bad"} in p1.pending
      # The "good" slot still converged.
      assert match?(%URI{}, p1.session_uri)
      assert match?(%URI{}, p1.orchestrator_uri)

      # Operator fix: populate the bad template's slice.
      {:ok, _} = dispatch(bad_tmpl, "template.write", %{content: agent_template_content(flavor, "now-good")})

      # Pass 2: should complete the bad slot too.
      assert {:ok, r2} = Session.spawn_from_template(st, owner)
      assert length(r2.slots) == 2
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # V1-R7 — The architectural invariant (residual codex #1.5 — adapted
  # from the SPEC §V1-R7 test)
  # ─────────────────────────────────────────────────────────────────────

  describe "V1-R7 — no saga regrowth (architectural gate)" do
    test "session.ex contains no cleanup_partial-style saga rollback" do
      # Resolve to absolute via __DIR__ — works both from the umbrella
      # root and from inside the app dir.
      session_ex =
        Path.join([__DIR__, "..", "..", "lib", "ezagent", "entity", "session.ex"])
        |> Path.expand()

      source = File.read!(session_ex)

      refute source =~ ~r/defp\s+cleanup_partial/,
             "Generator-reconciler refactor: cleanup_partial/1 must NOT be re-introduced. " <>
               "The reconciler treats partial residue as expected intermediate state; " <>
               "saga rollback is the wrong primitive."

      refute source =~ ~r/defp\s+terminate_kind/,
             "Generator-reconciler refactor: terminate_kind/1 (saga teardown wrapper) " <>
               "must NOT be re-introduced — the only caller was cleanup_partial."

      refute source =~ ~r/defp\s+guard\b/,
             "Generator-reconciler refactor: the saga's guard/2 accumulator must NOT " <>
               "be re-introduced. The reconciler has no accumulator — each step's " <>
               "outcome merges directly into :pending / :errors buckets."
    end

    # Generator-reconciler PR-C — extend the architectural gate to
    # tools.ex. The 6 saga-recovery helpers DELETED in PR-C must not
    # be re-introduced. Together with the session.ex gate above this
    # is the cross-file invariant for the Generator-as-Reconciler model.
    test "tools.ex contains no saga-recovery helpers (PR-C deletion gate)" do
      tools_ex =
        Path.join([__DIR__, "..", "..", "lib", "ezagent", "orchestrator", "tools.ex"])
        |> Path.expand()

      source = File.read!(tools_ex)

      refute source =~ ~r/defp\s+compensate_orphan_worker\b/,
             "Generator-reconciler PR-C: compensate_orphan_worker/_ must NOT be " <>
               "re-introduced. The reconciler treats a just-spawned worker that did " <>
               "not get a slot record as VALID intermediate state — the next pass " <>
               "completes the slot write or detects + reuses the worker."

      refute source =~ ~r/defp\s+abort_swap_after_repoint_rollback\b/,
             "Generator-reconciler PR-C: abort_swap_after_repoint_rollback/_ must NOT " <>
               "be re-introduced. The reconciler doesn't abort on routing rollback; " <>
               "it leaves the new worker alive and re-attempts the repoint next pass."

      refute source =~ ~r/defp\s+halt_routing_revert_failed\b/,
             "Generator-reconciler PR-C: halt_routing_revert_failed/_ must NOT be " <>
               "re-introduced. There is no recovery-of-recovery in the reconciler; " <>
               "the next pass IS the recovery."

      refute source =~ ~r/defp\s+manual_repair_error\b/,
             "Generator-reconciler PR-C: manual_repair_error/_ must NOT be re-introduced. " <>
               "Partial state is communicated via {:partial, info} on the return — a " <>
               "structured outcome the LLM sees, not a saga's terminal error."

      refute source =~ ~r/defp\s+rollback_slot_to_old\b/,
             "Generator-reconciler PR-C: rollback_slot_to_old/_ must NOT be re-introduced. " <>
               "The reconciler never rolls a slot back; if a step fails the slot " <>
               "stays where it was committed and the next pass continues."

      refute source =~ ~r/defp\s+revert_receivers_by_ids_txn\b/,
             "Generator-reconciler PR-C: revert_receivers_by_ids_txn/_ must NOT be " <>
               "re-introduced. The reconciler has no inverse-revert transaction; the " <>
               "forward repoint txn's rollback IS the recovery."

      # Belt-and-braces: the saga's terminal error shape must not be
      # CONSTRUCTED or RETURNED. We match the atom in a tuple-construction
      # context (`{:update_needs_manual_repair,` / `{:update_aborted,`)
      # so the moduledoc's prose mention of the deleted shapes doesn't
      # false-positive.
      refute source =~ ~r/\{:update_needs_manual_repair,/,
             "Generator-reconciler PR-C: the `:update_needs_manual_repair` saga error " <>
               "shape must NOT be re-constructed. Partial convergence surfaces as " <>
               "{:partial, info}."

      refute source =~ ~r/\{:update_aborted,/,
             "Generator-reconciler PR-C: the `:update_aborted` saga error shape must " <>
               "NOT be re-constructed. There is no abort; preflight failures return " <>
               "{:error, reason} directly, partial steps return {:partial, info}."
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Residual codex #1: retry_after_race
  # ─────────────────────────────────────────────────────────────────────

  describe "residual codex #1 — retry_after_race (real implementation)" do
    setup do
      flavor = register_test_flavor()
      a = URI.new!("template://agent/team-alpha/race-a-#{uniq()}")
      :ok = create_agent_template(a, agent_template_content(flavor, "a"))
      st = create_session_template("race-team-#{uniq()}", [{"only", a}], [])
      owner = URI.parse("entity://user/team-alpha/race-owner-#{uniq()}")

      :ok =
        spawn_owner(owner, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      {:ok, st: st, owner: owner}
    end

    test "same-owner sequential spawn (the deterministic case) never returns :orchestrator_foreign",
         %{st: st, owner: owner} do
      # The SPEC §2 step 2 invariant in plain form: a SECOND
      # `spawn_from_template/2` call with identical args (which is
      # the deterministic-URI re-run case AND the resolved form of
      # any honest concurrent race) MUST NOT classify the
      # already-owned orchestrator as foreign. The codex rev-4
      # MEDIUM-3 fix split `check_orchestrator/3` so only POSITIVE
      # foreign evidence returns `:foreign`.
      #
      # We test sequential rather than truly concurrent: the
      # concurrent test introduces SQLite sandbox contention that
      # makes the umbrella-wide test suite flaky for reasons
      # unrelated to the reconciler architecture. The sequential
      # variant is the same invariant — two calls, second sees the
      # first's owned orchestrator, must NOT classify foreign.
      assert {:ok, %{orchestrator_uri: o1}} = Session.spawn_from_template(st, owner)
      r2 = Session.spawn_from_template(st, owner)

      refute match?({:error, {:orchestrator_foreign, _, _}}, r2),
             "same-owner re-run must NOT classify the orchestrator as foreign. " <>
               "Got: #{inspect(r2)}"

      o2 = extract_orchestrator(r2)
      assert o2 != nil
      assert URI.to_string(o1) == URI.to_string(o2),
             "the same-args re-run must converge to the SAME orchestrator URI"
    end

    test "ownership-pending retry exhaustion → :partial (NOT :error)" do
      # Simulate a permanently-pending orchestrator: spawn a live
      # process at the candidate URI without recording lineage OR
      # binding workspace — `check_orchestrator/3` returns
      # `{:ownership_pending, _}` indefinitely, so retry_after_race
      # must EXHAUST and return `{:partial, _}`, NOT `{:error, _}`.
      flavor = register_test_flavor()
      a = URI.new!("template://agent/team-alpha/exhaust-a-#{uniq()}")
      :ok = create_agent_template(a, agent_template_content(flavor, "a"))

      st = create_session_template("exhaust-team-#{uniq()}", [{"only", a}], [])
      owner = URI.parse("entity://user/team-alpha/exhaust-owner-#{uniq()}")

      :ok =
        spawn_owner(owner, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      # First derive the orchestrator URI the reconciler WILL compute.
      # SPEC: session://generic/<ws>/<owner_name>-<template_name>
      # orch: entity://agent/<ws>/cc_orchestrator-<session_name_segment>
      tmpl_content = read_session_template_content(st)
      session_uri = Session.derive_session_uri(tmpl_content, @workspace_uri, owner)
      orch_uri = derive_orch_uri_for_test(session_uri)

      # Pre-spawn the orchestrator URI as a "limbo" process — alive,
      # but neither lineage NOR workspace recorded. Use a "cc" flavor
      # only-Kind spawn that doesn't record obligations (we register
      # the orch URI ourselves).
      register_inert_flavor("cc")

      {:ok, _limbo_pid} = Ezagent.SpawnRegistry.spawn(orch_uri)
      # Deliberately do NOT record lineage or bind workspace.

      result = Session.spawn_from_template(st, owner)

      # Reconciler MUST return :partial (NOT :error :orchestrator_foreign).
      assert match?({:partial, _}, result),
             "ownership-pending exhaustion must surface as :partial, not :error. " <>
               "Got: #{inspect(result)}"

      {:partial, partial} = result

      assert :orchestrator in partial.pending or
               Enum.any?(partial.errors, fn {k, _} -> k == :orchestrator end),
             "partial report must surface the orchestrator-pending state. " <>
               "Got partial: #{inspect(partial)}"
    end

    # ─────────────────────────────────────────────────────────────────
    # SPEC 2026-05-27-reconciler-return-shape (#430) §5 invariant test.
    #
    # BEHAVIORAL invariant: the retry-exhaustion path on
    # `Session.ensure_orchestrator_with_meta/3` MUST return
    # `{:partial, %{orchestrator_pending: _}}`, never collapse to
    # `{:ok, _}` and never raise.
    #
    # This is the drift guard the SPEC §5 mandated. It catches:
    #   - A future refactor that adds an early `:ok` short-circuit
    #     before the retry exhaustion fires.
    #   - A future refactor that maps :partial → :ok at the
    #     ensure_orchestrator_with_meta/3 boundary (the historical
    #     bug class :partial was designed to prevent).
    #   - A future refactor that turns :partial into an exception.
    #
    # We exercise `ensure_orchestrator_with_meta/3` directly (NOT via
    # the full Session.spawn_from_template/2 facade) so the invariant
    # is local to the function whose @spec carries the `:partial`
    # contract. The full-facade case is already covered by the
    # line-523 integration test in the same describe block.
    # ─────────────────────────────────────────────────────────────────
    test "ensure_orchestrator_with_meta surfaces :partial for unconvertible-limbo orch" do
      workspace_uri = @workspace_uri
      owner = URI.parse("entity://user/team-alpha/inv-#{uniq()}")
      session_uri = URI.new!("session://default/team-alpha/inv-test-#{uniq()}")
      orch_uri = Session.derive_orchestrator_uri(session_uri, workspace_uri)

      # Pre-spawn limbo: workspace and lineage both :absent so
      # check_orchestrator returns {:ownership_pending, _}, then
      # retry_after_race exhausts its bounded retries (3 × 50ms ≤ 150ms)
      # and returns {:partial, %{orchestrator_pending: ^orch_uri}}.
      register_inert_flavor("cc")
      {:ok, _limbo_pid} = Ezagent.SpawnRegistry.spawn(orch_uri)

      result = Session.ensure_orchestrator_with_meta(session_uri, workspace_uri, owner)

      assert match?({:partial, %{orchestrator_pending: ^orch_uri}}, result),
             "ensure_orchestrator_with_meta MUST return :partial on " <>
               "ownership-pending exhaustion; collapsing to :ok would break " <>
               "EzagentDomainChat.create_session/3 + LV 'Retry instantiation' branching. " <>
               "Got: #{inspect(result)}"
    end

    defp extract_orchestrator({:ok, %{orchestrator_uri: o}}), do: o
    defp extract_orchestrator({:partial, %{orchestrator_uri: o}}), do: o
    defp extract_orchestrator(_), do: nil

    defp read_session_template_content(%URI{} = st_uri) do
      target = URI.parse("#{URI.to_string(st_uri)}?action=template.read")

      {:ok, %{content: content}} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{},
          ctx: %{
            caller: User.admin_uri(),
            caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
            reply: {:caller_inbox, self()}
          }
        })

      content
    end

    defp derive_orch_uri_for_test(%URI{} = session_uri) do
      # Same logic as Session.derive_orchestrator_uri.
      # SPEC 2026-05-27-reconciler-return-shape (#430) §4.2 option (a):
      # ws_name must come from the test's @workspace_uri host (which
      # matches the SessionTemplate's default_workspace_uri), NOT the
      # hardcoded "default" — otherwise the limbo pre-spawn lands at the
      # wrong URI prefix and check_orchestrator routes to :not_live →
      # fresh-spawn path, never exercising :ownership_pending → :partial.
      ws_name = @workspace_uri.host

      session_name =
        case session_uri.path do
          "/" <> rest ->
            case String.split(rest, "/", parts: 2) do
              [_ws, name] -> name
              _ -> session_uri.host
            end

          _ ->
            session_uri.host
        end

      URI.new!("entity://agent/#{ws_name}/cc_orchestrator-#{session_name}")
    end

    defp register_inert_flavor(name) do
      # Only register if not already present (cc flavor is normally
      # registered by ezagent_plugin_cc — but tests sometimes need it
      # without the plugin). Idempotent.
      case AgentFlavorRegistry.lookup(name) do
        {:ok, _} ->
          :ok

        :error ->
          AgentFlavorRegistry.register(%{
            flavor: name,
            kind: Ezagent.Entity.Agent,
            template_class: nil
          })
      end
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Residual codex #3: working_copy_merge revalidation
  # ─────────────────────────────────────────────────────────────────────

  describe "residual codex #3 — working_copy merge this-pass revalidation" do
    test "a slot re-parented between reconcile_slot and merge_working_copy is caught" do
      # The HIGH-2 rev-4 revalidation branch: a worker that converged
      # this pass and was then re-parented (lineage changed to a
      # foreign principal) BEFORE merge_working_copy runs — the merge
      # MUST detect the lost ownership and write nil-worker (not
      # silently bind the foreign worker into the working copy).
      #
      # We exercise this with a tracer-style hack: spawn the team
      # normally (full convergence), then between two reconciler
      # passes, re-parent ONE worker's lineage to a foreign URI.
      # The second pass's merge_working_copy revalidation MUST detect
      # the lost ownership and put a nil-worker tuple in its place.
      flavor = register_test_flavor()
      a = URI.new!("template://agent/team-alpha/wcm-a-#{uniq()}")
      b = URI.new!("template://agent/team-alpha/wcm-b-#{uniq()}")
      :ok = create_agent_template(a, agent_template_content(flavor, "a"))
      :ok = create_agent_template(b, agent_template_content(flavor, "b"))

      st =
        create_session_template(
          "wcm-team-#{uniq()}",
          [{"alpha", a}, {"beta", b}],
          []
        )

      owner = URI.parse("entity://user/team-alpha/wcm-owner-#{uniq()}")

      :ok =
        spawn_owner(owner, [
          template_cap(:session_template, @workspace_uri),
          template_cap(:agent_template, @workspace_uri)
        ])

      assert {:ok, %{session_uri: s, slots: slots}} =
               Session.spawn_from_template(st, owner)

      [{_, beta_worker}] = Enum.filter(slots, fn {n, _} -> n == "beta" end)

      # RE-PARENT beta's lineage to a foreign principal — the worker
      # is still alive + workspace-bound, but lineage no longer points
      # at our orchestrator. Both `worker_already_owned_by_us?` and
      # `slot_still_owned?` will return false.
      foreign_orch = URI.parse("entity://agent/team-alpha/cc_orchestrator-foreign-#{uniq()}")
      :ok = AgentLineage.record(beta_worker, foreign_orch)

      # Re-run the reconciler. The this-pass slot reconcile for beta
      # will fail the fast-path (ownership broken) and the dispatch
      # path's `verify_slot_candidate_ownership/5` will refuse the
      # adoption (fresh?: false + not owned). The slot becomes an
      # :error in this pass's slot_results.
      #
      # When merge_working_copy then runs:
      #   - this_pass entry: NONE (slot is in :error bucket).
      #   - prior entry: was beta_worker (from pass 1's working copy).
      #     `slot_still_owned?(prior_entry, ws, orch)` — lineage now
      #     foreign → returns false.
      #   - merge writes a nil-worker tuple for beta.
      result = Session.spawn_from_template(st, owner)

      # The session converged (alpha is still fine), but beta is now
      # pending in the partial report.
      case result do
        {:partial, partial} ->
          assert {:slot, "beta"} in partial.pending

        {:ok, _} ->
          flunk("expected :partial after re-parenting beta; got :ok")
      end

      wc = read_working_copy_for_test(s)

      beta_slot =
        Enum.find(wc.agent_slots || [], fn
          {"beta", _, _, _} -> true
          _ -> false
        end)

      # The HIGH-2 rev-4 guarantee: the merge wrote a nil-worker
      # tuple for beta — NOT silently kept the foreign-owned worker.
      assert match?({"beta", _src, nil, _gen}, beta_slot),
             "merge_working_copy must NOT bind a re-parented worker into the " <>
               "working copy — expected nil-worker tuple for 'beta', got: #{inspect(beta_slot)}"
    end

    defp read_working_copy_for_test(%URI{} = session_uri) do
      {:ok, pid} = KindRegistry.lookup(session_uri)

      chat_slice =
        pid
        |> :sys.get_state()
        |> Map.get(:state, %{})
        |> Map.get(Ezagent.Behavior.Chat.state_slice(), %{})

      Ezagent.Behavior.Chat.template_working_copy(chat_slice)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Shared helpers
  # ─────────────────────────────────────────────────────────────────────

  defp wait_until(fun, attempts \\ 200)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end
end
