defmodule Ezagent.Socialware.SessionSelfLicenseMigration do
  @moduledoc """
  #189 PR-3 FIX 4 — the GOVERNED migration that turns already-persisted Session
  instances into principals.

  `Ezagent.Socialware.Definition.behaviors/1` prepends
  `Ezagent.ActionSet.SelfLicense` for every NEW session, but a session INSTANCE
  persisted BEFORE the carrier landed captured its `:kind_base` behavior list
  WITHOUT SelfLicense. `BehaviorSet.effective_set/2` intersects the declared set
  against that captured list, so SelfLicense stays excluded on cold restart and
  the old session boots as a NON-principal (no `:identity` self-license). This
  migration adopts each such instance:

    1. adds `Ezagent.ActionSet.SelfLicense` to the captured `:kind_base` set;
    2. mints ONE current-generation self-license (matching `SelfLicense.create/1`
       — `behavior: SelfLicense`, `kind: current_kind_type`) into the `:identity`
       slice;
    3. persists BOTH the rewritten snapshot AND the durable identity-caps store
       row (`active`).

  ## Anti-resurrection (the FIX-3 boundary — do NOT mint for a buried session)

  A DESTROYED session leaves a MARKER-ONLY snapshot (`ever_created: true`, empty
  `state`) — `SnapshotStore.delete/1` clears the state but preserves the marker
  — and (post-FIX-3) NO active store row. That is exactly the inert
  revoked/absent state FIX 3 declares must NEVER re-mint. This migration
  therefore mints ONLY for a session that is:

    * NOT marker-only (has real durable session state);
    * NOT already a principal (idempotent — a current self-license already
      present is skipped);
    * NOT previously REVOKED — a session whose authority was `regenesis/2`'d
      (`Cap.Authority.generation_count/1 > 1`) is adopted as
      `revoked_unprovisioned` in the store, NEVER minted `active` (minting under
      the current generation would pass `verified/2` by construction, so the
      gate has to be here, at the mint).

  Governed + idempotent: an operator runs it (via
  `mix ezagent.session.self_license_migration`, or the cutover task) UNDER the
  write-quiescence fence, BEFORE the fleet-parity barrier.
  """

  require Logger

  alias Ezagent.ActionSet.{KindBase, SelfLicense}
  alias Ezagent.Cap
  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.EntityCaps.Store

  @session_kind_type "session"

  @type outcome ::
          :migrated | :already_principal | :destroyed | :not_session | :revoked_adopted
  @type result :: %{outcome() => non_neg_integer(), errors: [{String.t(), term()}]}

  @doc """
  Run the migration over every persisted session snapshot.

  Options: `:dry_run` (boolean, default `false`) — classify + report, write
  nothing. Returns a per-outcome tally plus any per-URI errors.
  """
  @spec run(keyword()) :: {:ok, result()}
  def run(opts \\ []) when is_list(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)

    result =
      session_rows()
      |> Enum.reduce(
        %{
          migrated: 0,
          already_principal: 0,
          destroyed: 0,
          not_session: 0,
          revoked_adopted: 0,
          errors: []
        },
        fn row, acc -> reduce_row(row, dry_run?, acc) end
      )

    {:ok, result}
  end

  defp reduce_row(row, dry_run?, acc) do
    case migrate_row(row, dry_run?) do
      {:ok, outcome} -> Map.update!(acc, outcome, &(&1 + 1))
      {:error, reason} -> Map.update!(acc, :errors, &[{row.uri, reason} | &1])
    end
  end

  @doc false
  # The single per-row decision. Public for the pre-cutover fixture test.
  @spec migrate_row(%KindSnapshot{}, boolean()) :: {:ok, outcome()} | {:error, term()}
  def migrate_row(%KindSnapshot{} = row, dry_run?) do
    case decode(row) do
      {:ok, state} ->
        migrate_decoded(row, state, dry_run?)

      {:error, _reason} ->
        # A DESTROYED (marker-only) session may carry an empty/undecodable state
        # binary while keeping its `ever_created` marker — it is buried and MUST
        # NOT be resurrected. Only a non-marker undecodable row is a real error.
        if row.ever_created, do: {:ok, :destroyed}, else: {:error, :undecodable}
    end
  end

  defp migrate_decoded(row, state, dry_run?) do
    uri = Ezagent.URI.new!(row.uri)

    cond do
      marker_only?(row, state) ->
        {:ok, :destroyed}

      not real_session_state?(state) ->
        {:ok, :not_session}

      already_principal?(uri, state) ->
        {:ok, :already_principal}

      # A previously-REVOKED session (its authority was regenesis'd) must NOT be
      # minted back to `active`. Record it as `revoked_unprovisioned` in the
      # store (never resurrected) and leave the snapshot untouched.
      Cap.Authority.generation_count(uri) > 1 ->
        if dry_run?, do: {:ok, :revoked_adopted}, else: adopt_revoked(uri)

      true ->
        if dry_run?, do: {:ok, :migrated}, else: migrate(row, state, uri)
    end
  end

  defp adopt_revoked(uri) do
    case Store.adopt_absent_authority_history(uri) do
      {:ok, _} -> {:ok, :revoked_adopted}
      {:error, reason} -> {:error, {:adopt_failed, reason}}
    end
  end

  defp migrate(row, state, uri) do
    with {:ok, license} <- mint_self_license(uri),
         new_state <- rewrite_state(state, license),
         :ok <- persist_snapshot(row, new_state),
         :ok <- Store.persist(uri, [license]) do
      {:ok, :migrated}
    end
  end

  # Mint ONE current-generation self-license under the session's authority,
  # byte-shaped exactly like `SelfLicense.create/1` (behavior: SelfLicense,
  # kind: the current Kind authority type — :session — NOT `URI.type/1`, which
  # is the template axis).
  defp mint_self_license(uri) do
    with {:ok, authority} <- Cap.Authority.open(uri, :session) do
      Cap.Authority.with_current(authority, fn ->
        with {:ok, kind_type} <- Cap.Authority.current_kind_type() do
          requested =
            Capability.cap(kind_type, SelfLicense, :self_license, uri, Ezagent.URI.workspace_of(uri))

          intent = Cap.Grant.freeze(uri, uri, uri, requested)
          Cap.Authority.issue_self_license_current(intent)
        end
      end)
    end
  end

  # Add SelfLicense to the captured `:kind_base` set (preserving the two-container
  # shape) and materialize the `:identity` slice with the minted license in the
  # persisted `%{state: %{caps: MapSet}}` shape a Lifecycle slice cold-loads from.
  defp rewrite_state(state, license) do
    kb_key = KindBase.state_slice()
    captured = KindBase.behaviors_in_slice(Map.get(state, kb_key)) || []
    augmented = Enum.uniq(captured ++ [SelfLicense])
    new_kb = KindBase.put_behaviors(Map.get(state, kb_key) || %{}, augmented)

    state
    |> Map.put(kb_key, new_kb)
    |> Map.put(:identity, %{state: %{caps: MapSet.new([license])}})
  end

  defp persist_snapshot(row, new_state) do
    binary =
      new_state
      |> Ezagent.Kind.Snapshot.strip_transients()
      |> :erlang.term_to_binary()

    case KindSnapshot.upsert(row.uri, row.kind_type, binary, row.version, row.workspace_uri) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, {:snapshot_persist_failed, reason}}
    end
  end

  @doc false
  # A session snapshot is a principal that MUST carry identity iff it has REAL
  # durable session state (a non-marker-only row). The barrier reuses this so a
  # destroyed (marker-only) session is not flagged as a discrepancy forever.
  @spec principal_session_row?(%KindSnapshot{}) :: boolean()
  def principal_session_row?(%KindSnapshot{kind_type: @session_kind_type} = row) do
    case decode(row) do
      {:ok, state} -> not marker_only?(row, state) and real_session_state?(state)
      _ -> false
    end
  end

  def principal_session_row?(_row), do: false

  # --- predicates ------------------------------------------------------------

  # A destroyed session: `SnapshotStore.delete/1` cleared the state but kept the
  # `ever_created` marker (the KindBaseBackfill `marker_only_clear?` precedent).
  defp marker_only?(%KindSnapshot{ever_created: true}, state), do: state == %{}
  defp marker_only?(_row, _state), do: false

  # Slice keys that mark a real (non-empty) session — sourced from the session
  # behaviors' `state_slice/0` (chat/socialware share :session/:publisher;
  # socialware adds :turns/:surface; chat may carry :external_mirror).
  @real_session_slice_keys [:session, :publisher, :chat, :turns, :surface, :external_mirror]
  defp real_session_state?(state) when is_map(state) do
    Enum.any?(@real_session_slice_keys, &Map.has_key?(state, &1))
  end

  defp already_principal?(uri, state) do
    state
    |> Map.get(:identity)
    |> caps_from_identity_slice()
    |> Store.has_current_self_license?(uri)
  end

  defp caps_from_identity_slice(%{state: %{caps: caps}}), do: to_list(caps)
  defp caps_from_identity_slice(%{caps: caps}), do: to_list(caps)
  defp caps_from_identity_slice(_), do: []

  defp to_list(%MapSet{} = set), do: MapSet.to_list(set)
  defp to_list(list) when is_list(list), do: list
  defp to_list(_), do: []

  defp session_rows do
    KindSnapshot.list_all()
    |> Enum.filter(&(&1.kind_type == @session_kind_type))
  end

  defp decode(row) do
    case KindSnapshot.decode_state(row) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, :undecodable}
      {:error, reason} -> {:error, reason}
    end
  end
end
