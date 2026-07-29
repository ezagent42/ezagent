defmodule Ezagent.World.UserActionsTest do
  @moduledoc """
  P2 test-supplement — `Ezagent.World.UserActions` (328 lines: admin-only
  create/profile-save/password-set/disable/enable dispatch for the world
  identities surface) had ZERO test references before this file.

  Pins:

    * **self-disable guard** (`ensure_not_self/2`): an admin cannot disable
      their OWN account through this surface — `error:self_disable_denied`,
      checked BEFORE the target-exists lookup, so it holds even for a caller
      row that was never persisted.
    * **`require_admin/1` gate**: every mutating action (profile save,
      password set, disable, enable) rejects a non-admin caller with
      `error:unauthorized` and performs NO mutation.
    * **malformed/missing input**: a non-user-scheme or garbage `user_uri`
      degrades to `error:invalid_user_uri`; a well-formed but unregistered
      user degrades to `error:user_not_found` — neither crashes.
    * **admin positive path**: disable / enable / profile-save / password-set
      on a REAL, non-self user succeed and are observable in the backing
      store (`Ezagent.Users`, `Ezagent.Entity.Profile`).
    * **`users.create` validation + authz**: required-field/name-format
      validation runs before any dispatch, and a non-admin (zero-cap) caller
      is denied by the underlying Workspace CapBAC — no row is persisted.
    * an unrecognized action degrades to `error:unsupported_action` (the
      catch-all clause).

  Admin callers use a DISPOSABLE `entity://system/user/<uniq>` URI — NEVER
  the canonical `Ezagent.Entity.User.admin_uri/0`. `AdminAuthority.admin?/2`'s
  `home_is_system?/1` clause is purely structural (URI host/workspace name ==
  "system"; no spawn, no DB row, no live process required), so this reads as
  admin with zero shared-state risk. The canonical admin's live Identity
  slice is NOT rolled back by the Ecto sandbox — mutating it here would leak
  into sibling tests (see `save_session_template_public_scope_gate_test.exs`
  for the same caution, there worked around with an explicit `on_exit`
  terminate).
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Entity.Profile
  alias Ezagent.World.UserActions
  alias Ezagent.Users

  defp uniq, do: System.unique_integer([:positive])

  defp disposable_admin, do: URI.new!("entity://system/user/admin-probe-#{uniq()}")
  defp non_admin, do: URI.new!("entity://team-alpha/user/plain-#{uniq()}")

  # A REAL (persisted + spawned) admin row — needed only where the test must
  # durably GRANT the admin a concrete cap (`Ezagent.EntityCaps.grant/2`
  # requires its mutation target to already exist as a live/creatable
  # entity). `disposable_admin/0` stays a bare, never-persisted URI for every
  # test that only needs the structural `home_is_system?/1` admin check.
  defp real_disposable_admin! do
    uri = disposable_admin()
    {:ok, _row} = Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp real_user! do
    uri = URI.new!("entity://team-alpha/user/target-#{uniq()}")
    {:ok, _row} = Users.create(uri, "pw-not-secret-#{uniq()}", [])
    # `users.password.set` dispatches a `:call`-mode Invocation at the target
    # user's Kind, which needs a LIVE actor (unlike `disable`/`enable`, which
    # write the `users` row directly via `Ezagent.Users` — no live process
    # needed for those).
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp socket_for(caller, workspace_uri \\ URI.new!("workspace://system")) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, workspace_uri)
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
    |> assign(:last_dispatch_status, "idle")
  end

  # ----- self-disable guard ------------------------------------------------

  describe "self-disable guard (ensure_not_self/2)" do
    test "an admin cannot disable their own account" do
      admin = disposable_admin()
      socket = socket_for(admin)

      {:noreply, out} =
        UserActions.handle_dispatch(socket, "users.disable", %{
          "user_uri" => URI.to_string(admin),
          "reason" => "self-attempt"
        })

      assert out.assigns.last_dispatch_status == "error:self_disable_denied"
    end

    test "the self-disable guard fires even when the caller row does not exist" do
      # ensure_not_self runs BEFORE ensure_user_exists — the guard is a pure
      # URI-identity comparison, not a DB round-trip, so it holds even for a
      # caller/target that was never persisted as a Users row.
      admin = disposable_admin()
      refute Users.get_by_uri(admin)

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.disable", %{
          "user_uri" => URI.to_string(admin)
        })

      assert out.assigns.last_dispatch_status == "error:self_disable_denied"
    end

    test "an admin CAN disable a different (real) user" do
      admin = disposable_admin()
      target = real_user!()
      refute Users.disabled?(target)

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.disable", %{
          "user_uri" => URI.to_string(target),
          "reason" => "policy violation"
        })

      assert out.assigns.last_dispatch_status == "ok"
      assert Users.disabled?(target)
    end
  end

  # ----- require_admin gate -------------------------------------------------

  describe "require_admin/1 gate — non-admin caller rejected" do
    test "users.disable" do
      target = real_user!()
      caller = non_admin()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(caller), "users.disable", %{
          "user_uri" => URI.to_string(target)
        })

      assert out.assigns.last_dispatch_status == "error:unauthorized"
      refute Users.disabled?(target)
    end

    test "users.enable" do
      target = real_user!()
      {:ok, _} = Users.disable(target, disposable_admin(), "setup")
      caller = non_admin()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(caller), "users.enable", %{
          "user_uri" => URI.to_string(target)
        })

      assert out.assigns.last_dispatch_status == "error:unauthorized"
      assert Users.disabled?(target)
    end

    test "users.profile.save" do
      target = real_user!()
      caller = non_admin()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(caller), "users.profile.save", %{
          "user_uri" => URI.to_string(target),
          "display_name" => "Hijacked Name"
        })

      assert out.assigns.last_dispatch_status == "error:unauthorized"
      refute match?(%Profile{display_name: "Hijacked Name"}, Profile.get(target))
    end

    test "users.password.set" do
      target = real_user!()
      caller = non_admin()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(caller), "users.password.set", %{
          "user_uri" => URI.to_string(target),
          "password" => "new-password-123"
        })

      assert out.assigns.last_dispatch_status == "error:unauthorized"
    end
  end

  # ----- malformed / missing input -----------------------------------------

  describe "malformed input degrades cleanly (no crash)" do
    test "garbage user_uri -> invalid_user_uri" do
      admin = disposable_admin()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.disable", %{
          "user_uri" => "not a uri at all"
        })

      assert out.assigns.last_dispatch_status == "error:invalid_user_uri"
    end

    test "well-formed but non-user entity scheme -> invalid_user_uri" do
      admin = disposable_admin()
      agent_uri = "entity://team-alpha/agent/some-agent"

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.disable", %{
          "user_uri" => agent_uri
        })

      assert out.assigns.last_dispatch_status == "error:invalid_user_uri"
    end

    test "well-formed but unregistered user -> user_not_found" do
      admin = disposable_admin()
      ghost = URI.new!("entity://team-alpha/user/ghost-#{uniq()}")
      refute Users.get_by_uri(ghost)

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.disable", %{
          "user_uri" => URI.to_string(ghost)
        })

      assert out.assigns.last_dispatch_status == "error:user_not_found"
    end

    test "missing user_uri key on a mutating action does not crash" do
      admin = disposable_admin()

      {:noreply, out} = UserActions.handle_dispatch(socket_for(admin), "users.enable", %{})

      assert out.assigns.last_dispatch_status == "error:invalid_user_uri"
    end
  end

  # ----- admin positive path ------------------------------------------------

  describe "admin positive path" do
    test "enable reverses a prior disable" do
      admin = disposable_admin()
      target = real_user!()
      {:ok, _} = Users.disable(target, admin, "temp")
      assert Users.disabled?(target)

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.enable", %{
          "user_uri" => URI.to_string(target)
        })

      assert out.assigns.last_dispatch_status == "ok"
      refute Users.disabled?(target)
    end

    test "profile.save persists display_name + email" do
      admin = disposable_admin()
      target = real_user!()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.profile.save", %{
          "user_uri" => URI.to_string(target),
          "display_name" => "Ada Lovelace",
          "email" => "ada@example.com"
        })

      assert out.assigns.last_dispatch_status == "ok"
      profile = Profile.get(target)
      assert profile.display_name == "Ada Lovelace"
      assert profile.email == "ada@example.com"
    end

    test "password.set succeeds for an admin caller holding the concrete cap" do
      # `users.password.set` (unlike disable/enable/profile.save, which write
      # `Ezagent.Users`/`Ezagent.Entity.Profile` directly via Repo) dispatches
      # a real `:call`-mode Invocation at the TARGET's Kind — the CapBAC
      # chokepoint additionally requires the caller to hold a genuine cap for
      # THIS instance/action, not just pass the structural `require_admin/1`
      # gate. Mint + durably grant the exact action cap to the disposable
      # admin (same pattern as `admission_gate_world_invite_test.exs`'s
      # `invite_socket/2`) rather than reach for the canonical admin's
      # bootstrap wildcard — keeps this test independent of prod-only seed
      # state and off the shared canonical admin entirely.
      admin = real_disposable_admin!()
      target = real_user!()

      set_password_target =
        Ezagent.URI.with_action(target, :user_credentials, :set_password)

      cap = Ezagent.Test.CapHelper.signed_action_cap!(set_password_target, admin)
      :ok = Ezagent.EntityCaps.grant(admin, cap)

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.password.set", %{
          "user_uri" => URI.to_string(target),
          "password" => "brand-new-password-123"
        })

      assert out.assigns.last_dispatch_status == "ok"
    end

    test "password.set with a blank password is rejected as a validation error" do
      admin = disposable_admin()
      target = real_user!()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.password.set", %{
          "user_uri" => URI.to_string(target),
          "password" => ""
        })

      assert out.assigns.last_dispatch_status == "error:password_required"
    end
  end

  # ----- users.create: pure validation (no caps needed) ---------------------

  describe "users.create validation" do
    test "missing name -> name_required, no dispatch attempted" do
      admin = disposable_admin()
      ws = URI.new!("workspace://team-alpha-#{uniq()}")

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin, ws), "users.create", %{
          "user" => %{"password" => "pw-12345678"}
        })

      assert out.assigns.last_dispatch_status == "error:name_required"
    end

    test "missing password -> password_required" do
      admin = disposable_admin()
      ws = URI.new!("workspace://team-alpha-#{uniq()}")

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin, ws), "users.create", %{
          "user" => %{"name" => "newbie"}
        })

      assert out.assigns.last_dispatch_status == "error:password_required"
    end

    test "invalid name format is rejected before any dispatch" do
      admin = disposable_admin()
      ws = URI.new!("workspace://team-alpha-#{uniq()}")

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin, ws), "users.create", %{
          "user" => %{"name" => "Not Valid!", "password" => "pw-12345678"}
        })

      assert out.assigns.last_dispatch_status =~ "error:"
      assert out.assigns.last_dispatch_status =~ "bad_name"
    end
  end

  # ----- users.create: authz denial (real CapBAC chokepoint) ----------------

  describe "users.create authz — non-admin (zero-cap) caller is denied" do
    test "a plain caller with no caps cannot create a workspace user" do
      caller = non_admin()
      ws_name = "wcreate-#{uniq()}"
      {:ok, _} = Ezagent.Workspace.create(ws_name, %{})
      workspace_uri = URI.new!("workspace://#{ws_name}")
      new_user_name = "shouldnotexist#{uniq()}"

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(caller, workspace_uri), "users.create", %{
          "user" => %{"name" => new_user_name, "password" => "pw-12345678"}
        })

      assert out.assigns.last_dispatch_status =~ "error:"

      created_uri = URI.new!("entity://#{ws_name}/user/#{new_user_name}")
      refute Users.get_by_uri(created_uri)
    end
  end

  # ----- unsupported action --------------------------------------------------

  describe "unsupported action" do
    test "an unrecognized action degrades to error:unsupported_action" do
      admin = disposable_admin()

      {:noreply, out} =
        UserActions.handle_dispatch(socket_for(admin), "users.teleport", %{"user_uri" => "x"})

      assert out.assigns.last_dispatch_status == "error:unsupported_action"
    end
  end
end
