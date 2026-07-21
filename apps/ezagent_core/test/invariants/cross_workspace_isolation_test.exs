defmodule EzagentCore.Invariants.CrossWorkspaceIsolationTest do
  @moduledoc """
  A valid target signature is necessary but does not erase workspace isolation.
  Cross-workspace dispatch additionally requires a target-signed artifact whose
  workspace axis is `:any`.
  """

  use EzagentCore.DataCase, async: false

  @moduletag :umbrella_only

  alias Ezagent.{Cap, Capability, Invocation, Message, SpawnRegistry, WorkspaceRegistry}
  alias Ezagent.Entity.User

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(User.admin_uri()) => MapSet.new([:test_holder_license])
    })

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    :ok
  end

  test "intra-workspace target-signed dispatch clears both verifier and isolation gates" do
    context = setup_scenario()
    target = send_target(context.beta_session)
    cap = signed_action_cap!(target, context.beta_user)

    result = dispatch(target, context.beta_user, [cap])
    refute authz_error?(result)
  end

  test "cross-workspace target-signed dispatch without :any scope is denied by isolation" do
    context = setup_scenario()
    target = send_target(context.alpha_session)
    target_cap = signed_action_cap!(target, context.beta_user)

    assert {:error, :cross_workspace_denied} = dispatch(target, context.beta_user, [target_cap])
  end

  test "target-signed :any workspace artifact admits cross-workspace dispatch" do
    context = setup_scenario()
    target = send_target(context.alpha_session)
    target_cap = signed_action_cap!(target, context.beta_user)
    cross_cap = signed_cross_workspace_cap!(target, context.beta_user)

    result = dispatch(target, context.beta_user, [target_cap, cross_cap])
    refute authz_error?(result)
  end

  test "removing the :any artifact restores cross-workspace denial" do
    context = setup_scenario()
    target = send_target(context.alpha_session)
    target_cap = signed_action_cap!(target, context.beta_user)
    cross_cap = signed_cross_workspace_cap!(target, context.beta_user)

    refute authz_error?(dispatch(target, context.beta_user, [target_cap, cross_cap]))
    assert {:error, :cross_workspace_denied} = dispatch(target, context.beta_user, [target_cap])
  end

  test "missing-cap and cross-workspace denial remain distinct" do
    context = setup_scenario()
    target = send_target(context.alpha_session)

    assert {:error, :missing_cap} = dispatch(target, context.beta_user, [])
  end

  defp signed_cross_workspace_cap!(target, grantee) do
    requested = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: Ezagent.URI.instance(target),
      workspace_uri: :any,
      granted_by: User.admin_uri(),
      granted_at: DateTime.utc_now()
    }

    assert {:ok, issued} = Cap.issue({:admin, User.admin_uri()}, grantee, requested)
    issued
  end

  defp dispatch(target, caller, caps) do
    by_holder =
      Application.get_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{})

    Application.put_env(
      :ezagent_core,
      EzagentCore.Test.CapAuthorityLoaderStub,
      Map.put(by_holder, Ezagent.URI.stable_key(caller), MapSet.new([:test_holder_license]))
    )

    message = Message.new(caller, %{text: "workspace-proof", attachments: []})

    Invocation.dispatch(%Invocation{
      origin: :authenticated_external,
      target: target,
      mode: :call,
      args: %{message: message},
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: MapSet.new(caps),
        reply: :ignore
      }
    })
  end

  defp setup_scenario do
    suffix = System.unique_integer([:positive])
    beta = "tenant-beta-#{suffix}"
    alpha = "team-alpha-#{suffix}"

    assert {:ok, _} = Ezagent.Workspace.spawn_workspace(beta)
    assert {:ok, _} = Ezagent.Workspace.spawn_workspace(alpha)

    beta_session = Ezagent.URI.new!("session://#{beta}/default/main")
    alpha_session = Ezagent.URI.new!("session://#{alpha}/default/main")
    assert {:ok, _} = SpawnRegistry.spawn(beta_session)
    assert {:ok, _} = SpawnRegistry.spawn(alpha_session)
    :ok = WorkspaceRegistry.bind(beta_session, Ezagent.URI.workspace(beta))
    :ok = WorkspaceRegistry.bind(alpha_session, Ezagent.URI.workspace(alpha))

    beta_user = Ezagent.URI.new!("entity://#{beta}/user/caller")
    assert {:ok, _} = SpawnRegistry.spawn(beta_user)

    %{beta_session: beta_session, alpha_session: alpha_session, beta_user: beta_user}
  end

  defp send_target(session), do: Ezagent.URI.with_action(session, :session, :send)

  defp authz_error?({:error, reason})
       when reason in [:missing_cap, :invalid_cap_signature, :cross_workspace_denied],
       do: true

  defp authz_error?(_), do: false
end
