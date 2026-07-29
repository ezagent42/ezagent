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
            requires: [],
            bases: [],
            shape: [],
            views: [],
            roles: [],
            assets: [],
            routing_rules: [],
            prompt_templates: %{},
            legends: %{},
            orchestrator_template_uri: nil,
            adapters: [],
            visibility_policy: %{publish_policy: :auto, web_anon_access: false, scope: :private},
            owner_policy: %{type: :installer}

  @typedoc """
  A socialware-declared participant role slot. Agent slots name a recipe and
  default flavor; human slots are open runtime assignment slots. The optional
  `provider` names a cc-custom backend profile (spec 2026-07-17 Q2 — additive,
  shape-only here; the plugin catalog validates the NAME at materialization).
  """
  @type operate_edge :: %{role: String.t(), behavior: module(), action: atom()}
  @type role_slot ::
          %{
            required(:role_name) => String.t(),
            required(:fill) => :agent,
            required(:recipe) => String.t(),
            required(:flavor) => String.t(),
            optional(:provider) => String.t(),
            optional(:operates) => [operate_edge()]
          }
          | %{role_name: String.t(), fill: :human}

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          title: String.t() | nil,
          description: String.t(),
          uses: [String.t()],
          requires: [String.t()],
          bases: [module()],
          shape: [module()],
          views: [module()],
          roles: [role_slot()],
          assets: [map()],
          routing_rules: [map()],
          prompt_templates: map(),
          legends: map(),
          orchestrator_template_uri: URI.t() | nil,
          adapters: [map()],
          visibility_policy: map(),
          owner_policy: owner_policy()
        }

  @typedoc """
  Owner-derivation policy — socialware definitions never carry participant or
  owner instance URIs. The installer/caller becomes owner at install time.
  """
  @type owner_policy :: %{type: :installer}

  @doc "Build and validate a socialware definition from a persisted or authored map."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    raw_roles = get(attrs, :roles, [])
    routing_rules = list(attrs, :routing_rules)

    with :ok <- reject_retired_declaration_fields(attrs),
         {:ok, name} <- required_string(attrs, :name),
         {:ok, version} <- optional_string(attrs, :version, "0.1.0"),
         {:ok, title} <- optional_string(attrs, :title, nil),
         {:ok, description} <- optional_string(attrs, :description, ""),
         {:ok, uses} <- string_list(attrs, :uses),
         {:ok, requires} <- string_list(attrs, :requires),
         {:ok, bases} <- behavior_list(attrs, :bases),
         {:ok, shape} <- behavior_list(attrs, :shape),
         {:ok, views} <- behavior_list(attrs, :views),
         {:ok, roles} <- roles_list(attrs),
         :ok <- validate_operates_roles(roles),
         {:ok, visibility_policy} <- visibility_policy(attrs),
         {:ok, owner_policy} <- owner_policy(attrs),
         :ok <- reject_participant_instance_uris(raw_roles, routing_rules),
         :ok <- validate_anon_owner(visibility_policy, owner_policy) do
      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         title: title,
         description: description,
         uses: uses,
         requires: requires,
         bases: bases,
         shape: shape,
         views: views,
         roles: roles,
         assets: list(attrs, :assets),
         routing_rules: routing_rules,
         prompt_templates: map(attrs, :prompt_templates),
         legends: map(attrs, :legends),
         orchestrator_template_uri: optional_uri(attrs, :orchestrator_template_uri),
         adapters: list(attrs, :adapters),
         visibility_policy: visibility_policy,
         owner_policy: owner_policy
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
    # #189 PR-3 — every Session is a durable principal (URI == identity), so the
    # minimal non-dispatchable self-license carrier is a MANDATORY base of every
    # resolved session behavior set, prepended here (the single chokepoint that
    # builds every session's set) alongside `Session`. Auto-covers persisted
    # definitions whose stored `bases`/`shape` predate the carrier — no migration.
    self_license = Ezagent.ActionSet.SelfLicense
    mandatory = [self_license, session]

    # views are render ActionSets (each declares a UNIQUE `<sw>_render` cap-only
    # read action) — they MUST enter the spawned behavior set so the render cap
    # is registered on the Session Kind and `authorize_view` can check it.
    (mandatory ++ views ++ shape ++ Enum.reject(bases, &(&1 in mandatory)))
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
      requires: definition.requires,
      bases: Enum.map(definition.bases, &Atom.to_string/1),
      shape: Enum.map(definition.shape, &Atom.to_string/1),
      views: Enum.map(definition.views, &Atom.to_string/1),
      roles: json_safe(definition.roles),
      assets: json_safe(definition.assets),
      routing_rules: json_safe(definition.routing_rules),
      prompt_templates: json_safe(definition.prompt_templates),
      legends: json_safe(definition.legends),
      orchestrator_template_uri: uri_string(definition.orchestrator_template_uri),
      adapters: json_safe(definition.adapters),
      visibility_policy: stringify_visibility(definition.visibility_policy),
      owner_policy: stringify_owner_policy(definition.owner_policy)
    }
  end

  def body(attrs) when is_map(attrs) do
    with {:ok, definition} <- new(attrs) do
      body(definition)
    end
  end

  @doc """
  Deterministic content hash of the definition body (P0 §3.2) — the artifact
  identity. Env-independent: the same manifest bytes hash identically anywhere,
  regardless of key order or atom-vs-string keys.

  Single algorithm source: delegates to `Ezagent.Socialware.ContentHash.of/1`
  (identity layer), which `config_store` also uses to populate the stored
  `content_hash` column, so a fresh body and its persisted form agree.

  Accepts a `Definition` struct (hashed via `body/1`) or a raw body map.
  """
  @spec content_hash(t() | map()) :: String.t()
  def content_hash(%__MODULE__{} = definition), do: content_hash(body(definition))
  def content_hash(body) when is_map(body), do: Ezagent.Socialware.ContentHash.of(body)

  @doc """
  Derive the session `owner_uri` from the caller performing the install.
  """
  @spec owner_uri(t(), URI.t() | nil) :: URI.t() | nil
  def owner_uri(%__MODULE__{owner_policy: %{type: :installer}}, caller), do: caller

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

  # SHAPE-ONLY validation for the `roles` field. Recipe EXISTENCE
  # (`RecipeRegistry.lookup`) and role_name per-session uniqueness are NOT
  # resolved here — `new/1` has no workspace and a Definition is
  # authored/validated apart from any live session. Those checks live in the
  # workspace-aware gate (`mix ezagent.socialware.check`) and at
  # materialization/join time (`Members.role_name_conflict`).
  defp roles_list(attrs) do
    case get(attrs, :roles, []) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          case role_slot(item) do
            {:ok, slot} -> {:cont, {:ok, [slot | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, specs} -> {:ok, Enum.reverse(specs)}
          error -> error
        end

      other ->
        {:error, {:invalid_socialware_definition_field, :roles, other}}
    end
  end

  defp role_slot(item) when is_map(item) do
    recipe = get(item, :recipe)
    role_name = get(item, :role_name)
    fill = fill_type(get(item, :fill))

    case fill do
      :agent ->
        flavor = get(item, :flavor)

        with true <-
               non_empty_string?(recipe) and non_empty_string?(role_name) and
                 non_empty_string?(flavor),
             {:ok, operates} <- operates_list(item, role_name) do
          slot = %{role_name: role_name, fill: :agent, recipe: recipe, flavor: flavor}

          {:ok,
           slot
           |> maybe_put_provider(item)
           |> maybe_put_operates(operates)}
        else
          false -> {:error, {:invalid_socialware_role_slot, item}}
          {:error, _} = error -> error
        end

      :human ->
        with true <- non_empty_string?(role_name),
             [] <- get(item, :operates, []) do
          {:ok, %{role_name: role_name, fill: :human}}
        else
          false -> {:error, {:invalid_socialware_role_slot, item}}
          _ -> {:error, {:invalid_socialware_operates_source, role_name}}
        end

      _ ->
        {:error, {:invalid_socialware_role_slot, item}}
    end
  end

  defp role_slot(other), do: {:error, {:invalid_socialware_role_slot, other}}

  defp operates_list(item, source_role) do
    case get(item, :operates, []) do
      list when is_list(list) ->
        list
        |> Enum.reduce_while({:ok, []}, fn edge, {:ok, acc} ->
          case operate_edge(edge) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, edges} -> {:ok, Enum.reverse(edges)}
          error -> error
        end

      other ->
        {:error, {:invalid_socialware_operates, source_role, other}}
    end
  end

  defp operate_edge(edge) when is_map(edge) do
    role = get(edge, :role)
    behavior = get(edge, :behavior)
    action = get(edge, :action)

    with true <- non_empty_string?(role),
         {:ok, behavior} <- behavior_module(behavior),
         {:ok, action} <- operate_action(behavior, action) do
      {:ok, %{role: role, behavior: behavior, action: action}}
    else
      false -> {:error, {:invalid_socialware_operates_edge, edge}}
      {:error, _} = error -> error
    end
  end

  defp operate_edge(other), do: {:error, {:invalid_socialware_operates_edge, other}}

  defp operate_action(behavior, action) when is_atom(action) do
    if action != :any and action in Ezagent.ActionSet.action_names(behavior) do
      {:ok, action}
    else
      {:error, {:invalid_socialware_operates_action, behavior, action}}
    end
  end

  defp operate_action(behavior, action) when is_binary(action) do
    case Enum.find(Ezagent.ActionSet.action_names(behavior), &(Atom.to_string(&1) == action)) do
      nil -> {:error, {:invalid_socialware_operates_action, behavior, action}}
      declared -> {:ok, declared}
    end
  end

  defp operate_action(behavior, action),
    do: {:error, {:invalid_socialware_operates_action, behavior, action}}

  defp maybe_put_operates(slot, []), do: slot
  defp maybe_put_operates(slot, operates), do: Map.put(slot, :operates, operates)

  # Optional cc-custom backend profile NAME (spec 2026-07-17 Q2): additive and
  # shape-only — absent/empty leaves the key out (legacy slots byte-unchanged);
  # the plugin catalog fail-closed-validates the name at materialization.
  defp maybe_put_provider(slot, item) do
    case get(item, :provider) do
      provider when is_binary(provider) and provider != "" ->
        Map.put(slot, :provider, provider)

      _ ->
        slot
    end
  end

  defp validate_operates_roles(roles) do
    roles_by_name = Map.new(roles, &{&1.role_name, &1})

    Enum.reduce_while(roles, :ok, fn source, :ok ->
      source
      |> Map.get(:operates, [])
      |> Enum.reduce_while(:ok, fn %{role: target_role}, :ok ->
        case Map.get(roles_by_name, target_role) do
          %{fill: :agent} ->
            {:cont, :ok}

          _ ->
            {:halt,
             {:error, {:invalid_socialware_operates_target, source.role_name, target_role}}}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp fill_type(:agent), do: :agent
  defp fill_type("agent"), do: :agent
  defp fill_type(:human), do: :human
  defp fill_type("human"), do: :human
  defp fill_type(other), do: other

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp reject_retired_declaration_fields(attrs) do
    case Enum.find([:agents, :members], &has_key?(attrs, &1)) do
      nil -> :ok
      field -> {:error, {:retired_socialware_definition_field, field}}
    end
  end

  defp has_key?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  defp reject_participant_instance_uris(roles, routing_rules) do
    offenders =
      []
      |> collect_participant_uri_offenders(:roles, roles)
      |> collect_participant_uri_offenders(:routing_rules, routing_rules)

    case offenders do
      [] -> :ok
      _ -> {:error, {:socialware_definition_declares_instance_uri, Enum.reverse(offenders)}}
    end
  end

  defp collect_participant_uri_offenders(acc, section, value) do
    value
    |> participant_uri_values([])
    |> Enum.reduce(acc, fn value, acc -> [{section, value} | acc] end)
  end

  defp participant_uri_values(%URI{} = uri, acc),
    do: participant_uri_values(URI.to_string(uri), acc)

  defp participant_uri_values(%{} = map, acc) do
    Enum.reduce(map, acc, fn {_key, value}, acc -> participant_uri_values(value, acc) end)
  end

  defp participant_uri_values(list, acc) when is_list(list) do
    Enum.reduce(list, acc, fn value, acc -> participant_uri_values(value, acc) end)
  end

  defp participant_uri_values(value, acc) when is_binary(value) do
    if participant_instance_uri?(value), do: [value | acc], else: acc
  end

  defp participant_uri_values(_value, acc), do: acc

  defp participant_instance_uri?(value) do
    case Ezagent.URI.parse(value) do
      {:ok, %URI{} = uri} ->
        Ezagent.URI.type?(uri, :agent) or Ezagent.URI.type?(uri, :user)

      _ ->
        false
    end
  end

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
         web_anon_access:
           get(policy, :web_anon_access, false) == true or
             Map.get(policy, "web_anon_access", false) == true,
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

  # Definitions may not declare owner instance URIs. The only supported owner
  # policy is installer-derived ownership.
  defp owner_policy(attrs) do
    policy = map(attrs, :owner_policy)

    case owner_policy_type(get(policy, :type, :installer)) do
      :fixed ->
        {:error, {:socialware_definition_declares_owner_uri, policy}}

      :installer ->
        {:ok, %{type: :installer}}

      _ ->
        {:error, {:invalid_socialware_owner_policy, policy}}
    end
  end

  defp owner_policy_type(type) when type in [:installer, :fixed], do: type
  defp owner_policy_type("installer"), do: :installer
  defp owner_policy_type("fixed"), do: :fixed
  defp owner_policy_type(other), do: other

  defp validate_anon_owner(_visibility_policy, _owner_policy), do: :ok

  defp stringify_owner_policy(%{type: :installer}), do: %{"type" => "installer"}

  defp stringify_owner_policy(_), do: %{"type" => "installer"}

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
