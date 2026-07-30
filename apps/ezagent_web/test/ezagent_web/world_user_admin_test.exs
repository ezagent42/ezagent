defmodule EzagentWeb.WorldUserAdminTest do
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ezagent.Entity.Profile
  alias Ezagent.Users

  test "admin user-management routes mount the new-user and user-detail surfaces", %{conn: conn} do
    user_uri = Ezagent.URI.user(:system, unique_name("route-user"))
    {:ok, _user} = Users.create(user_uri, "route-password", [])

    encoded = user_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, form_view, form_html} = live(admin_conn(conn), "/identities/users/new")
    assert form_html =~ ~s(id="world-root")
    assert has_element?(form_view, "#world-root[data-world-component='user_new_form']")

    {:ok, detail_view, detail_html} = live(admin_conn(conn), "/identities/users/#{encoded}")
    assert detail_html =~ ~s(id="world-root")
    assert has_element?(detail_view, "#world-root[data-world-component='user_detail']")
  end

  test "admin can create a user from the world user form", %{conn: conn} do
    name = unique_name("created-user")
    user_uri = Ezagent.URI.user(:system, name)
    encoded = user_uri |> URI.to_string() |> URI.encode_www_form()
    email = "#{name}@example.test"

    {:ok, view, _html} = live(admin_conn(conn), "/identities/users/new")

    assert {:error, {:live_redirect, %{to: "/identities/users/" <> ^encoded}}} =
             view
             |> element("#world-root")
             |> render_hook("world:dispatch", %{
               "action" => "users.create",
               "args" => %{
                 "user" => %{
                   "name" => name,
                   "display_name" => "Created User",
                   "email" => email,
                   "password" => "created-password"
                 }
               }
             })

    assert Users.verify_password(user_uri, "created-password")

    assert %Profile{display_name: "Created User", email: ^email} = Profile.get(user_uri)
  end

  # This E2E performs four synchronous LiveView dispatches plus two bcrypt
  # verifications. It completes in ~2s alone, but the full umbrella sweep can
  # delay its shared-sandbox calls behind thousands of still-draining Kind
  # processes and exhaust ExUnit's 60s *whole-test* budget while the final
  # enable dispatch is waiting. The domain calls remain bounded; quarantine the
  # runner-load variance at the E2E boundary, as HomeLive's create path does.
  @tag timeout: 180_000
  test "admin can edit profile, reset password, disable, and enable a user", %{conn: conn} do
    user_uri = Ezagent.URI.user(:system, unique_name("managed-user"))
    {:ok, _user} = Users.create(user_uri, "old-password", [])
    :ok = Ezagent.Entity.spawn_principal(user_uri)
    {:ok, _profile} = Profile.upsert(%{entity_uri: user_uri, display_name: "Managed User"})

    encoded = user_uri |> URI.to_string() |> URI.encode_www_form()
    {:ok, view, html} = live(admin_conn(conn), "/identities/users/#{encoded}")

    assert has_element?(view, "#world-root[data-world-component='user_detail']")
    assert world_state(html)["display_name"] == "Managed User"

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "users.profile.save",
        "args" => %{
          "user_uri" => URI.to_string(user_uri),
          "display_name" => "Managed User Renamed",
          "email" => "managed-renamed@example.test"
        }
      })

    assert html =~ ~s(data-last-dispatch="ok")

    assert %Profile{display_name: "Managed User Renamed", email: "managed-renamed@example.test"} =
             Profile.get(user_uri)

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "users.password.set",
        "args" => %{"user_uri" => URI.to_string(user_uri), "password" => "new-password"}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert Users.verify_password(user_uri, "new-password")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "users.disable",
        "args" => %{"user_uri" => URI.to_string(user_uri), "reason" => "left team"}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert world_state(html)["disabled"] == true
    assert Users.disabled?(user_uri)
    refute Users.verify_password(user_uri, "new-password")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "users.enable",
        "args" => %{"user_uri" => URI.to_string(user_uri)}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert world_state(html)["disabled"] == false
    refute Users.disabled?(user_uri)
    assert Users.verify_password(user_uri, "new-password")
  end

  test "admin cannot disable their own signed-in account", %{conn: conn} do
    admin_uri = Ezagent.Entity.User.admin_uri()
    encoded = admin_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/identities/users/#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "users.disable",
        "args" => %{"user_uri" => URI.to_string(admin_uri), "reason" => "mistake"}
      })

    assert html =~ ~s(data-last-dispatch="error:self_disable_denied")
    assert world_state(html)["action_error"] =~ "不能禁用当前登录用户"

    case Users.get_by_uri(admin_uri) do
      nil -> :ok
      user -> assert is_nil(user.disabled_at)
    end
  end

  defp admin_conn(conn) do
    conn
    |> Map.put(:host, "world.ezagent.chat")
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
      "current_workspace_uri" => "workspace://system"
    })
  end

  defp unique_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp world_state(html) do
    [_, json] = Regex.run(~r/data-world-state="([^"]*)"/, html)

    json
    |> html_unescape()
    |> Jason.decode!()
  end

  defp html_unescape(s) do
    s
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end
end
