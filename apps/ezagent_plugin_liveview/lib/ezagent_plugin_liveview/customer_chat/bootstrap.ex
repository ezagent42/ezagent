defmodule EzagentPluginLiveview.CustomerChat.Bootstrap do
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
    do: URI.parse("session://default/#{workspace}/#{conv_id}")

  @spec customer_uri_for(String.t(), String.t()) :: URI.t()
  def customer_uri_for(workspace, customer_id),
    do: URI.parse("entity://user/#{workspace}/customer_#{customer_id}")

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
    Ezagent.Message.new(customer_uri, %{text: text, attachments: []},
      mentions: [cc_agent_uri]
    )
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

    case EzagentDomainChat.create_session(conv_id, admin_uri,
           workspace_uri: URI.parse("workspace://#{workspace}"),
           template_name: "default"
         ) do
      {:ok, _session_uri, _meta} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} ->
        Logger.warning("customer_chat ensure_session(#{workspace}, #{conv_id}) failed: #{inspect(reason)}")
        :ok
    end
  end

  # ---- cc agent lifecycle ----------------------------------------------

  @spec ensure_cc_for_conv(String.t(), String.t(), URI.t()) ::
          {:ok, URI.t()} | {:error, term()}
  def ensure_cc_for_conv(workspace, conv_id, session_uri) do
    cwd = cc_cwd_for_workspace(workspace)
    soul_path = cc_soul_path_for_workspace(workspace, "customer")
    agent_name = agent_name_for(conv_id)
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
    ws_uri = URI.parse("workspace://#{workspace}")
    args = %{flavor: "cc", name: agent_name, cwd: cwd, with_pty: true}
    args = if soul_path, do: Map.put(args, :soul_path, soul_path), else: args

    case Ezagent.Workspace.create_agent(ws_uri, args, ctx) do
      {:ok, %{agent_uri: u}} -> {:ok, u}
      {:error, {:already_exists, u_str}} when is_binary(u_str) -> {:ok, URI.parse(u_str)}
      {:error, {:already_exists, %URI{} = u}} -> {:ok, u}
      {:error, reason} ->
        Logger.warning("customer_chat ensure_cc_agent(#{workspace}, #{agent_name}) failed: #{inspect(reason)}")
        {:error, reason}
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
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("customer_chat join failed: #{inspect(reason)}")
        :ok
    end
  end

  defp cc_cwd_for_workspace(workspace) do
    root = Application.get_env(:ezagent_plugin_liveview, :customer_chat_sandbox_root, "~/poc-sandbox-phase2")
    Path.join(Path.expand(root), workspace)
  end

  defp cc_soul_path_for_workspace(workspace, role) do
    # PoC default: <repo>/poc/fixtures/plugins ; this module sits at
    # apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/customer_chat/bootstrap.ex
    # → six `..` hops reach the repo root.
    root_default = Path.expand("../../../../../../poc/fixtures/plugins", __ENV__.file)
    root = Application.get_env(:ezagent_plugin_liveview, :customer_chat_soul_root, root_default)
    path = Path.join([root, workspace, "souls", "#{role}.md"])
    if File.exists?(path), do: path, else: nil
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
