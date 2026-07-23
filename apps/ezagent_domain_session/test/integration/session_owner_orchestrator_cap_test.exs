defmodule EzagentDomainInstanceMessage.Integration.SessionOwnerOrchestratorCapTest do
  @moduledoc """
  Verifies that creating a session via
  `EzagentDomainInstanceMessage.SessionCreator.create_session/3` records the creator as the
  session owner without granting orchestrator-special management caps.

  Covers four invariants:

    1. `create_session/3` records `creator_uri` on the new session's
       `:chat.owner_uri` field (slice persists across in-process
       reads via `Ezagent.Kind.get_slice/2`).
    2. `Ezagent.Entity.Session.owner/1` returns `{:ok, creator_uri}`
       for the freshly-created session.
    3. Re-calling `create_session/3` with the same session is
       idempotent and does not mint special orchestrator caps.
  """

  use EzagentCore.DataCase, async: false

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

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short_name, creator,
          template_name: "default"
        )

      assert {:ok, ^creator} = Session.owner(session_uri)
    end

    test "creator does not gain OrchestratorAdmin :restart cap on create" do
      short_name = "rfc402-cap-test-#{System.unique_integer([:positive])}"
      creator = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short_name, creator,
          template_name: "default"
        )

      caps = Ezagent.Identity.list_caps_for(creator)

      refute Enum.any?(caps, &orchestrator_admin_cap?(&1, session_uri)),
             "create_session must not mint an OrchestratorAdmin restart cap; got:\n" <>
               inspect(caps, pretty: true)
    end

    test "re-call is idempotent — no duplicate cap rows on owner" do
      short_name = "rfc402-idem-test-#{System.unique_integer([:positive])}"
      creator = User.admin_uri()

      {:ok, session_uri_1, _meta_1} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short_name, creator,
          template_name: "default"
        )

      {:ok, session_uri_2, _meta_2} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short_name, creator,
          template_name: "default"
        )

      assert session_uri_1 == session_uri_2

      caps = Ezagent.Identity.list_caps_for(creator)

      matching =
        Enum.filter(caps, fn cap ->
          match?(%Ezagent.Capability{}, cap) and
            cap.kind == :session and
            cap.behavior == Ezagent.ActionSet.OrchestratorAdmin and
            cap.instance == session_uri_1
        end)

      assert matching == [],
             "expected no OrchestratorAdmin cap rows for this session " <>
               "after two create_session calls, got #{inspect(matching, pretty: true)}"
    end
  end

  describe "first-USER-join fallback (codex r1 HIGH 2026-05-26)" do
    test "legacy session without owner_uri — first user join claims owner without restart cap" do
      # Reproduce the legacy / system-internal create path: spawn a
      # Session WITHOUT owner_uri (the pre-RFC-#402 shape), then
      # join a real user. The do_join branch must (a) flip owner_uri
      # to that user AND (b) grant them the OrchestratorAdmin
      # :restart cap on this session.
      short_name = "rfc402-legacy-join-#{System.unique_integer([:positive])}"
      # Canonical (`authority: nil`) — the granted cap's workspace_uri is
      # stored canonically (the grant path normalizes through
      # Ezagent.URI.new!), so the `cap.workspace_uri == workspace_uri`
      # predicate must compare against the canonical struct. `URI.parse`
      # (`authority: "system"`) is field-divergent and never `==`-matches.
      workspace_uri = Ezagent.URI.new!("workspace://system")

      session_uri =
        URI.new!("session://system/default/#{short_name}")

      # Spawn the Session Kind directly with NO owner_uri — emulates
      # a legacy snapshot rehydration / system-internal spawn.
      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      # Sanity-check the legacy precondition.
      assert {:ok, nil} = Session.owner(session_uri)

      # Now have a real user join. admin_uri is a real entity://user URI.
      user_uri = User.admin_uri()
      _ = Ezagent.SpawnRegistry.spawn(user_uri)

      target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
      admin = Ezagent.Entity.User.admin_uri()
      cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

      {:ok, _} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{member: user_uri},
          ctx: %{
            caller: admin,
            authenticated_principal: admin,
            caps: MapSet.new([cap]),
            reply: {:caller_inbox, self()}
          }
        })

      # owner_uri now points at the user.
      assert {:ok, ^user_uri} = Session.owner(session_uri)

      refute Enum.any?(
               Ezagent.Identity.list_caps_for(user_uri),
               &orchestrator_admin_cap?(&1, session_uri)
             )
    end

    test "second user joining does NOT get owner cap (owner already claimed)" do
      # Once owner is set, subsequent joins must NOT claim ownership.
      short_name = "rfc402-second-join-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://system")
      session_uri = URI.new!("session://system/default/#{short_name}")

      # Spawn legacy session.
      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      first_user = User.admin_uri()
      _ = Ezagent.SpawnRegistry.spawn(first_user)

      join_target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
      admin = Ezagent.Entity.User.admin_uri()
      cap = Ezagent.Test.CapHelper.signed_action_cap!(join_target, admin)

      ctx = %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }

      {:ok, _} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          origin: :trusted_internal,
          target: join_target,
          mode: :call,
          args: %{member: first_user},
          ctx: ctx
        })

      # Now a SECOND user joins (synthetic non-admin URI).
      second_user =
        URI.new!("entity://system/user/second-#{System.unique_integer([:positive])}")

      _ = Ezagent.SpawnRegistry.spawn(second_user)

      {:ok, _} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          origin: :trusted_internal,
          target: join_target,
          mode: :call,
          args: %{member: second_user},
          ctx: ctx
        })

      # Owner is still the first user, NOT the second.
      assert {:ok, ^first_user} = Session.owner(session_uri)

      second_caps = Ezagent.Identity.list_caps_for(second_user)

      refute Enum.any?(second_caps, &orchestrator_admin_cap?(&1, session_uri))
    end

    test "agent join does NOT claim owner (user_uri? gate)" do
      # When orchestrator-spawn calls auto_join_session_members and
      # the orchestrator's chat.join lands BEFORE any user joins,
      # the agent URI MUST NOT become owner — only entity://user URIs
      # qualify.
      short_name = "rfc402-agent-no-claim-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://system")
      session_uri = URI.new!("session://system/default/#{short_name}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      # An agent URI (cc-orchestrator naming convention).
      agent_uri =
        URI.new!("entity://system/agent/cc_orchestrator-#{short_name}")

      _ = Ezagent.SpawnRegistry.spawn(agent_uri)

      target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
      admin = Ezagent.Entity.User.admin_uri()
      cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

      _ =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{member: agent_uri},
          ctx: %{
            caller: admin,
            authenticated_principal: admin,
            caps: MapSet.new([cap]),
            reply: {:caller_inbox, self()}
          }
        })

      # owner_uri stays nil — agent doesn't qualify.
      assert {:ok, nil} = Session.owner(session_uri)
    end
  end

  describe "Session.planned_orchestrator_uri/2 — URI workspace segment" do
    test "orchestrator URI's workspace segment matches the session's workspace segment" do
      # The orchestrator agent URI is workspace-first:
      # `entity://<workspace>/agent/cc_orchestrator-<disc>`.
      session_uri = Ezagent.URI.new!("session://team-alpha/default/some-session")
      workspace_uri = Ezagent.URI.new!("workspace://team-alpha")

      orch_uri = Session.planned_orchestrator_uri(session_uri, workspace_uri)

      assert orch_uri.scheme == "entity"
      assert orch_uri.host == "team-alpha"
      assert orch_uri.path =~ ~r{^/agent/}
      assert orch_uri.path =~ ~r{cc_orchestrator-}
    end
  end

  defp orchestrator_admin_cap?(cap, session_uri) do
    match?(%Ezagent.Capability{}, cap) and
      cap.kind == :session and
      cap.behavior == Ezagent.ActionSet.OrchestratorAdmin and
      cap.instance == session_uri
  end
end
