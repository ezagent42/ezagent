defmodule Ezagent.World.WorkspacePluginData do
  @moduledoc """
  Data builders for world workspace, plugin, profile, and generic surfaces.

  The module mirrors existing operator read models into JSON-safe state for the
  React shell. Mutations remain in their existing domain chokepoints or legacy
  LiveViews until a dedicated dispatch action is added.
  """

  alias Ezagent.World.FeishuBindingDispatch

  @type route :: %{
          component: String.t(),
          title: String.t(),
          path: String.t()
        }

  @doc "Build state for the non-admin workspace/plugin/profile component group."
  @spec state_for(route(), map()) :: map()
  def state_for(%{component: component} = route, opts) do
    workspace_uri = Map.get(opts, :workspace_uri)
    caller_uri = Map.get(opts, :caller_uri)
    caller_caps = Map.get(opts, :caller_caps, MapSet.new())

    base = %{
      "component" => component,
      "title" => route.title,
      "path" => route.path,
      "workspace_uri" => encode_uri(workspace_uri)
    }

    component_state(route, base, workspace_uri, caller_uri, caller_caps)
  end

  defp component_state(
         %{component: "workspaces_list"},
         base,
         _workspace_uri,
         caller_uri,
         caller_caps
       ) do
    Map.put(base, "workspaces", list_workspaces(caller_uri, caller_caps))
  end

  defp component_state(
         %{component: component, name: name},
         base,
         _workspace,
         caller,
         caps
       )
       when component in ["workspace_detail", "workspace_template_new"] do
    base
    |> Map.merge(workspace_detail(name, caller, caps))
    |> maybe_put_template_mode(component)
  end

  defp component_state(
         %{component: "kb"},
         base,
         workspace_uri,
         _caller,
         _caps
       ) do
    Map.put(base, "kb_agents", kb_agent_rows(workspace_uri))
  end

  defp component_state(%{component: "market"}, base, workspace_uri, _caller, _caps) do
    # PR-5 §15 — the market browse surface. HARD RULE: the card list comes from
    # `socialware_rows/1` (the `DefinitionRegistry.list/1`-scoped single source),
    # never a raw ConfigStore scan, so a private foreign def can never leak onto
    # the page. Retracted defs are already filtered by `list/1`.
    base
    |> Map.put("socialwares", socialware_rows(workspace_uri))
    |> Map.put("market_notice", nil)
    |> Map.put("market_error", nil)
  end

  defp component_state(%{component: "plugins"} = route, base, _workspace_uri, _caller, _caps) do
    base
    |> Map.put("plugins", list_plugins())
    |> Map.put("focus_slug", Map.get(route, :focus_slug))
  end

  defp component_state(
         %{component: "profile"},
         base,
         _workspace_uri,
         %URI{} = caller_uri,
         caller_caps
       ) do
    # Every world route is behind `live_session :world_require_entity`
    # (`LiveAuth.:require_entity` redirects+halts a nil entity), so the profile
    # caller is ALWAYS a real authenticated entity. Let it crash on the
    # impossible nil rather than silently leak the admin profile/caps to an
    # unauthenticated caller (#154 / let-it-crash).
    entity_uri = caller_uri
    entity_uri_str = encode_uri(entity_uri)

    base
    |> Map.put("entity_uri", entity_uri_str)
    |> Map.put("display_name", display_name(entity_uri_str))
    |> Map.put("editing_display_name", false)
    |> Map.put("caps_count", caps_count(caller_caps, entity_uri))
    |> Map.put("caps_path", caps_path(entity_uri_str))
  end

  defp component_state(
         %{component: "auto_derive", kind: kind, entity_uri: entity_uri},
         base,
         _workspace_uri,
         _caller,
         _caps
       ) do
    base
    |> Map.put("kind", kind && Atom.to_string(kind))
    |> Map.put("entity_uri", encode_uri(entity_uri))
    |> Map.merge(auto_derive(kind, entity_uri))
  end

  defp component_state(%{component: "feishu_bindings"}, base, workspace_uri, caller_uri, caps) do
    case FeishuBindingDispatch.list(workspace_uri, caller_uri, caps) do
      {:ok, bindings} ->
        base
        |> Map.put("bindings", bindings)
        |> Map.put("bindings_error", nil)

      {:error, code} ->
        base
        |> Map.put("bindings", [])
        |> Map.put("bindings_error", FeishuBindingDispatch.code_string(code))
    end
    |> Map.put("entity_options", entity_options(caller_uri, workspace_uri))
  end

  defp component_state(_route, base, _workspace_uri, _caller, _caps), do: base

  defp maybe_put_template_mode(state, "workspace_template_new"),
    do: Map.put(state, "template_mode", "new")

  defp maybe_put_template_mode(state, _component), do: state

  defp list_workspaces(caller_uri, caller_caps) do
    Ezagent.Workspace.list_workspaces_for(caller_uri, caller_caps)
    |> Enum.map(fn ws ->
      %{
        "name" => ws.name,
        "uri" => encode_uri(ws.uri),
        "members_count" => length(ws.members || []),
        "templates_count" => map_size(ws.session_templates || %{}),
        "routing_rules_count" => length(ws.routing_rules || []),
        "live" => Ezagent.LocalRuntime.kind_alive?(ws.uri),
        "detail_path" => "/workspaces/#{URI.encode_www_form(ws.name)}"
      }
    end)
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp workspace_detail(name, caller, caps) when is_binary(name) do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        %{"name" => name, "not_found" => true}

      ws ->
        %{
          "name" => ws.name,
          "uri" => encode_uri(ws.uri),
          "not_found" => false,
          "live" => workspace_live?(ws.uri),
          "members" => Enum.map(ws.members || [], &encode_uri/1),
          "session_templates" => template_rows(ws.session_templates || %{}, ws.name, caller),
          "routing_rules" => Enum.map(ws.routing_rules || [], &jsonable/1),
          "socialwares" => socialware_rows(ws.uri),
          "agent_flavors" => agent_flavors()
        }
        |> Map.merge(invite_state(ws.uri, caller, caps))
    end
  rescue
    err -> %{"name" => name, "not_found" => true, "error" => inspect(err)}
  end

  defp workspace_detail(_, _caller, _caps), do: %{"not_found" => true}

  defp agent_flavors do
    Ezagent.AgentFlavorRegistry.list_all()
    |> Enum.map(fn {flavor, _declaration} -> flavor end)
    |> Enum.sort()
  end

  defp invite_state(%URI{} = workspace_uri, %URI{} = caller, caps) do
    case Ezagent.Workspace.Invites.list(workspace_uri, %{
           caller: caller,
           authenticated_principal: caller,
           caps: caps
         }) do
      {:ok, %{invites: invites}} ->
        %{"can_manage_invites" => true, "invites" => Enum.map(invites, &jsonable/1)}

      {:error, _reason} ->
        %{"can_manage_invites" => false, "invites" => []}
    end
  end

  defp invite_state(_workspace_uri, _caller, _caps) do
    %{"can_manage_invites" => false, "invites" => []}
  end

  defp kb_agent_rows(%URI{scheme: "workspace"} = workspace_uri) do
    "kb"
    |> Ezagent.Agent.RecipeResolver.list_by_recipe(workspace_uri)
    |> Enum.map(fn uri ->
      uri_string = encode_uri(uri)

      %{
        "uri" => uri_string,
        "display_name" => display_name(uri_string) || Ezagent.URI.name!(uri)
      }
    end)
  rescue
    _ -> []
  end

  defp kb_agent_rows(_workspace_uri), do: []

  defp workspace_live?(%URI{} = uri) do
    Ezagent.LocalRuntime.kind_alive?(uri)
  end

  @doc """
  List SessionTemplate rows for a workspace detail surface.

  Read-plane PR-4 rework: the enumeration routes through the
  caller-authorizing `Ezagent.Session.TemplateReads` chokepoint
  (workspace member/operator only; fail-closed `[]`) — the live
  `KindRegistry` + durable `KindSnapshot` global scans are no longer
  touched from this presenter tier.
  """
  @spec session_template_rows(URI.t() | term(), String.t()) :: [map()]
  def session_template_rows(caller, workspace_name) when is_binary(workspace_name) do
    Ezagent.Session.TemplateReads.session_templates(caller, workspace_name)
  end

  @doc """
  Resolvable SessionTemplate names for the "New session" picker — the live
  SessionTemplate Kinds in this workspace (the names `create_session/3` can
  resolve, including any the operator just authored via the template form) plus
  the always-available `"default"` bootstrap class (auto-seeded on use).

  Single source of truth: `WorldLive` (sessions surface) and `AdminData`
  (Overview landing) both call this — never re-copy the body (arch cross-file
  duplicate-fn gate).
  """
  @spec session_template_names(URI.t() | term(), URI.t() | term()) :: [String.t()]
  def session_template_names(caller, %URI{scheme: "workspace"} = workspace_uri) do
    # F3: offer only Classes that are DIRECTLY creatable from this generic picker
    # (it supplies only the universal `session_name` arg). A Class whose
    # `instantiate/3` requires extra args declares `directly_creatable?/0 =>
    # false` and is filtered out, so it can't become the dropdown default and
    # fail closed with `{:invalid_template, …}` on create.
    classes =
      Ezagent.TemplateRegistry.registered_template_names()
      |> Enum.filter(&String.starts_with?(&1, "session."))
      |> Enum.filter(&class_directly_creatable?/1)
      |> Enum.map(&String.replace_prefix(&1, "session.", ""))

    instances =
      workspace_uri
      |> Ezagent.URI.name!()
      |> then(&session_template_rows(caller, &1))
      |> Enum.map(&Map.get(&1, "name"))

    # "default" is ALWAYS the first (selected) option — the React picker takes
    # `templates[0]` as its default, so the always-creatable bootstrap class must
    # lead regardless of how the other names sort.
    other =
      (classes ++ instances)
      |> Enum.reject(&(&1 in [nil, "", "default"]))
      |> Enum.uniq()
      |> Enum.sort()

    ["default" | other]
  rescue
    _ -> ["default"]
  end

  def session_template_names(_caller, _), do: ["default"]

  @doc "Installable socialware definitions visible to a workspace."
  @spec socialware_rows(URI.t() | term()) :: [map()]
  def socialware_rows(%URI{} = workspace_uri) do
    workspace_uri
    |> Ezagent.Socialware.DefinitionRegistry.list()
    |> Enum.map(fn row ->
      public? = Map.get(row, :public?, false)

      %{
        "name" => Map.get(row, :name),
        "title" => Map.get(row, :title),
        "description" => Map.get(row, :description),
        "version" => Map.get(row, :version),
        "config_id" => Map.get(row, :config_id),
        "content_hash" => Map.get(row, :content_hash),
        "roles" => socialware_role_rows(Map.get(row, :roles, []), workspace_uri),
        "scope" => Map.get(row, :scope, if(public?, do: "public", else: "private")),
        "workspace_uri" => encode_uri(Map.get(row, :workspace_uri)),
        "public" => public?
      }
    end)
  rescue
    _ -> []
  end

  def socialware_rows(_), do: []

  defp socialware_role_rows(roles, %URI{} = workspace_uri) when is_list(roles) do
    Enum.map(roles, fn
      %{fill: :agent, role_name: role_name, recipe: recipe, flavor: flavor} ->
        %{
          "role_name" => role_name,
          "fill" => "agent",
          "recipe" => recipe,
          "flavor" => flavor,
          "agent_options" => agent_options_for_recipe(recipe, workspace_uri)
        }

      %{fill: :human, role_name: role_name} ->
        %{"role_name" => role_name, "fill" => "human"}

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp socialware_role_rows(_roles, _workspace_uri), do: []

  defp agent_options_for_recipe(recipe, %URI{} = workspace_uri)
       when is_binary(recipe) and recipe != "" do
    uris = Ezagent.Agent.RecipeResolver.list_by_recipe(recipe, workspace_uri)
    display_map = Ezagent.EntityPresenter.display_many(Enum.map(uris, &URI.to_string/1))

    Enum.map(uris, fn uri ->
      uri_str = URI.to_string(uri)

      %{
        "uri" => uri_str,
        "display_name" => Map.get(display_map, uri_str, uri_str)
      }
    end)
  rescue
    _ -> []
  end

  defp agent_options_for_recipe(_recipe, _workspace_uri), do: []

  # F3: a registered `session.<name>` Class is offered by the generic picker only
  # when its Template Class declares itself directly creatable (default true;
  # advisor overrides false). An unregistered name conservatively passes (it's a
  # non-class instance name handled elsewhere).
  defp class_directly_creatable?(class_name) do
    case Ezagent.TemplateRegistry.lookup(class_name) do
      {:ok, module} -> Ezagent.Kind.Template.directly_creatable?(module)
      :error -> true
    end
  end

  defp template_rows(templates, workspace_name, caller) when is_map(templates) do
    legacy_rows =
      templates
      |> legacy_template_rows()

    # `body` normalization is the presenter's job (the world row
    # contract) — the chokepoint returns raw template content.
    session_rows =
      caller
      |> session_template_rows(workspace_name)
      |> Enum.map(fn row -> Map.update(row, "body", %{}, &jsonable/1) end)

    (session_rows ++ legacy_rows)
    |> Enum.uniq_by(&{&1["source"], &1["name"], &1["uri"]})
    |> Enum.sort_by(&{&1["name"], &1["source"]})
  end

  defp legacy_template_rows(templates) when is_map(templates) do
    templates
    |> Enum.map(fn {name, template} ->
      %{
        "name" => to_string(name),
        "source" => "workspace_template",
        "class" => template_class(template),
        "members_count" => template_member_count(template),
        "web_anon_access" => web_anon_access?(template),
        "status" => template_status(template),
        "body" => jsonable(template)
      }
    end)
  end

  defp template_class(%{"class" => class}) when is_binary(class), do: class
  defp template_class(_), do: nil

  defp template_member_count(%{"members" => members}) when is_list(members), do: length(members)
  defp template_member_count(%{members: members}) when is_list(members), do: length(members)
  defp template_member_count(_), do: 0

  defp web_anon_access?(content) when is_map(content) do
    content
    |> installs()
    |> Enum.any?(&socialware_web_anon_access?/1)
  end

  defp web_anon_access?(_), do: false

  defp installs(content) do
    case Map.get(content, :installs) || Map.get(content, "installs") do
      installs when is_list(installs) -> installs
      _ -> []
    end
  end

  defp socialware_web_anon_access?(ref) when is_binary(ref) do
    case Ezagent.Socialware.DefinitionRegistry.lookup(Ezagent.URI.workspace(:system), ref) do
      {:ok, definition, _object} ->
        definition.visibility_policy.web_anon_access == true

      :error ->
        false
    end
  end

  defp socialware_web_anon_access?(%{"ref" => ref}), do: socialware_web_anon_access?(ref)
  defp socialware_web_anon_access?(%{ref: ref}), do: socialware_web_anon_access?(ref)
  defp socialware_web_anon_access?(_), do: false

  defp template_status(%{"class" => class}) when is_binary(class) do
    case Ezagent.TemplateRegistry.lookup(class) do
      {:ok, _module} -> "class_registered"
      :error -> "no_class"
    end
  end

  defp template_status(_), do: "missing_class"

  @doc """
  Layer-2 left-rail nav entries contributed by INSTALLED plugins.

  Reuses the same `PluginRegistry.list_all/0` traversal as `list_plugins/0`
  (board-entry-and-modular-ui §2 "world 通用渲染") — reads every installed
  plugin that DECLARES `nav_surfaces/0` and serializes to JSON-safe
  `[%{"label", "path"}]` (+ optional `"icon"`) for the React sidebar.

  `nav_surfaces/0` is the **World-side** `Ezagent.World.UiSurfaceProvider`
  convention (NOT a core `Ezagent.Plugin` callback — decision 2026-06-30): a
  plugin contributes by defining a plain `nav_surfaces/0` function, read here
  via `function_exported?/3` (an absent function ⇒ no entry, "没装就没入口").
  Each entry is filtered through `UiSurfaceProvider.valid_nav_surface?/1`
  (fail-closed) so one plugin's malformed entry is skipped, not crash the whole
  sidebar. An uninstalled plugin is not in the registry, so it contributes
  nothing. Entries are deterministically ordered by plugin slug then declaration
  order.
  """
  @spec plugin_nav_surfaces() :: [%{required(String.t()) => String.t()}]
  def plugin_nav_surfaces do
    Ezagent.PluginRegistry.list_all()
    |> Enum.sort_by(fn plugin_module -> plugin_module.plugin_info().slug end)
    |> Enum.filter(&function_exported?(&1, :nav_surfaces, 0))
    |> Enum.flat_map(fn plugin_module ->
      plugin_module.nav_surfaces()
      |> Enum.filter(&Ezagent.World.UiSurfaceProvider.valid_nav_surface?/1)
      |> Enum.map(&nav_surface_row/1)
    end)
  rescue
    _ -> []
  end

  defp nav_surface_row(%{label: label, path: path} = surface)
       when is_binary(label) and is_binary(path) do
    base = %{"label" => label, "path" => path}

    case Map.get(surface, :icon) do
      icon when is_binary(icon) -> Map.put(base, "icon", icon)
      _ -> base
    end
  end

  @doc """
  Layer-3 conversation tabs contributed by INSTALLED plugins, RESOLVED for a
  given `session_uri`.

  Same `PluginRegistry.list_all/0` traversal as `plugin_nav_surfaces/0`
  (board-entry-and-modular-ui §2 "world 通用渲染") — reads every installed
  plugin that DECLARES `session_tabs/0` and keeps the tabs whose `:condition`
  holds for this session (`:always` / absent ⇒ always; a 1-arity predicate ⇒
  evaluated with the session URI string). kanban's condition is the cheap
  `BoardConfig.session_bound?/1` file read, so a session BOUND to a board grows
  the kanban tab and a free session does not.

  `session_tabs/0` is the **World-side** `Ezagent.World.UiSurfaceProvider`
  convention (NOT a core `Ezagent.Plugin` callback — decision 2026-06-30): read
  here via `function_exported?/3` (absent function ⇒ no tab) and filtered
  through `UiSurfaceProvider.valid_session_tab?/1` (fail-closed) so a malformed
  entry is skipped, not crash the view switcher. Serializes to JSON-safe
  `[%{"id", "label"}]`; an uninstalled plugin contributes nothing ("没插件就没
  tab"). Ordered by plugin slug then declaration.
  """
  @spec plugin_session_tabs(URI.t() | String.t() | nil) :: [%{required(String.t()) => String.t()}]
  def plugin_session_tabs(session_uri) do
    session_str = encode_uri(session_uri) || session_uri

    Ezagent.PluginRegistry.list_all()
    |> Enum.sort_by(fn plugin_module -> plugin_module.plugin_info().slug end)
    |> Enum.filter(&function_exported?(&1, :session_tabs, 0))
    |> Enum.flat_map(fn plugin_module ->
      plugin_module.session_tabs()
      |> Enum.filter(&Ezagent.World.UiSurfaceProvider.valid_session_tab?/1)
      |> Enum.filter(&session_tab_visible?(&1, session_str))
      |> Enum.map(&session_tab_row/1)
    end)
  rescue
    _ -> []
  end

  # Evaluate a session tab's per-session visibility condition. Absent / `:always`
  # ⇒ visible; a 1-arity predicate ⇒ called with the session URI string. A
  # predicate that raises is treated as "not visible" (fail-closed) so one
  # plugin's bad condition can't break the whole view switcher.
  defp session_tab_visible?(%{condition: :always}, _session_str), do: true

  defp session_tab_visible?(%{condition: fun}, session_str) when is_function(fun, 1) do
    fun.(session_str) == true
  rescue
    _ -> false
  end

  defp session_tab_visible?(%{}, _session_str), do: true

  defp session_tab_row(%{id: id, label: label}) when is_binary(id) and is_binary(label),
    do: %{"id" => id, "label" => label}

  defp list_plugins do
    Ezagent.PluginRegistry.list_all()
    |> Enum.map(fn plugin_module ->
      info = plugin_module.plugin_info()
      {config_path, config_label} = config_target(plugin_module.config_surface())

      %{
        "slug" => info.slug,
        "name" => info.name,
        "description" => info.description,
        "version" => info.version,
        "config_path" => config_path,
        "config_label" => config_label
      }
    end)
    |> Enum.sort_by(& &1["slug"])
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp config_target(%{kind: :route, path: path, label: label})
       when is_binary(path) and is_binary(label),
       do: {path, label}

  defp config_target(%{kind: :flavor, flavor: flavor, label: label})
       when is_binary(flavor) and is_binary(label),
       do: {"/identities?filter=agent:#{URI.encode_www_form(flavor)}", label}

  defp config_target(_), do: {nil, "Configure"}

  defp auto_derive(nil, _entity_uri), do: %{"error" => "unknown_kind", "instances" => []}

  defp auto_derive(kind, nil) when is_atom(kind) do
    %{
      "kind" => Atom.to_string(kind),
      "instances" => Enum.map(auto_derive_list_instances(kind), &auto_instance_row(&1, kind))
    }
  rescue
    err -> %{"kind" => Atom.to_string(kind), "instances" => [], "error" => inspect(err)}
  end

  defp auto_derive(kind, %URI{} = entity_uri) when is_atom(kind) do
    case auto_derive_instance_detail(entity_uri) do
      {:ok, detail} ->
        %{"kind" => Atom.to_string(kind), "detail" => auto_detail(detail)}

      {:error, reason} ->
        %{"kind" => Atom.to_string(kind), "detail_error" => inspect(reason)}
    end
  rescue
    err -> %{"kind" => Atom.to_string(kind), "detail_error" => inspect(err)}
  end

  defp auto_derive_list_instances(kind) do
    auto_derive_module()
    |> apply(:list_instances, [kind])
  end

  defp auto_derive_instance_detail(%URI{} = uri) do
    auto_derive_module()
    |> apply(:instance_detail, [uri])
  end

  defp auto_derive_module do
    module = Module.concat([EzagentDomainUi, AutoDerive])

    if Code.ensure_loaded?(module) do
      module
    else
      raise "EzagentDomainUi.AutoDerive is unavailable"
    end
  end

  defp auto_instance_row(
         %{uri: uri, pid: pid, slice_keys: slice_keys, kind_module: kind_module},
         kind
       ) do
    uri_str = encode_uri(uri)

    %{
      "uri" => uri_str,
      "pid" => inspect(pid),
      "kind_module" => inspect(kind_module),
      "slice_keys" => Enum.map(slice_keys || [], &to_string/1),
      "detail_path" => "/plugins/auto/#{Atom.to_string(kind)}/#{URI.encode_www_form(uri_str)}"
    }
  end

  defp auto_detail(detail) do
    uri = Map.get(detail, :uri)

    %{
      "uri" => encode_uri(uri),
      "pid" => inspect(Map.get(detail, :pid)),
      "kind_module" => Map.get(detail, :kind_module),
      "slices" => jsonable(Map.get(detail, :slices, %{})),
      "behaviors" => jsonable(Map.get(detail, :behaviors, [])),
      "credential_cascade" => credential_cascade(uri, detail)
    }
  end

  defp credential_cascade(%URI{} = uri, detail),
    do: Ezagent.World.CredentialCascade.detail_for(uri, detail)

  defp credential_cascade(_uri, _detail), do: nil

  defp entity_options(caller_uri, workspace_uri) do
    Module.concat([Ezagent.UI, UriOptions])
    |> apply(:entities, [caller_uri, workspace_uri])
    |> Enum.map(&jsonable/1)
  rescue
    _ -> []
  end

  defp display_name(nil), do: nil
  defp display_name(entity_uri), do: Ezagent.EntityPresenter.display(entity_uri)

  defp caps_count(%MapSet{} = caps, _entity_uri), do: MapSet.size(caps)
  defp caps_count(caps, _entity_uri) when is_list(caps), do: length(caps)

  defp caps_count(_caps, _entity_uri), do: 0

  defp caps_path(nil), do: nil

  defp caps_path(entity_uri) do
    kind =
      case Ezagent.URI.new!(entity_uri) |> Ezagent.URI.type() do
        {:ok, "agent"} -> "agents"
        _ -> "users"
      end

    "/identities/#{kind}/#{URI.encode_www_form(entity_uri)}/caps"
  rescue
    _ -> nil
  end

  defp jsonable(%URI{} = uri), do: URI.to_string(uri)
  defp jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp jsonable(%_struct{} = struct), do: struct |> Map.from_struct() |> jsonable()

  defp jsonable(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(other), do: other

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(uri) when is_binary(uri), do: uri
  defp encode_uri(_), do: nil
end
