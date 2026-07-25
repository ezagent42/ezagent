defmodule Ezagent.Kind.Adapters do
  @moduledoc """
  §3.4 actor-framework port wiring (C5).

  The actor framework (files still in core until the physical move chunk)
  reaches the staying-core spine ONLY through these config-resolved
  adapters/injections — the same inversion as the `authority_loader`
  config, `ReadyGate.register_external_gate`, and
  `SpawnRegistry.register/2`.

  The wiring is applied HERE, at core boot, via `Application.put_env/3` —
  NOT in `config/config.exs` as `config :ezagent_actor, …`: the
  `:ezagent_actor` OTP app does not exist yet, and Elixir 1.19's
  `app.config` validation HARD-FAILS a child-app boot on config keys for
  unavailable apps, which silently aborts umbrella-root `mix test`
  recursion (exit 0, zero tests run) before it ever reaches the requested
  suite. Runtime `put_env` carries no such validation and resolves
  identically at the call sites (`Application.fetch_env!/2`). The
  physical-move chunk can migrate this to the spec's `config
  :ezagent_actor` wiring block once the app exists.

  A key that is already set (real config, or a test that pre-wires a fake)
  is never clobbered.
  """

  @wiring [
    repo: EzagentCore.Repo,
    pubsub: EzagentCore.PubSub,
    persistence: Ezagent.Kind.Adapters.PersistenceAdapter,
    dead_letter: Ezagent.Kind.Adapters.DeadLetterAdapter,
    saga: Ezagent.Kind.Adapters.SagaAdapter,
    event_log: Ezagent.Kind.Adapters.EventLogAdapter,
    capability: Ezagent.Kind.Adapters.CapabilityAdapter,
    outbox: Ezagent.Kind.Adapters.OutboxAdapter,
    dispatch_policy: Ezagent.Kind.Adapters.DispatchPolicyAdapter,
    authz: Ezagent.Kind.Adapters.AuthzAdapter,
    authority: Ezagent.Kind.Adapters.AuthorityAdapter,
    # §3.4 non-port findings — the `BehaviorSet` slice-owner / required-read
    # tables and the `KindBaseBackfill` as-built sets INVERTED to
    # registration data (they hard-coded concrete domain/plugin ActionSet
    # modules inside the framework). The VALUES move here, core-side, and
    # the framework reads them from app env at runtime. Module ATOMS only —
    # no function is called on them at this site, so no compile dependency
    # on the domain/plugin apps (same atom-reference pattern the tables
    # themselves already relied on).
    slice_owners: %{
      chat: Ezagent.ActionSet.Session,
      turns: Ezagent.ActionSet.Turn,
      surface: Ezagent.ActionSet.Surface,
      config_evolve: Ezagent.ActionSet.ConfigEvolve,
      identity: Ezagent.ActionSet.Identity,
      publisher: Ezagent.ActionSet.Publisher.SessionImpl,
      sandbox: Ezagent.ActionSet.Sandbox,
      api_keys: Ezagent.ActionSet.ApiKeys,
      cc_headless_agent: Ezagent.ActionSet.CcHeadlessAgent,
      external_mirror: Ezagent.ActionSet.ExternalMirror,
      kind_base: Ezagent.ActionSet.KindBase
    },
    required_reads: %{
      Ezagent.ActionSet.Turn => %{surface: :required},
      Ezagent.ActionSet.ConfigEvolve => %{sandbox: :required, identity: :required},
      Ezagent.ActionSet.ExternalMirror => %{publisher: :required},
      Ezagent.ActionSet.Session => %{sandbox: :optional},
      Ezagent.ActionSet.CurlAgent => %{api_keys: :optional}
    },
    kind_base_backfill_sets: %{
      instance_message: [
        Ezagent.ActionSet.Session,
        Ezagent.ActionSet.Publisher.SessionImpl,
        Ezagent.ActionSet.ExternalMirror
      ],
      # Order matches the former socialware-session Kind's behavior set
      # exactly — see `KindBaseBackfill` for the byte-identical round-trip
      # invariant this ordering preserves.
      socialware: [
        Ezagent.ActionSet.Session,
        Ezagent.ActionSet.Turn,
        Ezagent.ActionSet.Surface,
        Ezagent.ActionSet.SupervisorApproval,
        Ezagent.ActionSet.Publisher.SessionImpl
      ]
    },
    # §3.4 / #533 §3.4 — the universal-behavior SET is core policy
    # (`Ezagent.ActionSet.Manage` stays in core); the moved
    # `Ezagent.UniversalBehaviors` reads it from app env instead of
    # hard-coding the module (same registration-data inversion as the
    # tables above; retires the last reverse-ratchet entry).
    universal_behaviors: [Ezagent.ActionSet.Manage]
  ]

  @doc false
  def wire! do
    Enum.each(@wiring, fn {key, value} ->
      case Application.get_env(:ezagent_actor, key) do
        nil -> Application.put_env(:ezagent_actor, key, value)
        _already_set -> :ok
      end
    end)

    :ok
  end
end
