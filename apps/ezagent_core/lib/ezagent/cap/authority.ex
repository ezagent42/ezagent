defmodule Ezagent.Cap.Authority do
  @moduledoc """
  Framework-owned per-Kind capability authority compartment.

  The authority is private top-level `Ezagent.Kind.Server` state. It is never
  merged into a Behavior slice, handler context, snapshot, event, log, or
  generic admin listing. Callers outside the framework receive capability
  artifacts, never key material.

  This boundary is defined for the reviewed-code (Path A) threat model. Code
  already executing maliciously inside the BEAM is explicitly out of scope.
  """

  alias Ezagent.Cap.Signing
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindCapAuthority
  alias EzagentCore.Repo

  @derive {Inspect, except: [:private_key]}
  @enforce_keys [:uri, :kind_type, :generation, :key_id, :public_key, :private_key]
  defstruct [:uri, :kind_type, :generation, :key_id, :public_key, :private_key]

  @opaque t :: %__MODULE__{
            uri: URI.t(),
            kind_type: atom(),
            generation: pos_integer(),
            key_id: String.t(),
            public_key: binary(),
            private_key: binary()
          }

  @doc false
  @spec open(URI.t(), atom()) :: {:ok, t()} | {:error, term()}
  def open(%URI{} = uri, kind_type) when is_atom(kind_type),
    do: open(uri, kind_type, :unknown)

  @doc false
  @spec open(URI.t(), atom(), :created | :existed | :unknown) ::
          {:ok, t()} | {:error, term()}
  def open(%URI{} = uri, kind_type, create_freshness)
      when is_atom(kind_type) and create_freshness in [:created, :existed, :unknown] do
    uri_string = Ezagent.URI.stable_key(uri)

    case KindCapAuthority.active(uri_string) do
      %KindCapAuthority{} = row -> {:ok, from_row(row)}
      nil -> genesis(uri, kind_type, create_freshness)
    end
  end

  @doc false
  @spec anchor(URI.t()) :: {:ok, Capability.t()} | {:error, :not_found}
  def anchor(%URI{} = uri) do
    case KindCapAuthority.active(Ezagent.URI.stable_key(uri)) do
      %KindCapAuthority{anchor: anchor} -> {:ok, :erlang.binary_to_term(anchor, [:safe])}
      nil -> {:error, :not_found}
    end
  end

  @doc false
  @spec current_generation(URI.t()) :: {:ok, pos_integer()} | :error
  def current_generation(%URI{} = uri) do
    case KindCapAuthority.active(Ezagent.URI.stable_key(Ezagent.URI.instance(uri))) do
      %KindCapAuthority{generation: generation} when is_integer(generation) and generation > 0 ->
        {:ok, generation}

      nil ->
        :error
    end
  rescue
    _ -> :error
  end

  @doc false
  @spec current_process_generation(URI.t()) :: {:ok, pos_integer()} | :error
  def current_process_generation(%URI{} = target) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{uri: uri, generation: generation} ->
        if same_uri?(uri, Ezagent.URI.instance(target)), do: {:ok, generation}, else: :error

      nil ->
        :error
    end
  end

  @doc false
  # STRUCTURAL root un-killability (#1627 B1-hybrid, codex r3 hardening 1).
  # `retire` DEACTIVATES the active authority row (no re-mint) — a bare
  # gen-retiring path. For the genesis admin that is a soft kill, so reject the
  # root here: "retire the admin's authority" is then impossible from EVERY
  # caller (restoring the stated invariant "every retire path funnels through the
  # guard"). The destroy chokepoint (`Lifecycle.do_destroy`) rejects the admin
  # target EARLIER, before any teardown, so no legitimate flow reaches here with
  # the root and the `:ok`-matching callers never see the error — this reject is
  # the structural belt for any future direct caller.
  @spec retire(URI.t()) :: :ok | {:error, :root_authority_immutable}
  def retire(%URI{} = uri) do
    if root?(uri) do
      {:error, :root_authority_immutable}
    else
      KindCapAuthority.retire_active(Ezagent.URI.stable_key(uri))
    end
  end

  @doc false
  @spec regenesis(URI.t(), atom(), map()) :: {:ok, t()} | {:error, term()}
  # The pre-G-1 URI-equality entry is deliberately closed. Operator bumps must
  # carry a full authenticated context and pass the target's grant/manage cap.
  def regenesis(%URI{}, kind_type, %URI{}) when is_atom(kind_type),
    do: {:error, :cap_context_required}

  def regenesis(%URI{} = uri, kind_type, %{} = ctx) when is_atom(kind_type) do
    holder = Map.get(ctx, :authenticated_principal)
    caps = Map.get(ctx, :caps, MapSet.new()) || MapSet.new()

    with %URI{} = holder <- holder,
         {:ok, _manage_cap} <- Ezagent.Cap.authorize(holder, caps, manage_needed(uri, kind_type)) do
      regenesis(uri, kind_type)
    else
      nil -> {:error, :authenticated_principal_required}
      {:error, _reason} = error -> error
      _ -> {:error, :authenticated_principal_required}
    end
  end

  @doc false
  @spec regenesis(URI.t(), atom()) :: {:ok, t()} | {:error, term()}
  def regenesis(%URI{} = uri, kind_type) when is_atom(kind_type) do
    # STRUCTURAL un-killability of the authority root (#1627 B1-hybrid). A BARE
    # generation bump of the genesis admin is a REVOCATION — it strands the root's
    # self-license at a retired generation with NO re-mint, bricking the sole §3
    # boot-seed holder. EVERY bare gen-bump path funnels through here (`regenesis/3`
    # → `/2`; `delete_user` → `/2`; the `revoke_all_to` handler → `/3` → `/2`), so
    # rejecting the root here makes "deliberately-killed admin" an UNREACHABLE
    # state. The ONLY sanctioned way to advance the root's generation is
    # `rotate_root_generation/2` (the atomic admin key-rotation operator command,
    # which re-mints the self-license in the SAME transaction — no stale-gen
    # window). Genesis (`open(:created)` on historical) is a re-mint path, not a
    # kill — it mints a fresh self-license in the same `create/1` — and is a
    # separate function, not `regenesis`.
    if root?(uri) do
      {:error, :root_authority_immutable}
    else
      do_regenesis(uri, kind_type)
    end
  end

  @doc false
  # SANCTIONED root-authority rotation — the ONLY path that may advance the
  # genesis admin's generation. Root-RESTRICTED (a non-root caller is rejected, so
  # this can never degrade into a general `regenesis` bypass). The caller MUST
  # re-mint the root's self-license under the returned authority in the SAME
  # transaction; `Ezagent.Identity.AdminKeyRotation` is the sole caller and the
  # Z-1 recredential ratchet enforces that.
  @spec rotate_root_generation(URI.t(), atom()) :: {:ok, t()} | {:error, term()}
  def rotate_root_generation(%URI{} = uri, kind_type) when is_atom(kind_type) do
    if root?(uri), do: do_regenesis(uri, kind_type), else: {:error, :not_root_authority}
  end

  defp do_regenesis(uri, kind_type) do
    uri_string = Ezagent.URI.stable_key(uri)

    Repo.transaction(fn ->
      :ok = KindCapAuthority.retire_active(uri_string)
      next_generation = next_generation(uri_string)

      case insert_generation(uri, kind_type, next_generation) do
        {:ok, authority} -> authority
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, authority} -> {:ok, authority}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec sign(t(), Capability.t()) :: Capability.t()
  def sign(%__MODULE__{} = authority, %Capability{} = cap) do
    cap = %{cap | key_id: authority.key_id}

    signature =
      :crypto.sign(
        :eddsa,
        :none,
        Signing.signing_payload(cap),
        [authority.private_key, :ed25519]
      )

    %{cap | signature: signature}
  end

  @doc false
  @spec verify(t(), Capability.t(), URI.t()) :: boolean()
  def verify(
        %__MODULE__{} = authority,
        %Capability{signature: signature, grantee_uri: presenter} = cap,
        %URI{} = presenter
      )
      when is_binary(signature) do
    cap.key_id == authority.key_id and
      verify_signature(authority.public_key, cap, presenter)
  end

  def verify(%__MODULE__{}, %Capability{}, %URI{}), do: false

  @doc false
  @spec verify_durable_current(URI.t(), Capability.t(), URI.t()) :: boolean()
  def verify_durable_current(
        %URI{} = target,
        %Capability{grantee_uri: %URI{} = grantee} = cap,
        %URI{} = receiver
      ) do
    with {:ok, artifact_target} <- target_uri(cap),
         true <- same_uri?(artifact_target, target),
         true <- same_uri?(grantee, receiver),
         %{generation: generation, public_key: public_key} <-
           KindCapAuthority.active_public(Ezagent.URI.stable_key(target)),
         expected_key_id <- key_id(public_key, generation),
         true <- cap.key_id == expected_key_id do
      verify_signature(public_key, cap, receiver)
    else
      _reason -> false
    end
  end

  def verify_durable_current(%URI{}, %Capability{}, %URI{}), do: false

  @doc false
  @spec with_current(t(), (-> result)) :: result when result: term()
  def with_current(%__MODULE__{} = authority, fun) when is_function(fun, 0) do
    key = {__MODULE__, :current}
    previous = Process.put(key, authority)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(key), else: Process.put(key, previous)
    end
  end

  @doc false
  @spec verify_current(Capability.t(), URI.t()) :: boolean()
  def verify_current(%Capability{} = cap, %URI{} = presenter) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{} = authority -> verify(authority, cap, presenter)
      nil -> false
    end
  end

  @doc """
  Verify a cap against the TARGET's CURRENT active authority row, read fresh
  from the DB on every call (unified-revocation Phase F-1, DECISION #2 / MF4).

  This is the revocation-correct verify: `regenesis/3` flips the DB active
  row atomically, so a gen-bumped target's old-gen caps fail immediately —
  independent of whether the target's process is alive or busy. The current
  `key_id` comes from the committed active row (never the process-dict
  `verify_current/2` authority, which a live process caches stale-on-bump);
  the public key for that immutable `key_id` is memoized in
  `Ezagent.Cap.AuthorityCache` (read-through to the durable row on a miss).

  Fail-closed: a target with no active row, an unreadable store, a `key_id`
  mismatch, a presenter other than the grantee, or a bad signature all
  return `false`.
  """
  @spec verify_against_current(Capability.t(), URI.t(), URI.t()) :: boolean()
  def verify_against_current(
        %Capability{signature: signature, grantee_uri: presenter} = cap,
        %URI{} = presenter,
        %URI{} = target
      )
      when is_binary(signature) do
    with {:ok, current_key_id} <- current_key_id(target),
         true <- cap.key_id == current_key_id,
         {:ok, public_key} <- Ezagent.Cap.AuthorityCache.public_key(current_key_id) do
      :crypto.verify(
        :eddsa,
        :none,
        Signing.signing_payload(cap),
        signature,
        [public_key, :ed25519]
      )
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def verify_against_current(%Capability{}, %URI{}, %URI{}), do: false

  @doc """
  Row-lock the TARGET's current active authority generation inside the caller's
  OPEN transaction, so a concurrent `regenesis/2` cannot rotate the generation
  between a `verify_against_current/3` check and the caller's dependent write
  (#189 PR-2, codex impl-review finding 1 — the verify/write race).

  The lock is keyed byte-identically to `current_key_id/1` (`instance |>
  stable_key`), so it serializes exactly the row `verify_against_current/3`
  reads. Returns `:ok` whether or not an active row exists — a target with no
  active row has nothing to lock and its self-license verification fails closed
  anyway. MUST be called inside a `Repo.transaction/1`; outside one a `FOR
  SHARE` locks nothing.
  """
  @spec lock_current_generation(URI.t()) :: :ok
  def lock_current_generation(%URI{} = target) do
    target |> Ezagent.URI.instance() |> Ezagent.URI.stable_key() |> KindCapAuthority.lock_active()
    :ok
  end

  @doc """
  Whether `uri` has ANY `kind_cap_authorities` history — an active OR retired
  generation row (#189 PR-3 FIX 3). `regenesis/2` RETIRES the active row
  (`retire_active/1`, an `UPDATE ... SET active=false`) and INSERTS a new
  generation; it never DELETES, so a revoked / rotated principal keeps its
  history. This is therefore the durable "this URI's authority was ever opened"
  witness that survives a store-row deletion — the fact the ephemeral
  ever-created signal uses to deny a re-mint on an absent store row. Fail-closed
  (a read error resolves to `true`: an unreadable history must never be read as
  "never created" and license a fresh genesis).
  """
  @spec has_authority_history?(URI.t()) :: boolean()
  def has_authority_history?(%URI{} = uri) do
    uri |> Ezagent.URI.instance() |> Ezagent.URI.stable_key() |> KindCapAuthority.list() != []
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  @doc """
  Error-aware authority-history read: `{:ok, boolean()}` on a successful read,
  `:error` on a read failure. Unlike `has_authority_history?/1` (which fails OPEN
  — an unreadable history resolves to `true` so a genesis is never licensed on a
  transient read error), callers that must FAIL CLOSED on an unreadable history
  (e.g. `Ezagent.Identity.PreEpochRemint`, which permits a re-mint only for a
  principal with confirmed authority history) use THIS and require `{:ok, true}`.
  """
  @spec has_authority_history_result?(URI.t()) :: {:ok, boolean()} | :error
  def has_authority_history_result?(%URI{} = uri) do
    {:ok,
     uri |> Ezagent.URI.instance() |> Ezagent.URI.stable_key() |> KindCapAuthority.list() != []}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc """
  The number of authority GENERATIONS `uri` has ever held (active + retired).
  `> 1` means the authority was `regenesis/2`'d at least once — i.e. the
  principal was REVOKED (a revocation retires the active row and inserts a new
  generation). #189 PR-3 FIX 4 uses this so the Session self-license migration
  refuses to mint an `active` self-license for a previously-revoked session
  (minting under the current generation would pass `verified/2` by construction,
  so gen-gating cannot catch it — the gate must be at the mint). Fail-closed:
  a read error returns a sentinel `> 1` so an unreadable history is never read
  as "never revoked".
  """
  @spec generation_count(URI.t()) :: non_neg_integer()
  def generation_count(%URI{} = uri) do
    uri
    |> Ezagent.URI.instance()
    |> Ezagent.URI.stable_key()
    |> KindCapAuthority.list()
    |> length()
  rescue
    _ -> 2
  catch
    _, _ -> 2
  end

  defp current_key_id(%URI{} = target) do
    target_string = target |> Ezagent.URI.instance() |> Ezagent.URI.stable_key()

    case KindCapAuthority.active(target_string) do
      %KindCapAuthority{key_id: key_id} -> {:ok, key_id}
      nil -> :error
    end
  end

  @doc false
  @spec current_target?(URI.t()) :: boolean()
  def current_target?(%URI{} = target) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{uri: uri} -> same_uri?(uri, Ezagent.URI.instance(target))
      nil -> false
    end
  end

  @doc false
  @spec current_kind_type() :: {:ok, atom()} | {:error, :authority_unavailable}
  def current_kind_type do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{kind_type: kind_type} -> {:ok, kind_type}
      nil -> {:error, :authority_unavailable}
    end
  end

  @doc false
  @spec issue_current(Ezagent.Cap.Grant.intent()) :: {:ok, Capability.t()} | {:error, term()}
  def issue_current(%Ezagent.Cap.Grant{} = intent) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{} = authority ->
        case Ezagent.Cap.Grant.issue(authority, intent) do
          %Capability{} = artifact -> {:ok, artifact}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, :authority_unavailable}
    end
  end

  @doc false
  @spec issue_self_license_current(Ezagent.Cap.Grant.intent()) ::
          {:ok, Capability.t()} | {:error, term()}
  def issue_self_license_current(%Ezagent.Cap.Grant{} = intent) do
    case Process.get({__MODULE__, :current}) do
      %__MODULE__{} = authority -> Ezagent.Cap.Grant.issue_self_license(authority, intent)
      nil -> {:error, :authority_unavailable}
    end
  end

  @doc false
  @spec target_uri(Capability.t()) :: {:ok, URI.t()} | {:error, :concrete_target_required}
  def target_uri(%Capability{instance: %URI{} = instance}),
    do: {:ok, Ezagent.URI.instance(instance)}

  def target_uri(%Capability{}), do: {:error, :concrete_target_required}

  defp manage_needed(uri, kind_type) do
    %{
      kind: kind_type,
      behavior: Ezagent.Cap.Grant,
      action: :grant,
      instance: Ezagent.URI.instance(uri),
      workspace_uri: Capability.workspace_of(uri)
    }
  end

  defp key_id(public_key, generation) do
    fingerprint = :crypto.hash(:sha256, public_key) |> Base.url_encode64(padding: false)
    "kind-g#{generation}:#{fingerprint}"
  end

  defp verify_signature(public_key, %Capability{signature: signature} = cap, %URI{})
       when is_binary(public_key) and is_binary(signature) do
    :crypto.verify(
      :eddsa,
      :none,
      Signing.signing_payload(cap),
      signature,
      [public_key, :ed25519]
    )
  end

  defp verify_signature(_public_key, %Capability{}, %URI{}), do: false

  defp genesis(uri, kind_type, create_freshness) do
    uri_string = Ezagent.URI.stable_key(uri)

    Repo.transaction(fn ->
      case KindCapAuthority.list(uri_string) do
        [] when create_freshness == :existed ->
          # #189 PR-2 fail-closed (codex spec-review F1): a URI that presents
          # itself as ALREADY-EXISTING (`:existed` — an ordinary open / cold
          # restart) but whose authority history is EMPTY must NOT have a
          # generation minted at runtime. Silently inserting generation 1 here
          # would birth signing authority for a principal whose creation was
          # never authorized (or whose authority was intentionally purged) —
          # exactly the regenesis-resurrection vector. Genesis stays reserved
          # for genuine creation (`:created`) and the legacy `:unknown` open.
          #
          # DEPLOY PRECONDITION (codex impl-review finding 2 — FLAGGED, unresolved
          # here): this guard REGRESSES a pre-authority durable entity
          # (`ever_created` snapshot, NO `kind_cap_authorities` row — created
          # before the #1457 cap-signing rollout and not re-opened since): its
          # cold restart hits this rollback and the Kind terminates. It is safe
          # to deploy ONLY if every durable Lifecycle entity in the target DB has
          # already acquired an authority row (opened once since #1457). If that
          # cannot be evidenced, a GOVERNED authority-history adoption is required
          # first, or this guard must land with PR-3's cutover instead. See
          # docs/superpowers/plans/2026-07-29-189-pr2-migration.md → "FIX 3".
          Repo.rollback(:no_authority_for_existing)

        [] ->
          unless same_uri?(uri, admin_uri()) do
            case KindCapAuthority.active(Ezagent.URI.stable_key(admin_uri())) do
              nil ->
                case insert_generation(admin_uri(), :user, 1) do
                  {:ok, _admin_authority} -> :ok
                  {:error, reason} -> Repo.rollback(reason)
                end

              _row ->
                :ok
            end
          end

          case insert_generation(uri, kind_type, 1) do
            {:ok, authority} -> authority
            {:error, reason} -> Repo.rollback(reason)
          end

        _historical when create_freshness == :created ->
          next_generation = next_generation(uri_string)

          case insert_generation(uri, kind_type, next_generation) do
            {:ok, authority} -> authority
            {:error, reason} -> Repo.rollback(reason)
          end

        _historical ->
          Repo.rollback(:regenesis_required)
      end
    end)
    |> case do
      {:ok, authority} -> {:ok, authority}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_generation(uri, kind_type, generation) do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    authority = %__MODULE__{
      uri: uri,
      kind_type: kind_type,
      generation: generation,
      key_id: key_id(public_key, generation),
      public_key: public_key,
      private_key: private_key
    }

    anchor =
      %Capability{
        kind: kind_type,
        behavior: :any,
        action: :grant,
        instance: uri,
        workspace_uri: Ezagent.Capability.workspace_of(uri),
        granted_by: admin_uri(),
        granted_at: DateTime.utc_now(),
        grantee_uri: admin_uri()
      }
      |> then(&sign(authority, &1))

    attrs = %{
      uri: Ezagent.URI.stable_key(uri),
      generation: generation,
      kind_type: Atom.to_string(kind_type),
      key_id: authority.key_id,
      public_key: public_key,
      private_key: private_key,
      anchor: :erlang.term_to_binary(anchor, [:deterministic]),
      sealed: true,
      active: true,
      inserted_at: DateTime.utc_now()
    }

    case KindCapAuthority.insert(attrs) do
      {:ok, _row} -> {:ok, authority}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp from_row(%KindCapAuthority{} = row) do
    %__MODULE__{
      uri: Ezagent.URI.new!(row.uri),
      kind_type: String.to_existing_atom(row.kind_type),
      generation: row.generation,
      key_id: row.key_id,
      public_key: row.public_key,
      private_key: row.private_key
    }
  end

  defp next_generation(uri_string) do
    uri_string
    |> KindCapAuthority.list()
    |> Enum.map(& &1.generation)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp admin_uri, do: Ezagent.URI.user(:system, :admin)
  defp same_uri?(left, right), do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)

  # The authority root — the canonical genesis admin, structurally un-killable
  # (#1627 B1-hybrid). Hardcoded to `admin_uri/0` (no config seam).
  defp root?(%URI{} = uri), do: same_uri?(uri, admin_uri())
  defp root?(_), do: false
end
