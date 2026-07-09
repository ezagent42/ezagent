defmodule Ezagent.Agent.RecipeAttributes do
  @moduledoc """
  Stored `recipe` (build-provenance name) attribute for an agent URI — the
  volatile ETS FAST PATH for the per-URI `:recipe` UriQuery resolver.

  (P2 role-slot: was `AgentRoleAttributes`/RF-7. In this codebase "role" and
  "recipe name" were conflated; P2 disambiguated them. This attribute records
  BUILD PROVENANCE — which recipe an agent was materialized from — NOT a session
  role. A session `role_name` lives ONLY on the (entity × session) membership
  edge, so the same agent can be `advisor` in one session and `reviewer` in
  another; Gate B forbids storing that session role on the agent.)

  An `entity://agent/*` created from a recipe carries that recipe's NAME. The
  recipe name is not part of the URI (a URI is an opaque id; flavor/recipe are
  stored attrs queried via `Ezagent.UriQuery`, never parsed). This table is the
  first-spawn launch-attribute bridge — exactly parallel to
  `Ezagent.AgentPassiveAttributes` (the `:passive` marker) and
  `Ezagent.AgentFlavorAttributes` (the `:flavor` marker).

  ## ETS = FAST PATH; durability lives in the `:sandbox` slice

  This table is the volatile ETS fast path. The *durable* source of truth is the
  agent's `:sandbox` slice `:recipe` field (written at create by the create
  step, snapshot-persisted by the Agent Kind). The `:recipe` UriQuery resolver
  (`EzagentDomainInstanceMessage.UriQueryResolvers`) layers **ETS → durable
  snapshot**, mirroring `resolve_passive` — so a per-URI recipe lookup stays
  correct across a cold restart (the ETS table is cleared on a BEAM restart).

  ## This table is the PER-URI fast path ONLY — NOT the list source

  `fetch/1` answers "which recipe was THIS agent built from?" (input URI →
  stable_key → lookup). It CANNOT answer "which agents came from recipe R?" —
  the ETS value is a bare recipe name and the list output must be agent URIs.
  The cold-restart-safe, cross-tenant-scopable, live+dormant list
  (`Ezagent.Agent.RecipeResolver.list_by_recipe/2`) is therefore sourced from the
  persisted `kind_snapshots` rows (which carry the `uri` column directly), NOT
  from this table.

  `fetch/1` (not a bare `recipe/1`) returns `:none` for an ABSENT entry so the
  layered resolver can fall through to the durable snapshot, instead of a `nil`
  that an ABSENT and a stored-no-recipe entry could not be distinguished by.
  """

  @table :ezagent_agent_recipe_attributes

  @doc "Return the ETS table name (used by `EzagentDomainAgent.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc "Store the recipe (build-provenance) NAME for an agent URI."
  @spec put(URI.t(), String.t()) :: :ok
  def put(%URI{} = agent_uri, recipe) when is_binary(recipe) and recipe != "" do
    :ets.insert(@table, {Ezagent.URI.stable_key(agent_uri), recipe})
    :ok
  end

  @doc """
  Fetch the stored recipe (build-provenance) NAME for an agent URI,
  distinguishing ABSENT.

  Returns `{:ok, recipe_name}` for a stored entry and `:none` for a missing one —
  parallel to `Ezagent.AgentFlavorAttributes.get/1` /
  `Ezagent.AgentPassiveAttributes.fetch/1`. The layered `:recipe` resolver uses
  THIS as its ETS fast path, so an absent entry falls through to the durable
  `:sandbox`-slice snapshot layer (the cold-restart source).
  """
  @spec fetch(URI.t()) :: {:ok, String.t()} | :none
  def fetch(%URI{} = agent_uri) do
    case :ets.lookup(@table, Ezagent.URI.stable_key(agent_uri)) do
      [{_key, recipe}] when is_binary(recipe) and recipe != "" -> {:ok, recipe}
      _ -> :none
    end
  end

  @doc "Delete any stored recipe (build-provenance) attribute for an agent URI."
  @spec delete(URI.t()) :: :ok
  def delete(%URI{} = agent_uri) do
    :ets.delete(@table, Ezagent.URI.stable_key(agent_uri))
    :ok
  end
end
