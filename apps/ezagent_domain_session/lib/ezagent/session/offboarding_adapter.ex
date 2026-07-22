defmodule Ezagent.Session.OffboardingAdapter do
  @moduledoc false

  @behaviour Ezagent.Identity.Offboarding.StructuralTransfer.Adapter

  alias Ezagent.ActionSet.Session.{ConfigActions, MemberCap, Membership}
  alias Ezagent.Identity.Offboarding.{RevocationFence, StructuralTransfer}
  alias Ezagent.Workspace.Store

  @impl true
  def supports?(%URI{scheme: scheme}) when scheme in ["session", "template"], do: true
  def supports?(_uri), do: false

  @impl true
  def transfer(%URI{scheme: "session"} = session_uri, %URI{} = deleted_user) do
    new_owner = transfer_target(session_uri, deleted_user)

    with {:ok, _pid} <- Ezagent.LocalRuntime.ensure_started(session_uri),
         {:ok, current_owner} <- Ezagent.Entity.Session.owner(session_uri),
         :ok <- maybe_transfer_session(session_uri, current_owner, deleted_user, new_owner) do
      :ok
    end
  end

  def transfer(%URI{scheme: "template"} = template_uri, %URI{} = deleted_user) do
    new_owner = transfer_target(template_uri, deleted_user)

    with {:ok, _pid} <- Ezagent.LocalRuntime.ensure_started(template_uri),
         {:ok, slice} when is_map(slice) <- Ezagent.Kind.get_slice(template_uri, :template),
         content when is_map(content) <-
           slice |> Ezagent.Kind.normalize_slice_view() |> Map.get(:content),
         current_owner <- Map.get(content, :created_by),
         :ok <- maybe_transfer_template(template_uri, current_owner, deleted_user, new_owner) do
      :ok
    else
      nil -> {:error, :template_not_populated}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_template_owner_read, other}}
    end
  end

  defp maybe_transfer_session(session_uri, current_owner, deleted_user, new_owner) do
    cond do
      same_principal?(current_owner, deleted_user) ->
        with {:ok, _result} <- ConfigActions.system_transfer_owner(session_uri, new_owner),
             :ok <- grant_session_owner_caps(session_uri, new_owner),
             :ok <- StructuralTransfer.record_transfer(session_uri, new_owner) do
          :ok
        end

      same_principal?(current_owner, new_owner) ->
        with :ok <- grant_session_owner_caps(session_uri, new_owner),
             :ok <- StructuralTransfer.record_transfer(session_uri, new_owner) do
          :ok
        end

      true ->
        :ok
    end
  end

  defp grant_session_owner_caps(session_uri, new_owner) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    with :ok <- MemberCap.grant_for_reownership(session_uri, new_owner),
         :ok <- Membership.mount_participation_caps(session_uri, new_owner),
         :ok <-
           EzagentDomainInstanceMessage.SessionCreator.Materializer.grant_owner_remove_participant_cap(
             session_uri,
             new_owner,
             workspace_uri
           ),
         :ok <-
           EzagentDomainInstanceMessage.SessionCreator.Materializer.grant_owner_assign_role_cap(
             session_uri,
             new_owner,
             workspace_uri
           ) do
      :ok
    end
  end

  defp maybe_transfer_template(template_uri, current_owner, deleted_user, new_owner) do
    cond do
      same_principal?(current_owner, deleted_user) ->
        with :ok <-
               Ezagent.ActionSet.Template.transfer_created_by_as_admin(template_uri, new_owner),
             :ok <- grant_template_owner_caps(template_uri, new_owner),
             :ok <- StructuralTransfer.record_transfer(template_uri, new_owner) do
          :ok
        end

      same_principal?(current_owner, new_owner) ->
        with :ok <- grant_template_owner_caps(template_uri, new_owner),
             :ok <- StructuralTransfer.record_transfer(template_uri, new_owner) do
          :ok
        end

      true ->
        :ok
    end
  end

  defp grant_template_owner_caps(template_uri, new_owner) do
    case Ezagent.URI.type(template_uri) do
      {:ok, "session"} ->
        Ezagent.ActionSet.Template.grant_template_owner_caps(
          new_owner,
          template_uri,
          Ezagent.Entity.SessionTemplate
        )

      {:ok, "agent"} ->
        Ezagent.ActionSet.Template.grant_template_owner_caps(
          new_owner,
          template_uri,
          Ezagent.Entity.AgentTemplate
        )

      _ ->
        {:error, {:unsupported_template_type, template_uri}}
    end
  end

  defp transfer_target(resource_uri, deleted_user) do
    workspace_owner =
      resource_uri
      |> Ezagent.URI.workspace_name!()
      |> Store.get_by_name()
      |> case do
        %{created_by: %URI{} = owner} -> owner
        _ -> admin()
      end

    if same_principal?(workspace_owner, deleted_user) or RevocationFence.fenced?(workspace_owner),
      do: admin(),
      else: workspace_owner
  end

  defp same_principal?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)

  defp same_principal?(_, _), do: false

  defp admin, do: Ezagent.Entity.User.admin_uri()
end
