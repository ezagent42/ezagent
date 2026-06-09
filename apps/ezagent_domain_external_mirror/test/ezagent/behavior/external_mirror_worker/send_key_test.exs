defmodule Ezagent.Behavior.ExternalMirrorWorker.SendKeyTest do
  @moduledoc """
  Unit tests for `Ezagent.Behavior.ExternalMirrorWorker.SendKey` — the
  pure send-key derivation extracted from
  `Ezagent.Behavior.ExternalMirrorWorker` (#25 Phase-3, PR-3O).

  Pure functions only: no process, no DB, no sandbox.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.ExternalMirrorWorker.SendKey
  alias Ezagent.Publisher.Event

  defp chat_event(new_slice) do
    %Event{
      slice_key: :chat,
      payload: %{new_slice: new_slice},
      cursor: 0,
      publisher_uri: nil,
      event_at: nil
    }
  end

  describe "extract_event_send_key/1" do
    test "returns {message_id, send_cursor} for a flat chat slice (atom keys)" do
      slice = %{last_message: %Ezagent.Message{id: "m1"}, send_cursor: 7}
      assert SendKey.extract_event_send_key(chat_event(slice)) == {"m1", 7}
    end

    test "unwraps a Lifecycle two-container slice (%{state: ...}) before reading" do
      slice = %{"state" => %{last_message: %Ezagent.Message{id: "m2"}, send_cursor: 3}}
      assert SendKey.extract_event_send_key(chat_event(slice)) == {"m2", 3}
    end

    test "defaults send_cursor to 0 when absent" do
      slice = %{last_message: %Ezagent.Message{id: "m3"}}
      assert SendKey.extract_event_send_key(chat_event(slice)) == {"m3", 0}
    end

    test "nil when the chat slice has no last_message" do
      assert SendKey.extract_event_send_key(chat_event(%{send_cursor: 5})) == nil
    end

    test "nil for a non-chat slice_key" do
      ev = %Event{
        slice_key: :external_mirror,
        payload: %{new_slice: %{}},
        cursor: 0,
        publisher_uri: nil,
        event_at: nil
      }

      assert SendKey.extract_event_send_key(ev) == nil
    end

    test "nil for a non-Event argument" do
      assert SendKey.extract_event_send_key(:nope) == nil
    end
  end

  describe "fetch_send_cursor/1" do
    test "reads atom key, string key, or defaults to 0" do
      assert SendKey.fetch_send_cursor(%{send_cursor: 9}) == 9
      assert SendKey.fetch_send_cursor(%{"send_cursor" => 4}) == 4
      assert SendKey.fetch_send_cursor(%{}) == 0
    end
  end

  describe "unwrap_chat_slice/1" do
    test "nil passes through" do
      assert SendKey.unwrap_chat_slice(nil) == nil
    end

    test "a flat slice passes through unchanged" do
      flat = %{last_message: %Ezagent.Message{id: "x"}, send_cursor: 1}
      assert SendKey.unwrap_chat_slice(flat) == flat
    end
  end
end
