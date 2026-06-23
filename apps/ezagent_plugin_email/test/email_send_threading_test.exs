defmodule Ezagent.EmailSendThreadingTest do
  @moduledoc """
  #88 PR-1 (HIGH 5 / §4.8) — `Ezagent.Email.send/4` carries the optional
  RFC 5322 threading headers (`Message-ID` / `In-Reply-To` / `References`)
  the email ExternalMirror Binding needs to thread a conversation.
  """
  use ExUnit.Case, async: false
  import Swoosh.TestAssertions

  test "send/4 stamps Message-ID / In-Reply-To / References when given" do
    assert {:ok, _} =
             Ezagent.Email.send("dest@ezagent.chat", "S", "B",
               message_id: "<m1@ezagent.chat>",
               in_reply_to: "<m0@ext>",
               references: "<m0@ext> <m1@ezagent.chat>"
             )

    assert_email_sent(fn email ->
      assert email.headers["Message-ID"] == "<m1@ezagent.chat>"
      assert email.headers["In-Reply-To"] == "<m0@ext>"
      assert email.headers["References"] == "<m0@ext> <m1@ezagent.chat>"
    end)
  end

  test "send/4 emits no threading headers when opts absent (backward-compatible)" do
    assert {:ok, _} = Ezagent.Email.send("dest@ezagent.chat", "S", "B")

    assert_email_sent(fn email ->
      not Map.has_key?(email.headers, "Message-ID") and
        not Map.has_key?(email.headers, "In-Reply-To") and
        not Map.has_key?(email.headers, "References")
    end)
  end
end
