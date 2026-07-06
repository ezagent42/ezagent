defmodule EzagentWeb.MailerEzagentChatTest do
  @moduledoc """
  Prod-path routing: with `EzagentWeb.Mailer` pinned to the REST
  `Ezagent.Mail.EzagentChatAdapter`, a present REST `smtp_config` routes
  `deliver_magic_link/2` through the adapter (asserted via the injected
  transport), and an absent/incomplete config fails the readiness gate with
  `{:error, :mail_not_configured}` — never touching the network.
  """
  # DB-backed (AppSettings) + flips app env; must not run concurrently.
  use EzagentCore.DataCase, async: false

  alias EzagentWeb.Mailer

  setup do
    prev_mailer = Application.get_env(:ezagent_web, EzagentWeb.Mailer)
    Application.put_env(:ezagent_web, EzagentWeb.Mailer, adapter: Ezagent.Mail.EzagentChatAdapter)

    on_exit(fn ->
      if prev_mailer,
        do: Application.put_env(:ezagent_web, EzagentWeb.Mailer, prev_mailer),
        else: Application.delete_env(:ezagent_web, EzagentWeb.Mailer)

      Application.delete_env(:ezagent_web, :http_request_fun)
    end)

    :ok
  end

  test "with a REST smtp_config present, deliver_magic_link routes through the REST adapter" do
    Ezagent.AppSettings.put("smtp_config", %{
      "from_address" => "auth@ezagent.chat",
      "base_url" => "https://email.ezagent.chat",
      "api_key" => "emk_live_key"
    })

    test_pid = self()

    Application.put_env(:ezagent_web, :http_request_fun, fn :post, request, _http_opts, _opts ->
      send(test_pid, {:sent, request})
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], ~c"{\"id\":\"m1\"}"}}
    end)

    assert {:ok, %{id: "m1"}} =
             Mailer.deliver_magic_link("user@example.com", "https://app/auth/magic/tok")

    assert_received {:sent, {url, headers, ~c"application/json", body}}
    assert url == ~c"https://email.ezagent.chat/api/send"
    assert {~c"authorization", ~c"Bearer emk_live_key"} in headers

    decoded = Jason.decode!(body)
    assert decoded["address"] == "auth@ezagent.chat"
    assert decoded["to"] == "user@example.com"
    assert decoded["subject"] =~ "sign-in"
  end

  test "with no smtp_config, deliver_magic_link returns {:error, :mail_not_configured}" do
    # No config at all → mail_api_configured? is false → readiness gate closes
    # BEFORE any network call. Assert the transport is never invoked.
    Application.put_env(:ezagent_web, :http_request_fun, fn _m, _r, _h, _o ->
      flunk("transport must not be called when mail is not configured")
    end)

    assert Mailer.deliver_magic_link("user@example.com", "https://app/auth/magic/tok") ==
             {:error, :mail_not_configured}
  end

  test "an SMTP-only config does NOT satisfy the REST adapter's readiness gate" do
    Ezagent.AppSettings.put("smtp_config", %{
      "host" => "smtp.example.com",
      "port" => 587,
      "username" => "u",
      "password" => "p",
      "from_address" => "auth@ezagent.chat"
    })

    Application.put_env(:ezagent_web, :http_request_fun, fn _m, _r, _h, _o ->
      flunk("transport must not be called: REST config (base_url/api_key) is absent")
    end)

    assert Mailer.deliver_magic_link("user@example.com", "https://app/auth/magic/tok") ==
             {:error, :mail_not_configured}
  end
end
