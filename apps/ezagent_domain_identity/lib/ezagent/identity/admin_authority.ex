defmodule Ezagent.Identity.AdminAuthority do
  @moduledoc """
  Admin-authority policy module (SPEC 2026-05-27-workspace-cap-based-visibility
  OQ-4 — r5 option b).

  ## Why this module exists (placement rationale)

  The §3.3 admin shortcut for `Ezagent.Workspace.list_workspaces_for/2`
  is a UNION of FOUR predicates that today live in two modules:

  - `Ezagent.ActionSet.IdentityAdmin.holds_admin_caps?/1` —
    `ezagent_domain_identity` (bootstrap-wildcard cap shape).
  - `Ezagent.ActionSet.IdentityAdmin.holds_cross_workspace_admin_cap?/1`
    — `ezagent_domain_identity` (delegated structural workspace-admin).
  - `Ezagent.Capability.home_is_system?/1` — `ezagent_core` (URI host
    `system`).
  - `Ezagent.Capability.member_of_system?/1` — `ezagent_core`
    (explicit `workspace://system` membership).

  Codex r3 review (MED) flagged that placing the helper in
  `ezagent_core` (`Capability`) would be a layer violation —
  `ezagent_domain_identity` depends on `ezagent_core`, so `Capability`
  calling `IdentityAdmin.holds_*` reverses the umbrella graph.

  Codex r4 review (MED) flagged that placing the helper as
  `Behavior.Identity.admin_authority?/2` was wrong on TWO grounds:
  (a) the predicates live on `IdentityAdmin`, not `Identity`, and
  (b) attaching a policy decision to a Behavior action module
  conflates policy with Behavior.

  This module — `Ezagent.Identity.AdminAuthority`, OUTSIDE the
  `Behavior.*` namespace — is the structural fix. The umbrella graph
  is respected (lives in `ezagent_domain_identity`, depends on
  `ezagent_core` for `Capability`, used by `ezagent_domain_workspace`
  for `list_workspaces_for/2`).

  ## Authority axis vs. `Capability.cross_workspace?/2`

  Per SPEC §3.3 "Relationship — deliberately narrower" + §10 OQ-7
  (r5): `AdminAuthority.admin?/2` and `Capability.cross_workspace?/2`
  cover DISTINCT authority axes:

  - `cross_workspace?/2` is per-cap, per-action: "given this ONE
    cap which already authorized THIS action, does it also bypass
    workspace isolation?" — runtime bypass at the dispatch
    chokepoint.
  - `AdminAuthority.admin?/2` is per-caller, aggregate: "is this
    caller an admin in the operator-listing sense?" — operator-facing
    visibility.

  The two share THREE clauses (home_is_system?, member_of_system?,
  and the narrowly-shaped wildcard-cap paths in (i)/(ii)) but the
  admin shortcut does NOT mirror `cross_workspace?/2`'s first
  clause (a non-admin-shape `workspace_uri: :any` cap). See
  SPEC §3.3 "Relationship" subsection for the full asymmetry.

  ## Forward-looking maintainability contract (codex r4 NIT)

  When future SPECs add new admin-cap variants:

  - YES, the new variant ALSO bypasses runtime workspace isolation
    → update both `cross_workspace?/2` AND the relevant
    `holds_*_admin_caps?` predicate.
  - NO, the new variant only confers operator-listing admin
    authority → update only the `holds_*_admin_caps?` predicate.

  ## Future maintainability sanity

  `admin?/2` is the SINGLE entry point operator-listing code calls.
  The four underlying predicates remain unit-testable at their
  existing homes (`IdentityAdmin.holds_*` and `Capability.*`); a
  change to any one is automatically reflected through this helper.
  """

  alias Ezagent.ActionSet.IdentityAdmin
  alias Ezagent.Capability

  @doc """
  Is the caller an operator in the operator-listing sense, with caps
  loaded LIVE?

  The one-call convenience over `admin?/2`: loads the caller's caps via
  `Ezagent.EntityCaps.load/1` (live-first, so a fresh promotion/demotion
  is seen immediately) and delegates to the 4-predicate union. This is
  the SAME predicate the read-plane chokepoints (`OperatorReads`,
  `UserReads`, `TemplateReads`) gate on — the load-and-check pair is
  never re-implemented per caller (a security boundary must not be
  copy-pasted). Any load failure → `false` (fail-closed).
  """
  @spec admin?(URI.t() | term()) :: boolean()
  def admin?(%URI{} = caller_uri) do
    caller_uri
    |> Ezagent.EntityCaps.load()
    |> then(&admin?(caller_uri, &1))
  rescue
    _ -> false
  end

  def admin?(_caller), do: false

  @doc """
  Is the caller an admin in the operator-listing sense?

  Returns `true` iff the 4-predicate UNION holds:

  1. `IdentityAdmin.holds_admin_caps?(caps)` — bootstrap wildcard
     (all five `:any` axes).
  2. `IdentityAdmin.holds_cross_workspace_admin_cap?(caps)` —
     delegated cross-workspace admin
     (`kind: :workspace, behavior: Workspace, action: :any,
       instance: :any, workspace_uri: :any`).
  3. `Capability.home_is_system?(caller_uri)` — caller URI host is
     `system`.
  4. `Capability.member_of_system?(caller_uri)` — caller is listed
     in `workspace://system.members`.

  The four are NOT subsumed by each other (per SPEC §3.3). Callers
  whose URI is malformed, who hold no caps, and who aren't system
  members return `false` — they go through the
  `list_workspaces_for/2` cap-scope + membership union instead of
  the admin shortcut.

  ## Performance note

  Order is cheapest-first: cap predicates short-circuit before
  membership lookup (which hits the workspace store via
  `apply/3`). For a non-admin caller, two cheap pattern matches
  precede the DB-touching membership query.
  """
  @spec admin?(URI.t() | nil, MapSet.t() | [Capability.t()]) :: boolean()
  def admin?(caller_uri, caps) do
    IdentityAdmin.holds_admin_caps?(caps) or
      IdentityAdmin.holds_cross_workspace_admin_cap?(caps) or
      caller_admin_by_uri?(caller_uri)
  end

  # Membership / URI-host predicates require a `%URI{}`. Malformed
  # callers (`nil`, atoms, strings) get `false` — they go through
  # the union branch, where membership returns `[]` for unparseable
  # callers per SPEC §3.6.
  defp caller_admin_by_uri?(%URI{} = caller_uri) do
    Capability.home_is_system?(caller_uri) or Capability.member_of_system?(caller_uri)
  end

  defp caller_admin_by_uri?(_), do: false
end
