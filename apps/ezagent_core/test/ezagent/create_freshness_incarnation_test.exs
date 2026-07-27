defmodule Ezagent.CreateFreshnessIncarnationTest do
  @moduledoc """
  #201-cred (codex r2 MEDIUM-6) — the create-vs-activate verdict is bound to
  the EXACT started process incarnation (`{uri, pid}`), never to a mutable
  URI-keyed row.

  Pre-fix failure mode: creator P1 records `:created`, dies before the
  winning `spawn_receipt` caller reads the row, and its supervisor's restart
  P2 overwrites the same URI-keyed row with `:existed`. The winning call
  then reads `created?: false` for an agent IT logically created — skipping
  materialization AND wrongfully deleting the genuine creator's grant.

  With the pid-bound row, P2's record is a DIFFERENT row: the winning
  incarnation's verdict stays `:created` (and, combined with the deferred
  grant mint, there is no grant to wrongfully delete).
  """
  use Ezagent.LifecycleCase

  # Cross-tier suite (spawns real Kinds under the gate supervisor).
  @moduletag :umbrella_only

  alias Ezagent.TestSupport.LifecycleFixtureKind

  defp fixture_uri do
    URI.new!("system://lifecycle_fixture/fresh-inc-#{System.unique_integer([:positive])}")
  end

  defp stop_kind(uri) do
    _ = Ezagent.Kind.terminate(uri)
    wait_until(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)
  end

  test "a restarted incarnation cannot overwrite the winning incarnation's verdict" do
    uri = fixture_uri()

    # P1: the first-ever creator — a genuine logical create.
    assert {:ok, :started, p1, %{created?: true}} =
             Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

    # P1 dies BEFORE any later read of the verdict row (brutal kill: the
    # terminate cleanup never runs, the row stays — exactly the codex window).
    Process.exit(p1, :kill)

    # The permanent supervisor restarts the Kind: P2 sees the durable
    # `ever_created` marker and records `:existed` for ITS incarnation.
    wait_until(fn ->
      case Ezagent.KindRegistry.lookup(uri) do
        {:ok, p2} when p2 != p1 -> true
        _ -> false
      end
    end)

    {:ok, p2} = Ezagent.KindRegistry.lookup(uri)
    refute p2 == p1

    # The WINNING incarnation's verdict is still bound to ITS pid: P2's
    # record did NOT overwrite it. Pre-fix both reads returned P2's
    # `:existed` (the mutable URI-keyed row), flipping the winner's receipt
    # to `created?: false`.
    assert Ezagent.Kind.create_freshness(uri, p1) == :created
    assert Ezagent.Kind.create_freshness(uri, p2) == :existed

    stop_kind(uri)
  end

  test "a verdict read for a dead/never-recorded pid is fail-conservative :unknown" do
    uri = fixture_uri()

    assert {:ok, :started, pid, %{created?: true}} =
             Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    assert Ezagent.Kind.create_freshness(uri, dead) == :unknown
    assert Ezagent.Kind.create_freshness(uri, self()) == :unknown

    # The live incarnation's own verdict is unaffected by other pids' reads.
    assert Ezagent.Kind.create_freshness(uri, pid) == :created

    stop_kind(uri)
  end

  test "a graceful terminate frees the incarnation's verdict row" do
    uri = fixture_uri()

    assert {:ok, :started, pid, %{created?: true}} =
             Ezagent.Kind.spawn_receipt(LifecycleFixtureKind, %{uri: uri})

    stop_kind(uri)

    # After a graceful stop the row is gone — a later read (e.g. a leaked
    # reference to the old pid) is :unknown, never a stale :created.
    assert Ezagent.Kind.create_freshness(uri, pid) == :unknown
  end
end
