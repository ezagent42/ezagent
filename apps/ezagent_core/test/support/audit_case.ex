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
  2026-05-26 against `Ezagent.Kind.SnapshotTest` seed-0 failures and
  ~22 `ezagent_plugin_liveview` "baseline flakes".)

  Tests that actually verify audit writes (e.g.
  `Ezagent.AuditTest`, `EzagentDomainChat.Integration.MentionGatedRoutingTest`,
  `EzagentPluginLiveview.ObservabilityLiveTest`) use this case to:

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
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

        unless tags[:async] do
          Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
        end

        for writer <- unquote(writers) do
          {:ok, pid} =
            case writer do
              :audit -> start_supervised(Ezagent.Audit.Writer)
              :snapshot -> start_supervised(Ezagent.Snapshot.Writer)
            end

          # Belt-and-suspenders: even with `{:shared, self()}` mode set
          # above, explicit allow makes the intent obvious and survives
          # tests that re-set mode to `:manual`.
          Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), pid)
        end

        :ok
      end
    end
  end
end
