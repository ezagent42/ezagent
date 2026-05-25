defmodule Ezagent.Entity.User do
  @moduledoc """
  User Kind — Phase 4-completion stable form.

  Implements `Ezagent.Kind` with Identity Behavior (Phase 3d added,
  Decision #24). Holds the admin-bootstrap constants `admin_uri/0` and
  `admin_caps/0` per Decision P1-D5 (no separate `Ezagent.Bootstrap` module
  — admin-specific knowledge is User-Kind-shaped).

  - `type_name :user`
  - `behaviors [Ezagent.Behavior.Identity]` — caps live in slice state
  - `persistence {:snapshot, :on_change}` — Phase 4-completion PR 2
    landed real snapshot impl; granted caps survive restart

  Non-admin Users (Phase 4-completion PR 4-5):
  - Provisioned via `mix ezagent.user.create entity://user/<workspace>/X --password Y --caps ...`
  - Authenticated via `/login` (`EzagentWeb.SessionController` +
    `Ezagent.Users.verify_password/2`)
  - Their caps live in `Ezagent.Users.caps_json` SQLite column AND mirror
    into Identity slice via `init_slice/1`
  """

  # Phase 9 PR-2 (SPEC v3 §3): entity URIs carry a workspace segment.
  # Phase 9 PR-8 (SPEC v3 §13.1): admin moved from the legacy default workspace
  # to `workspace://system` — the Keycloak realm-admin model. System
  # members hold cross-workspace authority by membership (see
  # `Ezagent.Capability.cross_workspace?/2`); the structural admin cap
  # keeps `workspace_uri: :any` for defence in depth.
  @admin_uri URI.parse("entity://user/system/admin")
  @system_bootstrap_uri URI.parse("system://bootstrap/default")

  # Static granted_at — admin capability is a structural bootstrap, not
  # a time-varying grant. Same value across boots so tests/fixtures stay
  # deterministic.
  @admin_granted_at ~U[2026-01-01 00:00:00Z]

  @doc "Bootstrap admin principal URI: `entity://user/system/admin`."
  @spec admin_uri() :: URI.t()
  def admin_uri, do: @admin_uri

  @doc """
  Admin's structural all-caps capability set.

  One capability with triple-`:any` granted by `system://bootstrap` —
  this is the invariant `Ezagent.Capability.revoke/2` refuses to remove.
  Returned as a `MapSet` so `Ezagent.Capability.matches?/2` lookups via
  `Enum.any?(caps, ...)` are O(n) of constant n=1 in Phase 1.
  """
  @spec admin_caps() :: MapSet.t(Ezagent.Capability.t())
  def admin_caps do
    MapSet.new([
      %Ezagent.Capability{
        kind: :any,
        behavior: :any,
        instance: :any,
        # Phase 9 PR-3 (SPEC v3 §4.4): admin's structural cap is
        # cross-workspace by design — the only cap with
        # `workspace_uri: :any` outside of explicit
        # `cross-workspace:dispatch` grants.
        workspace_uri: :any,
        granted_by: @system_bootstrap_uri,
        granted_at: @admin_granted_at
      }
    ])
  end

  @doc """
  Default caps every non-admin User starts life with.

  PR 27 (Allen 2026-05-18): every ESR User is, by construction, a
  principal that can attempt to participate in a session — without
  this baseline cap, even the most basic Feishu-delegate / CLI-test
  path is unauthorized and silently drops. Making this a User Kind
  structural default keeps every creation site (LV, mix task, Feishu
  bind) consistent without forcing each caller to remember the
  boilerplate.

  This is NOT an authorization escape hatch. The cap says "this
  principal may attempt to invoke session behaviors on some session
  instance"; whether the message actually lands depends on session
  membership and routing rules, not on this cap. Admin's wildcard
  `admin_caps/0` is the only true escape hatch, and is granted only
  to `entity://user/system/admin`.

  **Behavior wildcard**: `:any` follows the existing project
  convention. Modeling specific behaviors here would require
  ezagent_domain_identity
  to depend on ezagent_domain_chat (circular), or runtime
  BehaviorRegistry lookups at user-creation time (boot-order
  fragile). `:any` plus a narrow `:kind` scope is the consistent
  trade-off the codebase already uses.

  Prepended to user-supplied caps in `Ezagent.Domain.Identity.Users.create/3`.
  Idempotently re-granted by Feishu `BindingPolicy.apply/2` to handle
  pre-PR-27 users that were created without it.

  ## Phase 9 PR-3 (SPEC v3 §4.5) — workspace dimension

  The default cap is scoped to the user's own workspace via
  `workspace_uri:`. Cross-workspace chat requires an explicit
  cross-workspace cap (PR-4). Callers pass the workspace URI
  derived from the user's URI (`Ezagent.URI.entity_workspace_uri/1`).
  """
  @spec default_caps(URI.t()) :: [Ezagent.Capability.t()]
  def default_caps(%URI{scheme: "workspace"} = workspace_uri) do
    [
      %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        instance: :any,
        workspace_uri: workspace_uri,
        granted_by: @system_bootstrap_uri,
        granted_at: @admin_granted_at
      }
    ]
  end

  # --- Ezagent.Kind callbacks -----------------------------------------------
  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :user

  # Phase 3d: User Kinds carry Identity Behavior so caps live in slice
  # state (Decision #24). admin_caps/0 above still provides the
  # bootstrap value — chat plugin passes it as initial_caps when
  # spawning admin User.
  #
  # PR #126 (2026-05-19): User Kinds also carry the ApiKeys Behavior
  # so per-user secret storage (DeepSeek, OpenAI, etc.) coexists with
  # cap state on the same Kind. Both slices serialize through the
  # existing `{:snapshot, :on_change}` persistence.
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Identity, Ezagent.Behavior.ApiKeys]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): User Kinds live under the identity
  # domain's UserSupervisor. `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainIdentity.Application.UserSupervisor
end
