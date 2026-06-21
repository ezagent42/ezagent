defmodule Ezagent.World.WorkspacePluginData do
  @moduledoc """
  Data builders for world workspace, plugin, profile, and generic surfaces.

  The module mirrors existing operator read models into JSON-safe state for the
  React shell. Mutations remain in their existing domain chokepoints or legacy
  LiveViews until a dedicated dispatch action is added.
  """

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
         %{component: "workspace_detail", name: name},
         base,
         _workspace,
         _caller,
         _caps
       ) do
    Map.merge(base, workspace_detail(name))
  end

  defp component_state(%{component: "plugins"}, base, _workspace_uri, _caller, _caps) do
    Map.put(base, "plugins", list_plugins())
  end

  defp component_state(%{component: "profile"}, base, _workspace_uri, %URI{} = caller_uri, caller_caps) do
    # Every world route is behind `live_session :world_require_entity`
    # (`LiveAuth.:require_entity` redirects+halts a nil entity), so the profile
    # caller is ALWAYS a real authenticated entity. No `|| admin_uri()` default:
    # let it crash on the impossible nil rather than silently leak admin's
    # profile/caps to an unauthenticated caller (#154 / let-it-crash).
    entity_uri = caller_uri
    entity_uri_str = encode_uri(entity_uri)

    base
    |> Map.put("entity_uri", entity_uri_str)
    |> Map.put("display_name", display_name(entity_uri_str))
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

  defp component_state(%{component: "feishu_bindings"}, base, workspace_uri, caller_uri, _caps) do
    base
    |> Map.put("bindings", feishu_bindings())
    |> Map.put("entity_options", entity_options(caller_uri, workspace_uri))
  end

  defp component_state(_route, base, _workspace_uri, _caller, _caps), do: base

  defp list_workspaces(caller_uri, caller_caps) do
    Ezagent.Workspace.list_workspaces_for(caller_uri, caller_caps)
    |> Enum.map(fn ws ->
      live_pid =
        case Ezagent.KindRegistry.lookup(ws.uri) do
          {:ok, pid} -> pid
          :error -> nil
        end

      %{
        "name" => ws.name,
        "uri" => encode_uri(ws.uri),
        "members_count" => length(ws.members || []),
        "templates_count" => map_size(ws.session_templates || %{}),
        "routing_rules_count" => length(ws.routing_rules || []),
        "live" => is_pid(live_pid) and Process.alive?(live_pid),
        "detail_path" => "/workspaces/#{URI.encode_www_form(ws.name)}"
      }
    end)
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp workspace_detail(name) when is_binary(name) do
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
          "session_templates" => template_rows(ws.session_templates || %{}),
          "routing_rules" => Enum.map(ws.routing_rules || [], &jsonable/1)
        }
    end
  rescue
    err -> %{"name" => name, "not_found" => true, "error" => inspect(err)}
  end

  defp workspace_detail(_), do: %{"not_found" => true}

  defp workspace_live?(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> is_pid(pid) and Process.alive?(pid)
      :error -> false
    end
  end

  defp template_rows(templates) when is_map(templates) do
    templates
    |> Enum.map(fn {name, template} ->
      %{
        "name" => to_string(name),
        "class" => template_class(template),
        "members_count" => template_member_count(template),
        "status" => template_status(template),
        "body" => jsonable(template)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp template_class(%{"class" => class}) when is_binary(class), do: class
  defp template_class(_), do: nil

  defp template_member_count(%{"members" => members}) when is_list(members), do: length(members)
  defp template_member_count(_), do: 0

  defp template_status(%{"class" => class}) when is_binary(class) do
    case Ezagent.TemplateRegistry.lookup(class) do
      {:ok, _module} -> "class_registered"
      :error -> "no_class"
    end
  end

  defp template_status(_), do: "missing_class"

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
    %{
      "uri" => encode_uri(Map.get(detail, :uri)),
      "pid" => inspect(Map.get(detail, :pid)),
      "kind_module" => Map.get(detail, :kind_module),
      "slices" => jsonable(Map.get(detail, :slices, %{})),
      "behaviors" => jsonable(Map.get(detail, :behaviors, []))
    }
  end

  defp feishu_bindings do
    user_binding = Module.concat([EzagentPluginFeishu, UserBinding])

    if Code.ensure_loaded?(user_binding) and function_exported?(user_binding, :list_all, 0) do
      user_binding
      |> apply(:list_all, [])
      |> Enum.map(fn binding ->
        %{
          "open_id" => field(binding, :open_id),
          "user_uri" => field(binding, :user_uri),
          "bound_by" => field(binding, :bound_by),
          "bound_at" => datetime(field(binding, :bound_at))
        }
      end)
    else
      []
    end
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp entity_options(caller_uri, workspace_uri) do
    Module.concat([Ezagent.UI, UriOptions])
    |> apply(:entities, [caller_uri, workspace_uri])
    |> Enum.map(&jsonable/1)
  rescue
    _ -> []
  end

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_other, _key), do: nil

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

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(nil), do: nil
  defp datetime(value), do: inspect(value)

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
  defp encode_uri(_), do: nil
end
