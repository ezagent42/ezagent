defmodule Ezagent.Routing.Receiver do
  @moduledoc """
  Tagged routing receiver helpers.

  Persisted routing rules historically stored receiver strings. Role targeting
  needs an explicit tag so a role name is never parsed as a URI by accident.
  """

  @role_prefix "$role:"

  @type t :: {:role, String.t()} | {:uri, URI.t() | String.t()} | {:magic, String.t()}

  @doc "Build a tagged receiver for a declared session role."
  @spec role(String.t()) :: {:role, String.t()}
  def role(name) when is_binary(name) and name != "", do: {:role, name}

  @doc "Build a tagged receiver for a concrete URI."
  @spec uri(URI.t() | String.t()) :: {:uri, URI.t() | String.t()}
  def uri(%URI{} = uri), do: {:uri, uri}
  def uri(uri) when is_binary(uri) and uri != "", do: {:uri, uri}

  @doc "Build a tagged receiver for a magic routing receiver token."
  @spec magic(String.t()) :: {:magic, String.t()}
  def magic(token) when is_binary(token) and token != "", do: {:magic, token}

  @doc "Encode a receiver into the persistent RuleStore string format."
  @spec encode_for_store(t() | URI.t() | String.t()) :: String.t()
  def encode_for_store({:role, name}) when is_binary(name) and name != "" do
    @role_prefix <> Base.url_encode64(name, padding: false)
  end

  def encode_for_store({:uri, %URI{} = uri}), do: URI.to_string(uri)
  def encode_for_store({:uri, uri}) when is_binary(uri), do: uri
  def encode_for_store({:magic, token}) when is_binary(token), do: token
  def encode_for_store(%URI{} = uri), do: URI.to_string(uri)
  def encode_for_store(receiver) when is_binary(receiver), do: receiver

  @doc "Decode a persisted RuleStore receiver string, preserving legacy bare strings."
  @spec decode_from_store(String.t()) :: t() | String.t()
  def decode_from_store(@role_prefix <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, name} when name != "" -> {:role, name}
      _ -> @role_prefix <> encoded
    end
  end

  def decode_from_store(receiver) when is_binary(receiver), do: receiver
end
