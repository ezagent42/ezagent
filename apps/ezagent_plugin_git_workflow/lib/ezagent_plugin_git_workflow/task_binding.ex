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
    with :ok <- validate_known_fields(attrs),
         :ok <- validate_values(attrs),
         :ok <- validate_repository_ref(attrs) do
      struct = struct!(__MODULE__, Map.take(attrs, @fields))
      {:ok, struct}
    end
  end

  def new(_), do: {:error, :invalid_attributes}

  defp validate_known_fields(attrs) do
    extra = Map.keys(attrs) -- @fields

    if extra == [],
      do: :ok,
      else: {:error, {:unknown_fields, extra}}
  end

  defp validate_values(attrs) do
    checks = [
      {:id, is_binary(attrs.id) and byte_size(attrs.id) > 0},
      {:generation, is_integer(attrs.generation) and attrs.generation > 0},
      {:workspace_uri, is_struct(attrs.workspace_uri, URI)},
      {:task_receiver_uri, is_struct(attrs.task_receiver_uri, URI)},
      {:credential_owner_uri, is_struct(attrs.credential_owner_uri, URI)},
      {:repository_uri, is_struct(attrs.repository_uri, URI)},
      {:provider_adapter, is_atom(attrs.provider_adapter) and not is_nil(attrs.provider_adapter)},
      {:provider_host, is_binary(attrs.provider_host) and byte_size(attrs.provider_host) > 0},
      {:external_id, is_binary(attrs.external_id) and byte_size(attrs.external_id) > 0},
      {:owner_path, is_binary(attrs.owner_path) and byte_size(attrs.owner_path) > 0},
      {:base_ref, is_binary(attrs.base_ref) and byte_size(attrs.base_ref) > 0},
      {:visibility, attrs.visibility in [:public, :private]},
      {:allowed_head_namespace, is_binary(attrs.allowed_head_namespace)},
      {:enabled, is_boolean(attrs.enabled)}
    ]

    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end

  defp validate_repository_ref(attrs) do
    repo_attrs = %{
      repository_uri: attrs.repository_uri,
      provider_adapter: attrs.provider_adapter,
      provider_host: attrs.provider_host,
      external_id: attrs.external_id,
      owner_path: attrs.owner_path,
      base_ref: attrs.base_ref,
      visibility: attrs.visibility
    }

    case RepositoryRef.new(repo_attrs) do
      {:ok, _ref} -> :ok
      {:error, reason} -> {:error, {:invalid_repository_ref, reason}}
    end
  end
end
