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

  ## ETS layout

  `:ezagent_agent_lineage` set table owned by `EzagentCore.EtsOwner`. Keys
  are agent URI strings, values are spawned_by URI strings.

  ## Why not a slice field on Agent Kind

  Identity slice already exists per Decision #88; adding spawned_by
  there would couple two unrelated concepts (caps + lineage). A
  separate ETS registry is consistent with the WorkspaceRegistry
  pattern (5th Registry per Decision #135) and avoids slice-shape
  churn for what is effectively a runtime lookup table, not
  per-Agent state worth snapshotting (lineage is set once at
  spawn, never changes).

  ## Boot-time ordering

  Lives in ezagent_core so it's available before any plugin starts.
  EzagentCore.EtsOwner creates the table at boot before plugin
  Application.start callbacks run.
  """

  @table :ezagent_agent_lineage

  def table, do: @table

  @doc """
  Record that `agent_uri` was spawned by `spawned_by`. Idempotent.
  """
  @spec record(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def record(agent_uri, spawned_by) do
    a = uri_to_str(agent_uri)
    s = uri_to_str(spawned_by)
    :ets.insert(@table, {a, s})
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
      [{^a, s}] -> {:ok, Ezagent.URI.parse!(s)}
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

  @doc "Remove the lineage entry for `agent_uri`. Returns `:ok` either way."
  @spec forget(URI.t() | String.t()) :: :ok
  def forget(agent_uri) do
    :ets.delete(@table, uri_to_str(agent_uri))
    :ok
  end

  @doc "List all lineage entries as `[{agent_uri_str, spawned_by_uri_str}]`."
  @spec list_all() :: [{String.t(), String.t()}]
  def list_all do
    :ets.tab2list(@table)
  end

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
