defmodule Ezagent.Workspace.TaskWorkspace.Paths do
  @moduledoc "Tenant-authorized deterministic paths for task workspace Git state."

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.Resource.FsResolver

  @resource_type "git-task-workspaces"
  @backend_component "git-task-workspaces"

  @type derived :: %{
          cache_identity: String.t(),
          cache_path: String.t(),
          worktree_identity: String.t(),
          worktree_path: String.t()
        }

  @doc "Returns the FsResolver declaration registered by Workspace Domain at boot."
  @spec resource_type() :: {String.t(), FsResolver.type_spec()}
  def resource_type do
    {@resource_type,
     %{backend_component: @backend_component, authority: &__MODULE__.workspace_authority/2}}
  end

  @doc "Authorizes resolution only when URI and authenticated scope name the same workspace."
  @spec workspace_authority(URI.t(), FsResolver.scope()) :: :ok | {:error, term()}
  def workspace_authority(%URI{} = uri, %{workspace: scope_workspace}) do
    with {:ok, uri_workspace} <- Ezagent.URI.workspace_name(uri),
         {:ok, scope_name} <- workspace_name(scope_workspace),
         true <- uri_workspace == scope_name do
      :ok
    else
      false -> {:error, :foreign_workspace}
      _ -> {:error, :invalid_workspace_authority}
    end
  end

  @doc "Derives cache and worktree locations through the tenant-scoped FsResolver."
  @spec derive(map()) :: {:ok, derived()} | {:error, term()}
  def derive(attrs) when is_map(attrs) do
    with {:ok, workspace_name} <- exact_workspace(Map.get(attrs, :workspace_uri)),
         {:ok, repository_uri} <-
           exact_repository(Map.get(attrs, :repository_uri), workspace_name),
         :ok <- safe_provision_id(Map.get(attrs, :provision_id)),
         :ok <- positive_generation(Map.get(attrs, :generation)),
         :ok <- valid_ref(Map.get(attrs, :base_ref), :base_ref),
         :ok <- valid_ref(Map.get(attrs, :allowed_head_ref), :allowed_head_ref),
         cache_identity <- cache_identity(repository_uri, attrs.base_ref),
         worktree_identity <- worktree_identity(attrs.provision_id, attrs.generation),
         {:ok, cache_path} <- resolve(workspace_name, cache_identity),
         {:ok, worktree_path} <- resolve(workspace_name, worktree_identity) do
      {:ok,
       %{
         cache_identity: cache_identity,
         cache_path: cache_path,
         worktree_identity: worktree_identity,
         worktree_path: worktree_path
       }}
    end
  end

  def derive(_attrs), do: {:error, :invalid_path_coordinates}

  defp exact_workspace(%URI{scheme: "workspace"} = uri) do
    with {:ok, name} <- Ezagent.URI.workspace_name(uri),
         true <- uri == Ezagent.URI.workspace(name) do
      {:ok, name}
    else
      _ -> {:error, :invalid_workspace_uri}
    end
  end

  defp exact_workspace(_uri), do: {:error, :invalid_workspace_uri}

  defp exact_repository(%URI{scheme: "resource"} = uri, workspace_name) do
    with {:ok, uri_workspace} <- Ezagent.URI.workspace_name(uri),
         :ok <- same_workspace(uri_workspace, workspace_name),
         {:ok, "git-repository"} <- Ezagent.URI.type(uri),
         {:ok, name} <- Ezagent.URI.name(uri),
         true <- uri == Ezagent.URI.resource(workspace_name, "git-repository", name) do
      {:ok, uri}
    else
      {:error, :repository_workspace_mismatch} = error -> error
      _ -> {:error, :invalid_repository_uri}
    end
  end

  defp exact_repository(_uri, _workspace_name), do: {:error, :invalid_repository_uri}

  defp same_workspace(workspace_name, workspace_name), do: :ok

  defp same_workspace(_uri_workspace, _scope_workspace),
    do: {:error, :repository_workspace_mismatch}

  defp safe_provision_id(value) do
    if FsResolver.safe_component?(value),
      do: :ok,
      else: {:error, {:unsafe_segment, value}}
  end

  defp positive_generation(value) when is_integer(value) and value > 0, do: :ok
  defp positive_generation(_value), do: {:error, :invalid_generation}

  defp valid_ref(value, field) do
    if RepositoryRef.valid_ref?(value), do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp cache_identity(repository_uri, base_ref),
    do: "cache-" <> digest([URI.to_string(repository_uri), <<0>>, base_ref])

  defp worktree_identity(provision_id, generation),
    do: "worktree-" <> digest([provision_id, <<0>>, Integer.to_string(generation)])

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp resolve(workspace_name, identity) do
    workspace_name
    |> Ezagent.URI.resource(@resource_type, identity)
    |> FsResolver.resolve(%{workspace: workspace_name})
    |> case do
      {:ok, path} -> {:ok, path}
      :none -> {:error, :task_workspace_resource_type_not_registered}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace_name(%URI{scheme: "workspace"} = uri), do: Ezagent.URI.workspace_name(uri)
  defp workspace_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp workspace_name(_workspace), do: {:error, :invalid_scope_workspace}
end
