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
    def list_sessions(%URI{scheme: "workspace"}) do
      Process.get({:fake_session_listing, :sessions}, [])
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
    def web_anon_access?(%URI{}), do: false
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
end
