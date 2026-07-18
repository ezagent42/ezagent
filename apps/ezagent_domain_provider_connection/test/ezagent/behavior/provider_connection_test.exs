defmodule Ezagent.Behavior.ProviderConnectionTest do
  use ExUnit.Case, async: true

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
  end

  test "owner commands are stateless and the frozen boundary does not fake domain mutation" do
    assert {:ok, %{}} = ProviderConnection.create(%{})

    ctx = %{self_uri: Ezagent.URI.user(:team_alpha, :owner), read: fn _, default -> default end}

    for action <- @actions -- [:begin_authorization] do
      handler = String.to_existing_atom("handle_#{action}")

      assert {:error, :provider_connection_orchestration_not_implemented} =
               apply(ProviderConnection, handler, [%{command: %{}}, ctx])
    end

    assert {:error, :callback_artifact_required} =
             ProviderConnection.handle_begin_authorization(%{command: %{}}, ctx)
  end
end
