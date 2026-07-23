defmodule Ezagent.Workspace.OffboardingAdapter do
  @moduledoc false

  @behaviour Ezagent.Identity.Offboarding.StructuralTransfer.Adapter

  alias Ezagent.Identity.Offboarding.StructuralTransfer
  alias Ezagent.Workspace.Store

  @impl true
  def supports?(%URI{scheme: "workspace"}), do: true
  def supports?(_uri), do: false

  @impl true
  def transfer(%URI{scheme: "workspace"} = workspace_uri, %URI{} = deleted_user) do
    name = Ezagent.URI.name!(workspace_uri)

    case Store.get_by_name(name) do
      nil ->
        :ok

      %{created_by: current_owner} ->
        admin = Ezagent.Entity.User.admin_uri()

        cond do
          same_principal?(current_owner, deleted_user) ->
            with {:ok, _updated} <- Store.transfer_owner(name, admin),
                 :ok <- StructuralTransfer.record_transfer(workspace_uri, admin) do
              :ok
            end

          same_principal?(current_owner, admin) ->
            StructuralTransfer.record_transfer(workspace_uri, admin)

          true ->
            :ok
        end
    end
  end

  defp same_principal?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)

  defp same_principal?(_, _), do: false
end
