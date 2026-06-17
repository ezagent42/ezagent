defmodule Ezagent.Role.Compose do
  @moduledoc """
  Role × Flavor composition of sandbox CONTENT + BEHAVIORS (task #54 §2.3).

  Given a `%Ezagent.Role{}` (the flavor-agnostic sandbox-content recipe) and a
  flavor's per-instance behavior set, produce the **context-free** half of
  materialization:

  - `behaviors` — the role's behavior subset UNIONed with the flavor's
    per-instance behaviors (deduped).
  - `sandbox_content` — `%{skills, plugins, prompt}` to install into the
    flavor-allocated `config_dir`. **Flavor-independent**: the same role yields
    identical content for any flavor (the §6 completion invariant — same role ×
    two flavors → identical sandbox contents).

  ## Caps are deliberately NOT composed here

  A capability cannot be made safe without the full agent materialization
  context — `kind` (flavor), `instance`/`workspace_uri` (the materialized
  agent), and the granter. Producing cap "templates" here and leaving the
  consumer to inject those axes invites silent defaults at the grant chokepoint
  (`Capability.normalize!/2` defaults missing `:kind`/`:instance` to `:any` →
  cross-kind / cross-instance widening). So the role's `requested_caps` stay on
  the `%Role{}`; the **§2.3.1 fail-closed cap authorization + minting** is done
  by the materialization step (PR-1b), which has the agent context and builds a
  real `%Ezagent.Capability{}` via `normalize!` fail-closed. This module is the
  pure, context-free content/behavior composer — nothing about caps.
  """

  alias Ezagent.Role

  @type opts :: %{required(:flavor_behaviors) => [module() | atom()]}

  @type materialized :: %{
          behaviors: [module() | atom()],
          sandbox_content: %{
            skills: [Role.skill_ref()],
            plugins: [Role.plugin_ref()],
            prompt: term()
          }
        }

  @doc """
  Compose `(role, flavor_behaviors)` into `%{behaviors, sandbox_content}` — the
  context-free half of materialization. `opts.flavor_behaviors` is the flavor's
  per-instance behavior set (UNIONed with the role's, deduped). Caps are handled
  by the materialization step (PR-1b) — see the moduledoc.
  """
  @spec materialize(Role.t(), opts()) :: materialized()
  def materialize(%Role{} = role, %{flavor_behaviors: flavor_behaviors})
      when is_list(flavor_behaviors) do
    # The role's behaviors are validated as real Behaviors by `Role.new/1` (they
    # come from an untrusted persisted/operator recipe). The flavor's behaviors
    # are NOT re-validated here: they are CODE-DECLARED by the flavor plugin
    # (`AgentFlavorRegistry` `instance_behaviors`) — trusted input whose validity
    # belongs at flavor-registration, and which the runtime independently refuses
    # at dispatch ({:not_a_behavior, _}). Validating them in this pure composer
    # would couple it to cross-app module load-state for marginal defense.
    %{
      behaviors: Enum.uniq(role.behaviors ++ flavor_behaviors),
      sandbox_content: %{
        skills: role.skills,
        plugins: role.plugins,
        prompt: role.prompt
      }
    }
  end
end
