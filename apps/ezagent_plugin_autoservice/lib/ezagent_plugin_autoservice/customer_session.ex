defmodule EzagentPluginAutoservice.CustomerSession do
  @moduledoc """
  Assembles + maintains a customer's service session.

  A customer-service session is a plain `Session` Kind with a fixed
  agent team — NOT the LLM-orchestrator Generator
  (`Session.spawn_from_template/2`). The Generator spawns a full cc
  (claude) orchestrator per session for team-composition reasoning; a
  customer-service session has a fixed fast(+slow) team, so the
  orchestrator would be dead weight (one claude process per customer).

  Two entry points, both idempotent (reconciler style — re-running
  converges, never duplicates):

  - `provision/2` — seed-time, runs under a privileged principal
    (`system://mix-task`). Creates the fast agent, sets its DeepSeek
    key, spawns the session, joins the team, installs the
    customer→agents routing rule, posts the opening greeting.
  - `ensure_joined/1` — runtime, called by the customer LiveView on
    mount. Assumes the session was provisioned; just rehydrates +
    re-joins the customer (`chat.join` is a set-membership no-op).

  Privileged steps run under a system principal because a customer can
  never create agents themselves — `provision/2` is a setup operation,
  `ensure_joined/1` only does the slice-internal `chat.join` under
  `system://session-internal` (the same principal the chat fan-out
  uses).
  """

  alias Ezagent.{Invocation, KindRegistry, SpawnRegistry, WorkspaceRegistry}
  alias EzagentPluginAutoservice.Uris

  require Logger

  # The routing table the chat fan-out consults
  # (`Ezagent.Routing.Resolver` default). Declared by
  # `EzagentDomainChat` at boot.
  @routing_table EzagentDomainChat.Routing.MentionRouting

  @default_greeting "您好,我是在线客服助手。请问有什么可以帮您?"

  @fast_persona_fallback "你是一位友好、专业的在线客服助手,用简洁清晰的中文回复。先简短安抚用户（12-30字），稍候慢速 agent 会详细回答。遇到转人工请求时，告知人工客服即将介入。"

  @deepseek_api_url "https://api.deepseek.com/chat/completions"
  @deepseek_model "deepseek-chat"

  defp fast_persona do
    try do
      EzagentPluginAutoservice.CinnoxAssets.build_fast_ack_prompt()
    rescue
      _ -> @fast_persona_fallback
    end
  end

  @typedoc "Setup context — `%{caller: URI.t(), caps: [Capability.t()]}`."
  @type setup_ctx :: %{caller: URI.t(), caps: list()}

  @doc """
  Seed-time full assembly for one customer. Idempotent.

  Required opts:
  - `:workspace_uri` — `%URI{scheme: "workspace"}`
  - `:ctx` — `%{caller:, caps:}` privileged setup principal

  Optional opts:
  - `:deepseek_key` — DeepSeek API key for the fast agent (nil ⇒ the
    agent is created but replies with a "configure my key" message)
  - `:with_slow` — also spawn a cc (slow) agent (default `false`;
    requires a working claude environment)
  - `:greeting` — opening line posted by the fast agent
  """
  @spec provision(URI.t(), keyword()) ::
          {:ok, %{session_uri: URI.t(), fast_uri: URI.t(), slow_uri: URI.t() | nil}}
          | {:error, term()}
  def provision(%URI{scheme: "entity", host: "user"} = customer_uri, opts) do
    workspace_uri = Keyword.fetch!(opts, :workspace_uri)
    ctx = Keyword.fetch!(opts, :ctx)
    greeting = Keyword.get(opts, :greeting, @default_greeting)
    system_prompt = Keyword.get(opts, :system_prompt, fast_persona())
    deepseek_key = Keyword.get(opts, :deepseek_key)
    with_slow? = Keyword.get(opts, :with_slow, false)

    session_uri = Uris.session_uri(customer_uri)
    fast_uri = Uris.fast_agent_uri(customer_uri)

    with :ok <- ensure_user_alive(customer_uri),
         {:ok, ^fast_uri} <- ensure_fast_agent(customer_uri, workspace_uri, system_prompt),
         :ok <- maybe_put_deepseek_key(fast_uri, deepseek_key, ctx),
         {:ok, slow_uri} <- maybe_slow_agent(customer_uri, workspace_uri, with_slow?, ctx),
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
  def ensure_joined(%URI{scheme: "entity", host: "user"} = customer_uri) do
    ctx = session_internal_ctx()
    session_uri = Uris.session_uri(customer_uri)
    workspace_uri = Ezagent.URI.entity_workspace_uri(customer_uri)

    with :ok <- ensure_user_alive(customer_uri),
         :ok <- ensure_session(session_uri, customer_uri, workspace_uri),
         :ok <- join(session_uri, customer_uri, ctx) do
      {:ok, session_uri}
    end
  end

  @doc "The customer-service session URI for a customer (no side effects)."
  @spec session_uri(URI.t()) :: URI.t()
  def session_uri(customer_uri), do: Uris.session_uri(customer_uri)

  @doc "Default opening greeting."
  def default_greeting, do: @default_greeting

  # --- internals ------------------------------------------------------

  # Spawning a User Kind via SpawnRegistry is the documented pattern
  # (mirrors `EzagentDomainChat.join_creator/2`). Agents are NOT spawned
  # here — they come up via `Workspace.create_agent/3`, the only
  # allowlisted `SpawnRegistry.spawn(entity://agent/...)` site
  # (`agent_create_single_path_test.exs`).
  defp ensure_user_alive(%URI{scheme: "entity", host: "user"} = uri) do
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

  # Provision the fast agent as a workspace `curl.agent` TEMPLATE (not a
  # direct `create_agent`). This matters for the live reply path: a
  # direct-spawn agent does NOT rehydrate at server boot, so after a
  # restart it would be dormant and silently miss routed customer
  # messages. A workspace template is re-instantiated by
  # `Workspace.Loader.load_all/0` on every boot, so the fast agent is
  # always alive to receive. The template also carries the DeepSeek
  # config + persona (`system_prompt`). `add_template/3` validates +
  # stores + instantiates immediately (idempotent on re-run). The
  # DeepSeek API key is NOT in the template — it lives in the agent's
  # own `:api_keys` slice, set by `maybe_put_deepseek_key/3`.
  defp ensure_fast_agent(customer_uri, %URI{scheme: "workspace"} = workspace_uri, system_prompt) do
    fast_uri = Uris.fast_agent_uri(customer_uri)
    {_ws, name} = Uris.decompose_customer(customer_uri)
    tmpl_name = "autoservice.fast." <> name

    tmpl = %{
      "class" => "curl.agent",
      "agent_uri" => URI.to_string(fast_uri),
      "provider" => "deepseek",
      "api_url" => @deepseek_api_url,
      "model" => @deepseek_model,
      "system_prompt" => system_prompt,
      "max_history" => 20
    }

    case Ezagent.Workspace.add_template(workspace_uri.host, tmpl_name, tmpl) do
      :ok ->
        {:ok, fast_uri}

      {:error, reason} ->
        # Idempotent re-run / tight race — a now-alive agent is success.
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

  defp maybe_slow_agent(_customer_uri, _workspace_uri, false, _ctx), do: {:ok, nil}

  defp maybe_slow_agent(customer_uri, workspace_uri, true, ctx) do
    slow_uri = Uris.slow_agent_uri(customer_uri)

    case KindRegistry.lookup(slow_uri) do
      {:ok, _pid} ->
        {:ok, slow_uri}

      :error ->
        # Materialize shared CINNOX assets once (CLAUDE.md, skills,
        # flow chunks, KB files). Each agent gets its own subdir so
        # .mcp.json (esr-bridge token per agent) doesn't conflict.
        name = Uris.slow_agent_create_name(customer_uri)
        base = EzagentPluginAutoservice.CinnoxRuntime.materialize_cinnox_cc!()
        work_dir = Path.join(base, name)
        File.mkdir_p!(work_dir)

        # Symlink shared assets into per-agent dir (avoids copy bloat).
        for entry <- File.ls!(base) |> Enum.reject(&(&1 in [".mcp.json", name])) do
          src = Path.join(base, entry)
          dst = Path.join(work_dir, entry)
          unless File.exists?(dst), do: File.ln_s(src, dst)
        end

        case Ezagent.Workspace.create_agent(
               workspace_uri,
               %{flavor: "cc", name: name, cwd: work_dir, with_pty: false},
               ctx
             ) do
          {:ok, %{agent_uri: %URI{} = uri}} ->
            # Merge cinnox-kb MCP config into the agent's .mcp.json
            # (create_agent already wrote esr-bridge; add KB sidecar).
            mcp_path = Path.join(work_dir, ".mcp.json")
            mcp =
              mcp_path |> File.read!() |> Jason.decode!()
              |> Map.update!("mcpServers", &Map.merge(EzagentPluginAutoservice.CinnoxRuntime.kb_mcp_servers(), &1))
            File.write!(mcp_path, Jason.encode_to_iodata!(mcp, pretty: true))
            {:ok, uri}

          {:error, reason} ->
            case KindRegistry.lookup(slow_uri) do
              {:ok, _pid} -> {:ok, slow_uri}
              :error -> {:error, {:slow_agent_create_failed, reason}}
            end
        end
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
                 owner_uri: owner_uri
               }) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, {:already_registered, _}} -> :ok
            {:error, reason} -> {:error, {:session_spawn_failed, reason}}
          end
      end

    with :ok <- spawn_result do
      # WorkspaceRegistry.bind/2 always returns :ok (idempotent ETS put).
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

  # customer message in THIS session → fast (+ slow) agent. The fast
  # agent's own reply (sender = fast) does not match `{:from, customer}`,
  # so there is no loop. Workspace-scoped so it only fires for cinnox.
  defp install_routing(session_uri, customer_uri, fast_uri, slow_uri, workspace_uri) do
    fast_str = URI.to_string(fast_uri)
    existing = Ezagent.Routing.RuleStore.list(@routing_table)

    # Idempotent: each customer's fast-agent URI is unique, so an
    # existing rule already routing to it means this customer is wired.
    if Enum.any?(existing, fn r -> fast_str in (r.receivers || []) end) do
      _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
      :ok
    else
      receivers = [fast_uri | slow_receivers(slow_uri)]

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
    # Idempotent: only greet a fresh session. Re-provisioning (re-seed /
    # restart) must not pile up duplicate greetings.
    case Ezagent.MessageStore.recent_in_session(session_uri, 1) do
      [] -> do_post_greeting(session_uri, fast_uri, greeting, ctx)
      [_ | _] -> :ok
    end
  end

  defp do_post_greeting(%URI{} = session_uri, %URI{} = fast_uri, greeting, ctx) do
    msg = Ezagent.Message.new(fast_uri, %{text: greeting, attachments: []})
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

    # `:call` (overriding chat.send's `:cast` default per P18) so the
    # greeting is durably persisted BEFORE provision returns — the seed
    # runs in a short-lived BEAM that would otherwise exit before an
    # async cast reached MessageStore.write.
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
