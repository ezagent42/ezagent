defmodule Ezagent.Agent.Recipe do
  @moduledoc """
  Recipe — the **flavor-agnostic sandbox-content recipe** (task #54; symbol
  rename #127: `Ezagent.Role` → `Ezagent.Agent.Recipe`).

  > **The CONTENTS of the sandbox are the RECIPE; HOW the sandbox is loaded is
  > the FLAVOR.** (Allen 2026-06-14)

  A Recipe is the content of a forkable `template://<ws>/recipe/<name>` Template
  subtype: what fills an agent's `config_dir` sandbox — skills, plugins, a
  system-prompt persona, an optional operator-authored `script` (the RF-5b
  content→config_dir channel — py-agent P4: a py-role carries its python script
  here), the behavior subset it runs, the caps it **requests**, and a
  **reference** to a session-template. It is composed with a *flavor*
  (the domain-agent flavor loader — `config_dir` env + kind + bridge)
  at materialization (`Ezagent.Agent.Recipe.Compose`).

  ## Flavor-agnostic by construction

  None of a Recipe's fields may name a flavor (`:flavor`, `:kind`,
  `:bridge_adapter`, `:template_class`). Encoding a flavor here re-entangles
  recipe with flavor — the whole point of #54 is that the SAME recipe composes
  across cc/codex/curl with identical contents. `new/1` rejects such a recipe.

  ## Caps are REQUESTED, not granted (§2.3.1)

  `requested_caps` are a *request*. Materialization runs an explicit
  fail-closed authorization (`requested ∩ flavor/tenant policy`) — a requested
  cap the flavor/runtime/tenant does not permit is REJECTED, never copied. The
  field name encodes that semantics; the grant is the authorization step, not a
  copy. See `Ezagent.Agent.Recipe.Compose`.
  """

  @flavor_fields [:flavor, :kind, :bridge_adapter, :template_class]

  # Materialization/provenance axes a recipe cap MUST NOT carry — a Recipe is
  # workspace-agnostic, so these are injected at materialization (kind/instance/
  # workspace) or stamped at grant (granted_by/_at). Rejecting them stops an
  # operator-authored recipe from SMUGGLING a concrete/foreign workspace/instance
  # into a cap (a CapBAC hole). Fail LOUD, not silent-strip.
  @cap_materialization_axes [:kind, :instance, :workspace_uri, :granted_by, :granted_at]

  # All known cap axes — used to atomize a persisted cap's string keys uniformly.
  @cap_axes [:behavior, :action | @cap_materialization_axes]

  @enforce_keys []
  defstruct name: nil,
            passive: false,
            skills: [],
            plugins: [],
            prompt: nil,
            script: nil,
            behaviors: [],
            requested_caps: [],
            contributions: %{},
            session_template: nil,
            config: %{}

  @type skill_ref :: String.t()
  @type plugin_ref :: String.t()
  @type cap_template :: map()

  @type t :: %__MODULE__{
          name: String.t() | nil,
          passive: boolean(),
          skills: [skill_ref()],
          plugins: [plugin_ref()],
          prompt: String.t() | nil,
          script: String.t() | nil,
          behaviors: [module()],
          requested_caps: [cap_template()],
          contributions: map(),
          session_template: String.t() | URI.t() | nil,
          config: map()
        }

  @doc """
  Build a `%Recipe{}` from a recipe map (the `template://…/recipe/…` content).

  Absent fields default empty/`nil` (`skills`/`plugins`/`behaviors`/
  `requested_caps` → `[]`; `prompt`/`session_template` → `nil`). Returns
  `{:error, {:flavor_field_in_role, key}}` if the recipe names a flavor field
  (`#{inspect(@flavor_fields)}`) — a Recipe MUST be flavor-agnostic so the same
  recipe composes identically across flavors.
  """
  @spec new(map()) ::
          {:ok, t()}
          | {:error, {:flavor_field_in_role, atom()} | {:invalid_role_field, atom(), term()}}
  def new(recipe) when is_map(recipe) do
    # A persisted role recipe (a `template://…/recipe/…` content slice) round-trips
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
          name: get(recipe, :name, nil),
          passive: get(recipe, :passive, false),
          skills: get(recipe, :skills, []),
          plugins: get(recipe, :plugins, []),
          prompt: get(recipe, :prompt, nil),
          script: get(recipe, :script, nil),
          behaviors: get(recipe, :behaviors, []),
          requested_caps: get(recipe, :requested_caps, []),
          contributions: get(recipe, :contributions, %{}),
          session_template: get(recipe, :session_template, nil),
          config: get(recipe, :config, %{})
        })

      flavor_field ->
        {:error, {:flavor_field_in_role, flavor_field}}
    end
  end

  # Shape-validate the recipe at the boundary so `Compose` can assume a
  # well-formed `%Recipe{}`: the four collection fields are lists,
  # `requested_caps` entries are cap-template MAPS (so the fail-closed policy
  # predicate never receives a non-cap term), and `prompt`/`session_template`
  # are `nil` or a string/URI ref.
  defp validate(%__MODULE__{} = role) do
    with :ok <- ref_field(role.name, :name),
         {:ok, passive} <- passive_field(role.passive),
         :ok <- string_list_field(role.skills, :skills),
         :ok <- string_list_field(role.plugins, :plugins),
         {:ok, behaviors} <- behaviors_field(role.behaviors),
         {:ok, requested_caps} <- caps_field(role.requested_caps),
         {:ok, contributions} <- contributions_field(role.contributions),
         :ok <- ref_field(role.prompt, :prompt),
         :ok <- ref_field(role.script, :script),
         :ok <- ref_field(role.session_template, :session_template),
         {:ok, config} <- config_field(role.config) do
      # behaviors → module atoms; requested_caps → atom-keyed templates (value
      # canonicalization + minting are PR-1b's); passive → coerced boolean.
      {:ok,
       %{
         role
         | passive: passive,
           behaviors: behaviors,
           requested_caps: requested_caps,
           contributions: contributions,
           config: config
       }}
    end
  end

  # Contribution declarations are recipe-owned extension points consumed by
  # plugin transports. Keep the core boundary shape-only: concrete contribution
  # semantics belong to the declaring plugin.
  defp contributions_field(nil), do: {:ok, %{}}

  defp contributions_field(value) when is_map(value) do
    tools = Map.get(value, :tools) || Map.get(value, "tools") || []

    cond do
      tools == [] and map_size(value) == 0 ->
        {:ok, %{}}

      is_list(tools) and Enum.all?(tools, &tool_contribution?/1) ->
        {:ok, %{tools: Enum.map(tools, &canon_tool_contribution/1)}}

      true ->
        {:error, {:invalid_role_field, :contributions, value}}
    end
  end

  defp contributions_field(value), do: {:error, {:invalid_role_field, :contributions, value}}

  defp tool_contribution?(value) when is_map(value) do
    tool_name = Map.get(value, :name) || Map.get(value, "name")
    schema = Map.get(value, :schema) || Map.get(value, "schema")

    (is_atom(tool_name) or is_binary(tool_name)) and is_map(schema)
  end

  defp tool_contribution?(_), do: false

  defp canon_tool_contribution(value) do
    %{
      name: Map.get(value, :name) || Map.get(value, "name"),
      schema: Map.get(value, :schema) || Map.get(value, "schema"),
      mcp: Map.get(value, :mcp) || Map.get(value, "mcp") || false
    }
  end

  # `config` is the layer-2 business-config bag a recipe may carry for its
  # behaviors (e.g. `Behavior.Kanban`'s stage chain + CI/import defaults). It is
  # opaque map data — the recipe does NOT interpret it (the owning Behavior
  # reads its own keys, atom/string-key tolerant, at runtime). Only shape-
  # validate: nil → `%{}`; must be a map. This keeps the recipe the SOLE layer-2
  # carrier of business semantics while the Behavior stays generic mechanism.
  # (Taxonomy §0.2 / red line 1+2: business semantics live as data here, NOT in
  # layer-1 Behavior code.)
  defp config_field(nil), do: {:ok, %{}}
  defp config_field(value) when is_map(value), do: {:ok, value}
  defp config_field(value), do: {:error, {:invalid_role_field, :config, value}}

  # `passive` marks a NON-PRINCIPAL data actor (RF-6): an `entity://agent/*`
  # that acts only on dispatch and must NOT be a chat principal — non-mentionable,
  # non-`:join`-able as a member, and never a `chat.receive` target via ANY
  # routing rule (the kanban-manager class). A persisted/operator recipe may omit
  # the field (→ `false`, the principal-actor default) or supply a string-keyed
  # `true`/`false` from JSON round-trip; anything that is not a boolean (or the
  # `nil`/missing default) is REJECTED fail-loud rather than coerced to a
  # surprising truth value.
  defp passive_field(nil), do: {:ok, false}
  defp passive_field(value) when is_boolean(value), do: {:ok, value}
  defp passive_field(value), do: {:error, {:invalid_role_field, :passive, value}}

  defp string_list_field(value, name) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: :ok, else: {:error, {:invalid_role_field, name, value}}
  end

  defp string_list_field(value, name), do: {:error, {:invalid_role_field, name, value}}

  # Validate + canonicalize the behavior subset: every entry must resolve to a
  # real, loadable behavior MODULE — atoms pass through, persisted module-name
  # strings are decoded to their existing module atom, and anything that does
  # not load (typo / nil / non-module) is REJECTED fail-loud (not silently
  # dropped later by the behavior-set intersection). Returns the canonicalized
  # list so the materialized behaviors are always module atoms.
  defp behaviors_field(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, acc} ->
      case canon_behavior(entry) do
        {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
        :error -> {:halt, {:error, {:invalid_role_field, :behaviors, entry}}}
      end
    end)
    |> case do
      {:ok, mods} -> {:ok, Enum.reverse(mods)}
      err -> err
    end
  end

  defp behaviors_field(value), do: {:error, {:invalid_role_field, :behaviors, value}}

  defp canon_behavior(mod) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) do
    if behavior_module?(mod), do: {:ok, mod}, else: :error
  end

  defp canon_behavior(s) when is_binary(s) do
    mod = if String.starts_with?(s, "Elixir."), do: s, else: "Elixir." <> s
    atom = String.to_existing_atom(mod)
    if behavior_module?(atom), do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp canon_behavior(_), do: :error

  # A role behavior entry must be a real new-style Ezagent Behavior — not just
  # any loaded module. The runtime refuses a non-Behavior at dispatch
  # (`{:not_a_behavior, mod}`) and the behavior-set intersection drops it, so a
  # recipe listing `String` (or any non-Behavior) must fail at THIS boundary,
  # not degrade silently later (codex). `new_style?/1` reads the `__behavior__?/0`
  # marker `use Ezagent.ActionSet` injects.
  defp behavior_module?(mod) do
    Code.ensure_loaded?(mod) and Ezagent.ActionSet.new_style?(mod)
  end

  defp caps_field(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn cap, {:ok, acc} ->
      case canon_cap(cap) do
        {:ok, c} -> {:cont, {:ok, [c | acc]}}
        :error -> {:halt, {:error, {:invalid_role_field, :requested_caps, cap}}}
      end
    end)
    |> case do
      {:ok, caps} -> {:ok, Enum.reverse(caps)}
      err -> err
    end
  end

  defp caps_field(value), do: {:error, {:invalid_role_field, :requested_caps, value}}

  # Validate + canonicalize one requested cap template. Rejects (`:error`): a
  # non-map; a cap missing `behavior`/`action`; a smuggled materialization axis
  # (round 7); or a DUPLICATE axis (both the atom and string key form of the
  # same axis — ambiguous, and would make the downstream `normalize!` branch
  # selection non-deterministic, round 12). On success, returns the cap with its
  # axis KEYS canonicalized to ATOMS uniformly — so PR-1b always consumes
  # atom-keyed templates (no mixed-key / wrong-branch ambiguity). VALUE
  # canonicalization (behavior string → module, action string → atom) + context
  # injection + `%Capability{}` minting are PR-1b's (they need `normalize!` +
  # agent context); the recipe boundary only fixes key hygiene.
  defp canon_cap(cap) when is_map(cap) do
    cond do
      not (cap_key?(cap, :behavior) and cap_key?(cap, :action)) -> :error
      Enum.any?(@cap_materialization_axes, &cap_key?(cap, &1)) -> :error
      dup_axis?(cap) -> :error
      true -> {:ok, atomize_cap_keys(cap)}
    end
  end

  defp canon_cap(_), do: :error

  # A cap that carries BOTH the atom and string form of the same axis is
  # ambiguous → reject.
  defp dup_axis?(cap) do
    Enum.any?([:behavior, :action | @cap_materialization_axes], fn axis ->
      Map.has_key?(cap, axis) and Map.has_key?(cap, Atom.to_string(axis))
    end)
  end

  # Atomize ONLY the known cap-axis string keys; any other key passes through
  # unchanged (no atom-table growth from arbitrary persisted content).
  defp atomize_cap_keys(cap) do
    axis_strings = Map.new(@cap_axes, fn a -> {Atom.to_string(a), a} end)
    Map.new(cap, fn {k, v} -> {Map.get(axis_strings, k, k), v} end)
  end

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
