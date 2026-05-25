defmodule EzagentPluginLiveview.UsersLiveTest do
  use ExUnit.Case
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

  test "GET /identities/users renders existing admin row + create form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/identities/users")
    assert html =~ "Users"
    assert html =~ "entity://user/system/admin"
    assert html =~ "Create user"
  end

  test "create_user persists + appears in list", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/users")
    handle = "lv-create-#{System.unique_integer([:positive])}"
    # Phase 9 PR-3 (SPEC v3 §3): bare handles upgrade to 3-segment
    # `entity://user/<picked-workspace>/<handle>`. Test admin only has
    # the `system` workspace available in the dropdown.
    uri = "entity://user/system/" <> handle

    # Phase 8c PR-O — bare handle accepted; backend normalizes.
    lv
    |> form("#create-user form",
      user: %{
        handle: handle,
        display_name: "Test Display",
        password: "pw",
        caps: "workspace.workspace",
        workspace: "system"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ uri
    assert %{} = Ezagent.Users.get_by_uri(uri)
  end

  test "create_user refuses '*' caps via UI (must use mix --allow-allcaps)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/users")
    handle = "lv-allcaps-#{System.unique_integer([:positive])}"
    # Phase 9 PR-3 (SPEC v3 §3): bare handles upgrade to 3-segment
    # `entity://user/team-alpha/<handle>`.
    uri = "entity://user/team-alpha/" <> handle

    lv
    |> form("#create-user form",
      user: %{
        handle: handle,
        password: "pw",
        caps: "*"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ "allow-allcaps"
    assert nil == Ezagent.Users.get_by_uri(uri)
  end

  test "create_user accepts bare handle (Task 3 — Phase 8c PR-O)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/users")
    handle = "lv-bare-#{System.unique_integer([:positive])}"
    # Phase 9 PR-3 (SPEC v3 §3): bare handles upgrade to 3-segment
    # `entity://user/<picked-workspace>/<handle>`. Test admin only has
    # the `system` workspace available in the dropdown.
    expected_uri = "entity://user/system/" <> handle

    lv
    |> form("#create-user form",
      user: %{
        handle: handle,
        password: "",
        caps: "",
        workspace: "system"
      }
    )
    |> render_submit()

    html = render(lv)
    assert html =~ expected_uri
    assert %{} = Ezagent.Users.get_by_uri(expected_uri)
  end

  test "create_user persists display_name when supplied (Task 1 — Phase 8c PR-O)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/users")
    handle = "lv-dn-#{System.unique_integer([:positive])}"
    # Phase 9 PR-3 (SPEC v3 §3): bare handles upgrade to 3-segment
    # `entity://user/<picked-workspace>/<handle>`. Test admin only has
    # the `system` workspace available in the dropdown.
    uri = "entity://user/system/" <> handle

    lv
    |> form("#create-user form",
      user: %{
        handle: handle,
        display_name: "Spelled Out",
        password: "",
        caps: "",
        workspace: "system"
      }
    )
    |> render_submit()

    # Display name is what EntityPresenter resolves the URI to now.
    assert Ezagent.EntityPresenter.display(uri) == "Spelled Out"
  end

  test "set_password updates an existing user (PR 4 path)" do
    # Direct facade test — UI form submission with hidden field is
    # awkward in Phoenix.LiveViewTest; the facade is exercised in
    # PR 4 unit tests + the LV button is plain HTML POST.
    uri = "entity://user/team-alpha/lv-setpw-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(uri, nil, [])
    refute Ezagent.Users.verify_password(uri, "anything")

    assert {:ok, _} = Ezagent.Users.set_password(uri, "new-pw")
    assert Ezagent.Users.verify_password(uri, "new-pw")
  end

  describe "Presence online dot (PR-D of Presence rollout)" do
    test "user tracked in Presence renders the green dot", %{conn: conn} do
      handle = "lv-online-#{System.unique_integer([:positive])}"
      uri = URI.parse("entity://user/team-alpha/" <> handle)
      {:ok, _} = Ezagent.Users.create(URI.to_string(uri), nil, [])

      # Track from a separate process so the entry stays alive for
      # the duration of the LV render.
      tracker =
        spawn(fn ->
          {:ok, _} = Ezagent.Presence.track(uri, "test_dot", %{transport: :liveview})

          receive do
            :exit -> :ok
          end
        end)

      # Give Phoenix.Presence a tick to register
      Process.sleep(50)
      assert Ezagent.Presence.present?(uri)

      {:ok, _lv, html} = live(conn, "/identities/users")

      # Green dot for online — bg-emerald-500 class
      assert html =~ "bg-emerald-500"
      # Tooltip mentions transport
      assert html =~ "liveview"

      send(tracker, :exit)
    end

    test "untracked user renders the gray dot", %{conn: conn} do
      handle = "lv-offline-#{System.unique_integer([:positive])}"
      uri = "entity://user/team-alpha/" <> handle
      {:ok, _} = Ezagent.Users.create(uri, nil, [])

      refute Ezagent.Presence.present?(URI.parse(uri))

      {:ok, _lv, html} = live(conn, "/identities/users")

      assert html =~ "bg-zinc-300"
    end
  end
end
