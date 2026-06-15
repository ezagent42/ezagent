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

    **`effective_caps` are authorized, value-canonical templates carrying
    `{kind, behavior, action}`** — the flavor's `kind` is injected here (it is
    flavor context, known at composition, and closes the `normalize!`
    `kind: :any` cross-kind hole), `behavior`/`action` come from the role
    request (canonicalized to module/atom). They are NOT mint-ready
    `%Ezagent.Capability{}`: a Role is workspace-agnostic (a reusable recipe),
    so `workspace_uri` (and optionally `instance`) are **agent materialization
    context**, injected by PR-1b which then mints via
    `Ezagent.Capability.normalize!/2` (which mandates `workspace_uri` — no
    silent cross-workspace default), dropping any normalize failure fail-closed.
    Putting `workspace_uri`/`instance`/`kind` in the recipe would be wrong (and
    is rejected by `Ezagent.Role.new/1`) — it would pin a reusable role to one
    workspace/agent/flavor.

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
          required(:flavor_kind) => atom(),
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
  def materialize(%Role{} = role, %{
        flavor_behaviors: flavor_behaviors,
        flavor_kind: flavor_kind,
        authorize_cap: authorize
      })
      when is_list(flavor_behaviors) and is_atom(flavor_kind) and is_function(authorize, 1) do
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
        |> Enum.map(&normalize_cap/1)
        # Inject the FLAVOR's kind (the agent's Kind type) — a materialization
        # axis the recipe is forbidden to carry (so it can't be smuggled) but
        # which the cap-grant chokepoint needs concrete: `Capability.normalize!/2`
        # defaults a missing atom-keyed `:kind` to `:any`, which would mint a
        # CROSS-KIND cap. Injecting it here (kind is flavor context, known at
        # composition) closes that hole structurally — so two flavors of the
        # same role get correctly DIFFERING kinds (flavor-validated, §6). PR-1b
        # injects only the agent-specific `:workspace_uri` (+ optional
        # `:instance`) before `normalize!`.
        |> Enum.map(&Map.put(&1, :kind, flavor_kind))
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

  # Canonicalize a persisted request cap to atom KEYS + atom/module VALUES so
  # (a) an atom-key/atom-value policy predicate matches without raising, and
  # (b) `effective_caps` are value-canonical request templates PR-1b can mint
  # by injecting the agent workspace + calling `Capability.normalize!/2` — not
  # string-valued maps that would later mint a malformed `%Capability{}` (codex).
  # Only the request axes (`behavior` → module, `action` → atom) are
  # value-canonicalized; a value that does not resolve to an EXISTING atom/module
  # (typo'd persisted content) is left as the string, so the policy predicate
  # rejects it → fail-closed, never a crash and never a phantom atom.
  defp normalize_cap(cap) when is_map(cap) do
    Map.new(cap, fn {k, v} -> canon(axis(k), v) end)
  end

  defp normalize_cap(other), do: other

  defp canon(:behavior, v) when is_binary(v), do: {:behavior, safe_module(v)}
  defp canon(:action, v) when is_binary(v), do: {:action, safe_atom(v)}
  defp canon(key, v), do: {key, v}

  defp axis("behavior"), do: :behavior
  defp axis("action"), do: :action
  defp axis("instance"), do: :instance
  defp axis("workspace_uri"), do: :workspace_uri
  defp axis("kind"), do: :kind
  defp axis(k), do: k

  # Resolve a module-name string to its module atom ONLY if it already exists
  # (loaded); otherwise leave the string (predicate rejects → fail-closed). Never
  # `to_atom` — no atom-table growth from persisted content.
  defp safe_module(s) do
    String.to_existing_atom(if String.starts_with?(s, "Elixir."), do: s, else: "Elixir." <> s)
  rescue
    ArgumentError -> s
  end

  defp safe_atom(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> s
  end
end
