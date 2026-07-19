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

  `user/2` (the per-URI deep-link chokepoint): self / operator /
  same-workspace declared member may read the row; a non-member and a
  cross-tenant caller are denied BEFORE existence is checked (a denied
  caller never learns `:not_found` — no existence oracle).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.UserReads

  defmodule FakeUserListing do
    @moduledoc false
    def list_in_workspace(%URI{scheme: "workspace"}) do
      Process.get({:fake_user_listing, :users}, [])
    end

    def get_by_uri(%URI{} = uri) do
      Map.get(Process.get({:fake_user_listing, :by_uri}, %{}), URI.to_string(uri))
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

  # ----- user/2 — the per-URI (deep-link) read chokepoint ---------------

  test "user/2: self read returns the row", %{member: member} do
    row = fake_user_row(member)
    Process.put({:fake_user_listing, :by_uri}, %{URI.to_string(member) => row})

    assert UserReads.user(member, member) == {:ok, row}
  end

  test "user/2: a declared member reads another member of the SAME workspace (roster-visible)",
       %{member: member, other: other} do
    row = fake_user_row(other)
    Process.put({:fake_user_listing, :by_uri}, %{URI.to_string(other) => row})

    assert UserReads.user(member, other) == {:ok, row}
  end

  test "user/2: a NON-member is denied even for a user in a workspace it can name",
       %{other: other, outsider: outsider} do
    Process.put({:fake_user_listing, :by_uri}, %{URI.to_string(other) => fake_user_row(other)})

    assert UserReads.user(outsider, other) == {:error, :unauthorized}
    assert UserReads.user(nil, other) == {:error, :unauthorized}
  end

  test "user/2: CROSS-TENANT — a member of workspace A is denied a user of workspace B",
       %{member: member} do
    ws_b = "ws-user-reads-b-#{System.unique_integer([:positive])}"
    {:ok, _ws_b_pid} = Ezagent.Workspace.create(ws_b, %{})
    user_b = Ezagent.URI.user(ws_b, "someone")
    {:ok, _row} = Ezagent.Users.create(user_b, nil, [])

    Process.put({:fake_user_listing, :by_uri}, %{URI.to_string(user_b) => fake_user_row(user_b)})

    assert UserReads.user(member, user_b) == {:error, :unauthorized}
  end

  test "user/2: an operator (system home) reads any user", %{other: other} do
    row = fake_user_row(other)
    Process.put({:fake_user_listing, :by_uri}, %{URI.to_string(other) => row})

    operator =
      Ezagent.URI.new!("entity://system/user/op-#{System.unique_integer([:positive])}")

    assert UserReads.user(operator, other) == {:ok, row}
  end

  test "user/2: an authorized caller gets :not_found for a missing row", %{
    ws_name: ws_name,
    member: member
  } do
    ghost = Ezagent.URI.user(ws_name, "ghost")

    assert UserReads.user(member, ghost) == {:error, :not_found}
  end

  test "user/2: a DENIED caller gets :unauthorized (never :not_found) — no existence oracle",
       %{member: member} do
    # A ghost URI in a workspace the caller may not read must be
    # indistinguishable from a real one.
    ws_b = "ws-user-reads-b-#{System.unique_integer([:positive])}"
    {:ok, _ws_b_pid} = Ezagent.Workspace.create(ws_b, %{})
    ghost_b = Ezagent.URI.user(ws_b, "ghost")

    assert UserReads.user(member, ghost_b) == {:error, :unauthorized}
  end

  test "user/2: an unavailable user-listing facade fails closed", %{member: member} do
    Application.put_env(:ezagent_domain_workspace, :user_listing_facade, __MODULE__.Defunct)

    assert UserReads.user(member, member) == {:error, :unauthorized}
  end

  defmodule Defunct do
    @moduledoc false
  end
end
