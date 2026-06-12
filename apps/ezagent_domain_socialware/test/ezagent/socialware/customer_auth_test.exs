defmodule Ezagent.Socialware.CustomerAuthTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.SocialwareSession
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}

  defp session_uri(name) do
    Ezagent.URI.session(:team_alpha, :socialware, name)
  end

  setup do
    session_a = session_uri("auth-a-#{System.unique_integer([:positive])}")
    session_b = session_uri("auth-b-#{System.unique_integer([:positive])}")
    workspace = Ezagent.Capability.workspace_of(session_a)

    for session <- [session_a, session_b] do
      {:ok, _pid} =
        Ezagent.Kind.spawn(SocialwareSession, %{
          uri: session,
          behaviors: Ezagent.Entity.SocialwareSession.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    end

    %{session_a: session_a, session_b: session_b, workspace: workspace}
  end

  test "a token scoped to session A / workspace A is denied B and when expired", ctx do
    token_for_a = CustomerAuth.issue_token(ctx.session_a, ctx.workspace)
    token_for_other_workspace = CustomerAuth.issue_token(ctx.session_a, "workspace://other")
    expired_token = CustomerAuth.issue_token(ctx.session_a, ctx.workspace, expires_in_ms: -1)

    assert {:error, :unauthorized} = CustomerFeed.snapshot(ctx.session_b, token_for_a)

    assert {:error, :unauthorized} =
             CustomerFeed.snapshot(ctx.session_a, token_for_other_workspace)

    assert {:error, :unauthorized} = CustomerFeed.snapshot(ctx.session_a, expired_token)
    assert {:ok, _snapshot} = CustomerFeed.snapshot(ctx.session_a, token_for_a)
  end
end
