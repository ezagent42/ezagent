defmodule EzagentDomainChat.Integration.SessionOwnerOrchestratorCapTest do
  @moduledoc """
  RFC #402 (Allen 2026-05-26) — verifies that creating a session
  via `EzagentDomainChat.create_session/3` records the creator as the
  session owner AND grants them the
  `Behavior.OrchestratorAdmin :restart` cap on the new session.

  Covers four invariants:

    1. `create_session/3` records `creator_uri` on the new session's
       `:chat.owner_uri` field (slice persists across in-process
       reads via `Ezagent.Kind.get_slice/2`).
    2. `Ezagent.Entity.Session.owner/1` returns `{:ok, creator_uri}`
       for the freshly-created session.
    3. The creator's identity slice gains a
       `cap(:session, OrchestratorAdmin, :restart, session_uri, ws)`
       cap row.
    4. Re-calling `create_session/3` with the same session is
       idempotent — no duplicate cap rows on the owner.

  The cap is the UX gate `OrchestratorHealthCard` consults to render
  the Restart button only for the session owner — so this test pins
  the contract the LV depends on.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.{Session, User}

  setup do
    # Make sure the admin User Kind is alive so its Identity slice
    # exists when we read caps (admin is the bootstrap principal in
    # test env).
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  describe "create_session/3 — owner_uri + cap grant" do
    test "creator becomes session owner_uri" do
      short_name = "rfc402-owner-test-#{System.unique_integer([:positive])}"
      creator = User.admin_uri()

      {:ok, session_uri} =
        EzagentDomainChat.create_session(short_name, creator, template_name: "default")

      assert {:ok, ^creator} = Session.owner(session_uri)
    end

    test "creator gains OrchestratorAdmin :restart cap on the new session" do
      short_name = "rfc402-cap-test-#{System.unique_integer([:positive])}"
      creator = User.admin_uri()
      workspace_uri = Ezagent.URI.entity_workspace_uri(creator)

      {:ok, session_uri} =
        EzagentDomainChat.create_session(short_name, creator, template_name: "default")

      caps = Ezagent.Identity.list_caps_for(creator)

      # The cap must EXACTLY scope to (session, OrchestratorAdmin,
      # session_uri, workspace). Admin also holds an `:any/:any/:any/:any`
      # bootstrap cap — that one matches too but isn't what RFC #402
      # asks us to grant; we want a SPECIFIC instance-scoped row.
      assert Enum.any?(caps, fn cap ->
               match?(%Capability{}, cap) and
                 cap.kind == :session and
                 cap.behavior == Ezagent.Behavior.OrchestratorAdmin and
                 cap.instance == session_uri and
                 cap.workspace_uri == workspace_uri
             end),
             "expected an OrchestratorAdmin :restart cap on #{URI.to_string(session_uri)} " <>
               "scoped to #{URI.to_string(workspace_uri)} in admin's caps, got:\n#{inspect(caps, pretty: true)}"
    end

    test "re-call is idempotent — no duplicate cap rows on owner" do
      short_name = "rfc402-idem-test-#{System.unique_integer([:positive])}"
      creator = User.admin_uri()

      {:ok, session_uri_1} =
        EzagentDomainChat.create_session(short_name, creator, template_name: "default")

      {:ok, session_uri_2} =
        EzagentDomainChat.create_session(short_name, creator, template_name: "default")

      assert session_uri_1 == session_uri_2

      caps = Ezagent.Identity.list_caps_for(creator)

      matching =
        Enum.filter(caps, fn cap ->
          match?(%Capability{}, cap) and
            cap.kind == :session and
            cap.behavior == Ezagent.Behavior.OrchestratorAdmin and
            cap.instance == session_uri_1
        end)

      assert length(matching) == 1,
             "expected exactly 1 OrchestratorAdmin cap row for this session " <>
               "after two create_session calls (idempotent grant), got #{length(matching)}"
    end
  end

  describe "Session.derive_orchestrator_uri/2 — URI workspace segment" do
    test "orchestrator URI's workspace segment matches the session's workspace segment" do
      # RFC #402 (Allen-confirmed): the orchestrator agent URI is
      # `entity://agent/<workspace>/cc_orchestrator-<disc>` — the
      # workspace segment matches the session's workspace per SPEC v3
      # 3-segment authority.
      session_uri = URI.parse("session://default/team-alpha/some-session")
      workspace_uri = URI.parse("workspace://team-alpha")

      orch_uri = Session.derive_orchestrator_uri(session_uri, workspace_uri)

      assert orch_uri.scheme == "entity"
      assert orch_uri.host == "agent"
      # The path segment after host is /<workspace>/<name>
      assert orch_uri.path =~ ~r{^/team-alpha/}
      assert orch_uri.path =~ ~r{cc_orchestrator-}
    end
  end
end
