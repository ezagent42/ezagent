defmodule Ezagent.DomainGit.ChangeRequest do
  @moduledoc "Normalized provider change-request facts."

  alias Ezagent.DomainGit.{CommitSha, RepositoryRef, ValidationError}
  @fields [:external_id, :url, :head_ref, :head_sha, :base_ref, :state]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          external_id: String.t(),
          url: URI.t(),
          head_ref: String.t(),
          head_sha: String.t(),
          base_ref: String.t(),
          state: :open | :closed | :merged
        }

  @doc "Builds normalized change-request facts, including a lowercase head SHA."
  @spec new(term()) :: {:ok, t()} | {:error, ValidationError.t()}
  def new(attrs) do
    with :ok <- ValidationError.validate_attrs(attrs, @fields, &validate_values/1) do
      {:ok, struct!(__MODULE__, %{attrs | head_sha: String.downcase(attrs.head_sha)})}
    end
  end

  @doc "Returns whether a value is an HTTP(S) URI with a host and no userinfo."
  @spec web_uri?(term()) :: boolean()
  def web_uri?(%URI{scheme: "http", host: host, userinfo: nil} = uri)
      when is_binary(host) and host != "" do
    is_binary(uri.path) or is_nil(uri.path)
  end

  def web_uri?(%URI{scheme: "https", host: host, userinfo: nil} = uri)
      when is_binary(host) and host != "" do
    is_binary(uri.path) or is_nil(uri.path)
  end

  def web_uri?(_uri), do: false

  defp validate_values(attrs) do
    checks = [
      external_id: ValidationError.nonempty_string?(attrs.external_id),
      url: web_uri?(attrs.url),
      head_ref: RepositoryRef.valid_ref?(attrs.head_ref),
      head_sha: CommitSha.valid_sha1?(attrs.head_sha),
      base_ref: RepositoryRef.valid_ref?(attrs.base_ref),
      state: attrs.state in [:open, :closed, :merged]
    ]

    case Enum.find(checks, fn {_field, valid?} -> not valid? end) do
      nil -> :ok
      {field, _} -> {:error, {:invalid_field, field}}
    end
  end
end
