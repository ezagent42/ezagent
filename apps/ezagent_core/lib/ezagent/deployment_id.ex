defmodule Ezagent.DeploymentId do
  @moduledoc """
  Deployment identity for cross-BEAM orphan-reaper safety
  (PTY-orphan-restart 2026-05-26 round-2, codex finding #2).

  ## Why this exists

  The cc/np orphan reapers identify orphan claude/python OS processes
  by their argv signature + `EZAGENT_AGENT_URI` env tag + absence from
  the live in-BEAM Pty / Python registry. That third gate proves
  "not owned by this BEAM" but does NOT prove "orphaned" — a parallel
  BEAM under the same OS user can have a legitimate live child whose
  URI is naturally absent from THIS BEAM's registry.

  Without a stronger gate, reaper A would SIGTERM reaper B's live
  claude — taking down B's working agent.

  ## The gate

  Each spawned subprocess gets tagged with a `EZAGENT_DEPLOYMENT_ID`
  env var = `deployment_id/0`. The reaper compares each candidate's
  env value against the CURRENT BEAM's `deployment_id/0`; only matches
  are eligible for reaping.

  ## Identity composition

  `<node_name>|<cwd_at_boot>`

  - `node_name`: handles "named distillery / mix releases" — two
    independent named BEAMs (`ezagent_dev@host`,
    `ezagent_staging@host`) get different deployment_ids even from
    the same source tree.
  - `cwd_at_boot`: handles "unnamed dev BEAMs in different worktrees".
    The user's typical workflow runs `iex -S mix phx.server` from
    different worktree directories; cwd captures that. The cwd is
    captured ONCE at module-load (via `@deployment_id` module
    attribute) so a later `File.cd` from a test doesn't drift the id.

  ## What this is NOT

  - NOT a per-BEAM-startup nonce. The phx-restart cycle MUST share
    deployment_id with its prior incarnation — otherwise the reaper
    would refuse to clean up its own orphans. So restart-to-restart
    consistency is the goal, not uniqueness.
  - NOT a security boundary. A malicious co-tenant who can read
    `/proc/<pid>/environ` and forge env vars can defeat this. The
    gate is for accidental friendly-fire on a shared dev box, not
    adversarial protection.
  """

  # Captured at MODULE LOAD — stays stable for the lifetime of this
  # BEAM regardless of later `File.cd` calls. The cwd at the moment
  # `mix phx.server` started is what defines "this deployment".
  @cwd_at_load (case File.cwd() do
                  {:ok, path} -> path
                  _ -> "unknown"
                end)

  @doc """
  The current BEAM's deployment ID.

  Stable for the life of this BEAM (cwd_at_load is captured at
  module-load via module attribute; node() is set at BEAM start and
  doesn't change post-start).
  """
  @spec deployment_id() :: String.t()
  def deployment_id do
    "#{Atom.to_string(node())}|#{@cwd_at_load}"
  end
end
