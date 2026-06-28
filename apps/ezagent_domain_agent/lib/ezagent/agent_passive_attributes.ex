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
  `passive` field (`Ezagent.Agent.Recipe.Compose`). Until then, tests `put/2` directly.
  The default is `false` (principal actor) — a missing entry is NOT passive, so
  every existing agent keeps its principal semantics by construction.

  ## ETS = FAST PATH; durability lives in the `:sandbox` slice (RF-5a)

  This table is the **volatile ETS fast path**, exactly like
  `AgentFlavorAttributes`'s first-spawn launch bridge. The *durable* source of
  truth is the agent's `:sandbox` slice `:passive` field (written at create by
  `Ezagent.Behavior.Workspace.AgentCreate`'s role step, snapshot-persisted by the
  Agent Kind's `{:snapshot, :on_change}` policy). RF-5a made the
  `:passive` UriQuery resolver (`EzagentDomainInstanceMessage.UriQueryResolvers`)
  layer **ETS → kind-slice → durable snapshot**, mirroring `resolve_flavor`'s
  layering — so a passive data-actor stays passive across a cold restart (the
  isolation no longer FAILS OPEN to principal after the ETS table is cleared).

  `fetch/1` (not `passive?/1`) is the layered resolver's first probe: it returns
  `:none` for an ABSENT entry so the resolver can fall through to the durable
  layers, instead of a bare `false` that would shadow them (a stored `false` and
  an absent entry are NOT the same — only `fetch/1` distinguishes them).
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

  @doc """
  Fetch the stored passive attribute for an agent URI, distinguishing ABSENT.

  Returns `{:ok, boolean}` for a stored entry and `:none` for a missing one —
  parallel to `Ezagent.AgentFlavorAttributes.get/1`. The layered `:passive`
  resolver uses THIS (not `passive?/1`) as its ETS fast path, so an absent entry
  falls through to the durable `:sandbox`-slice / snapshot layers instead of a
  bare `false` shadowing them (the cold-restart fail-open RF-6 flagged). A stored
  `false` is authoritative (an explicitly-principal agent) and stops the layering.
  """
  @spec fetch(URI.t()) :: {:ok, boolean()} | :none
  def fetch(%URI{} = agent_uri) do
    case :ets.lookup(@table, Ezagent.URI.stable_key(agent_uri)) do
      [{_key, value}] when is_boolean(value) -> {:ok, value}
      _ -> :none
    end
  end

  @doc "Delete any stored passive attribute for an agent URI."
  @spec delete(URI.t()) :: :ok
  def delete(%URI{} = agent_uri) do
    :ets.delete(@table, Ezagent.URI.stable_key(agent_uri))
    :ok
  end
end
