defmodule Ezagent.Workspace.UserReadsTest do
  @moduledoc """
  Contract test for the workspace USER-roster read chokepoint
  (`Ezagent.Workspace.UserReads`) — read-plane PR-4 rework.

  The discriminating cases: a declared workspace member sees the
  workspace's provisioned-user roster; a cap-scoped NON-member gets `[]`
  (the F2 class of bug — the roster is not for anyone who merely passes
  the coarse workspace gate); an operator (promoted, non-bootstrap) sees
  the roster; `reveal_metadata?/2` is true for self and operators only;
  an unavailable user-listing facade fails closed to `[]`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.UserReads

  defmodule FakeUserListing do
    @moduledoc false
    def list_in_workspace(%URI{scheme: "workspace"}) do
      Process.get({:fake_user_listing, :users}, [])
    end
  end

  setup do
    ws_name = "ws-user-reads-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Ezagent.Workspace.create(ws_name, %{})

    workspace_uri = Ezagent.URI.workspace(ws_name)
    member = Ezagent.URI.user(ws_name, "member")
    other = Ezagent.URI.user(ws_name, "other")
    outsider = Ezagent.URI.user(ws_name, "outsider")

    for uri <- [member, other, outsider] do
      {:ok, _row} = Ezagent.Users.create(uri, nil, [])
    end

    {:ok, _} = Ezagent.Workspace.Store.update_members(ws_name, [member, other])

    Application.put_env(:ezagent_domain_workspace, :user_listing_facade, FakeUserListing)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :user_listing_facade)
    end)

    {:ok,
     ws_name: ws_name,
     workspace_uri: workspace_uri,
     member: member,
     other: other,
     outsider: outsider}
  end

  defp fake_user_row(%URI{} = uri), do: %{uri: uri}

  test "users/2: a declared workspace member sees the roster", %{
    workspace_uri: workspace_uri,
    member: member,
    other: other
  } do
    Process.put({:fake_user_listing, :users}, [fake_user_row(member), fake_user_row(other)])

    assert UserReads.users(member, workspace_uri) == [
             fake_user_row(member),
             fake_user_row(other)
           ]
  end

  test "users/2: a cap-scoped NON-member gets [] (the roster is members/operators only)",
       %{workspace_uri: workspace_uri, member: member, outsider: outsider} do
    Process.put({:fake_user_listing, :users}, [fake_user_row(member)])

    # The outsider holds NO membership; even a workspace-scoped cap would
    # only pass the coarse gate — the roster itself stays closed.
    assert UserReads.users(outsider, workspace_uri) == []
    assert UserReads.users(nil, workspace_uri) == []
  end

  test "users/2: an operator (promoted, non-bootstrap) sees the roster", %{
    workspace_uri: workspace_uri,
    member: member
  } do
    Process.put({:fake_user_listing, :users}, [fake_user_row(member)])

    operator =
      Ezagent.URI.new!("entity://system/user/op-#{System.unique_integer([:positive])}")

    assert UserReads.users(operator, workspace_uri) == [fake_user_row(member)]
  end

  test "users/2: an unavailable user-listing facade fails closed to []", %{
    workspace_uri: workspace_uri,
    member: member
  } do
    Application.put_env(:ezagent_domain_workspace, :user_listing_facade, __MODULE__.Defunct)

    assert UserReads.users(member, workspace_uri) == []
  end

  test "reveal_metadata?/2: self and operators only", %{member: member, other: other} do
    operator =
      Ezagent.URI.new!("entity://system/user/op-#{System.unique_integer([:positive])}")

    assert UserReads.reveal_metadata?(member, member)
    refute UserReads.reveal_metadata?(member, other)
    assert UserReads.reveal_metadata?(operator, other)
    refute UserReads.reveal_metadata?(nil, member)
  end

  defmodule Defunct do
    @moduledoc false
  end
end
