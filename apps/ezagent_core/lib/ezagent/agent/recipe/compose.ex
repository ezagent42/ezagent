defmodule Ezagent.Agent.Recipe.Compose do
  @moduledoc """
  Role × Flavor composition of sandbox CONTENT + BEHAVIORS (task #54 §2.3).

  Given a `%Ezagent.Agent.Recipe{}` (the flavor-agnostic sandbox-content recipe) and a
  flavor's per-instance behavior set, produce the **context-free** half of
  materialization:

  - `behaviors` — the role's behavior subset UNIONed with the flavor's
    per-instance behaviors (deduped).
  - `sandbox_content` — `%{skills, plugins, prompt, script}` to install into the
    flavor-allocated `config_dir`. **Flavor-independent**: the same role yields
    identical content for any flavor (the §6 completion invariant — same role ×
    two flavors → identical sandbox contents). `script` is the optional
    operator-authored file content (py-agent P4 RF-5b channel — a py-role carries
    its python script here; a flavor whose create route installs config_dir
    content reads it from `sandbox_content.script`). `nil` for a scriptless role.

  ## Caps are deliberately NOT composed here

  A capability cannot be made safe without the full agent materialization
  context — `kind` (flavor), `instance`/`workspace_uri` (the materialized
  agent), and the granter. Producing cap "templates" here and leaving the
  consumer to inject those axes invites silent defaults at the grant chokepoint
  (`Capability.normalize!/2` defaults missing `:kind`/`:instance` to `:any` →
  cross-kind / cross-instance widening). So the role's `requested_caps` stay on
  the `%Recipe{}`; the **§2.3.1 fail-closed cap authorization + minting** is done
  by the materialization step (PR-1b), which has the agent context and builds a
  real `%Ezagent.Capability{}` via `normalize!` fail-closed. This module is the
  pure, context-free content/behavior composer — nothing about caps.
  """

  alias Ezagent.Agent.Recipe

  @type opts :: %{required(:flavor_behaviors) => [module() | atom()]}

  @type materialized :: %{
          behaviors: [module() | atom()],
          contributions: map(),
          passive: boolean(),
          recipe: String.t() | nil,
          sandbox_content: %{
            skills: [Recipe.skill_ref()],
            plugins: [Recipe.plugin_ref()],
            prompt: term(),
            script: String.t() | nil
          }
        }

  @doc """
  Compose `(role, flavor_behaviors)` into `%{behaviors, sandbox_content}` — the
  context-free half of materialization. `opts.flavor_behaviors` is the flavor's
  per-instance behavior set (UNIONed with the role's, deduped). Caps are handled
  by the materialization step (PR-1b) — see the moduledoc.
  """
  @spec materialize(Recipe.t(), opts()) :: materialized()
  def materialize(%Recipe{} = role, %{flavor_behaviors: flavor_behaviors})
      when is_list(flavor_behaviors) do
    # The role's behaviors are validated as real Behaviors by `Recipe.new/1` (they
    # come from an untrusted persisted/operator recipe). The flavor's behaviors
    # are NOT re-validated here: they are CODE-DECLARED by the flavor plugin
    # (`instance_behaviors`) — trusted input whose validity
    # belongs at flavor-registration, and which the runtime independently refuses
    # at dispatch ({:not_a_behavior, _}). Validating them in this pure composer
    # would couple it to cross-app module load-state for marginal defense.
    %{
      behaviors: Enum.uniq(role.behaviors ++ flavor_behaviors),
      contributions: role.contributions,
      # RF-6: carry the role's non-principal (passive data-actor) marker through
      # to materialization so the create step can record it as a stored agent
      # attribute (RF-5a) — the routing/join/mention gates source `passive?` from
      # that attribute, never from a parsed URI.
      passive: role.passive,
      # P2 RECIPE PROVENANCE (was RF-7 role): carry the RECIPE NAME through to
      # materialization so the create step records it as the durable
      # `:sandbox`-slice `:recipe` field (the list-by-recipe read model + the
      # `:recipe` UriQuery resolver source it from that snapshot, never from a
      # parsed URI). This is build provenance, NOT a session role (Gate B).
      # `nil` only for an unnamed recipe.
      recipe: role.name,
      sandbox_content: %{
        skills: role.skills,
        plugins: role.plugins,
        prompt: role.prompt,
        # RF-5b (py-agent P4): the role's operator-authored file content. A
        # flavor whose create route installs config_dir content (py → agent.py)
        # reads it here; `nil` for a scriptless role (every existing role).
        script: role.script
      }
    }
  end
end
