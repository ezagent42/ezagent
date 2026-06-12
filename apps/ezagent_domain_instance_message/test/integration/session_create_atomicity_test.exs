defmodule EzagentDomainInstanceMessage.Integration.SessionCreateAtomicityTest do
  @moduledoc """
  Regression tests for the 2026-05-31 orchestrator-startup-atomicity
  codex-review fixes (SPEC
  `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`):

    * Q2 — `{:already_started}` must NOT return an INCOMPLETE session as
      success. A half-created session (Session spawned + bound but no
      OTU / no orchestrator / owner not joined) must be rolled back and
      RECREATED fresh, so the result is a COMPLETE session.

    * Q1 — `rollback_session/3` must mirror create's writes in reverse,
      idempotently, leaving NO durable / registry residue: no
      orchestrator Kind, no MCP registry row, no granted owner restart
      cap, no orchestrator scoped caps, no lineage row.
  """

  use ExUnit.Case, async: false

  alias Ezagent.{Capability, KindRegistry}
  alias Ezagent.Entity.{Session, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Admin User Kind alive — the orchestrator-spawn paths read owner
    # lineage; admin is the bootstrap principal in test env.
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())

    # Plant an orchestrator skill fixture so the role-bootstrap can find
    # SKILL.md (matches the unified suite's setup) — keeps the create on
    # the `:ready` (non-degraded) path.
    fixture_root =
      Path.join(System.tmp_dir!(), "orch-skill-atomicity-#{System.unique_integer([:positive])}")

    skill_src = Path.join(fixture_root, "ezagent-session-orchestrator")
    File.mkdir_p!(skill_src)
    File.write!(Path.join(skill_src, "SKILL.md"), "fixture skill\n")
    Application.put_env(:ezagent_plugin_cc, :orchestrator_skill_source, skill_src)

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_cc, :orchestrator_skill_source)
      _ = File.rm_rf(fixture_root)
    end)

    :ok
  end

  describe "Q2 — incomplete existing session is rolled back + recreated (not returned as success)" do
    test "a half-created session (bound, no OTU/no orchestrator/owner-not-joined) is recreated COMPLETE" do
      owner = User.admin_uri()
      workspace_uri = Ezagent.URI.entity_workspace_uri(owner)

      short = "atomicity-incomplete-#{System.unique_integer([:positive])}"
      session_uri = URI.new!("session://system/default/#{short}")

      # ---- Stage a HALF-CREATED session by hand ----
      # Session Kind spawned + workspace bound (steps 2-3), but
      # deliberately NO step-4 OTU materialization, NO step-5 orchestrator,
      # NO step-8 owner join. This is exactly the residue a crash
      # mid-create leaves — and exactly what the pre-Q2 `{:already_started}`
      # arm would have returned as a successful session.
      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          owner_uri: owner,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      # Sanity — the half-session is genuinely incomplete BEFORE we
      # re-create: no orchestrator registered, owner not a member.
      orch_uri = Session.planned_orchestrator_uri(session_uri, workspace_uri)
      assert KindRegistry.lookup(orch_uri) == :error
      refute owner in Session.session_member_uris(session_uri)

      # ---- Re-create with the SAME short_name ----
      # The spawn returns `{:already_started}` → verify_or_recreate
      # detects INCOMPLETE → rollback + recreate fresh.
      assert {:ok, ^session_uri, meta} =
               EzagentDomainInstanceMessage.SessionCreator.create_session(short, owner,
                 template_name: "default"
               )

      # ---- The result must be a COMPLETE session, not the half one ----
      # 1. OTU materialized (step 4).
      wc = Session.read_template_working_copy(session_uri)

      assert match?(%URI{}, Map.get(wc, :orchestrator_template_uri)),
             "recreated session must have its orchestrator_template_uri set"

      # 2. Orchestrator registered + alive (steps 5/7).
      assert meta.orchestrator_status == :ready
      assert {:ok, pid} = KindRegistry.lookup(meta.orchestrator_uri)
      assert Process.alive?(pid)

      assert match?(
               {:ok, _},
               Ezagent.Orchestrator.McpServer.from_orchestrator_uri(meta.orchestrator_uri)
             ),
             "recreated orchestrator must be registered-or-rebuildable"

      # 3. Owner joined as a chat member (step 8).
      assert owner in Session.session_member_uris(session_uri),
             "recreated session must have the owner as a member"
    end

    test "a COMPLETE existing session is returned idempotently (no needless recreate)" do
      owner = User.admin_uri()
      short = "atomicity-complete-#{System.unique_integer([:positive])}"

      # First create → complete.
      {:ok, session_uri, _meta1} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, owner,
          template_name: "default"
        )

      {:ok, orch_pid_before} =
        KindRegistry.lookup(
          Session.planned_orchestrator_uri(session_uri, URI.new!("workspace://system"))
        )

      # Second create → `{:already_started}` → COMPLETE → return existing
      # WITHOUT recreating (the orchestrator pid must be unchanged — a
      # recreate would have torn it down + re-spawned).
      {:ok, ^session_uri, _meta2} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, owner,
          template_name: "default"
        )

      {:ok, orch_pid_after} =
        KindRegistry.lookup(
          Session.planned_orchestrator_uri(session_uri, URI.new!("workspace://system"))
        )

      assert orch_pid_before == orch_pid_after,
             "a complete session must be returned idempotently — the orchestrator " <>
               "Kind must NOT be torn down + re-spawned"
    end
  end

  describe "Q1 — rollback_session/3 leaves NO durable / registry residue" do
    test "after a real create, full rollback removes orchestrator Kind + MCP row + caps + lineage + bind + snapshots" do
      owner = User.admin_uri()
      workspace_uri = Ezagent.URI.entity_workspace_uri(owner)

      short = "atomicity-rollback-#{System.unique_integer([:positive])}"

      # Create a real, COMPLETE orchestrator-bearing session so EVERY
      # write rollback must reverse is present.
      {:ok, session_uri, meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, owner,
          template_name: "default"
        )

      orch_uri = meta.orchestrator_uri
      assert match?(%URI{}, orch_uri)

      # ---- Pre-rollback: assert the writes ARE present ----
      assert {:ok, _} = KindRegistry.lookup(session_uri)
      assert {:ok, _} = KindRegistry.lookup(orch_uri)
      assert {:ok, _} = Ezagent.WorkspaceRegistry.lookup(orch_uri)
      assert {:ok, _} = Ezagent.Orchestrator.McpRegistry.lookup(orch_uri)
      assert {:ok, _} = Ezagent.AgentLineage.lookup(orch_uri)

      owner_caps_before = Ezagent.Identity.list_caps_for(owner)

      assert Enum.any?(owner_caps_before, &owner_restart_cap?(&1, session_uri, workspace_uri)),
             "owner must hold the OrchestratorAdmin :restart cap before rollback"

      orch_caps_before = Ezagent.Identity.list_caps_for(orch_uri)

      assert Enum.any?(orch_caps_before, &within_session_cap?(&1, session_uri)),
             "orchestrator must hold the within-session scoped cap before rollback"

      # ---- Roll back fully (the orchestrator-bearing path) ----
      assert :ok =
               EzagentDomainInstanceMessage.rollback_session(session_uri, orch_uri,
                 owner_uri: owner,
                 workspace_uri: workspace_uri
               )

      Process.sleep(80)

      # ---- Post-rollback: assert ZERO residue ----
      assert KindRegistry.lookup(session_uri) == :error,
             "Session Kind must be terminated"

      assert KindRegistry.lookup(orch_uri) == :error,
             "orchestrator Kind must be terminated"

      assert Ezagent.WorkspaceRegistry.lookup(orch_uri) == :error,
             "orchestrator workspace binding must be removed"

      assert Ezagent.WorkspaceRegistry.lookup(session_uri) == :error,
             "session workspace binding must be removed"

      assert Ezagent.Orchestrator.McpRegistry.lookup(orch_uri) == :error,
             "orchestrator MCP registry row must be removed"

      assert Ezagent.AgentLineage.lookup(orch_uri) == :error,
             "orchestrator lineage row must be forgotten"

      assert Ezagent.Ecto.KindSnapshot.get(URI.to_string(session_uri)) == nil,
             "session snapshot row must be deleted"

      assert Ezagent.Ecto.KindSnapshot.get(URI.to_string(orch_uri)) == nil,
             "orchestrator snapshot row must be deleted"

      # The DURABLE residue that outlives Kind teardown — the owner
      # restart cap on the persistent owner User Kind — must be revoked.
      owner_caps_after = Ezagent.Identity.list_caps_for(owner)

      refute Enum.any?(owner_caps_after, &owner_restart_cap?(&1, session_uri, workspace_uri)),
             "owner OrchestratorAdmin :restart cap must be revoked by rollback"
    end
  end

  # ---- cap predicates (match by identity, ignore provenance) ----

  defp owner_restart_cap?(%Capability{} = cap, session_uri, workspace_uri) do
    cap.kind == :session and
      cap.behavior == Ezagent.Behavior.OrchestratorAdmin and
      Capability.action_of(cap) == :restart and
      cap.instance == session_uri and
      cap.workspace_uri == workspace_uri
  end

  defp within_session_cap?(%Capability{} = cap, session_uri) do
    cap.instance == {:within_session, session_uri}
  end
end
