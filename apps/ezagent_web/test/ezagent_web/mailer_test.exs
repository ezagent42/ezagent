defmodule EzagentWeb.MailerTest do
  use ExUnit.Case, async: true

  alias EzagentWeb.Mailer

  test "build_magic_link_email/2 sets recipient, sender, and link in the body" do
    email =
      Mailer.build_magic_link_email("allen@example.com",
        url: "https://esr.example.com/auth/magic/abc123",
        from_address: "no-reply@esr.example.com"
      )

    assert Enum.any?(email.to, fn {_name, addr} -> addr == "allen@example.com" end)
    assert {_, "no-reply@esr.example.com"} = email.from
    assert email.subject =~ "Ezagent"
    assert email.text_body =~ "https://esr.example.com/auth/magic/abc123"
    assert email.html_body =~ "https://esr.example.com/auth/magic/abc123"
  end

  test "build_confirmation_email/2 puts the confirm link in the body" do
    email =
      Mailer.build_confirmation_email("new@example.com",
        url: "https://esr.example.com/auth/confirm/tok",
        from_address: "no-reply@ezagent.chat"
      )

    assert Enum.any?(email.to, fn {_n, a} -> a == "new@example.com" end)
    assert email.subject =~ "Confirm"
    assert email.text_body =~ "https://esr.example.com/auth/confirm/tok"
  end

  test "build_password_reset_email/2 puts the reset link in the body" do
    email =
      Mailer.build_password_reset_email("u@example.com",
        url: "https://esr.example.com/auth/reset/tok",
        from_address: "no-reply@ezagent.chat"
      )

    assert email.subject =~ "Reset"
    assert email.text_body =~ "https://esr.example.com/auth/reset/tok"
  end

  # task #87 — under the test Local adapter, deliver works with NO smtp_config
  # (the readiness gate treats Local as always-ready).
  test "deliver_confirmation/2 succeeds under the Local adapter without SMTP config" do
    assert {:ok, _} = Mailer.deliver_confirmation("new@example.com", "https://x/auth/confirm/t")
  end

  test "deliver_password_reset/2 succeeds under the Local adapter without SMTP config" do
    assert {:ok, _} = Mailer.deliver_password_reset("u@example.com", "https://x/auth/reset/t")
  end
end
