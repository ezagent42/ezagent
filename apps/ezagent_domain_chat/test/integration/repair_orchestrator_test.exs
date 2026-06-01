defmodule EzagentDomainChat.Integration.RepairOrchestratorTest do
  @moduledoc """
  SPEC `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
  §6 — `EzagentDomainChat.repair_orchestrator/1,2` RE-MATERIALIZES the
  session working copy (writes `orchestrator_template_uri` (OTU) +
  `session_template_uri`) THEN runs the §5 atomic gate. This is what
  fixes existing nil-OTU sessions (`main`, `orch-feishu-7429`) that were
  created before the atomic flow set OTU, or whose orchestrator died.

  The old `:restart` path only re-dispatched `template.instantiate` +
  respawned the PTY — it NEVER set OTU. The regression these tests guard:
  after a repair the session's durable working copy MUST carry OTU
  (otherwise `McpServer.from_orchestrator_uri/1` can't rebuild the
  orchestrator context on the next bridge JOIN → `:orchestrator_not_registered`).

  test_mode note: in `:test` env the cc PtyServer short-circuits the real
  claude, so the §5 30s LIVE-join gate is bypassed (the synchronous
  `register_orchestrator_mcp_context` is the readiness signal). The true
  live gate is validated by the e2e, not this unit suite.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Entity.{Session, User}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Default template seed inside the checkout (idempotent) + admin alive.
    :ok = EzagentDomainChat.Application.seed_default_session_template_now()
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  describe "repair_orchestrator/1 — re-materializes OTU on a nil-OTU session" do
    test "after clearing OTU, repair restores it + returns :ready" do
      short = "repair-otu-#{System.unique_integer([:positive])}"

      {:ok, session_uri, create_meta} =
        EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

      assert create_meta.orchestrator_status == :ready

      # Simulate the nil-OTU residue (`main` / `orch-feishu-7429`): wipe the
      # orchestrator_template_uri from the durable working copy.
      wc = Session.read_template_working_copy(session_uri)
      assert match?(%URI{}, Map.get(wc, :orchestrator_template_uri)),
             "precondition: a freshly-created session has OTU set"

      cleared = Map.put(wc, :orchestrator_template_uri, nil)
      {:ok, _} = Ezagent.Behavior.Chat.system_set_working_copy(session_uri, cleared)

      assert is_nil(
               Map.get(
                 Session.read_template_working_copy(session_uri),
                 :orchestrator_template_uri
               )
             ),
             "precondition: OTU is now nil (the bug state)"

      # The repair re-materializes OTU from the session's template.
      assert {:ok, ^session_uri, meta} =
               EzagentDomainChat.repair_orchestrator(session_uri)

      assert match?(%URI{}, meta.orchestrator_uri)
      assert meta.orchestrator_status == :ready

      repaired_wc = Session.read_template_working_copy(session_uri)

      assert match?(%URI{}, Map.get(repaired_wc, :orchestrator_template_uri)),
             "repair_orchestrator MUST re-write orchestrator_template_uri (the §6 fix)"

      assert match?(%URI{}, Map.get(repaired_wc, :session_template_uri)),
             "repair_orchestrator MUST also re-write session_template_uri"
    end

    test "repair_orchestrator/2 with explicit workspace behaves identically" do
      short = "repair-ws-#{System.unique_integer([:positive])}"

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, User.admin_uri(), template_name: "default")

      workspace_uri = Ezagent.URI.entity_workspace_uri(User.admin_uri())

      assert {:ok, ^session_uri, meta} =
               EzagentDomainChat.repair_orchestrator(session_uri, workspace_uri)

      assert meta.orchestrator_status == :ready
    end
  end

  describe "repair_orchestrator guards" do
    test "a session URI with no resolvable workspace fails loud" do
      # `repair_orchestrator/2` with nil workspace is an explicit error.
      assert {:error, :repair_requires_workspace} =
               EzagentDomainChat.repair_orchestrator(
                 Ezagent.URI.new!("session://default/system/whatever"),
                 nil
               )
    end
  end
end
