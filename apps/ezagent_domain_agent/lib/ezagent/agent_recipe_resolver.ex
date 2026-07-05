defmodule Ezagent.AgentRecipeResolver do
  @moduledoc """
  P2 recipe-provenance list read model + the per-URI `:recipe` durable-snapshot fallback (was RF-7 role).

  `Ezagent.KindRegistry` is a bare `uri → pid` map and explicitly says by-role
  indices belong elsewhere (codex MED-F). This module is that elsewhere: it
  answers "which agents have role R?" and "what role is THIS agent?" from the
  DURABLE persisted snapshots — so a DORMANT passive role agent (e.g. the
  kanban-manager) still enumerates by role after a BEAM restart, when its live
  Kind is not even spawned and the ETS fast path is empty. (If the list were
  sourced from the live `KindRegistry` the kanban board would VANISH on restart.)

  ## Why the LIST is sourced from snapshots, not ETS

  The ETS fast path (`Ezagent.AgentRecipeAttributes`) is keyed `stable_key → role
  name`; it can answer a per-URI lookup but CANNOT enumerate agents-by-role (the
  list output is agent URIs; the value is a bare role name, and the table is
  volatile — empty after a restart). The persisted `kind_snapshots` rows carry
  the `uri` column directly AND the `:sandbox` slice's durable `:recipe` provenance, so a
  snapshot scan is the ONE source that is cold-restart-safe, covers BOTH live and
  dormant agents (every created agent has a snapshot), and yields URIs. That is
  the source of truth for the list; ETS is the fast path for the per-URI resolver
  only.

  ## Scoping (K4 — the world kanban read-model)

  `list_by_recipe/2` takes an optional `workspace_uri` so the kanban board read
  model can ask for the kanban-manager of ITS workspace — `list_in_workspace/1`
  bounds the scan AND prevents a cross-tenant leak. `:all` (the default) scans
  every workspace (ops / system-scope callers only).
  """

  alias Ezagent.Ecto.KindSnapshot

  # Agent snapshot rows are written with `kind_type = Atom.to_string(type_name())`.
  @agent_kind_type Atom.to_string(Ezagent.Entity.Agent.type_name())

  @doc """
  List the agent URIs whose DURABLE role NAME equals `role_name`.

  Sourced from the persisted `kind_snapshots` rows (cold-restart-safe; covers
  live AND dormant agents). Only `kind_type == "agent"` rows are scanned, and
  only those whose decoded `:sandbox` slice carries `recipe == recipe_name` are
  returned. An empty/blank `role_name` returns `[]` (no agent is enumerated by
  the no-role sentinel).

  `workspace_uri` (default `:all`) scopes the scan to a single tenant via
  `KindSnapshot.list_in_workspace/1` — K4's kanban board passes its own
  workspace so it never leaks (or scans) other tenants' agents.
  """
  @spec list_by_recipe(String.t(), URI.t() | String.t() | :all) :: [URI.t()]
  def list_by_recipe(role_name, workspace_uri \\ :all)

  def list_by_recipe(role_name, _workspace_uri)
      when not is_binary(role_name) or role_name == "",
      do: []

  def list_by_recipe(role_name, workspace_uri) when is_binary(role_name) do
    workspace_uri
    |> snapshot_rows()
    |> Enum.filter(fn row -> row.kind_type == @agent_kind_type end)
    |> Enum.filter(fn row -> role_of_row(row) == role_name end)
    |> Enum.map(fn row -> row.uri end)
    |> Enum.uniq()
    |> Enum.map(&safe_uri/1)
    |> Enum.reject(&is_nil/1)
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      require Logger

      Logger.warning(
        "AgentRecipeResolver.list_by_recipe/2: snapshot scan failed for role=#{role_name}: " <>
          inspect(error.__struct__)
      )

      []
  end

  @doc """
  Durable role NAME for a single agent URI, read from its persisted `:sandbox`
  snapshot slice. Returns `{:ok, role_name}` / `:none`.

  This is the snapshot fallback the layered `:role` UriQuery resolver falls
  through to after the ETS fast path misses (a cold restart). No live-Kind read
  — a pure snapshot lookup, safe on the routing/`:join` hot path (parallel to
  `AgentPassiveAttributes` → `resolve_passive`'s snapshot layer).
  """
  @spec recipe_from_durable_snapshot(URI.t()) :: {:ok, String.t()} | :none
  def recipe_from_durable_snapshot(%URI{} = agent_uri) do
    case Ezagent.SnapshotStore.latest(agent_uri) do
      {:ok, %{state: state}} when is_map(state) ->
        case role_of_state(state) do
          role when is_binary(role) and role != "" -> {:ok, role}
          _ -> :none
        end

      _ ->
        :none
    end
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      require Logger

      Logger.warning(
        "AgentRecipeResolver.recipe_from_durable_snapshot/1: failed for " <>
          "#{URI.to_string(agent_uri)}: " <> inspect(error.__struct__)
      )

      :none
  end

  defp snapshot_rows(:all), do: KindSnapshot.list_all()
  defp snapshot_rows(%URI{} = ws), do: KindSnapshot.list_in_workspace(ws)
  defp snapshot_rows(ws) when is_binary(ws), do: KindSnapshot.list_in_workspace(ws)

  # The durable role of a snapshot ROW — decode its state binary, then read the
  # `:sandbox` slice's `:recipe`. A row whose state cannot decode / has no recipe is
  # treated as roleless (nil), never matching a role query.
  defp role_of_row(%KindSnapshot{} = row) do
    case KindSnapshot.decode_state(row) do
      {:ok, state} when is_map(state) -> role_of_state(state)
      _ -> nil
    end
  end

  # Read the `:sandbox` slice's `:recipe` provenance from a decoded snapshot
  # state. Snapshot slices are string-keyed after a JSON/term round-trip, so
  # normalize the slice view (mirrors
  # `AgentFlavorResolver.flavor_from_durable_snapshot`) before the
  # `Map.get(:recipe)` — otherwise the field is silently missed.
  defp role_of_state(state) when is_map(state) do
    case Map.get(state, :sandbox) || Map.get(state, "sandbox") do
      slice when is_map(slice) ->
        case slice |> Ezagent.Kind.normalize_slice_view() |> Map.get(:recipe) do
          recipe when is_binary(recipe) and recipe != "" -> recipe
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp role_of_state(_), do: nil

  defp safe_uri(uri) when is_binary(uri) do
    case Ezagent.URI.parse(uri) do
      {:ok, %URI{} = u} -> u
      _ -> nil
    end
  end

  defp safe_uri(%URI{} = uri), do: uri
  defp safe_uri(_), do: nil
end
