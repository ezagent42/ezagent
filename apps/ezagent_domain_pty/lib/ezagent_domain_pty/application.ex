defmodule EzagentDomainPty.Application do
  @moduledoc """
  Domain.Pty Application — owns the runtime supervision tree for
  PTY-managed sidecar processes (one PtyServer per agent_uri).

  Per SPEC v1 (`docs/superpowers/specs/2026-05-21-domain-pty-architecture.md`)
  §3.1, this is the Tier-2 Domain app that hosts the PTY primitive
  previously embedded inside `ezagent_plugin_cc`. The cc plugin (and
  any future PTY-capable plugin) now consumes this via the
  `Ezagent.Domain.Pty` facade.

  ## Children

  1. `EzagentDomainPty.Registry` — `:via` Registry keyed by
     `URI.to_string(agent_uri)`. PtyServers register here on
     `start_link`, so concurrent spawn attempts for the same agent
     collapse atomically to `{:error, {:already_started, pid}}`
     (PR-D2 atomic dedup invariant).
  2. `EzagentDomainPty.Supervisor` — `DynamicSupervisor` parenting the
     PtyServer GenServers.

  No other state. Behavior/View registration stays in the cc plugin in
  PR-A; PR-B moves `Ezagent.Behavior.Pty` here.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: EzagentDomainPty.Registry},
      {DynamicSupervisor, name: EzagentDomainPty.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
