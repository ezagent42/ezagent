defmodule Ezagent.PluginCc.Integration.CcAgentAdminReplyE2eTest do
  @moduledoc """
  CC-agent V1 sign-off e2e — "admin 发消息后 cc agent 可以回复"
  (Allen Feishu 2026-05-22). The CI-runnable, deterministic Test A
  variant from the e2e plan.

  ## What this proves end-to-end

  An admin User dispatches `chat.send` against a session that has a
  cc-flavored Agent as a member; the cc agent's `claude` PTY (here:
  the deterministic `fake_claude.py` stand-in) sees the message via
  the `esr-bridge` MCP `notifications/claude/channel`, replies with
  `tools/call name="reply"`, and that reply lands as a fresh
  `chat.send` on the same session.

  The full real production wiring is exercised:

    AgentTemplate slice (`flavor: "cc"`, universal `config_dir`, …)
      → `AgentTemplate.to_template_data/2`
      → `CcAgent.instantiate/3`
      → `build_claude_cmd/3` returns the argv list (mandatory `--settings`
        last; trusted esr-bridge `--mcp-config` always present)
      → `Domain.Pty.start/2` with `test_mode: false` → `:exec.run/2`
        spawns the fake `claude` via execve (NO shell — codex HIGH-2)
      → fake `claude` parses `--mcp-config <bridge.mcp.json>`, spawns
        `uv run --script ezagent_mcp_bridge.py` as the MCP server
      → bridge opens the WS Channel back to ezagent (`/agent_bridge`)
      → AgentBridge.Registry binds the channel pid to the agent_uri
      → admin sends `chat.send` to the session (mentioning the agent —
        mention-gated routing per PR #226)
      → Session fans out to the agent → `chat.receive` →
        `AgentBridge.Registry.lookup` → cc BridgeAdapter →
        `{:agent_bridge_push, "to_claude", payload}` → channel pushes
        `to_claude` to the bridge → bridge emits
        `notifications/claude/channel` on its stdout
      → fake claude sees the notification, calls
        `tools/call name="reply"` → bridge sends a WS `"reply"` event
      → `Ezagent.AgentBridge.Channel.handle_in("reply", _, _)` dispatches a
        new `chat.send` from the agent to the session
      → the session's PubSub `:events` topic broadcasts the reply.

  We subscribe to the session events topic at the start and assert the
  reply chat message arrives carrying our deterministic prefix.

  ## Assertions (V1 sign-off)

    * the round-trip lands the reply on the session events stream;
    * the `CLAUDE_CONFIG_DIR` env arrived at the spawned fake claude
      (proving the AgentTemplate's sandbox config threaded through);
    * the mandatory plugin safety `--settings` IS LAST in the argv
      chain handed to claude (proving the rev-1 hardening is
      non-bypassable, even with an operator `settings_path` set);
    * the trusted esr-bridge `--mcp-config` is present in the chain
      (proving the bridge is never replaced);
    * after the test, no orphan PtyServer / Channel pid is left bound.

  ## Why this is in the cc-plugin app (Tier 3)

  Per the 3-tier rule: chat-dispatch + AgentTemplate are Tier 2
  domain code; the integration that PROVES them wires through cc's
  PtyServer + Channel + MCP-bridge sits in Tier 3 (this app), where
  cc-only test fixtures (the fake_claude.py + the in-test endpoint
  hosting `/agent_bridge`) live without bleeding into domain tests.

  ## Tooling preconditions

  Three host-level binaries must be available — without any, the test
  is a real ExUnit `:skip` (not a printed SKIP that lets CI pass green
  without ever running the e2e):

    * `uv` — runs the Python bridge with PEP-723 inline metadata so
      `websockets` resolves on first run.
    * `python3` — runs the fake claude.
    * a TCP listener — the test binds a free port for the in-test
      Phoenix endpoint hosting `/agent_bridge`.

  ## Tagging

    * `:slow` — boots a real HTTP listener + spawns subprocesses
    * `:requires_exec` — uses `:exec.run/2` via Domain.Pty.Server

  Lives next to `dev_channels_confirm_test.exs` (the only other
  `:requires_exec` test in this app).
  """

  # The in-test Phoenix endpoint mirrors the production EzagentWeb
  # one (just the `/agent_bridge` mount and a `pubsub_server`). It MUST be
  # defined at the top level of the file (not nested in the test
  # module) so the `socket/3` macro is unambiguous against
  # Phoenix.ChannelTest's `socket/3` import.
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
  alias Ezagent.PluginCc.Template.CcAgent
  alias Ezagent.AgentBridge.Registry, as: BridgeRegistry
  alias EzagentPluginCc.McpConfigWriter

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

  # Create a temp `bin/` dir holding ONE executable named `claude` that
  # is in fact our `fake_claude.py`. Prepend that dir to PATH so
  # `CcAgent.resolve_claude_executable/1` (which is
  # `System.find_executable("claude")`) returns our fake. Returns
  # `{bin_dir, original_path}` so the caller can restore PATH on exit.
  defp install_fake_claude_on_path! do
    bin_dir = Path.join(System.tmp_dir!(), "cc_e2e_bin_#{uniq()}")
    File.mkdir_p!(bin_dir)
    claude_path = Path.join(bin_dir, "claude")

    # A tiny POSIX shell wrapper that execs the Python fake. Keeps the
    # OS interpretation simple: argv[0] is an absolute path so
    # `execve` resolves it (per codex review of #233 — argv[0] must
    # be an absolute path under list-form `:exec.run/2`); the wrapper
    # then `exec`s python3 with the real fake script, forwarding all
    # args. This avoids any shebang-resolution gotcha across
    # systems.
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

  # Pull every `--settings <path>` value out of an argv list, preserving
  # order. The LAST one MUST be the mandatory plugin safety file —
  # claude is last-wins (rev-1 hardening). The plugin file lives at
  # `:code.priv_dir(:ezagent_plugin_cc)/claude-pty-settings.json`.
  defp settings_paths(argv) do
    argv
    |> Enum.with_index()
    |> Enum.filter(fn {el, _i} -> el == "--settings" end)
    |> Enum.map(fn {_el, i} -> Enum.at(argv, i + 1) end)
  end

  defp mcp_config_paths(argv) do
    argv
    |> Enum.with_index()
    |> Enum.filter(fn {el, _i} -> el == "--mcp-config" end)
    |> Enum.map(fn {_el, i} -> Enum.at(argv, i + 1) end)
  end

  defp mandatory_safety_settings_path do
    :code.priv_dir(:ezagent_plugin_cc)
    |> Path.join("claude-pty-settings.json")
  end

  # Wait up to `timeout_ms` for `fun.()` to return a truthy value.
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
    # Set the WS URL the cc plugin's `McpConfigWriter` bakes into the
    # bridge mcp.json. We bind to a freshly-chosen free port so this
    # test never collides with a running `mix phx.server` (the prod
    # endpoint binds 10042). The TestEndpoint config below uses the
    # same port.
    port = free_tcp_port()
    ws_url = "ws://127.0.0.1:#{port}/agent_bridge/websocket"

    prev_url = System.get_env("EZAGENT_BRIDGE_WS_URL")
    System.put_env("EZAGENT_BRIDGE_WS_URL", ws_url)

    # Configure + start the test endpoint with a real HTTP listener.
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

  # --- the V1 sign-off test ----------------------------------------------

  describe "admin -> cc agent -> reply (Allen V1 sign-off, 2026-05-22)" do
    @tag :slow
    @tag :requires_exec
    @tag skip: @missing_tooling
    @tag timeout: 120_000
    test "an admin chat.send round-trips through the real cc agent stack and a reply lands on the session" do
      # ---- 1. ensure erlexec is up (PtyServer needs it in non-test_mode)
      case :application.ensure_all_started(:erlexec) do
        {:ok, _} -> :ok
        {:error, reason} -> flunk("erlexec unavailable: #{inspect(reason)}")
      end

      # ---- 2. build the AgentTemplate slice (sandbox config)
      agent_cwd =
        Path.join(System.tmp_dir!(), "cc_e2e_cwd_#{uniq()}")

      File.mkdir_p!(agent_cwd)

      sandbox_config_dir =
        Path.join(System.tmp_dir!(), "cc_e2e_sandbox_#{uniq()}/.claude")

      File.mkdir_p!(sandbox_config_dir)

      # An operator-supplied settings file — should land FIRST in the
      # --settings chain (non-conflicting key only; the mandatory plugin
      # file wins last on any safety key).
      operator_settings_path =
        Path.join(System.tmp_dir!(), "cc_e2e_operator_settings_#{uniq()}.json")

      File.write!(
        operator_settings_path,
        Jason.encode!(%{"includeCoAuthoredBy" => false})
      )

      status_file =
        Path.join(System.tmp_dir!(), "cc_e2e_status_#{uniq()}.json")

      on_exit(fn ->
        File.rm_rf(agent_cwd)
        File.rm_rf(Path.dirname(sandbox_config_dir))
        File.rm(operator_settings_path)
        File.rm(status_file)
      end)

      agent_uri = Ezagent.URI.agent("team-alpha", "cc_v1signoff-#{uniq()}")
      _authority = install_test_authority!(agent_uri, :agent)
      agent_uri_str = URI.to_string(agent_uri)

      # The cc.agent Template Class data — exactly what
      # `AgentTemplate.to_template_data/2` produces from a real
      # AgentTemplate `:template` slice carrying these sandbox keys.
      tmpl = %{
        "class" => "cc.agent",
        "agent_uri" => agent_uri_str,
        "cwd" => agent_cwd,
        "config_dir" => Path.dirname(sandbox_config_dir),
        "operator_settings_path" => operator_settings_path
      }

      # Sanity: the data flow from a real AgentTemplate content map
      # produces the SAME template data we're about to feed CcAgent —
      # proves the AgentTemplate adapter is the source of truth.
      at_content = %{
        flavor: "cc",
        project_cwd: agent_cwd,
        config_dir: Path.dirname(sandbox_config_dir),
        settings_path: operator_settings_path,
        mcp_config_path: nil,
        api_key_helper: nil
      }

      assert {:ok, derived} =
               Ezagent.Entity.AgentTemplate.to_template_data(at_content, agent_uri)

      assert derived["agent_uri"] == agent_uri_str
      assert derived["cwd"] == agent_cwd
      assert derived["config_dir"] == Path.dirname(sandbox_config_dir)
      assert derived["operator_settings_path"] == operator_settings_path

      # ---- 3. assert the argv build path emits the mandatory safety
      #         --settings LAST (rev-1 hardening, non-bypassable)
      mandatory = mandatory_safety_settings_path()
      fake_bridge_mcp = "/dummy/bridge.mcp.json"

      argv_seq =
        CcAgent.assemble_settings_mcp_args(mandatory, fake_bridge_mcp, tmpl)

      sp = settings_paths(argv_seq)

      assert sp == [operator_settings_path, mandatory],
             "the argv-safe builder must emit operator --settings FIRST and " <>
               "the mandatory plugin safety --settings LAST (last-wins)"

      assert List.last(sp) == mandatory,
             "the mandatory plugin safety --settings MUST be last (rev-1 hardening)"

      mcps = mcp_config_paths(argv_seq)
      assert fake_bridge_mcp in mcps

      # ---- 4. point the McpConfigWriter at a dedicated dir so writes
      #         don't clobber other tests' bridge.mcp.json
      mcp_dir = Path.join(System.tmp_dir!(), "cc_e2e_mcpdir_#{uniq()}")
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

      # ---- 5. build the PRODUCTION-shape Pty params (NOT test_mode)
      #         using the cc plugin's own argv builder
      {:ok, {production_argv, base_cmd_env}} =
        build_production_cmd!(agent_uri, agent_cwd, tmpl)

      # The mandatory safety --settings stayed last in the full argv too
      argv_settings = settings_paths(production_argv)
      assert List.last(argv_settings) == mandatory

      # Plumb the status-file path + reply prefix into the spawned fake
      # via the cc_env (same channel the cc plugin uses for
      # CLAUDE_CONFIG_DIR). The fake_claude.py looks these up.
      reply_prefix = "FAKE-ECHO::"

      cmd_env =
        base_cmd_env
        |> Map.put("FAKE_CLAUDE_STATUS_FILE", status_file)
        |> Map.put("FAKE_REPLY_PREFIX", reply_prefix)
        |> Map.put("FAKE_CLAUDE_GRACE_MS", "2500")
        |> Map.put("FAKE_CLAUDE_TIMEOUT_S", "60")

      # ---- 6. materialize the Agent through the template fixture first;
      #         production reaches the same Agent path from CcAgent.instantiate
      #         via SpawnRegistry, while this test owns the PtyServer lifecycle.
      {:ok, _agent_pid} =
        Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent_with_flavor(agent_uri, "cc")

      assert {:ok, _} = KindRegistry.lookup(agent_uri),
             "Agent Kind must be alive before the PtyServer spawns"

      # ---- 7. spawn the PtyServer with the production argv (NOT
      #         test_mode) — this is the e2e's load-bearing call:
      #         `:exec.run/2` runs the resolved `claude` (= fake_claude.py)
      #         under a real PTY via execve.
      {:ok, _pty_pid} =
        Ezagent.Domain.Pty.start(agent_uri, %{
          cwd: agent_cwd,
          test_mode: false,
          cmd_override: production_argv,
          cmd_env: cmd_env
        })

      # ---- 8. wait for the bridge to come up and bind in BridgeRegistry
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
             "the bridge subprocess (uv run --script ezagent_mcp_bridge.py) " <>
               "must connect to /agent_bridge and the AgentBridge registry must bind it. " <>
               "Status: #{(File.exists?(status_file) && File.read!(status_file)) || "(no status file yet)"}"

      # ---- 9. set up a session + admin user, join the agent + admin
      session_uri = Ezagent.URI.new!("session://team-alpha/default/v1signoff-#{uniq()}")
      admin_uri = User.admin_uri()

      {:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

      # admin User is bootstrapped by domain_identity at boot; it should
      # already be in KindRegistry. If not, spawn it.
      _ =
        case KindRegistry.lookup(admin_uri) do
          {:ok, _} -> :ok
          :error -> Ezagent.SpawnRegistry.spawn(admin_uri)
        end

      :ok = chat_join(session_uri, admin_uri)
      :ok = chat_join(session_uri, agent_uri)
      :ok = grant_session_send(session_uri, agent_uri)

      # ---- 10. subscribe to the session events stream BEFORE the send,
      #          so we don't miss the reply broadcast
      session_topic = "esr:session:#{URI.to_string(session_uri)}:events"
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

      # ---- 11. admin sends a message MENTIONING the agent — required
      #          per the mention-gated routing constraint (PR #226):
      #          an un-mentioned agent gets nothing.
      inbound_text = "hello cc agent, please echo this back to me"

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
            authenticated_principal: admin_uri,
            caps: MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(send_target, admin_uri)]),
            reply: :ignore
          }
        })

      # ---- 12. wait for the REPLY chat message from the agent on the
      #          session stream. The fake claude prefixes the inbound
      #          content with `FAKE-ECHO::`, then `Channel.handle_in("reply", ...)`
      #          dispatches a new `chat.send` from the agent — which we
      #          observe via the session events broadcast.
      reply_msg =
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

            cond do
              sender_str == URI.to_string(agent_uri) and String.contains?(text, reply_prefix) ->
                msg

              true ->
                # Not the reply — keep waiting (the inbound itself also
                # broadcasts).
                wait_for_reply(reply_prefix, agent_uri, 60_000)
            end
        after
          60_000 ->
            flunk_with_diagnostics(status_file, agent_uri, inbound_text)
        end

      # ---- 13. assert the reply content
      reply_text =
        case reply_msg.body do
          %{text: t} -> t
          %{"text" => t} -> t
        end

      assert String.starts_with?(reply_text, reply_prefix),
             "reply must carry the FAKE-ECHO:: prefix; got: #{inspect(reply_text)}"

      assert String.contains?(reply_text, inbound_text),
             "reply must echo the inbound content; got: #{inspect(reply_text)}"

      # ---- 14. fake-claude status file proves the env + safety invariants
      assert File.exists?(status_file), "fake_claude.py must write its status file"

      status = status_file |> File.read!() |> Jason.decode!()

      assert status["phase"] in ["reply_sent", "done"],
             "fake claude should have reached at least the reply_sent phase; got: #{inspect(status["phase"])}"

      # CLAUDE_CONFIG_DIR threaded through — proves the AgentTemplate's
      # sandbox knob actually reaches the spawned `claude`.
      assert get_in(status, ["env", "CLAUDE_CONFIG_DIR"]) == Path.dirname(sandbox_config_dir),
             "the AgentTemplate config_dir (universal) must reach the spawned claude via CLAUDE_CONFIG_DIR"

      # EZAGENT_AGENT_URI threaded through (used by the bridge to identify itself).
      assert get_in(status, ["env", "EZAGENT_AGENT_URI"]) == agent_uri_str

      assert get_in(status, ["env", "EZAGENT_AGENT_TOKEN"]) != "",
             "the per-instance bridge token must be exported to claude's env"

      # The mandatory safety --settings was LAST in the argv chain the
      # OS actually saw — end-to-end proof of rev-1 hardening.
      observed_settings = status["settings_chain"] || []

      assert List.last(observed_settings) == mandatory,
             "the OS argv chain handed to claude must end with the mandatory " <>
               "plugin safety --settings (rev-1 hardening, non-bypassable). " <>
               "Observed: #{inspect(observed_settings)}"

      assert operator_settings_path in observed_settings,
             "the operator settings_path from the AgentTemplate must reach claude"

      # The trusted esr-bridge --mcp-config is present in the argv.
      assert is_list(status["mcp_config_chain"]) and status["mcp_config_chain"] != [],
             "the trusted esr-bridge --mcp-config must be present in the argv"

      # ---- 15. cleanup hygiene: terminate the PtyServer + Agent Kind +
      #          unbind workspace + verify no orphans
      :ok = Ezagent.Domain.Pty.stop(agent_uri)
      _ = BridgeRegistry.unbind(agent_uri)

      _ = Ezagent.WorkspaceRegistry.unbind(session_uri)

      refute Ezagent.Domain.Pty.alive?(agent_uri),
             "no orphan PtyServer must remain after the test"

      assert BridgeRegistry.lookup(agent_uri) == :error,
             "no orphan BridgeRegistry binding may remain after the test"
    end
  end

  # --- chat.join helper ---------------------------------------------------

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
        authenticated_principal: member_uri,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
    |> case do
      {:ok, _} ->
        # Give the Session's monitor + slice update time to settle so a
        # send dispatched immediately after sees the member.
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

  defp wait_for_reply(reply_prefix, agent_uri, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_reply(reply_prefix, agent_uri, deadline)
  end

  defp do_wait_for_reply(reply_prefix, agent_uri, deadline) do
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
          do_wait_for_reply(reply_prefix, agent_uri, deadline)
        end
    after
      remaining ->
        nil
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
    no reply received on session events stream in 60s — the admin->cc agent
    round-trip did not complete.

    inbound text: #{inspect(inbound_text)}
    bridge: #{bridge_state}
    fake-claude status: #{status}
    """)
  end

  # --- build the PRODUCTION argv + env via the cc plugin's own builder ----

  # `CcAgent.build_claude_cmd/3` is private (`defp`) and gated to
  # `Mix.env() != :test` inside `build_pty_params/3`. We rebuild it
  # here using the SAME pieces — `resolve_claude_executable/1`,
  # `McpConfigWriter.write_with_token!/1`, `assemble_settings_mcp_args/3`,
  # and the same env shape — so the e2e exercises the production code
  # path. If a future refactor changes `build_claude_cmd/3`'s shape
  # this helper must move in lockstep (or, preferably, be replaced by
  # exposing the builder as `@doc false`).
  defp build_production_cmd!(agent_uri, agent_cwd, tmpl) do
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
end
