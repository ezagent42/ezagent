defmodule Ezagent.World.ViewCapGateRegressionTest do
  @moduledoc """
  Stage 3+4 — the cap-gate REGRESSION LOCK for world's registry-driven view
  enumeration (Allen lead-go: "world 枚举 view 最大的坑是绕过 authorize_view").

  Nails the security property end-to-end against a REAL capped/uncapped/anon
  caller (`Ezagent.Users.create_read_only` + `Ezagent.Identity.list_caps_for`,
  the same read `authorize_view/3` runs in prod):

    (a) a cap-gated view emits NO tab in `state_for/2`'s `"views"` for a caller
        WITHOUT the render cap;
    (b) same for an anon (nil) caller;
    (c) `switch_view/3` to a view id the caller can't see → `error:bad_view`
        (whitelist is same-source with tab visibility — not switchable either);
    (d) a caller HOLDING the render cap sees the tab AND can switch to it;
    (e) P2 test-supplement — the REVOKE transition: a caller who held the
        render cap and lost it (`Ezagent.EntityCaps.revoke/2`, the same
        mutation a real membership/role change drives) loses the tab on the
        VERY NEXT read — `authorize_view/3` re-derives the caller's caps LIVE
        (`Ezagent.Identity.list_caps_for/1` → `EntityCaps.load/1`) rather than
        trusting a cached/mount-time snapshot, so there is no stale-grant
        window. Driven through the SAME public read surface as (a)-(d)
        (`ConversationData.state_for/2`), not the registry internals.

  If anyone ever rewires world's enumeration off `applicable_views/2` (or the
  switch whitelist off `session_view_ids/2`), (a)–(c) go red. Do not delete.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.{ConversationActions, ConversationData}

  # A cap-only render ActionSet backing the gated view (the HelloRender shape):
  # `authorize_view/3` derives the needed render caps from `actions/0`.
  defmodule LockedRender do
    @moduledoc false
    def actions, do: [:locked_render]
  end

  # A cap-gated SessionView: visible/switchable ONLY to callers holding
  # LockedRender's render cap on the concrete session.
  defmodule LockedView do
    @moduledoc false
    @behaviour Ezagent.UI.SessionView
    use Phoenix.Component

    def id, do: :test_locked
    def label, do: "Locked"
    def icon, do: "lock"
    def applies_to?(%URI{}), do: true
    def applies_to?(_), do: false
    def view_behavior, do: LockedRender
    def render(assigns), do: ~H""
  end

  setup do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    :ok = Ezagent.UI.SessionViewRegistry.register(LockedView)

    session =
      Ezagent.URI.new!("session://system/generic/capgate-#{System.unique_integer([:positive])}")

    %{session: session}
  end

  defp render_cap(session, grantee) do
    requested =
      Ezagent.Capability.cap(
        :session,
        LockedRender,
        :locked_render,
        Ezagent.URI.instance(session),
        Ezagent.Capability.workspace_of(session)
      )

    Ezagent.Test.CapHelper.with_test_authority(session, :session, fn authority ->
      Ezagent.Test.CapHelper.authority_signed_cap!(authority, grantee, requested)
    end)
  end

  # A REAL user whose caps `Ezagent.Identity.list_caps_for/1` (the gate's read
  # path) returns — no stubbing of the authorization read.
  defp live_user(caps) do
    uri =
      Ezagent.URI.new!("entity://system/user/capgate-#{System.unique_integer([:positive])}")

    {:ok, _} = Ezagent.Users.create_read_only(uri, caps)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp live_user_with_render_cap(session) do
    uri =
      Ezagent.URI.new!("entity://system/user/capgate-#{System.unique_integer([:positive])}")

    cap = render_cap(session, uri)
    {:ok, _} = Ezagent.Users.create_read_only(uri, [cap])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp view_ids_in_state(session, caller) do
    session
    |> ConversationData.state_for(%{
      caller_uri: caller,
      workspace_uri: Ezagent.Capability.workspace_of(session),
      sessions: []
    })
    |> Map.fetch!("views")
    |> Enum.map(& &1["id"])
  end

  # Minimal LiveView socket stub: enough assigns for switch_view + push_world_state.
  defp build_socket(assigns) do
    base = Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :world_state, %{})
    Enum.reduce(assigns, base, fn {k, v}, acc -> Phoenix.Component.assign(acc, k, v) end)
  end

  test "(a) a caller WITHOUT the cap gets no gated tab in state_for views", %{session: session} do
    uncapped = live_user([])
    ids = view_ids_in_state(session, uncapped)

    assert "conversation" in ids
    refute "test_locked" in ids
  end

  test "(b) an anon (nil) caller gets no gated tab in state_for views", %{session: session} do
    ids = view_ids_in_state(session, nil)

    assert "conversation" in ids
    refute "test_locked" in ids
  end

  test "(c) switch_view to an unauthorized gated view id → error:bad_view", %{session: session} do
    uncapped = live_user([])

    assert {:noreply, socket} =
             ConversationActions.switch_view(
               build_socket(current_entity_uri: uncapped),
               session,
               "test_locked"
             )

    assert socket.assigns.last_dispatch_status == "error:bad_view"
    refute Map.get(socket.assigns.world_state, "active_view") == "test_locked"

    # anon (nil caller) can't switch either
    assert {:noreply, anon_socket} =
             ConversationActions.switch_view(
               build_socket(current_entity_uri: nil),
               session,
               "test_locked"
             )

    assert anon_socket.assigns.last_dispatch_status == "error:bad_view"
  end

  # switch_to_pty/3 is the one path besides switch_view/3 that sets active_view,
  # hard-wired to "pty". That is only safe while the pty view is NOT cap-gated.
  # If this goes red (someone gave TerminalView a view_behavior), switch_to_pty
  # MUST be routed through session_view_ids/2 — see the comment on switch_to_pty.
  test "guard: the pty view stays non-cap-gated (switch_to_pty's safety assumption)" do
    assert Ezagent.UI.SessionView.backing_behavior(EzagentDomainUi.Pty.TerminalView) == nil
  end

  test "(d) a caller HOLDING the render cap sees the gated tab and can switch to it", %{
    session: session
  } do
    capped = live_user_with_render_cap(session)

    ids = view_ids_in_state(session, capped)
    assert "test_locked" in ids

    assert {:noreply, socket} =
             ConversationActions.switch_view(
               build_socket(current_entity_uri: capped),
               session,
               "test_locked"
             )

    assert socket.assigns.world_state["active_view"] == "test_locked"
  end

  test "(e) a caller who holds the cap then has it REVOKED loses the tab on the next read",
       %{session: session} do
    caller = live_user([])
    cap = render_cap(session, caller)

    # Before the grant: no tab (same as (a)).
    refute "test_locked" in view_ids_in_state(session, caller)

    :ok = Ezagent.EntityCaps.grant(caller, cap)
    assert "test_locked" in view_ids_in_state(session, caller),
           "setup failed: the grant did not surface the tab"

    :ok = Ezagent.EntityCaps.revoke(caller, cap)

    refute "test_locked" in view_ids_in_state(session, caller),
           "a revoked render cap must drop the tab on the very next read — " <>
             "authorize_view/3 must not be trusting a cached/mount-time cap snapshot"

    # switch_view is the SAME whitelist source — the revoked caller can no
    # longer switch to it either.
    assert {:noreply, socket} =
             ConversationActions.switch_view(
               build_socket(current_entity_uri: caller),
               session,
               "test_locked"
             )

    assert socket.assigns.last_dispatch_status == "error:bad_view"
  end
end
