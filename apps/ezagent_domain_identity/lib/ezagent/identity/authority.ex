defmodule Ezagent.Identity.Authority do
  @moduledoc """
  Public manage-authority predicates (membership-cap unification Phase B.1,
  spec K2) — the SINGLE source of truth for "does principal P have manage/owner
  authority over target X?".

  ## Why this module exists

  The predicates `holds_manage_over_target?/2` and `holds_workspace_admin_cap?/2`
  used to be PRIVATE `defp`s inside `Ezagent.ActionSet.IdentityAdmin`
  (`behavior/identity.ex`). Two consumers now need them:

    * `IdentityAdmin`'s `grant_cap` authorization (the manager-delegated grant
      branch) — reads the CALLER's dispatch caps (`ctx.caps`);
    * the Part B cascade resolver `managers_of/1` + the Part C admission trigger
      — need the URI-based predicate `manages?/2` that resolves a caller's
      **durable identity caps by URI** (NOT `ctx.caps`).

  Extracting the shared logic here (and having `IdentityAdmin` call it) keeps ONE
  authority definition. A sibling `Ezagent.Identity.AdminAuthority` (`admin?/2`)
  already exists but exposes no per-target `manages?/2` — do NOT conflate.

  ## The two caps-list predicates (pure)

  `holds_manage_over_target?/2` and `workspace_admin?/2` operate on a plain caps
  LIST and are pure (no I/O). Callers that already hold the relevant caps (the
  dispatch `ctx.caps` path, or a provenance-pre-filtered candidate scan) pass the
  list directly.

  ## `manages?/2` — durable-identity, admin-UNION (K2)

  `manages?(caller, target)` resolves the caller's DURABLE identity caps by URI
  via `Ezagent.EntityCaps.load/1` (K5 — the live `:identity` slice, NOT
  `ctx.caps`, NOT `users.caps_json`) and is true iff the caller:

    * holds a `Manage`-over-`target` cap, OR
    * is an admin per the FULL admin union (`AdminAuthority.admin?/2` — bootstrap
      genesis wildcard `holds_admin_caps?/1` ∪ cross-workspace admin ∪ system
      URI/membership), OR
    * is a workspace admin over `target`'s workspace (`workspace_admin?/2`).

  The full admin union is load-bearing: the materializer dispatches member-joins
  under `admin_uri` whose **identity** holds the genesis wildcard (its `ctx.caps`
  carries only a narrow inline join cap). A `ctx.caps`-based or workspace-only
  predicate would fail to recognize that admin and relocate the Part C over-fire
  (every team-template spawn would stall PENDING). Reading durable caps by URI +
  the admin union is why `manages?(admin_uri, member)` is true (spec §C.1).

  ## Provenance

  `manages?/2` does NOT provenance-filter: the admin branch must recognize the
  system-granted genesis wildcard. The Part B resolver (`managers_of/1`) applies
  `Ezagent.Capability.granted_by_entity?/1` (K4) in the CALLER before matching, so
  the filter lives where a stale/system-granted Manage cap must not over-match —
  not inside these shared predicates.
  """

  alias Ezagent.Capability
  alias Ezagent.Identity.AdminAuthority

  @doc """
  True iff `caps` (a list of `%Capability{}`) contains a `Manage`-`:any` cap whose
  instance scope covers `instance`. `instance` may be a concrete `%URI{}` or a
  scope tuple (e.g. `{:within_session, uri}`) — the inner URI is used as the
  managed target. Honors the held cap's `:within_workspace`/`:spawned_by`/
  concrete-URI/`:any` instance scope via `Capability.matches?/2`.
  """
  @spec holds_manage_over_target?([Capability.t()] | term(), term()) :: boolean()
  def holds_manage_over_target?(caps, instance) when is_list(caps) do
    target = manage_target_instance(instance)

    Enum.any?(caps, fn
      %Capability{behavior: Ezagent.ActionSet.Manage} = held ->
        Capability.action_of(held) == :any and held_instance_covers_target?(held, target)

      _ ->
        false
    end)
  end

  def holds_manage_over_target?(_caps, _instance), do: false

  @doc """
  True iff `caps` holds a workspace-admin cap over `ws_uri`: a `Workspace`-`:any`
  cap scoped to `ws_uri` (or the cross-workspace `workspace_uri: :any` variant).
  """
  @spec workspace_admin?([Capability.t()] | term(), URI.t()) :: boolean()
  def workspace_admin?(caps, %URI{} = ws_uri) when is_list(caps) do
    Enum.any?(caps, fn
      %Capability{behavior: Ezagent.ActionSet.Workspace, action: :any, workspace_uri: ^ws_uri} ->
        true

      %Capability{behavior: Ezagent.ActionSet.Workspace, action: :any, workspace_uri: :any} ->
        true

      _ ->
        false
    end)
  end

  def workspace_admin?(_caps, _ws_uri), do: false

  @doc """
  Does `caller` have manage/owner authority over `target`? Resolves the caller's
  DURABLE identity caps by URI (K2/K5) and judges them against the FULL admin
  union — INCLUDING `AdminAuthority.admin?/2`'s `caller_admin_by_uri?`
  (`home_is_system?` / `member_of_system?`) branch. This is the long-standing
  behaviour of the live session-membership / composition authorizers
  (`membership.ex`, `composition_caps.ex`) and is deliberately UNCHANGED. Note the
  distinction from `manages?/3`: that arity takes a PRESENTED, unforgeable cap
  witness and deliberately DROPS the URI-trust branch, for surfaces where the
  caller identity is a free parameter (codex ② — `GranteeIndex.grantees_of/4`).
  """
  @spec manages?(URI.t(), URI.t()) :: boolean()
  def manages?(%URI{} = caller, %URI{} = target) do
    caps = Ezagent.EntityCaps.load(caller)

    holds_manage_over_target?(caps, target) or
      AdminAuthority.admin?(caller, caps) or
      workspace_admin?(caps, Capability.workspace_of(target))
  end

  def manages?(_caller, _target), do: false

  @doc """
  Does `caller` manage `target`, judged against the caller's **presented**
  `caller_caps` — the AUTHENTICATED, signed held-cap witness from a dispatch ctx /
  self-license, NOT loaded from the caller URI. Use THIS from any surface where the
  caller identity arrives as a free parameter (e.g. `GranteeIndex.grantees_of/4`,
  codex ②): loading caps from a caller-supplied URI is a forgeable witness (naming
  `user://system/admin` would load admin's caps); requiring the caller to PRESENT
  the caps they actually hold is not forgeable — an attacker cannot present a
  signed cap they do not hold. `caller` is still used for the canonical-admin
  identity check (`AdminAuthority.admin?/2` binds the admin cap to the URI).
  """
  @spec manages?(URI.t(), URI.t(), Enumerable.t()) :: boolean()
  def manages?(%URI{} = _caller, %URI{} = target, caller_caps) do
    holds_manage_over_target?(caller_caps, target) or
      caps_only_admin?(caller_caps) or
      workspace_admin?(caller_caps, Capability.workspace_of(target))
  end

  def manages?(_caller, _target, _caps), do: false

  # codex ②: the CAPS-only admin predicates. Deliberately EXCLUDES
  # `AdminAuthority.admin?/2`'s `caller_admin_by_uri?` branch, which grants admin
  # to ANY `system`-home caller URI (e.g. `user://system/admin`) with NO presented
  # cap — the exact forgeable witness this presented-caps arity closes. A real
  # admin presents its signed admin caps; an impostor merely naming the admin URI
  # holds none, so this returns false.
  defp caps_only_admin?(caps) do
    Ezagent.ActionSet.IdentityAdmin.holds_admin_caps?(caps) or
      Ezagent.ActionSet.IdentityAdmin.holds_cross_workspace_admin_cap?(caps)
  end

  # ---- shared instance-scope helpers (moved verbatim from IdentityAdmin) ----

  # The "target" a Manage cap must cover is the cap-to-grant's `instance`. When
  # that instance is itself a scope tuple (e.g. `{:within_session, _}`), use the
  # inner concrete URI as the managed target.
  defp manage_target_instance({_scope, %URI{} = uri}), do: uri
  defp manage_target_instance(other), do: other

  # Does the held Manage cap's instance scope cover `target`? Reuses
  # `Capability.matches?`'s instance-scope semantics by building a `needed` whose
  # kind/behavior/action/workspace AXES ECHO the held cap's own values (so those
  # four axes match trivially — sidestepping the asymmetric-`:any` rule which
  # would reject a `needed.kind: :any` against a concrete held kind), leaving the
  # INSTANCE axis as the only real constraint.
  defp held_instance_covers_target?(%Capability{} = held, %URI{} = target) do
    needed = %{
      kind: held.kind,
      behavior: held.behavior,
      action: Capability.action_of(held),
      instance: target,
      workspace_uri: held.workspace_uri
    }

    Capability.matches?(held, needed)
  end

  defp held_instance_covers_target?(_held, _target), do: false
end
