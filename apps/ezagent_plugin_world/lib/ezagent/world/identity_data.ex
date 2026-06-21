defmodule Ezagent.World.IdentityData do
  @moduledoc """
  Data builders for the world plugin's identities component group.

  The module mirrors the existing LiveView surfaces at a data boundary only:
  it reads the same domain registries/facades and returns JSON-safe maps for
  the React shell. Mutations stay in `WorldLive` so they can dispatch with the
  socket caller and LiveAuth-provided caps.
  """

  alias Ezagent.Invocation

  @fallback_flavors ~w(cc echo curl)

  @type route :: %{
          component: String.t(),
          title: String.t(),
          path: String.t(),
          entity_uri: URI.t() | nil
        }

  @doc "Build the world state payload for one identities-group route."
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
         %{component: "identities", filter: filter},
         base,
         workspace_uri,
         _caller,
         _caps
       ) do
    rows = list_entities(workspace_uri, filter)

    base
    |> Map.put("filter", filter)
    |> Map.put("entities", rows)
    |> Map.put("agent_flavors", agent_flavors(rows))
  end

  defp component_state(%{component: "users_table"}, base, _workspace_uri, _caller, _caps) do
    Map.put(base, "users", list_users())
  end

  defp component_state(%{component: "agents_table"}, base, workspace_uri, _caller, _caps) do
    Map.put(base, "agents", list_entities(workspace_uri, "agents"))
  end

  defp component_state(
         %{component: "entity_caps", entity_uri: entity_uri},
         base,
         _workspace,
         caller,
         caps
       ) do
    base
    |> Map.put("entity_uri", encode_uri(entity_uri))
    |> Map.put("entity_kind", entity_kind(entity_uri))
    |> Map.put("caps", list_entity_caps(entity_uri, caller, caps))
  end

  defp component_state(
         %{component: "agent_detail", entity_uri: agent_uri},
         base,
         _workspace,
         _caller,
         _caps
       ) do
    base
    |> Map.put("agent_uri", encode_uri(agent_uri))
    |> Map.put("agent_status", agent_status(agent_uri))
    |> Map.put("bridge", bridge_entry(agent_uri))
  end

  defp component_state(%{component: "agent_new_form"}, base, workspace_uri, _caller, _caps) do
    flavors = list_flavors()
    default_flavor = if "cc" in flavors, do: "cc", else: List.first(flavors) || "cc"

    base
    |> Map.put("flavors", flavors)
    |> Map.put("default_flavor", default_flavor)
    |> Map.put("preview_uri", preview_agent_uri(workspace_uri, ""))
  end

  defp component_state(
         %{component: "agent_api_keys", entity_uri: agent_uri},
         base,
         _workspace,
         caller,
         caps
       ) do
    base
    |> Map.put("agent_uri", encode_uri(agent_uri))
    |> Map.put("api_keys", list_api_keys(agent_uri, caller, caps))
    |> Map.put("creator_uri", encode_uri(lookup_creator_uri(agent_uri)))
    |> Map.put("can_edit", can_edit_api_keys?(agent_uri, caller))
  end

  defp component_state(
         %{component: "agent_extensions", entity_uri: agent_uri},
         base,
         _workspace,
         caller,
         caps
       ) do
    base
    |> Map.put("agent_uri", encode_uri(agent_uri))
    |> Map.merge(list_extensions(agent_uri, caller, caps))
  end

  defp component_state(
         %{component: "pty_terminal", entity_uri: agent_uri},
         base,
         _workspace,
         _caller,
         _caps
       ) do
    agent_uri_str = encode_uri(agent_uri)

    base
    |> Map.put("agent_uri", agent_uri_str)
    |> Map.put("agent_detail_path", detail_path("agent", agent_uri_str))
    |> Map.put("agent_status", agent_status(agent_uri))
    |> Map.put("pty_alive", pty_alive?(agent_uri))
    |> Map.put("pty_phase", pty_phase(agent_uri))
    |> Map.put("pty_initial_buffer", pty_initial_buffer(agent_uri))
  end

  defp component_state(_route, base, _workspace, _caller, _caps), do: base

  @doc "List entity rows for the identities and agents components."
  @spec list_entities(URI.t() | nil, String.t()) :: [map()]
  def list_entities(workspace_uri, filter) do
    workspace_filter = workspace_name_filter(workspace_uri)

    rows =
      Ezagent.KindRegistry.list_all()
      |> Enum.flat_map(fn {uri_str, pid} ->
        with {:ok, %URI{scheme: "entity"} = uri} <- safe_parse_entity(uri_str),
             {:ok, entity_type} <- Ezagent.URI.type(uri),
             true <- entity_type in ["user", "agent"],
             {:ok, entity_name} <- Ezagent.URI.name(uri),
             {:ok, workspace_name} <- Ezagent.URI.workspace_name(uri),
             true <- entity_matches_workspace?(workspace_name, workspace_filter) do
          [
            %{
              "uri" => uri_str,
              "kind" => entity_type,
              "name" => entity_name,
              "display_name" => entity_name,
              "flavor" => flavor_for(entity_type, uri),
              "alive" => is_pid(pid) and Process.alive?(pid),
              "caps_path" => caps_path(entity_type, uri_str),
              "detail_path" => detail_path(entity_type, uri_str),
              "api_keys_path" => api_keys_path(entity_type, uri_str),
              "extensions_path" => extensions_path(entity_type, uri_str)
            }
          ]
        else
          _ -> []
        end
      end)
      |> Enum.filter(&matches_filter?(&1, filter))
      |> Enum.sort_by(& &1["uri"])

    display_map = Ezagent.EntityPresenter.display_many(Enum.map(rows, & &1["uri"]))

    Enum.map(rows, fn row ->
      Map.put(row, "display_name", Map.get(display_map, row["uri"], row["name"]))
    end)
  rescue
    _ -> []
  end

  @doc "List provisioned user rows for the users table component."
  @spec list_users() :: [map()]
  def list_users do
    system_members =
      case Ezagent.Workspace.Store.get_by_name("system") do
        %{members: members} -> MapSet.new(members, &Ezagent.URI.stable_key/1)
        _ -> MapSet.new()
      end

    users = Ezagent.Users.list_all()
    display_map = Ezagent.EntityPresenter.display_many(Enum.map(users, &URI.to_string(&1.uri)))

    users
    |> Enum.map(fn user ->
      uri_str = URI.to_string(user.uri)
      online? = Ezagent.Presence.present?(user.uri)

      %{
        "uri" => uri_str,
        "display_name" => Map.get(display_map, uri_str, uri_str),
        "has_password" => not is_nil(user.password_hash),
        "cap_count" => length(user.caps),
        "online" => online?,
        "transports" => transports_summary(Ezagent.Presence.list(user.uri)),
        "system_member" => MapSet.member?(system_members, Ezagent.URI.stable_key(user.uri)),
        "caps_path" => caps_path("user", uri_str)
      }
    end)
    |> Enum.sort_by(& &1["uri"])
  rescue
    _ -> []
  end

  @doc "Registered agent flavors for the new-agent component."
  @spec list_flavors() :: [String.t()]
  def list_flavors do
    case Ezagent.AgentFlavorRegistry.list_all() do
      [] -> @fallback_flavors
      entries -> entries |> Enum.map(fn {flavor, _decl} -> flavor end) |> Enum.sort()
    end
  rescue
    _ -> @fallback_flavors
  end

  @doc "Preview an agent URI under the current workspace."
  @spec preview_agent_uri(URI.t() | nil, String.t()) :: String.t()
  def preview_agent_uri(workspace_uri, name) do
    workspace_name = workspace_name(workspace_uri)

    cond do
      String.trim(to_string(name)) == "" -> "<agent-uri>"
      true -> workspace_name |> Ezagent.URI.agent(String.trim(name)) |> URI.to_string()
    end
  rescue
    _ -> "<agent-uri>"
  end

  defp list_entity_caps(%URI{} = entity_uri, caller_uri, caller_caps) do
    target = Ezagent.URI.with_action(entity_uri, :identity, :list_caps)

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: caller_uri, caps: caller_caps, reply: :sync}
         }) do
      {:ok, %{caps: caps}} when is_list(caps) -> Enum.map(caps, &cap_row/1)
      {:error, reason} -> %{"error" => inspect(reason)}
      other -> %{"error" => inspect(other)}
    end
  rescue
    err -> %{"error" => inspect(err)}
  end

  defp list_entity_caps(_entity_uri, _caller_uri, _caller_caps),
    do: %{"error" => "invalid_entity"}

  defp cap_row(cap) do
    %{
      "kind" => inspect(cap.kind),
      "behavior" => inspect(cap.behavior),
      "action" => inspect(Ezagent.Capability.action_of(cap)),
      "instance" => inspect(cap.instance),
      "workspace_uri" => encode_uri(cap.workspace_uri),
      "granted_by" => encode_uri(cap.granted_by)
    }
  end

  defp agent_status(%URI{} = agent_uri) do
    agent_uri
    |> Ezagent.Domain.Agent.lifecycle_status()
    |> jsonable()
  rescue
    err -> %{"phase" => "error", "detail" => inspect(err)}
  end

  defp bridge_entry(%URI{} = agent_uri) do
    if Code.ensure_loaded?(Ezagent.AgentBridge.Registry) do
      Ezagent.AgentBridge.Registry.list_connected()
      |> Enum.find(fn {uri, _entry} -> URI.to_string(uri) == URI.to_string(agent_uri) end)
      |> case do
        {_uri, entry} -> jsonable(entry)
        nil -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp pty_alive?(%URI{} = agent_uri), do: Ezagent.Domain.Pty.alive?(agent_uri)
  defp pty_alive?(_), do: false

  defp pty_phase(%URI{} = agent_uri) do
    case Ezagent.Domain.Pty.status(agent_uri) do
      %{phase: phase} when is_atom(phase) -> Atom.to_string(phase)
      %{phase: phase} when is_binary(phase) -> phase
      %{running: true} -> "running"
      _ -> "dead"
    end
  end

  defp pty_phase(_), do: "unknown"

  defp pty_initial_buffer(%URI{} = agent_uri) do
    case Ezagent.Domain.Pty.Server.snapshot_buffer(agent_uri) do
      {:ok, buffer} when is_binary(buffer) -> buffer
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp list_api_keys(%URI{} = agent_uri, caller_uri, caller_caps) do
    target = Ezagent.URI.with_action(agent_uri, :identity, :list_api_keys)

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: caller_uri, caps: caller_caps, reply: :sync}
         }) do
      {:ok, %{api_keys: list}} when is_list(list) -> Enum.map(list, &jsonable/1)
      {:error, reason} -> %{"error" => inspect(reason)}
      other -> %{"error" => inspect(other)}
    end
  rescue
    err -> %{"error" => inspect(err)}
  end

  defp lookup_creator_uri(%URI{} = agent_uri) do
    case Ezagent.Behavior.ApiKeys.data_owner(agent_uri) do
      %URI{} = creator -> creator
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp can_edit_api_keys?(agent_uri, caller_uri) do
    creator_uri = lookup_creator_uri(agent_uri)

    same_uri?(caller_uri, Ezagent.Entity.User.admin_uri()) or
      (not is_nil(creator_uri) and same_uri?(caller_uri, creator_uri))
  end

  defp list_extensions(%URI{} = agent_uri, caller_uri, caller_caps) do
    with {:ok, template_class} <-
           EzagentDomainInstanceMessage.SessionCreator.TemplateResolver.resolve_agent_template_class(
             agent_uri
           ),
         {:ok, %{config_dir_path: dir}} when is_binary(dir) <-
           sandbox_read(agent_uri, caller_uri, caller_caps),
         {:ok, extensions} <- template_class.list_extensions(dir) do
      %{
        "config_dir_path" => dir,
        "extensions" => Enum.map(extensions, &jsonable/1)
      }
    else
      {:ok, %{config_dir_path: nil}} ->
        %{"config_dir_path" => nil, "extensions" => [], "notice" => "no_config_dir"}

      {:error, reason} ->
        %{"config_dir_path" => nil, "extensions" => [], "error" => inspect(reason)}

      other ->
        %{"config_dir_path" => nil, "extensions" => [], "error" => inspect(other)}
    end
  rescue
    err -> %{"config_dir_path" => nil, "extensions" => [], "error" => inspect(err)}
  end

  defp sandbox_read(agent_uri, caller_uri, caller_caps) do
    target = Ezagent.URI.with_action(agent_uri, :sandbox, :read)

    case Invocation.dispatch(%Invocation{
           target: target,
           mode: :call,
           args: %{},
           ctx: %{caller: caller_uri, caps: caller_caps, reply: {:caller_inbox, self()}}
         }) do
      {:ok, result} when is_map(result) -> {:ok, result}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_sandbox_read, other}}
    end
  end

  defp agent_flavors(rows) do
    rows
    |> Enum.filter(&(&1["kind"] == "agent"))
    |> Enum.map(& &1["flavor"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp flavor_for("agent", %URI{} = uri) do
    with {:ok, flavor} when is_binary(flavor) and flavor != "" <-
           Ezagent.UriQuery.resolve(:flavor, uri) do
      flavor
    else
      _ -> ""
    end
  end

  defp flavor_for(_, _), do: ""

  defp workspace_name_filter(%URI{scheme: "workspace"} = uri), do: workspace_name(uri)
  defp workspace_name_filter(_), do: :all

  defp workspace_name(%URI{scheme: "workspace"} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      :error -> raise ArgumentError, "workspace URI is missing a name: #{inspect(uri)}"
    end
  end

  defp workspace_name(other),
    do: raise(ArgumentError, "expected workspace URI, got: #{inspect(other)}")

  defp entity_matches_workspace?(_workspace_name, :all), do: true
  defp entity_matches_workspace?(workspace_name, workspace_name), do: true
  defp entity_matches_workspace?(_, _), do: false

  defp matches_filter?(_row, "all"), do: true
  defp matches_filter?(%{"kind" => "user"}, "users"), do: true
  defp matches_filter?(%{"kind" => "agent"}, "agents"), do: true
  defp matches_filter?(%{"kind" => "agent", "flavor" => flavor}, "agent:" <> flavor), do: true
  defp matches_filter?(_row, _filter), do: false

  defp entity_kind(%URI{} = uri) do
    case Ezagent.URI.type(uri) do
      {:ok, kind} when kind in ["user", "agent"] -> kind
      _ -> "entity"
    end
  end

  defp entity_kind(_), do: "entity"

  defp caps_path(kind, uri_str) when kind in ["user", "agent"] do
    "/identities/#{kind}s/#{URI.encode_www_form(uri_str)}/caps"
  end

  defp caps_path(_kind, _uri_str), do: nil

  defp detail_path("agent", uri_str), do: "/identities/agents/#{URI.encode_www_form(uri_str)}"
  defp detail_path(_kind, _uri_str), do: nil

  defp api_keys_path("agent", uri_str),
    do: "/identities/agents/#{URI.encode_www_form(uri_str)}/api-keys"

  defp api_keys_path(_kind, _uri_str), do: nil

  defp extensions_path("agent", uri_str),
    do: "/identities/agents/#{URI.encode_www_form(uri_str)}/extensions"

  defp extensions_path(_kind, _uri_str), do: nil

  defp transports_summary(presence_list) do
    for entries <- Map.values(presence_list),
        meta <- entries,
        transport = Map.get(meta, :transport),
        not is_nil(transport),
        uniq: true do
      to_string(transport)
    end
  rescue
    _ -> []
  end

  defp safe_parse_entity(s) when is_binary(s) do
    case Ezagent.URI.parse(s) do
      {:ok, %URI{scheme: "entity"} = uri} -> {:ok, uri}
      _ -> :error
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right), do: URI.to_string(left) == URI.to_string(right)
  defp same_uri?(_, _), do: false

  defp jsonable(%URI{} = uri), do: URI.to_string(uri)
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp jsonable(nil), do: nil
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  defp jsonable(value) when is_map(value) do
    value
    |> Map.from_struct()
    |> Enum.map(fn {key, val} -> {to_string(key), jsonable(val)} end)
    |> Map.new()
  rescue
    _ -> inspect(value)
  end

  defp jsonable(value), do: inspect(value)

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end
