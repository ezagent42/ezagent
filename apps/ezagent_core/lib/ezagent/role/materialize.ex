defmodule Ezagent.Role.Materialize do
  @moduledoc """
  Role × Flavor **materialization** — the composition step (task #54 §2.3).

  An agent is materialized by choosing a **role** (what fills the sandbox) and a
  **flavor** (how the sandbox is loaded). This module is the single point that
  composes the two, orchestrating the three flavor-agnostic `Role` primitives
  with the flavor's per-instance contribution + the agent's materialization
  context:

  1. **Resolve the flavor** — `Ezagent.AgentFlavorRegistry.lookup/1` → the
     flavor's `:instance_behaviors` (a 0-arity thunk, or `nil` for a flavor with
     its own dedicated Kind). An unknown flavor fails closed.
  2. **Compose contents + behaviors** — `Ezagent.Role.Compose.materialize/2`
     unions the role's behaviors with the flavor's and yields the
     **flavor-independent** `sandbox_content` (`%{skills, plugins, prompt}`).
  3. **Mint caps fail-closed** — `Ezagent.Role.CapMint.mint/3` authorizes the
     role's `requested_caps` against the injected `policy` (the flavor/tenant
     authorization predicate, §2.3.1) and mints the survivors as canonical
     `%Ezagent.Capability{}` under the agent context. The cap `kind` axis is the
     flavor's Kind `type_name/0` (the same value the runtime derives at dispatch),
     not a hard-coded `:agent` — failing closed if the Kind can't supply one. A
     rejected cap is dropped, never copied.

  ## The §6 completion invariant

  Materializing the SAME role against TWO flavors yields **identical
  `sandbox_content`** (the role's contents are flavor-independent), while
  `behaviors` (role ∪ flavor) and the flavor-validated `caps` may legitimately
  differ. See `Ezagent.Role.MaterializeTest`.

  ## Scope (PR-1b-ii)

  This is the **context-supplying composition** — it does NOT install
  `sandbox_content` into a `config_dir`, spawn the Kind, or bind the runtime.
  Wiring this into the live spawn path (`Ezagent.Entity.Agent.TemplateSpawn`)
  and migrating the cc-orchestrator to `role orchestrator × flavor cc` is PR-2
  (it touches the cc-orchestrator seam, coordinated separately). The `policy`
  is injected here (as `CapMint` requires); sourcing a per-flavor policy from
  the registry is part of that live wiring.
  """

  alias Ezagent.AgentFlavorRegistry
  alias Ezagent.Capability
  alias Ezagent.Role
  alias Ezagent.Role.{CapMint, Compose}

  @typedoc """
  The agent materialization context — the per-instance axes a cap needs that a
  flavor-agnostic role cannot carry. The `:kind` axis is derived from the
  resolved flavor's Kind `type_name/0`, not supplied here.
  """
  @type ctx :: %{
          required(:instance) => URI.t(),
          required(:workspace_uri) => URI.t(),
          required(:granter) => URI.t()
        }

  @type materialized :: %{
          behaviors: [module()],
          sandbox_content: %{
            skills: [Role.skill_ref()],
            plugins: [Role.plugin_ref()],
            prompt: term()
          },
          caps: [Capability.t()]
        }

  @doc """
  Materialize `role` against `flavor` under the agent `ctx`, authorizing the
  role's requested caps with `policy` (fail-closed). See the moduledoc.

  Returns `{:ok, %{behaviors, sandbox_content, caps}}`, or
  `{:error, {:unknown_flavor, flavor}}` if the flavor is not registered.
  """
  @spec materialize(Role.t(), String.t(), ctx(), (map() -> boolean())) ::
          {:ok, materialized()} | {:error, term()}
  def materialize(
        %Role{} = role,
        flavor,
        %{
          instance: %URI{} = instance,
          workspace_uri: %URI{} = workspace_uri,
          granter: %URI{} = granter
        },
        policy
      )
      when is_binary(flavor) and is_function(policy, 1) do
    with {:ok, decl} <- lookup_flavor(flavor),
         {:ok, kind} <- cap_kind(decl) do
      composed = Compose.materialize(role, %{flavor_behaviors: flavor_behaviors(decl)})

      caps =
        CapMint.mint(
          role.requested_caps,
          %{kind: kind, instance: instance, workspace_uri: workspace_uri, granter: granter},
          policy
        )

      {:ok, Map.put(composed, :caps, caps)}
    end
  end

  defp lookup_flavor(flavor) do
    case AgentFlavorRegistry.lookup(flavor) do
      {:ok, decl} -> {:ok, decl}
      :error -> {:error, {:unknown_flavor, flavor}}
    end
  end

  # The cap `kind` axis is the flavor's Kind module `type_name/0` — the SAME
  # value `Ezagent.Kind.Runtime` derives at dispatch (`safe_type_name/1`), so a
  # minted cap matches the runtime check. Hard-coding `:agent` would be wrong for
  # a flavor on a dedicated Kind whose type differs.
  #
  # The result is VALIDATED, not trusted verbatim: a GRANT must never widen to
  # the `:any` wildcard (`Capability.Match` treats a held `:any` kind as matching
  # every needed kind — a buggy/hostile flavor returning `:any` could escalate
  # role-requested grants across Kind boundaries). So only a concrete, non-`:any`
  # atom is accepted; `:any` / nil / a non-atom / a raising `type_name/0` all fail
  # closed. (`AgentFlavorRegistry.register/1` only checks `:kind` is an atom, so
  # this is the enforcing point.)
  defp cap_kind(%{kind: kind_module}) when is_atom(kind_module) do
    with true <- Code.ensure_loaded?(kind_module),
         true <- function_exported?(kind_module, :type_name, 0),
         type when is_atom(type) and not is_nil(type) and not is_boolean(type) and type != :any <-
           kind_module.type_name() do
      {:ok, type}
    else
      _ -> {:error, {:flavor_kind_undetermined, kind_module}}
    end
  rescue
    _ -> {:error, {:flavor_kind_undetermined, kind_module}}
  catch
    _, _ -> {:error, {:flavor_kind_undetermined, kind_module}}
  end

  defp cap_kind(decl), do: {:error, {:flavor_kind_undetermined, decl}}

  # A flavor backed by its own dedicated Kind contributes no per-instance
  # behaviors (`:instance_behaviors` is `nil`); a flavor folded onto a shared
  # Kind supplies a 0-arity thunk returning its behavior subset.
  defp flavor_behaviors(%{instance_behaviors: thunk}) when is_function(thunk, 0), do: thunk.()
  defp flavor_behaviors(_decl), do: []
end
