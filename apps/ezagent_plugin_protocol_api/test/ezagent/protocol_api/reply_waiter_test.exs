defmodule Ezagent.ProtocolApi.ReplyWaiterTest do
  use EzagentCore.DataCase, async: true

  alias Ezagent.ProtocolApi.ReplyWaiter
  alias Ezagent.Message

  describe "wait_for_reply/3" do
    test "returns {:ok, message} when matching ref_id found within deadline" do
      request_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      agent_uri = Ezagent.URI.new!("entity://agent/system/test_agent")
      deadline_ms = 500

      reply_msg = Message.new(agent_uri, %{text: "hello back"}, ref_id: request_id)
      event = build_publisher_event(reply_msg)

      task = Task.async(fn ->
        ReplyWaiter.wait_for_reply(request_id, agent_uri, deadline_ms)
      end)

      Process.sleep(50)
      send(task.pid, {:publisher_event, event})

      assert {:ok, %Message{ref_id: ^request_id}} = Task.await(task)
    end

    test "returns {:error, :timeout} when no matching event arrives" do
      request_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      agent_uri = Ezagent.URI.new!("entity://agent/system/test_agent")

      assert {:error, :timeout} =
               ReplyWaiter.wait_for_reply(request_id, agent_uri, 100)
    end

    test "ignores events with non-matching ref_id" do
      request_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      other_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      agent_uri = Ezagent.URI.new!("entity://agent/system/test_agent")
      deadline_ms = 500

      other_msg = Message.new(agent_uri, %{text: "wrong"}, ref_id: other_id)
      other_event = build_publisher_event(other_msg)

      task = Task.async(fn ->
        ReplyWaiter.wait_for_reply(request_id, agent_uri, deadline_ms)
      end)

      Process.sleep(50)
      send(task.pid, {:publisher_event, other_event})

      assert Process.alive?(task.pid)
    end

    test "ignores events from wrong sender" do
      request_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      agent_uri = Ezagent.URI.new!("entity://agent/system/target")
      wrong_agent = Ezagent.URI.new!("entity://agent/system/other")
      deadline_ms = 500

      wrong_msg = Message.new(wrong_agent, %{text: "hi"}, ref_id: request_id)
      wrong_event = build_publisher_event(wrong_msg)

      task = Task.async(fn ->
        ReplyWaiter.wait_for_reply(request_id, agent_uri, deadline_ms)
      end)

      Process.sleep(50)
      send(task.pid, {:publisher_event, wrong_event})

      assert Process.alive?(task.pid)
    end
  end

  defp build_publisher_event(%Message{} = msg) do
    %Ezagent.Publisher.Event{
      cursor: 1,
      publisher_uri: Ezagent.URI.new!("session://system/generic/test"),
      slice_key: :session,
      event_at: DateTime.utc_now(),
      payload: %{new_slice: %{last_message: msg, last_message_id: msg.id}}
    }
  end
end
