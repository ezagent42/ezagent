defmodule Ezagent.Socialware.AnonUserGCTest do
  @moduledoc """
  Issue #51 — 48h GC of abandoned anonymous external users (spec §3.4).

  Covers the PURE TTL predicate (`expired?/2`) AND the table-backed reap pass
  (`sweep/1`): an abandoned anon-User is `chat.leave`d, its `users` row + binding
  row deleted, and `ChatFeed.snapshot/2` then denies it; a fresh anon-User is
  untouched.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.{AnonBinding, AnonUser, ChatFeed}
  alias Ezagent.Socialware.AnonUser.GC
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.KindRegistry

  describe "expired?/2 — the pure 48h TTL predicate (GREEN)" do
    test "an anon-User last seen 49h ago is expired" do
      now = ~U[2026-06-13 12:00:00Z]
      last_seen = DateTime.add(now, -49 * 60 * 60, :second)
      assert GC.expired?(last_seen, now)
    end

    test "an anon-User last seen 1h ago is NOT expired" do
      now = ~U[2026-06-13 12:00:00Z]
      last_seen = DateTime.add(now, -1 * 60 * 60, :second)
      refute GC.expired?(last_seen, now)
    end

    test "exactly at the 48h boundary is expired (>=)" do
      now = ~U[2026-06-13 12:00:00Z]
      last_seen = DateTime.add(now, -GC.ttl_ms(), :millisecond)
      assert GC.expired?(last_seen, now)
    end

    test "the TTL is 48h" do
      assert GC.ttl_ms() == 48 * 60 * 60 * 1000
    end
  end

  describe "sweep/1 — table-backed reap" do
    # NOTE: a spawned Session Kind runs in its own process — `use
    # EzagentCore.DataCase, async: false` already shares the sandbox via a
    # drainable Agent owner, so a redundant `Sandbox.mode({:shared, self()})`
    # only re-globalized the connection onto the dying test pid and clobbered
    # concurrent suites with "owner exited" errors (#92).

    # Flake root cause (#108): `GC.sweep/1` is a GLOBAL table scan
    # (`AnonBinding.list_expired/2` has NO test/session scoping — it is
    # correctly global in production, §3.4). Each test below asserts on the
    # GLOBAL reaped COUNT (`{:ok, 0}` / `{:ok, 1}`), which silently assumes
    # the `socialware_anon_bindings` table contains ONLY this test's rows.
    # Under the full concurrent umbrella another expired binding can be
    # visible in the shared sandbox connection — and if ITS session is still
    # live, the sweep reaps THAT row, returning a count one higher than the
    # test expects (deterministically reproduced: a foreign live-session
    # expired binding yields `{:ok, 1}` where the test asserts `{:ok, 0}`,
    # anon_user_gc_test.exs:179). The honest fix is test ISOLATION, not
    # weakening the production sweep: start each sweep test from an empty
    # binding table so `list_expired/2` sees only this test's fixtures. The
    # delete runs in THIS test's owned sandbox connection (the same view
    # `list_expired/2` reads), so it removes exactly the rows that would
    # otherwise contaminate the count.
    setup do
      EzagentCore.Repo.delete_all(Ezagent.Socialware.AnonBinding)
      :ok
    end

    test "reaps an abandoned anon-User (leave + delete users/binding) and is a no-op for a fresh one" do
      now = DateTime.utc_now()
      session_uri = spawn_session()
      {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

      # A — abandoned (binding backdated 49h); B — fresh (binding = now).
      {:ok, a} = AnonUser.mint(session_uri)
      {:ok, b} = AnonUser.mint(session_uri)
      spawn_anon_kind(a)
      spawn_anon_kind(b)
      join(session_uri, a)
      join(session_uri, b)

      {:ok, _} = AnonBinding.touch(a, session_uri, DateTime.add(now, -49 * 60 * 60, :second))
      {:ok, _} = AnonBinding.touch(b, session_uri, now)

      # both are members + readable before the sweep
      assert member?(session_pid, a)
      assert member?(session_pid, b)

      assert {:ok, 1} = GC.sweep(now)
      drain(session_pid)

      # A reaped: no longer a member, users + binding rows gone, ChatFeed denies it
      refute member?(session_pid, a)
      assert AnonBinding.get(a) == nil
      assert Ezagent.Users.get_by_uri(a) == nil
      assert {:error, _} = ChatFeed.snapshot(session_uri, a)

      # B untouched: still a member, rows intact, still reads
      assert member?(session_pid, b)
      assert AnonBinding.get(b) != nil
      assert Ezagent.Users.get_by_uri(b) != nil
      assert {:ok, _} = ChatFeed.snapshot(session_uri, b)
    end

    test "a refreshed candidate (touched since listing) is NOT reaped (claim is compare-and-update)" do
      now = DateTime.utc_now()
      session_uri = spawn_session()
      {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

      {:ok, a} = AnonUser.mint(session_uri)
      spawn_anon_kind(a)
      join(session_uri, a)

      # Backdate, then immediately refresh — the row is no longer expired at sweep.
      {:ok, _} = AnonBinding.touch(a, session_uri, DateTime.add(now, -49 * 60 * 60, :second))
      {:ok, _} = AnonBinding.touch(a, session_uri, now)

      assert {:ok, 0} = GC.sweep(now)
      drain(session_pid)

      assert member?(session_pid, a)
      assert AnonBinding.get(a) != nil
      assert Ezagent.Users.get_by_uri(a) != nil
    end

    test "no expired bindings → {:ok, 0}" do
      assert {:ok, 0} = GC.sweep(DateTime.utc_now())
    end

    test "crash recovery: a STUCK reap (claimed but never finished) is completed by a later sweep" do
      now = DateTime.utc_now()
      session_uri = spawn_session()
      {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

      {:ok, a} = AnonUser.mint(session_uri)
      spawn_anon_kind(a)
      join(session_uri, a)

      # Simulate a crashed prior reap: expired binding ALREADY claimed (stuck in
      # reaping_at), the leave/delete never completed — A is still a member, its rows
      # still exist. A delete-as-claim would have lost the row; the marker keeps it as
      # the retry record.
      ttl = GC.ttl_ms()
      {:ok, _} = AnonBinding.touch(a, session_uri, DateTime.add(now, -49 * 60 * 60, :second))
      {:ok, :claimed} = AnonBinding.claim_for_reaping(a, now, ttl)
      assert AnonBinding.get(a).reaping_at != nil
      assert member?(session_pid, a)

      # a LATER sweep (past the staleness threshold) re-surfaces + re-claims the stuck
      # row and finishes the reap.
      later = DateTime.add(now, 2 * 60 * 60, :second)
      assert {:ok, 1} = GC.sweep(later)
      drain(session_pid)

      refute member?(session_pid, a)
      assert AnonBinding.get(a) == nil
      assert Ezagent.Users.get_by_uri(a) == nil
    end

    test "an UNCONFIRMED leave (session unreadable) keeps the binding claimed + user intact (no orphan) AND is observable" do
      now = DateTime.utc_now()
      session_uri = spawn_session()
      {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

      {:ok, a} = AnonUser.mint(session_uri)
      spawn_anon_kind(a)
      join(session_uri, a)
      {:ok, _} = AnonBinding.touch(a, session_uri, DateTime.add(now, -49 * 60 * 60, :second))

      # A skipped/incomplete reap must NOT be a silent no-op (codex r4/r5) — attach to
      # the GC's telemetry so the keep-claimed path proves it emits. This reachable
      # `:leave_unconfirmed` path exercises the SAME `signal_stuck_reap/3` mechanism the
      # publicly-unreachable `:user_delete_not_confirmed` (DB-only: Users.delete reports
      # :ok though the row survives) and `:claim_failed` (DB-only: claim_for_reaping
      # rescues a Repo.update_all exception) reasons ride — no FK / mock lib makes those
      # two reachable without a test seam, so the mechanism is proven here once.
      test_pid = self()
      handler_id = {:gc_unconfirmed_test, make_ref()}

      :telemetry.attach(
        handler_id,
        GC.reap_unconfirmed_event(),
        fn event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Tear the session down so the leave cannot be confirmed (get_slice fails). The
      # reap must NOT delete the user / binding on an unconfirmable leave — it keeps
      # the row claimed for retry rather than leaking an undiscoverable orphan.
      :ok =
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          session_pid
        )

      assert {:ok, 0} = GC.sweep(now)

      # binding + user survive (claimed, retried later); not reaped.
      assert AnonBinding.get(a) != nil
      assert Ezagent.Users.get_by_uri(a) != nil

      # ...and the stuck reap surfaced telemetry (alertable, not a silent leak loop).
      assert_receive {:telemetry, [:ezagent, :socialware, :gc, :reap_unconfirmed], %{count: 1},
                      %{reason: :leave_unconfirmed, entity_uri: e}}

      assert e == URI.to_string(a)
    end

    # Regression for the #108 flake root cause. `GC.sweep/1` scans the WHOLE
    # binding table (correctly — it is a global maintenance pass). The
    # COUNT-based assertions above silently assume the table holds only this
    # test's rows; a coexisting expired binding whose session is still LIVE
    # gets reaped and bumps the count. This test deterministically pins that
    # contamination mechanism AND proves the per-describe `setup` table-clear
    # neutralizes it: with the table reset, an UNCONFIRMED-scenario row `a`
    # (torn-down session) plus a coexisting live-session expired row `f`
    # yields `{:ok, 1}` (f reaped, a not) — and clearing-then-seeding-only-`a`
    # yields the isolated `{:ok, 0}` the UNCONFIRMED test depends on.
    test "ISOLATION: a coexisting live-session expired binding is what inflates the count (root-cause lock)" do
      now = DateTime.utc_now()

      # `a`: the UNCONFIRMED scenario — expired, session torn down → not reapable.
      s_a = spawn_session()
      {:ok, a_pid} = Ezagent.KindRegistry.lookup(s_a)
      {:ok, a} = AnonUser.mint(s_a)
      spawn_anon_kind(a)
      join(s_a, a)
      {:ok, _} = AnonBinding.touch(a, s_a, DateTime.add(now, -49 * 60 * 60, :second))

      :ok =
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          a_pid
        )

      # `f`: a FOREIGN-shaped row — expired, but its session is still LIVE
      # (stands in for another suite's leaked/concurrent binding).
      s_f = spawn_session()
      {:ok, f} = AnonUser.mint(s_f)
      spawn_anon_kind(f)
      join(s_f, f)
      {:ok, _} = AnonBinding.touch(f, s_f, DateTime.add(now, -49 * 60 * 60, :second))

      # With BOTH rows present, the global sweep reaps the live-session row `f`
      # (count 1) and skips the unreadable `a` — i.e. a count assertion that
      # assumed `a` was the only expired row would see `{:ok, 1}` (the flake).
      assert {:ok, 1} = GC.sweep(now)
      # `f` was reaped (binding + user gone) — it is the source of the count.
      assert AnonBinding.get(f) == nil
      assert Ezagent.Users.get_by_uri(f) == nil
      # `a` is untouched (unreapable), proving the count came from `f`, not `a`.
      assert AnonBinding.get(a) != nil
      assert Ezagent.Users.get_by_uri(a) != nil

      # The fix: starting from an empty table (what the describe `setup` does
      # before every test) and seeding ONLY `a` yields the isolated result the
      # UNCONFIRMED test asserts — no foreign live-session row to inflate it.
      EzagentCore.Repo.delete_all(Ezagent.Socialware.AnonBinding)
      {:ok, _} = AnonBinding.touch(a, s_a, DateTime.add(now, -49 * 60 * 60, :second))
      assert {:ok, 0} = GC.sweep(now)
    end
  end

  # ----- helpers -------------------------------------------------------------

  @owner Ezagent.URI.user(:system, :admin)

  defp spawn_session do
    uri =
      Ezagent.URI.new!("session://team-alpha/default/gc-#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: uri,
        owner_uri: @owner,
        behaviors: Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))

    on_exit(fn ->
      case KindRegistry.lookup(uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

        :error ->
          :ok
      end
    end)

    uri
  end

  # Spawn the anon-User Kind so it is a registered member-target for the join
  # (the production controller spawns it; the join rejects an unregistered member).
  defp spawn_anon_kind(anon_uri) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{
        uri: anon_uri,
        initial_caps: User.initial_caps_for_spawn(anon_uri)
      })

    :ok
  end

  # Join via the PRODUCTION dispatch path, :call so it is synchronous.
  defp join(session_uri, member_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    caller = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, caller)

    {:ok, _} =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{member: member_uri},
        ctx: %{caller: caller, caps: MapSet.new([cap]), reply: :ignore}
      })
  end

  # A synchronous round-trip drains the Session Kind's mailbox so a prior :cast
  # (join / leave) has been applied before we assert (no Process.sleep).
  defp drain(session_pid), do: :sys.get_state(session_pid)

  defp member?(session_pid, member_uri) do
    %{state: %{session: %{state: slice}}} = :sys.get_state(session_pid)
    Map.has_key?(slice.members || %{}, member_uri)
  end
end
