defmodule Ezagent.DomainGit.OperationContext do
  @moduledoc """
  Authorized identity coordinates built inside Git dispatch.

  `grantee_uri` and `credential_owner_uri` are DISTINCT roles, both carried
  from the `Ezagent.Entity.GitTaskAccess` policy: the grantee is who may
  invoke the operation, the credential owner is whose stored provider
  credential it runs under.

  The second one exists because providers differ in where a credential comes
  from. An adapter whose provider can mint a fresh credential per operation
  never needs to look one up. An adapter whose provider issued the credential
  once, at authorization time, must resolve WHICH stored connection to use —
  and cannot, without knowing whose it is. Only the second kind reads this
  field; the first ignores it.

  Required with no default, for the same reason
  `Ezagent.DomainGit.CreateChangeRequest.commit_date` is: absent, it would
  resurface much later as an unresolvable credential instead of as a refused
  construction here.
  """

  alias Ezagent.DomainGit.{RepositoryRef, ValidationError}
  alias Ezagent.Entity.GitTaskAccess
  @fields [:task_access_uri, :caller_uri, :grantee_uri, :credential_owner_uri, :idempotency_key]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          task_access_uri: URI.t(),
          caller_uri: URI.t(),
          grantee_uri: URI.t(),
          credential_owner_uri: URI.t(),
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
      grantee_uri: &RepositoryRef.ezagent_uri?(&1, "entity", nil),
      credential_owner_uri: &RepositoryRef.ezagent_uri?(&1, "entity", nil)
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

      # The credential owner is held to the same workspace as the task. A
      # credential belonging to another tenant would otherwise be accepted
      # here and only be caught -- if at all -- by whatever the provider
      # adapter happens to check.
      workspace(attrs.credential_owner_uri) != task_workspace ->
        {:error, {:invalid_field, :credential_owner_uri}}

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
