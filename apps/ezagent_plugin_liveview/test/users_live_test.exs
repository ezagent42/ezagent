defmodule EzagentPluginLiveview.UsersLiveTest do
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

    # SPEC 2026-05-27-workspace-cap-based-visibility — the previous
    # `users_live.ex` `workspace_options/1` helper synthetically
    # prepended a `system` row regardless of DB state. Post-SPEC the
    # picker reflects `list_workspaces_for(admin_uri, _)` which
    # returns `Store.list_all/0` for admin (the admin URI host is
    # `system`). Seed the workspace so the picker has options.
    case Ezagent.Workspace.Store.get_by_name("system") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("system", %{})
      _ -> :ok
    end

    case Ezagent.Workspace.Store.get_by_name("team-alpha") do
      nil -> {:ok, _} = Ezagent.Workspace.Store.create("team-alpha", %{})
      _ -> :ok
    end

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
    assert html =~ "entity://system/user/admin"
    assert html =~ "Create user"
  end

  test "create_user persists + appears in list", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/identities/users")
    handle = "lv-create-#{System.unique_integer([:positive])}"
    # Phase 9 PR-3 (SPEC v3 §3): bare handles upgrade to 3-segment
    # `entity://user/<picked-workspace>/<handle>`. Test admin only has
    # the `system` workspace available in the dropdown.
    uri = "entity://system/user/" <> handle

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
    # `entity://team-alpha/user/<handle>`.
    uri = "entity://team-alpha/user/" <> handle

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
    expected_uri = "entity://system/user/" <> handle

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
    uri = "entity://system/user/" <> handle

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
    uri = "entity://team-alpha/user/lv-setpw-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(uri, nil, [])
    refute Ezagent.Users.verify_password(uri, "anything")

    assert {:ok, _} = Ezagent.Users.set_password(uri, "new-pw")
    assert Ezagent.Users.verify_password(uri, "new-pw")
  end

  describe "CapBAC parity (HIGH-4 — close LV create/set_password dispatch bypass)" do
    # SPEC 2026-05-27-capability-action-axis §7 / todo.md HIGH-4 GUI
    # side. The `/identities/users` route is gated by `:require_entity`
    # (NOT `:require_admin`), so any logged-in entity reaches these
    # handlers. Before this PR the handlers called `Ezagent.Users.create/3`
    # and `Ezagent.Users.set_password/2` DIRECTLY, bypassing the
    # cap-checked dispatch chokepoint — a non-admin could mint users and
    # reset passwords from the GUI. After this PR both route through
    # `Ezagent.Invocation.dispatch/1` (step 5.5 CapBAC), so an
    # under-privileged caller is REJECTED — identical to the CLI.

    # Build a session whose caller is an under-privileged (non-admin)
    # user living in `team-alpha`. `Ezagent.Users.create/3` grants only
    # the structural workspace-scoped default caps — none of which
    # satisfy `:create_user` (kind `:workspace`) or another user's
    # `:set_password` (admin's `:any`-instance cap).
    defp underprivileged_conn(handle) do
      uri = "entity://team-alpha/user/#{handle}-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(uri, "pw", [])

      # PR-甲-2 (#154): a real onboarded user is added to its workspace's
      # MEMBER set (`Registration.create_principal` → `Workspace.add_member`);
      # `default_caps` is now `[]` (no broad session baseline). Mirror that here
      # so `list_workspaces_for/2` keeps team-alpha visible via `member_match?`
      # (the workspace `<select>` therefore renders "team-alpha"), while the
      # caller still holds NO `:create_user` cap — which is the actual thing this
      # CapBAC-parity test asserts is denied. Pre-甲-2 the dropdown only rendered
      # because the broad baseline accidentally seeded the cap's `workspace_uri`.
      existing =
        case Ezagent.Workspace.Store.get_by_name("team-alpha") do
          %{members: members} when is_list(members) -> members
          _ -> []
        end

      {:ok, _} = Ezagent.Workspace.Store.update_members("team-alpha", [uri | existing])

      # Spawn the User Kind so `Ezagent.Identity.list_caps_for/1`
      # resolves the caller's real (non-admin) caps via dispatch.
      if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
        _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(uri))
      end

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => uri,
          "current_workspace_uri" => "workspace://team-alpha"
        })

      {conn, uri}
    end

    test "create_user is REJECTED for an under-privileged LV caller (no row minted)" do
      {conn, _caller} = underprivileged_conn("create")
      {:ok, lv, _html} = live(conn, "/identities/users")

      handle = "lv-denied-create-#{System.unique_integer([:positive])}"
      target_uri = "entity://team-alpha/user/" <> handle

      lv
      |> form("#create-user form",
        user: %{
          handle: handle,
          password: "pw",
          caps: "",
          workspace: "team-alpha"
        }
      )
      |> render_submit()

      html = render(lv)
      # The cap-check fired and denied — surfaced as a flash error, and
      # NO row was minted (the structural proof the bypass is closed).
      assert html =~ "failed" or html =~ "unauthorized"
      assert nil == Ezagent.Users.get_by_uri(target_uri)
    end

    test "create_user SUCCEEDS for an admin LV caller (authorized path preserved)", %{conn: conn} do
      # `conn` (admin session from `setup`) holds wildcard caps via the
      # bootstrap catalog — dispatch step 5.5 admits it.
      {:ok, lv, _html} = live(conn, "/identities/users")

      handle = "lv-admin-create-#{System.unique_integer([:positive])}"
      uri = "entity://system/user/" <> handle

      lv
      |> form("#create-user form",
        user: %{handle: handle, password: "pw", caps: "", workspace: "system"}
      )
      |> render_submit()

      html = render(lv)
      assert html =~ uri
      assert %{} = Ezagent.Users.get_by_uri(uri)
    end

    test "set_password is REJECTED for an under-privileged LV caller (hash unchanged)" do
      {conn, _caller} = underprivileged_conn("setpw")

      # A victim user the caller must NOT be able to reset.
      victim = "entity://team-alpha/user/lv-victim-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(victim, "orig-pw", [])

      if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
        _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(victim))
      end

      {:ok, lv, _html} = live(conn, "/identities/users")

      render_submit(element(lv, ~s|form[phx-submit="set_password"][data-uri="#{victim}"]|), %{
        "uri" => victim,
        "password" => "attacker-pw"
      })

      html = render(lv)
      assert html =~ "failed" or html =~ "unauthorized"
      # The original password still verifies; the attacker's does not.
      assert Ezagent.Users.verify_password(victim, "orig-pw")
      refute Ezagent.Users.verify_password(victim, "attacker-pw")
    end

    test "caps are read FRESH at mutation time, not cached at mount (codex HIGH)" do
      # Mount as an under-privileged caller (no :create_user cap), THEN
      # grant the cap after mount. If caps were cached at mount the
      # create would still be denied; because they are re-fetched at
      # mutation time, the post-mount grant takes effect immediately.
      # The dispatch target (`workspace://team-alpha`) must be a LIVE
      # Workspace Kind for `:create_user` to route — spawn it.
      _ =
        case Ezagent.Workspace.spawn_workspace("team-alpha") do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> other
        end

      {conn, caller} = underprivileged_conn("freshcaps")
      {:ok, lv, _html} = live(conn, "/identities/users")

      caller_uri = Ezagent.URI.new!(caller)
      ws_uri = Ezagent.URI.workspace("team-alpha")

      # Grant the caller the workspace-user-admin :create_user cap AFTER
      # the LV has already mounted (so any mount-time snapshot is stale).
      :ok =
        Ezagent.Identity.grant_cap(
          caller_uri,
          %Ezagent.Capability{
            kind: :workspace,
            behavior: Ezagent.Behavior.WorkspaceUserAdmin,
            action: :create_user,
            instance: ws_uri,
            workspace_uri: ws_uri,
            granted_by: Ezagent.Entity.User.admin_uri(),
            granted_at: DateTime.utc_now()
          },
          Ezagent.Entity.User.admin_uri()
        )

      handle = "lv-fresh-#{System.unique_integer([:positive])}"
      target_uri = "entity://team-alpha/user/" <> handle

      lv
      |> form("#create-user form",
        user: %{handle: handle, password: "pw", caps: "", workspace: "team-alpha"}
      )
      |> render_submit()

      # The freshly-granted cap authorized the create — proving caps are
      # NOT frozen at mount.
      assert %{} = Ezagent.Users.get_by_uri(target_uri)
    end

    test "set_password SUCCEEDS for an admin LV caller (authorized path preserved)", %{conn: conn} do
      target = "entity://team-alpha/user/lv-admin-setpw-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(target, nil, [])

      if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
        _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(target))
      end

      {:ok, lv, _html} = live(conn, "/identities/users")

      render_submit(element(lv, ~s|form[phx-submit="set_password"][data-uri="#{target}"]|), %{
        "uri" => target,
        "password" => "fresh-pw"
      })

      assert Ezagent.Users.verify_password(target, "fresh-pw")
    end
  end

  describe "CapBAC parity — promote_to_system / revoke_system (admin-promotion bypass)" do
    # SPEC 2026-05-27-capability-action-axis §7 / todo.md "Admin promotion
    # cap-lifecycle cleanup". The `/identities/users` route is gated by
    # `:require_entity` (NOT `:require_admin`). Before this PR the
    # `promote_to_system` / `revoke_system` handlers called
    # `Ezagent.Workspace.add_member/remove_member("system", ...)` — the
    # `/2` programmatic facade that dispatches under
    # `system://workspace-loader`, so NO caller cap-check ran. A non-admin
    # entity could promote ANYONE (including themself) to system-workspace
    # membership — which confers cross-workspace authority — and revoke it.
    # After this PR both route through the cap-checked `/3` variants
    # carrying the caller's FRESH caps, so an under-privileged caller is
    # REJECTED (membership unchanged) — identical to the CLI.

    defp underprivileged_promote_conn(handle, workspace \\ "team-alpha") do
      uri = "entity://#{workspace}/user/#{handle}-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(uri, "pw", [])

      if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
        _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(uri))
      end

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => uri,
          "current_workspace_uri" => "workspace://#{workspace}"
        })

      {conn, uri}
    end

    defp system_members do
      case Ezagent.Workspace.Store.get_by_name("system") do
        nil -> []
        %{members: members} -> Enum.map(members, &URI.to_string/1)
      end
    end

    test "promote_to_system is REJECTED for an under-privileged LV caller (membership unchanged)" do
      # Live system Workspace Kind so the `:add_member` dispatch routes.
      _ =
        case Ezagent.Workspace.spawn_workspace("system") do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> other
        end

      {conn, caller} = underprivileged_promote_conn("promote-denied")
      {:ok, lv, _html} = live(conn, "/identities/users")

      victim = "entity://system/user/lv-promote-victim-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(victim, "pw", [])

      before = system_members()
      render_click(lv, "promote_to_system", %{"uri" => victim})

      html = render(lv)
      # Cap-check fired and denied — surfaced as a flash error, and the
      # system member set is UNCHANGED (the structural proof the bypass
      # is closed). The caller must also not have escalated themself.
      assert html =~ "failed" or html =~ "unauthorized"
      assert system_members() == before
      refute victim in system_members()
      refute caller in system_members()
    end

    test "revoke_system is REJECTED for an under-privileged LV caller (membership unchanged)" do
      _ =
        case Ezagent.Workspace.spawn_workspace("system") do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> other
        end

      # Seed a genuine system member (added by the trusted `/2` path) so
      # there is something to (fail to) revoke.
      member = "entity://system/user/lv-revoke-target-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(member, "pw", [])
      _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(member))
      :ok = Ezagent.Workspace.add_member("system", Ezagent.URI.new!(member))

      {conn, _caller} = underprivileged_promote_conn("revoke-denied")
      {:ok, lv, _html} = live(conn, "/identities/users")

      assert member in system_members()
      render_click(lv, "revoke_system", %{"uri" => member})

      html = render(lv)
      assert html =~ "failed" or html =~ "unauthorized"
      # The under-privileged caller could NOT strip the member's
      # system authority.
      assert member in system_members()
    end

    test "promote_to_system SUCCEEDS for an admin LV caller (authorized path preserved)", %{
      conn: conn
    } do
      _ =
        case Ezagent.Workspace.spawn_workspace("system") do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> other
        end

      target = "entity://system/user/lv-admin-promote-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(target, "pw", [])
      _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(target))

      {:ok, lv, _html} = live(conn, "/identities/users")
      render_click(lv, "promote_to_system", %{"uri" => target})

      # The admin's wildcard caps (bootstrap catalog) admit the cap-check.
      assert target in system_members()
    end

    test "caps are read FRESH at mutation time, not cached at mount (post-mount grant takes effect)" do
      _ =
        case Ezagent.Workspace.spawn_workspace("system") do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> other
        end

      # A system-home caller (so the post-grant promote is not blocked by
      # the cross-workspace isolation step) that still starts WITHOUT the
      # `:add_member` cap — proving the FRESH re-fetch (not a cap cached
      # at mount) is what authorizes the promote.
      {conn, caller} = underprivileged_promote_conn("promote-fresh", "system")
      {:ok, lv, _html} = live(conn, "/identities/users")

      caller_uri = Ezagent.URI.new!(caller)
      system_ws = Ezagent.URI.workspace("system")

      target = "entity://system/user/lv-fresh-promote-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(target, "pw", [])
      _ = Ezagent.SpawnRegistry.spawn(Ezagent.URI.new!(target))

      # Grant the caller the `:add_member` cap on workspace://system AFTER
      # the LV mounted. If caps were cached at mount the promote would be
      # denied; because `current_caller_caps/1` re-fetches, it succeeds.
      :ok =
        Ezagent.Identity.grant_cap(
          caller_uri,
          %Ezagent.Capability{
            kind: :workspace,
            behavior: Ezagent.Behavior.Workspace,
            action: :add_member,
            instance: system_ws,
            workspace_uri: system_ws,
            granted_by: Ezagent.Entity.User.admin_uri(),
            granted_at: DateTime.utc_now()
          },
          Ezagent.Entity.User.admin_uri()
        )

      render_click(lv, "promote_to_system", %{"uri" => target})

      assert target in system_members()
    end
  end

  describe "Part B — revoke_system sweeps the create_session cap granted on promotion" do
    # SPEC 2026-05-27-capability-action-axis §7 Part B (cap-lifecycle).
    # `:add_member` grants the new member a workspace-scoped
    # `:create_session` cap. Pre-fix `:remove_member` left it dangling, so
    # a demoted member retained create_session authority in the workspace.
    # The symmetric `revoke_cap` effect on `:remove_member` sweeps exactly
    # that cap.

    test "the create_session cap is granted on add and swept on remove (system workspace)" do
      _ =
        case Ezagent.Workspace.spawn_workspace("system") do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> other
        end

      member = "entity://system/user/lv-sweep-#{System.unique_integer([:positive])}"
      {:ok, _} = Ezagent.Users.create(member, "pw", [])
      member_uri = Ezagent.URI.new!(member)
      _ = Ezagent.SpawnRegistry.spawn(member_uri)

      system_ws = Ezagent.URI.workspace("system")

      held_create_session_cap? = fn ->
        member_uri
        |> Ezagent.Identity.list_caps_for()
        |> Enum.any?(fn cap ->
          cap.behavior == Ezagent.Behavior.Workspace and
            Ezagent.Capability.action_of(cap) == :create_session and
            URI.to_string(cap.instance) == URI.to_string(system_ws)
        end)
      end

      :ok = Ezagent.Workspace.add_member("system", member_uri)
      # Grant lands via a buffered `:cast` effect on the member's ready
      # transition — give it a moment to settle.
      wait_until(fn -> held_create_session_cap?.() end)
      assert held_create_session_cap?.(), "add_member should grant the create_session cap"

      :ok = Ezagent.Workspace.remove_member("system", member_uri)
      wait_until(fn -> not held_create_session_cap?.() end)

      refute held_create_session_cap?.(),
             "remove_member (Part B sweep) should revoke the create_session cap"
    end
  end

  # Poll a predicate up to ~2s — the cap grant/revoke effects dispatch
  # via buffered `:cast`, so the slice write is eventually-consistent.
  defp wait_until(fun, attempts \\ 40)
  defp wait_until(_fun, 0), do: :ok

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      wait_until(fun, attempts - 1)
    end
  end

  describe "Presence online dot (PR-D of Presence rollout)" do
    test "user tracked in Presence renders the green dot", %{conn: conn} do
      handle = "lv-online-#{System.unique_integer([:positive])}"
      uri = URI.parse("entity://team-alpha/user/" <> handle)
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
      uri = "entity://team-alpha/user/" <> handle
      {:ok, _} = Ezagent.Users.create(uri, nil, [])

      refute Ezagent.Presence.present?(URI.parse(uri))

      {:ok, _lv, html} = live(conn, "/identities/users")

      assert html =~ "bg-zinc-300"
    end
  end
end
