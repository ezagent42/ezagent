defmodule Ezagent.World.IdentityData do
  @moduledoc """
  Data builders for the world plugin's identities component group.

  The module mirrors the existing LiveView surfaces at a data boundary only:
  it reads the same domain registries/facades and returns JSON-safe maps for
  the React shell. Mutations stay in `WorldLive` so they can dispatch with the
  socket caller and LiveAuth-provided caps.
  """

  alias Ezagent.Invocation
  alias Ezagent.Sandbox.ConfigDir
  alias Ezagent.World.{CapData, UserData}

  @fallback_flavors ~w(cc cc-headless codex codex-remote py curl native)

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

    route
    |> component_state(base, workspace_uri, caller_uri, caller_caps)
    |> put_create_error(component, Map.get(opts, :create_error))
  end

  # Surface create failures on the matching form. Always written for the
  # form component (nil clears any stale message via the React state merge);
  # never written for other components.
  defp put_create_error(state, "agent_new_form", nil), do: Map.put(state, "create_error", nil)

  defp put_create_error(state, "agent_new_form", reason),
    do: Map.put(state, "create_error", create_error_message(reason))

  defp put_create_error(state, "user_new_form", nil), do: Map.put(state, "create_error", nil)

  defp put_create_error(state, "user_new_form", reason),
    do: Map.put(state, "create_error", UserData.error_message(reason))

  defp put_create_error(state, _component, _reason), do: state

  defp component_state(
         %{component: "identities", filter: filter},
         base,
         workspace_uri,
         caller,
         caps
       ) do
    rows = workspace_uri |> list_entities(filter) |> put_credential_statuses(caller, caps)

    base
    |> Map.put("filter", filter)
    |> Map.put("entities", rows)
    |> Map.put("agent_flavors", agent_flavors(rows))
  end

  defp component_state(%{component: "users_table"}, base, workspace_uri, _caller, _caps) do
    Map.put(base, "users", UserData.list_users(workspace_uri))
  end

  defp component_state(%{component: "user_new_form"}, base, workspace_uri, _caller, _caps) do
    Map.put(base, "preview_uri", UserData.preview_uri(workspace_uri, ""))
  end

  defp component_state(%{component: "agents_table"}, base, workspace_uri, caller, caps) do
    agents = workspace_uri |> list_entities("agents") |> put_credential_statuses(caller, caps)

    base
    |> Map.put("agents", agents)
    # F1: the flavor filter chips need the distinct flavors present, same source
    # the identities directory uses (`agent_flavors/1`).
    |> Map.put("agent_flavors", agent_flavors(agents))
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
    |> Map.put("caps", CapData.list_entity_caps(entity_uri, caller, caps))
  end

  defp component_state(
         %{component: "agent_detail", entity_uri: agent_uri},
         base,
         _workspace,
         caller,
         caps
       )
       when not is_nil(agent_uri) do
    # F2: guard non-existent agents (e.g. after a delete) — without this the
    # detail page rendered a hollow shell of "—"/"unknown" rows for a URI with
    # no live process AND no snapshot. Mirror `agent_config`'s `:agent_not_found`
    # contract: signal `agent_not_found` so the React detail surfaces a clean
    # not-found empty state instead of a misleading shell.
    if agent_exists?(agent_uri) do
      agent_detail_state(base, agent_uri, caller, caps)
    else
      base
      |> Map.put("agent_uri", encode_uri(agent_uri))
      |> Map.put("agent_not_found", true)
    end
  end

  # F2: a malformed agent URL parses `entity_uri` to nil (routes.ex
  # `parse_entity_uri/1` returns nil for any non-entity/unparseable segment).
  # Render the same clean not-found state rather than falling through to the
  # catch-all (which would emit a hollow shell with no agent_uri).
  defp component_state(%{component: "agent_detail", entity_uri: nil}, base, _ws, _caller, _caps) do
    base
    |> Map.put("agent_uri", nil)
    |> Map.put("agent_not_found", true)
  end

  defp component_state(%{component: "agent_new_form"}, base, workspace_uri, _caller, _caps) do
    flavors = list_flavors()
    default_flavor = if "cc" in flavors, do: "cc", else: List.first(flavors) || "cc"

    # M4: per-flavor config schemas for dynamic create form fields
    schemas = Map.new(flavors, &{&1, config_schema_for(&1)})

    base
    |> Map.put("flavors", flavors)
    |> Map.put("default_flavor", default_flavor)
    |> Map.put("config_schemas", schemas)
    |> Map.put("preview_uri", preview_agent_uri(workspace_uri, ""))
    |> Map.put("allowed_project_cwd_roots", ConfigDir.operator_allowed_project_cwd_roots())
    # UI hint only; server-side create defaults empty file-flavor cwd to config_dir.
    |> Map.put("cwd_required_flavors", [])
    |> Map.put("cwd_required_with_pty_flavors", [])
    # F6: py's Template Class `validate/1` requires a `script` config field; mark
    # it required in the create form (the `*` + Create-button gate) so the
    # operator can't submit without it and hit the raw `:missing_script` error.
    |> Map.put("script_required_flavors", ["py"])
  end

  defp component_state(
         %{component: "user_detail", entity_uri: user_uri},
         base,
         _workspace,
         caller,
         caps
       )
       when not is_nil(user_uri) do
    if UserData.exists?(user_uri) do
      UserData.detail_state(base, user_uri, caller, caps)
    else
      base
      |> Map.put("user_uri", encode_uri(user_uri))
      |> Map.put("user_not_found", true)
    end
  end

  defp component_state(%{component: "user_detail", entity_uri: nil}, base, _ws, _caller, _caps) do
    base
    |> Map.put("user_uri", nil)
    |> Map.put("user_not_found", true)
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
    |> Map.put("can_edit", can_edit_api_keys?(agent_uri, caller, caps))
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

  # A terminal's OUTPUT is as sensitive as its input: `claude /login` codes,
  # secrets echoed by commands, the agent's whole conversation. `entity_uri`
  # here comes straight out of the URL (`Routes.route_for/2` regex), so
  # WITHOUT this check any authenticated entity could watch any agent's
  # terminal in any workspace. Reading is gated on the same instance-scoped
  # Pty authority as writing — the agent's creator holds it (Allen,
  # 2026-07-14: "the terminal belongs to the creator"), admin's genesis
  # wildcard matches, nobody else does.
  #
  # The subscription in `WorldLive.maybe_subscribe_pty/2` is a SECOND,
  # independent exit for the same bytes and carries the same check.
  defp component_state(
         %{component: "pty_terminal", entity_uri: agent_uri},
         base,
         _workspace,
         _caller,
         caps
       ) do
    agent_uri_str = encode_uri(agent_uri)
    authorized? = Ezagent.Domain.Pty.Access.may_read?(agent_uri, caps)

    base
    |> Map.put("agent_uri", agent_uri_str)
    |> Map.put("agent_detail_path", detail_path("agent", agent_uri_str))
    |> Map.put("pty_authorized", authorized?)
    |> then(fn state ->
      if authorized? do
        state
        |> Map.put("agent_status", agent_status(agent_uri))
        |> Map.put("pty_alive", pty_alive?(agent_uri))
        |> Map.put("pty_phase", pty_phase(agent_uri))
        |> Map.put("pty_initial_buffer", pty_initial_buffer(agent_uri))
      else
        # No buffer, no liveness, no phase — an unauthorized viewer learns
        # nothing about the agent beyond the URI they already typed.
        state
        |> Map.put("agent_status", "unknown")
        |> Map.put("pty_alive", false)
        |> Map.put("pty_phase", "unknown")
        |> Map.put("pty_initial_buffer", "")
      end
    end)
  end

  defp component_state(
         %{component: "agent_config", entity_uri: agent_uri},
         base,
         _workspace_uri,
         caller,
         caps
       ) do
    case Ezagent.Domain.Agent.read_config(agent_uri, %{caller: caller, caps: caps}) do
      {:ok, cascade} ->
        flavor = flavor_for("agent", agent_uri)

        base
        |> Map.put("agent_uri", encode_uri(agent_uri))
        |> Map.put("cascade", jsonable(cascade))
        |> Map.put("config_schema", config_schema_for(flavor))

      {:error, :unauthorized} ->
        Map.put(base, "config_error", "没有查看权限（需要 manage 权限）")

      {:error, :invalid_agent_uri} ->
        Map.put(base, "config_error", "无效的 agent URI")

      {:error, :agent_not_found} ->
        Map.put(base, "config_error", "Agent 不存在")

      {:error, reason} ->
        Map.put(base, "config_error", "配置读取失败：#{inspect(reason)}")
    end
  rescue
    err -> Map.put(base, "config_error", "配置读取异常：#{inspect(err)}")
  end

  defp component_state(_route, base, _workspace, _caller, _caps), do: base

  # F2: the full agent-detail payload, built only once existence is confirmed.
  defp agent_detail_state(base, agent_uri, caller, caps) do
    # One sandbox read serves both config_dir + project_cwd so the detail page
    # reads the executor config the agent was actually spawned with (not a
    # re-derivation that could drift). `respawn_template_data` carries the
    # template content the cascade built the agent from — `project_cwd` /
    # source-template live there when the agent came from a registered template;
    # a direct-spawn (curl/np) agent has neither, so both render nil ("—").
    sandbox = agent_sandbox_state(agent_uri, caller, caps)

    agent_uri_str = encode_uri(agent_uri)
    flavor = flavor_for("agent", agent_uri)

    base
    |> Map.put("agent_uri", agent_uri_str)
    |> Map.put("agent_status", agent_status(agent_uri))
    |> Map.put("flavor", flavor)
    |> Map.put("bridge", bridge_entry(agent_uri))
    |> Map.put("granted_caps", CapData.list_entity_caps(agent_uri, caller, caps))
    |> Map.put("project_cwd", sandbox_project_cwd(sandbox))
    |> Map.put("config_dir", sandbox_config_dir(sandbox))
    # #160 — normalized credential status (owner + ws-admin only; nil for a
    # caller without the target's Manage cap, so the badge simply hides).
    |> Map.put("credential_status", agent_credential_status(agent_uri, caller, caps))
    |> Map.put("source_template", sandbox_source_template(sandbox))
    |> Map.put("config_path", config_path("agent", agent_uri_str))
    # M1: per-flavor config fields from template data + config cascade
    |> Map.put("config_fields", config_fields_for(agent_uri, flavor, sandbox, caller, caps))
    |> Map.put("not_wired", not_wired_annotations())
    # M2-mock: config schema (A4 落地后改为 tc.config_schema())
    |> Map.put("config_schema", config_schema_for(flavor))
    # F4: explicitly clear any stale action_error — the React island merges
    # world:state and never remounts, so a delete-failure banner pushed onto
    # this detail route would otherwise linger after the operator resolves the
    # cause and returns. nil clears it via the React state merge.
    |> Map.put("action_error", nil)
  end

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
              "extensions_path" => extensions_path(entity_type, uri_str),
              "config_path" => config_path(entity_type, uri_str)
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

  @doc "Registered agent flavors for the new-agent component."
  @spec list_flavors() :: [String.t()]
  def list_flavors do
    Ezagent.AgentFlavorRegistry.list_all()
    |> Enum.map(fn {flavor, _decl} -> flavor end)
    |> ordered_flavors()
  rescue
    _ -> @fallback_flavors
  end

  defp ordered_flavors(flavors) do
    extras =
      flavors
      |> Enum.reject(&(&1 in @fallback_flavors))
      |> Enum.sort()

    (@fallback_flavors ++ extras)
    |> Enum.uniq()
  end

  @doc "Map a create_agent/grant failure reason to an operator-facing message."
  @spec create_error_message(term()) :: String.t()
  def create_error_message({:cwd_not_a_dir, cwd}), do: "project_cwd 不是有效目录：#{cwd}"

  def create_error_message({:cwd_outside_allowed_roots, cwd}),
    do: "project_cwd 不在允许的目录范围内：#{cwd}"

  def create_error_message(:flavor_required), do: "请选择 flavor"
  def create_error_message(:name_required), do: "请填写 name"
  # F6: py's Template Class `validate/1` rejects a create with no operator
  # script. Surface a friendly hint instead of the raw `创建失败：:missing_script`.
  def create_error_message(:missing_script),
    do: "py 需要 script（在 py configuration 里填入 agent.py 脚本）"

  def create_error_message({:bad_name, name}),
    do: "name 不合法（字母数字开头，仅 字母/数字/-/_）：#{name}"

  def create_error_message({:bad_flavor, flavor}), do: "不支持的 flavor：#{flavor}"
  def create_error_message({:already_exists, uri}), do: "同名 agent 已存在：#{uri}"
  def create_error_message({:bad_workspace_uri, _}), do: "无效的 workspace"
  # The agent was created but a requested cap could not be granted. The common
  # case: the flavor's Kind doesn't mount the Identity behavior that exposes
  # `grant_cap` (e.g. echo) — surface a clean hint instead of a raw tuple.
  def create_error_message({:grant_failed, _cap, {:unknown_action, :grant_cap}}),
    do: "该 flavor 不支持授予 caps（其 Kind 未实现 Identity 授予）——请将 caps 留空，或改用 cc / curl"

  def create_error_message({:grant_failed, _cap, reason}),
    do: "授予 caps 失败：#{inspect(reason)}"

  def create_error_message(
        {:cascade_spawn_failed,
         {:codex_app_server_not_ready,
          {:codex_app_server_exited_before_ready, _socket_path, output}}}
      ),
      do: codex_app_server_error_message(output)

  def create_error_message(
        {:cascade_spawn_failed,
         {:codex_app_server_not_ready, {:codex_app_server_socket_timeout, _socket_path, output}}}
      ),
      do: codex_app_server_error_message(output)

  def create_error_message(other), do: "创建失败：#{inspect(other)}"

  defp codex_app_server_error_message(output) when is_binary(output) and output != "" do
    "Codex app-server 启动失败：#{String.trim(output)}"
  end

  defp codex_app_server_error_message(_output),
    do: "Codex app-server 启动失败：未能在限定时间内创建连接 socket"

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

  # F2: an agent exists if it has a live process OR a persisted snapshot. A URI
  # with neither (never created, or deleted) is genuinely gone — the detail page
  # then renders a not-found state instead of a hollow shell. A registered-but-
  # cold agent still has a snapshot, so it correctly reads as existing.
  #
  # Liveness goes through the owner-gated `Ezagent.LocalRuntime.kind_alive?/1`
  # (NOT a direct `KindRegistry.lookup` — the plugin-workspace-locality contract
  # forbids plugins consulting the local registry directly).
  defp agent_exists?(%URI{} = agent_uri) do
    Ezagent.LocalRuntime.kind_alive?(agent_uri) or
      Ezagent.Kind.StateRebuilder.snapshot_exists?(agent_uri)
  rescue
    _ -> true
  end

  defp agent_exists?(_), do: false

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
           ctx: %{caller: caller_uri, caps: caller_caps, reply: :sync},
           origin: :authenticated_external
         }) do
      {:ok, %{api_keys: list}} when is_list(list) -> Enum.map(list, &jsonable/1)
      # Graceful-degrade off the REAL dispatch result (no parallel flavor→behavior
      # table that could drift from what the Kind actually registers): a flavor
      # whose Kind doesn't implement Behavior.ApiKeys (echo/np) replies
      # `{:unknown_action, :list_api_keys}`. Surface that as a clean "unsupported"
      # marker so the page shows a friendly notice instead of a raw error tuple.
      {:error, {:unknown_action, _}} -> %{"unsupported" => true}
      {:error, reason} -> %{"error" => inspect(reason)}
      other -> %{"error" => inspect(other)}
    end
  rescue
    err -> %{"error" => inspect(err)}
  end

  defp lookup_creator_uri(%URI{} = agent_uri) do
    case Ezagent.ActionSet.ApiKeys.data_owner(agent_uri) do
      %URI{} = creator -> creator
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Edit affordance — DERIVED from the real authorization model so the UI hint
  # can't diverge from the dispatch gate. `Behavior.ApiKeys` authorizes
  # `:put_api_key`/`:delete_api_key` by data_owner (the agent's creator) or
  # admin, NOT by an explicitly-held cap; mirror that with the canonical
  # `Ezagent.Identity.admin?/1` (same shape as the LiveView reference
  # `agent_api_keys_live.ex`). Never hand-roll an inline caller/admin-principal
  # equality here — that reconstructs the predicate, drifts from the gate, and
  # the p13 probe rejects it (#154).
  defp can_edit_api_keys?(%URI{} = agent_uri, %URI{} = caller_uri, caps) do
    creator_uri = lookup_creator_uri(agent_uri)
    workspace_uri = Ezagent.URI.entity_workspace_uri(agent_uri)

    needed = %{
      kind: :any,
      behavior: Ezagent.ActionSet.ApiKeys,
      action: :put_api_key,
      instance: agent_uri,
      workspace_uri: workspace_uri
    }

    Ezagent.Identity.admin?(caller_uri) or
      (not is_nil(creator_uri) and same_uri?(caller_uri, creator_uri)) or
      Ezagent.Identity.caps_authorize?(caps, needed)
  end

  defp can_edit_api_keys?(_agent_uri, _caller, _caps), do: false

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

  # Read the agent's sandbox state for the DETAIL / extension panels WITHOUT
  # activating the agent, via the unified non-activating reader
  # `Ezagent.Domain.Agent.read_sandbox/2` (SPEC unified-non-activating-agent-read.md).
  # The reader owns the de-activation (durable `:sandbox` slice → snapshot
  # fallback) AND the `:sandbox/:read` cap gate (pure cap check, instance-scoped,
  # NO self/data-owner disjunct) the dispatch enforced — fixing FP5 S5 #115
  # (codex MEDIUM-2) once, in one place. This facade keeps only the surface call.
  defp sandbox_read(%URI{} = agent_uri, caller_uri, caller_caps) do
    Ezagent.Domain.Agent.read_sandbox(agent_uri, %{caller: caller_uri, caps: caller_caps})
  end

  defp sandbox_read(_agent_uri, _caller_uri, _caller_caps), do: {:error, :invalid_entity}

  # Read the agent's sandbox state through the non-activating
  # `Domain.Agent.read_sandbox/2`. Returns the raw result map
  # (`config_dir_path` / `respawn_template_data` / …) or `nil` when the agent
  # has no live sandbox Kind (direct-spawn / not running). Never raises — the
  # detail page degrades to "—" on any failure.
  defp agent_sandbox_state(%URI{} = agent_uri, caller_uri, caller_caps) do
    case sandbox_read(agent_uri, caller_uri, caller_caps) do
      {:ok, %{} = result} -> result
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp agent_sandbox_state(_agent_uri, _caller_uri, _caller_caps), do: nil

  # ── #160 credential-status view ──────────────────────────────────────
  #
  # Enrich agent rows with a normalized `credential_status` (nil for user rows and
  # for agents the caller may not manage). Read via the cap-gated, NON-ACTIVATING
  # `Ezagent.Domain.Agent.read_credential_status/2` — the SAME owner+ws-admin gate
  # as `read_config`, so a co-tenant learns nothing (#160 leak stays closed).
  defp put_credential_statuses(rows, caller, caps) when is_list(rows) do
    Enum.map(rows, fn
      %{"kind" => "agent", "uri" => uri_str} = row ->
        Map.put(row, "credential_status", agent_credential_status(uri_str, caller, caps))

      row ->
        row
    end)
  end

  defp put_credential_statuses(rows, _caller, _caps), do: rows

  defp agent_credential_status(%URI{} = agent_uri, caller, caps) do
    case Ezagent.Domain.Agent.read_credential_status(agent_uri, %{caller: caller, caps: caps}) do
      {:ok, status} -> encode_credential_status(status)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp agent_credential_status(uri_str, caller, caps) when is_binary(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, %URI{} = uri} -> agent_credential_status(uri, caller, caps)
      _ -> nil
    end
  end

  defp agent_credential_status(_agent_uri, _caller, _caps), do: nil

  # JSON-safe shape. `checked_at` (a DateTime) becomes an ISO8601 string (NOT the
  # field-map `jsonable/1` would emit for a struct); `expires_at` is epoch ms or nil.
  defp encode_credential_status(%{status: status} = s) do
    %{
      "status" => Atom.to_string(status),
      "flavor" => Map.get(s, :flavor),
      "detail" => Map.get(s, :detail),
      "expires_at" => Map.get(s, :expires_at),
      "checked_at" => encode_datetime(Map.get(s, :checked_at))
    }
  end

  defp encode_credential_status(_), do: nil

  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(_), do: nil

  defp sandbox_config_dir(%{} = sandbox) do
    case Map.get(sandbox, :config_dir_path) || Map.get(sandbox, "config_dir_path") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp sandbox_config_dir(_sandbox), do: nil

  # `project_cwd` is the universal "where the agent works" field carried in the
  # template content the cascade snapshotted into `respawn_template_data`. nil
  # for a direct-spawn agent (no template) — the UI renders that as "—".
  defp sandbox_project_cwd(%{} = sandbox) do
    respawn =
      Map.get(sandbox, :respawn_template_data) || Map.get(sandbox, "respawn_template_data")

    case respawn do
      %{} = data ->
        case Map.get(data, :project_cwd) || Map.get(data, "project_cwd") do
          cwd when is_binary(cwd) and cwd != "" -> cwd
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp sandbox_project_cwd(_sandbox), do: nil

  # Source template / version label. The cascade records the template flavor
  # (and, when present, source/credential URIs) in `respawn_template_data`; we
  # surface the flavor as the human-readable "version / template" hint. nil ⇒
  # the UI shows "direct-spawn (no template)".
  defp sandbox_source_template(%{} = sandbox) do
    respawn =
      Map.get(sandbox, :respawn_template_data) || Map.get(sandbox, "respawn_template_data")

    case respawn do
      %{} = data ->
        case Map.get(data, :flavor) || Map.get(data, "flavor") do
          flavor when is_binary(flavor) and flavor != "" -> flavor
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp sandbox_source_template(_sandbox), do: nil

  # ── M2: per-flavor config schema (A4 real config_schema/0) ────────────

  defp config_schema_for(flavor) when is_binary(flavor) and flavor != "" do
    case Ezagent.AgentFlavorRegistry.lookup(flavor) do
      {:ok, %{template_class: tc}} ->
        if function_exported?(tc, :config_schema, 0) do
          tc.config_schema() |> Enum.map(&schema_field_to_map/1)
        else
          []
        end

      :error ->
        []
    end
  rescue
    _ -> []
  end

  defp config_schema_for(_), do: []

  defp schema_field_to_map(field) when is_map(field) do
    %{}
    |> put_schema_string("key", Map.get(field, :key))
    |> put_schema_string("type", Map.get(field, :type) |> to_string())
    |> put_schema_string("label", Map.get(field, :label))
    |> put_schema_string("help", Map.get(field, :help))
    |> put_schema_string("placeholder", Map.get(field, :placeholder))
    |> put_schema_list("options", Map.get(field, :options))
    |> put_schema_any("default", Map.get(field, :default))
    |> put_schema_any("required", Map.get(field, :required))
  end

  defp put_schema_string(acc, _k, nil), do: acc
  defp put_schema_string(acc, k, v) when is_binary(v), do: Map.put(acc, k, v)
  defp put_schema_string(acc, k, v), do: Map.put(acc, k, to_string(v))

  defp put_schema_list(acc, _k, nil), do: acc
  defp put_schema_list(acc, k, v) when is_list(v), do: Map.put(acc, k, v)
  defp put_schema_list(acc, _k, _), do: acc

  defp put_schema_any(acc, _k, nil), do: acc
  defp put_schema_any(acc, k, v), do: Map.put(acc, k, v)

  # ── M1: per-flavor config fields + not-wired annotations ─────────────────

  # M1: temporary per-flavor field lists. M2+ replaced by config_schema/0.
  # Derived from each Template Class's template_data_extra/1.
  # cc/cc-headless: appends operator_settings_path/operator_mcp_config_path/api_key_helper/role/credential_source
  # codex/codex-remote: appends bridge_ws_url/codex_path
  defp template_field_keys_for("cc"),
    do:
      ~w(model effort permission_mode allowed_tools disallowed_tools mcp_servers system_prompt operator_settings_path operator_mcp_config_path api_key_helper role credential_source)

  defp template_field_keys_for("cc-headless"),
    do:
      ~w(model effort permission_mode allowed_tools disallowed_tools mcp_servers system_prompt operator_settings_path operator_mcp_config_path api_key_helper role credential_source)

  defp template_field_keys_for("codex"),
    do: ~w(model approval_policy sandbox bridge_ws_url codex_path)

  defp template_field_keys_for("codex-remote"),
    do: ~w(model approval_policy sandbox bridge_ws_url codex_path)

  defp template_field_keys_for("curl"), do: ~w(model provider api_url system_prompt max_history)
  # py-agent (P2): the operator script + per-call timeout are py's template data
  # fields (`Ezagent.Template.PyAgent.config_schema/0`).
  defp template_field_keys_for("py"), do: ~w(script timeout_ms)
  defp template_field_keys_for(_), do: []

  defp config_fields_for(agent_uri, flavor, sandbox_state, caller, caps) do
    respawn =
      (sandbox_state &&
         (Map.get(sandbox_state, :respawn_template_data) ||
            Map.get(sandbox_state, "respawn_template_data"))) ||
        %{}

    # Template data fields (storage B) — always emit known keys per flavor
    # Values may be nil for direct-spawn agents (no respawn_template_data)
    # M2+ replaced by config_schema/0 discovery
    template_fields =
      flavor
      |> template_field_keys_for()
      |> Enum.map(fn key ->
        value = Map.get(respawn, key) || Map.get(respawn, to_string(key))
        %{"key" => key, "value" => jsonable(value), "source" => "template"}
      end)

    # Config cascade soul_md (storage A) — best-effort read
    soul_fields = read_soul_field(agent_uri, caller, caps)

    template_fields ++ soul_fields
  end

  defp read_soul_field(_agent_uri, nil, _caps), do: []
  defp read_soul_field(_agent_uri, _caller, caps) when caps == %{}, do: []

  defp read_soul_field(agent_uri, caller, caps) do
    if Code.ensure_loaded?(Ezagent.Agent.Config) do
      # Canonical default key (NOT a re-hardcoded literal) — no drift from @default_key.
      key = Ezagent.Agent.Config.default_key()

      case Ezagent.Agent.Config.read_key(agent_uri, key, caller, caps) do
        {:ok, %{effective_body: %{"soul_md" => soul_md}}}
        when is_binary(soul_md) and soul_md != "" ->
          [%{"key" => "soul_md", "value" => soul_md, "source" => "cascade"}]

        _ ->
          []
      end
    else
      []
    end
  rescue
    _ -> []
  end

  defp not_wired_annotations do
    [
      %{"key" => "skills", "reason" => "还没接线（需 Role 模型编辑 + skill store）"},
      %{"key" => "tools", "reason" => "还没接线（需 tool registry）"},
      %{"key" => "kb", "reason" => "还没接线（需 ezagent_plugin_kb）"},
      %{"key" => "lifecycle_detail", "reason" => "还没接线（Domain.Agent 仅返回 phase+flavor）"},
      %{"key" => "settings_mgmt", "reason" => "还没接线（需 settings store）"},
      %{"key" => "fork", "reason" => "Deferred（Behavior.Template.:fork action 已存在，缺 UI）"}
    ]
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
  defp detail_path("user", uri_str), do: "/identities/users/#{URI.encode_www_form(uri_str)}"
  defp detail_path(_kind, _uri_str), do: nil

  defp api_keys_path("agent", uri_str),
    do: "/identities/agents/#{URI.encode_www_form(uri_str)}/api-keys"

  defp api_keys_path(_kind, _uri_str), do: nil

  defp extensions_path("agent", uri_str),
    do: "/identities/agents/#{URI.encode_www_form(uri_str)}/extensions"

  defp extensions_path(_kind, _uri_str), do: nil

  defp config_path("agent", uri_str),
    do: "/identities/agents/#{URI.encode_www_form(uri_str)}/config"

  defp config_path(_kind, _uri_str), do: nil

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

  defp jsonable(%_{} = value) do
    value
    |> Map.from_struct()
    |> Enum.map(fn {key, val} -> {to_string(key), jsonable(val)} end)
    |> Map.new()
  rescue
    _ -> inspect(value)
  end

  defp jsonable(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), jsonable(val)} end)
    |> Map.new()
  end

  defp jsonable(value), do: inspect(value)

  defp encode_uri(%URI{} = uri), do: URI.to_string(uri)
  defp encode_uri(_), do: nil
end
