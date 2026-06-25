defmodule Ezagent.AgentRoleAttributes do
  @moduledoc """
  Stored `role` (name) attribute for an agent URI (RF-7) — the volatile ETS
  FAST PATH for the per-URI `:role` UriQuery resolver.

  An `entity://agent/*` created from a role recipe carries that role's NAME. The
  role name is not part of the URI (a URI is an opaque id; flavor/role are stored
  attrs queried via `Ezagent.UriQuery`, never parsed). This table is the
  first-spawn launch-attribute bridge — exactly parallel to
  `Ezagent.AgentPassiveAttributes` (the `:passive` marker) and
  `Ezagent.AgentFlavorAttributes` (the `:flavor` marker).

  ## ETS = FAST PATH; durability lives in the `:sandbox` slice (RF-7)

  This table is the volatile ETS fast path. The *durable* source of truth is the
  agent's `:sandbox` slice `:role` field (written at create by the role create
  step, snapshot-persisted by the Agent Kind). The `:role` UriQuery resolver
  (`EzagentDomainInstanceMessage.UriQueryResolvers`) layers **ETS → durable
  snapshot**, mirroring `resolve_passive` — so a per-URI role lookup stays
  correct across a cold restart (the ETS table is cleared on a BEAM restart).

  ## This table is the PER-URI fast path ONLY — NOT the list source

  `fetch/1` answers "what role is THIS agent?" (input URI → stable_key →
  lookup). It CANNOT answer "which agents have role R?" — the ETS value is a
  bare role name and the list output must be agent URIs. The cold-restart-safe,
  cross-tenant-scopable, live+dormant list (`Ezagent.AgentRoleResolver.list_by_role/2`)
  is therefore sourced from the persisted `kind_snapshots` rows (which carry the
  `uri` column directly), NOT from this table.

  `fetch/1` (not a bare `role/1`) returns `:none` for an ABSENT entry so the
  layered resolver can fall through to the durable snapshot, instead of a `nil`
  that an ABSENT and a stored-no-role entry could not be distinguished by.
  """

  @table :ezagent_agent_role_attributes

  @doc "Return the ETS table name (used by `EzagentDomainAgent.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc "Store the role NAME for an agent URI."
  @spec put(URI.t(), String.t()) :: :ok
  def put(%URI{} = agent_uri, role) when is_binary(role) and role != "" do
    :ets.insert(@table, {Ezagent.URI.stable_key(agent_uri), role})
    :ok
  end

  @doc """
  Fetch the stored role NAME for an agent URI, distinguishing ABSENT.

  Returns `{:ok, role_name}` for a stored entry and `:none` for a missing one —
  parallel to `Ezagent.AgentFlavorAttributes.get/1` /
  `Ezagent.AgentPassiveAttributes.fetch/1`. The layered `:role` resolver uses
  THIS as its ETS fast path, so an absent entry falls through to the durable
  `:sandbox`-slice snapshot layer (the cold-restart source).
  """
  @spec fetch(URI.t()) :: {:ok, String.t()} | :none
  def fetch(%URI{} = agent_uri) do
    case :ets.lookup(@table, Ezagent.URI.stable_key(agent_uri)) do
      [{_key, role}] when is_binary(role) and role != "" -> {:ok, role}
      _ -> :none
    end
  end

  @doc "Delete any stored role attribute for an agent URI."
  @spec delete(URI.t()) :: :ok
  def delete(%URI{} = agent_uri) do
    :ets.delete(@table, Ezagent.URI.stable_key(agent_uri))
    :ok
  end
end
