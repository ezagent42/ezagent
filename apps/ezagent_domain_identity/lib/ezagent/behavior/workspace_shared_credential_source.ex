defmodule Ezagent.ActionSet.WorkspaceSharedCredentialSource do
  @moduledoc """
  Cap-checked workspace-admin chokepoint for workspace-shared credential sources.

  The durable pointer lives in `Ezagent.Credential.WorkspaceSharedSource`, but this
  Behavior is the production writer: dispatch supplies the workspace cap-check and
  audit effects, while the handler validates the pointed source before upserting.
  """

  use Ezagent.Lifecycle

  alias Ezagent.Credential.WorkspaceSharedSource
  alias EzagentCore.Repo

  action(:set_workspace_shared_credential_source,
    args: %{
      flavor: :string,
      source_uri: :string,
      workspace_uri: {:option, :string}
    },
    returns: %{
      flavor: :string,
      source_uri: :string
    },
    caps: [{:set_workspace_shared_credential_source, kind: :workspace}],
    modes: [:call],
    description:
      "Set a workspace-shared service-account credential source for a flavor. " <>
        "Validates source existence, workspace, and flavor before persistence."
  )

  def required_caps do
    %{
      set_workspace_shared_credential_source:
        Ezagent.Capability.cap(
          :workspace,
          __MODULE__,
          :set_workspace_shared_credential_source
        )
    }
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{set_count: 0}}

  def data_owner(_), do: :any

  def handle_set_workspace_shared_credential_source(args, ctx) when is_map(args) do
    flavor = Map.get(args, :flavor)
    source_uri = Map.get(args, :source_uri)
    workspace = self_uri_str(ctx)
    set_by = caller_str(ctx) || workspace

    with :ok <- check_workspace_arg(Map.get(args, :workspace_uri), workspace),
         true <- is_binary(flavor) and is_binary(source_uri) and is_binary(workspace),
         {:ok, _row} <- persist_validated(workspace, flavor, source_uri, set_by) do
      cur = ctx[:read].(:set_count, 0)

      {:ok, %{flavor: flavor, source_uri: source_uri},
       [
         {:set, :set_count, cur + 1},
         {:emit, :workspace_shared_credential_source_set,
          %{
            workspace_uri: workspace,
            flavor: flavor,
            source_uri: source_uri,
            set_by: set_by,
            at: DateTime.utc_now()
          }}
       ]}
    else
      false ->
        {:error,
         {:bad_args, "set_workspace_shared_credential_source requires {flavor, source_uri}"}}

      {:error, _} = err ->
        err
    end
  end

  def handle_set_workspace_shared_credential_source(args, _ctx) do
    {:error, {:bad_args, "set_workspace_shared_credential_source requires a map", args}}
  end

  defp persist_validated(workspace, flavor, source_uri, set_by) do
    with {:ok, source} <- Ezagent.URI.parse(source_uri),
         :ok <- validate_source(source, workspace, flavor) do
      %{workspace_uri: workspace, flavor: flavor, source_uri: source_uri, set_by: set_by}
      |> WorkspaceSharedSource.changeset()
      |> Repo.insert(
        on_conflict: {:replace, [:source_uri, :set_by, :updated_at]},
        conflict_target: :id
      )
    end
  end

  defp validate_source(%URI{} = source, workspace, flavor) do
    with :ok <- validate_source_exists(source),
         :ok <- validate_source_workspace(source, workspace),
         :ok <- validate_source_flavor(source, flavor) do
      :ok
    end
  end

  defp validate_source_exists(%URI{} = source) do
    if match?({:ok, _}, Ezagent.SnapshotStore.latest(source)) do
      :ok
    else
      {:error, :source_not_found}
    end
  end

  defp validate_source_workspace(%URI{} = source, workspace) do
    case Ezagent.URI.workspace_of(source) do
      %URI{} = source_workspace ->
        if URI.to_string(source_workspace) == workspace do
          :ok
        else
          {:error, :source_workspace_mismatch}
        end

      _ ->
        {:error, :source_workspace_mismatch}
    end
  end

  defp validate_source_flavor(%URI{} = source, flavor) do
    case Ezagent.UriQuery.resolve(:flavor, source) do
      {:ok, ^flavor} -> :ok
      {:ok, _other} -> {:error, :source_flavor_mismatch}
      :none -> {:error, :source_flavor_mismatch}
      {:error, _} -> {:error, :source_flavor_mismatch}
    end
  end

  defp check_workspace_arg(nil, _self_uri), do: :ok
  defp check_workspace_arg(self_uri, self_uri), do: :ok
  defp check_workspace_arg(other, _self_uri), do: {:error, {:workspace_uri_mismatch, other}}

  defp self_uri_str(ctx) do
    case Map.get(ctx, :self_uri) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> nil
    end
  end

  defp caller_str(ctx) do
    case Map.get(ctx, :caller) do
      %URI{} = u -> URI.to_string(u)
      s when is_binary(s) -> s
      _ -> nil
    end
  end
end
