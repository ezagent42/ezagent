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
    # #154 spec 甲 (2026-06-19) — `confirmed` is the REAL source of truth for
    # anon-ness (replaces the `anon-` URI name-prefix hack). `false` = an
    # anonymous / unconfirmed user (mounts the reduced participation tier at
    # join); `true` = a confirmed user. `create/3` → true, `create_read_only/2`
    # → false.
    field(:confirmed, :boolean, default: false)
    # task #87 (login email+password) — `email_verified` is the source of truth
    # for "this user proved email ownership". INDEPENDENT of `confirmed`
    # (anon-ness): a self-registered human is `confirmed: true` (a real,
    # non-anon user) but `email_verified: false` until they click the
    # confirmation link. Form login is gated on `email_verified == true`.
    field(:email_verified, :boolean, default: false)
    # Admin user management v1 — soft-disable real users. This intentionally
    # does NOT use `delete/1`, which tears down provisioning rows and Kind
    # snapshots for anon-User GC.
    field(:disabled_at, :utc_datetime_usec)
    field(:disabled_by, :string)
    field(:disabled_reason, :string)
    # PR #142: per-user `cli_token` field removed — bearer tokens now
    # live in `entity_tokens` (entity-agnostic, supports agents too).
    # See `Ezagent.Entity.Token`.
    timestamps(type: :utc_datetime_usec)
  end

  @type decoded :: %{
          id: integer() | nil,
          uri: URI.t(),
          password_hash: String.t() | nil,
          caps: [Ezagent.Capability.t()],
          confirmed: boolean(),
          email_verified: boolean(),
          disabled_at: DateTime.t() | nil,
          disabled_by: String.t() | nil,
          disabled_reason: String.t() | nil
        }

  # --- write paths ---------------------------------------------------

  @doc """
  Create a new User row. `password` is bcrypt-hashed before insert.
  Caps are `[Ezagent.Capability.t()]` — serialized via Jason.
  """
  @spec create(URI.t() | String.t(), String.t() | nil, [Ezagent.Capability.t()], keyword()) ::
          {:ok, decoded()} | {:error, term()}
  def create(uri, password, caps, opts \\ []) when is_list(caps) do
    uri_str = uri_to_str(uri)

    if reserved_anon_name?(uri_str) do
      # #51 codex P2: the `anon-` user-name prefix is RESERVED for the
      # anonymous-viewer mint path (`create_read_only/1`). A normal user MUST
      # NOT use it — otherwise `Session.Membership.anon_member?/1` would
      # misclassify them and silently drop their legitimate first-join owner
      # behavior. Reject it here so the prefix reliably identifies anon users.
      {:error, :reserved_anon_prefix}
    else
      do_create(uri_str, password, caps, opts)
    end
  end

  defp do_create(uri_str, password, caps, opts) do
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
        workspace_uri: URI.to_string(user_workspace),
        # #154 spec 甲 — a normal `create/3` user is CONFIRMED.
        confirmed: true,
        # task #87 — operator/programmatic creation is trusted (email_verified
        # defaults true); self-registration passes `email_verified: false` so
        # the form-login gate holds until the email is confirmed.
        email_verified: Keyword.get(opts, :email_verified, true)
      })
      |> Ecto.Changeset.unique_constraint(:uri, name: :users_uri_index)

    parent_uri = Keyword.get(opts, :created_by, user_workspace)
    edge_kind = if Keyword.has_key?(opts, :created_by), do: :created_by, else: :workspace_member

    insert_with_derivation(changeset, Ezagent.URI.new!(uri_str), parent_uri, edge_kind)
  end

  @doc """
  Create a **read-only** User row — NO password and a caps_json of EXACTLY the
  supplied `caps` (default `[]`, the empty-caps read-only-by-construction shape).

  Unlike `create/3`, this path does NOT prepend `Ezagent.Entity.User.default_caps/1`
  (the broad `{kind: :session, behavior: :any, action: :any}` baseline cap that lets
  a normal user attempt `chat.send`). It is the minting path for the socialware
  anonymous external user (issue #51): an entity that may only READ a session it is
  a member of, and whose read-only-ness IS the absence of any session WRITE cap. The
  User Kind demand-spawns this row via `Ezagent.Entity.User.initial_caps_for_spawn/1`,
  which hydrates from `caps_json` — an empty caps_json yields no session cap, so the
  spawned anon-User holds only the structural self-Identity cap.

  `caps` defaults to `[]` (the historical empty-caps invariant). The
  `public_view` anon-access path (issue #51 §4.1) passes a SINGLE narrow,
  concrete-instance `session.join` cap whose `granted_by` is the session owner
  (Decision #154 — no unowned permissions): the anon is then a self-sufficient
  caller that joins ONLY its own session under its OWN authority, with no
  `system://` principal in the dispatch ctx. NOTE the caps MUST be
  `to_map/1`-serializable. Concrete `%URI{}` / `:any` instance axes and the
  closed scope-tuple forms (`:within_session`, `:within_workspace`, and
  `:spawned_by`) round-trip through the same `caps_json` wire shape.

  The row carries no `password_hash`, so `verify_password/2` refuses login for it
  (a read-only viewer is never a login principal).
  """
  @spec create_read_only(URI.t() | String.t(), [Ezagent.Capability.t()]) ::
          {:ok, decoded()} | {:error, term()}
  def create_read_only(uri, caps \\ []) when is_list(caps) do
    uri_str = uri_to_str(uri)
    user_workspace = Ezagent.URI.entity_workspace_uri(Ezagent.URI.new!(uri_str))

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.change(%{
        uri: uri_str,
        password_hash: nil,
        # NO default_caps — read-only-by-construction. The only caps written are
        # the explicit narrow grants the caller supplies (default none).
        caps_json: encode_caps(caps),
        workspace_uri: URI.to_string(user_workspace),
        # #154 spec 甲 — the anonymous-viewer mint is UNCONFIRMED. This (not the
        # `anon-` URI name) is the source of truth for anon-ness.
        confirmed: false
      })
      |> Ecto.Changeset.unique_constraint(:uri, name: :users_uri_index)

    insert_with_derivation(
      changeset,
      Ezagent.URI.new!(uri_str),
      user_workspace,
      :workspace_member
    )
  end

  defp insert_with_derivation(changeset, child_uri, parent_uri, edge_kind) do
    attempt_id = Ezagent.Provenance.DerivationEdges.new_attempt_id()

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, changeset)
    |> Ecto.Multi.run(:derivation_edge, fn _repo, _changes ->
      case Ezagent.Provenance.DerivationEdges.record_derivation_edge(
             child_uri,
             parent_uri,
             edge_kind,
             attempt_id
           ) do
        :ok -> {:ok, :recorded}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: row}} -> {:ok, decode(row)}
      {:error, :user, changeset, _changes} -> {:error, changeset}
      {:error, :derivation_edge, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Delete a User by URI. Returns `:ok` (idempotent — a missing row is `:ok`).
  Used by the anon-User GC sweeper (issue #51) to reap an abandoned anon-User
  after it has left its session.

  Revocation precedes cleanup. The durable derivation closure is fenced in one
  write, the user and every owned/lineage agent advance generation, and stale
  self-licenses are removed before each fence is cleared. Structural resources
  survive: workspaces transfer to admin; sessions and templates transfer to
  their workspace owner (or admin when that owner is also being deleted).

  Only after that durable invalidation/re-ownership boundary succeeds do we
  tear down the User Kind and delete the provisioning row. A process cleanup
  failure can therefore never make stale authority valid again; D-3 owns the
  honest-terminate/reap convergence policy.
  """
  @spec delete(URI.t() | String.t()) :: :ok | {:error, term()}
  def delete(uri) do
    Ezagent.Lifecycle.with_entity_transition(uri, fn ->
      principal = uri |> uri_to_str() |> Ezagent.URI.new!() |> Ezagent.URI.instance()

      case Repo.get_by(__MODULE__, uri: URI.to_string(principal)) do
        nil ->
          :ok

        row ->
          if self_target?(principal) do
            {:error, :cannot_self_destroy}
          else
            with :ok <- Ezagent.Identity.Offboarding.DeleteUser.invalidate(principal),
                 :ok <- Ezagent.Identity.Offboarding.DeleteUser.cleanup(principal),
                 {:ok, _deleted} <- Repo.delete(row) do
              :ok
            end
          end
      end
    end)
  end

  defp self_target?(principal) do
    match?({:ok, pid} when pid == self(), Ezagent.KindRegistry.lookup(principal))
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

  @doc """
  Soft-disable a user by URI.

  Idempotent: disabling an already-disabled user preserves the original
  timestamp/reason and returns the current decoded row.
  """
  @spec disable(URI.t() | String.t(), URI.t() | String.t(), String.t() | nil) ::
          {:ok, decoded()} | {:error, :not_found}
  def disable(uri, disabled_by, reason \\ nil) do
    case Repo.get_by(__MODULE__, uri: uri_to_str(uri)) do
      nil ->
        {:error, :not_found}

      %__MODULE__{disabled_at: %DateTime{}} = row ->
        {:ok, decode(row)}

      row ->
        row
        |> Ecto.Changeset.change(%{
          disabled_at: DateTime.utc_now(),
          disabled_by: uri_to_str(disabled_by),
          disabled_reason: normalize_reason(reason)
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, decode(updated)}
          {:error, _changeset} -> {:error, :not_found}
        end
    end
  end

  @doc "Re-enable a soft-disabled user. Idempotent for already-enabled users."
  @spec enable(URI.t() | String.t()) :: {:ok, decoded()} | {:error, :not_found}
  def enable(uri) do
    case Repo.get_by(__MODULE__, uri: uri_to_str(uri)) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Ecto.Changeset.change(%{
          disabled_at: nil,
          disabled_by: nil,
          disabled_reason: nil
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, decode(updated)}
          {:error, _changeset} -> {:error, :not_found}
        end
    end
  end

  @doc "Whether a user is soft-disabled. Unknown users fail closed as disabled."
  @spec disabled?(URI.t() | String.t()) :: boolean()
  def disabled?(uri) do
    case Repo.get_by(__MODULE__, uri: uri_to_str(uri)) do
      %__MODULE__{disabled_at: %DateTime{}} -> true
      nil -> true
      _ -> false
    end
  end

  @doc """
  Mark a user's email as verified (task #87). Returns `{:ok, decoded}` or
  `{:error, :not_found}`. Idempotent — re-marking a verified user is a no-op
  update. Independent of `confirmed` (anon-ness).
  """
  @spec mark_email_verified(URI.t() | String.t()) :: {:ok, decoded()} | {:error, :not_found}
  def mark_email_verified(uri) do
    case Repo.get_by(__MODULE__, uri: uri_to_str(uri)) do
      nil ->
        {:error, :not_found}

      row ->
        row
        |> Ecto.Changeset.change(%{email_verified: true})
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
      %__MODULE__{disabled_at: %DateTime{}} ->
        Bcrypt.no_user_verify()
        false

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
  Whether `uri` is a CONFIRMED user (#154 spec 甲). `false` for an unconfirmed
  (anonymous) user OR an absent row (fail-closed: unknown ⇒ unconfirmed). This is
  the source of truth for anon-ness — preferred over the `anon-` URI name-prefix.
  """
  @spec confirmed?(URI.t() | String.t()) :: boolean()
  def confirmed?(uri) do
    case get_by_uri(uri) do
      %{confirmed: confirmed} -> confirmed == true
      _ -> false
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
      caps: decode_caps(row.caps_json),
      # `confirmed` may be absent on a row read before the column existed
      # (defensive): treat nil as false (unconfirmed).
      confirmed: row.confirmed == true,
      # task #87 — defensive nil → false (unverified).
      email_verified: row.email_verified == true,
      disabled_at: row.disabled_at,
      disabled_by: row.disabled_by,
      disabled_reason: row.disabled_reason
    }
  end

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_reason(_), do: nil

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

  # #51 codex P2 — the `anon-` user-name prefix is RESERVED for the
  # anonymous-viewer mint (`create_read_only/1`, which does its OWN insert and
  # is exempt). `create/3` (the normal, default-caps path) rejects it so the
  # prefix reliably identifies anon users for `Session.Membership.anon_member?/1`.
  @anon_name_prefix "anon-"
  defp reserved_anon_name?(uri_str) when is_binary(uri_str) do
    case uri_str |> String.split("/") |> List.last() do
      nil -> false
      name -> String.starts_with?(name, @anon_name_prefix)
    end
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
