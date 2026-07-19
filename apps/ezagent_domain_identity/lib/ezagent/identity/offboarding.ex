defmodule Ezagent.Identity.Offboarding do
  @moduledoc """
  Owner-offboarding cascade — the owned/lineage-agent arm of
  `Ezagent.Users.tombstone/3` (task #180 / #1469).

  **Binding principle** (the plan's Part 2): deleting a user revokes ALL
  authority that derives from that user — the user's own caps/respawn AND
  the authority of every agent whose authority derives from them (owned or
  spawned-in-lineage). Revoking a principal revokes what they delegated.
  Fail closed.

  ## Enumeration (who is "derived from U")

  An agent is cascaded iff EITHER:

    * **OWNED** — the agent's recorded creator is `U`. Resolution order
      (mirrors `Ezagent.ActionSet.ApiKeys.data_owner/1` + a durable read
      for cold agents): the live `:api_keys` slice's `creator_uri`, then
      the DURABLE snapshot's `:api_keys` slice (a cold agent whose Kind is
      not running still has its creator on disk), then — as the same
      fallback `data_owner/1` uses — the direct lineage parent.
    * **LINEAGE** — `Ezagent.AgentLineage.spawned_in_lineage?(agent, U)`
      walks the FULL spawn chain, so a grandchild agent (spawned by an
      agent U spawned) is caught too (codex's "direct-parent-only" gap).

  Candidates come from a SYSTEM-SCOPE scan — `KindSnapshot.list_all/0`
  filtered to `kind_type == "agent"` (the same durable source
  `Ezagent.Entity.Agent.list_in_workspace/1` scans, unscoped) UNION every
  `AgentLineage` entry. `delete_user` is a genesis-admin global op (the
  facade's membership cascade likewise enumerates every workspace), so the
  sweep deliberately does not bound to the user's home workspace: an agent
  U spawned into another workspace is still U-derived authority. The
  SCOPING guarantee (a workspace-independent agent is never touched) comes
  from the owner/lineage FILTER, not from the enumeration breadth.

  ## Per-agent tombstone (mirrors the user tombstone — reuse, don't invent)

  One DB transaction per agent (idempotent; the sweep is retryable to
  convergence):

    1. `AgentTombstone` marker insert (the durable fail-closed record);
    2. dead-letter every PENDING `cap_delivery_outbox` row targeting the
       agent (an in-flight `absorb_cap` must never replay post-cascade);
    3. tombstone the agent's `RecipeCapBinding` (its durable signed recipe
       caps must never re-grant on a respawn);
    4. retire the agent's per-Kind signing authority
       (`Ezagent.Cap.Authority.retire/1` — no new caps can be signed);
    5. revoke every PAT minted for the agent
       (`Ezagent.Entity.Token.revoke_all_for_entity/1`).

  Post-commit, `Ezagent.Lifecycle.destroy/2` tears down the live Agent
  Kind + its snapshot (the `:identity` slice's caps + the `:api_keys`
  secrets). A teardown failure PROPAGATES (F4 — never report success with
  a live residual); the marker committed in step 1 keeps the agent fenced
  while the operator/IdempotentRetry re-runs to convergence.

  ## The fence (reads the same markers)

  `refute_tombstoned/1` is registered into `Ezagent.SpawnFence` at
  `ezagent_domain_identity` boot and is the single predicate the core
  spawn/ensure-live/Kind-start paths consult. `tombstoned_principal?/1`
  is the boolean form used by `Token.authenticate/1` and the Identity
  Lifecycle fence. Both check:

    * user → `Users.deleted?/1`;
    * agent → its own `AgentTombstone` marker, OR its recorded creator
      tombstoned, OR ANY ancestor in its lineage chain tombstoned
      (user-deleted or agent-tombstoned) — the full-chain walk that
      closes codex F1-c.
  """

  alias Ezagent.Identity.AgentTombstone
  alias Ezagent.Identity.RecipeCapBinding
  alias EzagentCore.Repo

  @lineage_max_depth 100

  # ------------------------------------------------------------------
  # Fence predicate (registered into Ezagent.SpawnFence at identity boot)
  # ------------------------------------------------------------------

  @doc """
  The `Ezagent.SpawnFence` predicate: `:ok` to admit, `{:error, …}` to
  refuse. Refuses when `uri` is a tombstoned user, a tombstoned agent, or
  an agent whose creator/lineage ancestor is tombstoned. Non-entity URIs
  (sessions, templates, workspaces, …) are always admitted.
  """
  @spec refute_tombstoned(URI.t()) :: :ok | {:error, {:principal_tombstoned, URI.t()}}
  def refute_tombstoned(%URI{scheme: "entity"} = uri) do
    if tombstoned_principal?(uri) do
      {:error, {:principal_tombstoned, Ezagent.URI.instance(uri)}}
    else
      :ok
    end
  rescue
    # Test-sandbox artifact, NOT a tombstone signal: in `MIX_ENV=test` the
    # SQL sandbox runs in `:manual` mode, and a caller WITHOUT a checked-out
    # connection (plain `ExUnit.Case` processes exercising the spawn
    # registry — not the fence itself) cannot run the predicate's DB reads.
    # Admit rather than fail every spawn: the spawn hot path must not
    # REQUIRE a DB connection. A real tombstone is still refused everywhere
    # the check runs with DB access — every production path (the pool has
    # no ownership sandbox) and every offboarding test (DataCase checks
    # out). No other exception is rescued: a genuine DB failure in
    # production propagates and fails the spawn CLOSED via
    # `Ezagent.SpawnFence`'s crash-safe wrapper.
    DBConnection.OwnershipError -> :ok
  end

  def refute_tombstoned(%URI{}), do: :ok

  @doc """
  Whether `uri` is a tombstoned principal — a deleted user, a tombstoned
  agent, or an agent whose authority derives from a tombstoned principal
  (creator or any lineage ancestor). Non-entity URIs are never tombstoned.
  """
  @spec tombstoned_principal?(URI.t()) :: boolean()
  def tombstoned_principal?(%URI{scheme: "entity"} = uri) do
    cond do
      Ezagent.URI.type?(uri, :user) ->
        Ezagent.Users.deleted?(uri)

      Ezagent.URI.type?(uri, :agent) ->
        agent_tombstoned?(uri)

      true ->
        false
    end
  end

  def tombstoned_principal?(%URI{}), do: false

  defp agent_tombstoned?(%URI{} = agent_uri) do
    AgentTombstone.tombstoned?(agent_uri) or
      creator_tombstoned?(agent_uri) or
      lineage_tombstoned?(agent_uri)
  end

  # The recorded CREATOR (`:api_keys` slice `creator_uri`, live or durable)
  # tombstoned. Distinct from the lineage walk: a creator recorded at
  # instantiate time whose spawn predates (or lost) its lineage row.
  defp creator_tombstoned?(%URI{} = agent_uri) do
    case agent_creator(agent_uri) do
      %URI{} = creator -> user_or_agent_marker_tombstoned?(creator)
      _ -> false
    end
  end

  # Walk the FULL lineage chain (codex F1-c — the direct-parent-only gap):
  # refuse when ANY ancestor is a deleted user or a tombstoned agent.
  defp lineage_tombstoned?(%URI{} = agent_uri) do
    walk_lineage_tombstone(agent_uri, @lineage_max_depth)
  end

  defp walk_lineage_tombstone(_uri, 0), do: false

  defp walk_lineage_tombstone(%URI{} = uri, depth_left) do
    case Ezagent.AgentLineage.lookup(uri) do
      {:ok, ancestor} ->
        user_or_agent_marker_tombstoned?(ancestor) or
          walk_lineage_tombstone(ancestor, depth_left - 1)

      :error ->
        false
    end
  end

  defp user_or_agent_marker_tombstoned?(%URI{scheme: "entity"} = uri) do
    cond do
      Ezagent.URI.type?(uri, :user) -> Ezagent.Users.deleted?(uri)
      Ezagent.URI.type?(uri, :agent) -> AgentTombstone.tombstoned?(uri)
      true -> false
    end
  end

  defp user_or_agent_marker_tombstoned?(%URI{}), do: false

  @doc """
  The agent's recorded creator (`:api_keys` slice `:creator_uri`) — live
  slice first, then the DURABLE snapshot (a cold agent keeps its creator
  on disk), then the direct lineage parent (the `ApiKeys.data_owner/1`
  fallback). `%URI{}` or `nil`.
  """
  @spec agent_creator(URI.t()) :: URI.t() | nil
  def agent_creator(%URI{} = agent_uri) do
    live_creator(agent_uri) || durable_creator(agent_uri) || lineage_parent(agent_uri)
  end

  defp live_creator(%URI{} = agent_uri) do
    case Ezagent.Kind.get_slice(agent_uri, :api_keys) do
      {:ok, %{creator_uri: %URI{} = creator}} -> creator
      _ -> nil
    end
  end

  defp durable_creator(%URI{} = agent_uri) do
    case Ezagent.SnapshotStore.latest(agent_uri) do
      {:ok, %{state: state}} when is_map(state) ->
        state
        |> Map.get(:api_keys)
        |> case do
          nil -> nil
          slice -> slice |> Ezagent.Kind.SliceAccess.normalize_slice_view() |> creator_of(slice)
        end

      _ ->
        nil
    end
  end

  defp creator_of(normalized, raw_slice) do
    case normalized do
      %{creator_uri: %URI{} = creator} -> creator
      %{creator_uri: creator} when is_binary(creator) -> parse_uri(creator)
      _ -> creator_of_raw(raw_slice)
    end
  end

  # Defensive: a legacy/JSON slice with string keys (pre-`state_binary`
  # rows) — shape-flexible read, never crashes the fence.
  defp creator_of_raw(raw) when is_map(raw) do
    raw
    |> Map.get(:state, raw)
    |> case do
      state when is_map(state) ->
        case Map.get(state, :creator_uri) || Map.get(state, "creator_uri") do
          %URI{} = creator -> creator
          creator when is_binary(creator) -> parse_uri(creator)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp creator_of_raw(_), do: nil

  defp lineage_parent(%URI{} = agent_uri) do
    case Ezagent.AgentLineage.lookup(agent_uri) do
      {:ok, parent} -> parent
      :error -> nil
    end
  end

  defp parse_uri(str) when is_binary(str) do
    case Ezagent.URI.parse(str) do
      {:ok, uri} -> uri
      _ -> nil
    end
  end

  # ------------------------------------------------------------------
  # Cascade — enumerate + tombstone every U-derived agent
  # ------------------------------------------------------------------

  @doc """
  Tombstone EVERY agent whose authority derives from `user_uri` (owned or
  spawned-in-lineage). Idempotent and convergent: each per-agent tombstone
  is itself idempotent, so re-running after a partial failure resumes
  cleanly; the FIRST failure halts and propagates (never a half-revoked
  success). Returns `:ok` when every derived agent is fully revoked.
  """
  @spec cascade_derived_agents(URI.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def cascade_derived_agents(%URI{} = user_uri, deleted_by, reason) do
    user_uri
    |> derived_agents()
    |> Enum.reduce_while(:ok, fn agent_uri, :ok ->
      case tombstone_agent(agent_uri, deleted_by, reason) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Enumerate the URIs of every agent whose authority derives from
  `user_uri` — OWNED (`creator_uri == user`) or LINEAGE
  (`spawned_in_lineage?(agent, user)`). System-scope candidate scan (see
  the moduledoc for why), strict per-agent filter.
  """
  @spec derived_agents(URI.t()) :: [URI.t()]
  def derived_agents(%URI{} = user_uri) do
    user_key = user_uri |> Ezagent.URI.instance() |> Ezagent.URI.stable_key()

    candidate_agent_uris()
    |> Enum.filter(&derived_from_user?(&1, user_key, user_uri))
    |> Enum.map(&Ezagent.URI.new!/1)
    |> Enum.sort_by(&URI.to_string/1)
  end

  defp candidate_agent_uris do
    from_snapshots =
      Ezagent.Ecto.KindSnapshot.list_all()
      |> Enum.filter(fn row -> row.kind_type == "agent" end)
      |> Enum.map(fn row -> row.uri end)

    from_lineage = Ezagent.AgentLineage.list_all() |> Enum.map(fn {agent_uri, _} -> agent_uri end)

    # Live agents are covered by the snapshot scan: `Kind.Server.init/1`
    # persists the initial snapshot synchronously at every spawn, so a
    # spawn-completed agent always has a row; the lineage union also
    # catches an agent whose snapshot row was lost but whose lineage
    # survives.
    Enum.uniq(from_snapshots ++ from_lineage)
  end

  defp derived_from_user?(agent_uri_str, user_key, %URI{} = user_uri) do
    # Lineage first (pure ETS walk — cheap); the creator read (durable
    # snapshot decode) only runs for non-lineage candidates.
    case Ezagent.URI.parse(agent_uri_str) do
      {:ok, agent_uri} ->
        Ezagent.AgentLineage.spawned_in_lineage?(agent_uri, user_uri) or
          creator_is_user?(agent_uri, user_key)

      _ ->
        false
    end
  end

  defp creator_is_user?(%URI{} = agent_uri, user_key) do
    case agent_creator(agent_uri) do
      %URI{} = creator ->
        creator |> Ezagent.URI.instance() |> Ezagent.URI.stable_key() |> Kernel.==(user_key)

      _ ->
        false
    end
  end

  @doc """
  The per-agent tombstone — mirrors `Users.tombstone/3`'s shape (durable
  marker + cap-clear + outbox-cancel + teardown, idempotent, failures
  propagate). See the moduledoc for the five transactional steps.
  """
  @spec tombstone_agent(URI.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def tombstone_agent(%URI{} = agent_uri, deleted_by, reason) do
    agent_uri = Ezagent.URI.instance(agent_uri)

    txn =
      Repo.transaction(fn ->
        # 1. The durable fail-closed marker (idempotent — first tombstone wins).
        case AgentTombstone.tombstone(agent_uri, deleted_by, reason) do
          :ok -> :ok
          {:error, changeset} -> Repo.rollback({:marker_failed, changeset})
        end

        # 2. Dead-letter pending cap deliveries targeting the agent.
        case Ezagent.Cap.DeliveryOutbox.dead_letter_pending_for_target(
               agent_uri,
               :owner_deleted
             ) do
          {:ok, _dead_lettered} -> :ok
          other -> Repo.rollback({:outbox_cancel_failed, other})
        end

        # 3. Tombstone the agent's durable signed recipe binding so a
        #    respawn can never re-grant its recipe caps.
        :ok = RecipeCapBinding.tombstone_active(agent_uri)

        # 4. Retire the agent's per-Kind signing authority — no NEW caps
        #    can be signed by this Kind again (historical rows stay
        #    sealed; existing artifacts still verify against them).
        :ok = Ezagent.Cap.Authority.retire(agent_uri)

        # 5. Revoke every PAT minted for the agent.
        case Ezagent.Entity.Token.revoke_all_for_entity(agent_uri) do
          {:ok, _revoked} -> :ok
          other -> Repo.rollback({:token_revoke_failed, other})
        end

        :ok
      end)

    case txn do
      {:ok, :ok} ->
        # Post-commit teardown (F4 — propagate, never report success with
        # a live residual). The committed marker keeps the agent fenced
        # while the idempotent retry converges the teardown.
        case teardown_and_reap(agent_uri) do
          :ok -> :ok
          {:error, reason} -> {:error, {:agent_teardown_failed, agent_uri, reason}}
        end

      {:error, reason} ->
        {:error, {:agent_tombstone_failed, agent_uri, reason}}
    end
  end

  @doc """
  Tear down the entity's live Kind + snapshot via `Ezagent.Lifecycle.destroy/2`
  and verify NO slice committed inside the guard→teardown window survives
  (F2's teardown half): a snapshot row that reappeared after the destroy is
  removed by a second destroy pass; anything still standing after that is a
  propagated `{:error, {:teardown_residual, uri}}`. Shared by the user
  tombstone and the per-agent tombstone — teardown semantics must not drift.
  """
  @spec teardown_and_reap(URI.t()) :: :ok | {:error, term()}
  def teardown_and_reap(%URI{} = uri) do
    with :ok <- destroy_kind(uri),
         :ok <- remove_window_committed_slice(uri) do
      :ok
    end
  end

  defp remove_window_committed_slice(%URI{} = uri) do
    case Ezagent.Ecto.KindSnapshot.get(Ezagent.URI.stable_key(uri)) do
      nil ->
        :ok

      _residual ->
        with :ok <- destroy_kind(uri) do
          case Ezagent.Ecto.KindSnapshot.get(Ezagent.URI.stable_key(uri)) do
            nil -> :ok
            row -> {:error, {:teardown_residual, row.uri}}
          end
        end
    end
  end

  defp destroy_kind(%URI{} = uri) do
    case Ezagent.Lifecycle.destroy(uri) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
