defmodule EzagentPluginAutoservice.Assembly do
  @moduledoc """
  Idempotent provisioner for a single customer CS session on the AutoService
  v2 biphasic-agent path.

  `provision_session/3` (idempotent — re-running converges, never duplicates):

  1. CR publisher init — `EzagentPluginCr.Publisher.init_tenant/2` seeds release
     v1 for a fresh tenant (idempotent; resumes half-init).
  2. Workspace + customer user — ensure `workspace://<tid>`, create/ensure the
     customer `User` entity, add workspace membership, set the password (login
     row), grant customer caps.
  3. SocialwareSession — spawn + workspace-bind idempotently.
  4. Slow cc agent — provision context via `TenantContent.provision_context/2`,
     write `CLAUDE.md`, write `.mcp.json` (if KB path present), create via
     `Workspace.create_agent` with `flavor: "cc"`.
  5. Fast curl agent — provision context, register via `Workspace.add_template/3`
     (curl.agent class) so provider/api_url/model/system_prompt flow through the
     template instantiate path and are stored on the CurlAgent Kind.
  6. CS Orchestrator — tag flavor attribute, spawn `CsOrchestrator` Kind
     idempotently.
  7. Routing — install `in_session(session)` → [orchestrator_uri] rule
     (idempotent: rule already present = ok).
  8. Return `{:ok, %{session_uri, customer_uri, orchestrator_uri, fast_uri, slow_uri}}`.

  ## Bot-creation opt-out

  `provision_session/3` accepts `opts[:create_agents]` (default `true`).
  When `false`, the cc/curl `create_agent`/`add_template` calls are skipped
  and plain `Ezagent.Entity.Agent` Kinds are spawned instead. This enables
  full structural testing of session + orchestrator + routing without requiring
  a live claude environment or valid curl credentials.

  ## Fast agent config delivery

  The fast curl agent's `provider`/`api_url`/`model`/`system_prompt` are
  delivered via `Workspace.add_template/3` (curl.agent class template).
  `Workspace.create_agent` only forwards `flavor/name/cwd/with_pty/from` and
  DROPS any extra config — the template route is the only correct path.

  ## SLOW CC CONFIG GAP (Phase B)

  model/endpoint/explicit-effort overrides do NOT flow through
  `Workspace.create_agent` (it strips template_data to flavor/cwd/config_dir).
  Carrying them requires a per-agent AgentTemplate + spawn_from_template_content
  (the #17 cascade chokepoint) AND a cc `template_data_extra` producer for those
  keys — creation-unification-adjacent (Allen's domain), deferred.
  effort=low is delivered for free by #730's spawn_plan default
  (effort_for → "low" when absent), so the slow cc still gets ~26s replies
  once #730 syncs; model=deepseek is a cost optimization, not Phase-B-critical.

  ## `.mcp.json` path decision

  The cc spawn plan (`McpConfigWriter`) writes the bridge entry into
  `$CLAUDE_CONFIG_HOME/.mcp.json` (the per-agent config-dir, NOT the
  agent cwd). A work-dir `.mcp.json` (if present) is passed as
  `--mcp-config` by `spawn_plan`'s `per_agent_mcp_path`. These are
  DIFFERENT files — no conflict. We write `work_dir/.mcp.json` for the
  KB server; the bridge entry lives in config-dir `.mcp.json`. Both coexist.
  """

  alias Ezagent.{Invocation, KindRegistry, SpawnRegistry, WorkspaceRegistry}
  alias Ezagent.Entity.SocialwareSession
  alias EzagentPluginAutoservice.Roles
  alias EzagentPluginContent.TenantContent
  alias EzagentPluginCr.Publisher

  require Logger

  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

  @doc """
  Provision a full CS session for `customer_name` on tenant `tid`.

  `ctx` must carry `:caller` (a real entity URI, NOT a system principal — for
  `create_agent` capability grants) and `:caps`.

  `opts`:
  - `:create_agents` — `true` (default) creates real cc/curl agents;
    `false` uses plain entity stubs for structural testing.
  """
  @spec provision_session(String.t(), String.t(), map(), keyword()) ::
          {:ok,
           %{
             session_uri: URI.t(),
             customer_uri: URI.t(),
             orchestrator_uri: URI.t(),
             fast_uri: URI.t(),
             slow_uri: URI.t()
           }}
          | {:error, term()}
  def provision_session(tid, customer_name, ctx, opts \\ [])
      when is_binary(tid) and is_binary(customer_name) and is_map(ctx) do
    create_agents? = Keyword.get(opts, :create_agents, true)

    workspace_uri = Ezagent.URI.workspace(tid)
    customer_uri = Ezagent.URI.user(tid, customer_name)
    session_uri = Ezagent.URI.session(tid, "cs", customer_name)
    orch_uri = Ezagent.URI.agent(tid, "orch-cs-" <> customer_name)

    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_actor_uri = URI.to_string(admin_uri)

    with :ok <- ensure_admin_alive(),
         :ok <- content_init(tid, admin_actor_uri),
         :ok <- ensure_workspace(tid),
         :ok <- ensure_customer(customer_uri, customer_name, tid),
         {:ok, slow_uri} <-
           ensure_slow_agent(tid, customer_name, workspace_uri, ctx, create_agents?),
         {:ok, fast_uri} <-
           ensure_fast_agent(tid, customer_name, workspace_uri, ctx, create_agents?),
         # Spawn orchestrator BEFORE session join (chat.join requires the member to be registered)
         :ok <- ensure_orchestrator(orch_uri, session_uri, customer_uri, fast_uri, slow_uri),
         :ok <- ensure_session(session_uri, customer_uri, workspace_uri),
         :ok <- join(session_uri, customer_uri, ctx),
         :ok <- join(session_uri, slow_uri, ctx),
         :ok <- join(session_uri, fast_uri, ctx),
         :ok <- join(session_uri, orch_uri, ctx),
         :ok <- install_routing(session_uri, orch_uri, workspace_uri) do
      {:ok,
       %{
         session_uri: session_uri,
         customer_uri: customer_uri,
         orchestrator_uri: orch_uri,
         fast_uri: fast_uri,
         slow_uri: slow_uri
       }}
    end
  end

  @doc """
  Ensure an operator user exists on tenant `tid` with name `operator_name`.

  Creates the DB user row (password = operator_name, enables web login) and
  grants them the `Roles.bundle(:operator, workspace_uri)` capability set:
  session:join + turn:claim/settle + cs_orchestrator:operator_claim/settle,
  all scoped to this workspace (Stage F CapBAC role assignment).

  Idempotent: re-running converges, never duplicates.
  """
  @spec ensure_operator(String.t(), String.t()) :: {:ok, URI.t()} | {:error, term()}
  def ensure_operator(tid, operator_name)
      when is_binary(tid) and is_binary(operator_name) do
    operator_uri = Ezagent.URI.user(tid, operator_name)
    workspace_uri = Ezagent.URI.workspace(tid)

    create_result =
      case Ezagent.Users.create(operator_uri, operator_name, []) do
        {:ok, _decoded} ->
          :ok

        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :uri) do
            # Duplicate URI — already exists; idempotent OK.
            :ok
          else
            {:error, {:operator_create_failed, errors}}
          end

        {:error, reason} ->
          {:error, {:operator_create_failed, reason}}
      end

    with :ok <- create_result do
      _ = add_member(tid, operator_uri)

      # Grant operator caps — scoped operator role bundle (Stage F CapBAC).
      grant_ctx = %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }

      operator_caps = Roles.bundle(:operator, workspace_uri)

      Enum.each(operator_caps, fn cap ->
        Invocation.dispatch(%Invocation{
          target: Ezagent.URI.new!("#{URI.to_string(operator_uri)}?action=identity.grant_cap"),
          mode: :call,
          args: %{cap: cap},
          ctx: grant_ctx
        })
      end)

      {:ok, operator_uri}
    end
  end

  @doc """
  Ensure a tenant-admin user exists on tenant `tid` with name `admin_name`.

  Creates the DB user row (password = admin_name, enables web login) and
  grants them the `Roles.bundle(:tenant_admin, workspace_uri)` capability set:
  workspace manage + content write + user create, all scoped to this workspace.

  Idempotent: re-running converges, never duplicates.
  """
  @spec ensure_admin(String.t(), String.t()) :: {:ok, URI.t()} | {:error, term()}
  def ensure_admin(tid, admin_name)
      when is_binary(tid) and is_binary(admin_name) do
    admin_uri = Ezagent.URI.user(tid, admin_name)
    workspace_uri = Ezagent.URI.workspace(tid)

    create_result =
      case Ezagent.Users.create(admin_uri, admin_name, []) do
        {:ok, _decoded} ->
          :ok

        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :uri) do
            # Duplicate URI — already exists; idempotent OK.
            :ok
          else
            {:error, {:admin_create_failed, errors}}
          end

        {:error, reason} ->
          {:error, {:admin_create_failed, reason}}
      end

    with :ok <- create_result do
      _ = add_member(tid, admin_uri)

      grant_ctx = %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }

      admin_caps = Roles.bundle(:tenant_admin, workspace_uri)

      Enum.each(admin_caps, fn cap ->
        Invocation.dispatch(%Invocation{
          target: Ezagent.URI.new!("#{URI.to_string(admin_uri)}?action=identity.grant_cap"),
          mode: :call,
          args: %{cap: cap},
          ctx: grant_ctx
        })
      end)

      {:ok, admin_uri}
    end
  end

  @doc """
  Read the open_turn_id from the live CS Orchestrator Kind state.

  **Phase-B shortcut**: uses `:sys.get_state/2` to read the orchestrator's
  Lifecycle state directly. This is acceptable for Phase B (documented here)
  because there is no sanctioned read action on the orchestrator yet.
  Stage F will replace this with a CapBAC-gated `orchestrator.read_state`
  dispatch action.

  Returns the open_turn_id string if the orchestrator is alive and has one,
  or `nil` if the orchestrator is dormant, not found, or has no open turn.
  """
  @spec open_turn_id(URI.t()) :: String.t() | nil
  def open_turn_id(%URI{} = orch_uri) do
    case KindRegistry.lookup(orch_uri) do
      {:ok, pid} ->
        try do
          server_state = :sys.get_state(pid, 1_000)
          # Lifecycle two-container slice key is derived from the Behavior module name.
          # CsOrchestrator → :cs_orchestrator (the state_slice/0 atom).
          slice = get_in(server_state, [:state, :cs_orchestrator])

          case slice do
            %{state: %{open_turn_id: tid}} when is_binary(tid) -> tid
            %{open_turn_id: tid} when is_binary(tid) -> tid
            _ -> nil
          end
        rescue
          e ->
            Logger.info("Assembly.open_turn_id: :sys.get_state failed: #{inspect(e)}")
            nil
        end

      :error ->
        nil
    end
  end

  @doc """
  Runtime: ensure the customer's (already-provisioned) SocialwareSession is
  alive and the customer is joined. Returns `{:ok, session_uri}`.

  Used by `CustomerLive.mount/3` path.
  """
  @spec ensure_joined(URI.t()) :: {:ok, URI.t()} | {:error, term()}
  def ensure_joined(%URI{scheme: "entity"} = customer_uri) do
    ctx = session_internal_ctx()
    workspace_uri = Ezagent.URI.entity_workspace_uri(customer_uri)
    {:ok, tid} = Ezagent.URI.workspace_name(workspace_uri)
    {:ok, name} = Ezagent.URI.name(customer_uri)
    session_uri = Ezagent.URI.session(tid, "cs", name)

    with :ok <- ensure_user_alive(customer_uri),
         :ok <- ensure_session(session_uri, customer_uri, workspace_uri),
         :ok <- join(session_uri, customer_uri, ctx) do
      {:ok, session_uri}
    end
  end

  @doc """
  Ensure a CS `SocialwareSession` Kind is alive for `session_uri`.

  CS sessions MUST run as `Ezagent.Entity.SocialwareSession` (it carries the
  Turn behaviors). The generic `SpawnRegistry` `"session"` handler spawns a
  PLAIN chat `Session` (Chat but NO Turn) — so any path that rehydrates a
  dormant CS session via that handler leaves it unable to answer `turn.open`
  (`{:unknown_action, :open}`). `ensure_joined/1` (customer mount) already
  avoids this by going through `ensure_session/3`; this public wrapper lets the
  operator console do the same on session-select. Derives the session owner
  (the customer) structurally from the `session://<ws>/cs/<name>` URI.
  """
  @spec ensure_socialware_session(URI.t(), URI.t()) :: :ok | {:error, term()}
  def ensure_socialware_session(
        %URI{scheme: "session"} = session_uri,
        %URI{scheme: "workspace"} = workspace_uri
      ) do
    with {:ok, tid} <- Ezagent.URI.workspace_name(session_uri),
         {:ok, name} <- Ezagent.URI.name(session_uri) do
      owner_uri = Ezagent.URI.user(tid, name)
      ensure_session(session_uri, owner_uri, workspace_uri)
    else
      other -> {:error, {:bad_cs_session_uri, other}}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 1 — Content release init
  # ---------------------------------------------------------------------------

  defp content_init(tid, actor_uri) do
    case Publisher.init_tenant(tid, actor_uri) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:content_init_failed, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Step 2 — Workspace + customer user
  # ---------------------------------------------------------------------------

  defp ensure_workspace(tid) do
    case Ezagent.Workspace.create(tid, %{}) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        ws_uri = Ezagent.URI.workspace(tid)

        case KindRegistry.lookup(ws_uri) do
          {:ok, _pid} -> :ok
          :error -> {:error, {:workspace_create_failed, reason}}
        end
    end
  end

  defp ensure_customer(customer_uri, customer_name, tid) do
    workspace_uri = Ezagent.URI.workspace(tid)

    # Create the DB user row with password (enables web login).
    # A URI unique-constraint violation means the customer already exists
    # from a prior provision — that is the idempotent success case.
    # Any other error is a real failure and must stop execution.
    create_result =
      case Ezagent.Users.create(customer_uri, customer_name, []) do
        {:ok, _decoded} ->
          :ok

        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :uri) do
            # Duplicate URI — customer already exists; idempotent OK.
            :ok
          else
            {:error, {:customer_create_failed, errors}}
          end

        {:error, reason} ->
          {:error, {:customer_create_failed, reason}}
      end

    with :ok <- create_result do
      # Add workspace membership (best-effort — already-member is ok).
      _ = add_member(tid, customer_uri)

      # Grant customer caps via dispatch (same pattern as Stage-1 seed).
      grant_ctx = %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }

      customer_caps = Roles.bundle(:customer, workspace_uri)

      Enum.each(customer_caps, fn cap ->
        Invocation.dispatch(%Invocation{
          target: Ezagent.URI.new!("#{URI.to_string(customer_uri)}?action=identity.grant_cap"),
          mode: :call,
          args: %{cap: cap},
          ctx: grant_ctx
        })
      end)

      :ok
    end
  end

  defp add_member(tid, uri) do
    Ezagent.Workspace.add_member(tid, uri)
  rescue
    e ->
      Logger.info("Assembly: add_member #{URI.to_string(uri)} skipped: #{inspect(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Step 3 — SocialwareSession
  # ---------------------------------------------------------------------------

  defp ensure_session(%URI{} = session_uri, %URI{} = owner_uri, %URI{} = workspace_uri) do
    spawn_result =
      case KindRegistry.lookup(session_uri) do
        {:ok, _pid} ->
          :ok

        :error ->
          case Ezagent.Kind.spawn(SocialwareSession, %{
                 uri: session_uri,
                 owner_uri: owner_uri
               }) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, {:already_registered, _}} -> :ok
            {:error, reason} -> {:error, {:session_spawn_failed, reason}}
          end
      end

    with :ok <- spawn_result do
      :ok = WorkspaceRegistry.bind(session_uri, workspace_uri)
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Step 4 — Slow cc agent
  # ---------------------------------------------------------------------------

  defp ensure_slow_agent(tid, customer_name, workspace_uri, ctx, true) do
    agent_name = "cs-slow-" <> customer_name

    case TenantContent.provision_context(tid, "slow") do
      {:ok, sctx} ->
        File.mkdir_p!(sctx.work_dir)
        File.write!(Path.join(sctx.work_dir, "CLAUDE.md"), sctx.claude_md || "")
        maybe_write_mcp_json(tid, sctx)

        args = %{
          flavor: "cc",
          name: agent_name,
          cwd: sctx.work_dir,
          with_pty: false
        }

        create_or_lookup_agent(workspace_uri, args, ctx)

      {:error, reason} ->
        {:error, {:slow_content_failed, reason}}
    end
  end

  defp ensure_slow_agent(tid, customer_name, _workspace_uri, _ctx, false) do
    agent_name = "cs-slow-" <> customer_name
    agent_uri = Ezagent.URI.agent(tid, agent_name)
    stub_agent(agent_uri)
  end

  defp maybe_write_mcp_json(_tid, %{kb_db_path: nil}), do: :ok

  defp maybe_write_mcp_json(
         tid,
         %{kb_db_path: kb_db_path, skills_dir: skills_dir, work_dir: work_dir}
       ) do
    # KB MCP server script lives at <skills_dir>/../kb/kb_search_mcp.py
    # (skills_dir is <release_dir>/skills, parent is <release_dir>).
    kb_script = Path.join([Path.dirname(skills_dir), "kb", "kb_search_mcp.py"])
    # MCP server name is derived from tid so each tenant has its own namespaced key.
    kb_server_name = "#{tid}-kb"

    mcp_config = %{
      "mcpServers" => %{
        kb_server_name => %{
          "command" => "python3",
          "args" => [kb_script],
          "env" => %{"KB_DB_PATH" => kb_db_path}
        }
      }
    }

    # Write to work_dir/.mcp.json — this is the per_agent_mcp_path that
    # spawn_plan passes via --mcp-config. The bridge entry lives in the
    # per-agent config-dir .mcp.json (written by McpConfigWriter), NOT in
    # the cwd — so no conflict: two separate files.
    mcp_path = Path.join(work_dir, ".mcp.json")
    File.write!(mcp_path, Jason.encode!(mcp_config, pretty: true))
  end

  # ---------------------------------------------------------------------------
  # Step 5 — Fast curl agent
  # ---------------------------------------------------------------------------

  defp ensure_fast_agent(tid, customer_name, _workspace_uri, _ctx, true) do
    curl_name = "cs-fast-" <> customer_name
    # The curl.agent Template Class instantiate/3 spawns the CurlAgent at the URI
    # carried in the template's "agent_uri" field — entity://<tid>/agent/<curl_name>.
    agent_uri = Ezagent.URI.agent(tid, curl_name)
    agent_uri_str = URI.to_string(agent_uri)

    case TenantContent.provision_context(tid, "fast") do
      {:ok, fctx} ->
        ac = fctx.agent_config || %{}
        provider = Map.get(ac, "provider") || Map.get(ac, :provider) || ""

        # NOTE: agents.yaml's fast.max_tokens has NO consumer in curl (curl reads
        # "max_history" — a different concept, a count of history turns, not token
        # budget). Do NOT thread max_tokens here. This is an acknowledged gap.
        tmpl = %{
          "class" => "curl.agent",
          "agent_uri" => agent_uri_str,
          "provider" => provider,
          "api_url" => Map.get(ac, "api_url") || Map.get(ac, :api_url) || "",
          "model" => Map.get(ac, "model") || Map.get(ac, :model) || "",
          "system_prompt" => fctx.system_prompt
        }

        # Template name: stable per-agent, using the curl_name so re-provision
        # overwrites the same template slot (Map.put semantics in add_template).
        tmpl_name = "curl.agent." <> curl_name

        case Ezagent.Workspace.add_template(tid, tmpl_name, tmpl) do
          :ok ->
            _ = maybe_put_api_key(agent_uri, provider)
            {:ok, agent_uri}

          {:error, {:already_started, _pid}} ->
            # Idempotent: agent is already alive from a previous provision.
            {:ok, agent_uri}

          {:error, {:already_registered, _}} ->
            {:ok, agent_uri}

          {:error, reason} ->
            # Tight race: check live registry before propagating failure.
            case Ezagent.KindRegistry.lookup(agent_uri) do
              {:ok, _pid} -> {:ok, agent_uri}
              :error -> {:error, {:fast_agent_add_template_failed, curl_name, reason}}
            end
        end

      {:error, reason} ->
        {:error, {:fast_content_failed, reason}}
    end
  end

  defp ensure_fast_agent(tid, customer_name, _workspace_uri, _ctx, false) do
    agent_name = "cs-fast-" <> customer_name
    agent_uri = Ezagent.URI.agent(tid, agent_name)
    stub_agent(agent_uri)
  end

  # The fast curl agent reads its OWN provider key from its `:api_keys` slice
  # (curl_agent.ex `fetch_self_api_key/2`); without it the agent returns
  # `{:no_api_key, provider}` and produces no ACK. The key is a SECRET, so it is
  # NEVER baked into the agents.yaml/template — it is read from the environment
  # (`<PROVIDER>_API_KEY`, e.g. `DEEPSEEK_API_KEY`) at provision time and stored
  # via the `api_keys.put_api_key` dispatch. If the env var is absent we log a
  # clear warning and skip — the slow cc path still works; only the fast ACK
  # (biphasic) leg is unavailable until a key is provided.
  defp maybe_put_api_key(%URI{} = agent_uri, provider)
       when is_binary(provider) and provider != "" do
    env_var = String.upcase(provider) <> "_API_KEY"

    case System.get_env(env_var) do
      key when is_binary(key) and key != "" ->
        ctx = %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: {:caller_inbox, self()}
        }

        target =
          Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=api_keys.put_api_key")

        case Invocation.dispatch(%Invocation{
               target: target,
               mode: :call,
               args: %{provider: provider, key: key},
               ctx: ctx
             }) do
          {:ok, _} ->
            Logger.info(
              "Assembly: provisioned #{provider} api_key for #{URI.to_string(agent_uri)} (from $#{env_var})"
            )

            :ok

          other ->
            Logger.warning(
              "Assembly: api_keys.put_api_key failed for #{URI.to_string(agent_uri)} " <>
                "(#{inspect(other)}) — fast ACK will be unavailable"
            )

            :ok
        end

      _ ->
        Logger.warning(
          "Assembly: no $#{env_var} in env — fast curl agent " <>
            "#{URI.to_string(agent_uri)} has no #{provider} key; the fast ACK leg is " <>
            "DISABLED (slow cc reply still works). Set $#{env_var} and re-provision to enable."
        )

        :ok
    end
  end

  defp maybe_put_api_key(_agent_uri, _provider), do: :ok

  # ---------------------------------------------------------------------------
  # create_agent wrapper (idempotent) — cc slow agent only
  # ---------------------------------------------------------------------------

  # `Workspace.create_agent/3` accepts args with keys `:flavor`, `:name`,
  # `:cwd`, `:with_pty` (and optional `:from`). The curl fast agent no longer
  # uses this path — it goes through `Workspace.add_template/3` so that
  # provider/api_url/model/system_prompt flow into the CurlAgent Kind via the
  # template instantiate path.
  #
  # SLOW CC CONFIG GAP — see module @moduledoc for the full explanation.
  defp create_or_lookup_agent(workspace_uri, args, ctx) do
    {:ok, tid} = Ezagent.URI.workspace_name(workspace_uri)
    agent_name = Map.fetch!(args, :name)
    agent_uri = Ezagent.URI.agent(tid, agent_name)

    case Ezagent.Workspace.create_agent(workspace_uri, args, ctx) do
      {:ok, %{agent_uri: %URI{} = uri}} ->
        {:ok, uri}

      {:error, {:already_exists, _}} ->
        # Idempotent: agent exists from a previous provision run.
        {:ok, agent_uri}

      {:error, reason} ->
        # Tight race: check live registry.
        case KindRegistry.lookup(agent_uri) do
          {:ok, _pid} -> {:ok, agent_uri}
          :error -> {:error, {:agent_create_failed, agent_name, reason}}
        end
    end
  end

  defp stub_agent(%URI{} = agent_uri) do
    case KindRegistry.lookup(agent_uri) do
      {:ok, _pid} ->
        {:ok, agent_uri}

      :error ->
        case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri}) do
          {:ok, _pid} -> {:ok, agent_uri}
          {:error, {:already_started, _pid}} -> {:ok, agent_uri}
          {:error, {:already_registered, _}} -> {:ok, agent_uri}
          {:error, reason} -> {:error, {:stub_agent_spawn_failed, agent_uri, reason}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Step 6 — Orchestrator
  # ---------------------------------------------------------------------------

  defp ensure_orchestrator(orch_uri, session_uri, customer_uri, fast_uri, slow_uri) do
    :ok = Ezagent.AgentFlavorAttributes.put(orch_uri, "cs_orchestrator")

    params = %{
      uri: orch_uri,
      session_uri: URI.to_string(session_uri),
      customer_uri: URI.to_string(customer_uri),
      fast_uri: URI.to_string(fast_uri),
      slow_uri: URI.to_string(slow_uri)
    }

    case KindRegistry.lookup(orch_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.Kind.spawn(Ezagent.Entity.CsOrchestrator, params) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, {:already_registered, _}} -> :ok
          {:error, reason} -> {:error, {:orchestrator_spawn_failed, reason}}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Step 7 — Routing
  # ---------------------------------------------------------------------------

  defp install_routing(session_uri, orch_uri, workspace_uri) do
    session_str = URI.to_string(session_uri)
    orch_str = URI.to_string(orch_uri)
    existing = Ezagent.Routing.RuleStore.list(@routing_table)

    # Idempotent: if the orchestrator is already a receiver, we're done.
    if Enum.any?(existing, fn r -> orch_str in (r.receivers || []) end) do
      _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
      :ok
    else
      # in_session(session) only — agent replies also route to the orchestrator
      # so the orchestrator sees both customer messages and bot replies.
      matcher = {:in_session, session_str}

      case Ezagent.Routing.RuleStore.add(
             @routing_table,
             matcher,
             [orch_uri],
             nil,
             workspace_uri: workspace_uri
           ) do
        {:ok, _rule} ->
          _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
          :ok

        {:error, reason} ->
          {:error, {:routing_rule_failed, reason}}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Session join helper (mirrors Stage-1 pattern)
  # ---------------------------------------------------------------------------

  defp join(%URI{} = session_uri, %URI{} = member_uri, ctx) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
      })

    case result do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, {:join_failed, URI.to_string(member_uri), reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Admin + user lifecycle helpers
  # ---------------------------------------------------------------------------

  defp ensure_admin_alive do
    uri = Ezagent.Entity.User.admin_uri()

    case KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case SpawnRegistry.spawn(uri) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:admin_spawn_failed, reason}}
        end
    end
  end

  defp ensure_user_alive(%URI{} = uri) do
    case KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case SpawnRegistry.spawn(uri) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:user_spawn_failed, URI.to_string(uri), reason}}
        end
    end
  end

  defp session_internal_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("session-internal"),
      caps: Ezagent.SystemPrincipal.caps("system://session-internal")
    }
  end
end
