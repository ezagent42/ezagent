defmodule Ezagent.ActionSet.Workspace.AgentCreate.RoleStep do
  @moduledoc """
  RF-5a — the GENERIC role step of `:create_agent` (direct-spawn route).

  > **The CONTENTS of the sandbox are the ROLE; HOW the sandbox is loaded is the
  > FLAVOR.** (Allen 2026-06-14)

  When a create requests a `role` (name) on a DIRECT-SPAWN flavor (native / curl
  / np), this module resolves the role recipe (`Ezagent.Agent.RecipeRegistry`), composes
  it with the flavor's per-instance behavior set (`Ezagent.Agent.Recipe.Compose`), mints
  the recipe's authorized caps fail-closed (`Ezagent.Agent.Recipe.CapMint` × the flavor's
  CapMint policy from `Ezagent.AgentFlavorRegistry` — the RF-8 seam) and grants
  them at the workspace granter ctx (`Ezagent.Workspace.grant_initial_caps`, NOT
  the agent's own lifecycle), and records the durable `passive` (non-principal)
  marker. ONE generic step — no role-specific branch.

  Extracted from `Ezagent.ActionSet.Workspace.AgentCreate` (oversized-module arch
  gate) so the role concern is a separate module; the host threads the
  materialization into the spawn args (`:behaviors` override + `:passive`) and
  calls `grant_passive_marker/2` + `mint_and_grant_caps/4` after the spawn.

  ## Caps grant under CALLER authority (production note)

  `grant_initial_caps` authorizes via `{:held_by, caller}` — the chokepoint
  re-reads the CALLER's held caps and scope-bounds the grant (caps narrow, never
  broaden). So a non-admin creator must ALREADY hold the role's `requested_caps`
  or the create fails-closed at grant (`{:grant_failed, cap, reason}`). This is
  the intended CapBAC semantics (no privilege escalation via a role recipe); an
  admin/genesis creator holds everything and always succeeds.
  """

  alias Ezagent.Agent.Recipe
  alias Ezagent.Agent.RecipeBehaviorFold

  # File-flavors whose create route is the template/cascade path (NOT
  # direct-spawn); a role on these is RF-5b (deferred) → rejected fail-loud.
  # cc-custom / cc-headless-custom joined this lane in F3/#1460 — omitting them
  # here let a role pass validation and then be SILENTLY dropped by the
  # template lane (codex review of PR #1485).
  @file_flavors ~w(cc cc-headless echo codex codex-remote cc-custom cc-headless-custom)

  @doc "Is the `role` create arg shape-valid (nil or a string)?"
  @spec valid_role_arg?(term()) :: boolean()
  def valid_role_arg?(nil), do: true
  def valid_role_arg?(role) when is_binary(role), do: true
  def valid_role_arg?(_), do: false

  @doc """
  Coerce the `role` create arg to a role NAME or `nil`.

  An empty / whitespace-only string is treated as ABSENT (UI/CLI may pass `""`
  for "no role"), so the strict no-op gate fires.
  """
  @spec coerce_role_arg(term()) :: String.t() | nil
  def coerce_role_arg(nil), do: nil

  def coerce_role_arg(role) when is_binary(role) do
    case String.trim(role) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  RF-5a is the DIRECT-SPAWN role path only. A role requested with a file-flavor
  (cc/codex/echo/cc-headless/codex-remote) FAILS LOUD — RF-5b (role on the
  file-flavor/template route) is deliberately deferred. No role → always `:ok`
  (every existing create path unaffected).
  """
  @spec validate_for_flavor(String.t(), String.t() | nil) ::
          :ok | {:error, {:role_unsupported_for_flavor, String.t()}}
  def validate_for_flavor(_flavor, nil), do: :ok

  def validate_for_flavor(flavor, role) when is_binary(role) do
    if flavor in @file_flavors do
      {:error, {:role_unsupported_for_flavor, flavor}}
    else
      :ok
    end
  end

  @doc """
  Resolve + compose the requested role into the context-free materialization
  (`%{behaviors, passive, sandbox_content}`), or `{:ok, nil}` when no role was
  requested (the strict no-op gate — every existing create path is unaffected).

  A requested role that is unregistered or whose flavor is unknown FAILS LOUD
  (no silent fall-through to a roleless spawn). RF-5b (file-flavor role on
  cc/codex) is deferred — those flavors never reach this direct-spawn route.
  """
  @spec resolve(String.t() | nil, String.t()) ::
          {:ok, Recipe.Compose.materialized() | nil}
          | {:error, {:unknown_role, String.t()} | {:unknown_flavor_for_role, String.t()}}
  def resolve(nil, _flavor), do: {:ok, nil}

  def resolve(role_name, flavor) when is_binary(role_name) and is_binary(flavor) do
    with {:ok, recipe} <- lookup_role_recipe(role_name) do
      RecipeBehaviorFold.fold(recipe, flavor)
    end
  end

  @doc """
  Write the DURABLE passive (non-principal) marker for a passive role.

  The `:sandbox`-slice `:passive` field (threaded via the spawn args by the host)
  is the snapshot-backed source of truth; this ALSO primes the volatile ETS fast
  path (`Ezagent.AgentPassiveAttributes`) so the routing/`:join`/mention gates
  answer correctly BEFORE the first snapshot. A non-passive role (the default)
  writes nothing — an absent ETS entry + a `false` slice field both resolve to
  principal.
  """
  @spec grant_passive_marker(URI.t(), map() | nil) :: :ok
  def grant_passive_marker(_agent_uri, nil), do: :ok

  def grant_passive_marker(%URI{} = agent_uri, %{passive: true}) do
    Ezagent.AgentPassiveAttributes.put(agent_uri, true)
  end

  def grant_passive_marker(_agent_uri, _materialized), do: :ok

  @doc """
  Build the DURABLE marker spawn-args (`:passive` RF-6 + `:recipe` PROVENANCE,
  was RF-7 `:role`) the host merges into `Sandbox.create/1`'s args — both
  snapshot-backed in the `:sandbox` slice (the cold-restart source for the
  `:passive`/`:recipe` UriQuery resolvers +
  `Ezagent.Agent.RecipeResolver.list_by_recipe/2`). A no-recipe create
  (`nil` materialized) contributes nothing → the slice's defaults.
  """
  @spec spawn_marker_args(map() | nil) :: map()
  def spawn_marker_args(%{} = materialized) do
    %{}
    |> maybe_put(:passive, Map.get(materialized, :passive), &is_boolean/1)
    |> maybe_put(:recipe, Map.get(materialized, :recipe), &(is_binary(&1) and &1 != ""))
  end

  def spawn_marker_args(_), do: %{}

  defp maybe_put(args, key, value, valid?) do
    if valid?.(value), do: Map.put(args, key, value), else: args
  end

  @doc """
  Write the DURABLE RECIPE-PROVENANCE marker for a recipe-built agent (P2; was
  the RF-7 role marker).

  The `:sandbox`-slice `:recipe` field (threaded via the spawn args by the host)
  is the snapshot-backed source of truth for
  `Ezagent.Agent.RecipeResolver.list_by_recipe/2` + the `:recipe` UriQuery
  resolver. This ALSO primes the volatile ETS fast path
  (`Ezagent.Agent.RecipeAttributes`) so the per-URI `:recipe` resolver answers
  correctly BEFORE the first snapshot. A no-recipe create (`nil` materialized or
  an unnamed recipe) writes nothing — an absent ETS entry + a `nil` slice field
  both resolve to "no recipe provenance". This records BUILD PROVENANCE only,
  never a session role (session role_name lives on the membership edge; Gate B).
  """
  @spec grant_recipe_marker(URI.t(), map() | nil) :: :ok
  def grant_recipe_marker(_agent_uri, nil), do: :ok

  def grant_recipe_marker(%URI{} = agent_uri, %{recipe: recipe})
      when is_binary(recipe) and recipe != "" do
    Ezagent.Agent.RecipeAttributes.put(agent_uri, recipe)
  end

  def grant_recipe_marker(_agent_uri, _materialized), do: :ok

  @doc """
  Mint the role recipe's authorized caps fail-closed and grant them at the
  workspace granter ctx.

  CapMint (`Ezagent.Agent.Recipe.CapMint.mint/3`) runs the recipe's `requested_caps`
  through the FLAVOR's cap-policy from the registry (the RF-8 seam) — a flavor
  with no `:cap_policy` mints NOTHING (fail-closed, never a default grant). The
  minted caps are granted into the agent via
  `Ezagent.Workspace.grant_initial_caps/3` under the caller's authority. No role
  → `:ok` (the strict no-op gate).

  `params` carries `:role` (name), `:workspace_uri`, and `:caller`.
  """
  @spec mint_and_grant_caps(URI.t(), String.t(), map() | nil, map()) :: :ok | {:error, term()}
  def mint_and_grant_caps(_agent_uri, _flavor, nil, _params), do: :ok

  def mint_and_grant_caps(%URI{} = agent_uri, flavor, _materialized, params) do
    role_name = Map.get(params, :role)

    with {:ok, recipe} <- lookup_role_recipe(role_name),
         {:ok, decl} <- RecipeBehaviorFold.lookup_flavor_decl(flavor),
         {:ok, caller} <- require_caller(params) do
      case Map.get(decl, :cap_policy) do
        policy when is_function(policy, 1) ->
          minted =
            Ezagent.Agent.Recipe.CapMint.mint(
              recipe.requested_caps,
              %{
                # The cap `kind` axis is the ATOM `:agent` — it must match how the
                # role's behaviors declare `required_caps` (e.g. `Sandbox` uses
                # `Ezagent.Capability.cap(:agent, …)`); a string axis would mint a
                # cap that never authorizes dispatch. Every create here composes an
                # `entity://…/agent/…` URI, so `:agent` is correct by construction.
                kind: :agent,
                instance: agent_uri,
                workspace_uri: Map.fetch!(params, :workspace_uri),
                granter: caller
              },
              policy.(recipe.requested_caps)
            )

          Ezagent.Workspace.grant_initial_caps(agent_uri, minted, %{caller: caller})

        _ ->
          # No flavor cap-policy → no role-driven minting (fail-closed default).
          :ok
      end
    end
  end

  defp lookup_role_recipe(role_name) do
    case Ezagent.Agent.RecipeRegistry.lookup(role_name) do
      {:ok, recipe} -> {:ok, recipe}
      :error -> {:error, {:unknown_role, role_name}}
    end
  end

  defp require_caller(params) do
    case Map.get(params, :caller) do
      %URI{} = caller -> {:ok, caller}
      _ -> {:error, :missing_caller_for_role_caps}
    end
  end
end
