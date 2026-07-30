defmodule EzagentPluginForgejo.OAuthApp do
  @moduledoc """
  Per-tenant Forgejo OAuth application registrations, keyed by
  `{workspace_uri, governed_host}`.

  Forgejo is self-hosted, so **each instance is its own OAuth provider** with
  its own `client_id`/`client_secret`. GitHub needs no equivalent: one hosted
  instance means one App in config serving everyone.

  A tenant admin registers the application once per instance, in that
  instance's web UI, and the pair is recorded here. Registering it through the
  API is possible but rejected by design: `POST /user/applications/oauth2`
  requires a `write:user` token, which can modify account settings — keeping
  such a credential around to save one manual step is a bad trade (design
  §4.1.3).

  ## Tenant isolation

  `workspace_uri` is the first component of the primary key and is always part
  of the lookup, so one workspace can never reach another's client secret —
  a cross-tenant read is a miss, not a leak (invariant 14).

  The secret is sealed with `Ezagent.ProviderConnection.SealedEnvelope` — the
  provider-connection domain's keyed, rotatable envelope, the same one its own
  authorization records use — before it reaches the
  database and is opened only in `fetch/2`, on the way to
  `EzagentPluginForgejo.ForgejoOAuth`.
  """

  alias EzagentCore.Repo
  alias Ezagent.ProviderConnection.SealedEnvelope
  alias EzagentPluginForgejo.Instance

  defmodule Record do
    @moduledoc "Ecto schema for a tenant's Forgejo OAuth application registration."
    use Ecto.Schema

    @primary_key false
    schema "forgejo_oauth_apps" do
      field(:workspace_uri, :string, primary_key: true)
      field(:governed_host, :string, primary_key: true)
      field(:client_id, :string)
      field(:key_id, :string)
      field(:key_fingerprint, :binary)
      field(:nonce, :binary)
      field(:ciphertext, :binary)
      field(:redirect_uri, :string)

      timestamps(type: :utc_datetime_usec)
    end
  end

  @type app :: %{
          host: String.t(),
          client_id: String.t(),
          client_secret: String.t(),
          redirect_uri: String.t()
        }
  @type error ::
          :invalid_workspace_uri
          | :invalid_provider_host
          | :invalid_client_id
          | :invalid_client_secret
          | :invalid_redirect_uri
          | :oauth_app_not_registered
          | :authentication_failed

  @doc """
  Records (or replaces) a tenant's OAuth application for one instance.

  Every field is validated here rather than at request time: a malformed host
  or redirect URI discovered mid-authorization would already have sent a user —
  or an authorization code — somewhere unintended.
  """
  @spec register(map()) :: {:ok, Record.t()} | {:error, error()}
  def register(attrs) do
    with {:ok, workspace_uri} <- validate_workspace(attrs[:workspace_uri]),
         {:ok, host} <- validate_host(attrs[:governed_host]),
         {:ok, client_id} <- validate_present(attrs[:client_id], :invalid_client_id),
         {:ok, secret} <- validate_present(attrs[:client_secret], :invalid_client_secret),
         {:ok, redirect_uri} <- validate_redirect_uri(attrs[:redirect_uri]) do
      with {:ok, snapshot} <- SealedEnvelope.snapshot() do
        %{
          key_id: key_id,
          key_fingerprint: fingerprint,
          nonce: nonce,
          ciphertext: ciphertext
        } =
          SealedEnvelope.seal(
            snapshot,
            :active,
            :provider_oauth_app,
            secret,
            secret_aad(workspace_uri, host)
          )

        now = DateTime.utc_now()

        {:ok,
         Repo.insert!(
           %Record{
             workspace_uri: workspace_uri,
             governed_host: host,
             client_id: client_id,
             key_id: key_id,
             key_fingerprint: fingerprint,
             nonce: nonce,
             ciphertext: ciphertext,
             redirect_uri: redirect_uri,
             inserted_at: now,
             updated_at: now
           },
           on_conflict:
             {:replace,
              [
                :client_id,
                :key_id,
                :key_fingerprint,
                :nonce,
                :ciphertext,
                :redirect_uri,
                :updated_at
              ]},
           conflict_target: [:workspace_uri, :governed_host]
         )}
      end
    end
  end

  @doc """
  Loads the OAuth application a workspace registered for one instance.

  The returned map is the shape `EzagentPluginForgejo.ForgejoOAuth` takes.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, app()} | {:error, error()}
  def fetch(workspace_uri, governed_host)
      when is_binary(workspace_uri) and is_binary(governed_host) do
    case Repo.get_by(Record, workspace_uri: workspace_uri, governed_host: governed_host) do
      nil ->
        {:error, :oauth_app_not_registered}

      %Record{
        governed_host: host,
        client_id: client_id,
        key_id: key_id,
        key_fingerprint: fingerprint,
        nonce: nonce,
        ciphertext: ciphertext,
        redirect_uri: redirect_uri
      } ->
        with {:ok, snapshot} <- SealedEnvelope.snapshot(),
             {:ok, secret} <-
               SealedEnvelope.open(
                 snapshot,
                 :provider_oauth_app,
                 %{
                   key_id: key_id,
                   key_fingerprint: fingerprint,
                   nonce: nonce,
                   ciphertext: ciphertext
                 },
                 secret_aad(workspace_uri, host)
               ) do
          {:ok,
           %{
             host: host,
             client_id: client_id,
             client_secret: secret,
             redirect_uri: redirect_uri
           }}
        end
    end
  end

  # Binds the ciphertext to its row: a secret sealed for one tenant/instance
  # pair will not open under another.
  defp secret_aad(workspace_uri, governed_host),
    do: %{workspace_uri: workspace_uri, governed_host: governed_host}

  # ── validation ───────────────────────────────────────────────────────

  # `Ezagent.URI.new!/1` rather than stdlib `URI.parse/1`: this is an Ezagent
  # scheme, and only the canonical parser rejects the near-misses that
  # `URI.parse/1` happily accepts (SPEC 2026-05-27-uri-canonicalization §3).
  # It raises on malformed input, so a non-URI string becomes a closed
  # `{:error, :invalid_workspace_uri}` here rather than an exception escaping
  # into a caller that expected a tagged tuple.
  defp validate_workspace(value) when is_binary(value) do
    uri = Ezagent.URI.new!(value)

    if Ezagent.URI.scheme?(uri, "workspace") and Ezagent.URI.canonical?(uri) do
      {:ok, value}
    else
      {:error, :invalid_workspace_uri}
    end
  rescue
    _error -> {:error, :invalid_workspace_uri}
  end

  defp validate_workspace(_value), do: {:error, :invalid_workspace_uri}

  # Reuses the REST base's host allowlist so both the API calls and the
  # browser-bound authorization URL accept exactly the same set of hosts.
  defp validate_host(value) do
    case Instance.api_base(value) do
      {:ok, _base} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_present(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp validate_present(_value, error), do: {:error, error}

  defp validate_redirect_uri(value) when is_binary(value) do
    # The scheme is matched as a LITERAL per clause rather than with a
    # `scheme in [...]` guard. `mix ezagent.uri_query.scan` already exempts
    # external-URL reads, but it recognises them by a literal `scheme: "http"` /
    # `"https"` in the pattern (`scan.ex` `external_url_pattern?/1`); binding the
    # scheme to a variable hides that from the detector and the read is reported
    # as `positional_uri_read`. Writing it the way the gate reads it keeps the
    # exemption honest instead of widening the rule.
    #
    # NB the `uri-canonical-allow` marker below must stay on the SAME LINE as the
    # `URI.parse/1` call: `UriCanonicalizationInvariantTest` matches it per-line,
    # so pushing it above an explanatory block silently loses the exemption.
    # uri-canonical-allow: an OAuth redirect_uri is an external http(s) URL handed to a third-party provider, not an Ezagent-scheme URI — Ezagent.URI.new!/1 would reject every valid value.
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        {:ok, value}

      %URI{scheme: "http", host: host} when is_binary(host) and host != "" ->
        {:ok, value}

      _other ->
        {:error, :invalid_redirect_uri}
    end
  end

  defp validate_redirect_uri(_value), do: {:error, :invalid_redirect_uri}
end
