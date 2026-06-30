defmodule EzagentPluginKanban.PmCoordinatorSeed do
  @moduledoc """
  The kanban-aware half of the `pm-coordinator` default agent: the per-session
  materialize TRIGGER + the board-scoping cap grant.

  pm's role-as-data (recipe) + its boot-time template-seed live GENERICALLY in
  the agent domain (`Ezagent.Agent.DefaultRecipes` +
  `Ezagent.Agent.DefaultRecipeSeed`) — pm is a generic cc-headless agent config,
  NOT the kanban plugin's definitional agent (`kanban-manager` is). What STAYS
  here is the kanban-aware landing: when a board binds to a kanban-flow session
  (`Connectors.bind_session`), pm is materialized as a LIVE per-session `cc`
  agent for THAT session, and its kanban caps are SCOPED to that concrete board.

  ## Board-scoping (T7g Part A)

  `materialize/4` delegates to the generic `Ezagent.Agent.SessionAgentMaterialize`
  engine, supplying `cap_instance_overrides: %{Ezagent.Behavior.Kanban => board_uri}`.
  pm's `kanban.*` dispatches gate the BOARD agent (the `Behavior.Kanban` lives on
  the board host, not on pm), so the override scopes pm's kanban caps to that
  board instance — closing the act3 self-scoped-cap gap. Only the kanban caps are
  board-scoped (github gateway caps stay self-scoped); the agent domain stays
  kanban-agnostic — THIS seed owns the `Behavior.Kanban → board_uri` mapping.

  The override map keys by the MODULE atom `Ezagent.Behavior.Kanban`; the recipe
  names the same behavior by STRING. They still match: `GrantRecipeCaps` resolves
  the string to the module BEFORE matching the override map.
  """

  alias Ezagent.Agent.{DefaultAgentSeed, DefaultRecipes, SessionAgentMaterialize}

  @role_name "pm-coordinator"
  @telemetry_prefix [:ezagent, :kanban, :pm_coordinator_seed]

  @doc "The pm-coordinator role name (`\"pm-coordinator\"`) — exposed so the bind-time relay-back wiring can derive pm's planned per-session URI without a private-attr leak."
  @spec role_name() :: String.t()
  def role_name, do: @role_name

  @doc """
  Materialize the pm-coordinator as a LIVE, per-session `cc` agent for
  `session_uri` (owned by `owner_uri`, in `workspace_uri`) and land its recipe
  caps on that per-session URI, with the kanban caps SCOPED to `board_uri`.

  pm is per-session like the orchestrator (user decision 2026-06-29) — a
  kanban-flow session gets its OWN `entity://<ws>/agent/pm-coordinator-<session-disc>`
  brain. Delegates to the generic `Ezagent.Agent.SessionAgentMaterialize` engine
  with pm's `cc` template content + recipe (both from `Ezagent.Agent.DefaultRecipes`).
  The live `claude` brain reply is the T7b proof, NOT this call.

  `board_uri` (T7g Part A) is the kanban BOARD agent the bind established this
  session over (`Connectors.bind_session`'s `ctx[:self_uri]`). pm's kanban caps
  are scoped to that board instance via `cap_instance_overrides`; the github
  gateway caps stay self-scoped.
  """
  @spec materialize(URI.t(), URI.t(), URI.t(), URI.t()) ::
          {:ok, URI.t(), :created | :already_present} | {:error, term()}
  def materialize(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = owner_uri,
        %URI{} = board_uri
      ) do
    SessionAgentMaterialize.materialize(%{
      role: @role_name,
      session_uri: session_uri,
      workspace_uri: workspace_uri,
      owner_uri: owner_uri,
      template_content:
        DefaultAgentSeed.template_content(
          @role_name,
          DefaultRecipes.pm_description(),
          DefaultRecipes.pm_project_cwd()
        ),
      recipe: DefaultRecipes.pm_coordinator_recipe(),
      telemetry_prefix: @telemetry_prefix,
      cap_instance_overrides: %{Ezagent.Behavior.Kanban => board_uri}
    })
  end
end
