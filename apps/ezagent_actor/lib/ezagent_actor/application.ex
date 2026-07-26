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

        # ②b Unified sidecar registry (V5 pid-closure, A1b) — runtime infra,
        # NOT plugin-specific, so it lives here next to KindRegistry.
        # Sidecar children `:via`-self-register under
        # `{parent_uri, plugin, role}` keys; `Ezagent.Runtime.Resolver`
        # reads it. Behavior-additive: the registry runs, but nothing
        # resolves through it until a sidecar migrates onto the seam.
        Ezagent.Runtime.SidecarRegistry,

        # ②c Signal monitor relay (V5 use-side B1) — owns the raw
        # `Process.monitor/1`s behind `EzagentActor.Signal.monitor/1` and
        # re-delivers deaths as `%EzagentActor.Signal{kind: :down}`
        # envelopes. Additive: nothing monitors through it yet.
        EzagentActor.Signal.Monitor,

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

    result =
      Supervisor.start_link(children, strategy: :one_for_one, name: EzagentActor.Supervisor)

    # PR #145 (SPEC v2 §5.6 §5.11) — seed the runtime URI scheme allowlist
    # BEFORE any code path that calls `Ezagent.URI.new!/1` or
    # `Ezagent.SpawnRegistry.register/2` (which co-registers schemes).
    # C5 §3.2 ATOMIC move: registry module + ETS table + this seed travel
    # together. Ordering is STRUCTURAL — `ezagent_core` depends on
    # `ezagent_actor`, so OTP starts this app (and this seed) before any
    # core boot code can call `URI.new!/1` (e.g. the
    # `system://routing/default` sentinel spawn).
    :ok = seed_uri_schemes()

    result
  end

  # PR #145 — seed the 6 SPEC §5.6 schemes into SchemeRegistry. Idempotent
  # (`:ets.insert/2` overwrites the same key), safe on supervisor restart.
  # Idempotent `SchemeRegistry.init/0` covers the rare case where EtsOwner
  # has not yet finished initializing on a hot path — in normal boot,
  # EtsOwner is child ① in the supervision tree so the table is ready.
  defp seed_uri_schemes do
    :ok = Ezagent.URI.SchemeRegistry.init()

    Enum.each(~w(entity workspace session template resource system), fn s ->
      :ok = Ezagent.URI.SchemeRegistry.register(s)
    end)

    :ok
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
