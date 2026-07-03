defmodule Ezagent.Socialware.Definition do
  @moduledoc """
  Config-as-data socialware definition.

  P4 stores definitions as `ConfigObject`s under the structured non-URI subject
  `socialware:<name>` (workspace is a separate ConfigStore field) with key
  `"socialware"`. This module is the validation/rehydration boundary for that
  body.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            version: "0.1.0",
            title: nil,
            description: "",
            uses: [],
            bases: [],
            shape: [],
            views: [],
            agents: [],
            assets: [],
            members: [],
            routing_rules: [],
            prompt_templates: %{},
            legends: %{},
            orchestrator_template_uri: nil,
            adapters: [],
            visibility_policy: %{publish_policy: :auto, web_anon_access: false, scope: :private}

  @typedoc """
  A socialware-declared agent: the `recipe` (config义 — a RecipeRegistry name)
  this agent runs, and its `role_name` (routing义 — the per-session unique
  routing identifier, `{:role, name}` receiver). Both non-empty strings.
  """
  @type agent_spec :: %{recipe: String.t(), role_name: String.t(), flavor: String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          title: String.t() | nil,
          description: String.t(),
          uses: [String.t()],
          bases: [module()],
          shape: [module()],
          views: [module()],
          agents: [agent_spec()],
          assets: [map()],
          members: [map()],
          routing_rules: [map()],
          prompt_templates: map(),
          legends: map(),
          orchestrator_template_uri: URI.t() | nil,
          adapters: [map()],
          visibility_policy: map()
        }

  @doc "Build and validate a socialware definition from a persisted or authored map."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- required_string(attrs, :name),
         {:ok, version} <- optional_string(attrs, :version, "0.1.0"),
         {:ok, title} <- optional_string(attrs, :title, nil),
         {:ok, description} <- optional_string(attrs, :description, ""),
         {:ok, uses} <- string_list(attrs, :uses),
         {:ok, bases} <- behavior_list(attrs, :bases),
         {:ok, shape} <- behavior_list(attrs, :shape),
         {:ok, views} <- behavior_list(attrs, :views),
         {:ok, agents} <- agents_list(attrs),
         {:ok, visibility_policy} <- visibility_policy(attrs) do
      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         title: title,
         description: description,
         uses: uses,
         bases: bases,
         shape: shape,
         views: views,
         agents: agents,
         assets: list(attrs, :assets),
         members: list(attrs, :members),
         routing_rules: list(attrs, :routing_rules),
         prompt_templates: map(attrs, :prompt_templates),
         legends: map(attrs, :legends),
         orchestrator_template_uri: optional_uri(attrs, :orchestrator_template_uri),
         adapters: list(attrs, :adapters),
         visibility_policy: visibility_policy
       }}
    end
  end

  def new(other), do: {:error, {:invalid_socialware_definition, other}}

  @doc """
  The behavior set this definition installs onto a Session host.

  The host's own Session behavior is kept first, followed by flow shape, then
  remaining bases. This preserves the existing chat/socialware behavior order
  while still deriving the set from definition data.
  """
  @spec behaviors(t()) :: [module()]
  def behaviors(%__MODULE__{bases: bases, shape: shape, views: views}) do
    session = Ezagent.ActionSet.Session

    # views are render ActionSets (each declares a UNIQUE `<sw>_render` cap-only
    # read action) — they MUST enter the spawned behavior set so the render cap
    # is registered on the Session Kind and `authorize_view` can check it.
    ([session] ++ views ++ shape ++ Enum.reject(bases, &(&1 == session)))
    |> Enum.uniq()
  end

  @doc "JSON-safe body for ConfigStore persistence."
  @spec body(t() | map()) :: map()
  def body(%__MODULE__{} = definition) do
    %{
      name: definition.name,
      version: definition.version,
      title: definition.title,
      description: definition.description,
      uses: definition.uses,
      bases: Enum.map(definition.bases, &Atom.to_string/1),
      shape: Enum.map(definition.shape, &Atom.to_string/1),
      views: Enum.map(definition.views, &Atom.to_string/1),
      agents: json_safe(definition.agents),
      assets: json_safe(definition.assets),
      members: json_safe(definition.members),
      routing_rules: json_safe(definition.routing_rules),
      prompt_templates: json_safe(definition.prompt_templates),
      legends: json_safe(definition.legends),
      orchestrator_template_uri: uri_string(definition.orchestrator_template_uri),
      adapters: json_safe(definition.adapters),
      visibility_policy: stringify_visibility(definition.visibility_policy)
    }
  end

  def body(attrs) when is_map(attrs) do
    with {:ok, definition} <- new(attrs) do
      body(definition)
    end
  end

  defp required_string(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      other -> {:error, {:invalid_socialware_definition_field, key, other}}
    end
  end

  defp optional_string(attrs, key, default) do
    case get(attrs, key, default) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, {:invalid_socialware_definition_field, key, other}}
    end
  end

  defp string_list(attrs, key) do
    case get(attrs, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")) do
          {:ok, list}
        else
          {:error, {:invalid_socialware_definition_field, key, list}}
        end

      other ->
        {:error, {:invalid_socialware_definition_field, key, other}}
    end
  end

  defp behavior_list(attrs, key) do
    attrs
    |> get(key, [])
    |> case do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
          case behavior_module(value) do
            {:ok, mod} -> {:cont, {:ok, [mod | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, modules} -> {:ok, Enum.reverse(modules)}
          error -> error
        end

      other ->
        {:error, {:invalid_socialware_definition_field, key, other}}
    end
  end

  defp behavior_module(mod) when is_atom(mod) and not is_nil(mod) and not is_boolean(mod) do
    if Code.ensure_loaded?(mod) and Ezagent.ActionSet.new_style?(mod) do
      {:ok, mod}
    else
      {:error, {:invalid_socialware_behavior, mod}}
    end
  end

  defp behavior_module(name) when is_binary(name) do
    module_name = if String.starts_with?(name, "Elixir."), do: name, else: "Elixir." <> name

    module_name
    |> String.to_existing_atom()
    |> behavior_module()
  rescue
    ArgumentError -> {:error, {:invalid_socialware_behavior, name}}
  end

  defp behavior_module(other), do: {:error, {:invalid_socialware_behavior, other}}

  # SHAPE-ONLY validation for the `agents` field: a list of
  # `%{recipe: <non-empty-string>, role_name: <non-empty-string>}` (atom OR
  # string keys — persisted JSON round-trips as strings). Normalized to
  # atom-keyed maps. Recipe EXISTENCE (`RecipeRegistry.lookup`) and role_name
  # per-session uniqueness are NOT resolved here — `new/1` has no workspace and
  # a Definition is authored/validated apart from any live session. Those checks
  # live in the workspace-aware gate (`mix ezagent.socialware.check`) and at
  # materialization/join time (`Members.role_name_conflict`).
  defp agents_list(attrs) do
    case get(attrs, :agents, []) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          case agent_spec(item) do
            {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, specs} -> {:ok, Enum.reverse(specs)}
          error -> error
        end

      other ->
        {:error, {:invalid_socialware_definition_field, :agents, other}}
    end
  end

  defp agent_spec(item) when is_map(item) do
    recipe = get(item, :recipe)
    role_name = get(item, :role_name)
    flavor = get(item, :flavor, "cc")

    if is_binary(recipe) and recipe != "" and is_binary(role_name) and role_name != "" and
         is_binary(flavor) and flavor != "" do
      {:ok, %{recipe: recipe, role_name: role_name, flavor: flavor}}
    else
      {:error, {:invalid_socialware_agent, item}}
    end
  end

  defp agent_spec(other), do: {:error, {:invalid_socialware_agent, other}}

  defp visibility_policy(attrs) do
    policy = map(attrs, :visibility_policy)

    publish_policy =
      case get(policy, :publish_policy, :auto) do
        "auto" -> :auto
        :auto -> :auto
        "supervised" -> :supervised
        :supervised -> :supervised
        other -> other
      end

    scope =
      case get(policy, :scope, :private) do
        "private" -> :private
        :private -> :private
        "public" -> :public
        :public -> :public
        other -> other
      end

    if publish_policy in [:auto, :supervised] and scope in [:private, :public] do
      {:ok,
       %{
         publish_policy: publish_policy,
         web_anon_access: get(policy, :web_anon_access, false) == true,
         scope: scope
       }}
    else
      {:error,
       {:invalid_socialware_visibility_policy, %{publish_policy: publish_policy, scope: scope}}}
    end
  end

  defp stringify_visibility(policy) do
    %{
      "publish_policy" => policy |> Map.fetch!(:publish_policy) |> Atom.to_string(),
      "web_anon_access" => Map.get(policy, :web_anon_access, false) == true,
      "scope" => policy |> Map.get(:scope, :private) |> Atom.to_string()
    }
  end

  defp list(attrs, key) do
    case get(attrs, key, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp map(attrs, key) do
    case get(attrs, key, %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp optional_uri(attrs, key) do
    case get(attrs, key) do
      %URI{} = uri -> uri
      value when is_binary(value) and value != "" -> Ezagent.URI.new!(value)
      _ -> nil
    end
  end

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(_), do: nil

  defp json_safe(%URI{} = uri), do: URI.to_string(uri)

  defp json_safe({_, _} = tuple) do
    Ezagent.Routing.Matcher.to_json(tuple)
  rescue
    _ -> Tuple.to_list(tuple) |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {json_key(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(atom) when is_atom(atom) and not is_nil(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key), do: to_string(key)

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
