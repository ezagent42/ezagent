defmodule Ezagent.Agent.DefaultRecipes do
  @moduledoc """
  `DefaultRecipes` — the single role-as-data source for the **cc-headless
  default role-agents** `pm-coordinator` + `dev-together` (Phase 3 ③ refactor
  2026-06-30).

  Both are a **role × flavor** (the `cc` flavor mounts them, agent-guide 原则 1),
  NOT new Kinds and NOT plugin behaviors. They used to live in two plugins'
  `roles/0` (`EzagentPluginKanban` for pm, the now-deleted
  `ezagent_plugin_dev_together` for dev). They are NEITHER plugin's definitional
  agent — they are generic cc-headless agent CONFIGS — so they converge HERE in
  the agent domain behind ONE generic entry: the data lives in this module and
  is boot-seeded by `Ezagent.Agent.DefaultRecipeSeed` (recipe ConfigObject +
  `cc × <role>` AgentTemplate). No plugin `roles/0` returns them anymore.

  Contrast `kanban-manager`, which STAYS in `EzagentPluginKanban.roles/0`: it is
  the board's definitional passive native agent (flavor `native`), the kanban
  plugin's own data Kind, so it keeps its real-module behaviors there.

  ## Why a data module (not config.exs)

  A recipe is a structured map with a `requested_caps` list AND conditional
  `config[:project_cwd]` logic (`maybe_put_project_cwd/2` — omit the `:config`
  key when unset so the seeded body stays byte-identical, avoiding a
  `{:role_seed_collision, …}` on an existing DB). config.exs can hold neither
  the list shape nor the conditional. The opt-in `project_cwd` OVERRIDE value
  still comes from `Application` config, but under the domain-agent namespace
  (`:ezagent_domain_agent, :pm_coordinator_cwd` / `:dev_together_cwd`), migrated
  from the old per-plugin namespaces.

  ## Kanban caps are named by STRING

  The agent domain may NOT take a compile dep on a plugin, so the pm recipe's
  kanban caps name `Ezagent.Behavior.Kanban` as a STRING (the dev recipe already
  did; github caps were already strings). The string resolves to the module at
  the `GrantRecipeCaps` / CapMint chokepoint. The kanban-side board-scoping
  override map (`%{Ezagent.Behavior.Kanban => board_uri}`) keys by the resolved
  MODULE atom and still matches — `GrantRecipeCaps.grant_all/3` matches AFTER
  resolution.
  """

  @pm_role "pm-coordinator"
  @dev_role "dev-together"

  @pm_description "pm = the coordinator/项目经理 职位 — a cc 大脑 that drives the 9-stage " <>
                    "team dev flow (judging each gate, helping edit, prompting for gaps, " <>
                    "routing work by role) via the ezagent CLI under its own least-priv caps."

  @dev_description "dev-together = the team dev workflow SKILL run by a cc 大脑 — plan / " <>
                     "dive / write code / test / review / PR (issue→test→PR ⑦⑧⑨), driving " <>
                     "ezagent via the CLI under its own least-priv caps."

  @doc """
  Both default cc-headless role recipes — the input to the generic
  `Ezagent.Agent.DefaultRecipeSeed.seed_all/0`.
  """
  @spec all() :: [map()]
  def all, do: [pm_coordinator_recipe(), dev_together_recipe()]

  # ── pm-coordinator ──────────────────────────────────────────────────────

  @doc """
  The `pm-coordinator` role recipe (role-as-data). pm = the COORDINATOR job (a
  cc-headless 大脑 driving the 9-stage team dev flow): `passive: false` (a chat
  principal, @-able / join-able), `skills: ["pm-coordinator"]`, `behaviors: []`
  (acts via the CLI/dispatch surface, not mounted behaviors), and a LEAST-PRIV
  starter `requested_caps` set (kanban board ops + github gateway reads). Every
  cap is a `%{behavior:, action:}` map with NO `kind` axis (minted at
  materialization). BOTH the kanban and github behaviors are named by STRING so
  the agent domain keeps ZERO compile dep on either plugin.

  ⚠️ Allen 待确认 cap 集 — a STARTER least-priv set (phase3-pm-spec.md 开放决策).
  """
  @spec pm_coordinator_recipe() :: map()
  def pm_coordinator_recipe do
    %{
      name: @pm_role,
      passive: false,
      behaviors: [],
      skills: ["pm-coordinator"],
      # kanban board ops + github gateway reads — both named by STRING (zero
      # compile dep on ezagent_plugin_kanban / ezagent_plugin_github; resolved
      # to a module at the GrantRecipeCaps / CapMint chokepoint).
      requested_caps:
        Enum.map(
          [
            :get_tree,
            :add_node,
            :set_stage,
            :claim_node,
            :set_status,
            :attach_artifact,
            :register_pr
          ],
          fn action -> %{behavior: "Ezagent.Behavior.Kanban", action: action} end
        ) ++
          Enum.map(
            [:create_issue, :post_comment, :get_pull],
            fn action -> %{behavior: "Ezagent.Behavior.Github", action: action} end
          )
    }
  end

  @doc "The pm-coordinator AgentTemplate `description` (template-seed + kanban materialize share it)."
  @spec pm_description() :: String.t()
  def pm_description, do: @pm_description

  @doc """
  The pm-coordinator agent's `project_cwd` for the template-seed: the opt-in
  `:ezagent_domain_agent, :pm_coordinator_cwd` Application config, else the
  generic `~/.ezagent/pm-coordinator` sandbox default.
  """
  @spec pm_project_cwd() :: String.t()
  def pm_project_cwd, do: project_cwd(:pm_coordinator_cwd, @pm_role)

  # ── dev-together ────────────────────────────────────────────────────────

  @doc """
  The `dev-together` role recipe (role-as-data). dev-together = the team dev
  workflow SKILL (`.claude/skills/dev-together/`, issue→test→PR ⑦⑧⑨) run by a
  cc-headless 大脑: `passive: false`, `skills: ["dev-together"]`, `behaviors: []`,
  and a LEAST-PRIV dev-block `requested_caps` set (kanban node ops + github
  gateway reads/writes), every behavior named by STRING.

  The optional `config[:project_cwd]` is added by `maybe_put_project_cwd/2` ONLY
  when an operator opts in via `:ezagent_domain_agent, :dev_together_cwd` — the
  CLI-reachability seam consumed by the generic by-role materialize
  (`SessionAgentMaterialize.by_role_spec/4`). When unset the `:config` key is
  OMITTED so the seeded body stays byte-identical (no `{:role_seed_collision, …}`
  on an existing DB).
  """
  @spec dev_together_recipe() :: map()
  def dev_together_recipe do
    base = %{
      name: @dev_role,
      passive: false,
      behaviors: [],
      skills: ["dev-together"],
      requested_caps:
        Enum.map(
          [:get_tree, :claim_node, :set_status, :attach_artifact, :register_pr],
          fn action -> %{behavior: "Ezagent.Behavior.Kanban", action: action} end
        ) ++
          Enum.map(
            [:create_issue, :post_comment, :get_pull, :create_commit_status],
            fn action -> %{behavior: "Ezagent.Behavior.Github", action: action} end
          )
    }

    maybe_put_project_cwd(base, :dev_together_cwd)
  end

  @doc "The dev-together AgentTemplate `description` (template-seed)."
  @spec dev_description() :: String.t()
  def dev_description, do: @dev_description

  @doc """
  The dev-together agent's `project_cwd` for the template-seed: the opt-in
  `:ezagent_domain_agent, :dev_together_cwd` Application config, else the generic
  `~/.ezagent/dev-together` sandbox default.
  """
  @spec dev_project_cwd() :: String.t()
  def dev_project_cwd, do: project_cwd(:dev_together_cwd, @dev_role)

  # ── internals ───────────────────────────────────────────────────────────

  # CONDITIONAL config[:project_cwd] seam (T7f boot-regression discipline): add
  # the `:config` key ONLY when an operator opts in (a binary, non-empty cwd).
  # When unset, OMIT it entirely so the seeded body is byte-identical to the
  # pre-seam body — otherwise `%{project_cwd: nil}` is a NEW key the prior body
  # never had and `seed_role_if_absent/1` rejects it (`{:role_seed_collision, _}`)
  # on any DB seeded before the seam.
  defp maybe_put_project_cwd(recipe, config_key) do
    case Application.get_env(:ezagent_domain_agent, config_key) do
      cwd when is_binary(cwd) and cwd != "" ->
        Map.put(recipe, :config, %{project_cwd: cwd})

      _unset ->
        recipe
    end
  end

  defp project_cwd(config_key, role) do
    case Application.get_env(:ezagent_domain_agent, config_key) do
      cwd when is_binary(cwd) and cwd != "" ->
        cwd

      _unset ->
        Path.join([System.user_home() || System.tmp_dir!(), ".ezagent", role])
    end
  end
end
