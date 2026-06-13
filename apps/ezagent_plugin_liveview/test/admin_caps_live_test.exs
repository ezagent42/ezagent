defmodule EzagentPluginLiveview.AdminCapsLiveTest do
  @moduledoc """
  `/admin/caps` placement + admin-gate test.

  Mirrors `settings_live_admin_test.exs` — pins the contract that:

  1. /admin/caps is admin-only at the mount level (non-admin callers
     are redirected to /sessions, not just shown a no-op page).
  2. The admin caller sees the cap-subjects table.

  SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md` §8.1.
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
    :ok
  end

  defp admin_conn do
    # SPEC #324 rev 3: LV expects both `current_entity_uri` AND
    # `current_workspace_uri` in the session (set by LiveAuth on the
    # production mount path). Tests must inject both.
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
      "current_workspace_uri" => "workspace://system"
    })
  end

  defp non_admin_conn do
    uri = "entity://team-alpha/user/admin_caps_test_user"
    {:ok, _user} = Ezagent.Users.create(URI.parse(uri), nil, [])

    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => uri,
      "current_workspace_uri" => "workspace://team-alpha"
    })
  end

  describe "/admin/caps admin gate" do
    test "admin caller mounts successfully + sees cap subjects" do
      {:ok, _lv, html} = live(admin_conn(), "/admin/caps")

      # Page rendered (not a redirect).
      assert html =~ "Capability subjects"
      # At least one production cap subject is visible (Chat / Session is
      # always registered by EzagentDomainInstanceMessage.Application.start/2).
      assert html =~ "Ezagent.Behavior.Session" or html =~ "Ezagent.Entity.Session"
    end

    test "non-admin caller is redirected away from /admin/caps" do
      assert {:error, redirect} = live(non_admin_conn(), "/admin/caps")

      assert match?({:live_redirect, %{to: "/sessions"}}, redirect) or
               match?({:redirect, %{to: "/sessions"}}, redirect)
    end
  end

  describe "/admin/caps surface content" do
    test "renders the default-grants section" do
      {:ok, _lv, html} = live(admin_conn(), "/admin/caps")
      assert html =~ "Default grants"
      # `Ezagent.Entity.User` is registered with a default-grant fn by
      # EzagentDomainIdentity.Application.start/2.
      assert html =~ "Ezagent.Entity.User"
    end

    test "renders the dispatchable / cap-only badge column" do
      {:ok, _lv, html} = live(admin_conn(), "/admin/caps")
      assert html =~ "dispatchable"
    end
  end
end
