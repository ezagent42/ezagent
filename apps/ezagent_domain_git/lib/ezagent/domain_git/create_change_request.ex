defmodule Ezagent.DomainGit.CreateChangeRequest do
  @moduledoc "Provider-neutral request to create a change request."

  alias Ezagent.DomainGit.{CommitSha, RepositoryRef, ValidationError}
  @fields [:title, :body, :head_ref, :expected_base_sha]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          title: String.t(),
          body: String.t(),
          head_ref: String.t(),
          expected_base_sha: CommitSha.t()
        }

  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp validate_values(attrs) do
    cond do
      not ValidationError.nonempty_string?(attrs.title) ->
        {:error, {:invalid_field, :title}}

      not is_binary(attrs.body) ->
        {:error, {:invalid_field, :body}}

      not RepositoryRef.valid_ref?(attrs.head_ref) ->
        {:error, {:invalid_field, :head_ref}}

      not valid_commit_sha?(attrs.expected_base_sha) ->
        {:error, {:invalid_field, :expected_base_sha}}

      true ->
        :ok
    end
  end

  defp valid_commit_sha?(%CommitSha{value: value}),
    do: CommitSha.valid_sha1?(value) and value == String.downcase(value)

  defp valid_commit_sha?(_value), do: false
end
