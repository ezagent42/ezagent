defmodule Ezagent.EmailSendTest do
  use ExUnit.Case, async: false
  import Swoosh.TestAssertions

  test "send/4 delivers via the Test adapter" do
    assert {:ok, _} =
             Ezagent.Email.send("dest@ezagent.chat", "Hi", "body text",
               from: "no-reply@ezagent.chat")

    assert_email_sent(fn email ->
      assert {_, "dest@ezagent.chat"} = hd(email.to)
      assert email.subject == "Hi"
      assert email.text_body == "body text"
    end)
  end

  test "send/4 includes html body when given" do
    {:ok, _} = Ezagent.Email.send("d@ezagent.chat", "S", "t", html: "<p>t</p>")
    assert_email_sent(fn email -> assert email.html_body == "<p>t</p>" end)
  end
end
