defmodule Ezagent.Role do
  @moduledoc """
  Role — the **flavor-agnostic sandbox-content recipe** (task #54).

  > **The CONTENTS of the sandbox are the ROLE; HOW the sandbox is loaded is
  > the FLAVOR.** (Allen 2026-06-14)

  A Role is the content of a forkable `template://<ws>/role/<name>` Template
  subtype: what fills an agent's `config_dir` sandbox — skills, plugins, a
  system-prompt persona, the behavior subset it runs, the caps it **requests**,
  and a **reference** to a session-template. It is composed with a *flavor*
  (the `Ezagent.AgentFlavorRegistry` loader — `config_dir` env + kind + bridge)
  at materialization (`Ezagent.Role.Compose`).

  ## Flavor-agnostic by construction

  None of a Role's fields may name a flavor (`:flavor`, `:kind`,
  `:bridge_adapter`, `:template_class`). Encoding a flavor here re-entangles
  role with flavor — the whole point of #54 is that the SAME role composes
  across cc/codex/curl with identical contents. `new/1` rejects such a recipe.

  ## Caps are REQUESTED, not granted (§2.3.1)

  `requested_caps` are a *request*. Materialization runs an explicit
  fail-closed authorization (`requested ∩ flavor/tenant policy`) — a requested
  cap the flavor/runtime/tenant does not permit is REJECTED, never copied. The
  field name encodes that semantics; the grant is the authorization step, not a
  copy. See `Ezagent.Role.Compose`.
  """

  @flavor_fields [:flavor, :kind, :bridge_adapter, :template_class]

  @enforce_keys []
  defstruct skills: [],
            plugins: [],
            prompt: nil,
            behaviors: [],
            requested_caps: [],
            session_template: nil

  @type skill_ref :: String.t()
  @type plugin_ref :: String.t()
  @type cap_template :: map()

  @type t :: %__MODULE__{
          skills: [skill_ref()],
          plugins: [plugin_ref()],
          prompt: String.t() | nil,
          behaviors: [module()],
          requested_caps: [cap_template()],
          session_template: String.t() | URI.t() | nil
        }

  @doc """
  Build a `%Role{}` from a recipe map (the `template://…/role/…` content).

  Absent fields default empty/`nil` (`skills`/`plugins`/`behaviors`/
  `requested_caps` → `[]`; `prompt`/`session_template` → `nil`). Returns
  `{:error, {:flavor_field_in_role, key}}` if the recipe names a flavor field
  (`#{inspect(@flavor_fields)}`) — a Role MUST be flavor-agnostic so the same
  recipe composes identically across flavors.
  """
  @spec new(map()) :: {:ok, t()} | {:error, {:flavor_field_in_role, atom()}}
  def new(recipe) when is_map(recipe) do
    case Enum.find(@flavor_fields, &Map.has_key?(recipe, &1)) do
      nil ->
        {:ok,
         %__MODULE__{
           skills: Map.get(recipe, :skills, []),
           plugins: Map.get(recipe, :plugins, []),
           prompt: Map.get(recipe, :prompt),
           behaviors: Map.get(recipe, :behaviors, []),
           requested_caps: Map.get(recipe, :requested_caps, []),
           session_template: Map.get(recipe, :session_template)
         }}

      flavor_field ->
        {:error, {:flavor_field_in_role, flavor_field}}
    end
  end
end
