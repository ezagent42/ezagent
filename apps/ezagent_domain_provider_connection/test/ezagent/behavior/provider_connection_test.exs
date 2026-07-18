defmodule Ezagent.ActionSet.ProviderConnectionTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap!: 3, with_test_authority: 3]

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.Entity.User

  defmodule AcceptingAssuranceValidator do
    @behaviour Ezagent.ProviderConnection.AssuranceValidator

    @impl true
    def validate(action, assurance, context) do
      send(context.test_pid, {:assurance, action, assurance})
      :ok
    end
  end

  defmodule RejectingAssuranceValidator do
    @behaviour Ezagent.ProviderConnection.AssuranceValidator

    @impl true
    def validate(_action, _assurance, _context), do: {:error, :assurance_rejected}
  end

  @actions [
    :begin_authorization,
    :consume_callback,
    :reauthorize,
    :refresh,
    :revoke,
    :disconnect,
    :read_connection
  ]

  test "data owner is exactly the target User and malformed inputs fail closed" do
    owner = Ezagent.URI.user(:team_alpha, :owner)

    assert ProviderConnection.data_owner(owner) == owner

    assert ProviderConnection.data_owner(Ezagent.URI.agent(:team_alpha, :worker)) ==
             :no_owner

    assert ProviderConnection.data_owner(:any) == :no_owner
    assert ProviderConnection.data_owner(nil) == :no_owner
  end

  test "declares seven exact user-cap actions and remains registry-only" do
    assert ProviderConnection.actions() == @actions

    for action <- @actions do
      assert ProviderConnection.required_caps()[action] ==
               Ezagent.Capability.cap(:user, ProviderConnection, action)

      assert {:ok, ProviderConnection} = Ezagent.BehaviorRegistry.lookup(User, action)
    end

    refute ProviderConnection in User.behaviors()

    expected = %{
      begin_authorization:
        {%{
           connection_id: :string,
           provider_id: :string,
           governed_host: :string,
           acquisition_method: :string,
           execution_identity: :string,
           requested_permissions_digest: :string,
           redirect_uri_id: :string,
           correlation_id: :string,
           callback_artifact: :map
         }, %{attempt_ref: :string, authorization_url: :string, expires_at: :string}},
      consume_callback:
        {%{attempt_ref: :string, callback: :map, correlation_id: :string},
         %{connection_id: :string, status: :string, version: :integer}},
      reauthorize:
        {%{connection_id: :string, expected_version: :integer, assurance: :map},
         %{attempt_ref: :string, authorization_url: :string, expires_at: :string}},
      refresh:
        {%{connection_id: :string, expected_version: :integer, correlation_id: :string},
         %{connection_id: :string, status: :string, version: :integer}},
      revoke:
        {%{connection_id: :string, expected_version: :integer, assurance: :map},
         %{connection_id: :string, status: :string, version: :integer}},
      disconnect:
        {%{connection_id: :string, expected_version: :integer, assurance: :map},
         %{connection_id: :string, status: :string, version: :integer}},
      read_connection: {%{connection_id: :string}, %{connection: :map}}
    }

    for {action, {args, returns}} <- expected do
      spec = ProviderConnection.__action_spec__(action)
      assert spec.args == args
      assert spec.returns == returns
      assert spec.data_owner == :self
    end
  end

  test "callback artifact rejects every wrong signed coordinate and tampering before boundary" do
    parent = self()
    owner = Ezagent.URI.user(:team_alpha, :callback_owner)
    caller = Ezagent.URI.user(:team_alpha, :callback_operator)
    workspace = Ezagent.Capability.workspace_of(owner)
    ctx = %{self_uri: owner, caller: caller}

    Application.put_env(:ezagent_domain_provider_connection, :command_boundary, fn action, _, _ ->
      send(parent, {:boundary, action})
      {:ok, :accepted}
    end)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :command_boundary)
    end)

    with_test_authority(owner, :user, fn authority ->
      base =
        Ezagent.Capability.cap(
          :user,
          ProviderConnection,
          :consume_callback,
          Ezagent.URI.instance(owner),
          workspace
        )

      valid = authority_signed_cap!(authority, caller, base)

      signed_wrong =
        [
          %{base | kind: :agent},
          %{base | behavior: Ezagent.ActionSet.Identity},
          %{base | action: :refresh},
          %{base | instance: Ezagent.URI.instance(User.admin_uri())},
          %{base | workspace_uri: Ezagent.URI.workspace(:wrong)}
        ]
        |> Enum.map(&authority_signed_cap!(authority, caller, &1))

      wrong_grantee =
        authority_signed_cap!(authority, Ezagent.URI.user(:team_alpha, :other), base)

      tampered = %{valid | action: :refresh}

      for artifact <- [tampered, wrong_grantee | signed_wrong] do
        assert {:error, _} =
                 ProviderConnection.handle_begin_authorization(
                   %{callback_artifact: artifact},
                   ctx
                 )

        refute_received {:boundary, _}
      end

      assert {:ok, :accepted} =
               ProviderConnection.handle_begin_authorization(%{callback_artifact: valid}, ctx)

      assert_received {:boundary, :begin_authorization}
    end)
  end

  test "destructive assurances exhaustively reject bad coordinates before validator and boundary" do
    parent = self()
    owner = Ezagent.URI.user(:team_alpha, :assurance_owner)
    caller = Ezagent.URI.user(:team_alpha, :assurance_operator)
    ctx = %{self_uri: owner, caller: caller, test_pid: parent}
    valid = assurance(owner, caller)

    Application.put_env(:ezagent_domain_provider_connection, :command_boundary, fn action, _, _ ->
      send(parent, {:boundary, action})
      {:ok, :accepted}
    end)

    Application.put_env(
      :ezagent_domain_provider_connection,
      :assurance_validator,
      AcceptingAssuranceValidator
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :command_boundary)
      Application.delete_env(:ezagent_domain_provider_connection, :assurance_validator)
    end)

    invalid = [
      nil,
      %{valid | expires_at: DateTime.add(DateTime.utc_now(), -1, :second)},
      %{valid | owner_uri: User.admin_uri()},
      %{valid | workspace_uri: Ezagent.URI.workspace(:wrong)},
      %{valid | grantee_uri: User.admin_uri()},
      %{valid | connection_id: "wrong"},
      %{valid | connection_version: 2},
      %{valid | attempt_ref: nil},
      %{valid | attempt_version: -1},
      %{valid | status: :revoked},
      %{valid | signature: nil}
    ]

    for action <- [:reauthorize, :revoke, :disconnect], bad <- invalid do
      handler = String.to_existing_atom("handle_#{action}")
      args = %{connection_id: "connection-1", expected_version: 1, assurance: bad}
      assert {:error, _} = apply(ProviderConnection, handler, [args, ctx])
      refute_received {:assurance, _, _}
      refute_received {:boundary, _}
    end

    for action <- [:reauthorize, :revoke, :disconnect] do
      handler = String.to_existing_atom("handle_#{action}")
      args = %{connection_id: "connection-1", expected_version: 1, assurance: valid}
      assert {:ok, :accepted} = apply(ProviderConnection, handler, [args, ctx])
      assert_received {:assurance, ^action, ^valid}
      assert_received {:boundary, ^action}
    end

    Application.put_env(
      :ezagent_domain_provider_connection,
      :assurance_validator,
      RejectingAssuranceValidator
    )

    assert {:error, :assurance_rejected} =
             ProviderConnection.handle_revoke(
               %{connection_id: "connection-1", expected_version: 1, assurance: valid},
               ctx
             )

    refute_received {:boundary, _}
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

    Application.put_env(
      :ezagent_domain_provider_connection,
      :assurance_validator,
      AcceptingAssuranceValidator
    )

    assert {:ok, %{accepted: true}} =
             ProviderConnection.handle_revoke(
               %{connection_id: "connection-1", expected_version: 1, assurance: assurance},
               Map.put(ctx, :test_pid, self())
             )

    assert_received {:assurance, :revoke, ^assurance}
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

  defp assurance(owner, caller) do
    %{
      owner_uri: owner,
      workspace_uri: Ezagent.Capability.workspace_of(owner),
      grantee_uri: caller,
      connection_id: "connection-1",
      connection_version: 1,
      attempt_ref: "attempt-1",
      attempt_version: 1,
      status: :valid,
      signature: "signed-assurance",
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
    }
  end
end
