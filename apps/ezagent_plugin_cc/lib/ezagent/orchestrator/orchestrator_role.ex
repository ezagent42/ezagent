defmodule Ezagent.Orchestrator.OrchestratorRole do
  @moduledoc """
  The orchestrator **Role** recipe (task #54 PR-2, design §3).

  The session orchestrator is the load-bearing existing "role" — so it becomes
  the first thing expressed through the `Ezagent.Role` abstraction: a
  **flavor-agnostic recipe** (skills + persona prompt) that composes with a
  flavor (`cc` today) at materialization. The cc seam
  (`Ezagent.PluginCc.Template.OrchestratorBootstrap` + `CcOrchestratorSeed`)
  consults THIS recipe instead of hardcoding the `ezagent-session-orchestrator`
  skill / persona, so the same role recipe would compose identically against a
  future `codex` / `curl` flavor (the §6 invariant, proven by
  `Ezagent.Role.MaterializeTest`).

  ## Code-seeded built-in (Option B, Allen 2026-06-15)

  This is a **code recipe** fed through the real `Ezagent.Role.new/1` core
  primitive — NOT a registry (design §2.1 endorses code-seeded built-in roles).
  The design's forkable, persisted `template://<ws>/role/orchestrator` Template
  subtype (tenant fork/override) is a documented follow-up: it needs a
  `role`-type branch in the `template://` spawn resolver (the session domain)
  and a RoleTemplate Kind, neither of which exists yet. PR-2 delivers the
  in-lane decoupling now; the persisted Template is layered on later by
  re-pointing `OrchestratorBootstrap.resolve_orchestrator_role/0` at the live
  Template once that machinery lands.

  ## Scope (PR-2)

  `behaviors` and `requested_caps` are deliberately empty here: PR-2 migrates
  the sandbox **content** (skills + persona), not the caps/behaviors→spawn
  threading (that is the live `TemplateSpawn` cap path, deferred). The recipe is
  shaped so those fields can be populated later without changing consumers.
  """

  alias Ezagent.Role

  @skill_ref "ezagent-session-orchestrator"

  @doc """
  The orchestrator role recipe — the map `Ezagent.Role.new/1` consumes (and the
  future `template://system/role/orchestrator` content). Flavor-agnostic: it
  names no flavor field. `behaviors`/`requested_caps` are empty in PR-2 (see the
  moduledoc).
  """
  @spec recipe() :: map()
  def recipe do
    %{
      skills: [@skill_ref],
      prompt: persona(),
      behaviors: [],
      requested_caps: [],
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
    # You are an ESR session orchestrator

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

  @doc """
  Build the composed sandbox content for the orchestrator role × the given
  flavor's per-instance behaviors. Returns `Ezagent.Role.Compose`'s
  `%{behaviors, sandbox_content}` (the context-free half of materialization).

  `flavor_behaviors` defaults to `[]` — PR-2 composes content only; the cc
  flavor declares no `:instance_behaviors`.
  """
  @spec compose([module()]) ::
          {:ok, Ezagent.Role.Compose.materialized()} | {:error, term()}
  def compose(flavor_behaviors \\ []) when is_list(flavor_behaviors) do
    with {:ok, role} <- Role.new(recipe()) do
      {:ok, Role.Compose.materialize(role, %{flavor_behaviors: flavor_behaviors})}
    end
  end
end
