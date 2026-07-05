defmodule Ezagent.Socialware.Conformance do
  @moduledoc """
  T2-3 — socialware Definition conformance checker: the ONE rule "every declared
  reference resolves" broken into the SPEC §4 assertions. `check/2` runs them
  against a `%Definition{}` + its workspace and returns `:ok` or
  `{:error, [{assertion_id, detail}]}` (fail-closed — a bad reference is a red).

  The `mix ezagent.socialware.check` task is a thin wrapper; this library is the
  unit-testable core. A green run proves the definition is materializable: its
  bases/shape/views ActionSets load, its view render caps are registered, its
  agent role slots' recipes resolve with registered caps + unique role_names,
  its adapters are registered, its orchestrator URI parses, it is installable,
  and its routing/prompt/legend refs (incl. every `prompt_template_ref`) resolve.

  Assertion 9 (no view render entry bypasses `authorize_view`) is a SOURCE gate
  (`EzagentCore.Architecture.ViewAuthorizeGateTest`); here it is enforced
  positively — every view's `<sw>_render` cap MUST be registered so
  `authorize_view/3` has a concrete cap to check (assertion 2 is its prerequisite).
  """

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.CapabilityRegistry
  alias Ezagent.Routing.PromptTemplate
  alias Ezagent.Socialware.{Definition, DefinitionRegistry, Installation}

  @session_kind Ezagent.Entity.Session

  @type failure :: {atom(), term()}

  @doc """
  Run every conformance assertion against `definition` in `workspace_uri`.
  Returns `:ok` or `{:error, failures}` where each failure is
  `{assertion_id, detail}`.
  """
  @spec check(Definition.t(), URI.t() | String.t()) :: :ok | {:error, [failure()]}
  def check(%Definition{} = definition, workspace_uri) do
    ws = to_uri(workspace_uri)

    failures =
      []
      |> add(:uses_plugins_installed, check_uses_plugins(definition.uses))
      |> add(:bases_shape_load, check_modules_load(definition.bases ++ definition.shape))
      |> add(:views_exist_caps_registered, check_views(definition.views))
      |> add(:agent_recipes_resolve, check_agent_recipes(definition.roles, ws))
      |> add(:agent_caps_and_role_uniqueness, check_agent_caps_and_roles(definition.roles, ws))
      |> add(:adapters_registered, check_adapters(definition.adapters))
      |> add(
        :orchestrator_uri_parses,
        check_orchestrator_uri(definition.orchestrator_template_uri)
      )
      |> add(:install_resolves, check_install_resolves(definition, ws))
      |> add(:template_installable, check_template_installable(definition, ws))
      |> add(:routing_receivers_resolve, check_routing_receivers(definition))
      |> add(:prompt_template_refs_valid, check_prompt_template_refs(definition))
      |> add(:view_caps_gate_ready, check_view_caps_gate_ready(definition.views))
      |> Enum.reverse()

    if failures == [], do: :ok, else: {:error, failures}
  end

  @doc "The ordered list of assertion ids this checker enforces."
  @spec assertions() :: [atom()]
  def assertions do
    [
      :uses_plugins_installed,
      :bases_shape_load,
      :views_exist_caps_registered,
      :agent_recipes_resolve,
      :agent_caps_and_role_uniqueness,
      :adapters_registered,
      :orchestrator_uri_parses,
      :install_resolves,
      :template_installable,
      :routing_receivers_resolve,
      :prompt_template_refs_valid,
      :view_caps_gate_ready
    ]
  end

  # --- 0: uses[] plugins are installed ------------------------------------

  defp check_uses_plugins(uses) when is_list(uses) do
    case Enum.reject(uses, &plugin_installed?/1) do
      [] -> :ok
      missing -> {:error, {:missing_socialware_plugins, missing}}
    end
  end

  defp plugin_installed?(slug) when is_binary(slug) do
    not is_nil(Ezagent.PluginRegistry.info(slug)) or
      match?({:ok, _}, Ezagent.PluginPackage.InstalledRegistry.lookup(slug))
  rescue
    _ -> false
  end

  defp plugin_installed?(_), do: false

  # --- 1: bases/shape ActionSet modules load -------------------------------

  defp check_modules_load(modules) do
    case Enum.reject(modules, &Code.ensure_loaded?/1) do
      [] -> :ok
      missing -> {:error, {:modules_not_loaded, missing}}
    end
  end

  # --- 2 & 9: views exist + their render caps are registered ---------------

  defp check_views(views) do
    Enum.reduce_while(views, :ok, fn view, :ok ->
      cond do
        not Code.ensure_loaded?(view) ->
          {:halt, {:error, {:view_not_loaded, view}}}

        not function_exported?(view, :actions, 0) ->
          {:halt, {:error, {:view_missing_actions, view}}}

        true ->
          case unregistered_view_actions(view) do
            [] -> {:cont, :ok}
            missing -> {:halt, {:error, {:view_render_cap_unregistered, view, missing}}}
          end
      end
    end)
  end

  defp unregistered_view_actions(view) do
    Enum.reject(view.actions(), fn action ->
      match?({:ok, _}, CapabilityRegistry.lookup_subject(@session_kind, action))
    end)
  end

  # Assertion 9 (positive form): each view's render cap is registered so
  # authorize_view has a concrete cap to check. Same predicate as check 2, but a
  # distinct assertion so a regression here is named for the gate it protects.
  defp check_view_caps_gate_ready([]), do: :ok

  defp check_view_caps_gate_ready(views) do
    case Enum.flat_map(views, &unregistered_view_actions/1) do
      [] -> :ok
      missing -> {:error, {:view_cap_gate_not_ready, missing}}
    end
  end

  # --- 3: agent role slots' recipe resolves via RecipeRegistry -------------

  defp check_agent_recipes(roles, ws) do
    roles
    |> agent_role_slots()
    |> Enum.reduce_while(:ok, fn %{recipe: recipe}, :ok ->
      case RecipeRegistry.lookup(URI.to_string(ws), recipe) do
        {:ok, _} -> {:cont, :ok}
        :error -> {:halt, {:error, {:unknown_agent_recipe, recipe}}}
      end
    end)
  end

  # --- 4: agent requested_caps registered + role_name uniqueness -----------

  defp check_agent_caps_and_roles(roles, ws) do
    with :ok <- check_role_name_uniqueness(roles),
         :ok <- check_agent_requested_caps(agent_role_slots(roles), ws) do
      :ok
    end
  end

  defp check_role_name_uniqueness(roles) do
    role_names = Enum.map(roles, & &1.role_name)
    dups = role_names -- Enum.uniq(role_names)
    if dups == [], do: :ok, else: {:error, {:duplicate_role_name, Enum.uniq(dups)}}
  end

  defp check_agent_requested_caps(agents, ws) do
    Enum.reduce_while(agents, :ok, fn %{recipe: recipe}, :ok ->
      case RecipeRegistry.lookup(URI.to_string(ws), recipe) do
        {:ok, %{requested_caps: caps}} ->
          case Enum.reject(caps, &cap_behavior_loaded?/1) do
            [] -> {:cont, :ok}
            bad -> {:halt, {:error, {:agent_cap_behavior_not_loaded, recipe, bad}}}
          end

        {:ok, _} ->
          {:cont, :ok}

        :error ->
          # covered by check 3; don't double-report
          {:cont, :ok}
      end
    end)
  end

  defp cap_behavior_loaded?(cap) when is_map(cap) do
    case Map.get(cap, :behavior) || Map.get(cap, "behavior") do
      mod when is_atom(mod) and mod not in [nil, :any] -> Code.ensure_loaded?(mod)
      name when is_binary(name) -> module_name_loaded?(name)
      _ -> false
    end
  end

  defp module_name_loaded?(name) do
    elixir = if String.starts_with?(name, "Elixir."), do: name, else: "Elixir." <> name
    Code.ensure_loaded?(String.to_existing_atom(elixir))
  rescue
    ArgumentError -> false
  end

  # --- 5: adapters registered ----------------------------------------------

  defp check_adapters(adapters) do
    Enum.reduce_while(adapters, :ok, fn adapter, :ok ->
      adapter_id = adapter_id_of(adapter)

      cond do
        is_nil(adapter_id) ->
          {:halt, {:error, {:adapter_missing_id, adapter}}}

        match?({:ok, _}, Ezagent.ExternalMirror.AdapterRegistry.lookup(adapter_id)) ->
          {:cont, :ok}

        true ->
          {:halt, {:error, {:unknown_adapter, adapter_id}}}
      end
    end)
  end

  defp adapter_id_of(adapter) when is_map(adapter),
    do: Map.get(adapter, :adapter_id) || Map.get(adapter, "adapter_id")

  defp adapter_id_of(_), do: nil

  # --- 6: orchestrator_template_uri parses ---------------------------------

  defp check_orchestrator_uri(nil), do: :ok
  defp check_orchestrator_uri(%URI{}), do: :ok

  defp check_orchestrator_uri(value) when is_binary(value) do
    _ = Ezagent.URI.new!(value)
    :ok
  rescue
    e -> {:error, {:orchestrator_uri_unparsable, value, Exception.message(e)}}
  end

  defp check_orchestrator_uri(other), do: {:error, {:orchestrator_uri_invalid, other}}

  # --- 7: definition is installable (resolvable in the registry) -----------

  defp check_install_resolves(%Definition{name: name}, ws) do
    case DefinitionRegistry.lookup(ws, name) do
      {:ok, _def, _obj} -> :ok
      :error -> {:error, {:unknown_socialware_install, name}}
    end
  end

  defp check_template_installable(%Definition{name: name}, ws) do
    content = %{installs: [name]}

    with {:ok, _resolved} <- Installation.resolved_template_installs(content, ws),
         {:ok, _behaviors} <- Installation.behavior_set_for_template(content, ws) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_template_installability_result, other}}
    end
  end

  # --- 8: routing_rules receivers resolve to declared roles ----------------

  defp check_routing_receivers(%Definition{routing_rules: rules} = def) do
    declared = declared_role_names(def)

    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      receivers = Map.get(rule, :receivers) || Map.get(rule, "receivers") || []

      case Enum.reject(receivers, &receiver_resolvable?(&1, declared)) do
        [] -> {:cont, :ok}
        bad -> {:halt, {:error, {:socialware_receiver_not_a_role, bad}}}
      end
    end)
  end

  defp receiver_resolvable?({:role, role_name}, declared) when is_binary(role_name),
    do: role_name in declared

  defp receiver_resolvable?(r, declared) when is_binary(r) do
    r in declared
  end

  defp receiver_resolvable?(_r, _declared), do: false

  defp declared_role_names(%Definition{roles: roles}) do
    roles
    |> Enum.map(& &1.role_name)
    |> Enum.uniq()
  end

  defp agent_role_slots(roles), do: Enum.filter(roles, &(&1.fill == :agent))

  # --- 10: routing_rules[].prompt_template_ref valid -----------------------

  defp check_prompt_template_refs(%Definition{routing_rules: rules, prompt_templates: templates}) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case Map.get(rule, :prompt_template_ref) || Map.get(rule, "prompt_template_ref") do
        nil ->
          {:cont, :ok}

        ref when is_binary(ref) ->
          case template_for(templates, ref) do
            nil ->
              {:halt, {:error, {:unknown_prompt_template_ref, ref}}}

            template ->
              case PromptTemplate.validate(template) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, {:invalid_prompt_template, ref, reason}}}
              end
          end

        other ->
          {:halt, {:error, {:invalid_prompt_template_ref, other}}}
      end
    end)
  end

  defp template_for(templates, ref) do
    Map.get(templates, ref) || Map.get(templates, to_string(ref))
  end

  # --- helpers -------------------------------------------------------------

  defp add(failures, _id, :ok), do: failures
  defp add(failures, id, {:error, detail}), do: [{id, detail} | failures]

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(str) when is_binary(str), do: Ezagent.URI.new!(str)
end
