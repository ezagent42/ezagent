defmodule Ezagent.Role.Compose do
  @moduledoc """
  Role × Flavor composition at materialization (task #54 §2.3).

  Given a `%Ezagent.Role{}` (the flavor-agnostic sandbox-content recipe) and a
  flavor's wiring, produce the materialized agent shape:

  - `behaviors` — the role's behavior subset UNIONed with the flavor's
    per-instance behaviors (deduped).
  - `sandbox_content` — `%{skills, plugins, prompt}` to install into the
    flavor-allocated `config_dir`. **Flavor-independent**: the same role yields
    identical content for any flavor (the §6 completion invariant).
  - `effective_caps` — the role's `requested_caps` **authorized fail-closed**:
    `requested ∩ {policy permits}` (§2.3.1). A requested cap the
    flavor/runtime/tenant policy does NOT permit is REJECTED, never copied —
    so `effective_caps` may legitimately DIFFER across flavors while the
    sandbox contents are identical.

  Policy injection: `materialize/2` takes an `:authorize_cap` predicate
  (`cap -> boolean`) — the composition of the flavor/runtime + tenant policy.
  Keeping the predicate injected makes the intersection logic here pure +
  unit-testable; the call site (materialization) builds the predicate from the
  flavor decl + tenant policy (and may use `Ezagent.Capability.matches?/2`
  against the permitted cap patterns). This module never blanket-copies caps —
  the cap chokepoint stays the sole authority.
  """

  alias Ezagent.Role

  @type opts :: %{
          required(:flavor_behaviors) => [module() | atom()],
          required(:authorize_cap) => (Role.cap_template() -> boolean())
        }

  @type materialized :: %{
          behaviors: [module() | atom()],
          sandbox_content: %{
            skills: [Role.skill_ref()],
            plugins: [Role.plugin_ref()],
            prompt: term()
          },
          effective_caps: [Role.cap_template()]
        }

  @doc """
  Materialize `(role, flavor)` into `%{behaviors, sandbox_content,
  effective_caps}`. `opts.flavor_behaviors` is the flavor's per-instance
  behavior set; `opts.authorize_cap` is the fail-closed policy predicate
  (`requested ∩ permitted`). See the moduledoc.
  """
  @spec materialize(Role.t(), opts()) :: materialized()
  def materialize(%Role{} = role, %{flavor_behaviors: flavor_behaviors, authorize_cap: authorize})
      when is_list(flavor_behaviors) and is_function(authorize, 1) do
    %{
      behaviors: Enum.uniq(role.behaviors ++ flavor_behaviors),
      sandbox_content: %{
        skills: role.skills,
        plugins: role.plugins,
        prompt: role.prompt
      },
      # §2.3.1 fail-closed: keep ONLY requested caps the policy permits, and
      # ONLY on a STRICT `true` — a truthy non-boolean (e.g. an `{:error, _}` /
      # `{:ok, false}` a mis-integrated policy predicate might return) must NOT
      # authorize the cap. A rejected cap is dropped (never copied), so
      # effective ⊆ requested ∩ policy.
      effective_caps: Enum.filter(role.requested_caps, &(authorize.(&1) == true))
    }
  end
end
