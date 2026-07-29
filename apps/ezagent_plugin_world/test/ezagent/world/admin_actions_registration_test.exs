defmodule Ezagent.World.AdminActionsRegistrationTest do
  @moduledoc """
  P2 test-supplement — `Ezagent.World.AdminActions.save_registration/2` (the
  public-registration `open?` / `require_invite?` toggle) had no behavior
  test. Security-relevant: flipping `registration_open` controls whether
  anyone on the internet can self-register a workspace.

  `save_registration/2` gates on `Ezagent.Identity.admin?/1` — DISTINCT from
  (and STRICTER than) `Ezagent.Identity.AdminAuthority.admin?/2` used by
  `UserActions`/`require_admin`: it is an EXACT-identity check against the
  literal canonical `Ezagent.Entity.User.admin_uri/0`, not a "URI host ==
  system" structural check. Pins:

    * a plain non-admin caller is rejected, settings unchanged.
    * a caller whose URI HOST is `system` (would satisfy the broader
      `AdminAuthority.admin?/2`) but is NOT the literal canonical admin URI is
      ALSO rejected — proves this gate is stricter, not just "system host".
    * the literal canonical admin succeeds and the settings persist via
      `Ezagent.AppSettings`.

  The canonical admin is used here ONLY as a caller reading/writing the
  GLOBAL `app_settings` table (`Ecto.Repo`-backed, rolled back by the
  DataCase sandbox) — it is never the disable/mutation TARGET and nothing is
  durably granted to its own Identity slice, so this stays clear of the
  shared-state risk called out in `user_actions_test.exs`.
  """
  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.AppSettings
  alias Ezagent.World.AdminActions

  defp uniq, do: System.unique_integer([:positive])

  defp socket_for(caller) do
    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, caller)
    |> assign(:current_workspace_uri, URI.new!("workspace://system"))
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
    |> assign(:last_dispatch_status, "idle")
  end

  setup do
    # Baseline the two flags so each test starts from a KNOWN state instead
    # of whatever a sibling test (or another agent's run against this
    # partitioned DB) last left them at.
    :ok = AppSettings.put("registration_open", false)
    :ok = AppSettings.put("registration_require_invite", false)
    :ok
  end

  test "a plain non-admin caller is rejected; settings are unchanged" do
    caller = URI.new!("entity://team-alpha/user/plain-#{uniq()}")

    {:noreply, out} =
      AdminActions.handle_dispatch(socket_for(caller), "admin.registration.save", %{
        "registration" => %{"open" => "true", "require_invite" => "true"}
      })

    assert out.assigns.last_dispatch_status == "error:unauthorized"
    assert AppSettings.get("registration_open") == false
    assert AppSettings.get("registration_require_invite") == false
  end

  test "a system-host caller that is NOT the literal canonical admin is ALSO rejected" do
    # Would pass `AdminAuthority.admin?/2` (home_is_system?) but this gate is
    # an exact-identity check — proves the stricter contract.
    caller = URI.new!("entity://system/user/admin-lookalike-#{uniq()}")
    refute URI.to_string(caller) == URI.to_string(Ezagent.Entity.User.admin_uri())

    {:noreply, out} =
      AdminActions.handle_dispatch(socket_for(caller), "admin.registration.save", %{
        "registration" => %{"open" => "true", "require_invite" => "true"}
      })

    assert out.assigns.last_dispatch_status == "error:unauthorized"
    assert AppSettings.get("registration_open") == false
  end

  test "the canonical admin CAN toggle registration open + require_invite" do
    admin = Ezagent.Entity.User.admin_uri()

    {:noreply, out} =
      AdminActions.handle_dispatch(socket_for(admin), "admin.registration.save", %{
        "registration" => %{"open" => "true", "require_invite" => "true"}
      })

    assert out.assigns.last_dispatch_status == "ok"
    assert AppSettings.get("registration_open") == true
    assert AppSettings.get("registration_require_invite") == true
  end

  test "the canonical admin can also turn registration back off" do
    admin = Ezagent.Entity.User.admin_uri()
    :ok = AppSettings.put("registration_open", true)

    {:noreply, out} =
      AdminActions.handle_dispatch(socket_for(admin), "admin.registration.save", %{
        "registration" => %{"open" => "false", "require_invite" => "false"}
      })

    assert out.assigns.last_dispatch_status == "ok"
    assert AppSettings.get("registration_open") == false
  end

  test "an unrecognized admin action degrades to error:unsupported_action" do
    admin = Ezagent.Entity.User.admin_uri()

    {:noreply, out} =
      AdminActions.handle_dispatch(socket_for(admin), "admin.self_destruct", %{})

    assert out.assigns.last_dispatch_status == "error:unsupported_action"
  end
end
