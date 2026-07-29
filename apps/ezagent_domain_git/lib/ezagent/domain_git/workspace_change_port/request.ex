defmodule Ezagent.DomainGit.WorkspaceChangePort.Request do
  @moduledoc """
  Closed request accepted by the workspace-change collection port.

  Mirrors `Ezagent.DomainGit.WorkspaceProvisionPort.Request`'s closed-field
  discipline but carries no `task_policy` — collection proves worktree
  ownership by fresh-reading the exact `(task_access_uri, task_uri,
  generation)` identity off the already-ready `provision_id` row (design
  §4.2), not by re-presenting a CapBAC policy. The shape deliberately
  excludes repository URLs, provider selection, and filesystem paths —
  those coordinates are resolved by the workspace-owning domain from the
  persisted provision row.
  """

  @enforce_keys [:task_access_uri, :task_uri, :generation, :provision_id]
  defstruct @enforce_keys

  @fields @enforce_keys

  @type t :: %__MODULE__{
          task_access_uri: URI.t(),
          task_uri: URI.t(),
          generation: pos_integer(),
          provision_id: String.t()
        }

  @doc "Builds a request only when every key belongs to the closed contract and is well-typed."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    keys = Map.keys(attrs)

    cond do
      Enum.any?(keys, &(not is_atom(&1))) ->
        {:error, :invalid_attributes}

      Enum.any?(keys, &(&1 not in @fields)) ->
        {:error, :unknown_fields}

      missing = Enum.find(@fields, &(not Map.has_key?(attrs, &1))) ->
        {:error, {:missing_field, missing}}

      not match?(%URI{}, attrs.task_access_uri) ->
        {:error, {:invalid_field, :task_access_uri}}

      not match?(%URI{}, attrs.task_uri) ->
        {:error, {:invalid_field, :task_uri}}

      not (is_integer(attrs.generation) and attrs.generation > 0) ->
        {:error, {:invalid_field, :generation}}

      not (is_binary(attrs.provision_id) and attrs.provision_id != "") ->
        {:error, {:invalid_field, :provision_id}}

      true ->
        {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}
end
