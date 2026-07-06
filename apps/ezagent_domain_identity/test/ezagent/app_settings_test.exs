defmodule Ezagent.AppSettingsTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.AppSettings

  test "put/2 then get/1 round-trips a JSON-able term" do
    :ok = AppSettings.put("registration_domains", ["a.com", "b.com"])
    assert AppSettings.get("registration_domains") == ["a.com", "b.com"]
  end

  test "put/2 upserts" do
    :ok = AppSettings.put("registration_domains", ["a.com"])
    :ok = AppSettings.put("registration_domains", ["a.com", "c.com"])
    assert AppSettings.get("registration_domains") == ["a.com", "c.com"]
  end

  test "get/1 returns nil for an unset key" do
    assert AppSettings.get("nope") == nil
  end

  test "smtp_configured?/0 is false until a complete smtp_config is set" do
    refute AppSettings.smtp_configured?()

    :ok = AppSettings.put("smtp_config", %{"host" => "smtp.x.com"})
    refute AppSettings.smtp_configured?()

    :ok =
      AppSettings.put("smtp_config", %{
        "host" => "smtp.x.com",
        "port" => 587,
        "username" => "u",
        "password" => "p",
        "from_address" => "no-reply@x.com"
      })

    assert AppSettings.smtp_configured?()
  end

  # V1 regression — Allen Feishu 2026-05-21 17:44:
  # saved SMTP via the LV form, badge said "Configured", clicking
  # "Send test email" surfaced "SMTP not configured" — i.e.
  # smtp_configured?/0 returned false despite a complete row in
  # `app_settings`. These cases exercise the exact map shape the LV
  # produces (all-string keys, string `"port"` because the input is
  # `<input type="number">` which Phoenix delivers as a string param)
  # AND the bytewise-identical JSON the DB actually contains so the
  # JSON round-trip can't quietly drift.
  describe "smtp_configured?/0 — string-keyed map written by LV form (V1 regression)" do
    test "all-string-key map with stringified port (as LV form submits it) → true" do
      :ok =
        AppSettings.put("smtp_config", %{
          "host" => "smtp.feishu.cn",
          "port" => "587",
          "username" => "lin.yilun@h2oslabs.com",
          "password" => "tKBu7hEa1x4RVjNR",
          "from_address" => "ezagent@h2oslabs.com",
          "tls" => true
        })

      assert AppSettings.smtp_configured?()
    end

    test "the exact JSON shape Allen observed in the DB on 2026-05-21 → true" do
      # Bytewise reproduction of the row dumped via `sqlite3 ... SELECT
      # value FROM app_settings WHERE key='smtp_config'`.
      :ok =
        AppSettings.put("smtp_config", %{
          "from_address" => "ezagent@h2oslabs.com",
          "host" => "smtp.feishu.cn",
          "password" => "tKBu7hEa1x4RVjNR",
          "port" => "587",
          "tls" => true,
          "username" => "lin.yilun@h2oslabs.com"
        })

      assert AppSettings.smtp_configured?()
    end

    test "any one required field as empty string → false" do
      base = %{
        "host" => "smtp.x.com",
        "port" => "587",
        "username" => "u@x.com",
        "password" => "pw",
        "from_address" => "noreply@x.com",
        "tls" => true
      }

      for empty_field <- ~w(host port username password from_address) do
        :ok = AppSettings.put("smtp_config", Map.put(base, empty_field, ""))
        refute AppSettings.smtp_configured?(),
               "expected false when #{empty_field}=\"\""
      end
    end
  end

  describe "mail_api_configured?/0 — email.ezagent.chat REST shape" do
    test "false until base_url + api_key are both non-empty" do
      refute AppSettings.mail_api_configured?()

      :ok = AppSettings.put("smtp_config", %{"base_url" => "https://email.ezagent.chat"})
      refute AppSettings.mail_api_configured?()

      :ok =
        AppSettings.put("smtp_config", %{
          "from_address" => "auth@ezagent.chat",
          "base_url" => "https://email.ezagent.chat",
          "api_key" => "emk_x"
        })

      assert AppSettings.mail_api_configured?()
    end

    test "empty base_url or api_key → false" do
      :ok = AppSettings.put("smtp_config", %{"base_url" => "", "api_key" => "emk_x"})
      refute AppSettings.mail_api_configured?()

      :ok = AppSettings.put("smtp_config", %{"base_url" => "https://x", "api_key" => ""})
      refute AppSettings.mail_api_configured?()
    end

    test "a complete SMTP-relay config does NOT satisfy the REST check" do
      :ok =
        AppSettings.put("smtp_config", %{
          "host" => "smtp.x.com",
          "port" => "587",
          "username" => "u",
          "password" => "p",
          "from_address" => "a@x.com"
        })

      refute AppSettings.mail_api_configured?()
    end
  end

  describe "mail_configured?/0 — transport-agnostic readiness" do
    test "true for a complete SMTP config OR a complete REST config" do
      refute AppSettings.mail_configured?()

      :ok =
        AppSettings.put("smtp_config", %{
          "host" => "smtp.x.com",
          "port" => "587",
          "username" => "u",
          "password" => "p",
          "from_address" => "a@x.com"
        })

      assert AppSettings.mail_configured?()

      :ok =
        AppSettings.put("smtp_config", %{
          "from_address" => "auth@ezagent.chat",
          "base_url" => "https://email.ezagent.chat",
          "api_key" => "emk_x"
        })

      assert AppSettings.mail_configured?()
    end
  end
end
