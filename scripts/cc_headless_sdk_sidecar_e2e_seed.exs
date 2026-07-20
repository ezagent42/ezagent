require Logger

alias Ezagent.{Invocation, Message}
alias Ezagent.URI, as: EzUri
alias Ezagent.Entity.User

workspace_uri = EzUri.workspace(:system)
uniq = System.get_env("CC_HEADLESS_E2E_ID") || Integer.to_string(System.system_time(:millisecond))
session_uri = EzUri.new!("session://system/default/cc-headless-sdk-sidecar-#{uniq}")
agent_uri = EzUri.new!("entity://system/agent/cc_headless_sdk_sidecar_#{uniq}")
admin_uri = User.admin_uri()
admin_email = System.get_env("WORLD_E2E_ADMIN_EMAIL") || "admin@ezagent.chat"
admin_pw = System.get_env("WORLD_E2E_ADMIN_PW") || "worlddev"
cwd = File.cwd!()
real_sdk? = System.get_env("CC_HEADLESS_E2E_REAL_SDK") in ["1", "true", "TRUE", "yes"]

config_dir =
  System.get_env("CC_HEADLESS_E2E_CONFIG_DIR") ||
    if real_sdk? do
      Path.join(System.tmp_dir!(), "ezagent-cc-headless-sdk-sidecar-config-#{uniq}")
    else
      Path.join(System.tmp_dir!(), "ezagent-cc-headless-sdk-sidecar-config-#{uniq}")
    end

uv_path = System.find_executable("uv")
python_path = System.find_executable("python3") || System.find_executable("python")

worker_path =
  unless real_sdk? do
    Path.expand("apps/ezagent_plugin_cc/test/fixtures/fake_cc_sdk_worker.py", cwd)
  end

expected_reply =
  if real_sdk? do
    "CC_HEADLESS_REAL_SDK_E2E_OK #{uniq}"
  else
    "fake sdk reply: cc-headless SDK sidecar E2E #{uniq}: please answer from the sidecar"
  end

inbound_text =
  if real_sdk? do
    """
    这是 cc-headless SDK sidecar 的真实 E2E 验证。

    请用中文给出一个简洁但信息量充足的回答，包含：
    1. 第一行必须原样包含这个验证标记：#{expected_reply}
    2. 一句话说明你是通过 Claude Code Python SDK sidecar 返回的。
    3. 三个要点，概括这条链路已经验证了哪些能力。

    不要只回显标记。
    """
  else
    "cc-headless SDK sidecar E2E #{uniq}: please answer from the sidecar"
  end

unless is_binary(python_path) do
  raise "python3/python executable not found"
end

if real_sdk? and not is_binary(uv_path) do
  Logger.warning(
    "uv executable not found; real SDK E2E will use python and requires claude-agent-sdk"
  )
end

File.mkdir_p!(config_dir)

ensure_ok = fn
  :ok -> :ok
  {:ok, _} -> :ok
  other -> raise "expected :ok, got #{inspect(other)}"
end

case Ezagent.SpawnRegistry.spawn(session_uri) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
  other -> raise "spawn session failed: #{inspect(other)}"
end

ensure_ok.(Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri))

case Ezagent.Users.set_password(admin_uri, admin_pw) do
  {:ok, _} ->
    :ok

  {:error, :not_found} ->
    case Ezagent.Users.create(admin_uri, admin_pw, []) do
      {:ok, _} -> :ok
      other -> raise "admin create failed: #{inspect(other)}"
    end

  other ->
    raise "admin set_password failed: #{inspect(other)}"
end

case Ezagent.Entity.Profile.upsert(%{
       entity_uri: URI.to_string(admin_uri),
       display_name: "Admin",
       email: admin_email
     }) do
  {:ok, _} -> :ok
  other -> raise "admin profile upsert failed: #{inspect(other)}"
end

case Ezagent.Users.mark_email_verified(admin_uri) do
  {:ok, _} -> :ok
  other -> raise "admin email verify failed: #{inspect(other)}"
end

case Ezagent.KindRegistry.lookup(admin_uri) do
  {:ok, _pid} -> :ok
  :error -> ensure_ok.(Ezagent.Entity.spawn_principal(admin_uri))
end

:ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "cc-headless")

case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
       uri: agent_uri,
       behaviors: Ezagent.Entity.Agent.cc_headless_behaviors(),
       claude_session_id: "cc-headless-sdk-sidecar-e2e-#{uniq}"
     }) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
  other -> raise "spawn cc-headless agent failed: #{inspect(other)}"
