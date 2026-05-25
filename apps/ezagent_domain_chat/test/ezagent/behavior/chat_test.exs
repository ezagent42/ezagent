defmodule Ezagent.Behavior.ChatTest do
  @moduledoc """
  Phase 2b-step 2: Chat Behavior full invoke clause tests.

  Direct invoke/4 unit tests with crafted slices + ctx (no live
  KindRegistry / PubSub setup besides what the umbrella starts).
  Integration coverage (full dispatch path through Session GenServer
  + admin User membership) lives in
  `EzagentDomainChat.Integration.ChatRoutingTest`.
  """

  use ExUnit.Case
  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Behavior.Chat
  alias Ezagent.InterfaceValidator
  alias EzagentCore.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # Phase 9 PR-6 — `MessageStore.write/2` requires the session to be
  # bound to a workspace via WorkspaceRegistry (invariant 4 + SPEC v3
  # §7). Helper binds + queues teardown so tests calling Chat.invoke(:send)
  # or :join don't hit the "no workspace binding" raise.
  defp bind_to_default(session_uri) do
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://team-alpha"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  describe "Behavior contract surface" do
    test "actions/0 returns the K-path actions + the working-copy writer" do
      # Phase 7 completion PR-4 (SPEC §1.6) — `:set_working_copy` joins
      # the four K-path actions: the Generator + the orchestrator slot
      # tools write the durable `template_working_copy` field through it.
      assert Chat.actions() == [:send, :receive, :join, :leave, :set_working_copy]
    end

    test "state_slice/0 returns :chat" do
      assert Chat.state_slice() == :chat
    end

    test "init_slice/1 returns slice with all PR-EM-6-PRE fields + empty template_working_copy" do
      # Phase 7 completion PR-2 — the `:chat` slice now also carries
      # the durable `template_working_copy` field (SPEC §1.3 / §1.6).
      #
      # PR-EM-6-PRE (Allen 2026-05-25) — fresh sessions have three
      # send-tracking fields at their identity defaults
      # (`:last_message_id == nil`, `:last_message == nil`,
      # `:send_cursor == 0`). All three are necessary: ids cover the
      # stable cross-reference, the struct carries adapter-facing
      # body/sender data without DB lookups (HIGH-2), the cursor
      # guarantees `new_slice != slice` for retried sends with
      # idempotent msg.id writes (HIGH-1).
      #
      # `:owner_uri` defaults to `Map.get(args, :owner_uri)` = `nil`
      # for arg-less init (PR-OWN-2 introduced the field; the
      # original assertion in this test was stale and missed it).
      assert Chat.init_slice(%{}) == %{
               members: %{},
               owner_uri: nil,
               monitors: %{},
               last_seen: %{},
               last_message_id: nil,
               last_message: nil,
               send_cursor: 0,
               template_working_copy: Chat.default_template_working_copy()
             }
    end

    test "default_template_working_copy/0 is the empty template-shaped record (PR-2)" do
      assert Chat.default_template_working_copy() == %{
               agent_slots: [],
               routing_rules: [],
               orchestrator_template_uri: nil,
               default_workspace_uri: nil,
               description: ""
             }
    end

    test "template_working_copy/1 returns the field, defaulting when key is absent (pre-PR-2 slice)" do
      # A fresh `init_slice/1` carries the field.
      slice = Chat.init_slice(%{})
      assert Chat.template_working_copy(slice) == Chat.default_template_working_copy()

      # A pre-PR-2 `:chat` slice has no `template_working_copy` key —
      # readers must still get the empty default, never crash.
      pre_pr2_slice = %{members: %{}, monitors: %{}, last_seen: %{}}
      refute Map.has_key?(pre_pr2_slice, :template_working_copy)
      assert Chat.template_working_copy(pre_pr2_slice) == Chat.default_template_working_copy()
    end

    test "interface/0 declares all 5 actions" do
      keys = Chat.interface() |> Map.keys() |> Enum.sort()
      assert keys == [:join, :leave, :receive, :send, :set_working_copy]
    end
  end

  describe "invoke(:send, ...) routing (Phase 3c-step 1)" do
    test "with no routing rules → falls through to in-session members fan-out" do
      session_uri = URI.new!("session://default/team-alpha/chat-fallback-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      other_member = URI.new!("entity://user/team-alpha/other-#{System.unique_integer([:positive])}")
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
      assert {:ok, _, %{stored: true}} = Chat.invoke(:send, slice, %{message: msg}, ctx)
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

      target_session = URI.new!("session://default/team-alpha/chat-routed-#{System.unique_integer([:positive])}")
      session_uri = URI.new!("session://default/team-alpha/current")
      bind_to_default(session_uri)
      bind_to_default(target_session)
      sender = URI.new!("entity://user/system/admin")
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
      assert {:ok, _, %{stored: true}} = Chat.invoke(:send, slice, %{message: msg}, ctx)
    end
  end

  describe "invoke(:send, ...)" do
    test "writes to MessageStore + broadcasts on session events topic + returns {:ok, new_slice, %{stored: true}}" do
      session_uri = URI.new!("session://default/team-alpha/chat-test-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      msg = Message.new(sender, %{text: "hello world", attachments: []})

      slice = Chat.init_slice(%{})
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      topic = Chat.session_events_topic(session_uri)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      # PR-EM-6-PRE (Allen 2026-05-25) — `:send` now mutates the slice
      # (sets `:last_message_id` + `:last_message` + bumps
      # `:send_cursor`), so this is no longer a `^slice` pin match.
      # The bound `new_slice` shape is asserted below.
      assert {:ok, new_slice, %{stored: true}} =
               Chat.invoke(:send, slice, %{message: msg}, ctx)

      # Slice mutation: id stamp + full message + cursor bump (the
      # three fields that make `new_slice != slice` for both first
      # send AND idempotent retry — see init_slice/1 doc HIGH-1+2).
      assert new_slice.last_message_id == msg.id
      assert %Message{id: id} = new_slice.last_message
      assert id == msg.id
      assert new_slice.send_cursor == 1

      # All other fields unchanged from the fresh init
      assert new_slice.members == slice.members
      assert new_slice.monitors == slice.monitors
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
      session_uri = URI.new!("session://default/team-alpha/chat-fanout-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      member_2 = URI.new!("entity://agent/team-alpha/test_test-bot-#{System.unique_integer([:positive])}")
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
               Chat.invoke(:send, slice, %{message: msg}, ctx)
    end

    test "returns error when MessageStore write fails (let-it-crash policy)" do
      # Force a write failure by giving the schema something it can't
      # encode (URI struct in a place that expects URI but is malformed).
      # Easiest: corrupt session_uri so the Ecto.URI dump branch hits
      # the catch-all. We pass an atom instead of %URI{} which dump
      # rejects with :error.
      sender = URI.new!("entity://user/system/admin")
      msg = Message.new(sender, %{text: "boom", attachments: []})
      slice = Chat.init_slice(%{})
      ctx = %{self_uri: :not_a_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      assert_raise FunctionClauseError, fn ->
        Chat.invoke(:send, slice, %{message: msg}, ctx)
      end
    end
  end

  describe "invoke(:send, ...) — PR-EM-6-PRE slice mutation + SliceChange emit" do
    # PR-EM-6-PRE (Allen 2026-05-25) — Chat.send must mutate the :chat
    # slice so the SliceChange hook in `Kind.Runtime` fires per send.
    # This is the architectural seam external-mirror plugins ride on
    # after PR-EM-6 deletes the legacy `maybe_notify_external/3` path.
    # See `apps/ezagent_core/lib/ezagent/kind/runtime.ex` step 9.5 for
    # the `new_slice != slice` predicate that gates the event.

    test "fresh session has nil id, nil message, cursor 0" do
      slice = Chat.init_slice(%{})

      assert Map.has_key?(slice, :last_message_id)
      assert Map.has_key?(slice, :last_message)
      assert Map.has_key?(slice, :send_cursor)

      assert slice.last_message_id == nil
      assert slice.last_message == nil
      assert slice.send_cursor == 0
    end

    test "send → id stamp + full Message struct + cursor=1 (codex r1 HIGH-2 — adapters need the body)" do
      session_uri = URI.new!("session://default/team-alpha/lmi-mutation-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      msg = Message.new(sender, %{text: "ping", attachments: []})

      slice = Chat.init_slice(%{})
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      assert {:ok, new_slice, %{stored: true}} =
               Chat.invoke(:send, slice, %{message: msg}, ctx)

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
      session_uri = URI.new!("session://default/team-alpha/lmi-overwrite-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      msg1 = Message.new(sender, %{text: "first", attachments: []})
      msg2 = Message.new(sender, %{text: "second", attachments: []})
      # Sanity: independent message ids
      refute msg1.id == msg2.id

      slice = Chat.init_slice(%{})

      assert {:ok, slice1, _} = Chat.invoke(:send, slice, %{message: msg1}, ctx)
      assert slice1.last_message_id == msg1.id
      assert slice1.last_message.id == msg1.id
      assert slice1.send_cursor == 1

      assert {:ok, slice2, _} = Chat.invoke(:send, slice1, %{message: msg2}, ctx)
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
      session_uri = URI.new!("session://default/team-alpha/lmi-retry-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      msg = Message.new(sender, %{text: "same payload, sent twice", attachments: []})

      slice = Chat.init_slice(%{})

      assert {:ok, slice1, %{stored: true}} = Chat.invoke(:send, slice, %{message: msg}, ctx)
      assert slice1.last_message_id == msg.id
      assert slice1.send_cursor == 1

      # Resend the SAME msg (same id, same body, same sender).
      # MessageStore is idempotent on `(msg.id, session_uri)`; the
      # second invoke succeeds without crashing and still returns
      # `{:ok, _, %{stored: true}}`.
      assert {:ok, slice2, %{stored: true}} = Chat.invoke(:send, slice1, %{message: msg}, ctx)

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
        URI.new!("session://default/team-alpha/lmi-dup-id-#{System.unique_integer([:positive])}")

      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      original_body = %{text: "original truth", attachments: []}
      original = Message.new(sender, original_body)

      # Build a SECOND Message struct with the same id but a wholly
      # different body — simulating a misbehaving client.
      adversarial =
        %Message{original | body: %{text: "adversarial overwrite", attachments: []}}

      assert original.id == adversarial.id
      refute original.body == adversarial.body

      slice = Chat.init_slice(%{})

      # First send persists the original
      assert {:ok, slice1, %{stored: true}} =
               Chat.invoke(:send, slice, %{message: original}, ctx)

      assert slice1.last_message_id == original.id
      assert slice1.last_message.body["text"] == "original truth"

      # Second send with same id but different body. MessageStore
      # treats the id as already-persisted (on_conflict: :nothing) and
      # returns the ORIGINAL row — :last_message in the new slice
      # MUST be the original row, not the adversarial one.
      assert {:ok, slice2, %{stored: true}} =
               Chat.invoke(:send, slice1, %{message: adversarial}, ctx)

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
      session_uri = URI.new!("session://default/team-alpha/lmi-legacy-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      msg = Message.new(sender, %{text: "legacy slice send", attachments: []})

      legacy_slice = %{members: %{}, monitors: %{}, last_seen: %{}}
      refute Map.has_key?(legacy_slice, :last_message_id)
      refute Map.has_key?(legacy_slice, :last_message)
      refute Map.has_key?(legacy_slice, :send_cursor)

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      assert {:ok, new_slice, %{stored: true}} =
               Chat.invoke(:send, legacy_slice, %{message: msg}, ctx)

      assert new_slice.last_message_id == msg.id
      assert new_slice.last_message.id == msg.id
      assert new_slice.send_cursor == 1
    end

    test "SliceChange.emit fires on send (full Runtime path) and event carries last_message struct" do
      # End-to-end: drive the Chat behavior via Kind.Runtime so the
      # slice_change_event hook fires (per runtime.ex step 9.5). With
      # the three send-tracking fields mutated by `:send`, subscribers
      # should receive a `{:slice_changed, %{slice_key: :chat, ...}}`
      # event carrying the full Message in `new_slice.last_message`
      # (HIGH-2 — adapters convert the event without DB lookups).
      # Without this PR's slice mutation, `new_slice == slice` and
      # the hook short-circuits with `nil` — no event reaches the
      # topic.

      Application.put_env(:ezagent_core, :slice_change_hook, true)
      on_exit(fn -> Application.delete_env(:ezagent_core, :slice_change_hook) end)

      session_uri = URI.new!("session://default/team-alpha/lmi-slicechange-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      msg = Message.new(sender, %{text: "emit me", attachments: []})

      slice = Chat.init_slice(%{})

      # Subscribe to the entity's slice-changed topic. The hook fires
      # only via `Kind.Server.commit_and_notify/3` → `SliceChange.emit/1`
      # post-snapshot; we drive the full `Kind.Runtime.handle_dispatch/4`
      # path so the event shape matches production.
      Ezagent.SliceChange.subscribe_unverified(session_uri)
      on_exit(fn -> Ezagent.SliceChange.unsubscribe_unverified(session_uri) end)

      # Build a dispatch envelope identical to what `Invocation.dispatch/1`
      # would land in a Session GenServer's handle_call/cast.
      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

      inv = %Ezagent.Invocation{
        target: target,
        mode: :cast,
        args: %{message: msg},
        ctx: %{
          caller: sender,
          caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
          reply: :ignore
        }
      }

      # Initial state: just the :chat slice. Runtime defaults missing
      # slices to %{}, so we only need to seed this one.
      initial_state = %{chat: slice}

      assert {:ok, new_state, _result, slice_change_event} =
               Ezagent.Kind.Runtime.handle_dispatch(
                 inv,
                 initial_state,
                 Ezagent.Entity.Session,
                 session_uri
               )

      # Runtime built the event (proves new_slice != slice)
      assert is_map(slice_change_event)
      assert slice_change_event.slice_key == :chat
      assert slice_change_event.action == :send
      assert slice_change_event.kind_module == Ezagent.Entity.Session

      # All three send-tracking fields carry across in `new_slice` and
      # are at their pre-send defaults in `old_slice`.
      assert slice_change_event.new_slice.last_message_id == msg.id
      assert slice_change_event.new_slice.last_message.id == msg.id
      assert slice_change_event.new_slice.last_message.sender == sender
      assert slice_change_event.new_slice.last_message.session_uri == session_uri
      assert slice_change_event.new_slice.send_cursor == 1

      assert slice_change_event.old_slice.last_message_id == nil
      assert slice_change_event.old_slice.last_message == nil
      assert slice_change_event.old_slice.send_cursor == 0

      # State carries the mutated slice
      assert new_state.chat.last_message_id == msg.id
      assert new_state.chat.last_message.id == msg.id
      assert new_state.chat.send_cursor == 1

      # Fire emit directly the same way Kind.Server.commit_and_notify/3
      # does post-snapshot — and assert subscribers receive the event.
      :ok = Ezagent.SliceChange.emit(slice_change_event)

      assert_receive {:slice_changed, ^slice_change_event}, 500
    end
  end

  describe "invoke(:receive, ...) — User branch" do
    test "broadcasts {:message_received, msg} on user events topic" do
      user_uri = URI.new!("entity://user/team-alpha/admin-recv-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://agent/team-alpha/test_cc-builder")
      msg = Message.new(sender, %{text: "reply incoming", attachments: []})

      topic = Chat.user_events_topic(user_uri)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      slice = %{}
      ctx = %{self_uri: user_uri, kind_module: Ezagent.Entity.User, caller: sender}

      assert {:ok, ^slice} = Chat.invoke(:receive, slice, %{message: msg}, ctx)
      assert_receive {:message_received, %Message{id: rid}}, 500
      assert rid == msg.id
    end
  end

  describe "invoke(:receive, ...) — Agent branch" do
    test "returns {:ok, slice} unchanged (Agent has no chat slice state)" do
      agent_uri = URI.new!("entity://agent/team-alpha/test_cc-builder-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/system/admin")
      msg = Message.new(sender, %{text: "hi agent", attachments: []})

      slice = %{}
      ctx = %{self_uri: agent_uri, kind_module: Ezagent.Entity.Agent, caller: sender}

      assert {:ok, ^slice} = Chat.invoke(:receive, slice, %{message: msg}, ctx)
    end

    # PR 26 (2026-05-18): the channels-reference protocol declares
    # `meta: Record<string, string>` — every value MUST be a string,
    # otherwise claude TUI silently drops the entire notification.
    # PR 14 violated this by stamping a list under `meta.attachments`,
    # which broke the inbound path for ~3 weeks before discovery.

    test "to_claude payload meta values are all strings (no list/map smuggling)" do
      agent_uri = URI.new!("entity://agent/team-alpha/test_cc-meta-string-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/system/admin")
      session_uri = URI.new!("session://default/team-alpha/meta-#{System.unique_integer([:positive])}")

      msg = Message.new(sender, %{text: "plain text", attachments: []})

      :ok = EzagentPluginCc.BridgeRegistry.bind(agent_uri, self())
      on_exit(fn -> EzagentPluginCc.BridgeRegistry.unbind(agent_uri) end)

      ctx = %{self_uri: agent_uri, kind_module: Ezagent.Entity.Agent, caller: session_uri}

      Chat.invoke(:receive, %{}, %{message: msg}, ctx)

      assert_receive {:to_claude, %{"content" => content, "meta" => meta}}, 500

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
      agent_uri = URI.new!("entity://agent/team-alpha/test_cc-meta-att-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/system/admin")
      session_uri = URI.new!("session://default/team-alpha/meta-att-#{System.unique_integer([:positive])}")

      msg =
        Message.new(sender, %{
          text: "see file",
          attachments: [
            %{type: "file", name: "a.txt", local_path: "/tmp/a.txt"},
            %{type: "image", name: "b.png", local_path: "/tmp/b.png"}
          ]
        })

      :ok = EzagentPluginCc.BridgeRegistry.bind(agent_uri, self())
      on_exit(fn -> EzagentPluginCc.BridgeRegistry.unbind(agent_uri) end)

      ctx = %{self_uri: agent_uri, kind_module: Ezagent.Entity.Agent, caller: session_uri}

      Chat.invoke(:receive, %{}, %{message: msg}, ctx)

      assert_receive {:to_claude, %{"content" => content, "meta" => meta}}, 500

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
      agent_uri = URI.new!("entity://agent/team-alpha/test_cc-meta-stringkey-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/system/admin")
      session_uri = URI.new!("session://default/team-alpha/meta-stringkey-#{System.unique_integer([:positive])}")

      string_keyed_body = %{
        "text" => "from db",
        "attachments" => [%{"type" => "file", "name" => "x", "local_path" => "/tmp/x.txt"}]
      }

      msg = %Message{
        Message.new(sender, %{text: "stub", attachments: []})
        | body: string_keyed_body
      }

      :ok = EzagentPluginCc.BridgeRegistry.bind(agent_uri, self())
      on_exit(fn -> EzagentPluginCc.BridgeRegistry.unbind(agent_uri) end)

      ctx = %{self_uri: agent_uri, kind_module: Ezagent.Entity.Agent, caller: session_uri}

      Chat.invoke(:receive, %{}, %{message: msg}, ctx)

      assert_receive {:to_claude, %{"content" => content, "meta" => meta}}, 500

      assert content =~ "from db"
      assert meta["file_path"] == "/tmp/x.txt"
      for {_k, v} <- meta, do: assert(is_binary(v))
    end
  end

  describe "invoke(:join, ...)" do
    test "Process.monitor target Kind + add to members + returns members list" do
      session_uri = URI.new!("session://default/team-alpha/join-#{System.unique_integer([:positive])}")
      member_uri = URI.new!("entity://user/team-alpha/transient-#{System.unique_integer([:positive])}")

      # Spawn a minimal GenServer to play the member role; it self-registers
      # so KindRegistry.lookup returns ITS pid (the Registry's owner-pid).
      {:ok, member_pid} = GenServer.start_link(__MODULE__.NoopServer, member_uri)

      slice = Chat.init_slice(%{})
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: member_uri}

      assert {:ok, new_slice, %{members: [^member_uri]}} =
               Chat.invoke(:join, slice, %{member: member_uri}, ctx)

      assert Map.has_key?(new_slice.members, member_uri)
      assert new_slice.members[member_uri].online == true
      assert map_size(new_slice.monitors) == 1
      [{ref, ^member_uri}] = Map.to_list(new_slice.monitors)
      assert is_reference(ref)

      GenServer.stop(member_pid)
    end

    test "returns error when member URI not in KindRegistry" do
      session_uri = URI.new!("session://default/team-alpha/join-missing-#{System.unique_integer([:positive])}")
      missing_uri = URI.new!("entity://user/team-alpha/does-not-exist-#{System.unique_integer([:positive])}")

      slice = Chat.init_slice(%{})
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: missing_uri}

      assert {:error, {:member_not_registered, ^missing_uri}} =
               Chat.invoke(:join, slice, %{member: missing_uri}, ctx)
    end

    test "replays missed messages on rejoin (last_seen populated)" do
      session_uri = URI.new!("session://default/team-alpha/replay-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      member_uri = URI.new!("entity://user/team-alpha/rejoin-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/team-alpha/other")

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

      assert {:ok, new_slice, _} = Chat.invoke(:join, slice, %{member: member_uri}, ctx)
      # last_seen for this member is cleared
      refute Map.has_key?(new_slice.last_seen, member_uri)

      GenServer.stop(member_pid)
    end
  end

  describe "invoke(:leave, ...)" do
    test "drops member + demonitors + clears last_seen" do
      session_uri = URI.new!("session://default/team-alpha/leave-#{System.unique_integer([:positive])}")
      member_uri = URI.new!("entity://user/team-alpha/leaver-#{System.unique_integer([:positive])}")
      ref = make_ref()

      slice = %{
        members: %{member_uri => %{online: true}},
        monitors: %{ref => member_uri},
        last_seen: %{member_uri => DateTime.utc_now()}
      }

      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: member_uri}

      assert {:ok, new_slice} = Chat.invoke(:leave, slice, %{member: member_uri}, ctx)

      refute Map.has_key?(new_slice.members, member_uri)
      refute Map.has_key?(new_slice.monitors, ref)
      refute Map.has_key?(new_slice.last_seen, member_uri)
    end
  end

  describe "handle_kind_message/3 (:DOWN forwarder)" do
    test "marks member offline + records last_seen" do
      member_uri = URI.new!("entity://user/team-alpha/crashed-#{System.unique_integer([:positive])}")
      ref = make_ref()

      slice = %{
        members: %{member_uri => %{online: true}},
        monitors: %{ref => member_uri},
        last_seen: %{}
      }

      ctx = %{self_uri: URI.new!("session://default/team-alpha/x"), kind_module: Ezagent.Entity.Session}

      down_msg = {:DOWN, ref, :process, self(), :normal}

      assert {:ok, new_slice} = Chat.handle_kind_message(down_msg, slice, ctx)
      assert new_slice.members[member_uri].online == false
      refute Map.has_key?(new_slice.monitors, ref)
      assert %DateTime{} = new_slice.last_seen[member_uri]
    end

    test "ignores unknown refs" do
      slice = %{members: %{}, monitors: %{}, last_seen: %{}}
      ctx = %{self_uri: URI.new!("session://default/team-alpha/y"), kind_module: Ezagent.Entity.Session}

      assert :ignore =
               Chat.handle_kind_message(
                 {:DOWN, make_ref(), :process, self(), :normal},
                 slice,
                 ctx
               )
    end

    test "ignores non-:DOWN messages" do
      slice = Chat.init_slice(%{})
      ctx = %{self_uri: URI.new!("session://default/team-alpha/z"), kind_module: Ezagent.Entity.Session}

      assert :ignore = Chat.handle_kind_message(:tick, slice, ctx)
      assert :ignore = Chat.handle_kind_message({:any, "thing"}, slice, ctx)
    end
  end

  describe "interface schema validates real Message envelope" do
    test ":send action's message schema accepts a fully-formed Message" do
      sender = URI.new!("entity://user/system/admin")

      message =
        sender
        |> Message.new(%{text: "hi", attachments: []})
        |> Map.from_struct()

      schema = Chat.interface()[:send].args
      assert :ok = InterfaceValidator.validate(%{message: message}, schema)
    end

    test ":join args schema accepts URI member, rejects string" do
      schema = Chat.interface()[:join].args
      assert :ok = InterfaceValidator.validate(%{member: URI.new!("entity://user/system/admin")}, schema)

      assert {:error, {:invalid_args, _}} =
               InterfaceValidator.validate(%{member: "entity://user/system/admin"}, schema)
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
