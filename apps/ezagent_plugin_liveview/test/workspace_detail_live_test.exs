defmodule EzagentPluginLiveview.WorkspaceDetailLiveTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    case Ezagent.Workspace.Store.get_by_name("system") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("system", %{})
      _ -> :ok
    end

    _ =
      case Ezagent.Workspace.spawn_workspace("system") do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        other -> other
      end

    :ok
  end

  defp system_members do
    case Ezagent.Workspace.Store.get_by_name("system") do
      nil -> []
      %{members: members} -> Enum.map(members, &URI.to_string/1)
    end
  end

  defp underprivileged_conn(handle) do
    uri = "entity://system/user/#{handle}-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(uri, "pw", [])

    if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
      _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(uri))
    end

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => uri,
        "current_workspace_uri" => "workspace://system"
      })

    {conn, uri}
  end

  describe "CapBAC parity — /workspaces/system member mutations (codex follow-up to SPEC §7)" do
    # `/workspaces/:name` is a `:require_entity` route. Before the fix
    # WorkspaceDetailLive's add_member/remove_member called the `/2`
    # facade (system-loader principal) — the SAME admin-promotion bypass
    # class as UsersLive. Both now route through the cap-checked `/3`
    # variants carrying the caller's fresh caps.

    test "remove_member is REJECTED for an under-privileged caller (system membership unchanged)" do
      # Seed a genuine system member via the trusted /2 path.
      member = "entity://system/user/wd-victim-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(member, "pw", [])
      _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(member))
      :ok = Ezagent.Workspace.add_member("system", Ezagent.URI.new!(member))
      assert member in system_members()

      {conn, _caller} = underprivileged_conn("wd-remove-denied")
      {:ok, lv, _html} = live(conn, "/workspaces/system")

      render_click(lv, "remove_member", %{"member_uri" => member})

      html = render(lv)
      assert html =~ "failed" or html =~ "unauthorized"
      # The under-privileged caller could NOT strip the member.
      assert member in system_members()
    end

    test "add_member is REJECTED for an under-privileged caller (system membership unchanged)" do
      {conn, _caller} = underprivileged_conn("wd-add-denied")
      {:ok, lv, _html} = live(conn, "/workspaces/system")

      target = "entity://system/user/wd-add-target-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(target, "pw", [])

      before = system_members()

      render_submit(element(lv, ~s|form[phx-submit="add_member"]|), %{
        "add_member" => %{"member_uri" => target}
      })

      assert system_members() == before
      refute target in system_members()
    end
  end
end
