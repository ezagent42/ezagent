defmodule Ezagent.Workspace.WorkspaceReadsTest do
  @moduledoc """
  Contract test for the workspace session-LIST and agent-LIST read
  chokepoints (`Ezagent.Workspace.WorkspaceReads.sessions/2` and
  `agents/2`).

  The discriminating case: a caller who IS a workspace member but is NOT a
  member of session X must get X ABSENT — a wrapper that only
  workspace-filters (skips the per-row visibility check) FAILS this test.
  The owner/member of X (also a workspace member) DOES see X. A caller who
  is not authorized for the workspace at all fails closed to `[]`. The
  agent plane mirrors it: a workspace member who neither OWNS (creator via
  `data_owner/1`) nor MANAGES (instance-scoped Manage cap) agent X — with
  X not a declared workspace member — gets X ABSENT; the owner sees X.

  The session-side facades are injected via the runtime-DI env keys (the
  workspace domain sits below the session/socialware domains, so the real
  modules are deliberately not compile-time deps here) — the same fake-
  facade pattern as `CreateSessionDispatchTest`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Workspace
  alias Ezagent.Workspace.WorkspaceReads

  defmodule FakeSessionListing do
    @moduledoc false
    def list_persisted_sessions(%URI{scheme: "workspace"}) do
      Process.get({:fake_session_listing, :sessions}, [])
    end

    def list_sessions(%URI{scheme: "workspace"}, %URI{} = caller) do
      authorized = Process.get({:fake_session_reads, :authorized}, [])

      Enum.filter(
        Process.get({:fake_session_listing, :sessions}, []),
        &({caller, &1} in authorized)
      )
    end
  end

  defmodule FakeSessionReads do
    @moduledoc false

    # The shared live-first owner/member predicate, faked: the test seeds
    # exactly which (caller, session) pairs are authorized.
    def authorized?(%URI{} = caller, %URI{} = session_uri) do
      {caller, session_uri} in Process.get({:fake_session_reads, :authorized}, [])
    end
  end

  defmodule FakePublicView do
    @moduledoc false
    def web_anon_access?(%URI{} = session_uri) do
      session_uri in Process.get({:fake_public_view, :public}, [])
    end
  end

  # A facade that does NOT export the required `authorized?/2` — the F6
  # DI-loss case: the membership predicate is unavailable.
  defmodule DefunctSessionReads do
    @moduledoc false
  end

  defmodule FakeAgentListing do
    @moduledoc false
    def list_in_workspace(%URI{scheme: "workspace"}) do
      Process.get({:fake_agent_listing, :agents}, [])
    end
  end

  setup do
    ws_name = "ws-reads-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})

    workspace_uri = Ezagent.URI.workspace(ws_name)
    session_x = Ezagent.URI.session(ws_name, "default", "x")
    agent_x = Ezagent.URI.agent(ws_name, "x")

    member_uri = URI.new!("entity://#{ws_name}/user/member")
    nonmember_uri = URI.new!("entity://#{ws_name}/user/nonmember")
    outsider_uri = URI.new!("entity://#{ws_name}/user/outsider")

    for uri <- [member_uri, nonmember_uri, outsider_uri] do
      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new()})
    end

    # `member` and `nonmember` belong to the workspace; `outsider` does not.
    :ok = Workspace.add_member(ws_name, member_uri)
    :ok = Workspace.add_member(ws_name, nonmember_uri)
    # Allow the async membership/cap writes to land before the store read.
    Process.sleep(75)

    # The workspace-scoped base listing hands back session X for everyone;
    # per-row, only `member_uri` is an owner/member of X.
    Process.put({:fake_session_listing, :sessions}, [session_x])
    Process.put({:fake_session_reads, :authorized}, [{member_uri, session_x}])

    # Same for the agent plane: the base listing hands back agent X for
    # everyone; per-row, only `member_uri` OWNS X (recorded via the real
    # `AgentLineage`, the `data_owner/1` fallback tier). `nonmember_uri`
    # holds no caps over X and X is NOT a declared workspace member.
    Process.put({:fake_agent_listing, :agents}, [agent_x])
    :ok = Ezagent.AgentLineage.record(agent_x, member_uri)

    Application.put_env(:ezagent_domain_workspace, :session_listing_facade, FakeSessionListing)
    Application.put_env(:ezagent_domain_workspace, :session_reads_facade, FakeSessionReads)
    Application.put_env(:ezagent_domain_workspace, :public_view_facade, FakePublicView)
    Application.put_env(:ezagent_domain_workspace, :agent_listing_facade, FakeAgentListing)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :session_listing_facade)
      Application.delete_env(:ezagent_domain_workspace, :session_reads_facade)
      Application.delete_env(:ezagent_domain_workspace, :public_view_facade)
      Application.delete_env(:ezagent_domain_workspace, :agent_listing_facade)
      Ezagent.AgentLineage.forget(agent_x)
    end)

    {:ok,
     ws_name: ws_name,
     workspace_uri: workspace_uri,
     session_x: session_x,
     agent_x: agent_x,
     member_uri: member_uri,
     nonmember_uri: nonmember_uri,
     outsider_uri: outsider_uri}
  end

  test "sessions/2: per-row visibility — workspace member who is not a session member does not see the session; the owner/member does",
       %{
         workspace_uri: workspace_uri,
         session_x: session_x,
         member_uri: member_uri,
         nonmember_uri: nonmember_uri,
         outsider_uri: outsider_uri
       } do
    # The owner/member of X (also a workspace member) sees X.
    assert WorkspaceReads.sessions(member_uri, workspace_uri) == [session_x]

    # The workspace member who is NOT a member of X gets X ABSENT — a
    # workspace-only filter would return [session_x] here and FAIL.
    assert WorkspaceReads.sessions(nonmember_uri, workspace_uri) == []

    # Fail closed: a caller not authorized for the workspace gets [] even
    # though the workspace-scoped listing is non-empty.
    assert WorkspaceReads.sessions(outsider_uri, workspace_uri) == []
    assert WorkspaceReads.sessions(nil, workspace_uri) == []
  end

  test "agents/2: per-row visibility — workspace member who neither owns nor manages agent X gets X ABSENT; the owner sees X",
       %{
         workspace_uri: workspace_uri,
         agent_x: agent_x,
         member_uri: member_uri,
         nonmember_uri: nonmember_uri,
         outsider_uri: outsider_uri
       } do
    # The owner of X (also a workspace member) sees X.
    assert WorkspaceReads.agents(member_uri, workspace_uri) == [agent_x]

    # The workspace member who neither owns nor manages X (and X is not a
    # declared workspace member) gets X ABSENT — a workspace-only filter
    # would return [agent_x] here and FAIL.
    assert WorkspaceReads.agents(nonmember_uri, workspace_uri) == []

    # Fail closed: a caller not authorized for the workspace gets [] even
    # though the workspace-scoped listing is non-empty.
    assert WorkspaceReads.agents(outsider_uri, workspace_uri) == []
    assert WorkspaceReads.agents(nil, workspace_uri) == []
  end

  test "agents/2: F2 — a cap-scoped NON-member gets [] for the shared roster (was: full roster); a declared-member caller sees the roster",
       %{
         ws_name: ws_name,
         workspace_uri: workspace_uri,
         session_x: session_x,
         agent_x: agent_x,
         member_uri: member_uri,
         nonmember_uri: nonmember_uri
       } do
    # Agent X is a DECLARED workspace member → it is on the shared roster.
    {:ok, _} =
      Ezagent.Workspace.Store.update_members(ws_name, [member_uri, nonmember_uri, agent_x])

    # A declared workspace member who neither OWNS nor MANAGES X sees it via
    # the shared-roster disjunct (the CALLER's membership admits the row).
    assert WorkspaceReads.agents(nonmember_uri, workspace_uri) == [agent_x]

    # The F2 bypass principal: OUTSIDE the workspace's declared members but
    # holding ONE narrow workspace-scoped cap (which admits the workspace
    # into their `list_workspaces_for/2` visible set, passing the coarse
    # workspace gate). Pre-fix this caller got the WHOLE shared roster
    # ([agent_x]); the shared-roster disjunct must key on the CALLER's
    # membership, so now they get [].
    cap_outsider = URI.new!("entity://#{ws_name}/user/cap-outsider")
    {:ok, _row} = Ezagent.Users.create_read_only(cap_outsider, [])
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: cap_outsider, initial_caps: MapSet.new()})

    :ok =
      Ezagent.IdentityCaps.grant(
        cap_outsider,
        signed_session_send_cap(session_x, workspace_uri, cap_outsider)
      )

    assert WorkspaceReads.agents(cap_outsider, workspace_uri) == []

    # Sanity: the cap IS what lets the outsider through the workspace gate
    # (without it the test would pass vacuously) — the caller IS
    # workspace-authorized, just not a declared member.
    assert WorkspaceReads.authorized_workspace?(cap_outsider, workspace_uri)
    refute WorkspaceReads.declared_member?(cap_outsider, workspace_uri)
  end

  test "sessions/2: F6 — an unavailable membership facade fails closed to [] (NO public-predicate fallthrough)",
       %{
         workspace_uri: workspace_uri,
         session_x: session_x,
         member_uri: member_uri
       } do
    # The membership predicate facade is DOWN; the public predicate WOULD
    # admit the row. Strict fail-closed: the whole read returns [] BEFORE
    # filtering — a public row is not a substitute for the membership check.
    Application.put_env(:ezagent_domain_workspace, :session_reads_facade, DefunctSessionReads)
    Process.put({:fake_public_view, :public}, [session_x])

    on_exit(fn ->
      Application.put_env(:ezagent_domain_workspace, :session_reads_facade, FakeSessionReads)
    end)

    assert WorkspaceReads.sessions(member_uri, workspace_uri) == []
  end

  test "sessions/2: a PUBLIC session stays visible to a workspace non-member when the membership facade is healthy",
       %{
         workspace_uri: workspace_uri,
         session_x: session_x,
         nonmember_uri: nonmember_uri
       } do
    Process.put({:fake_public_view, :public}, [session_x])

    # `nonmember_uri` is a workspace member but NOT a member of X; X is
    # public, so the public disjunct admits it (the membership facade is
    # healthy — F6 only closes the read when it is DOWN).
    assert WorkspaceReads.sessions(nonmember_uri, workspace_uri) == [session_x]
  end

  test "workspace authorization rejects a cap after its target generation is revoked", %{
    workspace_uri: workspace_uri,
    outsider_uri: outsider_uri
  } do
    {:ok, _row} = Ezagent.Users.create_read_only(outsider_uri, [])

    requested =
      Ezagent.Capability.cap(
        :workspace,
        Ezagent.ActionSet.Workspace,
        :list_members,
        workspace_uri,
        workspace_uri
      )

    cap = Ezagent.Test.CapHelper.signed_cap!(workspace_uri, outsider_uri, requested)
    :ok = Ezagent.IdentityCaps.grant(outsider_uri, cap)

    assert WorkspaceReads.authorized_workspace?(outsider_uri, workspace_uri)

    revoke_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri)
    assert {:ok, _generation} = Ezagent.Cap.revoke_all_to(workspace_uri, revoke_ctx)

    refute WorkspaceReads.authorized_workspace?(outsider_uri, workspace_uri)
  end

  # A narrow workspace-scoped session-send cap for `grantee` — admits the
  # workspace into the grantee's `list_workspaces_for/2` visible set
  # WITHOUT granting any agent owns/manages relationship.
  defp signed_session_send_cap(session_uri, workspace_uri, grantee) do
    requested =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :send,
        session_uri,
        workspace_uri
      )

    Ezagent.Test.CapHelper.with_test_authority(session_uri, :session, fn authority ->
      Ezagent.Test.CapHelper.authority_signed_cap!(authority, grantee, requested)
    end)
  end
end
