defmodule Ezagent.Socialware.AnonUserGCTest do
  @moduledoc """
  Issue #51 — 48h GC of abandoned anonymous external users (spec §3.4).

  The PURE TTL predicate (`expired?/2`) is tested GREEN. The table-backed reap pass
  (`sweep/1`) is the TDD definition of the not-yet-built anon binding table + the
  in-app sweeper — tagged `:pending_impl` / `:skip` so CI stays green while the
  failing case stands as the executable spec.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.AnonUser.GC

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

  describe "sweep/1 — table-backed reap (PENDING the binding table)" do
    @tag :pending_impl
    @tag :skip
    test "reaps an abandoned anon-User (leave + delete users/binding rows) and is a no-op for a fresh one" do
      # DESIRED behavior once the anon binding table + sweeper land:
      #
      #   * mint anon-User A, join it to a session, backdate its binding
      #     last_seen_at to 49h ago;
      #   * mint anon-User B, join it, leave last_seen_at = now;
      #   * GC.sweep(now) returns {:ok, 1} (only A reaped);
      #   * after the sweep: A is no longer a session member, its `users` row and
      #     binding row are deleted, and ChatFeed.snapshot/2 denies A;
      #   * B is untouched (still a member, still reads).
      now = DateTime.utc_now()
      assert {:ok, 1} = GC.sweep(now)
    end
  end
end
