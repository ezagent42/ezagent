defmodule Ezagent.DomainGit.RepositoryRef do
  @moduledoc "Provider-neutral repository coordinates bound to an Ezagent Resource."

  alias Ezagent.DomainGit.ValidationError

  @fields [
    :repository_uri,
    :provider_adapter,
    :provider_host,
    :external_id,
    :owner_path,
    :base_ref,
    :visibility
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          repository_uri: URI.t(),
          provider_adapter: atom(),
          provider_host: String.t(),
          external_id: String.t(),
          owner_path: String.t(),
          base_ref: String.t(),
          visibility: :public | :private
        }

  @doc "Builds validated provider-neutral coordinates for an Ezagent Git repository."
  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @doc "Returns whether a value is an accepted provider branch or tag reference."
  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(ref) when is_binary(ref) and byte_size(ref) in 1..255 do
    String.match?(ref, ~r/\A[A-Za-z0-9][A-Za-z0-9._\/-]*\z/) and
      not String.starts_with?(ref, "refs/") and not String.ends_with?(ref, ["/", "."]) and
      not String.contains?(ref, ["//", "..", "@{"]) and
      Enum.all?(String.split(ref, "/"), &valid_ref_segment?/1)
  end

  def valid_ref?(_ref), do: false

  @doc "Returns whether a URI is canonical, action-free, and matches the requested axes."
  @spec ezagent_uri?(term(), String.t(), String.t()) :: boolean()
  def ezagent_uri?(%URI{} = uri, scheme, type) do
    Ezagent.URI.canonical?(uri) and Ezagent.URI.scheme?(uri, scheme) and
      match?({:ok, _workspace}, Ezagent.URI.workspace_name(uri)) and uri.query == nil and
      uri.fragment == nil and valid_uri_axes?(uri, type)
  end

  def ezagent_uri?(_uri, _scheme, _type), do: false

  defp validate_values(attrs) do
    checks = [
      repository_uri: ezagent_uri?(attrs.repository_uri, "resource", "git-repository"),
      provider_adapter: is_atom(attrs.provider_adapter) and not is_nil(attrs.provider_adapter),
      provider_host: ValidationError.nonempty_string?(attrs.provider_host),
      external_id: ValidationError.nonempty_string?(attrs.external_id),
      owner_path: ValidationError.nonempty_string?(attrs.owner_path),
      base_ref: valid_ref?(attrs.base_ref),
      visibility: attrs.visibility in [:public, :private]
    ]

    invalid_result(checks)
  end

  defp valid_ref_segment?(segment),
    do:
      segment not in ["", ".", ".."] and not String.starts_with?(segment, ".") and
        not String.ends_with?(segment, [".lock", "."])

  defp valid_uri_axes?(uri, nil),
    do:
      match?({:ok, _type}, Ezagent.URI.type(uri)) and match?({:ok, _name}, Ezagent.URI.name(uri))

  defp valid_uri_axes?(uri, type),
    do: Ezagent.URI.type?(uri, type) and match?({:ok, _name}, Ezagent.URI.name(uri))

  defp invalid_result(checks) do
    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end
end
