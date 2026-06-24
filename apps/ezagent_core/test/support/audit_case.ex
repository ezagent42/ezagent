defmodule Ezagent.Test.AuditCase do
  @moduledoc """
  Opt-in `ExUnit.Case` template for tests that need `Ezagent.Audit.Writer`
  (and/or `Ezagent.Snapshot.Writer`) running.

  Both writers are skipped from `EzagentCore.Application`'s supervision
  tree under `Mix.env() == :test` because their 100ms timer-driven
  `Repo.insert_all` / `Repo.insert!` flush interleaves with
  `Ecto.Adapters.SQL.Sandbox`'s per-test ownership lifecycle —
  flushing under a torn-down owner produces "Database busy" / "owner
  exited" errors that bleed into subsequent unrelated tests. (Diagnosed
  2026-05-26 against `Ezagent.Kind.SnapshotTest` seed-0 failures and operator
  UI baseline flakes.)

  Tests that actually verify audit writes (e.g.
  `Ezagent.AuditTest` and
  `EzagentDomainInstanceMessage.Integration.MentionGatedRoutingTest`) use this
  case to:

    1. `start_supervised!/1` the writer per-test (terminated on test exit
       so no cross-test residue).
    2. `Ecto.Adapters.SQL.Sandbox.allow/3` the writer onto the per-test
       connection so its inserts run under the same sandbox transaction.

  ## Usage

      defmodule MyAuditTest do
        use Ezagent.Test.AuditCase, writers: [:audit]   # or [:audit, :snapshot]

        test "audit writer logs invocation" do
          # Audit.Writer is alive AND scoped to my sandbox connection.
          ...
        end
      end

  Options:
    * `:writers` — list of writers to start. Allowed: `:audit` (default),
      `:snapshot`. Pass `[]` to use this case for sandbox setup only (no
      writers — equivalent to a vanilla `DataCase` minus the macros).

  Sets `async: false` because the writers are name-registered singletons
  that cannot coexist with a parallel test starting another instance.
  """

  use ExUnit.CaseTemplate

  using opts do
    writers = Keyword.get(opts, :writers, [:audit])

    quote do
      use ExUnit.Case, async: false

      setup tags do
        # #92: was a hand-rolled `Sandbox.checkout` + `{:shared, self()}` that
        # made the SHORT-LIVED TEST PROCESS the global shared owner — when this
        # test exited it reverted the pool to `:manual`, clobbering concurrent
        # suites' globally-supervised Kinds mid-write (`owner exited` /
        # `cannot find ownership process`, intermittent by seed). Route through
        # `EzagentCore.DataCase.setup_sandbox/1` instead: it establishes shared
        # mode via a STABLE, drainable Agent owner (not the dying test pid) and a
        # teardown that drains in-flight Kind DB work before reclaiming the
        # connection — the same safe owner every other shared-mode test now uses.
        EzagentCore.DataCase.setup_sandbox(tags)

        # Start the writers AFTER setup_sandbox so their `start_supervised`
        # teardown runs BEFORE `setup_sandbox`'s `stop_owner` (ExUnit on_exit is
        # LIFO) — no writer flush can outlive the owner connection. In shared
        # mode (`not async`) the stable owner's connection covers these
        # processes; the async path keeps an explicit `allow/3`.
        for writer <- unquote(writers) do
          {:ok, pid} =
            case writer do
              :audit -> start_supervised(Ezagent.Audit.Writer)
              :snapshot -> start_supervised(Ezagent.Snapshot.Writer)
            end

          if tags[:async] do
            Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), pid)
          end
        end

        :ok
      end
    end
  end
end
