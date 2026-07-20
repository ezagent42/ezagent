defmodule Ezagent.Cap.Signing do
  @moduledoc """
  Pure ed25519 signing primitives for capability artifacts.

  The module deliberately owns the signing envelope independently from the
  storage encoder: its bytes are RFC 8785 JSON Canonicalization Scheme (JCS)
  over the protocol's fixed capability payload.
  """

  alias Ezagent.{Cap, Capability}

  @key_id_max_size 512
  @key_id_pattern ~r/\Av([0-9]+)\|([A-Za-z0-9_-]+)\z/

  @doc "Return the domain-separated signing trust domain for a workspace scope."
  @spec trust_domain(URI.t() | :any) :: String.t()
  def trust_domain(%URI{} = workspace_uri), do: "w:" <> Ezagent.URI.stable_key(workspace_uri)
  def trust_domain(:any), do: "a:*"

  def trust_domain(workspace_uri) do
    raise ArgumentError,
          "cap signing trust domain requires a concrete workspace URI or :any, got: #{inspect(workspace_uri)}"
  end

  @doc "Build the bounded version-and-trust-domain key identifier."
  @spec key_id(non_neg_integer(), String.t()) :: String.t()
  def key_id(version, trust_domain)
      when is_integer(version) and version >= 0 and is_binary(trust_domain) do
    key_id = "v#{version}|" <> Base.url_encode64(trust_domain, padding: false)

    if byte_size(key_id) <= @key_id_max_size do
      key_id
    else
      raise ArgumentError,
            "cap signing key id exceeds the protocol limit of #{@key_id_max_size} bytes"
    end
  end

  @doc """
  Parse a key id only when its encoded trust domain is bound to `workspace_uri`.

  Malformed IDs and domain mismatches are authentic denial results, represented
  by `:error`; a malformed workspace scope still raises through `trust_domain/1`.
  """
  @spec parse_key_id(term(), URI.t() | :any) :: {:ok, non_neg_integer()} | :error
  def parse_key_id(key_id, workspace_uri)
      when is_binary(key_id) do
    with {:ok, version, domain} <- parse_key_id(key_id),
         expected_domain <- trust_domain(workspace_uri),
         true <- domain == expected_domain,
         true <- configured_key_version?(version) do
      {:ok, version}
    else
      _ -> :error
    end
  end

  def parse_key_id(_key_id, _workspace_uri), do: :error

  @doc false
  @spec parse_key_id(term()) :: {:ok, non_neg_integer(), String.t()} | :error
  def parse_key_id(key_id) when is_binary(key_id) and byte_size(key_id) <= @key_id_max_size do
    with [_, version_string, encoded_domain] <- Regex.run(@key_id_pattern, key_id),
         {version, ""} <- Integer.parse(version_string),
         {:ok, domain} <- Base.url_decode64(encoded_domain, padding: false) do
      {:ok, version, domain}
    else
      _ -> :error
    end
  end

  def parse_key_id(_key_id), do: :error

  @doc "Return RFC 8785 JCS bytes for the signed capability payload."
  @spec signing_payload(Capability.t()) :: binary()
  def signing_payload(%Capability{grantee_uri: grantee_uri} = cap),
    do: signing_payload(cap, grantee_uri)

  @doc false
  @spec signing_payload(Capability.t(), URI.t()) :: binary()
  def signing_payload(%Capability{grantee_uri: grantee_uri} = cap, grantee_uri) do
    %{
      "action" => canon_atom(Capability.action_of(cap)),
      "behavior" => canon_module(cap.behavior),
      "granted_at" => canon_timestamp(cap.granted_at),
      "granted_by" => canon_uri(cap.granted_by),
      "grantee" => canon_uri(grantee_uri),
      "instance" => canon_instance(cap.instance),
      "key_id" => canon_string(cap.key_id),
      "kind" => canon_atom(cap.kind),
      "v" => 1,
      "workspace_uri" => canon_workspace(cap.workspace_uri)
    }
    |> jcs_encode()
  end

  defp configured_key_version?(version) do
    signing_config()
    |> Keyword.get(:trusted_key_versions, [])
    |> Enum.member?(version)
  end

  defp signing_config do
    :ezagent_core
    |> Application.get_env(Cap, [])
    |> Keyword.get(:signing, [])
  end

  defp canon_atom(value) when is_atom(value), do: value |> Atom.to_string() |> canon_string()

  defp canon_module(:any), do: "any"

  defp canon_module(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> canon_string()
  end

  defp canon_instance(:any), do: "any"
  defp canon_instance(%URI{} = instance), do: canon_uri(instance)

  defp canon_instance({tag, %URI{} = scope_uri}) when is_atom(tag) do
    [canon_atom(tag), canon_uri(scope_uri)]
  end

  defp canon_instance(instance) do
    raise ArgumentError, "cap signing instance is not canonicalizable: #{inspect(instance)}"
  end

  defp canon_workspace(:any), do: "any"
  defp canon_workspace(%URI{} = workspace_uri), do: canon_uri(workspace_uri)

  defp canon_workspace(workspace_uri) do
    raise ArgumentError,
          "cap signing workspace URI is not canonicalizable: #{inspect(workspace_uri)}"
  end

  defp canon_uri(%URI{} = uri), do: uri |> Ezagent.URI.stable_key() |> canon_string()

  defp canon_uri(uri) do
    raise ArgumentError, "cap signing URI is not canonicalizable: #{inspect(uri)}"
  end

  defp canon_timestamp(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.to_unix(:millisecond)
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
    |> canon_string()
  end

  defp canon_timestamp(timestamp) do
    raise ArgumentError, "cap signing timestamp is not canonicalizable: #{inspect(timestamp)}"
  end

  defp canon_string(value) when is_binary(value) do
    if String.valid?(value) do
      String.normalize(value, :nfc)
    else
      raise ArgumentError, "cap signing strings must be valid UTF-8"
    end
  end

  defp canon_string(value) do
    raise ArgumentError, "cap signing string is not canonicalizable: #{inspect(value)}"
  end

  defp jcs_encode(map) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> [jcs_string(key), ":", jcs_encode(value)] end)
    |> Enum.intersperse(",")
    |> then(&["{", &1, "}"])
    |> IO.iodata_to_binary()
  end

  defp jcs_encode(list) when is_list(list) do
    list
    |> Enum.map(&jcs_encode/1)
    |> Enum.intersperse(",")
    |> then(&["[", &1, "]"])
    |> IO.iodata_to_binary()
  end

  defp jcs_encode(value) when is_binary(value), do: jcs_string(value)
  defp jcs_encode(value) when is_integer(value), do: Integer.to_string(value)

  defp jcs_string(value) do
    ["\"", jcs_escape(canon_string(value)), "\""]
    |> IO.iodata_to_binary()
  end

  defp jcs_escape(value), do: jcs_escape(value, [])
  defp jcs_escape(<<>>, acc), do: Enum.reverse(acc)

  defp jcs_escape(<<codepoint::utf8, rest::binary>>, acc) do
    escaped =
      case codepoint do
        ?\" ->
          "\\\""

        ?\\ ->
          "\\\\"

        8 ->
          "\\b"

        9 ->
          "\\t"

        10 ->
          "\\n"

        12 ->
          "\\f"

        13 ->
          "\\r"

        control when control <= 0x1F ->
          "\\u" <> String.pad_leading(Integer.to_string(control, 16), 4, "0")

        _ ->
          <<codepoint::utf8>>
      end

    jcs_escape(rest, [escaped | acc])
  end
end
