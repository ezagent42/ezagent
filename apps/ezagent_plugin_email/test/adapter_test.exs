defmodule Ezagent.Email.AdapterTest do
  @moduledoc """
  #88 PR-1 (SPEC §4.1) — pure `event_to_payload/1` translation +
  adapter declaration callbacks. No DB / no I/O.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Email.Adapter
  alias Ezagent.Publisher.Event

  @session_uri Ezagent.URI.new!("session://system/default/adapter-test")

  defp msg(body, opts \\ []) do
    sender = Keyword.get(opts, :sender, Ezagent.URI.new!("entity://system/user/alice"))

    %Ezagent.Message{
      id: Keyword.get(opts, :id, "m-#{System.unique_integer([:positive])}"),
      sender: sender,
      body: body,
      session_uri: @session_uri,
      mentions: []
    }
  end

  defp session_event(new_slice, old_slice \\ nil) do
    %Event{
      cursor: 1,
      publisher_uri: @session_uri,
      slice_key: :session,
      event_at: DateTime.utc_now(),
      payload: %{action: :send, caller: nil, new_slice: new_slice, old_slice: old_slice}
    }
  end

  # Wrap a flat slice in the two-container Lifecycle shape the Publisher
  # event carries (`%{state: <persistent>}`), exercising the unwrap.
  defp slice(fields), do: %{state: fields}

  describe "declaration callbacks" do
    test "adapter_id / kind / binding / cap_subject" do
      assert Adapter.adapter_id() == "email"
      assert Adapter.adapter_kind() == :push
      assert Adapter.binding_module() == Ezagent.Email.Binding
      assert %{behavior_module: mod} = Adapter.cap_subject()
      assert mod == EzagentPluginEmail.Behavior.ExternalAdapter.Email.Allow
    end

    test "target_ownership_check accepts a well-formed address, rejects garbage" do
      assert Adapter.target_ownership_check(
               Ezagent.URI.new!("entity://system/user/alice"),
               "human@example.com"
             ) == :ok

      assert {:error, _} =
               Adapter.target_ownership_check(
                 Ezagent.URI.new!("entity://system/user/alice"),
                 "not-an-address"
               )
    end
  end

  describe "event_to_payload/1" do
    test "fresh chat send → {:publish, %{subject, text, session_uri}}" do
      new_slice =
        slice(%{last_message_id: "m1", send_cursor: 1, last_message: msg(%{text: "hello"})})

      assert {:publish, payload} = Adapter.event_to_payload(session_event(new_slice))
      assert is_binary(payload.subject)
      assert payload.text =~ "hello"
      assert payload.session_uri == @session_uri
    end

    test "subject is sanitized of CR/LF + control chars (header injection)" do
      hostile = msg(%{text: "body"}, sender: Ezagent.URI.new!("entity://system/user/x"))
      hostile = %{hostile | body: %{text: "x\r\nBcc: evil@x\r\nSubject: pwned"}}
      new_slice = slice(%{last_message_id: "m1", send_cursor: 1, last_message: hostile})

      assert {:publish, payload} = Adapter.event_to_payload(session_event(new_slice))
      refute payload.subject =~ "\r"
      refute payload.subject =~ "\n"
    end

    test ":skip when chat_send_occurred? is false (unchanged id + cursor)" do
      s = slice(%{last_message_id: "m1", send_cursor: 1, last_message: msg(%{text: "x"})})

      assert Adapter.event_to_payload(
               session_event(s, %{state: %{last_message_id: "m1", send_cursor: 1}})
             ) == :skip
    end

    test ":skip on _email_origin self-echo (atom and string key)" do
      atom_echo = msg(%{text: "x", _email_origin: true})
      str_echo = msg(%{"text" => "x", "_email_origin" => true})

      assert Adapter.event_to_payload(
               session_event(
                 slice(%{last_message_id: "a", send_cursor: 1, last_message: atom_echo})
               )
             ) == :skip

      assert Adapter.event_to_payload(
               session_event(
                 slice(%{last_message_id: "b", send_cursor: 1, last_message: str_echo})
               )
             ) == :skip
    end

    test ":skip on non-session slice" do
      ev = %Event{
        cursor: 1,
        publisher_uri: @session_uri,
        slice_key: :members,
        event_at: DateTime.utc_now(),
        payload: %{}
      }

      assert Adapter.event_to_payload(ev) == :skip
    end
  end
end
