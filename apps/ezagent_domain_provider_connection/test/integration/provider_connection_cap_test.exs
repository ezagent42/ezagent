defmodule Ezagent.ProviderConnectionCapTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.ProviderConnection
  alias Ezagent.{Cap, Capability, Cmd, Router}
  alias Ezagent.Entity.User
  alias Ezagent.ProviderConnection.Assurance

  defmodule AcceptingValidator do
    @behaviour Ezagent.ProviderConnection.AssuranceValidator

    @impl true
    def validate(action, _assurance, _context) do
      send(
        Application.fetch_env!(:ezagent_domain_provider_connection, :test_pid),
        {:assurance, action}
      )

      :ok
    end
  end

  @actions ProviderConnection.actions()

  setup do
    parent = self()
    suffix = System.unique_integer([:positive])
    owner = Ezagent.URI.user(:team_alpha, "provider-owner-#{suffix}")
    caller = Ezagent.URI.user(:team_alpha, "provider-caller-#{suffix}")

    assert {:ok, _user} = Ezagent.Users.create(owner, nil, [])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(owner)

    boundary = fn action, args, _ctx ->
      send(parent, {:boundary, action, args})
      {:error, :authorization_backend_unavailable}
    end

    Application.put_env(:ezagent_domain_provider_connection, :command_boundary, boundary)
    Application.put_env(:ezagent_domain_provider_connection, :test_pid, parent)

    Application.put_env(
      :ezagent_domain_provider_connection,
      :assurance_validator,
      AcceptingValidator
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :command_boundary)
      Application.delete_env(:ezagent_domain_provider_connection, :test_pid)
      Application.delete_env(:ezagent_domain_provider_connection, :assurance_validator)
    end)

    {:ok, owner: owner, caller: caller}
  end

  test "all seven actions authorize only an exact signed cap before any later boundary", ctx do
    wrong_workspace_owner = Ezagent.URI.user(:other_workspace, "wrong-workspace-owner")

    for action <- @actions do
      valid = issue_cap!(ctx.owner, ctx.caller, ProviderConnection, action)

      wrong_caps = [
        MapSet.new(),
        MapSet.new([issue_cap!(ctx.owner, ctx.caller, ProviderConnection, wrong_action(action))]),
        MapSet.new([issue_cap!(ctx.owner, ctx.caller, Ezagent.ActionSet.Identity, action)]),
        MapSet.new([issue_cap!(User.admin_uri(), ctx.caller, ProviderConnection, action)]),
        MapSet.new([
          issue_cap!(wrong_workspace_owner, ctx.caller, ProviderConnection, action)
        ])
      ]

      for caps <- wrong_caps do
        assert {:error, _} = dispatch(ctx.owner, ctx.caller, action, args(action, ctx), caps)
        refute_received {:assurance, _}
        refute_received {:boundary, _, _}
      end

      result =
        dispatch(
          ctx.owner,
          ctx.caller,
          action,
          args(action, ctx),
          MapSet.new([valid])
        )

      if action in [:reauthorize, :revoke, :disconnect] do
        assert result == {:error, :assurance_validation_unavailable}
        refute_received {:assurance, ^action}
        refute_received {:boundary, ^action, _}
      else
        assert result == {:error, :authorization_backend_unavailable}
        assert_received {:boundary, ^action, _}
      end

      refute_received {:boundary, _, _}
    end

    assert {:ok, slice} = Ezagent.Kind.get_slice(ctx.owner, ProviderConnection.state_slice())
    assert slice in [nil, %{state: %{}, transients: %{}}]
  end

  test "live begin dispatch rejects malformed artifacts before the command boundary", ctx do
    cap = issue_cap!(ctx.owner, ctx.caller, ProviderConnection, :begin_authorization)
    callback = issue_cap!(ctx.owner, ctx.owner, ProviderConnection, :consume_callback)
    wrong_grantee = Ezagent.URI.user(:team_alpha, :wrong_callback_grantee)
    wrong_workspace_owner = Ezagent.URI.user(:other_workspace, :wrong_callback_owner)

    secret = "callback-artifact-secret-sentinel"

    invalid_artifacts = [
      %{},
      %{grantee_uri: ctx.caller},
      "not-an-artifact",
      nil,
      %{callback | action: :refresh},
      issue_cap!(ctx.owner, wrong_grantee, ProviderConnection, :consume_callback),
      issue_cap!(ctx.owner, ctx.caller, ProviderConnection, :consume_callback),
      issue_cap!(ctx.owner, ctx.caller, ProviderConnection, :refresh),
      issue_cap!(ctx.owner, ctx.caller, Ezagent.ActionSet.Identity, :consume_callback),
      issue_cap!(User.admin_uri(), ctx.caller, ProviderConnection, :consume_callback),
      issue_cap!(wrong_workspace_owner, ctx.caller, ProviderConnection, :consume_callback),
      callback |> Map.from_struct() |> Map.put(:unsigned_extra, secret),
      Map.delete(callback, :signature)
    ]

    for artifact <- invalid_artifacts do
      malformed_args = Map.put(args(:begin_authorization, ctx), :callback_artifact, artifact)

      assert {:error, _reason} =
               result =
               dispatch(
                 ctx.owner,
                 ctx.caller,
                 :begin_authorization,
                 malformed_args,
                 MapSet.new([cap])
               )

      refute inspect(result) =~ secret
      refute_received {:boundary, _, _}
    end

    assert {:error, :authorization_backend_unavailable} =
             dispatch(
               ctx.owner,
               ctx.caller,
               :begin_authorization,
               Map.put(args(:begin_authorization, ctx), :callback_artifact, callback),
               MapSet.new([cap])
             )

    assert_received {:boundary, :begin_authorization, _}
    refute_received {:boundary, _, _}
  end

  test "all seven live actions reject extra authority and secret keys before boundaries", ctx do
    secret = "live-command-secret-sentinel"

    extras = [
      {:owner_uri, ctx.owner},
      {:workspace_uri, Capability.workspace_of(ctx.owner)},
      {:grantee, ctx.caller},
      {:action, :read_connection},
      {:unsigned_extra, secret}
    ]

    for action <- @actions do
      cap = issue_cap!(ctx.owner, ctx.caller, ProviderConnection, action)

      for {key, value} <- extras do
        assert {:error, {:invalid_args, _}} =
                 result =
                 dispatch(
                   ctx.owner,
                   ctx.caller,
                   action,
                   Map.put(args(action, ctx), key, value),
                   MapSet.new([cap])
                 )

        refute inspect(result) =~ secret
        refute_received {:assurance, _}
        refute_received {:boundary, _, _}
      end

      result =
        dispatch(
          ctx.owner,
          ctx.caller,
          action,
          args(action, ctx),
          MapSet.new([cap])
        )

      if action in [:reauthorize, :revoke, :disconnect] do
        assert result == {:error, :assurance_validation_unavailable}
        refute_received {:assurance, ^action}
        refute_received {:boundary, ^action, _}
      else
        assert result == {:error, :authorization_backend_unavailable}
        assert_received {:boundary, ^action, _}
      end

      refute_received {:boundary, _, _}
    end
  end

  defp dispatch(owner, caller, action, args, caps) do
    target = Ezagent.URI.with_action(owner, :provider_connection, action)

    target
    |> Cmd.new(action, args, %{
      mode: :call,
      caller: caller,
      caps: caps,
      reply: {:caller_inbox, self()}
    })
    |> Router.dispatch()
  end

  defp args(:begin_authorization, ctx) do
    callback = issue_cap!(ctx.owner, ctx.owner, ProviderConnection, :consume_callback)

    %{
      connection_id: "connection-1",
      provider_id: "github",
      governed_host: "github.com",
      acquisition_method: "oauth",
      requested_execution_identity_class: "connected_user",
      requested_permissions_digest: "digest",
      redirect_uri_id: "callback",
      correlation_id: "correlation-1",
      callback_artifact: callback
    }
  end

  defp args(:consume_callback, _ctx),
    do: %{attempt_ref: "attempt-1", correlation_id: "correlation-1"}

  defp args(action, ctx) when action in [:reauthorize, :revoke, :disconnect] do
    {:ok, assurance} =
      Assurance.new(%{
        owner_uri: ctx.owner,
        workspace_uri: Capability.workspace_of(ctx.owner),
        grantee_uri: ctx.caller,
        connection_id: "connection-1",
        connection_version: 1,
        attempt_ref: "attempt-1",
        attempt_version: 1,
        status: :valid,
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
        key_id: "backend-key-1",
        signature: "signed-assurance"
      })

    base = %{connection_id: "connection-1", expected_version: 1, assurance: assurance}

    if action == :reauthorize do
      Map.merge(base, %{
        requested_execution_identity_class: "connected_user",
        requested_permissions_digest: "reauthorize-digest",
        redirect_uri_id: "callback",
        correlation_id: "reauthorize-correlation-1",
        callback_artifact: issue_cap!(ctx.owner, ctx.owner, ProviderConnection, :consume_callback)
      })
    else
      base
    end
  end

  defp args(:refresh, _ctx),
    do: %{connection_id: "connection-1", expected_version: 1, correlation_id: "correlation-1"}

  defp args(:read_connection, _ctx), do: %{connection_id: "connection-1"}

  defp wrong_action(:read_connection), do: :refresh
  defp wrong_action(_action), do: :read_connection

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
