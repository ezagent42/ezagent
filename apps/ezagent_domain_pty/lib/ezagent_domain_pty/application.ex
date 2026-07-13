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

  No other state. PR-B (2026-05-21) moved `Ezagent.ActionSet.Pty` into
  this app — the Behavior module lives here, but its Agent-Kind
  registration runs from `EzagentDomainInstanceMessage.Application.start/2`
  (where `Ezagent.Entity.Agent` is defined). View registration moves
  to `ezagent_domain_ui` in PR-C.
  """

  use Application

  # cc-PTY hardening 2026-07-10 (audit #3): the PtyServer DynamicSupervisor
  # previously ran with NO intensity override → OTP's default 3-restarts-in-5s.
  # Exceeding intensity terminates ALL children + the supervisor, so one
  # crash-looping `claude` wiped every PtyServer on the node. We now set an
  # explicit, GENEROUS intensity (20 restarts in 60 s) and pair it with a
  # per-child sliding-window respawn backoff (`Ezagent.Domain.Pty.RespawnBackoff`,
  # applied in the Server) that rate-limits a single looping child well below
  # this ceiling. Result: one bad agent can never trip the supervisor (isolated),
  # while a genuinely systemic mass-crash (many children restarting at once) still
  # escalates — which is what intensity is FOR. Both knobs are app-env-injectable
  # so tests can scale them.
  @default_max_restarts 20
  @default_max_seconds 60

  @impl true
  def start(_type, _args) do
    # Owned here so the tables exist before the first PtyServer spawns; both
    # modules also lazy-init defensively.
    :ok = Ezagent.Domain.Pty.RespawnBackoff.init()
    :ok = Ezagent.Domain.Pty.RespawnPolicy.init()

    children = [
      {Registry, keys: :unique, name: EzagentDomainPty.Registry},
      {DynamicSupervisor,
       name: EzagentDomainPty.Supervisor,
       strategy: :one_for_one,
       max_restarts: max_restarts(),
       max_seconds: max_seconds()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  @doc """
  PtyServer `DynamicSupervisor` restart intensity — max child restarts allowed
  within `max_seconds/0` before OTP terminates the subtree. Default
  #{@default_max_restarts}; override with
  `config :ezagent_domain_pty, :supervisor_max_restarts`.
  """
  @spec max_restarts() :: pos_integer()
  def max_restarts, do: cfg(:supervisor_max_restarts, @default_max_restarts)

  @doc """
  PtyServer `DynamicSupervisor` restart-intensity window in seconds. Default
  #{@default_max_seconds}; override with
  `config :ezagent_domain_pty, :supervisor_max_seconds`.
  """
  @spec max_seconds() :: pos_integer()
  def max_seconds, do: cfg(:supervisor_max_seconds, @default_max_seconds)

  defp cfg(key, default) do
    case Application.get_env(:ezagent_domain_pty, key, default) do
      v when is_integer(v) and v > 0 -> v
      _ -> default
    end
  end
end
