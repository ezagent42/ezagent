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
    setup do
      # Spawned Session Kind runs in its own process — share the sandbox.
      Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
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

      # A stuck/incomplete reap must NOT be a silent no-op (codex r4) — attach to the
      # GC's telemetry so the keep-claimed path proves it emits. This reachable
      # `:leave_unconfirmed` path exercises the SAME `signal_stuck_reap/3` mechanism
      # the (publicly-unreachable) `:user_delete_not_confirmed` branch rides.
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
      assert_receive {:telemetry, [:ezagent, :socialware, :gc, :reap_unconfirmed],
                      %{count: 1}, %{reason: :leave_unconfirmed, entity_uri: e}}

      assert e == URI.to_string(a)
    end
  end

  # ----- helpers -------------------------------------------------------------

  @owner Ezagent.URI.entity(:team_alpha, :user, "gc-owner")

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

  defp admin_caps do
    MapSet.new([
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: Ezagent.URI.new!("system://bootstrap/default"),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }
    ])
  end

  # Join via the PRODUCTION dispatch path, :call so it is synchronous.
  defp join(session_uri, member_uri) do
    {:ok, _} =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
        mode: :call,
        args: %{member: member_uri},
        ctx: %{caller: User.admin_uri(), caps: admin_caps(), reply: :ignore}
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
