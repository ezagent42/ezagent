defmodule EzagentPluginLiveview.SettingsLiveSmtpTest do
  @moduledoc """
  V1 regression — Allen Feishu 2026-05-21 17:44: saved SMTP config
  via `/admin/settings` (moved from `/settings` the same day; see
  router commit "move /settings to /admin/settings"), form showed
  "SMTP config saved." but clicking "Send test email" returned the
  cond branch's "SMTP not configured — fill host/port/username/
  password/from above and save first."

  These tests drive the LV through the actual form submission + test-send
  flow to keep the save→read invariant: after `save_smtp` returns
  successfully with all 5 required fields non-empty, the immediately-
  following `send_test_email` call MUST NOT fall through the
  `not Ezagent.AppSettings.smtp_configured?()` branch.
  """
  use ExUnit.Case

  # #52 Mode-A: cross-tier LiveView suite — mounts views that resolve
  # sibling-app domain modules; runs only in the umbrella. Excluded
  # standalone (`cd apps/ezagent_plugin_liveview && mix test`).
  @moduletag :umbrella_only
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  @smtp_complete %{
    "host" => "smtp.feishu.cn",
    "port" => "587",
    "username" => "lin.yilun@h2oslabs.com",
    "password" => "tKBu7hEa1x4RVjNR",
    "from_address" => "ezagent@h2oslabs.com",
    "tls" => "true"
  }

  describe "save_smtp -> send_test_email round-trip" do
    test "after saving a complete SMTP config, send_test_email does NOT report 'not configured'",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin/settings")

      # Switch to SMTP section + save the config the same way the form does.
      lv |> render_click("switch_section", %{"key" => "smtp"})
      html = lv |> render_submit("save_smtp", %{"smtp" => @smtp_complete})

      assert html =~ "SMTP config saved."
      # Badge should now read "Configured" — proves load_smtp_form refreshed
      # the @smtp_configured? assign correctly off the freshly-stored row.
      assert html =~ "Configured"

      # And — the regression — clicking send_test_email immediately
      # must NOT take the "not configured" branch.
      html =
        lv |> render_submit("send_test_email", %{"recipient" => "test@example.com"})

      refute html =~ "SMTP not configured"
      # We don't assert the actual SMTP delivery succeeds (we don't have
      # a working relay in tests), but it should at least *attempt* and
      # surface the real send-failure (or success) rather than the
      # configured-check error.
    end

    test "Ezagent.AppSettings.smtp_configured?/0 is true immediately after save_smtp completes",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin/settings")

      lv |> render_click("switch_section", %{"key" => "smtp"})
      _html = lv |> render_submit("save_smtp", %{"smtp" => @smtp_complete})

      # The exact predicate the send_test_email handler calls.
      assert Ezagent.AppSettings.smtp_configured?()
    end

    test "send_test_email DOES report 'not configured' when config is genuinely incomplete",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/admin/settings")

      lv |> render_click("switch_section", %{"key" => "smtp"})

      # Save with a blank host — partial config, password preservation has
      # no effect because there's no prior row.
      incomplete = Map.put(@smtp_complete, "host", "")
      _html = lv |> render_submit("save_smtp", %{"smtp" => incomplete})

      refute Ezagent.AppSettings.smtp_configured?()

      html =
        lv |> render_submit("send_test_email", %{"recipient" => "test@example.com"})

      assert html =~ "SMTP not configured"
    end
  end
end
