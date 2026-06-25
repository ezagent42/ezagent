defmodule Ezagent.AgentPassiveAttributes do
  @moduledoc """
  Stored `passive` (non-principal data-actor) attribute for an agent URI (RF-6).

  An `entity://agent/*` is, by default, a chat **principal** — `@`-mentionable,
  `:join`-able as a session member, and a `chat.receive` target. A **passive**
  data actor (e.g. the kanban-manager) acts only on dispatch and must be NONE of
  those. `passive` is therefore a per-instance, non-principal flag whose source
  of truth is this small launch-attribute table — exactly parallel to
  `Ezagent.AgentFlavorAttributes` (the `:flavor` launch attribute): not part of
  the URI, written before/at create, read by `Ezagent.UriQuery` so the
  routing/`:join`/mention gates can answer "is this URI a passive actor?" WITHOUT
  parsing the URI.

  RF-5a wires the create step to `put/2` this from the materialized role's
  `passive` field (`Ezagent.Role.Compose`). Until then, tests `put/2` directly.
  The default is `false` (principal actor) — a missing entry is NOT passive, so
  every existing agent keeps its principal semantics by construction.

  ## ⚠️ KNOWN LIMITATION — not restart-safe yet (RF-5a scope)

  This table is **volatile ETS only**, exactly like `AgentFlavorAttributes`'s
  first-spawn launch bridge — but UNLIKE flavor, the `:passive` UriQuery resolver
  has **no durable (kind-slice / snapshot) fallback yet**. After a node restart
  the ETS table is empty, so `passive?/1` returns `false` and a passive
  data-actor would revert to a chat PRINCIPAL until something re-`put/2`s it —
  the isolation FAILS OPEN across a cold restart.

  RF-6 deliberately defers the durable layers to **RF-5a**, which owns recipe →
  create-step population: RF-5a must (a) persist `passive` durably with the agent
  (the same way flavor persists in the sandbox slice) AND (b) extend
  `resolve_passive/1` with a kind-slice/snapshot fallback (mirroring
  `resolve_flavor`'s ETS → kind-slice → `flavor_from_durable_snapshot` layering),
  or the gate is not restart-safe. The routing/`:join`/mention gates themselves
  are correct and complete; only the source-of-truth durability is RF-5a's.
  """

  @table :ezagent_agent_passive_attributes

  @doc "Return the ETS table name (used by `EzagentDomainAgent.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc "Store the passive (non-principal) marker for an agent URI."
  @spec put(URI.t(), boolean()) :: :ok
  def put(%URI{} = agent_uri, passive?) when is_boolean(passive?) do
    :ets.insert(@table, {Ezagent.URI.stable_key(agent_uri), passive?})
    :ok
  end

  @doc """
  Is `agent_uri` a passive (non-principal) data actor?

  Fail-closed-to-PRINCIPAL: a missing entry (no stored attribute) is `false`,
  so an agent is treated as passive ONLY when explicitly marked. The
  routing/`:join`/mention gates reject on `true` — defaulting a missing entry to
  `false` keeps every unmarked agent a normal chat principal (the regression
  guarantee).
  """
  @spec passive?(URI.t()) :: boolean()
  def passive?(%URI{} = agent_uri) do
    case :ets.lookup(@table, Ezagent.URI.stable_key(agent_uri)) do
      [{_key, value}] when is_boolean(value) -> value
      _ -> false
    end
  end

  @doc "Delete any stored passive attribute for an agent URI."
  @spec delete(URI.t()) :: :ok
  def delete(%URI{} = agent_uri) do
    :ets.delete(@table, Ezagent.URI.stable_key(agent_uri))
    :ok
  end
end
