defmodule Ezagent.Invariants.KindSnapshotConcurrentUpsertTest do
  @moduledoc """
  Pins that `Ezagent.Ecto.KindSnapshot.upsert/5` remains safe under
  concurrent writes to distinct URIs. PostgreSQL should handle this path
  without row-level contention; transient retry is still isolated in
  `Ezagent.Persistence.TransientRetry` for deadlocks, serialization failures,
  and connection interruptions.

  We deliberately do NOT test concurrent upsert to the SAME URI here.
  In production, `KindRegistry.put_new/1` (Kind.Server.init/1 step 1)
  serialises Kind spawn by URI before `save_now` reaches the upsert,
  so the same-URI race is structurally impossible. Testing it
  separately would require declaring a unique constraint in the
  changeset to convert the PK-race into a changeset error rather
  than a raise — orthogonal to the `Database busy` retry concern.

  Per `feedback_completion_requires_invariant_test`: if someone
  removes the retry loop, this assertion goes red.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot

  # Keep numbers modest; the goal is to prove the production hot path for
  # concurrent Kind spawns, not to run a database load test.
  @parallel_concurrency 10

  test "concurrent upserts to distinct URIs all succeed" do
    workspace_uri = "workspace://system"

    tasks =
      for n <- 1..@parallel_concurrency do
        Task.async(fn ->
          uri =
            "entity://system/user/concurrent-distinct-#{n}-#{System.unique_integer([:positive])}"

          KindSnapshot.upsert(
            uri,
            "user",
            :erlang.term_to_binary(%{identity: %{caps: MapSet.new()}}),
            0,
            workspace_uri
          )
        end)
      end

    results = Task.await_many(tasks, 5_000)

    failures = Enum.reject(results, fn r -> match?({:ok, _}, r) end)

    assert failures == [],
           """
           Concurrent upserts to distinct URIs failed.
           This indicates the snapshot persistence path is not safe under
           ordinary concurrent Kind spawns.

           Failed results: #{inspect(failures)}
           """
  end
end
