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

    **`effective_caps` are authorized REQUEST TEMPLATES, not mint-ready caps.**
    A Role is workspace-agnostic (a reusable recipe), so a request template
    carries the authority axes (`behavior`/`action`) but NOT `workspace_uri` —
    the workspace is **materialization context** (like flavor), known only when
    the agent is created in a specific workspace. The materialization step
    (PR-1b) injects the agent's `workspace_uri` + `instance` and mints the
    canonical `%Ezagent.Capability{}` via `Ezagent.Capability.normalize!/2`
    (which mandates `workspace_uri` — no silent cross-workspace default),
    dropping any normalize failure fail-closed. Requiring `workspace_uri` in
    the recipe would be wrong — it would pin a reusable role to one workspace.

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
      #
      # A persisted role recipe carries STRING-keyed caps; normalize the known
      # cap AXIS keys to atoms first so an atom-key policy predicate
      # (`%{action: a}`) matches instead of raising FunctionClauseError. (Only
      # KEYS — VALUE normalization, e.g. a module-name string → module atom, is
      # the materialization step's job via `Ezagent.Capability.normalize!/2`,
      # PR-1b; an un-normalized VALUE merely fails the predicate → fail-closed
      # reject, never a crash.)
      effective_caps:
        role.requested_caps
        |> Enum.map(&normalize_cap_keys/1)
        |> Enum.filter(&authorized?(authorize, &1))
    }
  end

  # The authorization boundary is TOTAL + fail-closed: a cap is kept ONLY on a
  # strict `true`. A predicate that returns a non-`true` value OR RAISES (e.g. a
  # concrete-value clause `%{action: :send}` hitting an as-yet-unnormalized
  # string value `"send"` — value normalization is PR-1b's job) drops the cap.
  # So materialize/2 never crashes on a malformed cap × predicate combination;
  # it fails CLOSED, which is the only safe default for a CapBAC boundary.
  defp authorized?(authorize, cap) do
    authorize.(cap) == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # Normalize a cap template's known AXIS keys from persisted-string to atom
  # form so an atom-key policy predicate matches. Only the closed set of cap
  # axes is atomized; any other string key passes through unchanged so arbitrary
  # persisted content can never grow the atom table.
  defp normalize_cap_keys(cap) when is_map(cap), do: Map.new(cap, fn {k, v} -> {axis(k), v} end)
  defp normalize_cap_keys(other), do: other

  defp axis("behavior"), do: :behavior
  defp axis("action"), do: :action
  defp axis("instance"), do: :instance
  defp axis("workspace_uri"), do: :workspace_uri
  defp axis("kind"), do: :kind
  defp axis(k), do: k
end
