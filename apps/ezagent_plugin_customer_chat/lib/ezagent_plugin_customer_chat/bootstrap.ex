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
    - `dispatch_chat_send/2`

  All tenant data is parameterized — no hardcoded tenant name
  (migration constraint #1).
  """

  require Logger

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
  Build the inbound customer message. We synthesize a server-side
  `mentions: [cc_agent_uri]` because ezagent's default routing rule is
  `[session_users, mentions]` — an agent only receives messages it is
  @-mentioned in, and a customer's natural-language text carries no
  @-syntax. The synthesized mention is what makes the resolver fan
  `chat.receive` out to the cc agent.
  """
  @spec customer_message(URI.t(), String.t(), URI.t()) :: Ezagent.Message.t()
  def customer_message(customer_uri, text, cc_agent_uri) do
    Ezagent.Message.new(customer_uri, %{text: text, attachments: []}, mentions: [cc_agent_uri])
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

    # DEFERRED ARCHITECTURE DECISION (2026-05-30) — accepted for the PoC; do
    # NOT change core now. `create_session/3` UNCONDITIONALLY spawns a
    # per-session cc-orchestrator (Phase-7 "session-create-orchestrator-unified"
    # SPEC — no opt-out). Customer-chat does NOT use it: the customer message is
    # mention-routed straight to the cc_cust agent (see `customer_message/3` +
    # `dispatch_chat_send/2`); the orchestrator sits idle — an extra claude PTY
    # + system prompt per conversation. We accept this for now because whether
    # CS actually needs an orchestrator only becomes clear once the remaining
    # AutoService features are migrated. NOTE: even AutoService's fast/slow
    # agent pattern is just fan-out to 2 session members, NOT the LLM
    # orchestrator. REVISIT after migration — if CS stays orchestrator-less,
    # ask Allen for a `create_session(orchestrator: false)` opt-out. Tracked in
    # HANDOFF-2026-05-30.md "Deferred decisions".
    case EzagentDomainChat.create_session(conv_id, admin_uri,
           workspace_uri: URI.new!("workspace://#{workspace}"),
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
