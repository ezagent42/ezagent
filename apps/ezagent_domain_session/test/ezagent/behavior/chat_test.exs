defmodule Ezagent.ActionSet.ChatTest do
  @moduledoc """
  Phase 2b-step 2: Chat Behavior full invoke clause tests.

  Direct invoke/4 unit tests with crafted slices + ctx (no live
  KindRegistry / PubSub setup besides what the umbrella starts).
  Integration coverage (full dispatch path through Session GenServer
  + admin User membership) lives in
  `EzagentDomainInstanceMessage.Integration.ChatRoutingTest`.
  """

  use EzagentCore.DataCase, async: false
  alias Ezagent.{Capability, Message, MessageStore}
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.InterfaceValidator
  alias Ezagent.Routing.{Matcher, Receiver, Trace}
  import Ezagent.Test.CapHelper, only: [signed_fixture_cap!: 5, signed_invocation!: 2]
  # `Repo` is aliased by `use EzagentCore.DataCase`; no explicit alias needed (#92).

  setup do
    # Shared sandbox provided by EzagentCore.DataCase (#92).
    :ok = EzagentDomainInstanceMessage.AgentBridgeTestAdapter.ensure_registered()
    :ok
  end

  # Phase 9 PR-6 — `MessageStore.write/2` requires the session to be
  # bound to a workspace via WorkspaceRegistry (invariant 4 + SPEC v3
  # §7). Helper binds + queues teardown so tests calling EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(Ezagent.ActionSet.Session, :send)
  # or :join don't hit the "no workspace binding" raise.
  defp bind_to_default(session_uri) do
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://team-alpha"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  # Membership-cap unification A2.2 — `:receive` now authorizes in-handler on the
  # recipient's HELD member-cap over `ctx.caller`. These tests assert receive slice
  # MECHANICS / bridge payloads (the held-cap gate itself is proven in
  # `Ezagent.Session.HeldCapReceiveTest`), so they grant the recipient the matching
  # member-cap in the pre-loaded `:identity` sibling to clear the gate.
  defp with_member_cap(ctx) do
    caller = Map.fetch!(ctx, :caller)

    Map.put(ctx, :siblings, %{identity: %{caps: MapSet.new([member_cap(caller)])}})
  end

  defp member_cap(session_uri) do
    %Capability{
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session_uri,
        Capability.workspace_of(session_uri)
      )
      | granted_by: URI.new!("entity://system/user/owner"),
        granted_at: DateTime.utc_now()
    }
  end

  describe "Behavior contract surface" do
    test "actions/0 returns the K-path actions + the working-copy writer" do
      # Phase 7 completion PR-4 (SPEC §1.6) — `:set_working_copy` joins
      # the four K-path actions: the Generator + the orchestrator slot
      # tools write the durable `template_working_copy` field through it.
      # team-routing-unification §3.6 (PR-6) — `:set_legends` joins as the
      # session-scoped legend-registry writer (same authority class as
      # :set_working_copy). team-routing-unification §3.4/§3.7 (PR-7) —
      # `:set_prompt_templates` joins as the named prompt-template-map
      # writer (same authority class; PR-7 materialization installs it).
      # PR-2 (im/session/agent decomposition §OQ-4): `:receive` is no
      # longer a Session action — it split into `user.receive` /
      # `agent.receive` (their own Behaviors, on their own Kinds).
      # F7 PR-A — `:remove_participant` joins as the isomorphic participant-
      # removal primitive (declared right after `:leave`).
      # Membership-cap unification Part C (spec §C.4/§C.5) — the admission
      # approve/deny/withdraw actions join at the end (declared after
      # :set_prompt_templates), cap-exempt + in-handler manages?/requested_by authz.
      assert SessionBehavior.actions() ==
               [
                 :send,
                 :join,
                 :leave,
                 :remove_participant,
                 :assign_role,
                 :attach,
                 :merge_member,
                 :set_working_copy,
                 :set_legends,
                 :set_prompt_templates,
                 :approve_admission,
                 :deny_admission,
                 :withdraw_admission,
                 :composition_consent
               ]
    end

    test "state_slice/0 returns :chat" do
      assert SessionBehavior.state_slice() == :session
    end

    test "init_slice/1 returns two-container slice; create/1 holds the PERSISTENT fields (no :monitors)" do
      # Lifecycle migration (SPEC 2026-05-29 §2.3C) — the `:chat` slice is
      # now the two-container `%{state, transients}` shape. `:monitors`
      # moved OUT of the persistent state into the TRANSIENT container
      # (rebuilt by `activate/2`), so `create/1` (the persistent builder)
      # no longer carries it.
      #
      # Phase 7 completion PR-2 — `:chat` state carries the durable
      # `template_working_copy` (SPEC §1.3 / §1.6).
      #
      # PR-EM-6-PRE (Allen 2026-05-25) — three send-tracking fields at
      # their identity defaults. `:owner_uri` defaults to nil for arg-less
      # init (PR-OWN-2).
      assert SessionBehavior.init_slice(%{}) == %{
               state: %{
                 members: %{},
                 # Membership-cap unification Part C (spec §C.2) — pending
                 # admission requests; distinct from :members, empty by default.
                 pending_members: %{},
                 owner_uri: nil,
                 last_seen: %{},
                 last_message_id: nil,
                 last_message: nil,
                 send_cursor: 0,
                 # PR-N3 r4 — cursor-indexed bounded ring; starts empty.
                 recent_messages: [],
                 # team-routing-unification §3.4 (PR-4b) — session-scoped
                 # named prompt templates; empty by default.
                 prompt_templates: %{},
                 # team-routing-unification §3.6 (PR-6) — session-scoped legend
                 # registry; empty by default.
                 legends: %{},
                 template_working_copy: SessionBehavior.default_template_working_copy()
               },
               transients: %{}
             }

      # :monitors is GONE from the persistent state (it's a transient).
      refute Map.has_key?(SessionBehavior.init_slice(%{}).state, :monitors)
    end

    test "default_template_working_copy/0 is the empty template-shaped record (no agent_slots, §3.8)" do
      wc = SessionBehavior.default_template_working_copy()

      # team-routing-unification §3.8 (PR-8) — `agent_slots` is DROPPED from
      # the live working copy (clean cutover). A team is members + rule-sets.
      refute Map.has_key?(wc, :agent_slots),
             "default working copy must not carry :agent_slots — §3.8 retires the slot mechanism"

      assert wc == %{
               routing_rules: [],
               member_declarations: [],
               # Task #110 — durable SessionTemplate URI for cold-load
               # McpRegistry re-registration (the parent_template_uri).
               session_template_uri: nil,
               default_workspace_uri: nil,
               description: ""
             }
    end

    test "template_working_copy/1 returns the field, defaulting when key is absent (pre-PR-2 slice)" do
      # A fresh `create/1` state carries the field. `template_working_copy/1`
      # operates on the PERSISTENT slice (the `:state` sub-map post-Lifecycle).
      slice = SessionBehavior.init_slice(%{}).state

      assert SessionBehavior.template_working_copy(slice) ==
               SessionBehavior.default_template_working_copy()

      # A pre-PR-2 `:chat` slice has no `template_working_copy` key —
      # readers must still get the empty default, never crash.
      pre_pr2_slice = %{members: %{}, monitors: %{}, last_seen: %{}}
      refute Map.has_key?(pre_pr2_slice, :template_working_copy)

      assert SessionBehavior.template_working_copy(pre_pr2_slice) ==
               SessionBehavior.default_template_working_copy()
    end

    test "interface/0 declares the Session actions (:receive split out — PR-2)" do
      keys = SessionBehavior.interface() |> Map.keys() |> Enum.sort()
      # team-routing-unification §3.6 (PR-6) — :set_legends added;
      # §3.4/§3.7 (PR-7) — :set_prompt_templates added.
      # PR-2 (im/session/agent decomposition §OQ-4) — :receive removed
      # (now `user.receive` / `agent.receive`).
      # F7 PR-A — :remove_participant added (isomorphic participant removal).
      assert keys ==
               [
                 :approve_admission,
                 :assign_role,
                 :attach,
                 :composition_consent,
                 :deny_admission,
                 :join,
                 :leave,
                 :merge_member,
                 :remove_participant,
                 :send,
                 :set_legends,
                 :set_prompt_templates,
                 :set_working_copy,
                 :withdraw_admission
               ]
    end
  end

  describe "invoke(:send, ...) routing (Phase 3c-step 1)" do
    test "with no routing rules → falls through to in-session members fan-out" do
      session_uri =
        URI.new!(
          "session://team-alpha/default/chat-fallback-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")

      other_member =
        URI.new!("entity://team-alpha/user/other-#{System.unique_integer([:positive])}")

      msg = Message.new(sender, %{text: "no rules here", attachments: []})

      slice = %{
        members: %{sender => %{online: true}, other_member => %{online: true}},
        monitors: %{},
        last_seen: %{}
      }

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      # Just verify the invoke succeeds; Resolver returns [] (no rule),
      # so fall-through fan-outs to members minus sender. dispatch_receive
      # may return :error :no_such_actor for unregistered URIs but that's
      # fire-and-forget — invoke still {:ok, ...}.
      assert {:ok, _, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )
    end

    test "with active mention routing rule → respects rule receivers" do
      test_table = :"chat_routing_test_#{System.unique_integer([:positive])}"
      :ok = Ezagent.RoutingRegistry.declare_table(test_table, key_uniqueness: :duplicate)

      original = Application.get_env(:ezagent_core, :routing_tables)
      Application.put_env(:ezagent_core, :routing_tables, [test_table])

      on_exit(fn ->
        if original do
          Application.put_env(:ezagent_core, :routing_tables, original)
        else
          Application.delete_env(:ezagent_core, :routing_tables)
        end
      end)

      target_session =
        URI.new!("session://team-alpha/default/chat-routed-#{System.unique_integer([:positive])}")

      session_uri = URI.new!("session://team-alpha/default/current")
      bind_to_default(session_uri)
      bind_to_default(target_session)
      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "urgent help", attachments: []})

      :ok =
        Ezagent.RoutingRegistry.put(
          test_table,
          Ezagent.Routing.Matcher.text_contains("urgent"),
          [URI.to_string(target_session)]
        )

      slice = %{
        members: %{sender => %{online: true}},
        monitors: %{},
        last_seen: %{}
      }

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      # invoke fires routing path; recipients = [target_session] (per rule),
      # NOT the in-session member list. invoke still succeeds.
      assert {:ok, _, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )
    end

    test "hop-exhausted messages are stored but not routed and leave trace" do
      session_uri =
        URI.new!("session://team-alpha/default/chat-hop-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "loop stop", attachments: []}, hops: 0)

      slice = %{members: %{sender => %{online: true}}, monitors: %{}, last_seen: %{}}
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      assert {:ok, _, %{stored: true, dropped: :hop_exhausted}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )

      assert [%{rule_id: "no_match", hop: 0, drop_reason: "hop_exhausted"}] =
               Trace.journey(msg.id)
    end

    test "declarative hello chain routes by role, traces decisions, and keeps internal relay private" do
      test_table = :"hello_orchestration_m1_#{System.unique_integer([:positive])}"
      :ok = Ezagent.RoutingRegistry.declare_table(test_table, key_uniqueness: :duplicate)

      original = Application.get_env(:ezagent_core, :routing_tables)
      Application.put_env(:ezagent_core, :routing_tables, [test_table])

      on_exit(fn ->
        if original do
          Application.put_env(:ezagent_core, :routing_tables, original)
        else
          Application.delete_env(:ezagent_core, :routing_tables)
        end
      end)

      session_uri =
        URI.new!("session://team-alpha/default/hello-m1-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)

      viewer = URI.new!("entity://team-alpha/user/viewer")
      responser = URI.new!("entity://team-alpha/agent/responser")
      builder = URI.new!("entity://team-alpha/agent/builder")

      members = %{
        viewer => %{online: true, role_name: "viewer"},
        responser => %{online: true, role_name: "responser"},
        builder => %{online: true, role_name: "builder"}
      }

      :ok =
        Ezagent.RoutingRegistry.put(
          test_table,
          Matcher.from_role("viewer"),
          rule_value("viewer-to-responser", [Receiver.role("responser")])
        )

      :ok =
        Ezagent.RoutingRegistry.put(
          test_table,
          Matcher.all_of([
            Matcher.from_role("responser"),
            Matcher.text_matches("^\\[need-build\\]")
          ]),
          rule_value("responser-to-builder", [Receiver.role("builder")])
        )

      :ok =
        Ezagent.RoutingRegistry.put(
          test_table,
          Matcher.from_role("builder"),
          rule_value("builder-loop", [Receiver.role("responser")])
        )

      slice = %{members: members, monitors: %{}, last_seen: %{}}
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: viewer}

      viewer_msg = Message.new(viewer, %{text: "hello", attachments: []})

      assert {:ok, _slice, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: viewer_msg},
                 ctx
               )

      assert [%{rule_id: "viewer-to-responser", receivers: [responser_str], hop: 8}] =
               Trace.journey(viewer_msg.id)

      assert responser_str == URI.to_string(responser)

      relay_msg =
        Message.new(
          responser,
          %{text: "[need-build] render the page", attachments: []},
          visibility: :internal
        )

      assert {:ok, _slice, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: relay_msg},
                 ctx
               )

      assert [%{rule_id: "responser-to-builder", receivers: [builder_str], hop: 8}] =
               Trace.journey(relay_msg.id)

      assert builder_str == URI.to_string(builder)

      visible_texts =
        session_uri
        |> MessageStore.chat_visible_recent(10)
        |> Enum.map(& &1.body["text"])

      refute "[need-build] render the page" in visible_texts

      loop_msg =
        Message.new(builder, %{text: "loop", attachments: []}, hops: 0, visibility: :internal)

      assert {:ok, _slice, %{stored: true, dropped: :hop_exhausted}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: loop_msg},
                 ctx
               )

      assert [%{rule_id: "no_match", hop: 0, drop_reason: "hop_exhausted"}] =
               Trace.journey(loop_msg.id)
    end

    test "native agent matched by routing is not delivered to role receive" do
      test_table = :"native_no_receive_#{System.unique_integer([:positive])}"
      :ok = Ezagent.RoutingRegistry.declare_table(test_table, key_uniqueness: :duplicate)

      original = Application.get_env(:ezagent_core, :routing_tables)
      Application.put_env(:ezagent_core, :routing_tables, [test_table])

      on_exit(fn ->
        if original do
          Application.put_env(:ezagent_core, :routing_tables, original)
        else
          Application.delete_env(:ezagent_core, :routing_tables)
        end
      end)

      n = System.unique_integer([:positive])
      session_uri = URI.new!("session://team-alpha/default/native-no-receive-#{n}")
      bind_to_default(session_uri)

      viewer = URI.new!("entity://team-alpha/user/viewer-#{n}")
      native_agent = URI.new!("entity://team-alpha/agent/native-builder-#{n}")

      {:ok, _pid} =
        Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
          uri: native_agent,
          initial_caps:
            MapSet.new([
              signed_fixture_cap!(
                session_uri,
                :session,
                Ezagent.ActionSet.Session,
                :receive,
                native_agent
              )
            ])
        })

      :ok = Ezagent.AgentFlavorAttributes.put(native_agent, "native")
      on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(native_agent) end)

      handler_id = {__MODULE__, self(), make_ref()}

      :telemetry.attach(
        handler_id,
        [:ezagent, :agent_bridge, :deliver, :dropped],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:agent_bridge_dropped, metadata})
        end,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      :ok =
        Ezagent.RoutingRegistry.put(
          test_table,
          Matcher.from_role("viewer"),
          rule_value("viewer-to-native", [Receiver.role("builder")])
        )

      members = %{
        viewer => %{online: true, role_name: "viewer"},
        native_agent => %{online: true, role_name: "builder"}
      }

      msg = Message.new(viewer, %{text: "please rebuild", attachments: []})
      slice = %{members: members, monitors: %{}, last_seen: %{}}
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: viewer}

      assert {:ok, _slice, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )

      assert [%{rule_id: "viewer-to-native", receivers: [native_agent_str]}] =
               Trace.journey(msg.id)

      assert native_agent_str == URI.to_string(native_agent)

      assert_receive {:agent_bridge_dropped, %{recipient: ^native_agent, reason: reason}}, 500

      assert reason in [
               :no_sandbox_respawn_state,
               {:no_adapter, "native"},
               {:heal_failed, :no_sandbox_respawn_state}
             ]
    end
  end

  defp rule_value(rule_id, receivers) do
    %{
      receivers: receivers,
      applies_to_users: [],
      workspace_uri: nil,
      rule_id: rule_id,
      rule_set: "hello",
      prompt_template_ref: nil
    }
  end

  describe "invoke(:send, ...)" do
    test "writes to MessageStore + broadcasts on session events topic + returns {:ok, new_slice, %{stored: true}}" do
      session_uri =
        URI.new!("session://team-alpha/default/chat-test-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "hello world", attachments: []})

      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      topic = SessionBehavior.session_events_topic(session_uri)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      # PR-EM-6-PRE (Allen 2026-05-25) — `:send` now mutates the slice
      # (sets `:last_message_id` + `:last_message` + bumps
      # `:send_cursor`), so this is no longer a `^slice` pin match.
      # The bound `new_slice` shape is asserted below.
      assert {:ok, new_slice, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )

      # Slice mutation: id stamp + full message + cursor bump (the
      # three fields that make `new_slice != slice` for both first
      # send AND idempotent retry — see init_slice/1 doc HIGH-1+2).
      assert new_slice.last_message_id == msg.id
      assert %Message{id: id} = new_slice.last_message
      assert id == msg.id
      assert new_slice.send_cursor == 1

      # All other PERSISTENT fields unchanged from the fresh init.
      # (`:monitors` is no longer a persistent field — it's a transient,
      # and `:send` produces no monitor effect, so it is absent here.)
      assert new_slice.members == slice.members
      refute Map.has_key?(new_slice, :monitors)
      assert new_slice.last_seen == slice.last_seen
      assert new_slice.owner_uri == slice.owner_uri
      assert new_slice.template_working_copy == slice.template_working_copy

      # MessageStore now has it
      assert {:ok, loaded} = MessageStore.by_id(msg.id)
      assert loaded.session_uri == session_uri

      # Subscribers receive the chat_message broadcast
      assert_receive {:chat_message, _session_uri, %Message{id: stored_id}}, 500
      assert stored_id == msg.id
    end

    test "fan-out :receive on members when no mentions" do
      session_uri =
        URI.new!("session://team-alpha/default/chat-fanout-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")

      member_2 =
        URI.new!("entity://team-alpha/agent/test_test-bot-#{System.unique_integer([:positive])}")

      msg = Message.new(sender, %{text: "everyone hi", attachments: []})

      # Two members in slice (no Process.monitor needed for this test —
      # dispatch will fail :no_such_actor for the agent since it's not
      # registered, but that's the dispatch-level error, not invoke's).
      slice = %{
        members: %{sender => %{online: true}, member_2 => %{online: true}},
        monitors: %{},
        last_seen: %{}
      }

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      # invoke succeeds even if dispatch to absent member fails (cast
      # dispatch returns :ok or {:error, :no_such_actor} but we don't
      # consume the return — fan-out is fire-and-forget).
      assert {:ok, _new_slice, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )
    end

    test "returns error when MessageStore write fails (let-it-crash policy)" do
      # Force a write failure by giving the schema something it can't
      # encode (URI struct in a place that expects URI but is malformed).
      # Easiest: corrupt session_uri so the Ecto.URI dump branch hits
      # the catch-all. We pass an atom instead of %URI{} which dump
      # rejects with :error.
      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "boom", attachments: []})
      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: :not_a_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      assert_raise FunctionClauseError, fn ->
        EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
          Ezagent.ActionSet.Session,
          :send,
          slice,
          %{message: msg},
          ctx
        )
      end
    end
  end

  describe "invoke(:send, ...) — PR-EM-6-PRE slice mutation + SliceChange emit" do
    # PR-EM-6-PRE (Allen 2026-05-25) — SessionBehavior.send must mutate the :chat
    # slice so the SliceChange hook in `Kind.Runtime` fires per send.
    # This is the architectural seam external-mirror plugins ride on
    # after PR-EM-6 deletes the legacy `maybe_notify_external/3` path.
    # See `apps/ezagent_core/lib/ezagent/kind/runtime.ex` step 9.5 for
    # the `new_slice != slice` predicate that gates the event.

    test "fresh session has nil id, nil message, cursor 0" do
      slice = SessionBehavior.init_slice(%{}).state

      assert Map.has_key?(slice, :last_message_id)
      assert Map.has_key?(slice, :last_message)
      assert Map.has_key?(slice, :send_cursor)

      assert slice.last_message_id == nil
      assert slice.last_message == nil
      assert slice.send_cursor == 0
    end

    test "send → id stamp + full Message struct + cursor=1 (codex r1 HIGH-2 — adapters need the body)" do
      session_uri =
        URI.new!(
          "session://team-alpha/default/lmi-mutation-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "ping", attachments: []})

      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      assert {:ok, new_slice, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )

      assert is_binary(msg.id)
      assert new_slice.last_message_id == msg.id

      # HIGH-2: external-mirror adapters convert Publisher.Event →
      # payload purely (no DB lookup). The full Message must ride the
      # slice — with sender / body / mentions / inserted_at AND the
      # `:session_uri` that MessageStore.write stamps on persist.
      #
      # codex r2 HIGH (2026-05-25) — `MessageStore.write/2` returns
      # the ACTUALLY-PERSISTED row (not the caller's struct), so the
      # body field is JSON-roundtripped by ecto_sqlite3 (string keys).
      # Chat's `body_text/1` + `body_attachments/1` pattern-match both
      # shapes, so this is safe downstream; assert logical-identity
      # via the JSON shape here.
      assert %Message{} = new_slice.last_message
      assert new_slice.last_message.id == msg.id
      assert new_slice.last_message.sender == sender
      assert new_slice.last_message.body["text"] == "ping"
      assert new_slice.last_message.body["attachments"] == []
      assert new_slice.last_message.session_uri == session_uri

      # Cursor bumped from the initial 0
      assert new_slice.send_cursor == 1

      # The mutation is detectable by `new_slice != slice` — that's the
      # exact predicate `Ezagent.Kind.Runtime` uses to build the
      # slice_change_event payload (see runtime.ex step 9.5).
      refute new_slice == slice
    end

    test "send overwrites :last_message + :last_message_id and increments :send_cursor" do
      session_uri =
        URI.new!(
          "session://team-alpha/default/lmi-overwrite-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      msg1 = Message.new(sender, %{text: "first", attachments: []})
      msg2 = Message.new(sender, %{text: "second", attachments: []})
      # Sanity: independent message ids
      refute msg1.id == msg2.id

      slice = SessionBehavior.init_slice(%{}).state

      assert {:ok, slice1, _} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg1},
                 ctx
               )

      assert slice1.last_message_id == msg1.id
      assert slice1.last_message.id == msg1.id
      assert slice1.send_cursor == 1

      assert {:ok, slice2, _} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice1,
                 %{message: msg2},
                 ctx
               )

      assert slice2.last_message_id == msg2.id
      assert slice2.last_message.id == msg2.id
      assert slice2.send_cursor == 2
      refute slice2.last_message_id == msg1.id
    end

    # codex r1 HIGH-1 regression test (2026-05-25): retried sends of the
    # SAME msg.id MUST still produce a slice diff. MessageStore.write/2
    # uses `Repo.insert(_, on_conflict: :nothing, conflict_target: :id)`
    # at message_store.ex:86 — a resend of the same id is idempotent at
    # the DB layer (succeeds + returns the same struct). Without the
    # `:send_cursor` bump, `last_message_id` + `last_message` would be
    # byte-identical to the prior send and `new_slice != slice` would
    # be FALSE — Kind.Runtime would emit `nil` for slice_change_event,
    # external mirrors would silently miss the retry while in-session
    # subscribers still receive the dispatch.
    test "retry of same msg.id still mutates slice (HIGH-1 — :send_cursor guarantees diff)" do
      session_uri =
        URI.new!("session://team-alpha/default/lmi-retry-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      msg = Message.new(sender, %{text: "same payload, sent twice", attachments: []})

      slice = SessionBehavior.init_slice(%{}).state

      assert {:ok, slice1, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: msg},
                 ctx
               )

      assert slice1.last_message_id == msg.id
      assert slice1.send_cursor == 1

      # Resend the SAME msg (same id, same body, same sender).
      # MessageStore is idempotent on `(msg.id, session_uri)`; the
      # second invoke succeeds without crashing and still returns
      # `{:ok, _, %{stored: true}}`.
      assert {:ok, slice2, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice1,
                 %{message: msg},
                 ctx
               )

      # The id + message itself are byte-equal across the retry...
      assert slice2.last_message_id == slice1.last_message_id
      assert slice2.last_message.id == slice1.last_message.id

      # ...but the cursor MUST advance, so `slice2 != slice1` and
      # `Kind.Runtime` step 9.5 will build a non-nil slice_change_event.
      assert slice2.send_cursor == 2
      refute slice2 == slice1
    end

    # codex r2 HIGH regression test (2026-05-25): a misbehaving (or
    # adversarial) client that reuses a previously-persisted msg.id
    # with a DIFFERENT body must NOT cause `:last_message` to carry
    # the second body. MessageStore.write/2 is idempotent on id
    # conflict (`on_conflict: :nothing, conflict_target: :id`) but
    # now returns the actually-persisted row, so the slice always
    # reflects DB truth — external mirrors via SliceChange can never
    # publish content that isn't in `messages` for that id.
    test "duplicate msg.id with different body: :last_message reflects ORIGINAL DB row (codex r2 HIGH)" do
      session_uri =
        URI.new!("session://team-alpha/default/lmi-dup-id-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      original_body = %{text: "original truth", attachments: []}
      original = Message.new(sender, original_body)

      # Build a SECOND Message struct with the same id but a wholly
      # different body — simulating a misbehaving client.
      adversarial =
        %Message{original | body: %{text: "adversarial overwrite", attachments: []}}

      assert original.id == adversarial.id
      refute original.body == adversarial.body

      slice = SessionBehavior.init_slice(%{}).state

      # First send persists the original
      assert {:ok, slice1, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice,
                 %{message: original},
                 ctx
               )

      assert slice1.last_message_id == original.id
      assert slice1.last_message.body["text"] == "original truth"

      # Second send with same id but different body. MessageStore
      # treats the id as already-persisted (on_conflict: :nothing) and
      # returns the ORIGINAL row — :last_message in the new slice
      # MUST be the original row, not the adversarial one.
      assert {:ok, slice2, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 slice1,
                 %{message: adversarial},
                 ctx
               )

      assert slice2.last_message_id == original.id
      assert slice2.last_message.body["text"] == "original truth"
      refute slice2.last_message.body["text"] == "adversarial overwrite"

      # Send-cursor still bumps (HIGH-1: SliceChange must fire for the
      # retry even when last_message content is byte-identical to the
      # prior).
      assert slice2.send_cursor == 2

      # DB row matches what we put in the slice
      assert {:ok, persisted} = MessageStore.by_id(original.id)
      assert persisted.body["text"] == "original truth"
    end

    test "pre-PR-EM-6-PRE slice (none of the keys) gets all three on send" do
      # A pre-existing on-disk Session snapshot might carry a `:chat`
      # slice without any of the PR-EM-6-PRE keys. The invoke path
      # uses `Map.get/3` + `Map.put/3` so it covers both the fresh-init
      # shape (keys present at defaults) and the legacy shape (keys
      # absent). The cursor starts from 0 → 1 in either case.
      session_uri =
        URI.new!("session://team-alpha/default/lmi-legacy-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "legacy slice send", attachments: []})

      legacy_slice = %{members: %{}, monitors: %{}, last_seen: %{}}
      refute Map.has_key?(legacy_slice, :last_message_id)
      refute Map.has_key?(legacy_slice, :last_message)
      refute Map.has_key?(legacy_slice, :send_cursor)

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      assert {:ok, new_slice, %{stored: true}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :send,
                 legacy_slice,
                 %{message: msg},
                 ctx
               )

      assert new_slice.last_message_id == msg.id
      assert new_slice.last_message.id == msg.id
      assert new_slice.send_cursor == 1
    end

    test "SliceChange.emit fires on send (full Runtime path) and event carries last_message struct" do
      # End-to-end: drive the Chat behavior via Kind.Runtime so the
      # slice_change_event hook fires (per runtime.ex step 9.5). With
      # the three send-tracking fields mutated by `:send`, subscribers
      # should receive a `{:slice_changed, %{slice_key: :session, ...}}`
      # event carrying the full Message in `new_slice.last_message`
      # (HIGH-2 — adapters convert the event without DB lookups).
      # Without this PR's slice mutation, `new_slice == slice` and
      # the hook short-circuits with `nil` — no event reaches the
      # topic.

      Application.put_env(:ezagent_core, :slice_change_hook, true)
      on_exit(fn -> Application.delete_env(:ezagent_core, :slice_change_hook) end)

      session_uri =
        URI.new!(
          "session://team-alpha/default/lmi-slicechange-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)
      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "emit me", attachments: []})

      # Lifecycle migration: the Kind stores `:chat` as the two-container
      # `%{state, transients}` slice; seed that shape so the runtime's
      # handler-ctx builder reads persistent fields from `:state`.
      slice = SessionBehavior.init_slice(%{})

      # Subscribe to the entity's slice-changed topic. The hook fires
      # only via `Kind.Server.commit_and_notify/3` → `SliceChange.emit/1`
      # post-snapshot; we drive the full `Kind.Runtime.handle_dispatch/4`
      # path so the event shape matches production.
      Ezagent.SliceChange.subscribe_unverified(session_uri)
      on_exit(fn -> Ezagent.SliceChange.unsubscribe_unverified(session_uri) end)

      # Build a dispatch envelope identical to what `Invocation.dispatch/1`
      # would land in a Session GenServer's handle_call/cast.
      target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")

      inv =
        signed_invocation!(
          %Ezagent.Invocation{
            origin: :trusted_internal,
            target: target,
            mode: :cast,
            args: %{message: msg},
            ctx: %{
              caller: sender,
              caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
              reply: :ignore
            }
          },
          :session
        )

      # Initial state: just the :chat slice. Runtime defaults missing
      # slices to %{}, so we only need to seed this one.
      # P5-0b: Session requires a non-nil :kind_base; the instance_set_gate
      # reads it via effective_set/2. Seed an explicit set alongside :chat.
      initial_state = %{
        session: slice,
        kind_base: %{state: %{behaviors: Ezagent.Entity.Session.behaviors()}, transients: %{}}
      }

      assert {:ok, new_state, _result, slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(
                 inv,
                 initial_state,
                 Ezagent.Entity.Session,
                 session_uri
               )

      # Runtime built the event (proves new_slice != slice)
      assert is_map(slice_change_event)
      assert slice_change_event.slice_key == :session
      assert slice_change_event.action == :send
      assert slice_change_event.kind_module == Ezagent.Entity.Session

      # All three send-tracking fields carry across in `new_slice` and
      # are at their pre-send defaults in `old_slice`. Post-Lifecycle the
      # slice is two-container; the persistent fields live under `.state`.
      assert slice_change_event.new_slice.state.last_message_id == msg.id
      assert slice_change_event.new_slice.state.last_message.id == msg.id
      assert slice_change_event.new_slice.state.last_message.sender == sender
      assert slice_change_event.new_slice.state.last_message.session_uri == session_uri
      assert slice_change_event.new_slice.state.send_cursor == 1

      assert slice_change_event.old_slice.state.last_message_id == nil
      assert slice_change_event.old_slice.state.last_message == nil
      assert slice_change_event.old_slice.state.send_cursor == 0

      # State carries the mutated slice
      assert new_state.session.state.last_message_id == msg.id
      assert new_state.session.state.last_message.id == msg.id
      assert new_state.session.state.send_cursor == 1

      # Fire emit directly the same way Kind.Server.commit_and_notify/3
      # does post-snapshot — and assert subscribers receive the event.
      #
      # `SliceChange.emit/1` takes the fat producer event but broadcasts
      # the SECURITY-MINIMAL 5-key envelope (codex PR-N3 r2 HIGH-1 —
      # slice content never crosses PubSub; locked by
      # slice_change_event_carries_no_slice_content_test.exs). Subscribers
      # receive that minimal shape, NOT the fat event; the slice diff
      # asserted above is the producer-side value, not what's broadcast.
      :ok = Ezagent.SliceChange.emit(slice_change_event)

      assert_receive {:slice_changed,
                      %{
                        uri: ^session_uri,
                        slice_key: :session,
                        cursor: cursor,
                        event_at: %DateTime{},
                        result_summary: :ok
                      }},
                     500

      assert is_integer(cursor) and cursor > 0
    end
  end

  describe "user.receive — Behavior.User.Receive" do
    # PR-N3 (SPEC v2 notification-architecture-v2 §2.4 + §3, Allen
    # 2026-05-25) replaced the legacy raw `{:message_received, msg}`
    # broadcast on `esr:user:<uri>:events` with the PRODUCER pattern:
    # `user.receive` just mutates its `:session` slice (`:last_received`
    # + the cursor-indexed `:recent_messages` ring), and the runtime
    # emits the slice-change event post-commit via SliceChange.emit/1.
    # The handler itself does NO broadcast — the slice mutation IS the
    # notification.
    #
    # PR-2 (im/session/agent decomposition §OQ-4): this is now the
    # first-class `Ezagent.ActionSet.User.Receive`, NOT a branch inside
    # `Ezagent.ActionSet.Session`.
    test "mutates the receive slice (:last_received + :recent_messages ring)" do
      user_uri =
        URI.new!("entity://team-alpha/user/admin-recv-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://team-alpha/agent/test_cc-builder")
      msg = Message.new(sender, %{text: "reply incoming", attachments: []})

      slice = %{}

      ctx =
        with_member_cap(%{self_uri: user_uri, kind_module: Ezagent.Entity.User, caller: sender})

      assert {:ok, new_slice} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.User.Receive,
                 :receive,
                 slice,
                 %{message: msg},
                 ctx
               )

      assert new_slice.last_received.message_id == msg.id
      assert match?(%DateTime{}, new_slice.last_received.at)
      assert [{_cursor, rid} | _] = new_slice.recent_messages
      assert rid == msg.id
    end

    test "state_slice is :session (no snapshot migration — shares the User Kind slice key)" do
      assert Ezagent.ActionSet.User.Receive.state_slice() == :session
    end
  end

  describe "agent.receive — Behavior.Agent.Receive" do
    # PR-2 (im/session/agent decomposition §OQ-4): the Agent delivery
    # path is now the first-class `Ezagent.ActionSet.Agent.Receive`, NOT a
    # branch inside `Ezagent.ActionSet.Session`. Delivery mechanics still
    # live in the shared `Session.Delivery.deliver_agent_receive/2` helper.
    test "returns {:ok, slice} unchanged (Agent has no chat slice state)" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/cc_builder-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://system/user/admin")
      msg = Message.new(sender, %{text: "hi agent", attachments: []})

      slice = %{}

      ctx =
        with_member_cap(%{self_uri: agent_uri, kind_module: Ezagent.Entity.Agent, caller: sender})

      assert {:ok, ^slice} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Agent.Receive,
                 :receive,
                 slice,
                 %{message: msg},
                 ctx
               )
    end

    # PR 26 (2026-05-18): the channels-reference protocol declares
    # `meta: Record<string, string>` — every value MUST be a string,
    # otherwise claude TUI silently drops the entire notification.
    # PR 14 violated this by stamping a list under `meta.attachments`,
    # which broke the inbound path for ~3 weeks before discovery.

    test "to_claude payload meta values are all strings (no list/map smuggling)" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/cc_meta-string-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://system/user/admin")

      session_uri =
        URI.new!("session://team-alpha/default/meta-#{System.unique_integer([:positive])}")

      msg = Message.new(sender, %{text: "plain text", attachments: []})

      :ok = Ezagent.AgentBridge.Registry.bind(agent_uri, self())
      :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "cc")

      on_exit(fn ->
        Ezagent.AgentBridge.Registry.unbind(agent_uri)
        Ezagent.AgentFlavorAttributes.delete(agent_uri)
      end)

      ctx =
        with_member_cap(%{
          self_uri: agent_uri,
          kind_module: Ezagent.Entity.Agent,
          caller: session_uri
        })

      EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
        Ezagent.ActionSet.Agent.Receive,
        :receive,
        %{},
        %{message: msg},
        ctx
      )

      assert_receive {:agent_bridge_push, "to_claude", %{"content" => content, "meta" => meta}},
                     500

      assert is_binary(content)
      assert content == "plain text"

      for {k, v} <- meta do
        assert is_binary(k), "meta key not string: #{inspect(k)}"

        assert is_binary(v),
               "meta value for key #{inspect(k)} is not string: #{inspect(v)}"
      end

      assert Map.has_key?(meta, "sender")
      assert Map.has_key?(meta, "message_id")
      assert Map.has_key?(meta, "session")
      refute Map.has_key?(meta, "file_path")
    end

    test "attachment → meta.file_path is the first attachment's local_path string" do
      agent_uri =
        URI.new!("entity://team-alpha/agent/cc_meta-att-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://system/user/admin")

      session_uri =
        URI.new!("session://team-alpha/default/meta-att-#{System.unique_integer([:positive])}")

      msg =
        Message.new(sender, %{
          text: "see file",
          attachments: [
            %{type: "file", name: "a.txt", local_path: "/tmp/a.txt"},
            %{type: "image", name: "b.png", local_path: "/tmp/b.png"}
          ]
        })

      :ok = Ezagent.AgentBridge.Registry.bind(agent_uri, self())
      :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "cc")

      on_exit(fn ->
        Ezagent.AgentBridge.Registry.unbind(agent_uri)
        Ezagent.AgentFlavorAttributes.delete(agent_uri)
      end)

      ctx =
        with_member_cap(%{
          self_uri: agent_uri,
          kind_module: Ezagent.Entity.Agent,
          caller: session_uri
        })

      EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
        Ezagent.ActionSet.Agent.Receive,
        :receive,
        %{},
        %{message: msg},
        ctx
      )

      assert_receive {:agent_bridge_push, "to_claude", %{"content" => content, "meta" => meta}},
                     500

      assert content =~ "see file"
      assert content =~ "name=a.txt"
      assert content =~ "name=b.png"

      # Mirrors cc-openclaw channel_server convention: one file per
      # notification; first attachment wins meta.file_path.
      assert meta["file_path"] == "/tmp/a.txt"

      for {_k, v} <- meta, do: assert(is_binary(v))
    end

    test "attachment with string-keyed body (post-DB roundtrip) still produces file_path" do
      # MessageStore stores body as JSON → Ecto load returns string keys.
      # body_attachments + first_attachment_path must tolerate either shape.
      agent_uri =
        URI.new!(
          "entity://team-alpha/agent/cc_meta-stringkey-#{System.unique_integer([:positive])}"
        )

      sender = URI.new!("entity://system/user/admin")

      session_uri =
        URI.new!(
          "session://team-alpha/default/meta-stringkey-#{System.unique_integer([:positive])}"
        )

      string_keyed_body = %{
        "text" => "from db",
        "attachments" => [%{"type" => "file", "name" => "x", "local_path" => "/tmp/x.txt"}]
      }

      msg = %Message{
        Message.new(sender, %{text: "stub", attachments: []})
        | body: string_keyed_body
      }

      :ok = Ezagent.AgentBridge.Registry.bind(agent_uri, self())
      :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "cc")

      on_exit(fn ->
        Ezagent.AgentBridge.Registry.unbind(agent_uri)
        Ezagent.AgentFlavorAttributes.delete(agent_uri)
      end)

      ctx =
        with_member_cap(%{
          self_uri: agent_uri,
          kind_module: Ezagent.Entity.Agent,
          caller: session_uri
        })

      EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
        Ezagent.ActionSet.Agent.Receive,
        :receive,
        %{},
        %{message: msg},
        ctx
      )

      assert_receive {:agent_bridge_push, "to_claude", %{"content" => content, "meta" => meta}},
                     500

      assert content =~ "from db"
      assert meta["file_path"] == "/tmp/x.txt"
      for {_k, v} <- meta, do: assert(is_binary(v))
    end
  end

  describe "invoke(:join, ...)" do
    test "Process.monitor target Kind + add to members + returns members list" do
      session_uri =
        URI.new!("session://team-alpha/default/join-#{System.unique_integer([:positive])}")

      member_uri =
        URI.new!("entity://team-alpha/user/transient-#{System.unique_integer([:positive])}")

      # Spawn a minimal GenServer to play the member role; it self-registers
      # so KindRegistry.lookup returns ITS pid (the Registry's owner-pid).
      {:ok, member_pid} = GenServer.start_link(__MODULE__.NoopServer, member_uri)

      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: member_uri}

      assert {:ok, new_slice, %{members: [^member_uri]}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :join,
                 slice,
                 %{member: member_uri},
                 ctx
               )

      assert Map.has_key?(new_slice.members, member_uri)
      assert new_slice.members[member_uri].online == true
      assert map_size(new_slice.monitors) == 1
      [{ref, ^member_uri}] = Map.to_list(new_slice.monitors)
      assert is_reference(ref)

      GenServer.stop(member_pid)
    end

    test "returns error when member URI not in KindRegistry" do
      session_uri =
        URI.new!(
          "session://team-alpha/default/join-missing-#{System.unique_integer([:positive])}"
        )

      missing_uri =
        URI.new!("entity://team-alpha/user/does-not-exist-#{System.unique_integer([:positive])}")

      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: missing_uri}

      assert {:error, {:member_not_registered, ^missing_uri}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :join,
                 slice,
                 %{member: missing_uri},
                 ctx
               )
    end

    test "RF-6: a PASSIVE data actor is REJECTED from :join even when registered" do
      # A passive (non-principal) data actor must never become a session MEMBER —
      # membership is the chat-principal grant. The gate fires BEFORE
      # KindRegistry.lookup/monitor, so the passive actor never enters
      # slice.members. Register a live pid + mark it passive to prove the
      # rejection is the passive gate (not a missing-registration fallthrough).
      session_uri =
        URI.new!(
          "session://team-alpha/default/join-passive-#{System.unique_integer([:positive])}"
        )

      passive_uri =
        URI.new!("entity://team-alpha/agent/kanban_board-#{System.unique_integer([:positive])}")

      {:ok, member_pid} = GenServer.start_link(__MODULE__.NoopServer, passive_uri)
      on_exit(fn -> if Process.alive?(member_pid), do: GenServer.stop(member_pid) end)

      on_exit(fn -> Ezagent.AgentPassiveAttributes.delete(passive_uri) end)
      :ok = Ezagent.AgentPassiveAttributes.put(passive_uri, true)

      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: passive_uri}

      assert {:error, {:passive_actor_cannot_join, ^passive_uri}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :join,
                 slice,
                 %{member: passive_uri},
                 ctx
               )
    end

    test "RF-6 regression: a NORMAL (non-passive) agent still joins" do
      session_uri =
        URI.new!("session://team-alpha/default/join-normal-#{System.unique_integer([:positive])}")

      normal_uri =
        URI.new!("entity://team-alpha/agent/cc_worker-#{System.unique_integer([:positive])}")

      {:ok, member_pid} = GenServer.start_link(__MODULE__.NoopServer, normal_uri)
      on_exit(fn -> if Process.alive?(member_pid), do: GenServer.stop(member_pid) end)

      # No passive attribute stored → principal actor → joins normally.
      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: normal_uri}

      assert {:ok, new_slice, %{members: [^normal_uri]}} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :join,
                 slice,
                 %{member: normal_uri},
                 ctx
               )

      assert Map.has_key?(new_slice.members, normal_uri)
    end

    test "notifies the joinee when member is a user URI (todo.md notification coverage)" do
      # med-batch MED-3 — :join must emit a `:session_member_joined`
      # notification to the joinee's inbox so a freshly-added member
      # learns they were added to a session. Gated by user_uri?/1:
      # only user URIs get notifications (agents have no inbox).
      session_uri =
        URI.new!("session://team-alpha/default/join-notify-#{System.unique_integer([:positive])}")

      member_uri =
        URI.new!("entity://team-alpha/user/notify-#{System.unique_integer([:positive])}")

      :ok = Ezagent.Notifications.subscribe(member_uri)

      {:ok, member_pid} = GenServer.start_link(__MODULE__.NoopServer, member_uri)

      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: member_uri}

      assert {:ok, _slice, _result} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :join,
                 slice,
                 %{member: member_uri},
                 ctx
               )

      assert_receive {:notification, ^member_uri,
                      %{
                        type: :session_member_joined,
                        body: %{text: text, session_uri: ^session_uri},
                        source: Ezagent.ActionSet.Session
                      }},
                     1_000

      assert is_binary(text)

      GenServer.stop(member_pid)
    end

    test "does NOT notify when member is an agent URI" do
      # Agents have no inbox — the gate must filter them out, mirroring
      # the `Workspace.add_member` precedent. Test by subscribing to the
      # agent URI's inbox (works structurally) and asserting no msg
      # arrives.
      session_uri =
        URI.new!("session://team-alpha/default/join-agent-#{System.unique_integer([:positive])}")

      agent_uri =
        URI.new!("entity://team-alpha/agent/cc_notify-#{System.unique_integer([:positive])}")

      # Subscribe directly to the topic (agent URI Notifications.subscribe
      # would reject because Notifications is user-only; bypass via
      # raw PubSub to detect any stray broadcast).
      :ok =
        Phoenix.PubSub.subscribe(
          EzagentCore.PubSub,
          Ezagent.Notifications.topic(agent_uri)
        )

      {:ok, agent_pid} = GenServer.start_link(__MODULE__.NoopServer, agent_uri)

      slice = SessionBehavior.init_slice(%{}).state
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: agent_uri}

      assert {:ok, _slice, _result} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :join,
                 slice,
                 %{member: agent_uri},
                 ctx
               )

      refute_receive {:notification, ^agent_uri, _}, 200

      GenServer.stop(agent_pid)
    end

    test "replays missed messages on rejoin (last_seen populated)" do
      session_uri =
        URI.new!("session://team-alpha/default/replay-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)

      member_uri =
        URI.new!("entity://team-alpha/user/rejoin-#{System.unique_integer([:positive])}")

      sender = URI.new!("entity://team-alpha/user/other")

      # Persist 2 messages in the session before "rejoin"
      base = ~U[2026-05-16 09:00:00.000000Z]

      _m1 =
        Message.new(sender, %{text: "missed-1", attachments: []},
          inserted_at: DateTime.add(base, 60, :second)
        )
        |> MessageStore.write(session_uri)

      _m2 =
        Message.new(sender, %{text: "missed-2", attachments: []},
          inserted_at: DateTime.add(base, 120, :second)
        )
        |> MessageStore.write(session_uri)

      # Start a member that will receive replayed messages
      {:ok, member_pid} = GenServer.start_link(__MODULE__.NoopServer, member_uri)

      # Slice has last_seen at `base` — both messages are strictly after.
      slice = %{members: %{}, monitors: %{}, last_seen: %{member_uri => base}}
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: member_uri}

      assert {:ok, new_slice, _} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :join,
                 slice,
                 %{member: member_uri},
                 ctx
               )

      # last_seen for this member is cleared
      refute Map.has_key?(new_slice.last_seen, member_uri)

      GenServer.stop(member_pid)
    end
  end

  describe "invoke(:leave, ...)" do
    test "drops member + demonitors + clears last_seen" do
      session_uri =
        URI.new!("session://team-alpha/default/leave-#{System.unique_integer([:positive])}")

      member_uri =
        URI.new!("entity://team-alpha/user/leaver-#{System.unique_integer([:positive])}")

      ref = make_ref()

      slice = %{
        members: %{member_uri => %{online: true}},
        monitors: %{ref => member_uri},
        last_seen: %{member_uri => DateTime.utc_now()}
      }

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: member_uri}

      assert {:ok, new_slice} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke(
                 Ezagent.ActionSet.Session,
                 :leave,
                 slice,
                 %{member: member_uri},
                 ctx
               )

      refute Map.has_key?(new_slice.members, member_uri)
      refute Map.has_key?(new_slice.monitors, ref)
      refute Map.has_key?(new_slice.last_seen, member_uri)
    end
  end

  describe "invoke(:merge_member, ...)" do
    test "joins the login user, removes anon, rewrites last_message, and repoints read markers" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/merge-fresh-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)

      anon_uri =
        Ezagent.URI.new!("entity://team-alpha/user/anon-#{System.unique_integer([:positive])}")

      login_uri =
        Ezagent.URI.new!("entity://team-alpha/user/login-#{System.unique_integer([:positive])}")

      other_uri =
        Ezagent.URI.new!("entity://team-alpha/user/other-#{System.unique_integer([:positive])}")

      {:ok, login_pid} = GenServer.start_link(__MODULE__.NoopServer, login_uri)

      last_message =
        Message.new(anon_uri, %{text: "anon footprint", attachments: []},
          mentions: [anon_uri, other_uri]
        )

      msg_id =
        Message.new(other_uri, %{text: "seen", attachments: []})
        |> MessageStore.write(session_uri)
        |> then(fn {:ok, msg} -> msg.id end)

      assert {:ok, :updated} =
               Ezagent.Session.ReadMarker.mark(session_uri, anon_uri, msg_id, :read)

      anon_ref = make_ref()

      slice = %{
        members: %{anon_uri => %{online: true, role_name: "visitor"}},
        monitors: %{anon_ref => anon_uri},
        last_seen: %{anon_uri => ~U[2026-06-21 01:00:00.000000Z]},
        owner_uri: other_uri,
        last_message: last_message,
        last_message_id: last_message.id
      }

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: login_uri}

      assert {:ok, new_slice, %{members: members}, effects} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke_with_effects(
                 Ezagent.ActionSet.Session,
                 :merge_member,
                 slice,
                 %{from: anon_uri, to: login_uri},
                 ctx
               )

      refute Map.has_key?(new_slice.members, anon_uri)
      assert %{online: true} = new_slice.members[login_uri]
      assert login_uri in members
      refute anon_uri in members
      refute Map.has_key?(new_slice.monitors, anon_ref)
      refute Map.has_key?(new_slice.last_seen, anon_uri)
      assert new_slice.owner_uri == other_uri
      assert new_slice.last_message.sender == login_uri
      assert new_slice.last_message.mentions == [login_uri, other_uri]
      assert Ezagent.Session.ReadMarker.last_read(session_uri, login_uri, :read) == msg_id
      assert Ezagent.Session.ReadMarker.last_read(session_uri, anon_uri, :read) == nil

      assert Enum.any?(
               effects,
               &match?(
                 {:notify, _,
                  {:session_membership_change, ^session_uri, {:member_left, ^anon_uri}}},
                 &1
               )
             )

      assert Enum.any?(
               effects,
               &match?(
                 {:notify, _,
                  {:session_membership_change, ^session_uri, {:member_joined, ^login_uri}}},
                 &1
               )
             )

      GenServer.stop(login_pid)
    end

    test "dedupes when login user is already a member and is idempotent on re-run" do
      session_uri =
        Ezagent.URI.new!(
          "session://team-alpha/default/merge-dedup-#{System.unique_integer([:positive])}"
        )

      bind_to_default(session_uri)

      anon_uri =
        Ezagent.URI.new!("entity://team-alpha/user/anon-#{System.unique_integer([:positive])}")

      login_uri =
        Ezagent.URI.new!("entity://team-alpha/user/login-#{System.unique_integer([:positive])}")

      {:ok, login_pid} = GenServer.start_link(__MODULE__.NoopServer, login_uri)

      slice = %{
        members: %{
          anon_uri => %{online: false},
          login_uri => %{online: true, role_name: "confirmed"}
        },
        monitors: %{},
        last_seen: %{anon_uri => ~U[2026-06-21 01:00:00.000000Z]},
        owner_uri: login_uri,
        last_message: Message.new(anon_uri, %{text: "hi", attachments: []}, mentions: [anon_uri]),
        last_message_id: "m-last"
      }

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: login_uri}

      assert {:ok, merged, _result, _effects} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke_with_effects(
                 Ezagent.ActionSet.Session,
                 :merge_member,
                 slice,
                 %{from: anon_uri, to: login_uri},
                 ctx
               )

      assert Map.keys(merged.members) == [login_uri]
      assert merged.members[login_uri].role_name == "confirmed"
      assert merged.last_message.sender == login_uri
      assert merged.last_message.mentions == [login_uri]

      assert {:ok, rerun, _result, _effects} =
               EzagentDomainInstanceMessage.Test.BehaviorInvoker.invoke_with_effects(
                 Ezagent.ActionSet.Session,
                 :merge_member,
                 merged,
                 %{from: anon_uri, to: login_uri},
                 ctx
               )

      assert Map.keys(rerun.members) == [login_uri]
      assert rerun.members[login_uri].role_name == "confirmed"
      assert rerun.last_message.sender == login_uri
      assert rerun.last_message.mentions == [login_uri]

      GenServer.stop(login_pid)
    end
  end

  # Lifecycle migration (SPEC 2026-05-29 §2.3C) — `handle_kind_message/3`
  # is now macro-emitted; the developer hook is `handle_signal/2`, which
  # returns the same effect list a handler does. `:monitors` is a
  # TRANSIENT: the signal reads it from `ctx.transients[:monitors]` and
  # drops the dead ref via `{:set_transient, :monitors, _}`; the offline
  # flip + last_seen are persisted via `{:set, _, _}`.
  describe "handle_signal/2 (:DOWN forwarder)" do
    test "marks member offline + records last_seen + drops dead monitor ref (transient)" do
      member_uri =
        URI.new!("entity://team-alpha/user/crashed-#{System.unique_integer([:positive])}")

      ref = make_ref()

      members = %{member_uri => %{online: true}}

      ctx = %{
        self_uri: URI.new!("session://team-alpha/default/x"),
        kind_module: Ezagent.Entity.Session,
        read: fn key, default -> %{members: members, last_seen: %{}}[key] || default end,
        transients: %{monitors: %{ref => member_uri}}
      }

      down_msg = {:DOWN, ref, :process, self(), :normal}

      assert {:ok, effects} = SessionBehavior.handle_signal(down_msg, ctx)

      # member flipped offline (persisted :set)
      assert Enum.any?(effects, fn
               {:set, :members, m} -> m[member_uri].online == false
               _ -> false
             end)

      # last_seen recorded (persisted :set)
      assert Enum.any?(effects, fn
               {:set, :last_seen, ls} -> match?(%DateTime{}, ls[member_uri])
               _ -> false
             end)

      # dead ref dropped from the TRANSIENT monitors map (:set_transient)
      assert Enum.any?(effects, fn
               {:set_transient, :monitors, mons} -> not Map.has_key?(mons, ref)
               _ -> false
             end)
    end

    test "ignores unknown refs" do
      ctx = %{
        self_uri: URI.new!("session://team-alpha/default/y"),
        kind_module: Ezagent.Entity.Session,
        read: fn _key, default -> default end,
        transients: %{monitors: %{}}
      }

      assert :ignore =
               SessionBehavior.handle_signal({:DOWN, make_ref(), :process, self(), :normal}, ctx)
    end

    test "ignores non-:DOWN messages" do
      ctx = %{
        self_uri: URI.new!("session://team-alpha/default/z"),
        kind_module: Ezagent.Entity.Session,
        read: fn _key, default -> default end,
        transients: %{monitors: %{}}
      }

      assert :ignore = SessionBehavior.handle_signal(:tick, ctx)
      assert :ignore = SessionBehavior.handle_signal({:any, "thing"}, ctx)
    end
  end

  describe "interface schema validates real Message envelope" do
    test ":send action's message schema accepts a fully-formed Message" do
      sender = URI.new!("entity://system/user/admin")

      message =
        sender
        |> Message.new(%{text: "hi", attachments: []})
        |> Map.from_struct()

      schema = SessionBehavior.interface()[:send].args
      assert :ok = InterfaceValidator.validate(%{message: message}, schema)
    end

    test ":join args schema accepts URI member, rejects string" do
      schema = SessionBehavior.interface()[:join].args

      assert :ok =
               InterfaceValidator.validate(
                 %{member: URI.new!("entity://system/user/admin")},
                 schema
               )

      assert {:error, {:invalid_args, _}} =
               InterfaceValidator.validate(%{member: "entity://system/user/admin"}, schema)
    end
  end

  # --- Test support ------------------------------------------------------

  defmodule NoopServer do
    @moduledoc false
    use GenServer

    @impl true
    def init(uri) do
      :ok = Ezagent.KindRegistry.put_new(uri)
      {:ok, %{}}
    end
  end
end
