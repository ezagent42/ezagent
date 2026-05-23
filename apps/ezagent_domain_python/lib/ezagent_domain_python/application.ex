defmodule EzagentDomainPython.Application do
  @moduledoc """
  Domain.Python Application — owns the runtime supervision tree for
  uv-launched Python subprocesses (one `Ezagent.Domain.Python.Server`
  per managed handle).

  Per SPEC `docs/superpowers/specs/2026-05-23-domain-python.md` §1.1
  this is the Tier-2 Domain app that hosts the stdio-protocol Python
  subprocess primitive. Sibling of `EzagentDomainPty.Application`.

  ## Children

  1. `EzagentDomainPython.Registry` — `:via` Registry keyed by
     `Ezagent.Domain.Python.handle_key/1` (canonical handle). Servers
     register here on `start_link`, so concurrent spawn attempts for
     the same handle collapse atomically to
     `{:error, {:already_started, pid}}`. The facade's
     `start_subprocess/1` then performs readiness-aware adoption via
     `:await_ready` (SPEC §3.2 step 2 / D13).
  2. `EzagentDomainPython.Supervisor` — `DynamicSupervisor` parenting
     the Server GenServers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: EzagentDomainPython.Registry},
      {DynamicSupervisor, name: EzagentDomainPython.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
