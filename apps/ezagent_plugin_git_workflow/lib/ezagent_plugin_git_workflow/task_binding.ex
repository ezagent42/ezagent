defmodule EzagentPluginGitWorkflow.TaskBinding do
  @moduledoc """
  Governed binding between a workspace task receiver and a Git repository.

  Validates provider-neutral repository coordinates through
  `Ezagent.DomainGit.RepositoryRef.new/1`. No credential, token,
  installation id, OAuth value, or private key fields.
  """

  alias Ezagent.DomainGit.RepositoryRef

  @fields [
    :id,
    :generation,
    :workspace_uri,
    :task_receiver_uri,
    :credential_owner_uri,
    :repository_uri,
    :provider_adapter,
    :provider_host,
    :external_id,
    :owner_path,
    :base_ref,
    :visibility,
    :allowed_head_namespace,
    :enabled
  ]

  @enforce_keys @fields
  defstruct @fields ++ [:inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t(),
          generation: pos_integer(),
          workspace_uri: URI.t(),
          task_receiver_uri: URI.t(),
          credential_owner_uri: URI.t(),
          repository_uri: URI.t(),
          provider_adapter: atom(),
          provider_host: String.t(),
          external_id: String.t(),
          owner_path: String.t(),
          base_ref: String.t(),
          visibility: :public | :private,
          allowed_head_namespace: String.t(),
          enabled: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Builds a validated TaskBinding struct, including RepositoryRef validation."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs),
         :ok <- validate_known_fields(attrs),
         :ok <- validate_values(attrs),
         :ok <- validate_repository_ref(attrs) do
      struct = struct!(__MODULE__, Map.take(attrs, @fields))
      {:ok, struct}
    end
  end

  def new(_), do: {:error, :invalid_attributes}

  defp validate_required(attrs) do
    missing = Enum.filter(@fields, fn f -> not Map.has_key?(attrs, f) end)

    if missing == [],
      do: :ok,
      else: {:error, {:missing_field, hd(missing)}}
  end

  defp validate_known_fields(attrs) do
    extra = Map.keys(attrs) -- @fields

    if extra == [],
      do: :ok,
      else: {:error, {:unknown_fields, extra}}
  end

  defp validate_values(attrs) do
    id = Map.fetch!(attrs, :id)
    generation = Map.fetch!(attrs, :generation)
    workspace_uri = Map.fetch!(attrs, :workspace_uri)
    task_receiver_uri = Map.fetch!(attrs, :task_receiver_uri)
    credential_owner_uri = Map.fetch!(attrs, :credential_owner_uri)
    repository_uri = Map.fetch!(attrs, :repository_uri)
    provider_adapter = Map.fetch!(attrs, :provider_adapter)
    provider_host = Map.fetch!(attrs, :provider_host)
    external_id = Map.fetch!(attrs, :external_id)
    owner_path = Map.fetch!(attrs, :owner_path)
    base_ref = Map.fetch!(attrs, :base_ref)
    visibility = Map.fetch!(attrs, :visibility)
    allowed_head_namespace = Map.fetch!(attrs, :allowed_head_namespace)
    enabled = Map.fetch!(attrs, :enabled)

    checks = [
      {:id, is_binary(id) and byte_size(id) > 0},
      {:generation, is_integer(generation) and generation > 0},
      {:workspace_uri, is_struct(workspace_uri, URI) and Ezagent.URI.canonical?(workspace_uri)},
      {:task_receiver_uri,
       is_struct(task_receiver_uri, URI) and Ezagent.URI.canonical?(task_receiver_uri)},
      {:credential_owner_uri,
       is_struct(credential_owner_uri, URI) and Ezagent.URI.canonical?(credential_owner_uri)},
      {:repository_uri,
       is_struct(repository_uri, URI) and Ezagent.URI.canonical?(repository_uri)},
      {:provider_adapter, is_atom(provider_adapter) and not is_nil(provider_adapter)},
      {:provider_host, is_binary(provider_host) and byte_size(provider_host) > 0},
      {:external_id, is_binary(external_id) and byte_size(external_id) > 0},
      {:owner_path, is_binary(owner_path) and byte_size(owner_path) > 0},
      {:base_ref, is_binary(base_ref) and byte_size(base_ref) > 0},
      {:visibility, visibility in [:public, :private]},
      {:allowed_head_namespace, is_binary(allowed_head_namespace)},
      {:enabled, is_boolean(enabled)}
    ]

    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end

  defp validate_repository_ref(attrs) do
    repo_attrs = %{
      repository_uri: Map.fetch!(attrs, :repository_uri),
      provider_adapter: Map.fetch!(attrs, :provider_adapter),
      provider_host: Map.fetch!(attrs, :provider_host),
      external_id: Map.fetch!(attrs, :external_id),
      owner_path: Map.fetch!(attrs, :owner_path),
      base_ref: Map.fetch!(attrs, :base_ref),
      visibility: Map.fetch!(attrs, :visibility)
    }

    case RepositoryRef.new(repo_attrs) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, {:invalid_repository_ref, reason}}
    end
  end
end
