defmodule Ezagent.Orchestrator.OrchestratorRecipe do
  @moduledoc """
  The orchestrator **Role** recipe (task #54 PR-2, design §3).

  The session orchestrator is the load-bearing existing "role" — so it becomes
  the first thing expressed through the `Ezagent.Agent.Recipe` abstraction: a
  **flavor-agnostic recipe** (skills + persona prompt) that composes with a
  flavor (`cc` today) at materialization. The cc seam
  (`Ezagent.PluginCc.Template.OrchestratorBootstrap` + `CcOrchestratorSeed`)
  consults THIS recipe instead of hardcoding the `ezagent-session-orchestrator`
  skill / persona, so the same role recipe would compose identically against a
  future `codex` / `curl` flavor (the §6 invariant, proven by
  `Ezagent.Agent.Recipe.ComposeTest`).

  ## Code-seeded built-in, registered via `roles/0` (RF-9)

  This is a **code recipe** (design §2.1 endorses code-seeded built-in roles).
  RF-9 brings it onto the unified path: the cc plugin's `roles/0` callback
  (`EzagentPluginCc.Application.roles/0`) returns this `recipe/0`, and
  `Ezagent.Plugin.boot/1` Phase 2 registers it in `Ezagent.Agent.RecipeRegistry` by
  `name/0` ("orchestrator") — a first-class named role like any other.
  `OrchestratorBootstrap.resolve_orchestrator_recipe/0` then looks it up BY NAME
  in that registry (the same indirection RF-5a uses), instead of re-deriving it
  from a bespoke `Recipe.Compose` call.

  The design's forkable, persisted `template://<ws>/recipe/orchestrator` Template
  subtype (tenant fork/override) is a documented follow-up: it needs a
  `role`-type branch in the `template://` spawn resolver (the session domain)
  and a RoleTemplate Kind, neither of which exists yet. The persisted Template
  is layered on later by re-pointing the registry source (or the
  `resolve_orchestrator_recipe/0` lookup) at the live Template once that machinery
  lands — the `RecipeRegistry` lookup IS that re-point seam.

  ## Scope (PR-2)

  `requested_caps` carries only concrete behavior/action requests. Wildcard or
  genesis-style authority is deliberately not expressible here; materialization
  must intersect these requests with a fail-closed policy.
  """

  @skill_ref "ezagent-session-orchestrator"

  # The registry NAME this role is keyed by (`roles/0` → `RecipeRegistry`, RF-4)
  # AND the name the future persisted `template://system/recipe/orchestrator`
  # Template subtype is keyed by. Single-sourced so the `roles/0` declaration,
  # the `RecipeRegistry.lookup/1`, and the `OrchestratorBootstrap` resolver all
  # agree on one string.
  @role_name "orchestrator"

  @doc "The registry name this role is keyed by (`RecipeRegistry.lookup(name/0)`)."
  @spec name() :: String.t()
  def name, do: @role_name

  @doc "The orchestrator MCP tools declared by the cc recipe contribution."
  @spec tool_contributions() :: [map()]
  def tool_contributions do
    Enum.map(tool_schemas(), fn schema ->
      %{
        name: schema["name"],
        schema: schema,
        mcp: true
      }
    end)
  end

  @doc "The orchestrator MCP tool schemas contributed by this recipe."
  @spec tool_schemas() :: [map()]
  def tool_schemas do
    Ezagent.Session.Config.Catalog.core_operations()
    |> Enum.map(&Ezagent.Session.Config.Operation.schema/1)
  end

  @doc "The orchestrator MCP tool names contributed by this recipe."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.map(tool_atoms(), &Atom.to_string/1)

  @doc "The orchestrator MCP tool atoms contributed by this recipe."
  @spec tool_atoms() :: [atom()]
  def tool_atoms do
    Ezagent.Session.Config.Catalog.core_operations()
    |> Enum.map(&String.to_existing_atom(&1.name))
  end

  @doc """
  The orchestrator role recipe — the map `Ezagent.Agent.Recipe.new/1` consumes (and the
  future `template://system/recipe/orchestrator` content). Flavor-agnostic: it
  names no flavor field.

  Carries a `:name` ("orchestrator") so the cc plugin's `roles/0` callback (RF-4)
  registers it as a first-class named role in `Ezagent.Agent.RecipeRegistry`, looked up
  by `OrchestratorBootstrap.resolve_orchestrator_recipe/0` at agent-spawn time
  (RF-9 — the orchestrator joins the unified `roles/0` + `Recipe.Compose` path).
  """
  @spec recipe() :: map()
  def recipe do
    %{
      name: @role_name,
      skills: [@skill_ref],
      prompt: persona(),
      behaviors: [],
      requested_caps: [
        %{behavior: Ezagent.ActionSet.Template, action: :read},
        %{behavior: Ezagent.ActionSet.Template, action: :write},
        %{behavior: Ezagent.ActionSet.Template, action: :instantiate},
        %{behavior: Ezagent.ActionSet.Template, action: :fork}
      ],
      contributions: %{tools: tool_contributions()},
      session_template: nil
    }
  end

  @doc """
  The single-source orchestrator persona — written into the orchestrator's
  sandbox `CLAUDE.md` by `CcOrchestratorSeed` (and the value of the role's
  `prompt`). A live `claude` orchestrator reads it on startup.
  """
  @spec persona() :: String.t()
  def persona do
    """
    # You are an Ezagent session orchestrator

    You manage a team of worker agents inside one chat session. You build
    the team from MEMBERS + RULE-SETS (via the `esr-orchestrator` MCP
    server) — a worker is a session MEMBER with a stable `role_name`; a
    multi-agent flow is a named RULE-SET of single-receiver routing rules,
    optionally fronted by a `@legend`:

    - `add_managed_member` — spawn a worker from an AgentTemplate and join
      it as a member with a stable `role_name`.
    - `remove_member` — remove a member by `role_name` (terminates the
      worker you spawned + prunes its routing rules).
    - `define_rule_set_rule` — add a single-receiver routing rule to a
      named rule-set: when a message matches, deliver it to the member
      named by `receiver_role_name` (optionally rendered with a prompt
      template). Express a relay as static rules — e.g. `{from: relay-cc}
      → relay-codex` — NEVER ask a worker to compute the next hop itself.
    - `define_prompt_template` — install a named prompt template (rules
      reference it via `prompt_template_ref`; it renders into the
      delivered message, e.g. `"接龙：{body}（by {sender}）"`).
    - `define_legend` — front a rule-set with a `@legend` handle so a user
      can trigger the whole team by `@`-mentioning the legend name.
    - `update_template` — save the current team as a new version of its
      parent SessionTemplate.
    - `save_template_as` — save the current team as a NEW template family.
    - `list_templates` — discover the AgentTemplates / SessionTemplates
      available in your workspace.

    ## Rules

    - You act ONLY within your own session and workspace. Tools that
      target anything outside it will be denied — that is expected; do
      not retry with a different workspace.
    - When a tool returns an error, surface it plainly to the user and
      explain what they could do (e.g. "that template is outside your
      workspace").
    - Compose the team to fit the user's task: add members with role_names,
      then wire the flow with `define_rule_set_rule` (the routing TABLE is
      the baton — workers never emit hop tokens), and front it with a
      `@legend` if the user should trigger it by name.
    """
  end
end
