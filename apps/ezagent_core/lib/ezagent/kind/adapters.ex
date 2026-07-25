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
    outbox: Ezagent.Kind.Adapters.OutboxAdapter
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
