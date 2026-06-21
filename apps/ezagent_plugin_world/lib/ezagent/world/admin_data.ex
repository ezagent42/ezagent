defmodule Ezagent.World.AdminData do
  @moduledoc """
  Data builders for the world plugin's admin component group.

  The admin group is deliberately read-heavy in v1: it mirrors the existing
  operator surfaces as JSON-safe summaries while preserving all existing
  mutation chokepoints for future form work.
  """

  @type route :: %{
          component: String.t(),
          title: String.t(),
          path: String.t(),
          session_uri: URI.t() | nil
        }

  @doc "Build a JSON-safe world state payload for one admin route."
  @spec state_for(route(), map()) :: map()
  def state_for(%{component: component} = route, opts) do
    workspace_uri = Map.get(opts, :workspace_uri)
    caller_uri = Map.get(opts, :caller_uri)

    base = %{
      "component" => component,
      "title" => route.title,
      "path" => route.path,
      "workspace_uri" => encode_uri(workspace_uri)
    }

    component_state(route, base, workspace_uri, caller_uri)
  end

  defp component_state(%{component: "dashboard"}, base, _workspace_uri, _caller_uri) do
    kinds = Ezagent.KindRegistry.list_all()

    base
    |> Map.put("kpis", %{
      "kinds" => length(kinds),
      "sessions" => count_scheme(kinds, "session"),
      "workspaces" => count_scheme(kinds, "workspace"),
      "entities" => count_scheme(kinds, "entity"),
      "agents" => count_entity_type(kinds, "agent")
    })
    |> Map.put("cc_orchestrator_status", cc_orchestrator_status())
  end

  defp component_state(%{component: "observability"}, base, workspace_uri, _caller_uri) do
    base
    |> Map.put("audit_rows", recent_invocations(25, workspace_uri))
    |> Map.put("bridges", bridges())
    |> Map.put("snapshots", snapshots(12, workspace_uri))
  end

  defp component_state(%{component: "entity_registry"}, base, _workspace_uri, _caller_uri) do
    Map.put(base, "entities", registry_rows())
  end

  defp component_state(%{component: "snapshots"}, base, workspace_uri, _caller_uri) do
    Map.put(base, "snapshots", snapshots(50, workspace_uri))
  end

  defp component_state(%{component: "templates"}, base, _workspace_uri, _caller_uri) do
    Map.put(base, "templates", template_rows())
  end

  defp component_state(%{component: "caps_admin"}, base, workspace_uri, _caller_uri) do
    base
    |> Map.put("grantable", grantable_caps())
    |> Map.put("default_grants", default_grants(workspace_uri))
  end

  defp component_state(%{component: "authz_audit"}, base, workspace_uri, _caller_uri) do
    Map.put(base, "audit_rows", recent_invocations(100, workspace_uri))
  end

  defp component_state(%{component: "settings"}, base, _workspace_uri, caller_uri) do
    Map.put(base, "settings", settings_state(caller_uri))
  end

  defp component_state(%{component: "routing"}, base, _workspace_uri, _caller_uri) do
    base
    |> Map.put("rules", routing_rules())
    |> Map.put("external_mirror_bindings", external_mirror_bindings(25))
  end

  defp component_state(
         %{component: "external_mirror", session_uri: session_uri},
         base,
         _workspace_uri,
         _caller_uri
       ) do
    base
    |> Map.put("session_uri", encode_uri(session_uri))
    |> Map.put("bindings", external_mirror_bindings_for(session_uri))
  end

  defp component_state(_route, base, _workspace_uri, _caller_uri), do: base

  @doc "Build settings form state for world admin settings."
  @spec settings_state(URI.t() | nil) :: map()
  def settings_state(caller_uri) do
    smtp_config = Ezagent.AppSettings.get("smtp_config") || %{}

    %{
      "smtp_configured" => Ezagent.AppSettings.smtp_configured?(),
      "smtp" => %{
        "host" => Map.get(smtp_config, "host", ""),
        "port" => to_string(Map.get(smtp_config, "port", "")),
        "username" => Map.get(smtp_config, "username", ""),
        "from_address" => Map.get(smtp_config, "from_address", ""),
        "tls" => Map.get(smtp_config, "tls", true),
        "has_password" => Map.get(smtp_config, "password", "") not in [nil, ""]
      },
      "smtp_test_recipient" => default_test_recipient(caller_uri),
      "smtp_test_result" => nil,
      "smtp_flash" => nil
    }
  rescue
    err -> %{"error" => inspect(err)}
  end

  defp default_test_recipient(%URI{} = caller_uri) do
    case Ezagent.Entity.Profile.get(caller_uri) do
      %{email: email} when is_binary(email) -> email
      _ -> ""
    end
  end

  defp default_test_recipient(_), do: ""

  defp count_scheme(kinds, scheme) do
    Enum.count(kinds, fn {uri_str, _pid} ->
      match?(%URI{scheme: ^scheme}, parse_uri(uri_str))
    end)
  end

  defp count_entity_type(kinds, type) do
    Enum.count(kinds, fn {uri_str, _pid} ->
      case parse_uri(uri_str) do
        %URI{scheme: "entity"} = uri -> Ezagent.URI.type(uri) == {:ok, type}
        _ -> false
      end
    end)
  end

  defp registry_rows do
    Ezagent.KindRegistry.list_all()
    |> Enum.map(fn {uri_str, pid} ->
      %{
        "uri" => uri_str,
        "scheme" => uri_scheme(uri_str),
        "alive" => is_pid(pid) and Process.alive?(pid),
        "pid" => if(is_pid(pid), do: inspect(pid), else: nil)
      }
    end)
    |> Enum.sort_by(& &1["uri"])
  end

  defp template_rows do
    Ezagent.KindRegistry.list_all()
    |> Enum.flat_map(fn {uri_str, pid} ->
      case parse_uri(uri_str) do
        %URI{scheme: "template"} ->
          [%{"uri" => uri_str, "alive" => is_pid(pid) and Process.alive?(pid)}]

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1["uri"])
  end

  defp recent_invocations(limit, workspace_uri) do
    {where, params} = workspace_filter_sql(workspace_uri)

    sql =
      "SELECT target, action, authz, duration_us, workspace_uri, inserted_at " <>
        "FROM invocations #{where} ORDER BY id DESC LIMIT ?#{length(params) + 1}"

    case EzagentCore.Repo.query(sql, params ++ [limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [target, action, authz, duration_us, workspace, inserted_at] ->
          %{
            "target" => target,
            "action" => action,
            "authz" => authz,
            "duration_us" => duration_us,
            "workspace_uri" => workspace,
            "inserted_at" => inspect(inserted_at)
          }
        end)

      {:error, reason} ->
        [%{"error" => inspect(reason)}]
    end
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp snapshots(limit, workspace_uri) do
    {where, params} = workspace_filter_sql(workspace_uri)

    sql =
      "SELECT uri, kind_type, version, workspace_uri, updated_at FROM kind_snapshots " <>
        "#{where} ORDER BY updated_at DESC LIMIT ?#{length(params) + 1}"

    case EzagentCore.Repo.query(sql, params ++ [limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [uri, kind_type, version, workspace, updated_at] ->
          %{
            "uri" => uri,
            "kind_type" => kind_type,
            "version" => version,
            "workspace_uri" => workspace,
            "updated_at" => inspect(updated_at)
          }
        end)

      {:error, reason} ->
        [%{"error" => inspect(reason)}]
    end
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp grantable_caps do
    Ezagent.CapabilityRegistry.list_grantable()
    |> Enum.map(&jsonable/1)
    |> Enum.sort_by(&inspect/1)
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp default_grants(workspace_uri) do
    workspace_uri = workspace_uri || Ezagent.URI.workspace(:system)

    Ezagent.CapabilityRegistry.kinds_with_default_grants()
    |> Enum.map(fn kind ->
      %{
        "kind" => inspect(kind),
        "caps" =>
          kind
          |> Ezagent.CapabilityRegistry.default_grants_for(workspace_uri)
          |> Enum.map(&jsonable/1)
      }
    end)
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp routing_rules do
    Ezagent.Routing.RuleStore.list(EzagentDomainInstanceMessage.Routing.MentionRouting)
    |> Enum.map(&jsonable/1)
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp external_mirror_bindings(limit) do
    sql =
      "SELECT session_uri, adapter_id, target_id, workspace_uri, bound_at " <>
        "FROM external_mirror_bindings ORDER BY bound_at DESC LIMIT ?1"

    case EzagentCore.Repo.query(sql, [limit]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [session_uri, adapter_id, target_id, workspace_uri, bound_at] ->
          %{
            "session_uri" => session_uri,
            "adapter_id" => adapter_id,
            "target_id" => target_id,
            "workspace_uri" => workspace_uri,
            "bound_at" => inspect(bound_at)
          }
        end)

      {:error, reason} ->
        [%{"error" => inspect(reason)}]
    end
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp external_mirror_bindings_for(%URI{} = session_uri) do
    session = URI.to_string(session_uri)

    case EzagentCore.Repo.query(
           "SELECT adapter_id, target_id, workspace_uri, bound_at FROM external_mirror_bindings WHERE session_uri = ?1 ORDER BY bound_at DESC",
           [session]
         ) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [adapter_id, target_id, workspace_uri, bound_at] ->
          %{
            "adapter_id" => adapter_id,
            "target_id" => target_id,
            "workspace_uri" => workspace_uri,
            "bound_at" => inspect(bound_at)
          }
        end)

      {:error, reason} ->
        [%{"error" => inspect(reason)}]
    end
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp external_mirror_bindings_for(_), do: []

  defp bridges do
    if Code.ensure_loaded?(Ezagent.AgentBridge.Registry) do
      Ezagent.AgentBridge.Registry.list_all()
      |> Enum.map(&jsonable/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp cc_orchestrator_status do
    seed_module = Ezagent.Orchestrator.CcOrchestratorSeed

    if Code.ensure_loaded?(seed_module) and function_exported?(seed_module, :seed_status, 0) do
      seed_module |> apply(:seed_status, []) |> jsonable()
    else
      "unavailable"
    end
  rescue
    _ -> "unavailable"
  end

  defp workspace_filter_sql(%URI{} = workspace_uri) do
    {"WHERE workspace_uri = ?1", [URI.to_string(workspace_uri)]}
  end

  defp workspace_filter_sql(_), do: {"", []}

  defp uri_scheme(uri_str) do
    case parse_uri(uri_str) do
      %URI{scheme: scheme} -> scheme
      _ -> "invalid"
    end
  end

  defp parse_uri(uri_str) when is_binary(uri_str) do
    Ezagent.URI.new!(uri_str)
  rescue
    _ -> nil
  end

  defp jsonable(%URI{} = uri), do: URI.to_string(uri)
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp jsonable(nil), do: nil
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)

  defp jsonable(value) when is_tuple(value) do
    value |> Tuple.to_list() |> jsonable()
  end

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
