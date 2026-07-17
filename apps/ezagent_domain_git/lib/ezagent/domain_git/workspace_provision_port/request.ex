defmodule Ezagent.DomainGit.WorkspaceProvisionPort.Request do
  @moduledoc """
  Closed request accepted by the workspace provision port.

  The shape deliberately excludes repository URLs, provider selection, and
  filesystem paths. Those coordinates are resolved by the owning domains.
  """

  @enforce_keys [:task_access_uri, :task_uri, :generation, :operation, :provision_id]
  defstruct @enforce_keys

  @fields @enforce_keys

  @type t :: %__MODULE__{
          task_access_uri: URI.t(),
          task_uri: URI.t(),
          generation: non_neg_integer(),
          operation: Ezagent.DomainGit.WorkspaceProvisionPort.operation(),
          provision_id: String.t()
        }

  @doc "Builds a request only when every key belongs to the closed contract."
  @spec new(map()) :: {:ok, t()} | {:error, :invalid_attributes | :unknown_fields | term()}
  def new(attrs) when is_map(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :invalid_attributes}

      Enum.any?(keys, &(&1 not in @fields)) ->
        {:error, :unknown_fields}

      missing = Enum.find(@fields, &(not Map.has_key?(attrs, &1))) ->
        {:error, {:missing_field, missing}}

      true ->
        {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}
end
