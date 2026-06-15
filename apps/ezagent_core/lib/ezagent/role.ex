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
  @spec new(map()) ::
          {:ok, t()}
          | {:error, {:flavor_field_in_role, atom()} | {:invalid_role_field, atom(), term()}}
  def new(recipe) when is_map(recipe) do
    # A persisted role recipe (a `template://…/role/…` content slice) round-trips
    # through JSON/snapshot as STRING keys, so the flavor-field rejection AND the
    # field reads must be symmetric over atom + string keys — otherwise
    # `%{"flavor" => "cc"}` would slip past the flavor-agnostic boundary (codex).
    case Enum.find(@flavor_fields, &flavor_key_present?(recipe, &1)) do
      nil ->
        # This is a persisted-content / operator-authored boundary, so SHAPE-
        # validate before returning {:ok, role} — a malformed recipe (e.g.
        # `behaviors: nil`, `requested_caps: "x"`) must fail HERE, not crash or
        # feed non-cap input into the policy predicate downstream in Compose (codex).
        validate(%__MODULE__{
          skills: get(recipe, :skills, []),
          plugins: get(recipe, :plugins, []),
          prompt: get(recipe, :prompt, nil),
          behaviors: get(recipe, :behaviors, []),
          requested_caps: get(recipe, :requested_caps, []),
          session_template: get(recipe, :session_template, nil)
        })

      flavor_field ->
        {:error, {:flavor_field_in_role, flavor_field}}
    end
  end

  # Shape-validate the recipe at the boundary so `Compose` can assume a
  # well-formed `%Role{}`: the four collection fields are lists,
  # `requested_caps` entries are cap-template MAPS (so the fail-closed policy
  # predicate never receives a non-cap term), and `prompt`/`session_template`
  # are `nil` or a string/URI ref.
  defp validate(%__MODULE__{} = role) do
    with :ok <- list_field(role.skills, :skills),
         :ok <- list_field(role.plugins, :plugins),
         :ok <- list_field(role.behaviors, :behaviors),
         :ok <- caps_field(role.requested_caps),
         :ok <- ref_field(role.prompt, :prompt),
         :ok <- ref_field(role.session_template, :session_template) do
      {:ok, role}
    end
  end

  defp list_field(value, _name) when is_list(value), do: :ok
  defp list_field(value, name), do: {:error, {:invalid_role_field, name, value}}

  defp caps_field(value) when is_list(value) do
    if Enum.all?(value, &valid_cap_template?/1),
      do: :ok,
      else: {:error, {:invalid_role_field, :requested_caps, value}}
  end

  defp caps_field(value), do: {:error, {:invalid_role_field, :requested_caps, value}}

  # A requested cap template must carry at least the axes the fail-closed policy
  # predicate consumes — `behavior` + `action` (in atom or persisted-string key
  # form). This stops a malformed entry (`%{}`, missing `action`) from reaching
  # `Compose`'s authorization predicate and crashing materialization. (Canonical
  # %Capability{} construction + atom-key normalization happen at the
  # materialization step, PR-1b, via `Ezagent.Capability.normalize!/2` — the
  # recipe boundary only validates presence.)
  defp valid_cap_template?(cap) when is_map(cap),
    do: cap_key?(cap, :behavior) and cap_key?(cap, :action)

  defp valid_cap_template?(_), do: false

  defp cap_key?(map, atom_key),
    do: Map.has_key?(map, atom_key) or Map.has_key?(map, Atom.to_string(atom_key))

  defp ref_field(nil, _name), do: :ok
  defp ref_field(value, _name) when is_binary(value), do: :ok
  defp ref_field(%URI{}, _name), do: :ok
  defp ref_field(value, name), do: {:error, {:invalid_role_field, name, value}}

  # A forbidden flavor field is present in EITHER its atom or string form.
  defp flavor_key_present?(recipe, atom_field) do
    Map.has_key?(recipe, atom_field) or Map.has_key?(recipe, Atom.to_string(atom_field))
  end

  # Read a recipe field by atom key, falling back to its string key (persisted
  # JSON/snapshot content), then the default.
  defp get(recipe, atom_key, default) do
    case Map.fetch(recipe, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(recipe, Atom.to_string(atom_key), default)
    end
  end
end
