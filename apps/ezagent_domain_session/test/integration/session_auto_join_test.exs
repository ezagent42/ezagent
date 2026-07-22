defmodule EzagentDomainInstanceMessage.Integration.SessionAutoJoinTest do
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
    %{state: %{session: chat}} = :sys.get_state(pid)
    persistent = Map.get(chat, :state, chat)
    transients = Map.get(chat, :transients, %{})
    monitors = Map.get(transients, :monitors, Map.get(persistent, :monitors, %{}))
    {Map.keys(persistent.members), monitors, persistent}
  end

  # team-routing-unification §3.1 (PR-5a) — the FULL member-meta map
  # (`%{URI.t() => meta}`), so a test can assert the facets threaded onto a
  # member by `chat.join` (provenance / role_name / in_session_template), not
  # just membership presence.
  defp session_members_meta(%URI{} = session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: chat}} = :sys.get_state(pid)
    persistent = Map.get(chat, :state, chat)
    persistent.members
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
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, admin,
          template_name: "default"
        )

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

  describe ":join idempotency (Behavior.Session)" do
    # Codex r1 HIGH-1 (2026-05-26) — strict pid-match short-circuit
    # regression test. The short-circuit MUST verify the held monitor
    # ref is for the SAME pid KindRegistry currently resolves the URI
    # to; otherwise the dead-old-pid + fresh-new-pid + stale-:DOWN
    # window causes the live member to be marked offline.
    test "short-circuit fires only when the held monitor ref is for the CURRENT pid" do
      short = "ajs-pid-#{uniq()}"
      admin = User.admin_uri()

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, admin,
          template_name: "default"
        )

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
      target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
      cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

      :ok =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :cast,
          args: %{member: admin},
          ctx: %{
            caller: Ezagent.Entity.User.admin_uri(),
            authenticated_principal: Ezagent.Entity.User.admin_uri(),
            caps: MapSet.new([cap]),
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
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, admin,
          template_name: "default"
        )

      # Wait for the creator-auto-join cast to land.
      assert wait_until(fn ->
               {members, _monitors, _slice} = session_members(session_uri)
               Enum.any?(members, &(URI.to_string(&1) == URI.to_string(admin)))
             end)

      {_members_before, monitors_before, _slice} = session_members(session_uri)
      ref_count_before = map_size(monitors_before)

      # Dispatch chat.join 5 more times — every one should be a no-op
      # at the slice level (online + monitor alive → short-circuit).
      target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
      cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

      for _ <- 1..5 do
        :ok =
          Ezagent.Invocation.dispatch(%Ezagent.Invocation{
            origin: :trusted_internal,
            target: target,
            mode: :cast,
            args: %{member: admin},
            ctx: %{
              caller: Ezagent.Entity.User.admin_uri(),
              authenticated_principal: Ezagent.Entity.User.admin_uri(),
              caps: MapSet.new([cap]),
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
               "Behavior.Session.invoke(:join) idempotency regression"
    end
  end

  # ----------------------------------------------------------------------
  # Layer 3 — member facets thread through chat.join (§3.1, PR-5a)
  # ----------------------------------------------------------------------

  describe "member facets (team-routing-unification §3.1, PR-5a)" do
    test "join carrying role_name + in_session_template lands them on member meta" do
      {session_uri, _admin} = new_session("ajs-facets")
      member_uri = register_member()

      :ok = join_cast(session_uri, member_uri, %{role_name: "relay", in_session_template: true})

      meta = await_meta(session_uri, member_uri, &Map.has_key?(&1, :role_name))

      assert meta.online == true
      assert meta.role_name == "relay"
      assert meta.in_session_template == true
      # provenance is a PR-5b facet — NEVER set from a join's args.
      refute Map.has_key?(meta, :provenance)
    end

    test "a plain join (no facets) keeps the minimal %{online: true} meta" do
      {session_uri, admin} = new_session("ajs-plain")

      meta = await_meta(session_uri, admin, fn _ -> true end)

      assert meta.online == true
      refute Map.has_key?(meta, :role_name)
      refute Map.has_key?(meta, :provenance)
      refute Map.has_key?(meta, :in_session_template)
    end

    test "facets SURVIVE a reconnect through the offline/stale-monitor path (codex #2)" do
      {session_uri, _admin} = new_session("ajs-rejoin")
      member_uri = register_member()

      # First join carries the facets.
      :ok = join_cast(session_uri, member_uri, %{role_name: "keep", in_session_template: true})
      _ = await_meta(session_uri, member_uri, &(&1[:role_name] == "keep"))

      # Member process dies → :DOWN flips online → false (facets preserved in meta).
      kill_member(member_uri)
      _ = await_meta(session_uri, member_uri, &(&1[:online] == false))

      # A NEW pid re-registers + rejoins WITHOUT supplying facets — the
      # offline path reaches do_join, which must PRESERVE the prior facets.
      member_uri2 = re_register_member(member_uri)
      assert URI.to_string(member_uri2) == URI.to_string(member_uri)
      :ok = join_cast(session_uri, member_uri, %{})

      meta = await_meta(session_uri, member_uri, &(&1[:online] == true))
      assert meta.role_name == "keep", "role_name must survive reconnect (was dropped pre-fix)"
      assert meta.in_session_template == true
    end

    test "a duplicate role_name from a DIFFERENT member is rejected (codex #4, spec §8.2)" do
      {session_uri, _admin} = new_session("ajs-dup")
      member1 = register_member()
      member2 = register_member()

      :ok = join_cast(session_uri, member1, %{role_name: "relay"})
      _ = await_meta(session_uri, member1, &(&1[:role_name] == "relay"))

      # member2 tries to take the same role_name via :call so we observe the error.
      assert {:error, {:role_name_taken, "relay"}} =
               join_call(session_uri, member2, %{role_name: "relay"})

      # member2 must NOT have been added, and "relay" still resolves to member1.
      assert is_nil(session_members_meta(session_uri)[member2])
    end
  end

  # --- Layer 3 helpers --------------------------------------------------

  defp new_session(prefix) do
    admin = User.admin_uri()

    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session("#{prefix}-#{uniq()}", admin,
        template_name: "default"
      )

    {session_uri, admin}
  end

  # M-5: use a real Agent Kind with an Identity slice. Grant-only join no longer
  # mounts a registry PID directly; the cap lands on the entity and its Identity
  # after-commit hook performs the holder-authenticated add_self.
  defp register_member do
    member_uri = URI.new!("entity://system/agent/relay-#{uniq()}")
    {member_uri, _pid} = spawn_registered(member_uri)
    member_uri
  end

  defp re_register_member(%URI{} = member_uri) do
    # Old pid is gone (kill_member waited for offline). Re-register a fresh pid.
    wait_until(fn -> KindRegistry.lookup(member_uri) == :error end)
    {uri, _pid} = spawn_registered(member_uri)
    uri
  end

  defp spawn_registered(%URI{} = member_uri) do
    assert {:ok, pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
               uri: member_uri,
               initial_caps: MapSet.new()
             })

    :ok = Ezagent.WorkspaceRegistry.bind(member_uri, Ezagent.Capability.workspace_of(member_uri))

    on_exit(fn ->
      Ezagent.WorkspaceRegistry.unbind(member_uri)

      case KindRegistry.lookup(member_uri) do
        {:ok, live_pid} ->
          DynamicSupervisor.terminate_child(
            EzagentDomainInstanceMessage.AgentSupervisor,
            live_pid
          )

        :error ->
          :ok
      end
    end)

    {member_uri, pid}
  end

  defp kill_member(%URI{} = member_uri) do
    {:ok, pid} = KindRegistry.lookup(member_uri)

    :ok =
      DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, pid)
  end

  defp join_cast(session_uri, member_uri, facets) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :cast,
      args: Map.put(facets, :member, member_uri),
      ctx: join_ctx(target, :ignore)
    })
  end

  defp join_call(session_uri, member_uri, facets) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: Map.put(facets, :member, member_uri),
      ctx: join_ctx(target, {:caller_inbox, self()})
    })
  end

  defp join_ctx(target, reply) do
    admin = Ezagent.Entity.User.admin_uri()

    %{
      caller: admin,
      authenticated_principal: admin,
      caps: MapSet.new([Ezagent.Test.CapHelper.signed_action_cap!(target, admin)]),
      reply: reply
    }
  end

  defp await_meta(session_uri, member_uri, pred) do
    meta =
      wait_until(fn ->
        m = session_members_meta(session_uri)[member_uri]
        if is_map(m) and pred.(m), do: m, else: false
      end)

    assert is_map(meta), "expected member #{URI.to_string(member_uri)} meta to satisfy predicate"
    meta
  end
end
