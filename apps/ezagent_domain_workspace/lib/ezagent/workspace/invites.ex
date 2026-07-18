defmodule Ezagent.Workspace.Invites do
  @moduledoc """
  CapBAC-checked facade for workspace registration invites.

  Browser and CLI surfaces use this module so mint, list, and revoke all pass
  through the Workspace Kind's `WorkspaceUserAdmin` Behavior and the shared
  dispatch/audit pipeline.
  """

  alias Ezagent.{Cmd, Router}

  @type context :: %{required(:caller) => URI.t(), required(:caps) => Enumerable.t()}

  @doc "Mint a registration invite through the workspace dispatch pipeline."
  @spec mint(URI.t(), map(), context()) :: {:ok, %{invite: map()}} | {:error, term()}
  def mint(%URI{scheme: "workspace"} = workspace_uri, args, ctx) when is_map(args) do
    dispatch(workspace_uri, :mint_invite, args, ctx)
  end

  @doc "List registration invites through the workspace dispatch pipeline."
  @spec list(URI.t(), context()) :: {:ok, %{invites: [map()]}} | {:error, term()}
  def list(%URI{scheme: "workspace"} = workspace_uri, ctx) do
    dispatch(workspace_uri, :list_invites, %{}, ctx)
  end

  @doc "Revoke a registration invite through the workspace dispatch pipeline."
  @spec revoke(URI.t(), String.t(), context()) :: {:ok, %{invite: map()}} | {:error, term()}
  def revoke(%URI{scheme: "workspace"} = workspace_uri, code, ctx)
      when is_binary(code) and code != "" do
    dispatch(workspace_uri, :revoke_invite, %{code: code}, ctx)
  end

  defp dispatch(workspace_uri, action, args, ctx) do
    target = Ezagent.URI.with_action(workspace_uri, :workspace_user_admin, action)

    Router.dispatch(%Cmd{
      target: target,
      action: action,
      args: args,
      origin: :authenticated_external,
      ctx: %{
        mode: :call,
        caller: Map.fetch!(ctx, :caller),
        caps: Map.fetch!(ctx, :caps),
        reply: {:caller_inbox, self()}
      }
    })
  end
end
