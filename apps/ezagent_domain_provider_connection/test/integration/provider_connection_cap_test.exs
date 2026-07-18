defmodule Ezagent.ProviderConnectionCapTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.{Cap, Capability, Cmd, Router}
  alias Ezagent.Entity.User

  setup do
    parent = self()
    suffix = System.unique_integer([:positive])
    owner = Ezagent.URI.user(:team_alpha, "provider-owner-#{suffix}")
    caller = Ezagent.URI.user(:team_alpha, "provider-caller-#{suffix}")

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner)

    boundary = fn action, args, _ctx ->
      send(parent, {:boundary, action, args})
      {:error, :provider_connection_orchestration_not_implemented}
    end

    Application.put_env(:ezagent_domain_provider_connection, :command_boundary, boundary)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :command_boundary)
    end)

    {:ok, owner: owner, caller: caller}
  end

  test "central User dispatch denies missing and wrong exact caps before the handler", ctx do
    valid = issue_cap!(ctx.owner, ctx.caller, ProviderConnection, :read_connection)

    wrong_caps = [
      MapSet.new(),
      MapSet.new([issue_cap!(ctx.owner, ctx.caller, ProviderConnection, :refresh)]),
      MapSet.new([
        issue_cap!(ctx.owner, ctx.caller, Ezagent.ActionSet.Identity, :read_connection)
      ]),
      MapSet.new([%{valid | instance: Ezagent.URI.instance(User.admin_uri())}]),
      MapSet.new([%{valid | workspace_uri: Ezagent.URI.workspace(:other_workspace)}])
    ]

    for caps <- wrong_caps do
      assert {:error, _} = dispatch_read(ctx.owner, ctx.caller, caps)
      refute_received {:boundary, _, _}
    end

    assert {:error, :provider_connection_orchestration_not_implemented} =
             dispatch_read(ctx.owner, ctx.caller, MapSet.new([valid]))

    assert_received {:boundary, :read_connection, %{connection_id: "connection-1"}}
    refute_received {:boundary, _, _}

    assert {:ok, slice} = Ezagent.Kind.get_slice(ctx.owner, ProviderConnection.state_slice())
    assert slice in [nil, %{state: %{}, transients: %{}}]
  end

  defp dispatch_read(owner, caller, caps) do
    target = Ezagent.URI.with_action(owner, :provider_connection, :read_connection)

    target
    |> Cmd.new(:read_connection, %{connection_id: "connection-1"}, %{
      mode: :call,
      caller: caller,
      caps: caps,
      reply: {:caller_inbox, self()}
    })
    |> Router.dispatch()
  end

  defp issue_cap!(owner, grantee, behavior, action) do
    requested =
      Capability.cap(
        :user,
        behavior,
        action,
        Ezagent.URI.instance(owner),
        Capability.workspace_of(owner)
      )

    assert {:ok, artifact} = Cap.issue({:admin, User.admin_uri()}, grantee, requested)
    artifact
  end
end
