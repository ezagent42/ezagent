defmodule EzagentWeb.ErrorHTMLTest do
  use EzagentWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html — ezagent-branded with Activity Bar fallbacks" do
    # Phase 8c (Allen 2026-05-20): custom 404 page replaces plain "Not Found".
    # Asserts structural contract — branded, mentions the dead-end situation,
    # offers all three Activity Bar primary destinations as recovery links.
    html = render_to_string(EzagentWeb.ErrorHTML, "404", "html", [])
    assert html =~ "404 · not found"
    assert html =~ "ezagent"
    assert html =~ ~s(href="/sessions")
    assert html =~ ~s(href="/identities")
    assert html =~ ~s(href="/admin")
  end

  describe "500.html — branded fallback" do
    test "renders ezagent-branded Something-went-wrong with recovery actions" do
      # V1 acceptance (Allen 2026-05-21): replaces "Internal Server Error" plain
      # text with Next.js-style friendly page + collapsible debug section.
      conn = Phoenix.ConnTest.build_conn(:get, "/broken") |> Plug.Test.init_test_session(%{})
      html = render_to_string(EzagentWeb.ErrorHTML, "500", "html", conn: conn)
      assert html =~ "Something went wrong"
      assert html =~ "EZAGENT"
      assert html =~ ~s(href="/sessions")
      assert html =~ ~s(href="/login")
    end

    test "debug details HIDDEN for non-admin in test env" do
      # test env: :show_error_debug = false; session has no admin URI.
      conn = Phoenix.ConnTest.build_conn(:get, "/broken") |> Plug.Test.init_test_session(%{})

      html =
        render_to_string(EzagentWeb.ErrorHTML, "500", "html",
          conn: conn,
          reason: %RuntimeError{message: "boom"}
        )

      refute html =~ "Debug info"
      refute html =~ "boom"
    end

    test "debug details VISIBLE when :show_error_debug is true" do
      Application.put_env(:ezagent_web, :show_error_debug, true)
      conn = Phoenix.ConnTest.build_conn(:get, "/broken") |> Plug.Test.init_test_session(%{})

      try do
        html =
          render_to_string(EzagentWeb.ErrorHTML, "500", "html",
            conn: conn,
            reason: %RuntimeError{message: "configured-as-debug"}
          )

        assert html =~ "Debug info"
        assert html =~ "configured-as-debug"
      after
        Application.put_env(:ezagent_web, :show_error_debug, false)
      end
    end
  end

  describe "ErrorHTML helper functions" do
    test "show_debug?/1 false for plain conn in test env" do
      conn = Phoenix.ConnTest.build_conn(:get, "/") |> Plug.Test.init_test_session(%{})
      refute EzagentWeb.ErrorHTML.show_debug?(conn)
    end

    test "show_debug?/1 true when :show_error_debug app env is true" do
      Application.put_env(:ezagent_web, :show_error_debug, true)
      conn = Phoenix.ConnTest.build_conn(:get, "/") |> Plug.Test.init_test_session(%{})

      try do
        assert EzagentWeb.ErrorHTML.show_debug?(conn)
      after
        Application.put_env(:ezagent_web, :show_error_debug, false)
      end
    end

    test "debug_reason/1 reflects gating" do
      conn = Phoenix.ConnTest.build_conn(:get, "/") |> Plug.Test.init_test_session(%{})
      assert EzagentWeb.ErrorHTML.debug_reason(conn) == "<hidden>"

      Application.put_env(:ezagent_web, :show_error_debug, true)

      try do
        assert EzagentWeb.ErrorHTML.debug_reason(conn) == "dev env"
      after
        Application.put_env(:ezagent_web, :show_error_debug, false)
      end
    end

    test "show_debug?/1 false for non-Plug.Conn input (defensive)" do
      refute EzagentWeb.ErrorHTML.show_debug?(nil)
      refute EzagentWeb.ErrorHTML.show_debug?("not a conn")
    end
  end
end