end

sidecar_params =
  %{
    cwd: cwd,
    config_dir: config_dir,
    session_id: "cc-headless-sdk-sidecar-e2e-#{uniq}",
    python_path: python_path,
    model: System.get_env("ANTHROPIC_MODEL"),
    effort: System.get_env("CLAUDE_EFFORT"),
    cli_path: System.find_executable("claude"),
    permission_mode: System.get_env("CC_HEADLESS_E2E_PERMISSION_MODE") || "bypassPermissions"
  }
  |> then(fn params ->
    cond do
      real_sdk? and is_binary(uv_path) -> Map.put(params, :uv_path, uv_path)
      real_sdk? -> params
      true -> Map.put(params, :sdk_worker_path, worker_path)
    end
  end)

case EzagentPluginCc.SdkSidecar.start(agent_uri, sidecar_params) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
  other -> raise "start SDK sidecar failed: #{inspect(other)}"
end

chat_join = fn member_uri ->
  target = EzUri.with_action(session_uri, :session, :join)
  {:ok, join_cap} = Ezagent.Cap.issue_for_action({:admin, admin_uri}, member_uri, target)

  ensure_ok.(
    Invocation.dispatch(%Invocation{
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{caller: member_uri, caps: MapSet.new([join_cap]), reply: :ignore},
      origin: :trusted_internal
    })
  )

  Ezagent.ActionSet.Session.Membership.mount_participation_caps(session_uri, member_uri)
end

chat_join.(admin_uri)
chat_join.(agent_uri)

session_topic = "esr:session:#{URI.to_string(session_uri)}:events"
:ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

send_target = EzUri.with_action(session_uri, :session, :send)
{:ok, send_cap} = Ezagent.Cap.issue_for_action({:admin, admin_uri}, admin_uri, send_target)

inbound_msg =
  Message.new(admin_uri, %{text: inbound_text, attachments: []}, mentions: [agent_uri])

ensure_ok.(
  Invocation.dispatch(%Invocation{
    target: send_target,
    mode: :cast,
    args: %{message: inbound_msg},
    ctx: %{caller: admin_uri, caps: MapSet.new([send_cap]), reply: :ignore},
    origin: :trusted_internal
  })
)

wait_for_reply = fn wait_for_reply, deadline_ms ->
  cond do
    System.monotonic_time(:millisecond) > deadline_ms ->
      raise "timed out waiting for cc-headless SDK sidecar reply #{inspect(expected_reply)}"

    true ->
      receive do
        {:chat_message, _session, %Message{sender: sender, body: body}} ->
          sender_str =
            if match?(%URI{}, sender), do: URI.to_string(sender), else: to_string(sender)

          text = Map.get(body, :text) || Map.get(body, "text") || ""

          if sender_str == URI.to_string(agent_uri) and String.contains?(text, expected_reply) do
            :ok
          else
            wait_for_reply.(wait_for_reply, deadline_ms)
          end
      after
        250 ->
          messages = Ezagent.MessageStore.recent_in_session(session_uri, 20)

          found? =
            Enum.any?(messages, fn %Message{sender: sender, body: body} ->
              sender_str =
                if match?(%URI{}, sender), do: URI.to_string(sender), else: to_string(sender)

              text = Map.get(body, :text) || Map.get(body, "text") || ""
              sender_str == URI.to_string(agent_uri) and String.contains?(text, expected_reply)
            end)

          if found?, do: :ok, else: wait_for_reply.(wait_for_reply, deadline_ms)
      end
  end
end

wait_for_reply.(wait_for_reply, System.monotonic_time(:millisecond) + 30_000)

encoded_session = session_uri |> URI.to_string() |> URI.encode_www_form()

IO.puts("CC_HEADLESS_E2E_SESSION=#{URI.to_string(session_uri)}")
IO.puts("CC_HEADLESS_E2E_AGENT=#{URI.to_string(agent_uri)}")
IO.puts("CC_HEADLESS_E2E_DEEPLINK=/sessions?session=#{encoded_session}")
IO.puts("CC_HEADLESS_E2E_ADMIN_EMAIL=#{admin_email}")
IO.puts("CC_HEADLESS_E2E_ADMIN_PW=#{admin_pw}")
IO.puts("CC_HEADLESS_E2E_EXPECTED_REPLY=#{expected_reply}")
IO.puts("CC_HEADLESS_E2E_REAL_SDK=#{real_sdk?}")
