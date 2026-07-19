defmodule Ezagent.World.AdminData do
  @moduledoc """
  Data builders for the world plugin's admin component group.

  The admin group is deliberately read-heavy in v1: it mirrors the existing
  operator surfaces as JSON-safe summaries while preserving all existing
  mutation chokepoints for future form work.
  """

  import Ecto.Query

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

  defp component_state(%{component: "dashboard"}, base, _workspace_uri, caller_uri) do
    case kpis(caller_uri) do
      {:ok, kpi_map} ->
        base
        |> Map.put("kpis", kpi_map)
        |> Map.put("cc_orchestrator_status", cc_orchestrator_status())

      {:error, :unauthorized} ->
        unauthorized_state(base)
    end
  end

  # Overview 操作员落地页（FP5 S2-a）：复用 dashboard 的 KPI 概览,前端再叠快捷入口 +
  # 可继续 session 列表。不带 orchestrator 明细 —— 那是 Admin Dashboard 的职责,Overview
  # 只做轻量总览 + 导航。session_template_names 复用 WorkspacePluginData(单一 source,
  # 与 WorldLive 的 "New session" 选择器同源)。
  defp component_state(%{component: "overview"}, base, workspace_uri, caller_uri) do
    case overview_kpis(caller_uri, workspace_uri) do
      {:ok, kpi_map, session_rows} ->
        base
        |> Map.put("kpis", kpi_map)
        |> Map.put("available_sessions", Enum.take(session_rows, 3))
        |> Map.put(
          "session_template_names",
          Ezagent.World.WorkspacePluginData.session_template_names(caller_uri, workspace_uri)
        )

      {:error, :unauthorized} ->
        unauthorized_state(base)
    end
  end

  defp component_state(%{component: "observability"}, base, workspace_uri, _caller_uri) do
    base
    |> Map.put("audit_rows", recent_invocations(25, workspace_uri))
    |> Map.put("bridges", bridges())
    |> Map.put("snapshots", snapshots(12, workspace_uri))
  end

  defp component_state(%{component: "entity_registry"}, base, _workspace_uri, caller_uri) do
    case registry_rows(caller_uri) do
      {:ok, rows} -> Map.put(base, "entities", rows)
      {:error, :unauthorized} -> unauthorized_state(base)
    end
  end

  defp component_state(%{component: "snapshots"}, base, workspace_uri, _caller_uri) do
    Map.put(base, "snapshots", snapshots(50, workspace_uri))
  end

  defp component_state(%{component: "templates"}, base, _workspace_uri, caller_uri) do
    case template_rows(caller_uri) do
      {:ok, rows} -> Map.put(base, "templates", rows)
      {:error, :unauthorized} -> unauthorized_state(base)
    end
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

    settings = %{
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

    if Ezagent.Identity.admin?(caller_uri) do
      Map.merge(settings, %{
        "can_manage_registration" => true,
        "registration_open" => Ezagent.AppSettings.registration_open?(),
        "registration_require_invite" => Ezagent.AppSettings.registration_require_invite?(),
        "registration_requests" => registration_requests(),
        "registration_flash" => nil
      })
    else
      Map.put(settings, "can_manage_registration", false)
    end
  rescue
    err -> %{"error" => inspect(err)}
  end

  defp registration_requests do
    Enum.map(Ezagent.Entity.RegistrationRequest.list_pending(), fn request ->
      %{"email" => request.email, "requested_at" => request.updated_at}
    end)
  end

  defp default_test_recipient(%URI{} = caller_uri) do
    case Ezagent.Entity.Profile.get(caller_uri) do
      %{email: email} when is_binary(email) -> email
      _ -> ""
    end
  end

  defp default_test_recipient(_), do: ""

  defp overview_kpis(caller_uri, workspace_uri) do
    session_rows = overview_session_rows(workspace_uri, caller_uri)

    case kpis(caller_uri) do
      {:ok, kpi_map} -> {:ok, Map.put(kpi_map, "sessions", length(session_rows)), session_rows}
      {:error, :unauthorized} = err -> err
    end
  end

  # KPI 概览,dashboard 与 overview 共用（FP5 S2-a）。F5 (read-plane PR-4
  # rework): the GLOBAL registry list-all behind these counts is an
  # OPERATOR query-scope — routed through the
  # `Ezagent.Identity.OperatorReads` chokepoint (promoted operators
  # included); a non-operator gets `{:error, :unauthorized}`, surfaced
  # as an explicit unauthorized state, NEVER an empty/zero table.
  defp kpis(caller_uri) do
    case Ezagent.Identity.OperatorReads.registry_all(caller_uri) do
      {:ok, kinds} ->
        {:ok,
         %{
           "kinds" => length(kinds),
           "sessions" => count_scheme(kinds, "session"),
           "workspaces" => count_scheme(kinds, "workspace"),
           "entities" => count_scheme(kinds, "entity"),
           "agents" => count_entity_type(kinds, "agent")
         }}

      {:error, :unauthorized} = err ->
        err
    end
  end

  # Overview 落地页"可继续 session"列表:复用会话页的 filtered row builder,
  # 保证 KPI 总数和下方可继续列表使用同一套 workspace/caller 可见性口径。
  defp overview_session_rows(%URI{scheme: "workspace"} = workspace_uri, %URI{} = caller_uri) do
    Ezagent.World.ConversationSessionState.rows_for_workspace(workspace_uri, caller_uri)
  rescue
    _ -> []
  end

  defp overview_session_rows(_, _), do: []

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

  # GLOBAL registry list-all (every Kind instance across the whole system)
  # is an OPERATOR query-scope — routed through the
  # Ezagent.Identity.OperatorReads chokepoint: authorize FIRST, and
  # PROPAGATE `{:error, :unauthorized}` to the route (F5, read-plane PR-4
  # rework) — never coerce a denial to an empty table.
  defp registry_rows(caller_uri) do
    case Ezagent.Identity.OperatorReads.registry_all(caller_uri) do
      {:ok, kinds} ->
        {:ok,
         kinds
         |> Enum.map(fn {uri_str, pid} ->
           %{
             "uri" => uri_str,
             "scheme" => uri_scheme(uri_str),
             "alive" => is_pid(pid) and Process.alive?(pid),
             "pid" => if(is_pid(pid), do: inspect(pid), else: nil)
           }
         end)
         |> Enum.sort_by(& &1["uri"])}

      {:error, :unauthorized} = err ->
        err
    end
  end

  defp template_rows(caller_uri) do
    case Ezagent.Identity.OperatorReads.registry_all(caller_uri) do
      {:ok, kinds} ->
        {:ok,
         kinds
         |> Enum.flat_map(fn {uri_str, pid} ->
           case parse_uri(uri_str) do
             %URI{scheme: "template"} ->
               [%{"uri" => uri_str, "alive" => is_pid(pid) and Process.alive?(pid)}]

             _ ->
               []
           end
         end)
         |> Enum.sort_by(& &1["uri"])}

      {:error, :unauthorized} = err ->
        err
    end
  end

  # F5 (read-plane PR-4 rework): the explicit unauthorized state — the
  # route surfaces a rejection marker and NO data keys, so a denied
  # caller can never mistake a coerced empty table for "no rows".
  defp unauthorized_state(base) do
    base
    |> Map.put("unauthorized", true)
    |> Map.put("error", "unauthorized")
  end

  defp recent_invocations(limit, workspace_uri) do
    "invocations"
    |> where_workspace(workspace_uri)
    |> order_by([i], desc: field(i, :id))
    |> limit(^limit)
    |> select([i], %{
      "target" => field(i, :target),
      "action" => field(i, :action),
      "authz" => field(i, :authz),
      "duration_us" => field(i, :duration_us),
      "workspace_uri" => field(i, :workspace_uri),
      "inserted_at" => field(i, :inserted_at)
    })
    |> EzagentCore.Repo.all()
    |> Enum.map(&inspect_timestamp(&1, "inserted_at"))
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  defp snapshots(limit, workspace_uri) do
    "kind_snapshots"
    |> where_workspace(workspace_uri)
    |> order_by([s], desc: field(s, :updated_at))
    |> limit(^limit)
    |> select([s], %{
      "uri" => field(s, :uri),
      "kind_type" => field(s, :kind_type),
      "version" => field(s, :version),
      "workspace_uri" => field(s, :workspace_uri),
      "updated_at" => field(s, :updated_at)
    })
    |> EzagentCore.Repo.all()
    |> Enum.map(&inspect_timestamp(&1, "updated_at"))
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
    from(b in "external_mirror_bindings",
      order_by: [desc: field(b, :bound_at)],
      limit: ^limit,
      select: %{
        "session_uri" => field(b, :session_uri),
        "adapter_id" => field(b, :adapter_id),
        "target_id" => field(b, :target_id),
        "workspace_uri" => field(b, :workspace_uri),
        "bound_at" => field(b, :bound_at)
      }
    )
    |> EzagentCore.Repo.all()
    |> Enum.map(&inspect_timestamp(&1, "bound_at"))
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  @doc "List external-mirror bindings for one session (used to refresh the surface after bind/unbind)."
  @spec external_mirror_bindings_for(URI.t() | term()) :: [map()]
  def external_mirror_bindings_for(%URI{} = session_uri) do
    session = URI.to_string(session_uri)

    from(b in "external_mirror_bindings",
      where: field(b, :session_uri) == ^session,
      order_by: [desc: field(b, :bound_at)],
      select: %{
        "adapter_id" => field(b, :adapter_id),
        "target_id" => field(b, :target_id),
        "workspace_uri" => field(b, :workspace_uri),
        "bound_at" => field(b, :bound_at)
      }
    )
    |> EzagentCore.Repo.all()
    |> Enum.map(&inspect_timestamp(&1, "bound_at"))
  rescue
    err -> [%{"error" => inspect(err)}]
  end

  def external_mirror_bindings_for(_), do: []

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
      seed_module |> apply(:seed_status, []) |> shape_orchestrator_status()
    else
      "unavailable"
    end
  rescue
    _ -> "unavailable"
  end

  defp where_workspace(source, %URI{} = workspace_uri) do
    workspace = URI.to_string(workspace_uri)
    from(row in source, where: field(row, :workspace_uri) == ^workspace)
  end

  defp where_workspace(source, _), do: from(row in source)

  # `seed_status/0` returns a `{state, detail}` tuple (state = :ok/:partial/
  # :missing, detail carries the seeded template). Flatten it into a
  # display-ready map: a `state` field (the UI renders it as a status badge)
  # plus a few meaningful, scalar template fields — never the raw nested
  # `{:ok, %{template_content: %{...}}}` dump (world §3.3). nil/empty fields
  # are dropped so the card only shows what's actually set.
  defp shape_orchestrator_status({state, detail})
       when is_atom(state) and is_map(detail) do
    content = Map.get(detail, :template_content, %{})

    %{
      "state" => Atom.to_string(state),
      "template" => detail |> Map.get(:template_uri) |> jsonable(),
      "name" => content[:name],
      "role" => content[:role],
      "flavor" => content[:flavor],
      "project_cwd" => content[:project_cwd],
      "config_dir" => content[:config_dir],
      "created_at" => content[:created_at] && to_string(content[:created_at])
    }
    |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
    |> Map.new()
  end

  defp shape_orchestrator_status(other), do: jsonable(other)

  defp inspect_timestamp(row, field_name) do
    Map.update(row, field_name, nil, &format_timestamp/1)
  end

  # 时间戳转人类可读串（截到秒），避免把 Elixir `~N[...]` sigil 直接展示给操作员。
  defp format_timestamp(%NaiveDateTime{} = dt),
    do: dt |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()

  defp format_timestamp(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_string()

  defp format_timestamp(nil), do: nil
  defp format_timestamp(value) when is_binary(value), do: value
  defp format_timestamp(other), do: inspect(other)

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
