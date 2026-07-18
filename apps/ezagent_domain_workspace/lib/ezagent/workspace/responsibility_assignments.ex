defmodule Ezagent.Workspace.ResponsibilityAssignments do
  @moduledoc """
  Facade operations for P9 workspace responsibility assignments.

  Kept outside `Ezagent.Workspace` so the workspace facade stays below the
  architecture width gate while still exposing defdelegated public API.
  """

  alias Ezagent.{Cmd, KindRegistry, Router, Workspace.Store}
  alias Ezagent.Workspace.ResponsibilityAssignment

  @doc "Cap-gated assignment entry used by `Ezagent.Workspace.assign_role/5`."
  @spec assign_role(URI.t(), String.t(), URI.t(), map(), map()) ::
          {:ok, ResponsibilityAssignment.decoded()} | {:error, term()}
  def assign_role(
        %URI{scheme: "workspace"} = workspace_uri,
        responsibility,
        %URI{} = holder,
        config,
        ctx
      )
      when is_binary(responsibility) and is_map(config) and is_map(ctx) do
    with :ok <- ensure_workspace_live(workspace_uri),
         {:ok, dispatch_ctx} <- caller_ctx(ctx),
         :ok <-
           dispatch_mutation(
             workspace_uri,
             :assign_role,
             %{
               responsibility: responsibility,
               holder: holder
             },
             dispatch_ctx
           ),
         {:ok, assignment} <-
           ResponsibilityAssignment.assign(
             workspace_uri,
             responsibility,
             holder,
             Map.get(dispatch_ctx, :caller),
             config
           ),
         :ok <- grant_responsibility_caps(holder, responsibility, workspace_uri, dispatch_ctx) do
      {:ok, assignment}
    end
  end

  @doc "Cap-gated unassignment entry used by `Ezagent.Workspace.unassign_role/4`."
  @spec unassign_role(URI.t(), String.t(), URI.t(), map()) :: :ok | {:error, term()}
  def unassign_role(
        %URI{scheme: "workspace"} = workspace_uri,
        responsibility,
        %URI{} = holder,
        ctx
      )
      when is_binary(responsibility) and is_map(ctx) do
    with :ok <- ensure_workspace_live(workspace_uri),
         {:ok, dispatch_ctx} <- caller_ctx(ctx),
         :ok <-
           dispatch_mutation(
             workspace_uri,
             :unassign_role,
             %{
               responsibility: responsibility,
               holder: holder
             },
             dispatch_ctx
           ),
         :ok <- ResponsibilityAssignment.unassign(workspace_uri, responsibility, holder),
         :ok <- revoke_responsibility_caps(holder, responsibility, workspace_uri, dispatch_ctx) do
      :ok
    end
  end

  defp dispatch_mutation(%URI{} = workspace_uri, action, args, auth_ctx) when is_atom(action) do
    target = Ezagent.URI.with_action(workspace_uri, :workspace, action)

    case Router.dispatch(%Cmd{
           target: target,
           action: action,
           args: args,
           ctx: Map.merge(auth_ctx, %{mode: :call, reply: {:caller_inbox, self()}}),
           origin: :trusted_internal
         }) do
      :ok -> :ok
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp caller_ctx(%{caller: %URI{} = caller, caps: caps}) when is_list(caps),
    do: {:ok, %{caller: caller, caps: caps}}

  defp caller_ctx(%{caller: %URI{} = caller, caps: %MapSet{} = caps}),
    do: {:ok, %{caller: caller, caps: caps}}

  defp caller_ctx(_other), do: {:error, :invalid_caller_ctx}

  defp ensure_workspace_live(%URI{scheme: "workspace"} = workspace_uri) do
    name = Ezagent.URI.name!(workspace_uri)

    case KindRegistry.lookup(workspace_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Store.get_by_name(name) do
          nil ->
            {:error, :workspace_not_found}

          %{members: members, session_templates: templates, routing_rules: rules} ->
            case Ezagent.Workspace.spawn_workspace(name, %{
                   members: members,
                   session_templates: templates,
                   routing_rules: rules
                 }) do
              {:ok, _pid} -> :ok
              {:error, {:already_started, _pid}} -> :ok
              {:error, reason} -> {:error, {:workspace_spawn_failed, reason}}
            end
        end
    end
  end

  defp grant_responsibility_caps(%URI{} = holder, responsibility, %URI{} = workspace_uri, ctx) do
    _authorized_assigner = Map.fetch!(ctx, :caller)
    admin = Ezagent.URI.user(:system, :admin)

    responsibility_caps(responsibility, workspace_uri)
    |> Enum.reduce_while(:ok, fn cap, :ok ->
      case Ezagent.Identity.Grant.grant_cap(holder, cap, {:admin, admin}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:grant_responsibility_cap_failed, cap, reason}}}
      end
    end)
  end

  defp revoke_responsibility_caps(%URI{} = holder, responsibility, %URI{} = workspace_uri, ctx) do
    responsibility_caps(responsibility, workspace_uri)
    |> Enum.reduce_while(:ok, fn cap, :ok ->
      case Ezagent.Identity.Grant.revoke_cap(holder, cap, {:held_by, Map.fetch!(ctx, :caller)}) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:revoke_responsibility_cap_failed, cap, reason}}}
      end
    end)
  end

  defp responsibility_caps("supervisor", %URI{} = workspace_uri) do
    session_facade =
      Application.get_env(
        :ezagent_domain_workspace,
        :session_facade,
        EzagentDomainInstanceMessage.SessionCreator
      )

    if Code.ensure_loaded?(session_facade) and
         function_exported?(session_facade, :list_sessions, 1) do
      session_facade.list_sessions(workspace_uri)
      |> Enum.flat_map(&ResponsibilityAssignment.supervisor_caps_for_session(&1, workspace_uri))
    else
      []
    end
  end

  defp responsibility_caps(_responsibility, _workspace_uri), do: []
end
