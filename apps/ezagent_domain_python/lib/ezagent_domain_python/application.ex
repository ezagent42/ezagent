defmodule EzagentDomainPython.Application do
  @moduledoc """
  Domain.Python Application — owns the runtime supervision tree for
  uv-launched Python subprocesses (one `Ezagent.Domain.Python.Server`
  per managed handle).

  Per SPEC `docs/superpowers/specs/2026-05-23-domain-python.md` §1.1
  this is the Tier-2 Domain app that hosts the stdio-protocol Python
  subprocess primitive. Sibling of `EzagentDomainPty.Application`.

  ## Children

  1. `EzagentDomainPython.Supervisor` — `DynamicSupervisor` parenting
     the Server GenServers.

  V5 pid-closure A1b: the private `EzagentDomainPython.Registry` is
  RETIRED — Servers self-register in the unified
  `Ezagent.Runtime.SidecarRegistry` (started by
  `EzagentActor.Application`) under `{handle_key,
  :ezagent_domain_python, :python}` and are reached only through the
  `Ezagent.Runtime.Resolver` seam. Concurrent spawn attempts for the
  same handle still collapse atomically at the `:via` registration
  (`{:error, {:already_started, pid}}`), and the facade's
  `start_subprocess/1` keeps its readiness-aware `:await_ready`
  adoption (SPEC §3.2 step 2 / D13).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: EzagentDomainPython.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
