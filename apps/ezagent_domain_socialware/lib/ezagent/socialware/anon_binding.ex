defmodule Ezagent.Socialware.AnonBinding do
  @moduledoc """
  Ecto schema + context for `socialware_anon_bindings` — the anon external-user
  binding table (issue #51, design §3.4 / OQ-4).

  A row maps one anonymous external-user (`entity://<ws>/user/anon-<random>`,
  minted read-only by `Ezagent.Socialware.AnonUser`) to the public socialware
  session it VIEWS, carrying the `last_seen_at` that the 48h GC sweeps on. The table
  is BOTH the GC index AND the cookie→entity resolver.

  ## The two staged consumers

  This module is the persistence foundation; its consumers land in follow-up PRs
  (the foundation is shipped first because the alternative — a partial GC reap that
  deletes the `users` row but does NOT `chat.leave` the session — would dangle
  membership state, and a correct reap is an atomic cross-domain operation that
  touches the session domain; see the design and `AnonUser.GC`):

  - **the public-route controller (§4.1)** — `touch/3` on first-open (insert) and on
    a returning visitor (bump `last_seen_at`); `get/1` to resolve a verified cookie
    back to its anon-User (the controller compares the row's `session_uri` to the
    requested session before reuse);
  - **`Ezagent.Socialware.AnonUser.GC.sweep/1` (§3.4)** + the login-replacement path
    (§4.4) — `list_expired/2` to find abandoned anon-Users, `delete/1` to reap.

  ## Key = entity_uri (not a stored cookie token)

  Design §6 settled the `socialware_anon` cookie as a SIGNED Phoenix.Token carrying
  `{external_user_name, session_uri}` — self-describing + integrity-checked, so
  resolution is "verify cookie → reconstruct the `entity://` URI → look it up". No
  cookie secret needs persisting; one anon-User ⇄ one binding, so `entity_uri` is the
  primary key (reconciling OQ-4's `cookie_id_hash` sketch with §6).

  ## Workspace is DERIVED, never supplied

  `touch/3` derives `workspace_uri` from the session via `Ezagent.URI.workspace_of/1`
  rather than taking it as an argument, so an anon binding can never carry a
  workspace foreign to the session it views (invariant #14 — per-tenant tables carry
  `workspace_uri NOT NULL`). A non-session `session_uri` fails closed (no row).

  **Pure data module.** Mirrors `Ezagent.ExternalMirror.BindingRow`: writes via the
  shared `EzagentCore.Repo`, `delete/1` returns a structured `:deleted` / `:not_found`
  outcome so a caller can tell a real reap from a no-op (issue #53's silent-success
  removal).
  """

  use Ecto.Schema

  import Ecto.Query

  alias Ezagent.Socialware.AnonUser
  alias EzagentCore.Repo

  @primary_key {:entity_uri, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  schema "socialware_anon_bindings" do
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:last_seen_at, :utc_datetime_usec)
    # #51 §3.4 crash-safe GC claim — non-null while a sweeper is reaping this row;
    # the row survives (as the retry record) until the reap completes, then is
    # hard-deleted. See `claim_for_reaping/3`.
    field(:reaping_at, :utc_datetime_usec)
    # anon-user PR-2 — durable login-merge claim. Non-null while the anon
    # footprint is being physically relabelled to the confirmed login entity.
    field(:merging_to, :string)
    field(:merge_state, :string)

    timestamps()
  end

  @type t :: %__MODULE__{
          entity_uri: String.t(),
          session_uri: String.t(),
          workspace_uri: String.t(),
          last_seen_at: DateTime.t(),
          reaping_at: DateTime.t() | nil,
          merging_to: String.t() | nil,
          merge_state: String.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @doc """
  Record (or refresh) the binding of anon-User `entity_uri` to the public
  `session_uri`, stamping `last_seen_at` = `now`.

  First open → inserts the row (`workspace_uri` derived from `session_uri`, never
  supplied). Returning visitor (same `entity_uri`) → bumps `last_seen_at`/`updated_at`
  via an `entity_uri`-conflict upsert; `session_uri`/`workspace_uri` are unchanged
  (one anon-User is bound to one session for life).

  ## Fail-closed write contract

  The GC + login-replacement consumers `chat.leave` + DELETE the `users` row named
  by a binding, so a bad row is a durable data-loss / tenant-isolation hazard, not a
  rejected request. `touch/3` therefore rejects (no row written) unless ALL hold:

  - `entity_uri` is an **anon-User** URI (`AnonUser.anon_uri?/1`) — a real principal
    can never acquire a binding that would later get its `users` row reaped;
  - `entity_uri`'s workspace **equals the session's** workspace — an anon-User views
    only a session in its own tenant (matches `AnonUser.mint/1`, which mints the
    entity in the session's workspace);
  - any EXISTING row for `entity_uri` is bound to the **same** `session_uri` — a
    same-entity / different-session touch is a bug or a replayed cookie, never a
    legitimate bump (one anon-User ⇄ one session for life), so it is refused rather
    than silently re-pointed.

  A non-`session://` `session_uri` also fails closed (`{:error, {:not_a_session, _}}`).

  The session-match guard is enforced at the **DB write boundary**, not a racy
  pre-read: the `entity_uri`-conflict update only fires `WHERE session_uri =` the
  attempted session, so a concurrent first-touch of the same entity against a
  different session leaves the stored row untouched (the conditional update is a
  no-op); a post-write re-read then returns `{:error, {:session_mismatch, _}}` rather
  than a spurious success. (Under concurrency Postgres serialises the two racers on
  the row / unique index; the loser's conditional update matches no row and is a
  no-op, so it falls to the mismatch path — the atomic write boundary, not any
  single-writer property of the store, is what orders them.)
  """
  @spec touch(URI.t(), URI.t(), DateTime.t()) :: {:ok, t()} | {:error, term()}
  def touch(%URI{} = entity_uri, %URI{scheme: "session"} = session_uri, %DateTime{} = now) do
    with {:ok, workspace_uri} <- session_workspace(session_uri),
         :ok <- validate_anon(entity_uri),
         :ok <- validate_same_workspace(entity_uri, workspace_uri) do
      upsert(entity_uri, session_uri, workspace_uri, now)
    end
  end

  def touch(%URI{}, %URI{} = session_uri, %DateTime{}),
    do: {:error, {:not_a_session, session_uri}}

  defp upsert(entity_uri, session_uri, workspace_uri, now) do
    entity_str = URI.to_string(entity_uri)
    session_str = URI.to_string(session_uri)

    # Conditional conflict update: bump last_seen ONLY when the stored row already
    # names this session AND is not being reaped. A conflicting row for a DIFFERENT
    # session is left untouched (no-op), so the write boundary — not a TOCTOU
    # pre-read — is what fails closed. The `reaping_at IS NULL` guard (#51 §3.4)
    # means a row a GC sweeper has CLAIMED cannot be refreshed out from under the
    # reap: its `last_seen_at` stays old so the stuck-reap retry (`list_expired/2`)
    # still re-surfaces it after a crash, and the post-write re-read surfaces a
    # `{:reaping, _}` signal so the caller mints a fresh anon (§4.1a) instead of
    # reusing a binding that is being torn down.
    on_conflict =
      from(b in __MODULE__,
        where: b.session_uri == ^session_str and is_nil(b.reaping_at),
        update: [set: [last_seen_at: ^now, updated_at: ^now]]
      )

    result =
      %__MODULE__{}
      |> Ecto.Changeset.cast(
        %{
          entity_uri: entity_str,
          session_uri: session_str,
          workspace_uri: workspace_uri,
          last_seen_at: now
        },
        [:entity_uri, :session_uri, :workspace_uri, :last_seen_at]
      )
      |> Ecto.Changeset.validate_required([
        :entity_uri,
        :session_uri,
        :workspace_uri,
        :last_seen_at
      ])
      # allow_stale: a different-session conflict makes the conditional update a
      # 0-row no-op, which Ecto would otherwise raise as StaleEntryError; we want it
      # to land as {:ok, _} so the post-write re-read below can surface the mismatch.
      |> Repo.insert(on_conflict: on_conflict, conflict_target: :entity_uri, allow_stale: true)

    with {:ok, _} <- result do
      # Re-read the durable row: a no-op conditional update leaves the row in its
      # prior state, which we surface explicitly instead of the changeset's
      # optimistic value — a DIFFERENT-session conflict as a mismatch, and a row a
      # sweeper has CLAIMED (reaping_at set) as `{:reaping, _}` (#51 §3.4) so the
      # caller mints a fresh anon rather than reusing a binding being reaped.
      case get(entity_str) do
        %__MODULE__{session_uri: ^session_str, reaping_at: ra} when not is_nil(ra) ->
          {:error, {:reaping, entity_str}}

        %__MODULE__{session_uri: ^session_str} = row ->
          {:ok, row}

        %__MODULE__{session_uri: other} ->
          {:error, {:session_mismatch, other}}

        nil ->
          {:error, :write_lost}
      end
    end
  end

  defp session_workspace(session_uri) do
    case Ezagent.URI.workspace_of(session_uri) do
      %URI{} = ws -> {:ok, URI.to_string(ws)}
      :any -> {:error, {:no_workspace, session_uri}}
    end
  end

  defp validate_anon(entity_uri) do
    if AnonUser.anon_uri?(entity_uri),
      do: :ok,
      else: {:error, {:not_anon_user, entity_uri}}
  end

  defp validate_same_workspace(entity_uri, workspace_uri) do
    case Ezagent.URI.workspace_of(entity_uri) do
      %URI{} = ws ->
        if URI.to_string(ws) == workspace_uri,
          do: :ok,
          else: {:error, {:cross_workspace, entity_uri, workspace_uri}}

      :any ->
        {:error, {:cross_workspace, entity_uri, workspace_uri}}
    end
  end

  @doc """
  Fetch the binding for anon-User `entity_uri`, or `nil` if none. The cookie→entity
  resolver (§4.1a) — the caller compares the returned `session_uri` to the requested
  session before reusing the anon-User.
  """
  @spec get(URI.t() | String.t()) :: t() | nil
  def get(%URI{} = entity_uri), do: get(URI.to_string(entity_uri))
  def get(entity_uri) when is_binary(entity_uri), do: Repo.get(__MODULE__, entity_uri)

  # #51 §3.4 — a row whose `reaping_at` is older than this is treated as a STUCK
  # reap (the sweeper crashed mid-reap) and re-surfaced for retry. Generous vs a
  # real reap (milliseconds), so a healthy in-progress reap is never re-claimed by
  # a concurrent sweeper; ≤ the sweep interval, so a crashed reap is retried on the
  # next pass.
  @reaping_retry_ms 60 * 60 * 1000

  @doc """
  Every binding abandoned as of `now` — `last_seen_at` at or beyond `ttl_ms` ago —
  that is NOT currently being reaped (a stuck `reaping_at` past
  `#{@reaping_retry_ms}`ms is re-surfaced for retry).

  Mirrors the SAME `>=` boundary as `Ezagent.Socialware.AnonUser.GC.expired?/2`
  (`now - last_seen >= ttl` ⟺ `last_seen <= now - ttl`); the caller passes
  `GC.ttl_ms/0` so the TTL has a single owner. The GC sweep `claim_for_reaping/3`s
  then leaves + deletes each.
  """
  @spec list_expired(DateTime.t(), pos_integer()) :: [t()]
  def list_expired(%DateTime{} = now, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    cutoff = DateTime.add(now, -ttl_ms, :millisecond)
    retry_cutoff = DateTime.add(now, -@reaping_retry_ms, :millisecond)

    Repo.all(
      from(b in __MODULE__,
        where:
          b.last_seen_at <= ^cutoff and
            (is_nil(b.reaping_at) or b.reaping_at <= ^retry_cutoff),
        order_by: b.last_seen_at
      )
    )
  end

  @doc """
  **Compare-and-update** (NON-destructive claim): stamp `reaping_at = now` on the
  binding for `entity_uri` ONLY if it is still abandoned (`last_seen_at <= cutoff`)
  AND not already being reaped (`reaping_at` null or stale). This is the GC-safe
  reap primitive — the claim that does NOT destroy the retry index.

  Two races it closes in a single statement:

  - **Pre-claim refresh:** a candidate from `list_expired/2` can be `touch/3`ed by a
    returning visitor before the sweeper acts. The `last_seen_at <= cutoff` guard
    makes a refreshed row a `{:ok, :not_claimed}` no-op, so an *active* anon-User is
    never reaped (the original delete-as-claim concern).
  - **Concurrent / repeat claim:** the `reaping_at` guard means only ONE sweeper
    claims a row at a time; a healthy in-progress reap (within
    `#{@reaping_retry_ms}`ms) is not re-claimed, while a STUCK reap past that
    threshold is (crash recovery).

  Returns:

  - `{:ok, :claimed}` — the row was still expired + free, now marked `reaping_at`;
    the caller MAY proceed to leave + `users`-delete, then hard-`delete/1` the row
    LAST (so a crash before that re-surfaces the row for retry);
  - `{:ok, :not_claimed}` — refreshed since listing, or another sweeper holds it →
    SKIP, nothing destructive;
  - `{:error, term()}` — the update failed.

  Pass the SAME `now`/`ttl_ms` used for the `list_expired/2` that produced the
  candidate, so the cutoff is identical.
  """
  @spec claim_for_reaping(URI.t() | String.t(), DateTime.t(), pos_integer()) ::
          {:ok, :claimed | :not_claimed} | {:error, term()}
  def claim_for_reaping(%URI{} = entity_uri, %DateTime{} = now, ttl_ms),
    do: claim_for_reaping(URI.to_string(entity_uri), now, ttl_ms)

  def claim_for_reaping(entity_uri, %DateTime{} = now, ttl_ms)
      when is_binary(entity_uri) and is_integer(ttl_ms) and ttl_ms > 0 do
    cutoff = DateTime.add(now, -ttl_ms, :millisecond)
    retry_cutoff = DateTime.add(now, -@reaping_retry_ms, :millisecond)

    query =
      from(b in __MODULE__,
        where:
          b.entity_uri == ^entity_uri and b.last_seen_at <= ^cutoff and
            (is_nil(b.reaping_at) or b.reaping_at <= ^retry_cutoff),
        update: [set: [reaping_at: ^now, updated_at: ^now]]
      )

    case Repo.update_all(query, []) do
      {0, _} -> {:ok, :not_claimed}
      {n, _} when n >= 1 -> {:ok, :claimed}
    end
  rescue
    e -> {:error, e}
  end

  @merge_claimed "claimed"
  @merge_states ~w(claimed session_merged read_markers_repointed messages_relabelled caps_mounted verified)

  @doc """
  Claim an anon binding for an in-flight anon→login merge.

  The claim is durable and idempotent: the first caller stamps
  `merging_to` + `merge_state = "claimed"`, repeat callers for the same
  target get `{:ok, :already_claimed}`, and a different target is rejected.
  The row is never deleted here; it remains the repair record until the
  orchestrator verifies convergence and retires the anon.
  """
  @spec claim_for_merge(URI.t() | String.t(), URI.t(), DateTime.t()) ::
          {:ok, :claimed | :already_claimed} | {:error, term()}
  def claim_for_merge(%URI{} = entity_uri, %URI{} = to_uri, %DateTime{} = now) do
    with :ok <- validate_anon(entity_uri) do
      claim_for_merge(URI.to_string(entity_uri), to_uri, now)
    end
  end

  def claim_for_merge(entity_uri, %URI{} = to_uri, %DateTime{} = now)
      when is_binary(entity_uri) do
    with {:ok, parsed_entity_uri} <- Ezagent.URI.parse(entity_uri),
         :ok <- validate_anon(parsed_entity_uri),
         :ok <- validate_login_target(to_uri),
         {:ok, to_workspace} <- entity_workspace(to_uri) do
      do_claim_for_merge(entity_uri, URI.to_string(to_uri), to_workspace, now)
    end
  end

  defp do_claim_for_merge(entity_uri, to_str, to_workspace, now) do
    query =
      from(b in __MODULE__,
        where:
          b.entity_uri == ^entity_uri and b.workspace_uri == ^to_workspace and
            is_nil(b.reaping_at) and is_nil(b.merging_to),
        update: [set: [merging_to: ^to_str, merge_state: ^@merge_claimed, updated_at: ^now]]
      )

    case Repo.update_all(query, []) do
      {1, _} ->
        {:ok, :claimed}

      {0, _} ->
        case get(entity_uri) do
          nil ->
            {:error, :not_found}

          %__MODULE__{workspace_uri: ws} when ws != to_workspace ->
            {:error, {:cross_workspace, entity_uri, to_workspace}}

          %__MODULE__{reaping_at: reaping_at} when not is_nil(reaping_at) ->
            {:error, {:reaping, entity_uri}}

          %__MODULE__{merging_to: ^to_str} ->
            {:ok, :already_claimed}

          %__MODULE__{merging_to: other} when is_binary(other) ->
            {:error, {:merge_conflict, other}}

          %__MODULE__{} ->
            {:error, :claim_failed}
        end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Advance the durable merge state for an already-claimed binding.

  States are intentionally coarse and idempotent; a repair pass can re-run the
  step named by the current state and then advance again.
  """
  @spec mark_merge_state(URI.t() | String.t(), atom() | String.t()) ::
          {:ok, :updated | :already_state} | {:error, term()}
  def mark_merge_state(%URI{} = entity_uri, state),
    do: mark_merge_state(URI.to_string(entity_uri), state)

  def mark_merge_state(entity_uri, state) when is_binary(entity_uri) do
    with {:ok, state_str} <- normalize_merge_state(state) do
      now = DateTime.utc_now()

      query =
        from(b in __MODULE__,
          where: b.entity_uri == ^entity_uri and not is_nil(b.merging_to),
          update: [set: [merge_state: ^state_str, updated_at: ^now]]
        )

      case get(entity_uri) do
        nil ->
          {:error, :not_found}

        %__MODULE__{merging_to: nil} ->
          {:error, :not_claimed}

        %__MODULE__{merge_state: ^state_str} ->
          {:ok, :already_state}

        %__MODULE__{} ->
          case Repo.update_all(query, []) do
            {0, _} -> {:error, :not_claimed}
            {n, _} when n >= 1 -> {:ok, :updated}
          end
      end
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  In-flight merge rows that a repair pass should re-run.
  """
  @spec list_merge_repair_candidates() :: [t()]
  def list_merge_repair_candidates do
    Repo.all(
      from(b in __MODULE__,
        where:
          not is_nil(b.merging_to) and (is_nil(b.merge_state) or b.merge_state != "verified"),
        order_by: [asc: b.updated_at, asc: b.entity_uri]
      )
    )
  end

  @doc """
  Unconditionally delete the binding for `entity_uri`. Structured outcome (issue #53):

  - `{:ok, :deleted}` — a row existed and was removed;
  - `{:ok, :not_found}` — no row matched (already reaped / replaced by login);
  - `{:error, term()}` — the delete failed.

  This is the **login-replacement** reap (§4.4) — a deliberate immediate retire of
  the anon-User regardless of `last_seen_at` (the real user just logged in). The
  freshness-race-prone GC path claims via `claim_for_reaping/3` first, then hard-
  deletes with this `delete/1` LAST. Idempotent.
  """
  @spec delete(URI.t() | String.t()) :: {:ok, :deleted | :not_found} | {:error, term()}
  def delete(%URI{} = entity_uri), do: delete(URI.to_string(entity_uri))

  def delete(entity_uri) when is_binary(entity_uri) do
    case Repo.delete_all(from(b in __MODULE__, where: b.entity_uri == ^entity_uri)) do
      {0, _} -> {:ok, :not_found}
      {n, _} when n >= 1 -> {:ok, :deleted}
    end
  rescue
    e -> {:error, e}
  end

  defp validate_login_target(%URI{} = to_uri) do
    cond do
      not Ezagent.URI.type?(to_uri, :user) ->
        {:error, {:not_user, to_uri}}

      AnonUser.anon_uri?(to_uri) ->
        {:error, {:not_confirmed_login, to_uri}}

      true ->
        :ok
    end
  end

  defp entity_workspace(%URI{} = uri) do
    case Ezagent.URI.workspace_of(uri) do
      %URI{} = ws -> {:ok, URI.to_string(ws)}
      :any -> {:error, {:no_workspace, uri}}
    end
  end

  defp normalize_merge_state(state) when is_atom(state),
    do: normalize_merge_state(Atom.to_string(state))

  defp normalize_merge_state(state) when is_binary(state) do
    if state in @merge_states do
      {:ok, state}
    else
      {:error, {:invalid_merge_state, state}}
    end
  end
end
