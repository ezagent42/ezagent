defmodule EzagentActor.Application do
  # The actor framework's OTP Application (C5 physical move — spec
  # `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md`
  # §3.2). Owns the framework's ETS tables, the stdlib Registry backing
  # `Ezagent.KindRegistry`, the idempotency sweeper, the snapshot async
  # writer, and the default Kind supervisor.
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # ① Framework ETS tables — must exist before the Registry, the
        # Sweeper, or any Kind instance touches them.
        EzagentActor.EtsOwner,

        # ② stdlib Registry for URI → pid (`Ezagent.KindRegistry` wraps this).
        {Registry, keys: :unique, name: Ezagent.KindRegistry},

        # ③ Idempotency LRU prune — its own GenServer so a crash doesn't
        # take the ETS owner with it.
        Ezagent.Idempotency.Sweeper,

        # ④ Snapshot async writer — handles `:periodic` strategy.
        # **Skipped in :test env** for the same Sandbox-ownership reason as
        # core's `Ezagent.Audit.Writer` (see `Ezagent.Test.AuditCase`).
        Ezagent.Snapshot.Writer,

        # ⑤ Default Kind supervisor — `Ezagent.Kind.spawn/2` routes here
        # when a Kind module doesn't declare its own `supervisor/0`.
        Ezagent.KindSupervisor
      ]
      |> Enum.reject(&skip_in_test_env?/1)

    Supervisor.start_link(children, strategy: :one_for_one, name: EzagentActor.Supervisor)
  end

  # See the `EzagentCore.Application` note on the writer skip — the 100ms
  # timer-driven Repo flush stamps over `Ecto.Adapters.SQL.Sandbox`
  # per-test ownership. The invariant test
  # `audit_writer_test_env_isolation_test.exs` pins both halves (prod
  # children include the writer, test children do not).
  @writers_skipped_in_test [Ezagent.Snapshot.Writer]

  defp skip_in_test_env?(child),
    do: is_test?() and child in @writers_skipped_in_test

  defp is_test? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end
end
