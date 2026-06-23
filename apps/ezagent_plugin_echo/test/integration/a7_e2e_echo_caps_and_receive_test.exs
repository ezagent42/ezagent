defmodule EzagentPluginEcho.Integration.A7EchoCapAndReceiveTest do
  @moduledoc """
  A7 — E2E gate: echo agents are `Entity.Agent` (with Identity), and
  `Behavior.Echo` is in their per-instance set.

  Two verifications:

  ## Verify 1 — echo agent CAN RECEIVE CAPS (original bug this refactor fixes)

  Before A1-A5, creating an echo agent with caps failed:
  `{:grant_failed, _, {:unknown_action, :grant_cap}}` because `Entity.Echo`
  lacked `Identity` behavior. Now echo is `Entity.Agent` (has Identity).
  We create a fresh echo agent, grant it a `session.send` cap, and assert
  the grant SUCCEEDS (no `:grant_failed`).

  ## Verify 2 — echo ECHOES ON RECEIVE (critical regression check)

  Echo's purpose: when it RECEIVES a chat message, it replies back with
  "echo: <text>". After the refactor, `:receive` on `Entity.Agent` is
  handled by `Behavior.Agent.Receive` → `AgentBridge`. A8 registers
  `EzagentPluginEcho.BridgeAdapter` (`:in_process_sync` transport) so
  `deliver/2` calls `Behavior.Echo.handle_receive/2` in-process and fires
  the echo reply immediately. Was tagged `:known_regression` in A7; fixed
  in A8.

  ## Files changed by A7 (production fixes, not test-only):

  - `EzagentPluginEcho.Application.after_boot/0` — use
    `Kind.spawn(Entity.Agent, %{behaviors: echo_behaviors()})` instead
    of `SpawnRegistry.spawn/1` (the URI-only path fell to
    `nil_capture_behavior_set/0` → base only, no Echo).
  - `EzagentDomainInstanceMessage.Application.spawn_agent/1` — thread
    `instance_behaviors` from `AgentFlavorRegistry` so demand-spawns
    (cold-loads, test re-seeds, CLI respawns) also get the flavor's
    behavior set. Without this, any demand-spawn of a stale-snapshot
    echo agent produced a behaviors-less instance.

  ## Files changed by A8 (echo-on-receive fix):

  - `EzagentPluginEcho.BridgeAdapter` — new `:in_process_sync` adapter that
    calls `Behavior.Echo.handle_receive/2` in-process and dispatches its
    `session.send` reply effects immediately.
  - `EzagentPluginEcho.Application.agent_flavors/0` — `bridge_adapter:` key
    (registers the adapter for flavor `"echo"`).
  - `Ezagent.Behavior.Echo.create/1` — adds `flavor: "echo"` to the slice so a
    cold-loaded echo agent resolves its flavor from the durable snapshot.

  NOTE: `:sync_result` is deliberately NOT registered for echo — it is globally
  bound to `Behavior.CurlAgent`, so registering it would crash boot. The
  platform-enqueued `:sync_result` `:cast` is therefore dropped: echo's
  `:count`/`:last_msg` are not updated on a bridge-receive, and the drop emits a
  `:authz, :denied` (`behavior_not_in_instance_set`) telemetry event per receive.
  The echo reply itself is unaffected. Proper `:sync_result` handling for echo is
  a follow-up (A7 "option C").
  """

  use ExUnit.Case, async: false

  alias Ezagent.{Invocation, Message}
  alias Ezagent.Entity.User
  alias Ezagent.Workspace

  # This test touches DB (Kind snapshot writes, Identity grant writes,
  # Session membership writes) — manual sandbox checkout.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Bootstrap session domain so entity:// spawn fn is registered.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    # Unique workspace per test to avoid cross-test URI collisions.
    ws_name = "a7-test-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws_name, %{})
    workspace_uri = Ezagent.URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  # -----------------------------------------------------------------------
  # Verify 1 — echo CAN RECEIVE CAPS (previously grant_failed)
  # -----------------------------------------------------------------------

  describe "Verify 1 — echo agent can receive caps (original A1-A5 bug fix)" do
    @tag :integration
    test "create echo agent + grant session.send cap — no :grant_failed", %{
      ws_name: ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      unless entity_spawn_registered?() do
        IO.puts(:stderr, "SKIP Verify-1: entity spawn fn not registered (bootstrap incomplete)")
        :ok
      else
        echo_name = "a7v1-#{System.unique_integer([:positive])}"

        # Create echo agent through the same facade the mix task uses.
        assert {:ok, %{agent_uri: agent_uri}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{flavor: "echo", name: echo_name, cwd: "", with_pty: false},
                   admin_ctx
                 ),
               "create_agent for echo flavor must succeed"

        # Prove it's an Entity.Agent (not Entity.Echo — deleted in A5).
        assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri),
               "echo agent must be alive in KindRegistry after create"

        # Prove Identity is in the instance set (prerequisite for grant).
        # Identity.grant_cap is how operators grant caps at runtime.
        assert {:ok, _} = Ezagent.Kind.get_slice(agent_uri, :identity),
               "echo agent must have :identity slice (Identity behavior in instance set)"

        # Grant a real, non-wildcard cap — this is the failing action
        # that triggered the original bug (grant_cap required Identity).
        cap_to_grant =
          Ezagent.Capability.cap(
            :session,
            Ezagent.Behavior.Session,
            :send,
            Ezagent.URI.new!("session://#{ws_name}/default/main"),
            workspace_uri
          )

        # CORE ASSERTION: grant_initial_caps must return :ok (not {:grant_failed, _, _}).
        # Before A1-A5 fix this returned {:grant_failed, _, {:unknown_action, :grant_cap}}
        # because Entity.Echo lacked Identity. Entity.Agent has Identity → grant succeeds.
        assert :ok = Workspace.grant_initial_caps(agent_uri, [cap_to_grant], admin_ctx),
               "grant_initial_caps must succeed for an echo agent — " <>
                 "echo is now Entity.Agent (has Identity). " <>
                 "If this fails with {:grant_failed, _, {:unknown_action, :grant_cap}}, " <>
                 "the A1-A5 refactor is incomplete (Identity not in instance set)."

        # Verify the cap actually landed.
        assert Ezagent.Identity.list_caps_for(agent_uri)
               |> Enum.any?(fn
                 %Ezagent.Capability{behavior: Ezagent.Behavior.Session} = c ->
                   Ezagent.Capability.action_of(c) == :send

                 _ ->
                   false
               end),
               "the granted session.send cap must be queryable from the agent's identity"
      end
    end

    @tag :integration
    test "echo agent :say dispatch proves Behavior.Echo is in instance set", %{
      ws_name: _ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      unless entity_spawn_registered?() do
        IO.puts(:stderr, "SKIP: entity spawn fn not registered")
        :ok
      else
        echo_name = "a7v1-say-#{System.unique_integer([:positive])}"

        assert {:ok, %{agent_uri: agent_uri}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{flavor: "echo", name: echo_name, cwd: "", with_pty: false},
                   admin_ctx
                 )

        target = Ezagent.URI.with_action(agent_uri, :echo, :say)

        # :say dispatch proves Echo behavior is in the instance set.
        # If Behavior.Echo is absent (nil_capture_behavior_set), this returns
        # {:error, :behavior_not_in_instance_set}.
        assert {:ok, %{echo: "hello from A7"}} =
                 Invocation.dispatch(%Invocation{
                   target: target,
                   mode: :call,
                   args: %{msg: "hello from A7"},
                   ctx: %{
                     caller: User.admin_uri(),
                     caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                     reply: {:caller_inbox, self()}
                   }
                 }),
               "echo :say must return {:ok, %{echo: ...}} — " <>
                 "Behavior.Echo must be in the per-instance set. " <>
                 "Got :behavior_not_in_instance_set → the instance was spawned " <>
                 "without :behaviors threaded (nil_capture_behavior_set/0 = base only)."
      end
    end
  end

  # -----------------------------------------------------------------------
  # Verify 2 — echo ECHOES ON RECEIVE (critical regression check)
  # -----------------------------------------------------------------------
  #
  # FINDING: this test FAILS. After A1-A5, {Entity.Agent, :receive} is globally
  # owned by Behavior.Agent.Receive which routes to AgentBridge (subprocess_ws).
  # No echo AgentBridge adapter is registered, so deliver returns :no_bridge.
  # Behavior.Echo.handle_receive/2 is NEVER called — the echo reply never happens.
  #
  # The follow-up fix: register an echo AgentBridge adapter with transport_class
  # :in_process_sync (or a new :direct class) that calls Behavior.Echo.handle_receive,
  # OR implement per-flavor receive routing in Behavior.Agent.Receive.
  #
  # Tagged :known_regression so CI records the finding without blocking other gates.

  describe "Verify 2 — echo-on-receive (chat.send fan-out triggers echo reply)" do
    @tag :integration
    test "echo agent replies 'echo: <text>' when session dispatches chat.send to it", %{
      ws_name: _ws_name,
      workspace_uri: workspace_uri,
      admin_ctx: admin_ctx
    } do
      unless entity_spawn_registered?() do
        IO.puts(:stderr, "SKIP Verify-2: entity spawn fn not registered")
        :ok
      else
        {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

        # Create a fresh echo agent.
        echo_name = "a7v2-#{System.unique_integer([:positive])}"

        assert {:ok, %{agent_uri: echo_agent_uri}} =
                 Workspace.create_agent(
                   workspace_uri,
                   %{flavor: "echo", name: echo_name, cwd: "", with_pty: false},
                   admin_ctx
                 )

        # Create a session + join the echo agent.
        session_name = "a7v2-sess-#{System.unique_integer([:positive])}"

        # Create the session in the SAME workspace as the echo agent so
        # workspace isolation check passes when the session dispatches
        # agent.receive to the echo agent.
        assert {:ok, session_uri, _meta} =
                 EzagentDomainInstanceMessage.SessionCreator.create_session(
                   session_name,
                   User.admin_uri(),
                   template_name: "default",
                   workspace_uri: workspace_uri
                 )

        join_target = Ezagent.URI.with_action(session_uri, :session, :join)

        assert {:ok, _} =
                 Invocation.dispatch(%Invocation{
                   target: join_target,
                   mode: :call,
                   args: %{member: echo_agent_uri},
                   ctx: %{
                     caller: User.admin_uri(),
                     caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                     reply: {:caller_inbox, self()}
                   }
                 })

        # Subscribe to session events BEFORE sending.
        session_topic = Ezagent.Behavior.Session.session_events_topic(session_uri)
        :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, session_topic)

        text = "ping-a7-#{System.unique_integer([:positive])}"

        msg =
          Message.new(User.admin_uri(), %{text: text, attachments: []},
            mentions: [echo_agent_uri]
          )

        send_target = Ezagent.URI.with_action(session_uri, :session, :send)

        :ok =
          Invocation.dispatch(%Invocation{
            target: send_target,
            mode: :cast,
            args: %{message: msg},
            ctx: %{
              caller: User.admin_uri(),
              caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
              reply: :ignore
            }
          })

        # First broadcast: the original message.
        assert_receive {:chat_message, ^session_uri, %Message{} = _first}, 1000

        # Second broadcast: echo's reply "echo: <text>" from the echo agent's URI.
        #
        # A8 FIX — this assertion now passes. The echo :in_process_sync bridge
        # adapter (EzagentPluginEcho.BridgeAdapter) calls
        # Behavior.Echo.handle_receive/2 in-process and fires the session.send
        # reply synchronously, so the reply arrives before this assert_receive
        # window expires.
        assert_receive {:chat_message, ^session_uri, %Message{} = reply},
                       2000,
                       "echo-on-receive must produce a reply. " <>
                         "If this fails, check that EzagentPluginEcho.BridgeAdapter " <>
                         "is registered for flavor 'echo' (A8 fix)."

        reply_text =
          case reply.body do
            %{text: t} -> t
            %{"text" => t} -> t
          end

        assert reply_text == "echo: #{text}",
               "echo reply must be 'echo: #{text}', got #{inspect(reply_text)}"

        assert URI.to_string(reply.sender) == URI.to_string(echo_agent_uri),
               "reply.sender must be the echo agent URI"
      end
    end
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  defp entity_spawn_registered? do
    function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) and
      "entity" in Ezagent.SpawnRegistry.registered_schemes()
  end
end
