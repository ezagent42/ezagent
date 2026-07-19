defmodule Ezagent.ActionSet.ProviderConnectionTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap!: 3, with_test_authority: 3]

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.Entity.User
  alias Ezagent.ProviderConnection.Assurance

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

  defmodule ArbitraryErrorAssuranceValidator do
    @behaviour Ezagent.ProviderConnection.AssuranceValidator

    @impl true
    def validate(_action, _assurance, _context),
      do: {:error, {:backend_secret, "validator-secret-sentinel"}}
  end

  defmodule RaisingAssuranceValidator do
    @behaviour Ezagent.ProviderConnection.AssuranceValidator

    @impl true
    def validate(_action, _assurance, _context),
      do: raise("validator-secret-sentinel")
  end

  defmodule ThrowingAssuranceValidator do
    @behaviour Ezagent.ProviderConnection.AssuranceValidator

    @impl true
    def validate(_action, _assurance, _context),
      do: throw({:validator_secret, "validator-secret-sentinel"})
  end

  defmodule WrongShapeAssuranceValidator do
    @behaviour Ezagent.ProviderConnection.AssuranceValidator

    @impl true
    def validate(_action, _assurance, _context), do: {:ok, "validator-secret-sentinel"}
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
           callback_artifact: {:struct, Ezagent.Capability}
         }, %{attempt_ref: :string, authorization_url: :string, expires_at: :string}},
      consume_callback:
        {%{attempt_ref: :string, callback: :map, correlation_id: :string},
         %{connection_id: :string, status: :string, version: :integer}},
      reauthorize:
        {%{
           connection_id: :string,
           expected_version: :integer,
           assurance: {:struct, Assurance}
         }, %{attempt_ref: :string, authorization_url: :string, expires_at: :string}},
      refresh:
        {%{connection_id: :string, expected_version: :integer, correlation_id: :string},
         %{connection_id: :string, status: :string, version: :integer}},
      revoke:
        {%{
           connection_id: :string,
           expected_version: :integer,
           assurance: {:struct, Assurance}
         }, %{connection_id: :string, status: :string, version: :integer}},
      disconnect:
        {%{
           connection_id: :string,
           expected_version: :integer,
           assurance: {:struct, Assurance}
         }, %{connection_id: :string, status: :string, version: :integer}},
      read_connection: {%{connection_id: :string}, %{connection: :map}}
    }

    for {action, {args, returns}} <- expected do
      spec = ProviderConnection.__action_spec__(action)
      assert spec.args == {:closed_map, args}
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
                   Map.put(
                     direct_args(:begin_authorization, owner),
                     :callback_artifact,
                     artifact
                   ),
                   ctx
                 )

        refute_received {:boundary, _}
      end

      secret = "direct-callback-artifact-secret-sentinel"

      for forged <- [Map.put(valid, :unsigned_extra, secret), Map.delete(valid, :signature)] do
        assert {:error, {:invalid_args, _}} =
                 result =
                 ProviderConnection.handle_begin_authorization(
                   Map.put(direct_args(:begin_authorization, owner), :callback_artifact, forged),
                   ctx
                 )

        refute inspect(result) =~ secret
        refute_received {:boundary, _}
      end

      assert {:ok, :accepted} =
               ProviderConnection.handle_begin_authorization(
                 Map.put(direct_args(:begin_authorization, owner), :callback_artifact, valid),
                 ctx
               )

      assert_received {:boundary, :begin_authorization}
    end)
  end

  test "begin handler closes malformed callback artifacts without raising" do
    owner = Ezagent.URI.user(:team_alpha, :malformed_callback_owner)
    ctx = %{self_uri: owner, caller: owner}

    for args <- [
          %{},
          Map.put(direct_args(:begin_authorization, owner), :callback_artifact, nil),
          Map.put(direct_args(:begin_authorization, owner), :callback_artifact, %{}),
          Map.put(direct_args(:begin_authorization, owner), :callback_artifact, %{
            grantee_uri: owner
          }),
          Map.put(
            direct_args(:begin_authorization, owner),
            :callback_artifact,
            "not-an-artifact"
          )
        ] do
      assert {:error, reason} = ProviderConnection.handle_begin_authorization(args, ctx)
      assert match?({:invalid_args, _}, reason)
    end
  end

  test "all direct handlers reject extra top-level command keys before boundaries" do
    parent = self()
    owner = Ezagent.URI.user(:team_alpha, :direct_closed_owner)
    ctx = %{self_uri: owner, caller: owner}
    secret = "direct-command-secret-sentinel"

    Application.put_env(:ezagent_domain_provider_connection, :command_boundary, fn action, _, _ ->
      send(parent, {:boundary, action})
      {:ok, :accepted}
    end)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :command_boundary)
    end)

    for action <- @actions do
      handler = String.to_existing_atom("handle_#{action}")

      assert {:error, {:invalid_args, _}} =
               result =
               apply(ProviderConnection, handler, [
                 Map.put(direct_args(action, owner), :unsigned_extra, secret),
                 ctx
               ])

      refute inspect(result) =~ secret
      refute_received {:boundary, _}
    end
  end

  test "assurance validator runtime accepts only its closed result contract" do
    owner = Ezagent.URI.user(:team_alpha, :validator_owner)
    assurance = assurance(owner, owner)
    ctx = %{self_uri: owner, caller: owner}

    assert :ok =
             Ezagent.ProviderConnection.AssuranceValidator.validate(
               AcceptingAssuranceValidator,
               :revoke,
               assurance,
               Map.put(ctx, :test_pid, self())
             )

    assert {:error, :assurance_rejected} =
             Ezagent.ProviderConnection.AssuranceValidator.validate(
               RejectingAssuranceValidator,
               :revoke,
               assurance,
               ctx
             )

    for validator <- [
          ArbitraryErrorAssuranceValidator,
          RaisingAssuranceValidator,
          ThrowingAssuranceValidator,
          WrongShapeAssuranceValidator
        ] do
      result =
        Ezagent.ProviderConnection.AssuranceValidator.validate(
          validator,
          :revoke,
          assurance,
          ctx
        )

      assert result == {:error, :assurance_validator_misconfigured}
      refute inspect(result) =~ "validator-secret-sentinel"
    end
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

  test "assurance evidence has a closed validated struct contract" do
    owner = Ezagent.URI.user(:team_alpha, :assurance_owner)
    grantee = Ezagent.URI.user(:team_alpha, :assurance_operator)

    attrs = %{
      owner_uri: owner,
      workspace_uri: Ezagent.Capability.workspace_of(owner),
      grantee_uri: grantee,
      connection_id: "connection-1",
      connection_version: 1,
      attempt_ref: "attempt-1",
      attempt_version: 1,
      status: :valid,
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
      key_id: "backend-key-1",
      signature: "signed-assurance"
    }

    assert {:ok, %Assurance{} = assurance} = Assurance.new(attrs)
    assert {:error, :invalid_assurance_shape} = Assurance.new(Map.put(attrs, :trusted, true))
    assert {:error, :invalid_assurance} = Assurance.new(Map.put(attrs, :status, :unknown))

    assert {:error, {:invalid_args, _}} =
             ProviderConnection.handle_revoke(
               %{connection_id: "connection-1", expected_version: 1, assurance: attrs},
               %{self_uri: owner, caller: grantee}
             )

    assert assurance.__struct__ == Assurance

    secret = "assurance-struct-secret-sentinel"

    for forged <- [
          Map.put(assurance, :unsigned_extra, secret),
          Map.delete(assurance, :signature)
        ] do
      assert {:error, :invalid_assurance} = result = Assurance.validate(forged)
      refute inspect(result) =~ secret
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

    {:ok, assurance} =
      Assurance.new(%{
        owner_uri: owner,
        workspace_uri: Ezagent.Capability.workspace_of(owner),
        grantee_uri: owner,
        connection_id: "connection-1",
        connection_version: 1,
        attempt_ref: "attempt-1",
        attempt_version: 1,
        status: :valid,
        issued_at: DateTime.utc_now(),
        key_id: "backend-key-1",
        signature: "signed-assurance",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

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
               apply(ProviderConnection, handler, [direct_args(action, ctx.self_uri), ctx])
    end

    assert {:error, {:invalid_args, _}} =
             ProviderConnection.handle_begin_authorization(%{}, ctx)
  end

  defp assurance(owner, caller) do
    {:ok, assurance} =
      Assurance.new(%{
        owner_uri: owner,
        workspace_uri: Ezagent.Capability.workspace_of(owner),
        grantee_uri: caller,
        connection_id: "connection-1",
        connection_version: 1,
        attempt_ref: "attempt-1",
        attempt_version: 1,
        status: :valid,
        issued_at: DateTime.utc_now(),
        key_id: "backend-key-1",
        signature: "signed-assurance",
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    assurance
  end

  defp direct_args(:begin_authorization, _owner),
    do: %{
      connection_id: "connection-1",
      provider_id: "github",
      governed_host: "github.com",
      acquisition_method: "oauth",
      execution_identity: "owner",
      requested_permissions_digest: "digest",
      redirect_uri_id: "callback",
      correlation_id: "correlation-1",
      callback_artifact: %{}
    }

  defp direct_args(:consume_callback, _owner),
    do: %{attempt_ref: "attempt-1", callback: %{}, correlation_id: "correlation-1"}

  defp direct_args(action, owner) when action in [:reauthorize, :revoke, :disconnect],
    do: %{connection_id: "connection-1", expected_version: 1, assurance: assurance(owner, owner)}

  defp direct_args(:refresh, _owner),
    do: %{connection_id: "connection-1", expected_version: 1, correlation_id: "correlation-1"}

  defp direct_args(:read_connection, _owner), do: %{connection_id: "connection-1"}
end
