defmodule Ezagent.PluginCc.Integration.CcAgentSandboxCredentialsTest do
  @moduledoc """
  Sandbox + credential-copy e2e — proves the "copy host
  `~/.claude/.credentials.json` into a sandbox CLAUDE_CONFIG_DIR" flow
  Allen explicitly signed off on (Feishu 2026-05-23):

  > 使用 sandbox 模式是否可以加载保存在本地的 credentials
  > (从 ~/.claude/ 中复制过去), 避免要求用户反复登录.

  This is a V1 production-usability requirement: an operator should be
  able to seed a sandbox once (e.g. via `mix ezagent.demo.seed_cc_sandbox`)
  and have every subsequent cc agent in that sandbox authenticate
  WITHOUT re-running `claude login`.

  ## Complements the PR #255 wiring e2e — does NOT replace it

  `cc_agent_admin_reply_e2e_test.exs` proves the full admin → cc agent
  → reply round-trip through the WS Channel + MCP bridge with a fake
  claude. This test reuses the same harness (TestEndpoint, fake_claude
  on PATH, real `Ezagent.Domain.Pty.start/2` via `:exec.run/2`) but
  narrows the assertion surface to the SANDBOX MECHANICS:

  1. A `.credentials.json` written into `<sandbox>/.credentials.json`
     BEFORE the cc agent spawns is visible to the spawned claude via
     `CLAUDE_CONFIG_DIR=<sandbox>` env threading.
  2. The cc agent's spawned process env carries
     `CLAUDE_CONFIG_DIR=<sandbox>` end-to-end (proves the AgentTemplate
     universal `config_dir` → `build_claude_cmd/3` cmd_env →
     `:exec.run/2` env → `execve(2)` env chain holds).
  3. The seeded credentials contents round-trip back to the test via
     the reply path: the fake claude tags the reply with `[creds:<contents>]`
     so the test reads the file contents OUT OF the reply broadcast,
     proving end-to-end that the spawned process actually read the
     file (not just that the env var was set).

  ## Why this matters (the "avoid re-login" claim)

  The real `claude` binary, when run with `CLAUDE_CONFIG_DIR=<sandbox>`,
  looks in `<sandbox>/.credentials.json` for an authenticated token. If
  the file is there with valid OAuth contents, claude does NOT prompt
  for a login. The cc agent is launched non-interactively under a PTY
  — a login prompt would hang the process forever. Pre-seeding the
  sandbox's credentials file is the operator-side fix.

  This test proves the FILE-LAYOUT + ENV-THREADING side of the
  contract: a credentials file at the documented path inside the
  sandbox is found by a process spawned through the cc agent stack.
  The CONTENTS-VALID side (real OAuth tokens) is the operator's
  responsibility — copying their authenticated host file.

  ## Tooling preconditions

  Same as PR #255: `uv` and `python3` on PATH for the bridge + fake.
  The test SKIPS when either is missing (real ExUnit `:skip`).

  ## macOS Keychain caveat

  On macOS, `claude login` stores credentials in Keychain (per-user)
  rather than `~/.claude/.credentials.json`. In that case the copy
  step finds nothing useful to copy. See `docs/runbook/cc-agent-e2e.md`
  for the API-key-helper workaround. This test is platform-agnostic
  because it writes its OWN fake credentials file — it does NOT touch
  the operator's real `~/.claude/`.
  """

  defmodule TestEndpoint do
    use Phoenix.Endpoint, otp_app: :ezagent_plugin_cc

    socket("/agent_bridge", Ezagent.AgentBridge.Socket,
      websocket: [check_origin: false],
      longpoll: false
    )
  end

  use EzagentCore.DataCase, async: false

  require Logger

  alias Ezagent.{Invocation, KindRegistry, Message}
  alias Ezagent.Entity.User
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry

  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")

  @uv_path System.find_executable("uv")
  @python_path System.find_executable("python3")

  @missing_tooling (cond do
                      is_nil(@uv_path) ->
                        "uv not on PATH — cannot run the cc MCP bridge subprocess"

                      is_nil(@python_path) ->
                        "python3 not on PATH — cannot run fake_claude.py"

                      true ->
                        false
                    end)

  @fake_claude_path Path.expand("../fixtures/fake_claude.py", __DIR__)

  # --- helpers -----------------------------------------------------------

  defp uniq, do: System.unique_integer([:positive])

  defp free_tcp_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  # Same install pattern as PR #255: a tmp `bin/claude` shell-shim that
  # execs python3 fake_claude.py, prepended to PATH so
  # `CcAgent.resolve_claude_executable/1` resolves to it.
  defp install_fake_claude_on_path! do
    bin_dir = Path.join(System.tmp_dir!(), "cc_sbx_bin_#{uniq()}")
    File.mkdir_p!(bin_dir)
    claude_path = Path.join(bin_dir, "claude")

    File.write!(claude_path, """
    #!/usr/bin/env bash
    exec #{@python_path} #{@fake_claude_path} "$@"
    """)

    File.chmod!(claude_path, 0o755)

    original_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    {bin_dir, original_path}
  end

  defp restore_path!(original_path) do
    if original_path do
      System.put_env("PATH", original_path)
    else
      System.delete_env("PATH")
    end
  end

  defp wait_until(fun, timeout_ms, step_ms \\ 50) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline, step_ms)
  end

  defp do_wait_until(fun, deadline, step_ms) do
    case fun.() do
      val when val not in [nil, false] ->
        val

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          nil
        else
          Process.sleep(step_ms)
          do_wait_until(fun, deadline, step_ms)
        end
    end
  end

  # --- setup --------------------------------------------------------------

  setup_all do
    port = free_tcp_port()
    ws_url = "ws://127.0.0.1:#{port}/agent_bridge/websocket"

    prev_url = System.get_env("EZAGENT_BRIDGE_WS_URL")
    System.put_env("EZAGENT_BRIDGE_WS_URL", ws_url)

    Application.put_env(:ezagent_plugin_cc, TestEndpoint,
      adapter: Bandit.PhoenixAdapter,
      http: [ip: {127, 0, 0, 1}, port: port],
      secret_key_base: String.duplicate("a", 64),
      pubsub_server: EzagentCore.PubSub,
      server: true
    )

    {:ok, _ep_pid} = start_supervised(TestEndpoint)

    on_exit(fn ->
      if prev_url do
        System.put_env("EZAGENT_BRIDGE_WS_URL", prev_url)
      else
        System.delete_env("EZAGENT_BRIDGE_WS_URL")
      end
    end)

    {:ok, port: port, ws_url: ws_url}
  end

  setup do
    {bin_dir, original_path} = install_fake_claude_on_path!()

    on_exit(fn ->
      restore_path!(original_path)
      File.rm_rf(bin_dir)
    end)

    {:ok, bin_dir: bin_dir}
  end

  # --- the sandbox + credentials e2e --------------------------------------

  describe "sandbox + credentials copy (Allen 'avoid re-login', 2026-05-23)" do
    @tag :slow
    @tag :requires_exec
    @tag skip: @missing_tooling
    @tag timeout: 120_000
    test "a credentials file seeded into the sandbox is visible to the spawned claude" do
      # ---- 1. erlexec up (PtyServer needs it in non-test_mode)
      case :application.ensure_all_started(:erlexec) do
        {:ok, _} -> :ok
        {:error, reason} -> flunk("erlexec unavailable: #{inspect(reason)}")
      end

      # ---- 2. build a sandbox AND pre-seed a credentials file inside it.
      # This is exactly what `mix ezagent.demo.seed_cc_sandbox` does for
      # an operator. The credentials contents are a uniqueness-tagged
      # JSON blob so we can prove out-of-band the SPECIFIC file we wrote
      # is what the spawned process read.
      sandbox_dir = Path.join(System.tmp_dir!(), "cc_sbx_creds_#{uniq()}")
      File.mkdir_p!(sandbox_dir)
      File.chmod!(sandbox_dir, 0o700)

      credentials_tag = "test-tok-#{uniq()}"

      credentials_contents =
        Jason.encode!(%{
          "claudeAiOauth" => %{
            "accessToken" => credentials_tag,
            "refreshToken" => "fake-refresh",
            "scopes" => ["user:inference"]
          }
        })

      credentials_path = Path.join(sandbox_dir, ".credentials.json")
      File.write!(credentials_path, credentials_contents)
      File.chmod!(credentials_path, 0o600)

      # ---- 3. agent working dir (separate from the sandbox dir)
      agent_cwd = Path.join(System.tmp_dir!(), "cc_sbx_cwd_#{uniq()}")
      File.mkdir_p!(agent_cwd)

      status_file = Path.join(System.tmp_dir!(), "cc_sbx_status_#{uniq()}.json")

      on_exit(fn ->
        File.rm_rf(sandbox_dir)
        File.rm_rf(agent_cwd)
        File.rm(status_file)
      end)

      agent_uri_str = "entity://team-alpha/agent/cc_sbxcreds-#{uniq()}"
      # Use the canonical constructor — `URI.parse/1` builds a non-canonical
      # %URI{} (authority set) that the deprecated parse leaves, which now trips
      # the canonical boundary in the RF-6 `:join` passive-actor gate
      # (`Ezagent.URI.stable_key/1`). Production always supplies canonical member
      # URIs; the test must mirror that.
      agent_uri = Ezagent.URI.new!(agent_uri_str)

      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => agent_cwd,
        "config_dir" => sandbox_dir
      }

      # ---- 4. dedicated McpConfigWriter dir
      mcp_dir = Path.join(System.tmp_dir!(), "cc_sbx_mcpdir_#{uniq()}")
      File.mkdir_p!(mcp_dir)

      prev_mcp_dir = Application.get_env(:ezagent_plugin_cc, :mcp_config_dir)
      Application.put_env(:ezagent_plugin_cc, :mcp_config_dir, mcp_dir)

      on_exit(fn ->
        File.rm_rf(mcp_dir)

        if prev_mcp_dir do
          Application.put_env(:ezagent_plugin_cc, :mcp_config_dir, prev_mcp_dir)
        else
          Application.delete_env(:ezagent_plugin_cc, :mcp_config_dir)
        end
      end)

      # ---- 5. build the production-shape Pty params
      {:ok, {production_argv, base_cmd_env}} =
        build_production_cmd!(agent_uri, agent_cwd, tmpl)

      # Pre-flight assertion: the cmd_env the cc plugin built carries
      # CLAUDE_CONFIG_DIR=<sandbox>. This is the load-bearing env-threading
      # invariant — without this, the spawned claude defaults to ~/.claude
      # and the credentials-copy flow is meaningless.
      assert base_cmd_env["CLAUDE_CONFIG_DIR"] == sandbox_dir,
             "the cc plugin's build_claude_cmd/3 must put CLAUDE_CONFIG_DIR=<sandbox> " <>
               "into the spawned process env; got: #{inspect(base_cmd_env)}"

      reply_prefix = "FAKE-ECHO::"

      cmd_env =
        base_cmd_env
        |> Map.put("FAKE_CLAUDE_STATUS_FILE", status_file)
        |> Map.put("FAKE_REPLY_PREFIX", reply_prefix)
        |> Map.put("FAKE_CLAUDE_GRACE_MS", "2500")
        |> Map.put("FAKE_CLAUDE_TIMEOUT_S", "60")
        # Tells the fake to read $CLAUDE_CONFIG_DIR/.credentials.json and
        # prepend `[creds:<contents>]` to its reply.
        |> Map.put("FAKE_CLAUDE_ECHO_CREDENTIALS", "1")

      # ---- 6. materialize the Agent through the template fixture first;
      #         this keeps the real Agent creation path aligned with
      #         from-template provisioning while letting this test own the
      #         PtyServer lifecycle.
      {:ok, _agent_pid} =
        Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent_with_flavor(agent_uri, "cc")

      assert {:ok, _} = KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive before the PtyServer spawns"

      # ---- 7. spawn the PtyServer with the production argv — :exec.run/2
      #         runs the resolved claude (= fake_claude.py) under a real
      #         PTY via execve, threading cmd_env (including CLAUDE_CONFIG_DIR).
      {:ok, _pty_pid} =
        Ezagent.Domain.Pty.start(agent_uri, %{
          cwd: agent_cwd,
          test_mode: false,
          cmd_override: production_argv,
          cmd_env: cmd_env
        })

      # ---- 8. wait for bridge bind
      bridge_bound =
        wait_until(
          fn ->
            case BridgeRegistry.lookup(agent_uri) do
              {:ok, pid} -> pid
              :error -> nil
            end
          end,
          60_000
        )

      assert is_pid(bridge_bound),
             "the bridge subprocess must connect to /agent_bridge and bind. " <>
               "Status: #{(File.exists?(status_file) && File.read!(status_file)) || "(no status file yet)"}"

      # ---- 9. session + admin, join both
      session_uri = Ezagent.URI.new!("session://team-alpha/default/sbxcreds-#{uniq()}")
      admin_uri = User.admin_uri()

      {:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

      _ =
        case KindRegistry.lookup(admin_uri) do
          {:ok, _} -> :ok
          :error -> Ezagent.SpawnRegistry.spawn(admin_uri)
        end

      :ok = chat_join(session_uri, admin_uri)
      :ok = chat_join(session_uri, agent_uri)
      :ok = grant_session_send(session_uri, agent_uri)

      session_topic = "esr:session:#{URI.to_string(session_uri)}:events"
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

      # ---- 10. admin sends a message MENTIONING the agent (mention-gated #226)
      inbound_text = "ping sandbox-credentials probe"

      inbound_msg =
        Message.new(admin_uri, %{text: inbound_text, attachments: []}, mentions: [agent_uri])

      send_target = Ezagent.URI.with_action(session_uri, :session, :send)

      :ok =
        Invocation.dispatch(%Invocation{
          origin: :trusted_internal,
          target: send_target,
          mode: :cast,
          args: %{message: inbound_msg},
          ctx: %{
            caller: admin_uri,
            caps: MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(send_target, admin_uri)]),
            reply: :ignore
          }
        })

      # ---- 11. wait for the reply — the fake claude prepends a
      #          `[creds:<contents>]` tag if it read the credentials file.
      reply_msg = wait_for_agent_reply(agent_uri, reply_prefix, 60_000)

      if reply_msg == nil do
        flunk_with_diagnostics(status_file, agent_uri, inbound_text)
      end

      reply_text =
        case reply_msg.body do
          %{text: t} -> t
          %{"text" => t} -> t
        end

      # ---- 12. PRIMARY ASSERTION — the reply carries the [creds:...] tag
      #          with our seeded credentials contents. This proves end-to-end:
      #            (a) CLAUDE_CONFIG_DIR threaded through execve,
      #            (b) the spawned process READ the file at <sandbox>/.credentials.json,
      #            (c) the contents were the bytes we wrote (NOT the host ~/.claude).
      assert String.contains?(reply_text, "[creds:"),
             "reply must carry the [creds:...] tag the fake-claude adds " <>
               "when it successfully reads <CLAUDE_CONFIG_DIR>/.credentials.json. " <>
               "Got: #{inspect(reply_text)}"

      assert String.contains?(reply_text, credentials_tag),
             "reply must carry the SPECIFIC credentials tag we seeded " <>
               "(#{credentials_tag}); proves the spawned claude read OUR " <>
               "sandbox file rather than some other path. " <>
               "Got: #{inspect(reply_text)}"

      # ---- 13. status file ALSO records the credentials probe — belt-and-braces
      assert File.exists?(status_file), "fake_claude.py must write its status file"
      status = status_file |> File.read!() |> Jason.decode!()

      assert get_in(status, ["env", "CLAUDE_CONFIG_DIR"]) == sandbox_dir,
             "spawned claude must see CLAUDE_CONFIG_DIR=<sandbox> in its env"

      probe = status["credentials_probe"] || %{}

      assert probe["path"] == credentials_path,
             "fake-claude probed the right credentials path"

      assert probe["exists"] == true,
             "fake-claude reports the credentials file EXISTS at the sandbox path"

      assert probe["contents"] == credentials_contents,
             "fake-claude reports the EXACT bytes we seeded — no leakage from the host"

      # ---- 14. cleanup
      :ok = Ezagent.Domain.Pty.stop(agent_uri)
      _ = BridgeRegistry.unbind(agent_uri)
      _ = Ezagent.WorkspaceRegistry.unbind(session_uri)

      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "no orphan PtyServer must remain after the test"

      assert BridgeRegistry.lookup(agent_uri) == :error,
             "no orphan BridgeRegistry binding may remain after the test"
    end
  end

  # --- chat helpers --------------------------------------------------------

  defp chat_join(session_uri, member_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, member_uri)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: member_uri,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
    |> case do
      {:ok, _} ->
        Process.sleep(50)
        :ok

      other ->
        flunk("chat.join failed for member=#{URI.to_string(member_uri)}: #{inspect(other)}")
    end
  end

  defp grant_session_send(session_uri, member_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :send)
    artifact = Ezagent.Test.CapHelper.signed_action_cap!(target, member_uri)

    with :ok <- Ezagent.Identity.absorb_cap(member_uri, artifact) do
      Ezagent.Identity.CapAbsorbAwait.await_exact(member_uri, [artifact], 5_000)
    end
  end

  defp wait_for_agent_reply(agent_uri, reply_prefix, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_reply(agent_uri, reply_prefix, deadline)
  end

  defp do_wait_for_reply(agent_uri, reply_prefix, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:chat_message, _sess, %Message{sender: sender, body: body} = msg} ->
        sender_str =
          case sender do
            %URI{} = u -> URI.to_string(u)
            s when is_binary(s) -> s
            _ -> ""
          end

        text =
          case body do
            %{text: t} -> t
            %{"text" => t} -> t
            _ -> ""
          end

        if sender_str == URI.to_string(agent_uri) and String.contains?(text, reply_prefix) do
          msg
        else
          do_wait_for_reply(agent_uri, reply_prefix, deadline)
        end
    after
      remaining -> nil
    end
  end

  defp flunk_with_diagnostics(status_file, agent_uri, inbound_text) do
    status =
      if File.exists?(status_file) do
        case File.read!(status_file) |> Jason.decode() do
          {:ok, s} -> inspect(s, pretty: true, limit: :infinity)
          _ -> "(could not decode status file)"
        end
      else
        "(no status file written)"
      end

    bridge_state =
      case BridgeRegistry.lookup(agent_uri) do
        {:ok, pid} -> "bound to pid=#{inspect(pid)}"
        :error -> "NOT bound"
      end

    flunk("""
    no [creds:...] reply received on session events stream in 60s.

    inbound text: #{inspect(inbound_text)}
    bridge: #{bridge_state}
    fake-claude status: #{status}
    """)
  end

  # --- build the PRODUCTION argv + env via the cc plugin's own builder ----
  # Mirrors PR #255's helper; if `CcAgent.build_claude_cmd/3` is ever
  # exposed (`@doc false`), both tests should switch to it. Until then
  # this rebuild stays in lockstep with the private builder.

  defp build_production_cmd!(agent_uri, agent_cwd, tmpl) do
    alias Ezagent.PluginCc.Template.CcAgent
    alias EzagentPluginCc.McpConfigWriter

    {:ok, claude_path} = CcAgent.resolve_claude_executable(agent_uri)

    {:ok, mcp_path, agent_token} =
      McpConfigWriter.write_with_token!(
        agent_uri: URI.to_string(agent_uri),
        agent_cwd: agent_cwd
      )

    settings_mcp_args =
      CcAgent.assemble_settings_mcp_args(
        mandatory_safety_settings_path(),
        mcp_path,
        tmpl
      )

    argv =
      [
        claude_path,
        # Mirror production (cc_agent build_claude_cmd) — see the
        # 2026-06-01 headless startup-dialog fix.
        "--dangerously-skip-permissions",
        "--dangerously-load-development-channels",
        "server:esr-bridge"
      ] ++ settings_mcp_args

    base_env = %{
      "EZAGENT_AGENT_URI" => URI.to_string(agent_uri),
      "EZAGENT_AGENT_TOKEN" => agent_token
    }

    cmd_env =
      case Map.get(tmpl, "config_dir") do
        dir when is_binary(dir) and dir != "" -> Map.put(base_env, "CLAUDE_CONFIG_DIR", dir)
        _ -> base_env
      end

    {:ok, {argv, cmd_env}}
  end

  defp mandatory_safety_settings_path do
    :code.priv_dir(:ezagent_plugin_cc)
    |> Path.join("claude-pty-settings.json")
  end
end
