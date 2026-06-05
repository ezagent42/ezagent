defmodule Ezagent.Invariants.KindSnapshotConcurrentUpsertTest do
  @moduledoc """
  2026-05-26 (Allen "请重试" directive) — pins the `Database busy`
  retry behaviour in `Ezagent.Ecto.KindSnapshot.upsert/5`.

  SQLite is single-writer at the file level. Before the bounded
  retry was added (PR #364 follow-up), concurrent `Kind.spawn` calls
  raced their initial-snapshot inserts and exactly one of them got
  back `%Exqlite.Error{message: "Database busy"}` from
  `Ecto.Adapters.SQL.raise_sql_call_error/1`, which propagated up
  through `Kind.Server.init/1`'s `{:stop, {:persistence_failed, _}}`
  return value and surfaced in the caller's `SpawnRegistry.spawn`
  return as `{:error, {:persistence_failed, %Exqlite.Error{...}}}`.

  3 production tests hit this race:

    - `Ezagent.Integration.CapsDenialE2ETest` Scenario 4
    - `EzagentCore.Invariants.CrossWorkspaceIsolationTest` (two scenarios)

  This invariant pins **N concurrent upserts to N distinct URIs all
  succeed**. SQLite's writer lock is file-scoped, so even distinct
  rows block each other under load — without retry, ~half raise
  `Database busy`.

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

  # Keep numbers modest — SQLite's single-writer ceiling is real even
  # WITH retry; the goal is to prove the retry works under realistic
  # concurrency (≥3 concurrent Kind spawns is the production hot
  # path), not to stress-test sqlite itself.
  @parallel_concurrency 10

  test "concurrent upserts to distinct URIs all succeed (retry covers Database busy)" do
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
           This indicates the `Database busy` retry in
           `KindSnapshot.do_upsert_with_retry/4` has regressed.

           Failed results: #{inspect(failures)}
           """
  end
end
