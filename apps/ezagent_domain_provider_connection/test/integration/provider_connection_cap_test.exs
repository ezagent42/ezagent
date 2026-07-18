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
      {:error, :provider_connection_orchestration_not_implemented}
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

      assert {:error, :provider_connection_orchestration_not_implemented} =
               dispatch(
                 ctx.owner,
                 ctx.caller,
                 action,
                 args(action, ctx),
                 MapSet.new([valid])
               )

      if action in [:reauthorize, :revoke, :disconnect],
        do: assert_received({:assurance, ^action})

      assert_received {:boundary, ^action, _}
      refute_received {:boundary, _, _}
    end

    assert {:ok, slice} = Ezagent.Kind.get_slice(ctx.owner, ProviderConnection.state_slice())
    assert slice in [nil, %{state: %{}, transients: %{}}]
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
    callback = issue_cap!(ctx.owner, ctx.caller, ProviderConnection, :consume_callback)

    %{
      connection_id: "connection-1",
      provider_id: "github",
      governed_host: "github.com",
      acquisition_method: "oauth",
      execution_identity: "owner",
      requested_permissions_digest: "digest",
      redirect_uri_id: "callback",
      correlation_id: "correlation-1",
      callback_artifact: callback
    }
  end

  defp args(:consume_callback, _ctx),
    do: %{attempt_ref: "attempt-1", callback: %{}, correlation_id: "correlation-1"}

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

    %{connection_id: "connection-1", expected_version: 1, assurance: assurance}
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
