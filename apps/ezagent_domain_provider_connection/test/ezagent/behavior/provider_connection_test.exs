defmodule Ezagent.Behavior.ProviderConnectionTest do
  use ExUnit.Case, async: false

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.Entity.User

  @actions [
    :begin_authorization,
    :consume_callback,
    :reauthorize,
    :refresh,
    :revoke,
    :disconnect,
    :read_connection
  ]

  test "declares seven exact user-cap actions and remains registry-only" do
    assert ProviderConnection.actions() == @actions

    for action <- @actions do
      assert ProviderConnection.required_caps()[action] ==
               Ezagent.Capability.cap(:user, ProviderConnection, action)

      assert {:ok, ProviderConnection} = Ezagent.BehaviorRegistry.lookup(User, action)
    end

    refute ProviderConnection in User.behaviors()

    for action <- @actions do
      spec = ProviderConnection.__action_spec__(action)
      assert spec.data_owner == :self
      refute spec.args == %{command: :map}
      refute spec.returns == :map
    end
  end

  test "destructive owner commands fail closed unless assurance is explicitly accepted" do
    parent = self()

    boundary = fn action, command, _ctx ->
      send(parent, {:boundary, action, command})
      {:ok, %{accepted: true}}
    end

    Application.put_env(:ezagent_domain_provider_connection, :command_boundary, boundary)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :command_boundary)
      Application.delete_env(:ezagent_domain_provider_connection, :assurance_validator)
    end)

    owner = Ezagent.URI.user(:team_alpha, :owner)
    ctx = %{self_uri: owner, caller: owner}

    assurance = %{
      owner_uri: owner,
      workspace_uri: Ezagent.Capability.workspace_of(owner),
      grantee_uri: owner,
      connection_id: "connection-1",
      connection_version: 1,
      attempt_ref: "attempt-1",
      attempt_version: 1,
      status: :valid,
      signature: "signed-assurance",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    for action <- [:reauthorize, :revoke, :disconnect] do
      handler = String.to_existing_atom("handle_#{action}")

      assert {:error, :assurance_validation_unavailable} =
               apply(ProviderConnection, handler, [
                 %{connection_id: "connection-1", expected_version: 1, assurance: assurance},
                 ctx
               ])

      refute_received {:boundary, ^action, _}
    end

    Application.put_env(:ezagent_domain_provider_connection, :assurance_validator, fn _, _, _ ->
      :ok
    end)

    assert {:ok, %{accepted: true}} =
             ProviderConnection.handle_revoke(
               %{connection_id: "connection-1", expected_version: 1, assurance: assurance},
               ctx
             )

    assert_received {:boundary, :revoke, _}
  end

  test "owner commands are stateless and the frozen boundary does not fake domain mutation" do
    assert {:ok, %{}} = ProviderConnection.create(%{})

    ctx = %{self_uri: Ezagent.URI.user(:team_alpha, :owner), read: fn _, default -> default end}

    for action <- [:consume_callback, :refresh, :read_connection] do
      handler = String.to_existing_atom("handle_#{action}")

      assert {:error, :provider_connection_orchestration_not_implemented} =
               apply(ProviderConnection, handler, [%{}, ctx])
    end

    assert {:error, :callback_artifact_required} =
             ProviderConnection.handle_begin_authorization(%{}, ctx)
  end
end
