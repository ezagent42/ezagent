defmodule Ezagent.Entity.Token do
  @moduledoc """
  Entity-agnostic, self-identifying HMAC bearer-token store.

  Replaces the User-only `users.cli_token` field with the
  `entity_tokens` table. Any Entity URI can mint tokens —
  `entity://user/<name>` (CLI access for a human user) or
  `entity://agent/<flavor>_<name>` (agent service auth).

  ## Lifecycle

      {plain, row} = Token.mint(uri, label: "cli-laptop")
      # store `plain` once at the call site (operator sees it)
      # `row.token_digest` is HMAC-SHA256(pepper_vN, raw), persisted

      {:ok, principal} = Ezagent.Authentication.authenticate(plain)
      # principal is derived from the token; caps remain an authZ concern

      :ok = Token.revoke(row.id)
      # subsequent authenticate(plain) → {:error, :invalid_credentials}

  The token format is `esr_pat_v<N>_<raw>`. The in-token version selects a
  durable server pepper before the database read; the keyed digest is then one
  unique-index lookup. No caller-supplied entity URI and no bcrypt fallback are
  accepted.

  ## See also

  - `Ezagent.Authentication.authenticate/1` — the token-only facade that
    resolves the owning principal before authorization.
  - `entity-agnostic-architecture-reflection.md` §4 S-2 — the
    design rationale (User-only token field doesn't generalize).
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "entity_tokens" do
    field(:entity_uri, :string)
    field(:token_hash, :string)
    field(:token_digest, :binary)
    field(:digest_version, :integer)
    field(:bound_generation, :integer)
    field(:label, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    # Phase 9 PR-6 (SPEC v3 §7) — per-tenant data isolation. NOT NULL;
    # derived from `entity_uri` at mint time (the 3-segment URI carries
    # the workspace name as its first path segment). Token operations
    # are scoped to the workspace the entity belongs to — a CLI token
    # for `entity://user/team-alpha/alice` can only authenticate as
    # alice in team-alpha, never the homonym in workspace://team-beta.
    field(:workspace_uri, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc """
  Mint a fresh token for `entity_uri`. Returns `{plain_token, row}`.

  Options:
  - `:label` — operator-readable name (e.g. `"cli-laptop"`)
  - `:expires_at` — `%DateTime{}` for time-bound tokens; default `nil`
    (no-expiry, suitable for long-running agent processes)

  Returns `{:error, {:unsupported_entity_uri, uri}}` for non-entity URIs.
  """
  @spec mint(URI.t() | String.t(), keyword()) ::
          {String.t(), t()} | {:error, term()}
  def mint(uri, opts \\ [])

  def mint(%URI{scheme: "entity"} = uri, opts) do
    version = current_version()

    with {:ok, generation} <- current_generation(uri),
         :ok <- credential_generation_allowed(uri, generation, opts),
         {:ok, pepper} <- pepper(version) do
      raw = generate_raw_secret()
      plain = "esr_pat_v#{version}_#{raw}"
      workspace_uri = Ezagent.Persistence.workspace_uri_for!(uri)

      %__MODULE__{}
      |> Ecto.Changeset.change(%{
        entity_uri: URI.to_string(uri),
        token_hash: nil,
        token_digest: digest(pepper, raw),
        digest_version: version,
        bound_generation: generation,
        label: Keyword.get(opts, :label),
        expires_at: Keyword.get(opts, :expires_at),
        workspace_uri: workspace_uri
      })
      |> Repo.insert!()
      |> then(&{plain, &1})
    end
  end

  def mint(uri, _opts), do: {:error, {:unsupported_entity_uri, uri}}

  @doc "Resolve one versioned PAT to its canonical principal with one indexed lookup."
  @spec authenticate(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def authenticate(token) when is_binary(token) do
    with {:ok, version, raw} <- parse(token),
         {:ok, pepper} <- pepper(version),
         %__MODULE__{} = row <- row_for_digest(digest(pepper, raw)),
         true <- row.digest_version == version,
         false <- expired?(row, DateTime.utc_now()),
         {:ok, principal} <- enabled_principal(row),
         :ok <- Ezagent.Entity.spawn_principal(principal) do
      bump_last_used(row, DateTime.utc_now())
      {:ok, principal}
    else
      {:error, {:pat_pepper_unavailable, _}} = error -> error
      _ -> {:error, :invalid_credentials}
    end
  end

  def authenticate(_), do: {:error, :invalid_credentials}

  @doc "Replace all tokens with `label` for an entity and return one fresh PAT."
  @spec rotate_label(URI.t(), String.t(), keyword()) ::
          {String.t(), t()} | {:error, term()}
  def rotate_label(%URI{scheme: "entity"} = uri, label, opts \\ [])
      when is_binary(label) and label != "" do
    case Repo.transaction(fn ->
           from(t in __MODULE__, where: t.entity_uri == ^URI.to_string(uri) and t.label == ^label)
           |> Repo.delete_all()

           case mint(uri, Keyword.put(opts, :label, label)) do
             {:error, reason} -> Repo.rollback(reason)
             result -> result
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List all (non-revoked) tokens for `entity_uri`, sorted by
  `inserted_at` descending. Does not include the plain token (it
  was returned once at mint time and is not recoverable).

  **Workspace-scoped via URI key** (Phase 9 PR-6 / SPEC v3 §7.2) —
  filters by `entity_uri` which is 3-segment workspace-bound; an
  entity in workspace://team-beta cannot leak its tokens to a
  homonym in workspace://team-alpha. Same exemption pattern as
  `Ezagent.EntityPresenter`.
  """
  @spec list(URI.t() | String.t()) :: [t()]
  def list(uri) do
    uri_str = uri_to_str(uri)

    from(t in __MODULE__,
      where: t.entity_uri == ^uri_str,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Revoke a token by its primary id. Always returns `:ok` even if the
  id is unknown (idempotent — admins running cleanup don't need to
  know the prior state).
  """
  @spec revoke(integer()) :: :ok
  def revoke(token_id) when is_integer(token_id) do
    from(t in __MODULE__, where: t.id == ^token_id)
    |> Repo.delete_all()

    :ok
  end

  # --- internals -----------------------------------------------------

  defp row_for_digest(token_digest) do
    from(t in __MODULE__, where: t.token_digest == ^token_digest, limit: 1)
    |> Repo.one()
  end

  defp expired?(%__MODULE__{expires_at: nil}, _now), do: false

  defp expired?(%__MODULE__{expires_at: %DateTime{} = exp}, now) do
    DateTime.compare(now, exp) == :gt
  end

  defp bump_last_used(row, now) do
    row
    |> Ecto.Changeset.change(%{last_used_at: now})
    |> Repo.update!()
  end

  defp enabled_principal(%__MODULE__{} = row) do
    principal = Ezagent.URI.new!(row.entity_uri)

    with {:ok, generation} <- current_generation(principal),
         true <- row.bound_generation == generation,
         :ok <- enabled_user(principal, row.entity_uri) do
      {:ok, principal}
    else
      _ -> {:error, :disabled}
    end
  rescue
    ArgumentError -> {:error, :invalid_credentials}
  end

  defp enabled_user(principal, entity_uri) do
    if Ezagent.URI.type?(principal, :user) do
      case Ezagent.Users.get_by_uri(entity_uri) do
        %{disabled_at: %DateTime{}} -> {:error, :disabled}
        _ -> :ok
      end
    else
      :ok
    end
  end

  defp current_generation(uri) do
    case Ezagent.Cap.Authority.current_generation(uri) do
      {:ok, generation} -> {:ok, generation}
      :error -> {:error, :authority_unavailable}
    end
  end

  defp credential_generation_allowed(_uri, 1, _opts), do: :ok

  defp credential_generation_allowed(uri, generation, opts) do
    with :created <- Keyword.get(opts, :create_freshness),
         {:ok, ^generation} <- Ezagent.Cap.Authority.current_process_generation(uri) do
      :ok
    else
      _ -> {:error, :principal_revoked}
    end
  end

  defp parse(token) do
    case Regex.run(~r/\Aesr_pat_v([1-9][0-9]*)_([A-Za-z0-9_-]{43})\z/, token) do
      [_, version, raw] -> {:ok, String.to_integer(version), raw}
      _ -> {:error, :invalid_credentials}
    end
  end

  defp current_version do
    :ezagent_domain_identity
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:current_version, 1)
  end

  defp pepper(version) do
    peppers =
      :ezagent_domain_identity
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:peppers, %{})

    case Map.get(peppers, version) do
      value when is_binary(value) and byte_size(value) >= 32 -> {:ok, value}
      _ -> {:error, {:pat_pepper_unavailable, version}}
    end
  end

  defp digest(pepper, raw), do: :crypto.mac(:hmac, :sha256, pepper, raw)

  defp generate_raw_secret do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
