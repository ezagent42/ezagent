defmodule Ezagent.Users do
  @moduledoc """
  Facade for the `users` SQLite table — provisioning + login lookup
  (Phase 4-completion Spec 05 Part A).

  Distinct from User-Kind snapshot:
  - `users` is **provisioning config** — "these credentials exist, here
    are their initial caps."
  - User Kind's `:identity` slice is **runtime state** — "the live cap
    set, possibly mutated by ops."

  Boot flow: plugin Application.start reads `users.list_all/0` → for
  each row, spawns the User Kind via SpawnRegistry with `initial_caps:`
  decoded from `caps_json`.

  Per Spec 05 Q-MU-4: passwords are bcrypt-hashed via `:bcrypt_elixir`.
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @primary_key {:id, :id, autogenerate: true}
  schema "users" do
    field(:uri, :string)
    field(:password_hash, :string)
    field(:caps_json, :string)
    # Phase 9 PR-6 (SPEC v3 §7) — per-tenant data isolation. NOT NULL.
    # Derived from `uri` at create-time (the 3-segment entity URI
    # carries the workspace name as its first path segment). The
    # serialized caps in `caps_json` inherit scope via this column —
    # we do not split caps into a separate per-cap workspace column
    # because every cap minted for a user is bounded by the user's
    # workspace (admin's cross-workspace cap is the documented
    # exception per SPEC §4.4, stored on admin's row).
    field(:workspace_uri, :string)
    # PR #142: per-user `cli_token` field removed — bearer tokens now
    # live in `entity_tokens` (entity-agnostic, supports agents too).
    # See `Ezagent.Entity.Token`.
    timestamps(type: :utc_datetime_usec)
  end

  @type decoded :: %{
          id: integer() | nil,
          uri: URI.t(),
          password_hash: String.t() | nil,
          caps: [Ezagent.Capability.t()]
        }

  # --- write paths ---------------------------------------------------

  @doc """
  Create a new User row. `password` is bcrypt-hashed before insert.
  Caps are `[Ezagent.Capability.t()]` — serialized via Jason.
  """
  @spec create(URI.t() | String.t(), String.t() | nil, [Ezagent.Capability.t()]) ::
          {:ok, decoded()} | {:error, term()}
  def create(uri, password, caps) when is_list(caps) do
    uri_str = uri_to_str(uri)

    hash =
      if is_binary(password) and password != "" do
        Bcrypt.hash_pwd_salt(password)
      else
        nil
      end

    # PR 27 (Allen 2026-05-18): prepend the User Kind's structural
    # default caps so every newly-minted user can at least participate
    # in chat. Caller-supplied caps follow, so an operator who
    # explicitly grants `session.chat` doesn't double-grant (the
    # Identity slice de-dupes via MapSet on load anyway).
    #
    # Phase 9 PR-3 (SPEC v3 §4.5): default caps are workspace-scoped
    # — derive the user's workspace from their URI.
    user_workspace = Ezagent.URI.entity_workspace_uri(Ezagent.URI.new!(uri_str))
    final_caps = Ezagent.Entity.User.default_caps(user_workspace) ++ caps

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.change(%{
        uri: uri_str,
        password_hash: hash,
        caps_json: encode_caps(final_caps),
        # Phase 9 PR-6 (SPEC v3 §7) — derive the workspace_uri column
        # from the entity URI so SELECTs can scope by workspace.
        workspace_uri: URI.to_string(user_workspace)
      })
      |> Ecto.Changeset.unique_constraint(:uri, name: :users_uri_index)

    case Repo.insert(changeset) do
      {:ok, row} -> {:ok, decode(row)}
      err -> err
    end
  end

  @doc "Set or rotate a user's password. Returns `{:ok, decoded}` or `{:error, :not_found}`."
  @spec set_password(URI.t() | String.t(), String.t()) ::
          {:ok, decoded()} | {:error, term()}
  def set_password(uri, password) when is_binary(password) and password != "" do
    uri_str = uri_to_str(uri)
    hash = Bcrypt.hash_pwd_salt(password)

    case Repo.get_by(__MODULE__, uri: uri_str) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Ecto.Changeset.change(%{password_hash: hash})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, decode(updated)}
          err -> err
        end
    end
  end

  @doc "Verify a password against the stored hash. Returns true/false."
  @spec verify_password(URI.t() | String.t(), String.t()) :: boolean()
  def verify_password(uri, password) when is_binary(password) do
    uri_str = uri_to_str(uri)

    case Repo.get_by(__MODULE__, uri: uri_str) do
      %__MODULE__{password_hash: hash} when is_binary(hash) and hash != "" ->
        Bcrypt.verify_pass(password, hash)

      _ ->
        # No row OR password_hash is NULL — refuse login. Per Spec 05
        # Q-MU-1: admin must set password via mix task before first login.
        # Run a dummy verification to avoid timing leak.
        Bcrypt.no_user_verify()
        false
    end
  end

  # --- read paths ----------------------------------------------------

  @doc """
  Look up a user by full URI.

  **System-scope read** — does not apply `Ezagent.Persistence.scope_by_workspace/2`
  because the URI itself is already 3-segment (carries the workspace),
  so the unique-on-`uri` index serves as the workspace partition. A
  caller asking for `entity://user/team-alpha/alice` cannot
  accidentally receive `entity://user/team-alpha/alice`.
  """
  @spec get_by_uri(URI.t() | String.t()) :: decoded() | nil
  def get_by_uri(uri) do
    case Repo.get_by(__MODULE__, uri: uri_to_str(uri)) do
      nil -> nil
      row -> decode(row)
    end
  end

  @doc """
  List ALL users across all workspaces.

  **System-scope read** — intentional cross-workspace listing for the
  Application boot path (every User Kind is hydrated from this table
  via `SpawnRegistry.spawn`) and the admin user management UI. Per
  SPEC v3 §7.2 documented exception: bypasses `scope_by_workspace/2`
  by design. Per-workspace listing is `list_in_workspace/1`.
  """
  @spec list_all() :: [decoded()]
  def list_all do
    Repo.all(from(u in __MODULE__, order_by: u.uri))
    |> Enum.map(&decode/1)
  end

  @doc """
  List users scoped to a single workspace. Per SPEC v3 §7.2 — the
  standard workspace-scoped read path. Use this for per-tenant admin
  UI, NOT `list_all/0`.
  """
  @spec list_in_workspace(URI.t() | String.t()) :: [decoded()]
  def list_in_workspace(workspace_uri) do
    __MODULE__
    |> Ezagent.Persistence.scope_by_workspace(workspace_uri)
    |> order_by([u], u.uri)
    |> Repo.all()
    |> Enum.map(&decode/1)
  end

  # CLI token helpers removed in PR #142 — bearer tokens are now
  # entity-agnostic via `Ezagent.Entity.Token` (`entity_tokens` table).
  # See also `mix ezagent.user.token --mint|--list|--revoke`.

  # --- encoding helpers ---------------------------------------------

  defp encode_caps(caps) when is_list(caps) do
    caps
    |> Enum.map(&Ezagent.Capability.to_map/1)
    |> Jason.encode!()
  end

  defp decode(%__MODULE__{} = row) do
    %{
      id: row.id,
      uri: Ezagent.URI.new!(row.uri),
      password_hash: row.password_hash,
      caps: decode_caps(row.caps_json)
    }
  end

  defp decode_caps(nil), do: []
  defp decode_caps(""), do: []

  defp decode_caps(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) ->
        Enum.map(list, &Ezagent.Capability.from_map/1)

      _ ->
        []
    end
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
