defmodule EzagentWeb.GettextTest do
  @moduledoc """
  i18n V1 (Allen 2026-05-21) — verify the EzagentWeb.Gettext backend
  compiles, knows the two V1 locales, and translates the high-visibility
  proof-of-concept strings.
  """
  use ExUnit.Case, async: false

  setup do
    Gettext.put_locale(EzagentWeb.Gettext, "en")
    :ok
  end

  describe "backend" do
    test "knows V1 locales en and zh_CN" do
      locales = Gettext.known_locales(EzagentWeb.Gettext)
      assert "en" in locales
      assert "zh_CN" in locales
    end
  end

  describe "translation roundtrip" do
    test "Sign in defaults to msgid (en)" do
      assert Gettext.gettext(EzagentWeb.Gettext, "Sign in") == "Sign in"
    end

    test "Sign in translates to 登录 under zh_CN" do
      Gettext.put_locale(EzagentWeb.Gettext, "zh_CN")
      assert Gettext.gettext(EzagentWeb.Gettext, "Sign in") == "登录"
    end

    test "login form labels translate" do
      Gettext.put_locale(EzagentWeb.Gettext, "zh_CN")
      assert Gettext.gettext(EzagentWeb.Gettext, "Username or entity URI") == "用户名或实体 URI"
      assert Gettext.gettext(EzagentWeb.Gettext, "Password or token") == "密码或令牌"
      assert Gettext.gettext(EzagentWeb.Gettext, "With password") == "使用密码"
      assert Gettext.gettext(EzagentWeb.Gettext, "With email magic link") == "使用邮箱魔法链接"
    end

    test "Ecto changeset error translations work" do
      Gettext.put_locale(EzagentWeb.Gettext, "zh_CN")
      assert Gettext.dgettext(EzagentWeb.Gettext, "errors", "can't be blank") == "不能为空"
      assert Gettext.dgettext(EzagentWeb.Gettext, "errors", "is invalid") == "无效"
    end

    test "unknown msgid falls back to msgid (en)" do
      assert Gettext.gettext(EzagentWeb.Gettext, "this-string-does-not-exist") ==
               "this-string-does-not-exist"
    end

    test "unknown msgid falls back to msgid (zh_CN)" do
      Gettext.put_locale(EzagentWeb.Gettext, "zh_CN")

      assert Gettext.gettext(EzagentWeb.Gettext, "this-string-does-not-exist") ==
               "this-string-does-not-exist"
    end
  end
end
