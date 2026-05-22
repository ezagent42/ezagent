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
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://default"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  describe "Behavior contract surface" do
    test "actions/0 returns the 4 K-path actions" do
      assert Chat.actions() == [:send, :receive, :join, :leave]
    end

    test "state_slice/0 returns :chat" do
      assert Chat.state_slice() == :chat
    end

    test "init_slice/1 returns slice with members / monitors / last_seen empty maps + empty template_working_copy" do
      # Phase 7 completion PR-2 — the `:chat` slice now also carries the
      # durable `template_working_copy` field (SPEC §1.3 / §1.6).
      assert Chat.init_slice(%{}) == %{
               members: %{},
               monitors: %{},
               last_seen: %{},
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

    test "interface/0 declares all 4 actions" do
      keys = Chat.interface() |> Map.keys() |> Enum.sort()
      assert keys == [:join, :leave, :receive, :send]
    end
  end

  describe "invoke(:send, ...) routing (Phase 3c-step 1)" do
    test "with no routing rules → falls through to in-session members fan-out" do
      session_uri = URI.new!("session://default/default/chat-fallback-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      other_member = URI.new!("entity://user/default/other-#{System.unique_integer([:positive])}")
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

      target_session = URI.new!("session://default/default/chat-routed-#{System.unique_integer([:positive])}")
      session_uri = URI.new!("session://default/default/current")
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
    test "writes to MessageStore + broadcasts on session events topic + returns {:ok, slice, %{stored: true}}" do
      session_uri = URI.new!("session://default/default/chat-test-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      msg = Message.new(sender, %{text: "hello world", attachments: []})

      slice = Chat.init_slice(%{})
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: sender}

      topic = Chat.session_events_topic(session_uri)
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, topic)

      assert {:ok, ^slice, %{stored: true}} =
               Chat.invoke(:send, slice, %{message: msg}, ctx)

      # MessageStore now has it
      assert {:ok, loaded} = MessageStore.by_id(msg.id)
      assert loaded.session_uri == session_uri

      # Subscribers receive the chat_message broadcast
      assert_receive {:chat_message, _session_uri, %Message{id: stored_id}}, 500
      assert stored_id == msg.id
    end

    test "fan-out :receive on members when no mentions" do
      session_uri = URI.new!("session://default/default/chat-fanout-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      sender = URI.new!("entity://user/system/admin")
      member_2 = URI.new!("entity://agent/default/test_test-bot-#{System.unique_integer([:positive])}")
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

  describe "invoke(:receive, ...) — User branch" do
    test "broadcasts {:message_received, msg} on user events topic" do
      user_uri = URI.new!("entity://user/default/admin-recv-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://agent/default/test_cc-builder")
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
      agent_uri = URI.new!("entity://agent/default/test_cc-builder-#{System.unique_integer([:positive])}")
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
      agent_uri = URI.new!("entity://agent/default/test_cc-meta-string-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/system/admin")
      session_uri = URI.new!("session://default/default/meta-#{System.unique_integer([:positive])}")

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
      agent_uri = URI.new!("entity://agent/default/test_cc-meta-att-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/system/admin")
      session_uri = URI.new!("session://default/default/meta-att-#{System.unique_integer([:positive])}")

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
      agent_uri = URI.new!("entity://agent/default/test_cc-meta-stringkey-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/system/admin")
      session_uri = URI.new!("session://default/default/meta-stringkey-#{System.unique_integer([:positive])}")

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
      session_uri = URI.new!("session://default/default/join-#{System.unique_integer([:positive])}")
      member_uri = URI.new!("entity://user/default/transient-#{System.unique_integer([:positive])}")

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
      session_uri = URI.new!("session://default/default/join-missing-#{System.unique_integer([:positive])}")
      missing_uri = URI.new!("entity://user/default/does-not-exist-#{System.unique_integer([:positive])}")

      slice = Chat.init_slice(%{})
      ctx = %{self_uri: session_uri, kind_module: Ezagent.Entity.Session, caller: missing_uri}

      assert {:error, {:member_not_registered, ^missing_uri}} =
               Chat.invoke(:join, slice, %{member: missing_uri}, ctx)
    end

    test "replays missed messages on rejoin (last_seen populated)" do
      session_uri = URI.new!("session://default/default/replay-#{System.unique_integer([:positive])}")
      bind_to_default(session_uri)
      member_uri = URI.new!("entity://user/default/rejoin-#{System.unique_integer([:positive])}")
      sender = URI.new!("entity://user/default/other")

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
      session_uri = URI.new!("session://default/default/leave-#{System.unique_integer([:positive])}")
      member_uri = URI.new!("entity://user/default/leaver-#{System.unique_integer([:positive])}")
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
      member_uri = URI.new!("entity://user/default/crashed-#{System.unique_integer([:positive])}")
      ref = make_ref()

      slice = %{
        members: %{member_uri => %{online: true}},
        monitors: %{ref => member_uri},
        last_seen: %{}
      }

      ctx = %{self_uri: URI.new!("session://default/default/x"), kind_module: Ezagent.Entity.Session}

      down_msg = {:DOWN, ref, :process, self(), :normal}

      assert {:ok, new_slice} = Chat.handle_kind_message(down_msg, slice, ctx)
      assert new_slice.members[member_uri].online == false
      refute Map.has_key?(new_slice.monitors, ref)
      assert %DateTime{} = new_slice.last_seen[member_uri]
    end

    test "ignores unknown refs" do
      slice = %{members: %{}, monitors: %{}, last_seen: %{}}
      ctx = %{self_uri: URI.new!("session://default/default/y"), kind_module: Ezagent.Entity.Session}

      assert :ignore =
               Chat.handle_kind_message(
                 {:DOWN, make_ref(), :process, self(), :normal},
                 slice,
                 ctx
               )
    end

    test "ignores non-:DOWN messages" do
      slice = Chat.init_slice(%{})
      ctx = %{self_uri: URI.new!("session://default/default/z"), kind_module: Ezagent.Entity.Session}

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
