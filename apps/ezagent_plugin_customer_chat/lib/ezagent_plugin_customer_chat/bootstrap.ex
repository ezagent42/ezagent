defmodule EzagentPluginCustomerChat.Bootstrap do
  @moduledoc """
  Shared customer-chat bootstrap, extracted from
  `EzagentWeb.CustomerChatController` so the SSE controller and the
  customer LiveView use ONE code path (DRY).

  Responsibilities:
    - URI / message builders (pure)
    - `validate_workspace/1`
    - `ensure_session/2`
    - `ensure_cc_for_conv/3` (cc agent + EagerBridge + join)
    - `install_customer_routing/3` (explicit customer→cc routing rule)
    - `dispatch_chat_send/2`

  Customer→cc routing is via an explicit `Ezagent.Routing.RuleStore`
  rule (`install_customer_routing/3`), mirroring B's
  `EzagentPluginAutoservice.CustomerSession`. This replaces the former
  mention-synthesis hack where `customer_message/3` stamped every
  inbound message with `mentions: [cc_agent_uri]`.

  All tenant data is parameterized — no hardcoded tenant name
  (migration constraint #1).
  """

  require Logger

  # The routing table the chat fan-out consults (`Ezagent.Routing.Resolver`
  # default). Declared by `EzagentDomainChat` at boot. Same table B's
  # `EzagentPluginAutoservice.CustomerSession` writes its customer→agent
  # rule into.
  @routing_table EzagentDomainChat.Routing.MentionRouting

  # ---- pure builders ----------------------------------------------------

  @spec session_uri_for(String.t(), String.t()) :: URI.t()
  def session_uri_for(workspace, conv_id),
    do: URI.new!("session://default/#{workspace}/#{conv_id}")

  @spec customer_uri_for(String.t(), String.t()) :: URI.t()
  def customer_uri_for(workspace, customer_id),
    do: URI.new!("entity://user/#{workspace}/customer_#{customer_id}")

  @spec agent_name_for(String.t()) :: String.t()
  def agent_name_for(conv_id), do: "cust_" <> sanitize_for_uri(conv_id)

  @spec generate_conv_id() :: String.t()
  def generate_conv_id,
    do: Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)

  @doc """
  Build the inbound customer message — a plain `chat.send` body, no
  synthesized mentions.

  Routing the customer's text to the cc agent is now handled by an
  explicit `Ezagent.Routing.RuleStore` rule installed in
  `install_customer_routing/3` (mirroring B's
  `EzagentPluginAutoservice.CustomerSession.install_routing`), not by a
  server-side `mentions: [cc_agent_uri]` hack. The rule's `{:from,
  customer}` clause is what fans `chat.receive` out to the cc agent;
  the message itself carries no @-syntax.

  The third arg (`_cc_agent_uri`) is retained but UNUSED so the SSE
  controller call site (`EzagentWeb.CustomerChatController`, out of this
  plugin's edit scope) keeps compiling. Callers that want the cc agent
  to actually receive the message must first install the routing rule
  via `install_customer_routing/3` (the customer LiveView does this at
  bootstrap).
  """
  @spec customer_message(URI.t(), String.t(), URI.t()) :: Ezagent.Message.t()
  def customer_message(customer_uri, text, _cc_agent_uri) do
    Ezagent.Message.new(customer_uri, %{text: text, attachments: []})
  end

  # ---- customer→cc routing rule ----------------------------------------

  @doc """
  Install the explicit customer→cc routing rule for this conversation.
  Idempotent (reconciler style — re-running converges, never duplicates).

  This REPLACES the old mention-synthesis: instead of stamping every
  inbound customer message with `mentions: [cc_agent_uri]`, we register
  one declarative `RuleStore` rule that fans any non-agent message in the
  session out to the cc agent. The matcher is `{:and, [{:in_session, S},
  {:not, {:from, agent}}]}` — customer-AGNOSTIC (the customer id is
  ephemeral per page-load, so a `{:from, customer}` rule would only match
  the page that installed it), and the `{:not, {:from, agent}}` clause
  excludes the cc agent's OWN replies so there is no loop. One rule per
  (session, agent) covers every customer id.

  Mirrors B's `EzagentPluginAutoservice.CustomerSession.install_routing`:
  same `RuleStore` API, the same `{:and, [{:in_session, _}, {:from, _}]}`
  matcher, the same list-based idempotency, and the same
  `load_into_registry/1` after a successful add.
  """
  @spec install_customer_routing(URI.t(), URI.t(), URI.t()) :: :ok
  def install_customer_routing(%URI{} = session_uri, %URI{} = customer_uri, %URI{} = agent_uri) do
    agent_str = URI.to_string(agent_uri)
    existing = Ezagent.Routing.RuleStore.list(@routing_table)

    # Idempotent: each conversation's cc agent URI is unique, so an
    # existing rule already routing to it means this conversation is wired.
    if Enum.any?(existing, fn r -> agent_str in (r.receivers || []) end) do
      _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
      :ok
    else
      # Workspace derived structurally from the customer URI
      # (`entity://user/<workspace>/customer_<id>` → `workspace://<ws>`),
      # the same way B's seed passes its `workspace_uri` through.
      workspace_uri = Ezagent.URI.entity_workspace_uri(customer_uri)

      # Customer-AGNOSTIC on purpose. The customer id is EPHEMERAL — a fresh
      # `customer_<rand>` per page-load / prewarm (ChatLive `rand_customer_id`).
      # A `{:from, customer}` rule would only match the one page that installed
      # it, so the recorder's prewarm-then-record (two different customer ids on
      # the same conv) — and any reload — got NO delivery → no reply. Instead
      # route ANY non-agent message in this session to the cc agent; the agent's
      # OWN replies (sender = agent) are excluded by `{:not, {:from, agent}}`, so
      # there is no loop. One rule per (session, agent) covers every customer id.
      matcher =
        {:and,
         [
           {:in_session, URI.to_string(session_uri)},
           {:not, {:from, agent_str}}
         ]}

      case Ezagent.Routing.RuleStore.add(
             @routing_table,
             matcher,
             [agent_str],
             nil,
             workspace_uri: workspace_uri
           ) do
        {:ok, _rule} ->
          _ = Ezagent.Routing.RuleStore.load_into_registry(@routing_table)
          :ok

        {:error, reason} ->
          Logger.warning(
            "customer_chat install_customer_routing(#{URI.to_string(session_uri)}) " <>
              "failed: #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  defp sanitize_for_uri(conv_id) when is_binary(conv_id) do
    conv_id |> String.replace(~r/[^A-Za-z0-9]/, "_") |> String.slice(0, 32)
  end

  # ---- workspace validation --------------------------------------------

  @spec validate_workspace(String.t() | nil) :: :ok | {:error, String.t()}
  def validate_workspace(nil), do: {:error, "workspace path segment required"}
  def validate_workspace(""), do: {:error, "workspace path segment required"}

  def validate_workspace(name) when is_binary(name) do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil -> {:error, "workspace not found"}
      _ws -> :ok
    end
  end

  # ---- session ----------------------------------------------------------

  @spec ensure_session(String.t(), String.t()) :: :ok
  def ensure_session(workspace, conv_id) do
    admin_uri = Ezagent.Entity.User.admin_uri()
    ws_uri = URI.new!("workspace://#{workspace}")

    # Customer-service sessions are orchestrator-LESS: the customer message is
    # mention-routed straight to the cc_cust agent (see `customer_message/3` +
    # `dispatch_chat_send/2`), so no LLM orchestrator is needed. The system
    # "default" SessionTemplate (boot-seeded only under workspace://system)
    # carries an orchestrator whose isolated CLAUDE_CONFIG_DIR hits the claude
    # 2.1.92 OAuth screen → it never becomes ready → create_session fails with
    # {:orchestrator_not_ready_within, _} and the session is never spawned
    # (chat.send then fails :no_such_actor). So we ensure a PLAIN
    # (orchestrator_template_uri: nil) "default" template for THIS workspace;
    # `session_complete?` already treats a nil-orchestrator template as a
    # complete plain session (bound + owner-member). This is the
    # orchestrator-less path the "ask Allen for create_session(orchestrator:
    # false)" note wanted — achieved at the template level, no core change.
    :ok = ensure_plain_session_template(ws_uri)

    case EzagentDomainChat.create_session(conv_id, admin_uri,
           workspace_uri: ws_uri,
           template_name: "default"
         ) do
      {:ok, _session_uri, _meta} ->
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "customer_chat ensure_session(#{workspace}, #{conv_id}) failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Idempotently persist a PLAIN (orchestrator-less) "default" SessionTemplate
  # for the workspace. SessionTemplates are content-addressed, so re-persisting
  # identical content yields the same URI — cheap + churn-free. On a clean
  # workspace this is the only "default", so create_session resolves it.
  defp ensure_plain_session_template(%URI{} = workspace_uri) do
    content = %{
      name: "default",
      description:
        "Customer-service default session template (orchestrator-less; the " <>
          "cc_cust agent answers via mention routing).",
      agent_slots: [],
      orchestrator_template_uri: nil,
      routing_rules: [],
      default_workspace_uri: workspace_uri,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: nil,
      created_at: nil
    }

    case Ezagent.Entity.SessionTemplate.persist_version_as_system(content, workspace_uri) do
      {:ok, _uri} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "customer_chat ensure_plain_session_template(#{URI.to_string(workspace_uri)}) " <>
            "failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  # ---- cc agent lifecycle ----------------------------------------------

  # NOTE on caps: the customer is anonymous, so all bootstrap actions
  # (agent create, join, dispatch) run as the admin principal with
  # `system://bootstrap` caps. Phase 2.x does NOT attempt to model
  # "what caps does a third-party-IM-relayed end user hold" — that is a
  # separate, still-open design question (phase-1-2-verdict.md §6).
  @spec ensure_cc_for_conv(String.t(), String.t(), URI.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def ensure_cc_for_conv(workspace, conv_id, session_uri) do
    agent_name = agent_name_for(conv_id)
    # Per-CONVERSATION cwd, not per-workspace. Every cc agent gets its
    # own sandbox dir so its `.mcp.json` (bridge token), per-agent
    # `.esr-system-prompt.md`, and any files claude writes are isolated.
    # A shared per-workspace cwd made all concurrent conversations write
    # the SAME `<cwd>/.mcp.json` — the last spawn's `EZAGENT_AGENT_TOKEN`
    # clobbered the others, so only one agent ever bound to the bridge
    # (every other conv's reply silently dropped as `:no_bridge`). This
    # also restores cc_agent.ex's per-agent-cwd isolation assumption that
    # the per-workspace cwd quietly violated.
    cwd = cc_cwd_for_conv(workspace, agent_name)
    # The cc flavor REQUIRES its cwd to already exist (workspace
    # create_agent validates `File.dir?/1` and rejects with
    # `{:cwd_not_a_dir, _}` otherwise). A per-conversation cwd is fresh
    # every time, so create it up front. mkdir_p is idempotent — a
    # resumed conversation reuses the same dir.
    File.mkdir_p!(cwd)
    soul_path = cc_soul_path_for_workspace(workspace, "customer")
    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
    ctx = %{caller: admin_uri, caps: admin_caps, reply: {:caller_inbox, self()}}

    with {:ok, agent_uri} <- ensure_cc_agent(workspace, agent_name, cwd, soul_path, ctx),
         :ok <- EzagentPluginCc.EagerBridge.ensure_bound!(agent_uri),
         :ok <- ensure_agent_in_session(session_uri, agent_uri, ctx) do
      {:ok, agent_uri}
    end
  end

  defp ensure_cc_agent(workspace, agent_name, cwd, soul_path, ctx) do
    ws_uri = URI.new!("workspace://#{workspace}")
    args = %{flavor: "cc", name: agent_name, cwd: cwd, with_pty: true}
    args = if soul_path, do: Map.put(args, :soul_path, soul_path), else: args

    result =
      case Ezagent.Workspace.create_agent(ws_uri, args, ctx) do
        {:ok, %{agent_uri: u}} ->
          {:ok, u}

        {:error, {:already_exists, u_str}} when is_binary(u_str) ->
          {:ok, URI.new!(u_str)}

        {:error, {:already_exists, %URI{} = u}} ->
          {:ok, u}

        {:error, reason} ->
          Logger.warning(
            "customer_chat ensure_cc_agent(#{workspace}, #{agent_name}) failed: #{inspect(reason)}"
          )

          {:error, reason}
      end

    # Per-conversation cc agents are EPHEMERAL: customer-chat re-creates
    # them on demand every time a conversation opens (static-soul model).
    # `create_agent` unconditionally registers a `cc.agent.<name>` spawn
    # template in `workspaces.session_templates`, which the boot loader
    # replays — so every conversation ever opened respawns its claude PTY
    # at boot ("boot storm" that saturates spawn capacity and blocks new
    # conversations). Deregister the template right after create:
    # `remove_template` only drops the boot-restore registration, it does
    # NOT terminate the running Kind, so the agent keeps serving this
    # conversation. Best-effort — a deregister failure only degrades to
    # the old (accumulating) behavior, never to a reply failure. See
    # docs/superpowers/specs/2026-05-30-ephemeral-cc-agents-design.md.
    case result do
      {:ok, agent_uri} ->
        deregister_ephemeral(workspace, agent_uri)
        {:ok, agent_uri}

      err ->
        err
    end
  end

  # Build the `session_templates` key `create_agent` registered for this
  # cc agent: `"cc.agent." <> <entity-name>`. The entity name is the LAST
  # path segment of the agent URI and INCLUDES the `cc_` flavor prefix
  # (e.g. `entity://agent/cinnox/cc_cust_abc` → `cc.agent.cc_cust_abc`),
  # so it must be derived from the returned `agent_uri`, not rebuilt from
  # the bare `agent_name` (`cust_abc`). Mirrors `agent_name/1` in
  # Ezagent.Behavior.Workspace.
  @doc false
  def ephemeral_template_name(%URI{path: "/" <> rest}) do
    entity =
      case String.split(rest, "/", parts: 2) do
        [_workspace, entity_name] -> entity_name
        [entity_name] -> entity_name
      end

    "cc.agent." <> entity
  end

  defp deregister_ephemeral(workspace, agent_uri) do
    tmpl_name = ephemeral_template_name(agent_uri)

    case Ezagent.Workspace.remove_template(workspace, tmpl_name) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "customer_chat deregister ephemeral template #{tmpl_name} failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp ensure_agent_in_session(session_uri, agent_uri, ctx) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=chat.join")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{member: agent_uri},
      ctx: %{ctx | reply: :ignore}
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("customer_chat join failed: #{inspect(reason)}")
        :ok
    end
  end

  defp cc_cwd_for_workspace(workspace) do
    root =
      Application.get_env(
        :ezagent_plugin_customer_chat,
        :customer_chat_sandbox_root,
        "~/poc-sandbox-phase2"
      )

    Path.join(Path.expand(root), workspace)
  end

  # Per-conversation sandbox cwd: `<sandbox_root>/<workspace>/<agent_name>`.
  # `agent_name` is already URI-sanitized (`cust_<conv>`), so it is a safe
  # single path segment. Isolating per agent is what keeps each agent's
  # `.mcp.json` bridge token from clobbering the others (see
  # ensure_cc_for_conv/3).
  defp cc_cwd_for_conv(workspace, agent_name) do
    Path.join(cc_cwd_for_workspace(workspace), agent_name)
  end

  defp cc_soul_path_for_workspace(workspace, role) do
    EzagentPluginCustomerChat.SoulStore.effective_path(workspace, role)
  end

  # ---- dispatch ---------------------------------------------------------

  @spec dispatch_chat_send(URI.t(), Ezagent.Message.t()) :: :ok
  def dispatch_chat_send(session_uri, msg) do
    target = URI.new!(URI.to_string(session_uri) <> "?action=chat.send")
    admin_uri = Ezagent.Entity.User.admin_uri()
    admin_caps = Ezagent.SystemPrincipal.caps("system://bootstrap")

    inv = %Ezagent.Invocation{
      target: target,
      mode: :cast,
      args: %{message: msg},
      ctx: %{caller: admin_uri, caps: admin_caps, reply: :ignore}
    }

    case Ezagent.Invocation.dispatch(inv) do
      :ok -> :ok
      other -> Logger.warning("customer_chat dispatch chat.send failed: #{inspect(other)}")
    end

    :ok
  end
end
