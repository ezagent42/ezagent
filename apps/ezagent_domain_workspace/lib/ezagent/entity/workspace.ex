defmodule Ezagent.Entity.Workspace do
  @moduledoc """
  Workspace Kind — Phase 4 first-class entity for declaring what a
  cluster instance should run.

  Per Phase 4 D3 / D4 / D5: a Workspace is a `workspace://<name>` URI
  that carries (a) a set of member Entity URIs that should be alive
  whenever the Workspace is "instantiated", (b) a list of session
  templates (recipes for creating Sessions with declared members and
  routing rules), and (c) routing rules scoped to this Workspace.

  It is the **plugin-isolation north star** in action: a future plugin
  author adds a new Kind X, declares it in a Workspace template, and
  on cluster restart their Kind X comes back without any change to
  ezagent_core.

  ## Phase 4b scope (this PR)

  - Kind module + Behavior (state shape + actions)
  - `persistence :ephemeral` — Phase 4c flips to `{:snapshot, :on_change}`
    once the `workspaces` table + Loader exist
  - `:instantiate` returns the children list as data (no actual spawn
    yet — 4c's Loader walks the list)

  ## Phase 4c follow-up

  - Postgres `workspaces` table + Ecto schema
  - `Ezagent.Workspace.Loader` queries DB on app start, dispatches
    `:instantiate` per Workspace, walks children + spawns via
    plugin-registered spawn functions
  - The plugin-isolation invariant test lives here

  ## Phase 4d follow-up

  - LV UI: Workspace list + detail + member-picker

  ## Why Workspace lives in ezagent_core (not a separate plugin)

  Workspace is the foundation for plugin authors to declare their
  Kinds. It must be present before any plugin can use it, so it
  belongs in ezagent_core (alongside User, the other foundational Entity).
  The actual SPAWN logic stays decoupled — `:instantiate` returns
  `{Kind, args, URI}` tuples and the caller decides how to spawn
  (typically via a plugin-registered spawn fn in Phase 4c).
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :workspace

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.ActionSet.Workspace]

  # Stays `:ephemeral` even after Phase 4c persistence ships — the
  # Kind itself is rehydrated by `Ezagent.Workspace.Loader` from the
  # `workspaces` Postgres table (managed via `Ezagent.Workspace.Store`),
  # not by per-Kind snapshot. Per Phase 4 D6/D7: config persistence
  # vs runtime-state snapshot are different things.
  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @impl Ezagent.Kind
  def uri_from_args(args), do: Map.fetch!(args, :uri)

  # V1 prevention (Allen 2026-05-21): Workspace Kinds live under the
  # workspace domain's supervisor. `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: Ezagent.Workspace.Supervisor

  @doc """
  Build a `workspace://<name>` URI from a short name.

  Per Phase 4 D4 — Workspaces are first-class URIs that participate
  in cap checks and KindRegistry lookups, identical pattern to
  `session://<type>/<name>` and `entity://agent/<flavor>_<name>`.

      iex> Ezagent.Entity.Workspace.uri_for("team-alpha") |> URI.to_string()
      "workspace://team-alpha"
  """
  @spec uri_for(String.t()) :: URI.t()
  def uri_for(name) when is_binary(name) and name != "" do
    Ezagent.URI.workspace(name)
  end
end
