defmodule Ezagent.Entity.User do
  @moduledoc """
  User Kind — Phase 4-completion stable form.

  Implements `Ezagent.Kind` with Identity Behavior (Phase 3d added,
  Decision #24). Holds the admin-bootstrap constants `admin_uri/0` and
  `admin_caps/0` per Decision P1-D5 (no separate `Ezagent.Bootstrap` module
  — admin-specific knowledge is User-Kind-shaped).

  - `type_name :user`
  - `behaviors [Ezagent.ActionSet.Identity]` — caps live in slice state
  - `persistence {:snapshot, :on_change}` — Phase 4-completion PR 2
    landed real snapshot impl; granted caps survive restart

  Non-admin Users (Phase 4-completion PR 4-5):
  - Provisioned via `mix ezagent.user.create entity://user/<workspace>/X --password Y --caps ...`
  - Authenticated via `/login` (`EzagentWeb.SessionController` +
    `Ezagent.Users.verify_password/2`)
  - Their caps live only in `Ezagent.IdentityCaps.Store`; the Identity slice
    is a live projection.
  """

  # Phase 9 PR-2 (SPEC v3 §3): entity URIs carry a workspace segment.
  # Phase 9 PR-8 (SPEC v3 §13.1): admin moved from the legacy default workspace
  # to `workspace://system` — the Keycloak realm-admin model. System
  # members hold cross-workspace authority by membership (see
  # `Ezagent.Capability.cross_workspace?/2`); the structural admin cap
  # keeps `workspace_uri: :any` for defence in depth.

  @doc "Bootstrap admin principal URI: `entity://user/system/admin`."
  @spec admin_uri() :: URI.t()
  def admin_uri, do: Ezagent.URI.user(:system, :admin)

  @doc """
  Bootstrap caps the User Kind for `uri` should be spawned with.

  Single chokepoint for the `entity://user/*` SpawnRegistry handler
  (registered both in `EzagentDomainIdentity.Application` and — for
  stacks loading chat — overwritten in
  `EzagentDomainInstanceMessage.Application`). Both fns delegate here so the
  policy stays in ONE place.

  Reads the sole Store authority. During the clean first-spawn window, staged
  initial grants are visible before the first authority generation exists.
  Once authority history exists, non-active rows expose no capabilities.

  Returns `MapSet.t(Ezagent.Capability.t())`.

  A missing or unreadable Store row returns an empty argument projection; the
  actor readiness path independently refuses established cold starts without
  Store authority.
  """
  @spec initial_caps_for_spawn(URI.t()) :: MapSet.t(Ezagent.Capability.t())
  def initial_caps_for_spawn(%URI{} = uri) do
    case Ezagent.IdentityCaps.Store.load_initial(uri) do
      {:ok, caps} -> MapSet.new(caps)
      {:error, _reason} -> MapSet.new()
    end
  end

  # SPEC caps-cleanup-v1 §4 / §4.6 (PR-CC-1): `admin_caps/0` DELETED.
  # The ambient all-caps escape hatch is replaced by the closed
  # `Ezagent.SystemPrincipal.Catalog` allowlist of 14 system
  # principals + their permitted caps. Per-Kind sealed anchors replace the
  # former ambient admin wildcard.
  #
  # Per `feedback_let_it_crash_no_workarounds`: there is no shim
  # here — any remaining caller fails at compile time, and the
  # invariant test `no_admin_caps_fallback_test.exs` is the gate
  # against re-introduction.
  #
  # PR-甲-2 (#154): `default_caps/1` no longer mints a `system://bootstrap`-
  # granted session baseline (it returns `[]`), so the former
  # `system_bootstrap_uri/0` helper + `@admin_granted_at` static timestamp it
  # used for grant attribution are gone — participation is granted per-session
  # at the trusted access points with the session owner as `granted_by`.

  @doc """
  Default caps every non-admin User starts life with — now **empty** (`[]`).

  ## no-unowned-caps north star PR-甲-2 (Decision #154 / capbac.md §6)

  HISTORY: PR 27 (Allen 2026-05-18) gave every Ezagent User a single broad
  baseline cap at creation —
  `cap(:session, behavior: :any, action: :any, instance: :any, ws)`,
  granted by `system://bootstrap`. The intent was "every user can attempt
  to participate in a session"; the consequence was that a member NOT
  pulled into a session still held that session's permissions across the
  ENTIRE workspace, and the `granted_by` was an abstract `system://`
  principal (a Decision #154 violation).

  Allen-approved target model (spec
  `2026-06-19-membership-mount-anon-model-design.md`): "a member not pulled
  into a session has no session perms; participation is granted per-session
  at join, by the session owner." Join authority is rooted at SESSION POLICY
  (`Ezagent.ActionSet.Session.Membership.provision_join_authority/2`, owner-
  rooted) and the participation TIER is mounted at the trusted access points
  after a successful join (`Membership.mount_participation_caps/2`) — both
  with a real-entity `granted_by` (the session owner; admin only as the named
  extreme-case granter), never a `system://` principal.

  With participation + join moved to the access points, this baseline is no
  longer needed and returns `[]`. A fresh User holds ONLY the structural
  self-Identity cap (added by `Behavior.Identity.init_slice/1` via
  `add_owner_identity_cap/2`) — exactly the least-privilege "no session perms
  until pulled in" target.

  The `%URI{scheme: "workspace"}` argument is retained for signature stability
  (callers + `CapabilityRegistry.register_default_grant/2` pass the user's
  workspace URI) and for any future workspace-scoped NON-session baseline; it
  is currently unused.

  Prepended to user-supplied caps in `Ezagent.Domain.Identity.Users.create/3`
  (a `[]` prepend is a no-op). Feishu `BindingPolicy.apply/2` re-grants
  `default_caps/1` and so becomes a natural no-op — a bound user participates
  per-session via join like everyone else (the bind is only the open_id↔user
  link).
  """
  @spec default_caps(URI.t()) :: [Ezagent.Capability.t()]
  def default_caps(%URI{scheme: "workspace"} = _workspace_uri), do: []

  # --- Ezagent.Kind callbacks -----------------------------------------------
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :user

  # Phase 3d: User Kinds carry Identity Behavior so caps live in slice
  # state (Decision #24). admin_caps/0 above still provides the
  # bootstrap value — chat plugin passes it as initial_caps when
  # spawning admin User.
  #
  # PR #126 (2026-05-19): User Kinds ALSO carried the ApiKeys Behavior
  # so per-user secret storage (DeepSeek, OpenAI, etc.) coexisted with
  # cap state on the same Kind. Allen 2026-05-26: that's wrong — agents
  # hold their own keys (the credential funds the agent's outbound
  # request, not the user's). ApiKeys is now on `Ezagent.Entity.Agent`.
  # User Kind no longer carries `:api_keys` slice. Existing user-side
  # `:api_keys` data in `kind_snapshots.state_binary` is orphaned (no
  # Behavior reads it) — operators re-PUT their keys onto the relevant
  # agent. Per `feedback_let_it_crash_no_workarounds`, no destructive
  # migration runs against live DBs.
  #
  # HIGH-2 completion (2026-05-26): UserCredentials Behavior carries
  # password mutation via dispatch (closes the legacy
  # `mix ezagent.user.set_password` bypass). UserTokens Behavior
  # carries bearer-token CRUD via dispatch (closes the legacy
  # `mix ezagent.user.token --mint/list/revoke` bypass except for the
  # admin-bootstrap mint carve-out). Both slices (`:user_credentials`
  # / `:user_tokens`) are incidental counters; durable storage is the
  # `users.password_hash` column + the `entity_tokens` table.
  @impl Ezagent.Kind
  def behaviors,
    do: [
      Ezagent.ActionSet.Identity,
      Ezagent.ActionSet.UserCredentials,
      Ezagent.ActionSet.UserTokens
    ]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): User Kinds live under the identity
  # domain's UserSupervisor. `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainIdentity.Application.UserSupervisor
end
