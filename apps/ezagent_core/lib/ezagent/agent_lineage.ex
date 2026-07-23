defmodule Ezagent.AgentLineage do
  @moduledoc """
  Agent spawn lineage registry — `agent_uri → spawned_by_uri`
  (Phase 7 PR 40, supports PR 42's `{:spawned_by, _}` cap shape).

  Per Decision #137: `{:spawned_by, principal_uri}` is one of two
  scope-tuple cap shapes for bounded delegation. PR 42 ships the
  contract surface but returns `false` for the shape because
  there's no place to look up lineage at CapBAC step 5.5 (and
  recursive dispatch from inside CapBAC would deadlock).

  This registry is the storage that flips PR 42's placeholder into
  real lineage-aware matching: `Ezagent.Entity.Agent.spawn/4` records
  who spawned each agent; `Capability.instance_match?/2` reads
  this registry to decide if a `{:spawned_by, P}` cap matches a
  needed action targeting an agent in P's lineage.

  ## Lookup semantics

  - `record(agent_uri, spawned_by)` — idempotent; re-recording the
    same pair is a no-op (orchestrator may re-spawn an agent under
    the same lineage).
  - `lookup(agent_uri)` — `{:ok, spawned_by_uri}` if recorded,
    `:error` otherwise.
  - `spawned_in_lineage?(agent_uri, principal_uri)` — true if
    walking the lineage chain from `agent_uri` upward eventually
    hits `principal_uri`. Bounded depth (default 100) to prevent
    pathological cycles (which shouldn't happen but defense in
    depth).

  ## Storage — durable source of truth + ETS read cache (remediation C-B #114)

  The `:ezagent_agent_lineage` set table (owned by `EzagentCore.EtsOwner`,
  keys are agent URI strings, values are spawned_by URI strings) is the
  fast runtime READ cache. Behind it sits the durable `agent_lineage`
  SQLite table — the SOURCE OF TRUTH — so lineage survives a restart.

  This is the `Ezagent.TemplateTags` / `Ezagent.Routing.RuleStore`
  pattern: `record/2` write-through (upsert) to the DB AND the cache;
  `forget/1` deletes from both; `rehydrate/0` re-populates the empty ETS
  cache from the table at boot (the `EtsOwner` recreates the table empty
  on every start). `lookup/1` / `spawned_in_lineage?/3` keep the
  lock-free ETS read path.

  Before C-B the table was pure ETS: the `agent_uri → spawned_by`
  mapping was lost on restart, so a previously-owned agent became
  "foreign" and `{:spawned_by, P}` CapBAC matching broke for every
  agent spawned before the restart. codex confirmed there was no durable
  `spawned_by` field on the Agent Kind to rebuild from, so the durable
  row IS the rebuild source.

  ## Why not a slice field on Agent Kind

  Identity slice already exists per Decision #88; adding spawned_by
  there would couple two unrelated concepts (caps + lineage). A
  dedicated lineage table is consistent with the WorkspaceRegistry /
  TemplateTags pattern and avoids slice-shape churn for what is
  effectively a lookup table, not per-Agent state worth snapshotting
  (lineage is set once at spawn, never changes).

  ## Boot-time ordering

  Lives in ezagent_core so it's available before any plugin starts.
  `EzagentCore.EtsOwner` creates the (empty) ETS table at boot before
  plugin `Application.start` callbacks run; `EzagentCore.Application`
  then calls `rehydrate/0` AFTER the Repo + Migrator children are up
  (alongside `Ezagent.TemplateTags.load_into_registry/0`) to fill the
  cache from the durable table.
  """

  use Ecto.Schema
  import Ecto.Query
  alias EzagentCore.Repo

  @table :ezagent_agent_lineage

  @primary_key {:agent_uri, :string, autogenerate: false}
  schema "agent_lineage" do
    field :spawned_by, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          agent_uri: String.t(),
          spawned_by: String.t() | nil
        }

  @doc "The ETS read-cache table name. `EzagentCore.EtsOwner` creates it."
  def table, do: @table

  @doc """
  Record that `agent_uri` was spawned by `spawned_by`. Idempotent for the same
  derivation and fail-loud when an existing append-only edge names a different
  creator.

  remediation C-B (#114) — write-through: upsert the durable row (the
  source of truth) AND the ETS cache. The `agent_uri` PRIMARY KEY makes
  the upsert idempotent — re-recording the same pair overwrites in place,
  matching the prior `:ets.insert/2` overwrite semantics.
  """
  @spec record(URI.t() | String.t(), URI.t() | String.t()) :: :ok | {:error, term()}
  def record(agent_uri, spawned_by) do
    a = uri_to_str(agent_uri)
    s = uri_to_str(spawned_by)

    with :ok <-
           Ezagent.Provenance.DerivationEdges.record_derivation_edge(
             a,
             s,
             :spawned_by,
             stable_attempt_id(a)
           ),
         row = %__MODULE__{agent_uri: a, spawned_by: s, inserted_at: DateTime.utc_now()},
         {:ok, _} <-
           Repo.insert(row,
             on_conflict: [set: [spawned_by: s]],
             conflict_target: [:agent_uri]
           ) do
      :ets.insert(@table, {a, s})
      :ok
    end
  end

  @doc "Persist an exact lineage fact through the caller's Repo without updating ETS."
  @spec record_exact(module(), URI.t() | String.t(), URI.t() | String.t()) ::
          {:ok, :inserted | :exists} | {:error, :lineage_conflict}
  def record_exact(repo, agent_uri, spawned_by) when is_atom(repo) do
    a = uri_to_str(agent_uri)
    s = uri_to_str(spawned_by)

    case repo.insert_all(
           __MODULE__,
           [%{agent_uri: a, spawned_by: s, inserted_at: DateTime.utc_now()}],
           on_conflict: :nothing,
           conflict_target: [:agent_uri]
         ) do
      {1, _} ->
        {:ok, :inserted}

      {0, _} ->
        case repo.get(__MODULE__, a) do
          %__MODULE__{spawned_by: ^s} -> {:ok, :exists}
          %__MODULE__{} -> {:error, :lineage_conflict}
          nil -> {:error, :lineage_conflict}
        end
    end
  end

  @doc "Publish a committed lineage fact to the ETS read cache."
  @spec publish_cache(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def publish_cache(agent_uri, spawned_by) do
    :ets.insert(@table, {uri_to_str(agent_uri), uri_to_str(spawned_by)})
    :ok
  end

  @doc """
  Look up the direct spawner of `agent_uri`. Returns
  `{:ok, %URI{} = spawned_by_uri}` or `:error`.
  """
  @spec lookup(URI.t() | String.t()) :: {:ok, URI.t()} | :error
  def lookup(agent_uri) do
    a = uri_to_str(agent_uri)

    case :ets.lookup(@table, a) do
      [{^a, s}] -> {:ok, Ezagent.URI.new!(s)}
      [] -> :error
    end
  end

  @doc """
  Return true if walking the lineage chain from `agent_uri` upward
  eventually reaches `principal_uri` (inclusive — direct match
  counts). False otherwise.

  Bounded by `max_depth` to prevent cycles (which shouldn't happen
  in practice — orchestrator spawn graph is a tree — but defensive).
  """
  @spec spawned_in_lineage?(URI.t() | String.t(), URI.t() | String.t(), pos_integer()) ::
          boolean()
  def spawned_in_lineage?(agent_uri, principal_uri, max_depth \\ 100) do
    target = uri_to_str(principal_uri)
    walk_lineage(uri_to_str(agent_uri), target, max_depth)
  end

  defp walk_lineage(_current, _target, 0), do: false

  defp walk_lineage(current, target, depth_left) do
    if current == target do
      true
    else
      case :ets.lookup(@table, current) do
        [{^current, parent}] -> walk_lineage(parent, target, depth_left - 1)
        [] -> false
      end
    end
  end

  @doc """
  Remove the lineage entry for `agent_uri`. Returns `:ok` either way.

  remediation C-B (#114) — deletes the durable row AND the ETS cache so
  a subsequent `rehydrate/0` does not resurrect a forgotten entry.
  """
  @spec forget(URI.t() | String.t()) :: :ok
  def forget(agent_uri) do
    a = uri_to_str(agent_uri)
    Repo.delete_all(from(r in __MODULE__, where: r.agent_uri == ^a))
    :ets.delete(@table, a)
    :ok
  end

  @doc """
  Hydrate the ETS read cache from the durable `agent_lineage` SQLite
  table (remediation C-B #114).

  Called at boot from `EzagentCore.Application` AFTER the Repo + Migrator
  children are up — the `Ezagent.TemplateTags.load_into_registry/0`
  analogue. `EtsOwner` recreates the ETS table EMPTY on every start, so
  without this call every pre-restart lineage entry would be lost. Clears
  the cache and re-populates it from every persisted row, so the cache
  reflects exactly what the durable table holds.

  Returns `:ok`.
  """
  @spec rehydrate() :: :ok
  def rehydrate do
    rows = Repo.all(__MODULE__)

    :ets.delete_all_objects(@table)

    Enum.each(rows, fn r ->
      :ets.insert(@table, {r.agent_uri, r.spawned_by})
    end)

    :ok
  end

  @doc "List all lineage entries as `[{agent_uri_str, spawned_by_uri_str}]`."
  @spec list_all() :: [{String.t(), String.t()}]
  def list_all do
    :ets.tab2list(@table)
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s

  defp stable_attempt_id(agent_uri) do
    digest = :crypto.hash(:sha256, agent_uri) |> Base.url_encode64(padding: false)
    "agent-lineage:" <> digest
  end
end
