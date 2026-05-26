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

  describe "first-USER-join fallback (codex r1 HIGH 2026-05-26)" do
    test "legacy session without owner_uri — first user join claims owner AND gains restart cap" do
      # Reproduce the legacy / system-internal create path: spawn a
      # Session WITHOUT owner_uri (the pre-RFC-#402 shape), then
      # join a real user. The do_join branch must (a) flip owner_uri
      # to that user AND (b) grant them the OrchestratorAdmin
      # :restart cap on this session.
      short_name = "rfc402-legacy-join-#{System.unique_integer([:positive])}"
      workspace_uri = URI.parse("workspace://system")

      session_uri =
        URI.new!("session://default/system/#{short_name}")

      # Spawn the Session Kind directly with NO owner_uri — emulates
      # a legacy snapshot rehydration / system-internal spawn.
      {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      # Sanity-check the legacy precondition.
      assert {:ok, nil} = Session.owner(session_uri)

      # Now have a real user join. admin_uri is a real entity://user URI.
      user_uri = User.admin_uri()
      _ = Ezagent.SpawnRegistry.spawn(user_uri)

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      {:ok, _} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{member: user_uri},
          ctx: %{
            caller: Ezagent.SystemPrincipal.uri("session-internal"),
            caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
            reply: {:caller_inbox, self()}
          }
        })

      # owner_uri now points at the user.
      assert {:ok, ^user_uri} = Session.owner(session_uri)

      # AND that user holds the specific OrchestratorAdmin :restart
      # cap (the LV's gate). The grant is dispatched via `:cast` from
      # `Chat.do_join` to avoid GenServer-self deadlock (the grant
      # path's `check_grant_authorized` would otherwise call
      # `Session.owner` against the same Session pid we're inside);
      # so the cap appears asynchronously. Poll for ≤500ms.
      cap_predicate = fn cap ->
        match?(%Capability{}, cap) and
          cap.kind == :session and
          cap.behavior == Ezagent.Behavior.OrchestratorAdmin and
          cap.instance == session_uri and
          cap.workspace_uri == workspace_uri
      end

      assert wait_for_cap(user_uri, cap_predicate, 500),
             "expected OrchestratorAdmin :restart cap on the first-joining user " <>
               "after legacy session rehydration. Got caps:\n" <>
               inspect(Ezagent.Identity.list_caps_for(user_uri), pretty: true)
    end

    test "second user joining does NOT get owner cap (owner already claimed)" do
      # Once owner is set, subsequent joins must NOT cascade
      # OrchestratorAdmin grants to every joiner. The cap is
      # SINGLY-bound to the session owner.
      short_name = "rfc402-second-join-#{System.unique_integer([:positive])}"
      workspace_uri = URI.parse("workspace://system")
      session_uri = URI.new!("session://default/system/#{short_name}")

      # Spawn legacy session.
      {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      first_user = User.admin_uri()
      _ = Ezagent.SpawnRegistry.spawn(first_user)

      join_target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      ctx = %{
        caller: Ezagent.SystemPrincipal.uri("session-internal"),
        caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
        reply: {:caller_inbox, self()}
      }

      {:ok, _} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: join_target,
          mode: :call,
          args: %{member: first_user},
          ctx: ctx
        })

      # Now a SECOND user joins (synthetic non-admin URI).
      second_user =
        URI.new!("entity://user/system/second-#{System.unique_integer([:positive])}")

      _ = Ezagent.SpawnRegistry.spawn(second_user)

      {:ok, _} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: join_target,
          mode: :call,
          args: %{member: second_user},
          ctx: ctx
        })

      # Owner is still the first user, NOT the second.
      assert {:ok, ^first_user} = Session.owner(session_uri)

      # Drain any pending cast for the FIRST user's grant_cap so the
      # subsequent assertion against the second user is clean.
      Process.sleep(200)

      # Second user does NOT hold the OrchestratorAdmin cap for this
      # session.
      second_caps = Ezagent.Identity.list_caps_for(second_user)

      refute Enum.any?(second_caps, fn cap ->
               match?(%Capability{}, cap) and
                 cap.kind == :session and
                 cap.behavior == Ezagent.Behavior.OrchestratorAdmin and
                 cap.instance == session_uri
             end),
             "RFC #402: only the session OWNER may hold OrchestratorAdmin " <>
               "on this session. Second joiner must not get the cap."
    end

    test "agent join does NOT claim owner (user_uri? gate)" do
      # When orchestrator-spawn calls auto_join_session_members and
      # the orchestrator's chat.join lands BEFORE any user joins,
      # the agent URI MUST NOT become owner — only entity://user URIs
      # qualify.
      short_name = "rfc402-agent-no-claim-#{System.unique_integer([:positive])}"
      workspace_uri = URI.parse("workspace://system")
      session_uri = URI.new!("session://default/system/#{short_name}")

      {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      # An agent URI (cc-orchestrator naming convention).
      agent_uri =
        URI.new!("entity://agent/system/cc_orchestrator-#{short_name}")

      _ = Ezagent.SpawnRegistry.spawn(agent_uri)

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      _ =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :call,
          args: %{member: agent_uri},
          ctx: %{
            caller: Ezagent.SystemPrincipal.uri("session-internal"),
            caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
            reply: {:caller_inbox, self()}
          }
        })

      # owner_uri stays nil — agent doesn't qualify.
      assert {:ok, nil} = Session.owner(session_uri)
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

  # Poll the entity's cap MapSet until `predicate.(cap)` matches one
  # of the held caps OR the deadline expires. Returns true on hit,
  # false on timeout. Used by the cast-driven first-USER-join
  # assertion above (cap shows up asynchronously after the cast
  # lands on the User Kind's mailbox).
  defp wait_for_cap(%URI{} = entity_uri, predicate, timeout_ms) when is_function(predicate, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_cap(entity_uri, predicate, deadline)
  end

  defp do_wait_for_cap(entity_uri, predicate, deadline) do
    if Enum.any?(Ezagent.Identity.list_caps_for(entity_uri), predicate) do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        do_wait_for_cap(entity_uri, predicate, deadline)
      end
    end
  end
end
