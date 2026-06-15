defmodule EzagentWeb.AutoServiceAdminE2ETest do
  @moduledoc """
  E2E smoke tests for AutoService admin LiveView pages.

  These tests mount each LiveView via the full Phoenix pipeline (using
  `Phoenix.LiveViewTest.live/2`) and verify:
  1. The page mounts without crashing
  2. Expected content renders in the HTML
  3. Key interactive elements are present

  Prerequisites: a seeded tenant (run `mix ezagent.demo.seed_autoservice`)
  with a known admin entity URI and workspace URI.

  Tagged `:umbrella_only` because these require the full umbrella stack.
  """

  use EzagentWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @moduletag :umbrella_only
  @moduletag timeout: 120_000

  # --- Helpers ---

  defp admin_session(tid) do
    %{
      "current_entity_uri" => "entity://system/user/admin",
      "current_workspace_uri" => "workspace://#{tid}"
    }
  end

  defp conn_with_session(%{conn: conn}, tid) do
    conn
    |> Plug.Test.init_test_session(admin_session(tid))
  end

  # --- Master Dashboard ---

  describe "GET /admin/autoservice (MasterDashboardLive)" do
    test "mounts and renders tenant overview", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, _lv, html} = live(conn, "/admin/autoservice")

      assert html =~ "Master Admin Dashboard"
      assert html =~ "Tenants"
      assert html =~ "+ 新建租户"
    end
  end

  # --- Tenant Onboard ---

  describe "GET /admin/autoservice/tenants/new (TenantOnboardLive)" do
    test "mounts the 3-step wizard", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, _lv, html} = live(conn, "/admin/autoservice/tenants/new")

      assert html =~ "Onboard New Tenant"
      assert html =~ "Step 1"
    end
  end

  # --- Tenant Dashboard ---

  describe "GET /admin/autoservice/tenants/:tid (TenantDashboardLive)" do
    test "mounts with valid tenant", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, _lv, html} = live(conn, "/admin/autoservice/tenants/system")

      assert html =~ "tenant"
    end
  end

  # --- CR Dashboard ---

  describe "GET /admin/autoservice/tenants/:tid/cr (CrDashboardLive)" do
    test "mounts and shows CR panel", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, _lv, html} = live(conn, "/admin/autoservice/tenants/system/cr")

      assert html =~ "Active CR" || html =~ "No active CR"
    end
  end

  # --- Tenant Admin (Content Management) ---

  describe "GET /autoservice/admin (TenantAdminLive)" do
    test "mounts with tabs", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, lv, html} = live(conn, "/autoservice/admin")

      # Tab navigation is present
      assert html =~ "Soul"
      assert html =~ "Skills"
      assert html =~ "KB"
      assert html =~ "Fast Agent"
      assert html =~ "发布"

      # Default tab shows Soul editor
      assert html =~ "Soul 编辑"
    end

    test "switches to Skills tab shows skill list (read-only if no content cap)", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, lv, _html} = live(conn, "/autoservice/admin")

      html = lv |> element("button", "Skills") |> render_click()

      # Without content:write cap, shows read-only list. With cap, shows create form.
      assert html =~ "Sandbox Skills" || html =~ "新建 Skill"
    end

    test "switches to KB tab", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, lv, _html} = live(conn, "/autoservice/admin")

      html = lv |> element("button", "KB") |> render_click()

      assert html =~ "KB 搜索"
      assert html =~ "KB 条目"
    end

    test "switches to Fast Agent tab", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, lv, _html} = live(conn, "/autoservice/admin")

      html = lv |> element("button", "Fast Agent") |> render_click()

      assert html =~ "Fast Agent ACK Prompt"
      assert html =~ "fast_ack_prompt.md"
    end

    test "switches to Publish tab shows CR and Lint", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, lv, _html} = live(conn, "/autoservice/admin")

      html = lv |> element("button", "发布") |> render_click()

      assert html =~ "Change Request"
      assert html =~ "预览渲染"
    end
  end

  # --- Customer Live ---

  describe "GET /autoservice (CustomerLive)" do
    test "mounts customer chat", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, _lv, html} = live(conn, "/autoservice")

      assert html =~ "暂无消息" || html =~ "输入你的问题"
    end
  end

  # --- Operator Live ---

  describe "GET /autoservice/operator (OperatorLive)" do
    test "mounts operator console", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, admin_session("system"))
      {:ok, _lv, html} = live(conn, "/autoservice/operator")

      assert html =~ "operator" || html =~ "客服" || html =~ "会话"
    end
  end
end
