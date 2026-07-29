defmodule EzagentPluginForgejo.ForgejoCredentialBackend do
  @moduledoc """
  `Ezagent.ProviderConnection.CredentialBackend` implementation for Forgejo PATs.

  Credentials live in a named ETS table, encrypted at rest with AES-256-GCM
  under a key from `:ezagent_plugin_forgejo, :token_encryption_key`. The table
  is owned by this module's supervised process.

  ## Renewal

  Forgejo access tokens expire in an hour and the access token IS the
  repository credential, so renewal is load-bearing. `begin_refresh_exchange/1`
  and `consume_refresh_exchange/1` implement the custody half of the domain's
  refresh-exchange protocol; `EzagentPluginForgejo.ForgejoDriver.refresh/1`
  implements the provider half.

  The asymmetry with GitHub is worth stating: a GitHub App mints a fresh
  installation token per operation, so its stored user-to-server token is
  identity-only and never needs renewing — which is why that plugin's
  equivalent callbacks answer `:backend_unavailable` without consequence.
  Copying that answer here would have left every Forgejo connection dead after
  an hour.

  ## Security posture (design §4.2)

  This backend preserves "the credential never leaves the plugin": the
  plaintext token exists only between `lease_for_operation/1` and the HTTP call
  in `EzagentPluginForgejo.ForgejoClient`.

  With OAuth2 the credential is also genuinely **short-lived** (1h + rotation),
  which is parity with a GitHub installation token. What is still not available
  is GitHub's **per-repository** scoping: Forgejo's scope grammar is
  `<read|write>:<category>` with no repository selector. Note that last point is
  a structural inference from the grammar, **not** something measured — see
  design §4.1.1 for what would settle it.

  Sealing lives in `EzagentPluginForgejo.Sealed`. It began as private
  functions here, with a note that a second caller should trigger promotion
  rather than a copy; `EzagentPluginForgejo.OAuthApp` became that caller in
  slice F0, so it was promoted. This module's round-trip and
  no-plaintext-at-rest tests still cover the path.
  """

  @behaviour Ezagent.ProviderConnection.CredentialBackend

  alias Ezagent.ProviderConnection.CredentialBackend.RefreshUse
  alias Ezagent.ProviderConnection.CredentialRefreshExchange.ScopeAuthority
  alias EzagentPluginForgejo.Sealed

  @table_name :forgejo_credential_tokens
  @handoff_table :forgejo_credential_handoffs

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts the credential backend process, which owns the ETS table."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        :ets.new(@handoff_table, [:set, :public, :named_table, read_concurrency: true])
        :ok
      end,
      name: name
    )
  end

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def store(%{credential_material: {:write_only_handoff, token}}) do
    ref = "forgejo-credential-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    :ets.insert(@table_name, {ref, {Sealed.seal(token), 1}})
    {:ok, %{credential_ref: ref, credential_version: 1}}
  end

  # The domain calls `replace/1` in TWO shapes, and NEITHER carries a
  # `credential_ref`:
  #
  #   * after a refresh (`refresh.ex:449`) — `credential_material` is the
  #     one-use handoff reference this module minted in `seal_result/1`, plus
  #     `expected_credential_version`. The rotated tokens themselves never
  #     cross the domain; they wait in this module's handoff vault.
  #   * after a reauthorization (`exchange.ex:589` via `credential_command/3`)
  #     — real material from the driver, with `prior_credential_ref` naming the
  #     record being replaced.
  #
  # An earlier version of this module matched on `credential_ref`, which no
  # caller sends: `replace/1` raised `FunctionClauseError` on every real
  # refresh, and its tests passed only because they invented that shape.

  # This clause MUST come first. The refresh shape's head (credential_material
  # + expected_credential_version) also matches a reauthorization command,
  # which merely carries `prior_credential_ref` in addition -- put the handoff
  # clause first and every reauthorization is misread as a refresh and looked
  # up in an empty vault.
  @impl true
  def replace(%{
        credential_material: {:write_only_handoff, new_token},
        prior_credential_ref: prior_ref,
        expected_credential_version: expected_version
      })
      when is_binary(prior_ref) do
    swap(prior_ref, Sealed.seal(new_token), expected_version)
  end

  @impl true
  def replace(%{
        credential_material: {:write_only_handoff, handoff_ref},
        expected_credential_version: expected_version
      })
      when is_binary(handoff_ref) do
    case :ets.take(@handoff_table, handoff_ref) do
      [{^handoff_ref, sealed_replacement, target_ref}] ->
        # `:ets.take/2` is the one-use guarantee: a replayed replace finds
        # nothing and conflicts rather than re-applying a rotation.
        swap(target_ref, sealed_replacement, expected_version)

      [] ->
        {:error, :credential_conflict}
    end
  end

  def replace(_command), do: {:error, :credential_conflict}

  defp swap(ref, sealed, expected_version) do
    case :ets.lookup(@table_name, ref) do
      [{^ref, {_encrypted, version}}] when is_integer(version) and version == expected_version ->
        new_version = version + 1
        :ets.insert(@table_name, {ref, {sealed, new_version}})
        {:ok, %{credential_ref: ref, credential_version: new_version}}

      [{^ref, {_encrypted, _version}}] ->
        {:error, :stale_version}

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def status(%{credential_ref: ref}) do
    case :ets.lookup(@table_name, ref) do
      [{^ref, {_encrypted, version}}] ->
        {:ok, %{credential_ref: ref, credential_version: version}}

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def lease_for_operation(%{credential_ref: ref}) do
    case :ets.lookup(@table_name, ref) do
      [{^ref, {sealed, _version}}] ->
        case Sealed.open(sealed) do
          {:ok, token} -> {:ok, %{credential: token, credential_ref: ref, expires_at: nil}}
          {:error, reason} -> {:error, reason}
        end

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def consume_lease(_command), do: :ok

  # ── Refresh exchange ───────────────────────────────────────────────────
  #
  # The custody half of renewal. The domain
  # (`Ezagent.ProviderConnection.CredentialRefreshExchange`) owns the
  # orchestration: it resolves the bindings, starts the scope authority,
  # calls `begin_refresh_exchange/1`, then runs the driver, then checks that
  # what the driver returned is byte-identical to what this module sealed.
  # This module owns exactly two things the domain cannot know:
  #
  #   * which part of the stored credential the provider needs in order to
  #     renew (for Forgejo: the REFRESH token, not the access token), and
  #   * that the result the driver produced is well-formed before it is
  #     recorded as this backend's sealed result.
  #
  # Renewal matters here in a way it does not for GitHub: a GitHub App mints
  # a fresh installation token per operation, so its stored user-to-server
  # token is identity-only and never needs refreshing. A Forgejo access token
  # IS the repository credential and expires in an hour (measured), so without
  # this the connection simply dies and must be re-authorized.

  @impl true
  def begin_refresh_exchange(%{
        current_credential_ref: ref,
        scope_authority: authority,
        scope_token: token,
        scope_binding_digest: digest
      }) do
    case :ets.lookup(@table_name, ref) do
      [{^ref, {sealed, _version}}] ->
        # `private` is backend-owned and never leaves this module: the domain
        # treats the RefreshUse as opaque and its Inspect impl is redacted.
        # The sealed credential is carried rather than the plaintext so an
        # exchange that is begun but never consumed leaves no decrypted token
        # sitting in a struct.
        {:ok, RefreshUse.new(authority, token, digest, __MODULE__, %{sealed: sealed, ref: ref})}

      [] ->
        {:error, :credential_conflict}
    end
  end

  def begin_refresh_exchange(_command), do: {:error, :correlation_conflict}

  @impl true
  def consume_refresh_exchange(%{refresh_use: %RefreshUse{} = use, provider_exchange: exchange})
      when is_function(exchange, 1) do
    with __MODULE__ <- RefreshUse.backend(use),
         :ok <- consume_claim(use),
         %{sealed: sealed, ref: ref} <- RefreshUse.private(use),
         {:ok, credential} <- Sealed.open(sealed),
         {:ok, refresh_token} <- refresh_token(credential) do
      case exchange.(%{current_credential: refresh_token}) do
        {:ok, :not_completed} -> {:ok, :not_completed}
        {:ok, result} when is_map(result) -> seal_result(result, ref)
        {:error, reason} -> {:error, reason}
        _unexpected -> {:error, :provider_protocol_failed}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _mismatch -> {:error, :correlation_conflict}
    end
  end

  def consume_refresh_exchange(_command), do: {:error, :correlation_conflict}

  # The domain claims the scoped authority before handing this module a
  # `claimed_use` (`credential_refresh_exchange.ex:97-110`). Consuming that
  # claim is what binds this decryption to THIS invocation: without it the
  # backend would hand the refresh token to any closure presenting a
  # structurally-valid RefreshUse, including a stale one from an earlier
  # exchange.
  defp consume_claim(use) do
    case RefreshUse.claim_proof(use) do
      proof when is_reference(proof) ->
        ScopeAuthority.consume_claim(
          RefreshUse.authority(use),
          RefreshUse.token(use),
          RefreshUse.binding_digest(use),
          proof
        )

      _unclaimed ->
        {:error, :correlation_conflict}
    end
  end

  # The provider renews against the REFRESH token. Handing over the access
  # token instead is the obvious slip and would make every renewal fail with
  # `invalid_grant`.
  defp refresh_token(credential) do
    case Jason.decode(credential) do
      {:ok, %{"refresh_token" => token}} when is_binary(token) and token != "" ->
        {:ok, token}

      _no_refresh_token ->
        # A credential stored without a refresh token cannot be renewed. Saying
        # so beats calling the provider with something that is not a refresh
        # token and reporting its rejection as a provider fault.
        {:error, :credential_conflict}
    end
  end

  # `validate_result/2` in the domain requires exactly these five keys, with
  # `replacement_credential` already converted into a `credential_material`
  # handoff. Checking the shape here keeps a malformed provider result from
  # being recorded as this backend's sealed result.
  defp seal_result(
         %{
           provider_result_ref: provider_result_ref,
           replacement_credential: {:write_only_handoff, _material} = replacement,
           granted_permissions_digest: digest,
           expires_at: expires_at,
           provider_metadata: metadata
         } = result,
         target_ref
       )
       when map_size(result) == 5 and is_map(metadata) do
    with true <- nonempty?(provider_result_ref),
         true <- nonempty?(digest),
         true <- is_nil(expires_at) or is_struct(expires_at, DateTime),
         {:write_only_handoff, material} <- replacement,
         true <- nonempty?(material) do
      {:ok,
       result
       |> Map.delete(:replacement_credential)
       |> Map.put(
         :credential_material,
         park_handoff(provider_result_ref, material, target_ref)
       )}
    else
      _invalid -> {:error, :provider_protocol_failed}
    end
  end

  defp seal_result(_result, _target_ref), do: {:error, :provider_protocol_failed}

  # The handoff is a REFERENCE to the replacement, not the replacement itself:
  # the sealed result travels back through the domain and the driver, and the
  # rotated tokens have no business on that path in the clear.
  #
  # The replacement is parked here, sealed, under that reference, together with
  # the credential it replaces — because the domain's follow-up `replace/1`
  # carries ONLY the reference (`refresh.ex:449`). Minting a reference without
  # parking anything behind it, as an earlier version did, made every rotation
  # unrecoverable: the reference itself was stored as if it were the token.
  defp park_handoff(provider_result_ref, material, target_ref) do
    reference =
      {__MODULE__, provider_result_ref, material}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    :ets.insert(@handoff_table, {reference, Sealed.seal(material), target_ref})
    {:write_only_handoff, reference}
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  # Deleting an absent key is already a no-op in ETS, so an exact retry of the
  # same `idempotency_key` applies the same single logical effect.
  @impl true
  def revoke(%{credential_ref: ref}) do
    :ets.delete(@table_name, ref)
    :ok
  end
end
