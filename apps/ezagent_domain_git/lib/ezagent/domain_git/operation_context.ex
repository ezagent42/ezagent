defmodule Ezagent.DomainGit.OperationContext do
  @moduledoc "Authorized identity coordinates built inside Git dispatch."

  alias Ezagent.DomainGit.{RepositoryRef, ValidationError}
  alias Ezagent.Entity.GitTaskAccess
  @fields [:task_access_uri, :caller_uri, :grantee_uri, :idempotency_key]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          task_access_uri: URI.t(),
          caller_uri: URI.t(),
          grantee_uri: URI.t(),
          idempotency_key: String.t()
        }

  @doc "Builds an operation context whose task, caller, and grantee share a workspace."
  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp validate_values(attrs) do
    roles = [
      task_access_uri: &GitTaskAccess.task_access_uri?/1,
      caller_uri: &RepositoryRef.ezagent_uri?(&1, "entity", nil),
      grantee_uri: &RepositoryRef.ezagent_uri?(&1, "entity", nil)
    ]

    invalid =
      Enum.find(roles, fn {field, valid?} ->
        not valid?.(attrs[field])
      end)

    case invalid do
      {field, _role} ->
        {:error, {:invalid_field, field}}

      nil ->
        validate_workspace_and_key(attrs)
    end
  end

  defp validate_workspace_and_key(attrs) do
    task_workspace = workspace(attrs.task_access_uri)

    cond do
      workspace(attrs.caller_uri) != task_workspace ->
        {:error, {:invalid_field, :caller_uri}}

      workspace(attrs.grantee_uri) != task_workspace ->
        {:error, {:invalid_field, :grantee_uri}}

      not ValidationError.nonempty_string?(attrs.idempotency_key) ->
        {:error, {:invalid_field, :idempotency_key}}

      true ->
        :ok
    end
  end

  defp workspace(uri) do
    case Ezagent.URI.workspace_name(uri) do
      {:ok, workspace} -> workspace
      :error -> nil
    end
  end
end
