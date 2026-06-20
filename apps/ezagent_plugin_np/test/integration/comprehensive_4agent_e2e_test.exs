defmodule EzagentPluginNp.Integration.Comprehensive4AgentE2eTest do
  @moduledoc """
  Comprehensive 4-agent orchestration e2e per Allen Feishu 2026-05-23:

    user → @cc → cc converts to LaTeX → @curl → curl (mocked DeepSeek)
    converts LaTeX → numpy expr → @np → np computes → reply to user.

  This validates the multi-agent orchestration pipeline THROUGH the
  np-agent (`Ezagent.Behavior.NpAgent` + `Ezagent.Domain.Python`), the
  real curl-agent (HTTP client against a Bandit-hosted Plug mock that
  simulates DeepSeek), and a lightweight `FakeCcAgent` stand-in for
  the cc-agent's LaTeX-transformation contract.

  ## Why a FakeCcAgent and not the real cc PTY bridge

  The full real-cc round-trip is already proven end-to-end in
  `apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs`
  (the V1 sign-off test). Reusing it here would mean spinning up a
  Phoenix endpoint + uv bridge subprocess + erlexec PTY just to test
  ORCHESTRATION across three downstream agents. Per Allen's brief
  ("duplicate if cross-app sharing is too fiddly — your judgement")
  the focused stand-in (`Ezagent.PluginNp.Test.FakeCcAgent`) keeps this
  test fast + deterministic while exercising the same contract the
  real cc-agent satisfies on its reply path: `chat.receive` →
  transform → dispatch `chat.send` back.

  The real-cc + real-DeepSeek runbook
  (`docs/runbook/4-agent-comprehensive-e2e.md`) covers the manual
  smoke through the full stack.

  ## What this proves end-to-end

    * `Ezagent.Domain.Python` (#256) — a per-NpAgent uv-launched
      Python subprocess with PEP-723 inline deps (numpy + sympy)
      computes the formula the curl-agent emits.
    * `Ezagent.Behavior.NpAgent` — receives chat, dispatches
      `compute` to its Python subprocess via the `handle_key`
      canonical handle path, dispatches the result back as
      `chat.send`.
    * Real curl-agent — receives chat, calls the (mocked) DeepSeek
      endpoint via `httpc`, dispatches the assistant content back
      as `chat.send`.
    * 4-agent orchestration via per-session `{:from, sender}` rules
      that wire the chain: admin → cc → curl → np → admin.
    * The admin sees the final computed value on the session events
      stream.

  ## Routing config

  The system_default `{:always} → [$session_users, $mentions]` is
  mention-gated. To keep the orchestration explicit (admin's compose
  text need not name every agent in turn), we ADD per-session rules:

    `{:from, admin}`  → [cc_uri]
    `{:from, cc}`     → [curl_uri]
    `{:from, curl}`   → [np_uri]
    `{:from, np}`     → [admin_uri]

  These compose ADDITIVELY with the system default. cc / curl / np
  replies don't carry mentions metadata (their reply paths don't
  parse @-mentions out of text), so `$mentions` contributes nothing
  for the agent→agent legs — `{:from, _}` is what carries the chain.
  admin's User Kind also receives every reply via `$session_users`,
  which is what surfaces the final result on the admin's session
  events stream.

  ## Tags

    * `:slow` — boots a Bandit listener + spawns a uv subprocess
    * `:requires_uv` — needs `uv` on PATH
  """

  use EzagentCore.DataCase, async: false

  require Logger

  alias Ezagent.{Invocation, Message, RoutingRegistry}
  alias Ezagent.Behavior.Session, as: SessionBehavior
  alias Ezagent.Entity.User
  alias Ezagent.PluginNp.Template.NpAgent, as: NpTemplate
  alias Ezagent.PluginNp.Test.MockDeepSeek
  alias Ezagent.Routing.{Matcher, Resolver}

  @workspace_uri URI.new!("workspace://team-alpha")

  @uv_path System.find_executable("uv")
  @missing_uv if is_nil(@uv_path),
                do:
                  "uv not on PATH — Domain.Python requires uv to launch the np compute subprocess",
                else: false

  defp uniq, do: System.unique_integer([:positive])

  defp free_tcp_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    port
  end

  # Install a routing table that holds BOTH the migrated mention-
  # gated default + the four per-leg {:from, sender} chain rules.
  defp install_orchestration_table(legs) do
    table = String.to_atom("np_e2e_routing_#{uniq()}")
    :ok = RoutingRegistry.declare_table(table, key_uniqueness: :duplicate)

    # Mention-gated default (the system_default shape post-migration).
    :ok =
      RoutingRegistry.put(
        table,
        Matcher.always(),
        [Resolver.session_users_token(), Resolver.mentions_token()]
      )

    # The orchestration chain — explicit per-sender rules.
    for {sender_uri, receiver_uri} <- legs do
      :ok =
        RoutingRegistry.put(
          table,
          Matcher.from(sender_uri),
          [URI.to_string(receiver_uri)]
        )
    end

    # Tell the Resolver to consult this table.
    prev = Application.get_env(:ezagent_core, :routing_tables)
    Application.put_env(:ezagent_core, :routing_tables, [table])

    on_exit(fn ->
      if prev do
        Application.put_env(:ezagent_core, :routing_tables, prev)
      else
        Application.delete_env(:ezagent_core, :routing_tables)
      end
    end)

    table
  end

  defp join(session, member) do
    :ok =
      Invocation.dispatch(%Invocation{
        target: URI.new!("#{URI.to_string(session)}?action=session.join"),
        mode: :cast,
        args: %{member: member},
        ctx: %{
          caller: member,
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: :ignore
        }
      })

    Process.sleep(50)
  end

  # Spawn a Bandit listener on a free port serving the MockDeepSeek Plug.
  defp start_mock_deepseek! do
    port = free_tcp_port()

    {:ok, server_pid} =
      Bandit.start_link(plug: MockDeepSeek, port: port, ip: {127, 0, 0, 1})

    on_exit(fn ->
      try do
        Process.exit(server_pid, :shutdown)
      catch
        _, _ -> :ok
      end
    end)

    "http://127.0.0.1:#{port}/chat/completions"
  end

  describe "4-agent orchestration (admin → cc → curl → np → admin)" do
    @tag :slow
    @tag :requires_uv
    @tag skip: @missing_uv
    @tag timeout: 180_000
    test "round-trip completes and the admin sees the np-agent's computed reply" do
      # ---- 0. Stand up the mock DeepSeek endpoint ---------------------
      mock_deepseek_url = start_mock_deepseek!()

      # ---- 1. Spawn admin user + session ------------------------------
      session_uri = URI.new!("session://team-alpha/default/np-e2e-#{uniq()}")
      admin_uri = User.admin_uri()

      {:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
      on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

      # admin User is bootstrapped at boot; ensure it's spawned.
      case Ezagent.KindRegistry.lookup(admin_uri) do
        {:ok, _} -> :ok
        :error -> {:ok, _} = Ezagent.SpawnRegistry.spawn(admin_uri)
      end

      # ---- 2. Spawn the fake-cc agent (a generic Ezagent.Entity.Agent
      #         Kind with a transient Behavior registration to FakeCcAgent)
      cc_uri = URI.new!("entity://team-alpha/agent/test_cc-#{uniq()}")
      {:ok, _} = Ezagent.TestSupport.TemplateAgentSpawn.spawn_agent(cc_uri, "test")

      :ok =
        Ezagent.BehaviorRegistry.register(
          Ezagent.Entity.Agent,
          :receive,
          Ezagent.PluginNp.Test.FakeCcAgent
        )

      on_exit(fn ->
        # Restore the REAL Agent :receive Behavior so other tests in the suite
        # aren't affected. PR-2 (im/session/agent decomposition §OQ-4) split
        # `:receive` per Kind — `{Entity.Agent, :receive}` is now
        # `Ezagent.Behavior.Agent.Receive` (was `Behavior.Session` pre-split).
        _ =
          Ezagent.BehaviorRegistry.register(
            Ezagent.Entity.Agent,
            :receive,
            Ezagent.Behavior.Agent.Receive
          )
      end)

      # ---- 3. Spawn the real curl-agent + point it at the mock --------
      # PR-6 (im/session/agent decomposition §3.5) — a curl agent now spawns
      # on the UNIFIED `Ezagent.Entity.Agent` Kind with the curl per-instance
      # behavior set (`curl_behaviors/0`) + the stored `curl` flavor. Receive
      # flows `agent.receive` → AgentBridge → the curl `:in_process_sync`
      # adapter (the mocked-DeepSeek HTTP round-trip) → the curl Behavior's
      # `:sync_result` persist+reply. (Pre-fold this spawned the standalone
      # curl Kind, now DELETED; `mix ezagent.curl.migrate` rewrites old rows.)
      curl_uri = URI.new!("entity://team-alpha/agent/curl_np-e2e-#{uniq()}")

      {:ok, _curl_pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
          uri: curl_uri,
          behaviors: Ezagent.Entity.Agent.curl_behaviors(),
          provider: "deepseek",
          api_url: mock_deepseek_url,
          model: "deepseek-chat",
          system_prompt: nil,
          max_history: 20
        })

      # PR-6 — record the stored curl flavor so AgentBridge resolves the
      # `:in_process_sync` adapter (the Template does this; the direct spawn
      # here must do it explicitly).
      :ok = Ezagent.AgentFlavorAttributes.put(curl_uri, "curl")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(curl_uri) end)

      # Seed an API key on the curl-agent's OWN `:api_keys` slice
      # (Allen 2026-05-26 ApiKeys-to-Agent flip — agents hold their
      # own keys; the old "seed on admin user" path is gone).
      assert {:ok, _} =
               Invocation.dispatch(%Invocation{
                 target: URI.new!("#{URI.to_string(curl_uri)}?action=identity.put_api_key"),
                 mode: :call,
                 args: %{provider: "deepseek", key: "sk-fake-test-key-1234567890"},
                 ctx: %{
                   caller: admin_uri,
                   caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                   reply: {:caller_inbox, self()}
                 }
               })

      # ---- 4. Spawn the real np-agent via its Template Class ----------
      np_uri_str = "entity://team-alpha/agent/np_e2e-#{uniq()}"

      assert {:ok, [%URI{} = np_uri], %{fresh?: true}} =
               NpTemplate.instantiate(
                 "np.agent",
                 %{
                   "class" => "np.agent",
                   "agent_uri" => np_uri_str,
                   "cwd" => System.tmp_dir!()
                 },
                 @workspace_uri
               )

      on_exit(fn ->
        _ = Ezagent.Domain.Python.stop(np_uri)
      end)

      # Sanity: the Python subprocess is alive + answers ping.
      assert Ezagent.Domain.Python.alive?(np_uri),
             "the np-agent's Domain.Python subprocess must be alive after instantiate"

      assert {:ok, %{"ok" => true}} =
               Ezagent.Domain.Python.call(np_uri, "ping", %{}, 30_000)

      # ---- 5. Install the orchestration routing table -----------------
      _table =
        install_orchestration_table([
          {admin_uri, cc_uri},
          {cc_uri, curl_uri},
          {curl_uri, np_uri},
          {np_uri, admin_uri}
        ])

      # ---- 6. Join all four members to the session --------------------
      join(session_uri, admin_uri)
      join(session_uri, cc_uri)
      join(session_uri, curl_uri)
      join(session_uri, np_uri)

      # ---- 7. Subscribe to the session events stream BEFORE the send --
      session_topic = SessionBehavior.session_events_topic(session_uri)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

      # ---- 8. admin sends "compute 2+2" — kicks off the chain ---------
      inbound_text = "compute 2+2"

      inbound_msg =
        Message.new(admin_uri, %{text: inbound_text, attachments: []})

      :ok =
        Invocation.dispatch(%Invocation{
          target: URI.new!("#{URI.to_string(session_uri)}?action=session.send"),
          mode: :cast,
          args: %{message: inbound_msg},
          ctx: %{
            caller: admin_uri,
            caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
            reply: :ignore
          }
        })

      # ---- 9. Collect every chat broadcast on the session stream ------
      #         until we see the np-agent's reply (or timeout).
      np_reply_text =
        wait_for_sender_reply(
          np_uri,
          120_000,
          fn body ->
            text =
              case body do
                %{text: t} -> t
                %{"text" => t} -> t
                _ -> ""
              end

            # Reply text must contain "=" (NpAgent.format prefix) +
            # the computed result ("0.5" since MockDeepSeek returns
            # 0.5 for the integral the fake-cc emits — see
            # MockDeepSeek.transform_to_numpy/1).
            String.contains?(text, "=") and String.contains?(text, "0.5")
          end
        )

      assert np_reply_text != nil,
             "the admin must see the np-agent's reply on the session events " <>
               "stream within 120s; the 4-agent orchestration round-trip did " <>
               "not complete"

      # ---- 10. Final assertion: the np-agent computed the value -------
      assert String.contains?(np_reply_text, "0.5"),
             "np-agent reply must carry the computed value `0.5`; got: " <>
               inspect(np_reply_text)

      # Bonus: assert the in-between hops also showed up on the stream
      # (proves cc + curl actually fired, not just np).
      stream = drain_stream_messages(2_000)
      senders = Enum.map(stream, fn {_s, %Message{sender: sender}} -> URI.to_string(sender) end)

      assert URI.to_string(cc_uri) in senders or already_saw?(cc_uri),
             "the fake-cc agent's reply must have appeared on the session stream"

      assert URI.to_string(curl_uri) in senders or already_saw?(curl_uri),
             "the curl-agent's reply must have appeared on the session stream"
    end
  end

  # --- helpers -----------------------------------------------------------

  # Tracks senders we observed during the primary wait loop so the
  # post-test stream assertions can credit them.
  defp seen_senders_table do
    case :ets.whereis(:np_e2e_seen) do
      :undefined -> :ets.new(:np_e2e_seen, [:set, :public, :named_table])
      _ -> :np_e2e_seen
    end
  end

  defp note_sender(%URI{} = u), do: :ets.insert(seen_senders_table(), {URI.to_string(u), true})

  defp already_saw?(%URI{} = u) do
    case :ets.lookup(seen_senders_table(), URI.to_string(u)) do
      [{_, true}] -> true
      _ -> false
    end
  end

  defp wait_for_sender_reply(target_uri, timeout_ms, body_pred) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_sender_reply(target_uri, deadline, body_pred)
  end

  defp do_wait_for_sender_reply(target_uri, deadline, body_pred) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:chat_message, _session, %Message{sender: sender, body: body}} ->
        if match?(%URI{}, sender), do: note_sender(sender)

        sender_match =
          case sender do
            %URI{} = u -> URI.to_string(u) == URI.to_string(target_uri)
            s when is_binary(s) -> s == URI.to_string(target_uri)
            _ -> false
          end

        if sender_match and body_pred.(body) do
          extract_text(body)
        else
          do_wait_for_sender_reply(target_uri, deadline, body_pred)
        end

      _other ->
        do_wait_for_sender_reply(target_uri, deadline, body_pred)
    after
      remaining -> nil
    end
  end

  defp drain_stream_messages(extra_ms) do
    Process.sleep(extra_ms)
    drain_loop([])
  end

  defp drain_loop(acc) do
    receive do
      {:chat_message, s, %Message{} = msg} -> drain_loop([{s, msg} | acc])
      _ -> drain_loop(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""
end
