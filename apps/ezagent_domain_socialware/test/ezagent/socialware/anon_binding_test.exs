defmodule Ezagent.Socialware.AnonBindingTest do
  @moduledoc """
  Issue #51 (design §3.4 / OQ-4) — the anon external-user binding table: the GC
  index + the cookie→entity resolver.

  This pins the persistence contract the two staged consumers ride:

  - the public-route controller (§4.1) — `touch/3` on first-open / returning-visitor
    bump, `get/1` to resolve a returning visitor's cookie → entity;
  - `Ezagent.Socialware.AnonUser.GC.sweep/1` (§3.4) — `list_expired/2` to find
    abandoned anon-Users (then leave + delete users/binding rows) and `delete/1` to
    reap, mirrored by the login-replacement path (§4.4).

  `now` is an explicit `touch/3` argument so a test can backdate a binding — the
  GC-boundary cases below pin `list_expired/2` to the SAME `>=` TTL boundary as
  `GC.expired?/2`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.AnonBinding
  alias Ezagent.Socialware.AnonUser.GC

  @session Ezagent.URI.session(:team_alpha, :socialware, "pub-1")
  @entity_a Ezagent.URI.entity(:team_alpha, :user, "anon-aaaa")
  @entity_b Ezagent.URI.entity(:team_alpha, :user, "anon-bbbb")
  @now ~U[2026-06-15 12:00:00.000000Z]

  describe "touch/3 — insert on first-open, bump on returning visit" do
    test "inserts a fresh binding with the workspace DERIVED from the session (invariant #14)" do
      assert {:ok, row} = AnonBinding.touch(@entity_a, @session, @now)

      assert row.entity_uri == URI.to_string(@entity_a)
      assert row.session_uri == URI.to_string(@session)
      assert row.last_seen_at == @now
      # workspace_uri is NOT a caller-supplied arg — it is derived from the session,
      # so an anon binding can never carry a workspace foreign to its session.
      assert row.workspace_uri == URI.to_string(Ezagent.URI.workspace_of(@session))
    end

    test "a second touch of the SAME entity bumps last_seen_at without duplicating the row" do
      {:ok, _} = AnonBinding.touch(@entity_a, @session, @now)
      later = DateTime.add(@now, 3600, :second)

      assert {:ok, bumped} = AnonBinding.touch(@entity_a, @session, later)
      assert bumped.last_seen_at == later

      # still exactly one row for this entity
      assert AnonBinding.get(@entity_a).last_seen_at == later
    end

    test "fail-closed on a non-session URI — no row stored" do
      not_a_session = Ezagent.URI.entity(:team_alpha, :user, "alice")
      assert {:error, _} = AnonBinding.touch(@entity_a, not_a_session, @now)
      assert AnonBinding.get(@entity_a) == nil
    end

    test "fail-closed: a real (non-anon) principal can NEVER acquire a binding" do
      # a real user URI would otherwise get its `users` row reaped by the GC that
      # walks this table — reject it at the write boundary, no row.
      real_user = Ezagent.URI.entity(:team_alpha, :user, "alice")
      assert {:error, {:not_anon_user, _}} = AnonBinding.touch(real_user, @session, @now)
      assert AnonBinding.get(real_user) == nil
    end

    test "fail-closed: an anon-User from a DIFFERENT workspace than the session — no row" do
      foreign = Ezagent.URI.entity(:team_beta, :user, "anon-xxxx")
      assert {:error, {:cross_workspace, _, _}} = AnonBinding.touch(foreign, @session, @now)
      assert AnonBinding.get(foreign) == nil
    end

    test "fail-closed: a returning touch pointed at a DIFFERENT session is refused; binding intact" do
      # This drives the DB conflict path directly — a row already bound to @session,
      # then a touch for a different same-workspace session. It is exactly the LOSING
      # branch of a first-touch race (SQLite serializes the two inserts; the loser
      # hits this conflict), so the conditional `on_conflict` no-op + post-write
      # re-read fail-closes deterministically without flaky true concurrency.
      {:ok, _} = AnonBinding.touch(@entity_a, @session, @now)
      other_session = Ezagent.URI.session(:team_alpha, :socialware, "pub-2")

      assert {:error, {:session_mismatch, _}} = AnonBinding.touch(@entity_a, other_session, @now)
      # the original binding is untouched (still bound to @session, last_seen intact)
      kept = AnonBinding.get(@entity_a)
      assert kept.session_uri == URI.to_string(@session)
      assert kept.last_seen_at == @now
    end
  end

  describe "get/1 — cookie→entity resolution" do
    test "returns the binding for a known entity, nil for an unknown one" do
      {:ok, _} = AnonBinding.touch(@entity_a, @session, @now)

      assert %AnonBinding{entity_uri: e} = AnonBinding.get(@entity_a)
      assert e == URI.to_string(@entity_a)
      assert AnonBinding.get(@entity_b) == nil
    end
  end

  describe "list_expired/2 — the GC scan (same >= boundary as GC.expired?/2)" do
    test "returns only bindings last seen at or beyond the TTL ago" do
      ttl = GC.ttl_ms()
      fresh = DateTime.add(@now, -3600, :second)
      old = DateTime.add(@now, -49 * 3600, :second)
      boundary = DateTime.add(@now, -ttl, :millisecond)

      {:ok, _} = AnonBinding.touch(@entity_a, @session, old)
      {:ok, _} = AnonBinding.touch(@entity_b, @session, fresh)

      boundary_entity = Ezagent.URI.entity(:team_alpha, :user, "anon-cccc")
      {:ok, _} = AnonBinding.touch(boundary_entity, @session, boundary)

      expired = AnonBinding.list_expired(@now, ttl) |> Enum.map(& &1.entity_uri) |> MapSet.new()

      assert MapSet.member?(expired, URI.to_string(@entity_a))
      assert MapSet.member?(expired, URI.to_string(boundary_entity))
      refute MapSet.member?(expired, URI.to_string(@entity_b))
    end
  end

  describe "claim_for_reaping/3 — the GC-safe non-destructive compare-and-update claim" do
    test "claims a still-expired binding (stamps reaping_at, row SURVIVES as the retry record)" do
      ttl = GC.ttl_ms()
      old = DateTime.add(@now, -49 * 3600, :second)
      {:ok, _} = AnonBinding.touch(@entity_a, @session, old)

      assert {:ok, :claimed} = AnonBinding.claim_for_reaping(@entity_a, @now, ttl)
      # NOT deleted — the binding is the GC index + retry record until the reap
      # completes and hard-deletes it LAST.
      row = AnonBinding.get(@entity_a)
      assert row != nil
      assert row.reaping_at == @now
    end

    test "is a no-op (:not_claimed) when the candidate was refreshed since listing — the reap race" do
      ttl = GC.ttl_ms()
      old = DateTime.add(@now, -49 * 3600, :second)
      {:ok, _} = AnonBinding.touch(@entity_a, @session, old)

      # a concurrent public-route hit refreshes last_seen past the cutoff between the
      # GC's list_expired and its claim — the guarded claim must NOT reap it.
      {:ok, _} = AnonBinding.touch(@entity_a, @session, @now)

      assert {:ok, :not_claimed} = AnonBinding.claim_for_reaping(@entity_a, @now, ttl)
      row = AnonBinding.get(@entity_a)
      assert row.last_seen_at == @now
      assert row.reaping_at == nil
    end

    test "is a no-op (:not_claimed) when another sweeper holds a FRESH claim (no double-reap)" do
      ttl = GC.ttl_ms()
      old = DateTime.add(@now, -49 * 3600, :second)
      {:ok, _} = AnonBinding.touch(@entity_a, @session, old)

      assert {:ok, :claimed} = AnonBinding.claim_for_reaping(@entity_a, @now, ttl)
      # a second concurrent sweeper must not re-claim a fresh in-progress reap
      assert {:ok, :not_claimed} = AnonBinding.claim_for_reaping(@entity_a, @now, ttl)
    end

    test "RE-claims a STUCK reap (reaping_at past the staleness threshold) — crash recovery" do
      ttl = GC.ttl_ms()
      old = DateTime.add(@now, -49 * 3600, :second)
      {:ok, _} = AnonBinding.touch(@entity_a, @session, old)

      # claim now (reaping_at = @now), then the reap "crashes" — the row is stuck.
      assert {:ok, :claimed} = AnonBinding.claim_for_reaping(@entity_a, @now, ttl)
      assert {:ok, :not_claimed} = AnonBinding.claim_for_reaping(@entity_a, @now, ttl)

      # a LATER sweep (past the staleness threshold) re-surfaces + re-claims it.
      later = DateTime.add(@now, 2 * 3600, :second)

      assert MapSet.member?(
               AnonBinding.list_expired(later, ttl) |> Enum.map(& &1.entity_uri) |> MapSet.new(),
               URI.to_string(@entity_a)
             )

      assert {:ok, :claimed} = AnonBinding.claim_for_reaping(@entity_a, later, ttl)
    end

    test "is :not_claimed for an unknown entity" do
      assert {:ok, :not_claimed} = AnonBinding.claim_for_reaping(@entity_b, @now, GC.ttl_ms())
    end

    test "touch-after-claim does NOT refresh last_seen (signals :reaping) so the stuck reap retries" do
      ttl = GC.ttl_ms()
      old = DateTime.add(@now, -49 * 3600, :second)
      {:ok, _} = AnonBinding.touch(@entity_a, @session, old)

      assert {:ok, :claimed} = AnonBinding.claim_for_reaping(@entity_a, @now, ttl)

      # a returning visitor touches the row WHILE it is being reaped — it must NOT
      # be refreshed out from under the reap (codex r2 MEDIUM), and the caller is
      # told to mint fresh.
      assert {:error, {:reaping, _}} = AnonBinding.touch(@entity_a, @session, @now)

      # last_seen stayed OLD, so the stuck-reap retry still re-surfaces it later
      # (it did NOT get masked for a full TTL by the refresh).
      assert AnonBinding.get(@entity_a).last_seen_at == old

      later = DateTime.add(@now, 2 * 3600, :second)

      assert MapSet.member?(
               AnonBinding.list_expired(later, ttl) |> Enum.map(& &1.entity_uri) |> MapSet.new(),
               URI.to_string(@entity_a)
             )
    end
  end

  describe "delete/1 — unconditional login-replacement reap" do
    test "deletes a row regardless of freshness, idempotent the second time" do
      {:ok, _} = AnonBinding.touch(@entity_a, @session, @now)

      assert {:ok, :deleted} = AnonBinding.delete(@entity_a)
      assert AnonBinding.get(@entity_a) == nil
      assert {:ok, :not_found} = AnonBinding.delete(@entity_a)
    end
  end
end
