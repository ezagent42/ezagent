defmodule Ezagent.Orchestrator.LiveJoinRegistry do
  @moduledoc """
  `orchestrator_uri → live-bridge-joined?` durable-state table — the
  robust readiness signal the §5 startup gate polls
  (`Ezagent.Entity.Session.await_orchestrator_ready/3`).

  ## Why this exists (and why it is NOT `McpRegistry`)

  The orchestrator startup gate must know ONE thing: has the
  orchestrator's LIVE claude stdio bridge actually JOINed the MCP
  Channel end-to-end (PTY up → claude up → MCP bridge up → registered)?

  `Ezagent.Orchestrator.McpChannel.join/3` broadcasts an
  `{:orchestrator_ready, uri}` PubSub message on a successful join. But
  that broadcast is FIRE-ONCE: if the gate's `receive` is not already
  parked on the topic at the instant the bridge joins (a timing / process
  race), the signal is lost and the gate times out — KILLING a perfectly
  functional orchestrator and rolling back the whole create with EMPTY
  members. The PubSub plumbing itself works; relying on a transient
  event instead of a durable state is the bug.

  This registry records the live-join as DURABLE STATE. The gate POLLS
  `joined?/1` on a bounded loop, so it cannot miss a join that already
  happened — and still keeps the broadcast as an instant-wake
  optimization.

  ## Why a SEPARATE table from `McpRegistry`

  `McpRegistry` is a read-through CACHE whose miss path
  (`McpServer.from_orchestrator_uri/1` → `rebuild_from_durable/1`)
  REPOPULATES the row from the Session's durable snapshot. So a row in
  `McpRegistry` does NOT distinguish "a live bridge joined" from "a
  durable rebuild filled the cache on a cold read". The gate needs
  EXACTLY that distinction — only a live bridge join is a valid
  readiness signal. Hence a dedicated table that is written ONLY by
  `McpChannel.join/3` (mark) and `McpChannel.terminate/2` (clear), never
  by any rebuild path.

  ## Storage

  ETS-backed, `:set`, `:public`, `:named_table`. Declared by `init/0`
  from `EzagentDomainInstanceMessage.Application.start/2` — the same lazy `init/0`
  pattern as `Ezagent.Orchestrator.McpRegistry` (this registry lives in
  a domain app, so it cannot ride the core `EzagentCore.EtsOwner` table
  list).

  Each row: `{orchestrator_uri_string, true}` — presence is the signal.

  ## Lifecycle

  - `mark_joined/1` — called on a SUCCESSFUL `McpChannel.join/3`.
  - `clear/1` — called on `McpChannel.terminate/2` (bridge disconnect)
    and by the gate's PTY-kill teardown, so a stale live-join row from a
    prior incarnation never satisfies a future gate.
  - `joined?/1` — the gate poll.

  Reset on a phx restart is acceptable: a live bridge that survives a
  BEAM restart will re-join and re-`mark_joined`; the gate only ever runs
  during a fresh create, where the relevant bridge join is concurrent.
  """

  @table :ezagent_orchestrator_live_join_registry

  @doc """
  Create the ETS table. Idempotent — safe to call on every boot.
  Called from `EzagentDomainInstanceMessage.Application.start/2`.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc "The ETS table name (exposed for diagnostics / tests)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Mark `orchestrator_uri`'s live bridge as JOINed. Called from
  `Ezagent.Orchestrator.McpChannel.join/3` on a successful join.
  Idempotent.
  """
  @spec mark_joined(URI.t()) :: :ok
  def mark_joined(%URI{} = orchestrator_uri) do
    init()
    true = :ets.insert(@table, {URI.to_string(orchestrator_uri), true})
    :ok
  end

  @doc """
  Has `orchestrator_uri`'s live bridge JOINed? The durable readiness
  signal the §5 startup gate polls.
  """
  @spec joined?(URI.t()) :: boolean()
  def joined?(%URI{} = orchestrator_uri) do
    init()

    case :ets.lookup(@table, URI.to_string(orchestrator_uri)) do
      [{_, true}] -> true
      [] -> false
    end
  end

  @doc """
  Clear `orchestrator_uri`'s live-join row. Called from
  `Ezagent.Orchestrator.McpChannel.terminate/2` (bridge disconnect) and
  by the gate's PTY-kill teardown. Idempotent.
  """
  @spec clear(URI.t()) :: :ok
  def clear(%URI{} = orchestrator_uri) do
    init()
    :ets.delete(@table, URI.to_string(orchestrator_uri))
    :ok
  end
end
