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

  ## Custody is durable

  The credential lives in `EzagentPluginForgejo.CredentialRecord` (a per-tenant
  Postgres table) sealed by `Ezagent.ProviderConnection.SealedEnvelope` — the
  domain's own keyed, rotatable envelope. It used to live in an ETS table owned
  by this module's process, which meant one crash wiped every user's credential
  on the node while `provider_connections` kept pointing at them.

  ## The handoff vault is ETS, with a known window

  A parked replacement is a within-operation artifact, so it lives in ETS rather
  than in a table. The entry is deleted only AFTER the durable write succeeds,
  so a failed write stays retryable.

  **The residual window is a process restart.** ETS dies with its owner, and the
  domain's refresh-path `replace/1` carries only an opaque reference — it cannot
  re-derive the rotated credential. So a restart between
  `consume_refresh_exchange/1` and `replace/1` loses a rotation that the provider
  has already applied: the domain retries the same reference, gets
  `:credential_conflict` each time, and after its retry budget expires the
  connection (`refresh.ex:28`), which costs the owner one browser
  re-authorization.

  An earlier version of this moduledoc claimed losing the vault merely "fails a
  refresh that the domain retries". That was WRONG — the domain retries the
  `replace`, not the exchange, and the same dead reference can never resolve.
  Closing the window needs the parked replacement to be durable (a table beside
  `forgejo_credentials`); it is recorded in design §12.3 rather than fixed here.
  """

  @behaviour Ezagent.ProviderConnection.CredentialBackend

  alias Ezagent.ProviderConnection.CredentialBackend.RefreshUse
  alias Ezagent.ProviderConnection.CredentialRefreshExchange.ScopeAuthority
  alias EzagentPluginForgejo.CredentialRecord

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

  @doc """
  Starts the process that owns the handoff vault.

  It no longer owns the credentials — those are durable rows. Only the
  within-operation handoff vault is process-owned, which is why losing this
  process is now recoverable.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        :ets.new(@handoff_table, [:set, :public, :named_table, read_concurrency: true])
        :ok
      end,
      name: name
    )
  end

  # ── Callbacks ──────────────────────────────────────────────────────────

  # `workspace_uri` is REQUIRED. The real caller
  # (`LocalAuthorizationBackend.Support.credential_command/3`) always sends it;
  # the previous clause matched only `credential_material`, so every test
  # described a command shape no caller produces. The durable row needs the
  # workspace, so requiring it here matches the table to reality.
  @impl true
  def store(%{
        workspace_uri: workspace_uri,
        credential_material: {:write_only_handoff, token}
      })
      when is_binary(workspace_uri) do
    CredentialRecord.insert(workspace_uri, token)
  end

  def store(_command), do: {:error, :credential_conflict}

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
        workspace_uri: workspace_uri,
        credential_material: {:write_only_handoff, new_token},
        prior_credential_ref: prior_ref,
        expected_credential_version: expected_version
      })
      when is_binary(workspace_uri) and is_binary(prior_ref) do
    CredentialRecord.replace(workspace_uri, prior_ref, new_token, expected_version)
  end

  @impl true
  def replace(%{
        credential_material: {:write_only_handoff, handoff_ref},
        expected_credential_version: expected_version
      })
      when is_binary(handoff_ref) do
    # LOOKUP, then delete only after the durable write succeeds.
    #
    # `:ets.take/2` here removed the only copy of the rotated credential BEFORE
    # the write. If the write then failed, the token was gone for good: the
    # provider has already invalidated the old refresh token, and the domain
    # retries `replace/1` with the same opaque reference (`refresh.ex:449`),
    # which can never resolve again — so every retry returns
    # `:credential_conflict` until the connection is expired and the owner has
    # to re-authorize in a browser. Read-then-delete makes that failure
    # retryable, which is what this path was documented to be.
    #
    # One-use is still enforced: after a successful write the entry is deleted,
    # so a replay conflicts instead of re-applying a rotation.
    #
    # The workspace comes from the vault, not from the command: the refresh-path
    # `replace/1` carries no `workspace_uri`, so it is captured when the handoff
    # is parked — at which point this module still knows which tenant's
    # credential is being rotated.
    case :ets.lookup(@handoff_table, handoff_ref) do
      [{^handoff_ref, replacement, workspace_uri, target_ref}] ->
        case CredentialRecord.replace(workspace_uri, target_ref, replacement, expected_version) do
          {:ok, result} ->
            :ets.delete(@handoff_table, handoff_ref)
            {:ok, result}

          {:error, reason} ->
            {:error, reason}
        end

      [] ->
        {:error, :credential_conflict}
    end
  end

  def replace(_command), do: {:error, :credential_conflict}

  @impl true
  def status(%{credential_ref: ref}) do
    case CredentialRecord.version(ref) do
      {:ok, version} -> {:ok, %{credential_ref: ref, credential_version: version}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `workspace_uri` is REQUIRED here. The credential is the only thing this
  # backend hands back in plaintext, so it is the one call that must not be
  # satisfiable by holding a ref alone: a stale or mis-bound pointer carrying
  # another tenant's ref would otherwise lease that tenant's access token.
  # `CredentialSource` is the sole production caller and always knows the
  # workspace — it selected the connection by it.
  @impl true
  def lease_for_operation(%{workspace_uri: workspace_uri, credential_ref: ref})
      when is_binary(workspace_uri) do
    case CredentialRecord.fetch_credential(workspace_uri, ref) do
      {:ok, token} -> {:ok, %{credential: token, credential_ref: ref, expires_at: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  def lease_for_operation(_command), do: {:error, :credential_conflict}

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
    # The workspace is captured HERE, from the row itself, because the domain's
    # follow-up `replace/1` on the refresh path carries none — and the rotation
    # must land on the same tenant's row it was read from.
    case CredentialRecord.workspace_of(ref) do
      {:ok, workspace_uri} ->
        # `private` is backend-owned and never leaves this module: the domain
        # treats the RefreshUse as opaque and its Inspect impl is redacted. Only
        # the REF travels — the credential is read from the durable row inside
        # `consume_refresh_exchange/1`, so an exchange that is begun but never
        # consumed leaves neither plaintext nor ciphertext sitting in a struct.
        {:ok,
         RefreshUse.new(authority, token, digest, __MODULE__, %{
           ref: ref,
           workspace_uri: workspace_uri
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def begin_refresh_exchange(_command), do: {:error, :correlation_conflict}

  @impl true
  def consume_refresh_exchange(%{refresh_use: %RefreshUse{} = use, provider_exchange: exchange})
      when is_function(exchange, 1) do
    with __MODULE__ <- RefreshUse.backend(use),
         :ok <- consume_claim(use),
         %{ref: ref, workspace_uri: workspace_uri} <- RefreshUse.private(use),
         {:ok, credential} <- CredentialRecord.fetch_credential(workspace_uri, ref),
         {:ok, refresh_token} <- refresh_token(credential) do
      case exchange.(%{current_credential: refresh_token}) do
        {:ok, :not_completed} -> {:ok, :not_completed}
        {:ok, result} when is_map(result) -> seal_result(result, workspace_uri, ref)
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
         workspace_uri,
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
         park_handoff(provider_result_ref, material, workspace_uri, target_ref)
       )}
    else
      _invalid -> {:error, :provider_protocol_failed}
    end
  end

  defp seal_result(_result, _workspace_uri, _target_ref), do: {:error, :provider_protocol_failed}

  # The handoff is a REFERENCE to the replacement, not the replacement itself:
  # the sealed result travels back through the domain and the driver, and the
  # rotated tokens have no business on that path in the clear.
  #
  # The replacement is parked here, sealed, under that reference, together with
  # the credential it replaces — because the domain's follow-up `replace/1`
  # carries ONLY the reference (`refresh.ex:449`). Minting a reference without
  # parking anything behind it, as an earlier version did, made every rotation
  # unrecoverable: the reference itself was stored as if it were the token.
  defp park_handoff(provider_result_ref, material, workspace_uri, target_ref) do
    reference =
      {__MODULE__, provider_result_ref, material}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    # Stored unsealed: the vault is in-VM, single-use, and consumed within the
    # same operation. `CredentialRecord.replace/4` seals it on the way to disk.
    :ets.insert(@handoff_table, {reference, material, workspace_uri, target_ref})
    {:write_only_handoff, reference}
  end

  defp nonempty?(value), do: is_binary(value) and value != ""

  # Deleting an absent row is already the desired state, so an exact retry of
  # the same `idempotency_key` applies the same single logical effect.
  @impl true
  def revoke(%{credential_ref: ref}), do: CredentialRecord.delete(ref)
end
