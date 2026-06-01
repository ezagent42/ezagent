defmodule EzagentDomainChat.Integration.SessionAutoJoinTest do
  @moduledoc """
  Session member auto-join (Allen 2026-05-26) — regression coverage for
  the gap where the MemberPanel rendered empty even after a session was
  opened.

  2026-05-31 orchestrator-startup-atomicity §7 — the Layer-2 describe
  block (orchestrator + static workers auto-join via the deleted
  `Session.spawn_from_template/2` reconciler) was removed with the
  Generator tree + static multi-slot. The orchestrator member-join is
  now exercised end-to-end by the unified `create_session/3` flow
  (`session_create_orchestrator_unified_test.exs`). The two layers kept
  here cover the parts that did NOT go through the Generator:

  1. **Creator auto-join via create_session/3** — the creator appears in
     `chat.members` WITHOUT a manual Invite.

  2. **`:join` idempotency** — re-dispatching `chat.join` for an
     already-online member does NOT stack monitor refs.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.KindRegistry
  alias Ezagent.Entity.User

  defp uniq, do: System.unique_integer([:positive])

  defp session_members(%URI{} = session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)

    # Lifecycle migration (SPEC 2026-05-29 §2.3C): the Chat slice is now the
    # two-container `%{state, transients}` shape. `members` lives in
    # `:state` (persisted); `monitors` lives in `:transients` (rebuilt by
    # activate/2). Return the same `{members, monitors, persistent_slice}`
    # tuple the callers expect.
    %{state: %{chat: chat}} = :sys.get_state(pid)
    persistent = Map.get(chat, :state, chat)
    transients = Map.get(chat, :transients, %{})
    monitors = Map.get(transients, :monitors, Map.get(persistent, :monitors, %{}))
    {Map.keys(persistent.members), monitors, persistent}
  end

  defp wait_until(fun, retries \\ 100) do
    case fun.() do
      false when retries > 0 ->
        Process.sleep(10)
        wait_until(fun, retries - 1)

      result ->
        result
    end
  end

  # ----------------------------------------------------------------------
  # Layer 1 — creator auto-join via create_session/3
  # ----------------------------------------------------------------------

  describe "creator auto-join (via create_session/3)" do
    test "admin appears in chat.members after create_session" do
      short = "ajs-creator-#{uniq()}"
      admin = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, admin, template_name: "default")

      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(admin)))
             end),
             "admin must appear in chat.members WITHOUT a manual Invite"
    end
  end

  # ----------------------------------------------------------------------
  # Layer 2 — `:join` invoke idempotency at the slice level
  # ----------------------------------------------------------------------

  describe ":join idempotency (Behavior.Chat)" do
    # Codex r1 HIGH-1 (2026-05-26) — strict pid-match short-circuit
    # regression test. The short-circuit MUST verify the held monitor
    # ref is for the SAME pid KindRegistry currently resolves the URI
    # to; otherwise the dead-old-pid + fresh-new-pid + stale-:DOWN
    # window causes the live member to be marked offline.
    test "short-circuit fires only when the held monitor ref is for the CURRENT pid" do
      short = "ajs-pid-#{uniq()}"
      admin = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, admin, template_name: "default")

      # Wait for the creator-auto-join cast to land.
      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(admin)))
             end)

      # The admin Kind's current pid + the session's current monitor
      # ref for admin.
      {:ok, admin_pid_before} = KindRegistry.lookup(admin)

      {_members, monitors_before, _slice} = session_members(session_uri)

      # Check that `:monitored_by` on admin includes the session pid.
      {:ok, session_pid} = KindRegistry.lookup(session_uri)

      {:monitored_by, monitored_by} = Process.info(admin_pid_before, :monitored_by)

      assert session_pid in monitored_by,
             "Session must hold a monitor on the admin pid (the structural " <>
               "anchor for the chat.join idempotency short-circuit)"

      # Repeated chat.join with the SAME admin pid — must NOT stack
      # monitors AND must NOT install a fresh ref (the existing one
      # is for the current pid).
      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      :ok =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :cast,
          args: %{member: admin},
          ctx: %{
            caller: Ezagent.SystemPrincipal.uri("session-internal"),
            caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
            reply: :ignore
          }
        })

      Process.sleep(100)

      {_members_after, monitors_after, _slice} = session_members(session_uri)

      # Same ref + same count — full short-circuit fired.
      assert monitors_after == monitors_before,
             "short-circuit must leave slice.monitors UNCHANGED for same-pid rejoin " <>
               "(pre #{inspect(monitors_before)}, post #{inspect(monitors_after)})"
    end

    test "re-dispatching chat.join for the same member does NOT stack monitors" do
      short = "ajs-idem-#{uniq()}"
      admin = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainChat.create_session(short, admin, template_name: "default")

      # Wait for the creator-auto-join cast to land.
      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(admin)))
             end)

      {_members_before, monitors_before, _slice} = session_members(session_uri)
      ref_count_before = map_size(monitors_before)

      # Dispatch chat.join 5 more times — every one should be a no-op
      # at the slice level (online + monitor alive → short-circuit).
      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      for _ <- 1..5 do
        :ok =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            target: target,
            mode: :cast,
            args: %{member: admin},
            ctx: %{
              caller: Ezagent.SystemPrincipal.uri("session-internal"),
              caps: Ezagent.SystemPrincipal.caps("system://session-internal"),
              reply: :ignore
            }
          })
      end

      # Let the casts drain.
      Process.sleep(150)

      {_members_after, monitors_after, _slice} = session_members(session_uri)

      assert map_size(monitors_after) == ref_count_before,
             "5 repeated chat.join casts must NOT stack monitor refs (was " <>
               "#{ref_count_before}, now #{map_size(monitors_after)}) — " <>
               "Behavior.Chat.invoke(:join) idempotency regression"
    end
  end
end
