defmodule EzagentPluginLiveview.AdminAuthzAuditLiveTest do
  @moduledoc """
  `/admin/audit/authz` admin-gate test (Design 2 from caps-e2e-design.md §5).
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  defp admin_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
    })
  end

  defp non_admin_conn do
    uri = "entity://user/default/authz_audit_test_user_#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(URI.parse(uri), nil, [])

    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"current_entity_uri" => uri})
  end

  describe "/admin/audit/authz" do
    test "admin caller mounts the audit page" do
      {:ok, _lv, html} = live(admin_conn(), "/admin/audit/authz")
      assert html =~ "Capability authz audit"
      # Empty-state notice when no events yet
      assert html =~ "No events yet"
    end

    test "non-admin caller is redirected" do
      assert {:error, redirect} = live(non_admin_conn(), "/admin/audit/authz")

      assert match?({:live_redirect, %{to: "/sessions"}}, redirect) or
               match?({:redirect, %{to: "/sessions"}}, redirect)
    end
  end
end
