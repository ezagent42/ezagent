defmodule EzagentDomainInstanceMessage.Integration.RepairOrchestratorTest do
  @moduledoc """
  Rev6 repair contract: `repair_orchestrator/1,2` re-materializes the
  session template declaration and routing metadata from the session's
  recorded template. During the 2026-07-10 default-template hotfix, the stock
  `default` template is plain chat, so repair must not invent an orchestrator
  declaration for that path.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}

  setup do
    # Default template seed inside the checkout (idempotent) + admin alive.
    :ok = EzagentDomainInstanceMessage.Application.seed_default_session_template_now()
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  describe "repair_orchestrator/1 — re-materializes template declarations" do
    test "after clearing default-template metadata, repair restores the template URI without inventing orchestrator" do
      short = "repair-otu-#{System.unique_integer([:positive])}"

      {:ok, session_uri, create_meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      assert create_meta == %{}

      wc = Session.read_template_working_copy(session_uri)
      assert [] == Map.get(wc, :member_declarations)
      assert match?(%URI{}, Map.get(wc, :session_template_uri))

      cleared =
        wc
        |> Map.put(:member_declarations, [])
        |> Map.put(:session_template_uri, nil)

      {:ok, _} = Ezagent.ActionSet.Session.system_set_working_copy(session_uri, cleared)

      assert [] == Map.get(Session.read_template_working_copy(session_uri), :member_declarations)

      assert {:ok, ^session_uri, meta} =
               EzagentDomainInstanceMessage.repair_orchestrator(session_uri)

      assert meta == %{}

      repaired_wc = Session.read_template_working_copy(session_uri)

      assert match?(%URI{}, Map.get(repaired_wc, :session_template_uri)),
             "repair_orchestrator MUST re-write session_template_uri"

      assert [] == Map.get(repaired_wc, :member_declarations)
      refute Map.has_key?(repaired_wc, :orchestrator_template_uri)
    end

    test "repair_orchestrator/2 with explicit workspace behaves identically" do
      short = "repair-ws-#{System.unique_integer([:positive])}"

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      workspace_uri = Ezagent.URI.entity_workspace_uri(User.admin_uri())

      assert {:ok, ^session_uri, meta} =
               EzagentDomainInstanceMessage.repair_orchestrator(session_uri, workspace_uri)

      assert meta == %{}
    end

    test "repair_orchestrator/2 accepts the authenticated actor alongside the workspace" do
      short = "repair-actor-#{System.unique_integer([:positive])}"

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, User.admin_uri(),
          template_name: "default"
        )

      workspace_uri = Ezagent.URI.entity_workspace_uri(User.admin_uri())

      assert {:ok, ^session_uri, %{}} =
               EzagentDomainInstanceMessage.repair_orchestrator(
                 session_uri,
                 {workspace_uri, User.admin_uri()}
               )
    end
  end

  describe "repair_orchestrator guards" do
    test "a session URI with no resolvable workspace fails loud" do
      # `repair_orchestrator/2` with nil workspace is an explicit error.
      assert {:error, :repair_requires_workspace} =
               EzagentDomainInstanceMessage.repair_orchestrator(
                 Ezagent.URI.new!("session://system/default/whatever"),
                 nil
               )
    end

    test "an owner-unresolvable session fails loud instead of repairing as admin" do
      suffix = System.unique_integer([:positive])
      session_uri = Ezagent.URI.session("system", "default", "repair-no-owner-#{suffix}")
      workspace_uri = Ezagent.URI.workspace(:system)

      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          behaviors: Session.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      assert {:error, {:no_session_owner, ^session_uri}} =
               EzagentDomainInstanceMessage.repair_orchestrator(
                 session_uri,
                 {workspace_uri, User.admin_uri()}
               )
    end
  end
end
