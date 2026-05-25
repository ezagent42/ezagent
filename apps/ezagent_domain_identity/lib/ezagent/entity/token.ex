defmodule Ezagent.Entity.Token do
  @moduledoc """
  Entity-agnostic bearer-token store (PR #142, SPEC v2 §5.12).

  Replaces the User-only `users.cli_token` field with the
  `entity_tokens` table. Any Entity URI can mint tokens —
  `entity://user/<name>` (CLI access for a human user) or
  `entity://agent/<flavor>_<name>` (agent service auth).

  ## Lifecycle

      {plain, row} = Token.mint(uri, label: "cli-laptop")
      # store `plain` once at the call site (operator sees it)
      # `row.token_hash` is bcrypt(plain), persisted in the table

      {:ok, %{caps: caps}} = Token.verify(uri, plain)
      # `last_used_at` is bumped on every successful verify

      :ok = Token.revoke(row.id)
      # subsequent Token.verify(uri, plain) → {:error, :invalid_credentials}

  ## Why bcrypt the token

  Bearer tokens leak the same way passwords do (operator pastes one
  into a chat, an env file gets checked in). Hashing reduces blast
  radius — a stolen DB doesn't immediately yield usable tokens.
  Verification cost is acceptable: agents/CLI present a token once
  per session, not per request.

  ## See also

  - `Ezagent.Entity.authenticate/2` — the unified facade that
    dispatches to this module for `entity://agent/*` URIs.
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
    plain = generate_token()
    hash = Bcrypt.hash_pwd_salt(plain)
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(uri)

    %__MODULE__{}
    |> Ecto.Changeset.change(%{
      entity_uri: URI.to_string(uri),
      token_hash: hash,
      label: Keyword.get(opts, :label),
      expires_at: Keyword.get(opts, :expires_at),
      # Phase 9 PR-6 (SPEC v3 §7) — workspace_uri tracks the entity's
      # tenant so SELECTs can scope by workspace at audit time.
      workspace_uri: workspace_uri
    })
    |> Repo.insert!()
    |> then(&{plain, &1})
  end

  def mint(uri, _opts), do: {:error, {:unsupported_entity_uri, uri}}

  @doc """
  Verify `plain_token` against the tokens minted for `entity_uri`.

  Returns:
  - `{:ok, %{caps: MapSet.t()}}` on success, with `last_used_at` bumped
  - `{:error, :no_such_entity}` if no tokens exist for that URI
  - `{:error, :invalid_credentials}` for wrong / expired tokens
  """
  @spec verify(URI.t() | String.t(), String.t()) ::
          {:ok, %{caps: MapSet.t(Ezagent.Capability.t())}} | {:error, atom()}
  def verify(uri, plain_token) when is_binary(plain_token) do
    uri_str = uri_to_str(uri)

    case rows_for(uri_str) do
      [] ->
        # Run a dummy verify to avoid timing leak.
        Bcrypt.no_user_verify()
        {:error, :no_such_entity}

      rows ->
        check_rows(rows, plain_token, uri)
    end
  end

  def verify(_, _), do: {:error, :invalid_credentials}

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

  defp rows_for(uri_str) do
    from(t in __MODULE__,
      where: t.entity_uri == ^uri_str,
      order_by: [desc: t.inserted_at]
    )
    |> Repo.all()
  end

  defp check_rows(rows, plain_token, uri) do
    now = DateTime.utc_now()

    Enum.find(rows, fn row ->
      not expired?(row, now) and Bcrypt.verify_pass(plain_token, row.token_hash)
    end)
    |> case do
      nil ->
        {:error, :invalid_credentials}

      row ->
        bump_last_used(row, now)
        caps = Ezagent.Identity.list_caps_for(uri)
        {:ok, %{caps: caps}}
    end
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

  defp generate_token do
    "esr_pat_" <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
