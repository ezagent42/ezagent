defmodule EzagentPluginAutoservice.CustomerSession do
  @moduledoc """
  Assembles + maintains a customer's service session.

  A customer-service session is a plain `Session` Kind with a fixed
  agent team -- NOT the LLM-orchestrator Generator
  (`Session.spawn_from_template/2`). The Generator spawns a full cc
  (claude) orchestrator per session for team-composition reasoning; a
  customer-service session has a fixed fast(+slow) team, so the
  orchestrator would be dead weight (one claude process per customer).

  ## v0.2 -- Content plugin integration

  This version replaces all CINNOX hardcoding with content plugin APIs:

  - **Fast agent prompt**: `File.read!` from the tenant release config
    (`fast_ack_prompt.md`), located via `TenantRuntime.current_release_path/1`.
  - **Fast agent model/endpoint**: read from `agents.yaml` at
    `priv/skeleton/config/agents.yaml` (module-level cached).
  - **Slow agent**: `TenantRuntime.materialize/3` symlinks skills + KB into
    a per-agent work dir.
  - **Soul**: `SoulRenderer.full_claude_md/3` generates CLAUDE.md from
    loaded templates + slot_values.
  - **MCP**: `KbMcpProvider.config/2` generates the <tid>-kb MCP server
    entry for `.mcp.json`.

  ## Entry points

  - `provision/2` -- seed-time, runs under a privileged principal
    (`system://mix-task`). Creates the fast agent, sets its DeepSeek
    key, spawns the session, joins the team, installs the
    customer->agents routing rule, posts the opening greeting.
  - `ensure_joined/1` -- runtime, called by the customer LiveView on
    mount. Assumes the session was provisioned; just rehydrates +
    re-joins the customer.
  """

  alias Ezagent.{Invocation, KindRegistry, SpawnRegistry, WorkspaceRegistry}
  alias EzagentPluginAutoservice.Uris

  alias EzagentPluginContent.Soul.SoulRenderer
  alias EzagentPluginContent.Tenant.TenantRuntime
  alias EzagentPluginContent.Kb.KbMcpProvider

  require Logger

  # --- Module-level cached config ---

  # The routing table the chat fan-out consults (`Ezagent.Routing.Resolver`
  # default). Declared by `EzagentDomainInstanceMessage` at boot.
  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

  @default_greeting "您好,我是在线客服助手。请问有什么可以帮您?"

  @skeleton_config_dir Path.join(:code.priv_dir(:ezagent_plugin_content), "skeleton/config")

  # Cached agents.yaml (loaded once at compile time).
  @agents_config YamlElixir.read_from_file!(Path.join(@skeleton_config_dir, "agents.yaml"))

  @fast_provider get_in(@agents_config, ["fast", "provider"]) || "deepseek"
  @fast_model get_in(@agents_config, ["fast", "model"]) || "deepseek-chat"
  @fast_endpoint get_in(@agents_config, ["fast", "endpoint"]) ||
                   "https://api.deepseek.com/chat/completions"

  @typedoc "Setup context -- `%{caller: URI.t(), caps: [Capability.t()]}`."
  @type setup_ctx :: %{caller: URI.t(), caps: list()}

  @doc """
  Seed-time full assembly for one customer. Idempotent.

  Required opts:
  - `:tid` -- tenant ID (String), used to locate tenant release config
    and materialize slow agent workspace
  - `:workspace_uri` -- `%URI{scheme: "workspace"}`
  - `:ctx` -- `%{caller:, caps:}` privileged setup principal

  Optional opts:
  - `:deepseek_key` -- DeepSeek API key for the fast agent (nil => the
    agent is created but replies with a "configure my key" message)
  - `:with_slow` -- also spawn a cc (slow) agent (default `false`)
  - `:greeting` -- opening line posted by the fast agent
  - `:soul_slot_values` -- `%{String.t() => String.t()}` for rendering
    `{{key}}` placeholders in the slow agent's CLAUDE.md
  - `:role` -- agent role name for TenantRuntime.materialize/3 (default `"slow"`)
  """
  @spec provision(URI.t(), keyword()) ::
          {:ok, %{session_uri: URI.t(), fast_uri: URI.t(), slow_uri: URI.t() | nil}}
          | {:error, term()}
  def provision(%URI{scheme: "entity"} = customer_uri, opts) do
    # 3-segment URI format: entity://<ws>/user/<name>
    # Validate the type segment is "user".
    if Ezagent.URI.type(customer_uri) != {:ok, "user"} do
      raise ArgumentError,
            "CustomerSession.provision/2 requires a user URI (entity://<ws>/user/<name>), " <>
              "got: #{URI.to_string(customer_uri)}"
    end

    tid = Keyword.fetch!(opts, :tid)
    workspace_uri = Keyword.fetch!(opts, :workspace_uri)
    ctx = Keyword.fetch!(opts, :ctx)
    greeting = Keyword.get(opts, :greeting, @default_greeting)
    deepseek_key = System.get_env("DEEPSEEK_API_KEY") || Keyword.get(opts, :deepseek_key)
    with_slow? = Keyword.get(opts, :with_slow, false)
    soul_slot_values = Keyword.get(opts, :soul_slot_values, %{})
    role = Keyword.get(opts, :role, "slow")

    session_uri = Uris.session_uri(customer_uri)
    fast_uri = Uris.fast_agent_uri(customer_uri)

    # Load fast ACK prompt from tenant release config (or fall back to skeleton default).
    fast_prompt = load_fast_prompt(tid)

    with :ok <- ensure_user_alive(customer_uri),
         {:ok, ^fast_uri} <-
           ensure_fast_agent(customer_uri, workspace_uri, fast_prompt, soul_slot_values, tid),
         :ok <- maybe_put_deepseek_key(fast_uri, deepseek_key, ctx),
         {:ok, slow_uri} <-
           maybe_slow_agent(
             customer_uri,
             workspace_uri,
             with_slow?,
             ctx,
             soul_slot_values,
             tid,
             role
           ),
         :ok <- ensure_session(session_uri, customer_uri, workspace_uri),
         :ok <- join(session_uri, customer_uri, ctx),
         :ok <- join(session_uri, fast_uri, ctx),
         :ok <- maybe_join(session_uri, slow_uri, ctx),
         :ok <- install_routing(session_uri, customer_uri, fast_uri, slow_uri, workspace_uri),
         :ok <- post_greeting(session_uri, fast_uri, greeting, ctx) do
      {:ok, %{session_uri: session_uri, fast_uri: fast_uri, slow_uri: slow_uri}}
    end
  end

  @doc """
  Runtime: ensure the customer's (already-provisioned) session is alive
  and the customer is joined. Returns the session URI.
  """
  @spec ensure_joined(URI.t()) :: {:ok, URI.t()} | {:error, term()}
  def ensure_joined(%URI{scheme: "entity"} = customer_uri) do
    if Ezagent.URI.type(customer_uri) != {:ok, "user"} do
      {:error, {:not_a_user_uri, URI.to_string(customer_uri)}}
    else
      _ensure_joined(customer_uri)
    end
  end

  defp _ensure_joined(%URI{} = customer_uri) do
    ctx = session_internal_ctx()
    session_uri = Uris.session_uri(customer_uri)
    workspace_uri = Ezagent.URI.entity_workspace_uri(customer_uri)
    fast_uri = Uris.fast_agent_uri(customer_uri)
    slow_uri = Uris.slow_agent_uri(customer_uri)

    with :ok <- ensure_user_alive(customer_uri),
         :ok <- ensure_session(session_uri, customer_uri, workspace_uri),
         :ok <- join(session_uri, customer_uri, ctx),
         :ok <- join(session_uri, fast_uri, ctx),
         :ok <- maybe_join_slow(session_uri, slow_uri, ctx) do
      {:ok, session_uri}
    end
  end

  # Only join the slow agent if it exists (it's optional — only created with --with-slow).
  defp maybe_join_slow(session_uri, slow_uri, ctx) do
    case KindRegistry.lookup(slow_uri) do
      {:ok, _pid} -> join(session_uri, slow_uri, ctx)
      :error -> :ok
    end
  end

  @doc "The customer-service session URI for a customer (no side effects)."
  @spec session_uri(URI.t()) :: URI.t()
  def session_uri(customer_uri), do: Uris.session_uri(customer_uri)

  @doc "Default opening greeting."
  def default_greeting, do: @default_greeting

  @doc "Fast agent provider from agents.yaml."
  def fast_provider, do: @fast_provider

  @doc "Fast agent model from agents.yaml."
  def fast_model, do: @fast_model

  @doc "Fast agent endpoint from agents.yaml."
  def fast_endpoint, do: @fast_endpoint

  # --- internals ------------------------------------------------------

  # Load fast ACK prompt: first try the tenant release config, fall back
  # to the skeleton default shipped with the content plugin.
  defp load_fast_prompt(tid) do
    tenant_config_path =
      Path.join([TenantRuntime.current_release_path(tid), "config", "fast_ack_prompt.md"])

    if File.exists?(tenant_config_path) do
      File.read!(tenant_config_path)
    else
      skeleton_default = Path.join(@skeleton_config_dir, "fast_ack_prompt.md")
      File.read!(skeleton_default)
    end
  end

  defp ensure_user_alive(%URI{scheme: "entity"} = uri) do
    # 3-segment URI format: entity://<ws>/user/<name>
    # Validate the type segment is "user" to guard against agent URIs.
    if Ezagent.URI.type(uri) != {:ok, "user"} do
      {:error, {:not_a_user_uri, URI.to_string(uri)}}
    else
      _ensure_user_alive(uri)
    end
  end

  defp _ensure_user_alive(%URI{} = uri) do
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

  # Provision the fast agent as a workspace `curl.agent` TEMPLATE.
  # The template is re-instantiated by `Workspace.Loader.load_all/0` on
  # every boot, so the fast agent is always alive after a restart.
  defp ensure_fast_agent(
         customer_uri,
         %URI{scheme: "workspace"} = workspace_uri,
         system_prompt,
         soul_slot_values,
         _tid
       ) do
    fast_uri = Uris.fast_agent_uri(customer_uri)
    {_ws, name} = Uris.decompose_customer(customer_uri)
    tmpl_name = "autoservice.fast." <> name

    tmpl = %{
      "class" => "curl.agent",
      "agent_uri" => URI.to_string(fast_uri),
      "provider" => @fast_provider,
      "api_url" => @fast_endpoint,
      "model" => @fast_model,
      "system_prompt" => system_prompt,
      "max_history" => 20,
      "soul_slot_values" => soul_slot_values
    }

    case Ezagent.Workspace.add_template(workspace_uri.host, tmpl_name, tmpl) do
      :ok ->
        {:ok, fast_uri}

      {:error, reason} ->
        case KindRegistry.lookup(fast_uri) do
          {:ok, _pid} -> {:ok, fast_uri}
          :error -> {:error, {:fast_agent_template_failed, reason}}
        end
    end
  end

  defp maybe_put_deepseek_key(_fast_uri, nil, _ctx), do: :ok
  defp maybe_put_deepseek_key(_fast_uri, "", _ctx), do: :ok

  defp maybe_put_deepseek_key(%URI{} = fast_uri, key, ctx) when is_binary(key) do
    target = URI.new!("#{URI.to_string(fast_uri)}?action=identity.put_api_key")

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{provider: "deepseek", key: key},
        ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
      })

    case result do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, {:put_deepseek_key_failed, reason}}
    end
  end

  defp maybe_slow_agent(_customer_uri, _workspace_uri, false, _ctx, _slot_values, _tid, _role),
    do: {:ok, nil}

  defp maybe_slow_agent(customer_uri, workspace_uri, true, ctx, soul_slot_values, tid, role) do
    slow_uri = Uris.slow_agent_uri(customer_uri)

    case KindRegistry.lookup(slow_uri) do
      {:ok, _pid} ->
        {:ok, slow_uri}

      :error ->
        # Materialize agent work dir via content plugin: symlinks
        # skills/<role> + kb.db from release/_current into a per-agent
        # cc-agents/<role>-work directory.
        base = TenantRuntime.materialize(tid, role, :release)
        name = Uris.slow_agent_create_name(customer_uri)
        work_dir = Path.join(Path.dirname(base), "#{name}-work")
        File.mkdir_p!(work_dir)

        # Symlink skills + kb.db into the per-agent dir (avoids copy bloat
        # and keeps a single SoT).
        for entry <- File.ls!(base) |> Enum.reject(&(&1 in [".mcp.json", "#{name}-work"])) do
          src = Path.join(base, entry)
          dst = Path.join(work_dir, entry)
          unless File.exists?(dst), do: File.ln_s(src, dst)
        end

        # Load soul templates for the role from the tenant release.
        # Soul templates live at release/_current/soul/<role>.md or as
        # layered templates; for now we load the single soul.md if present.
        soul_templates = load_soul_templates(tid, role)
        skill_index = load_skill_index(tid, role)

        # Render CLAUDE.md with slot values + skill index.
        rendered_claude_md =
          SoulRenderer.full_claude_md(soul_templates, soul_slot_values, skill_index)

        File.write!(Path.join(work_dir, "CLAUDE.md"), rendered_claude_md)

        case Ezagent.Workspace.create_agent(
               workspace_uri,
               %{flavor: "cc", name: name, cwd: work_dir, with_pty: false},
               ctx
             ) do
          {:ok, %{agent_uri: %URI{} = uri}} ->
            # Merge tenant KB MCP config into the agent's .mcp.json
            # (create_agent already wrote esr-bridge; add KB sidecar).
            mcp_path = Path.join(work_dir, ".mcp.json")

            if File.exists?(mcp_path) do
              sandbox_kb_dir = Path.join([TenantRuntime.sandbox_path(tid), "kb"])
              kb_mcp_json = KbMcpProvider.config(tid, sandbox_kb_dir)
              kb_mcp = Jason.decode!(kb_mcp_json)

              mcp =
                mcp_path
                |> File.read!()
                |> Jason.decode!()
                |> Map.update!("mcpServers", &Map.merge(kb_mcp["mcpServers"], &1))

              File.write!(mcp_path, Jason.encode_to_iodata!(mcp, pretty: true))
            end

            {:ok, uri}

          {:error, reason} ->
            case KindRegistry.lookup(slow_uri) do
              {:ok, _pid} -> {:ok, slow_uri}
              :error -> {:error, {:slow_agent_create_failed, reason}}
            end
        end
    end
  end

  # Load soul templates for a role from the tenant release directory.
  # Looks for: release/_current/soul/<role>.md  or  release/_current/soul/<role>/soul.md
  defp load_soul_templates(tid, role) do
    release_current = TenantRuntime.current_release_path(tid)
    direct = Path.join([release_current, "soul", "#{role}.md"])
    layered = Path.join([release_current, "soul", role, "soul.md"])

    cond do
      File.exists?(direct) -> [File.read!(direct)]
      File.exists?(layered) -> [File.read!(layered)]
      true -> []
    end
  end

  # Load skill index for a role from the tenant release directory.
  # Looks for: release/_current/skills/<role>/SKILL_INDEX.md
  defp load_skill_index(tid, role) do
    index_path =
      Path.join([TenantRuntime.current_release_path(tid), "skills", role, "SKILL_INDEX.md"])

    if File.exists?(index_path) do
      File.read!(index_path)
    else
      ""
    end
  end

  defp ensure_session(%URI{} = session_uri, %URI{} = owner_uri, %URI{} = workspace_uri) do
    spawn_result =
      case KindRegistry.lookup(session_uri) do
        {:ok, _pid} ->
          :ok

        :error ->
          case Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
                 uri: session_uri,
                 owner_uri: owner_uri,
                 behaviors: Ezagent.Entity.Session.socialware_behaviors()
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

  defp maybe_join(_session_uri, nil, _ctx), do: :ok
  defp maybe_join(session_uri, %URI{} = member_uri, ctx), do: join(session_uri, member_uri, ctx)

  defp join(%URI{} = session_uri, %URI{} = member_uri, ctx) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :cast,
        args: %{member: member_uri},
        ctx: Map.put(ctx, :reply, :ignore)
      })

    :ok
  end

  # customer message in THIS session -> fast (+ slow) agent.
  defp install_routing(session_uri, customer_uri, fast_uri, slow_uri, workspace_uri) do
    fast_str = URI.to_string(fast_uri)
    existing = Ezagent.Routing.RuleStore.list(@routing_table)

    if Enum.any?(existing, fn r -> fast_str in (r.receivers || []) end) do
      _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
      :ok
    else
      # Route customer messages through CsOrchestrator Behavior.
      # CsOrchestrator handles Turn.open + dispatch_after_commit fan-out to
      # fast+slow agents. Direct agent receivers removed to avoid duplicate
      # dispatch (MentionRouting delivers to ALL matching receivers — chat.ex:512).
      orch_receiver =
        Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=cs_orchestrator.process_message")

      receivers = [orch_receiver]

      matcher =
        {:and,
         [
           {:in_session, URI.to_string(session_uri)},
           {:from, URI.to_string(customer_uri)}
         ]}

      case Ezagent.Routing.RuleStore.add(
             @routing_table,
             matcher,
             receivers,
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

  defp slow_receivers(nil), do: []
  defp slow_receivers(%URI{} = slow_uri), do: [slow_uri]

  defp post_greeting(_session_uri, _fast_uri, greeting, _ctx)
       when not is_binary(greeting) or greeting == "",
       do: :ok

  defp post_greeting(%URI{} = session_uri, %URI{} = fast_uri, greeting, ctx) do
    case Ezagent.MessageStore.recent_in_session(session_uri, 1) do
      [] -> do_post_greeting(session_uri, fast_uri, greeting, ctx)
      [_ | _] -> :ok
    end
  end

  defp do_post_greeting(%URI{} = session_uri, %URI{} = fast_uri, greeting, ctx) do
    msg = Ezagent.Message.new(fast_uri, %{text: greeting, attachments: []})
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{message: msg},
        ctx: Map.put(ctx, :reply, {:caller_inbox, self()})
      })

    :ok
  end

  defp session_internal_ctx do
    %{
      caller: Ezagent.SystemPrincipal.uri("session-internal"),
      caps: Ezagent.SystemPrincipal.caps("system://session-internal")
    }
  end
end
