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
  Bootstrap caps the User Kind for `uri` should be spawned with.

  Single chokepoint for the `entity://user/*` SpawnRegistry handler
  (registered both in `EzagentDomainIdentity.Application` and — for
  stacks loading chat — overwritten in
  `EzagentDomainChat.Application`). Both fns delegate here so the
  policy stays in ONE place.

  Three cases:

  1. **Admin URI** (`entity://user/system/admin`) — bootstrap caps
     from the closed catalog at `Ezagent.SystemPrincipal.caps("system://bootstrap")`
     (the `[:any, :any, :any, :any]` wildcard structural invariant
     plus catalog rows). Same value across boots; admin has no
     `users.caps_json` row at the time of the very first boot before
     `ensure_admin_user/0` provisions it.

  2. **Non-admin user with a `users.caps_json` row** — caps_json
     contents (which include `User.default_caps(workspace)` ++ any
     caller-supplied caps from `mix ezagent.user.create --caps ...`
     or `Behavior.WorkspaceUserAdmin.create_user`). This is the fix
     for the wildcard-cap-fix regression: pre-fix the spawn fn
     defaulted to `MapSet.new()` so wildcard caps written to
     caps_json never reached the slice — snapshot then froze that
     empty state, denying dispatch step 5.5 forever.

  3. **Non-admin user with NO caps_json row** — empty MapSet. This
     covers test fixtures that demand-spawn a URI without a backing
     DB row, and the brief boot-order window before
     `Ezagent.Users.get_by_uri/1` is callable. The User Kind will
     have ONLY the structural self-Identity cap (auto-added by
     `Behavior.Identity.init_slice/1` via `add_owner_identity_cap/2`),
     which is intentional — a principal with no DB row should not
     gain dispatch authority via spawn alone.

  Returns `MapSet.t(Ezagent.Capability.t())`.

  ## Boot-order tolerance

  Wrapped in `try/rescue` so an early-boot call (before `Ezagent.Users`
  is callable) degrades to `MapSet.new()` rather than crashing the
  spawn — the post_init reconcile path in
  `Ezagent.Behavior.Identity` repairs the slice on the next spawn
  once the DB is available (and `mix ezagent.user.create` runs
  outside boot anyway).
  """
  @spec initial_caps_for_spawn(URI.t()) :: MapSet.t(Ezagent.Capability.t())
  def initial_caps_for_spawn(%URI{} = uri) do
    if uri == @admin_uri do
      Ezagent.SystemPrincipal.caps("system://bootstrap")
    else
      hydrate_from_caps_json(uri)
    end
  end

  defp hydrate_from_caps_json(%URI{} = uri) do
    if Code.ensure_loaded?(Ezagent.Users) and
         function_exported?(Ezagent.Users, :get_by_uri, 1) do
      try do
        case Ezagent.Users.get_by_uri(uri) do
          %{caps: caps_list} when is_list(caps_list) -> MapSet.new(caps_list)
          _ -> MapSet.new()
        end
      rescue
        _ -> MapSet.new()
      catch
        _, _ -> MapSet.new()
      end
    else
      MapSet.new()
    end
  end

  # SPEC caps-cleanup-v1 §4 / §4.6 (PR-CC-1): `admin_caps/0` DELETED.
  # The ambient all-caps escape hatch is replaced by the closed
  # `Ezagent.SystemPrincipal.Catalog` allowlist of 14 system
  # principals + their permitted caps. Admin's bootstrap caps now
  # come from `Ezagent.SystemPrincipal.caps("system://bootstrap")`,
  # which mints the same structural wildcard cap (granted by
  # `system://bootstrap/default`) so the `Capability.revoke/2`
  # admin-invariant + admin-bootstrap behavior are preserved.
  #
  # Per `feedback_let_it_crash_no_workarounds`: there is no shim
  # here — any remaining caller fails at compile time, and the
  # invariant test `no_admin_caps_fallback_test.exs` is the gate
  # against re-introduction.
  #
  # `@system_bootstrap_uri` + `@admin_granted_at` constants kept
  # because `default_caps/1` (below) still uses them as the cap's
  # `granted_by` / `granted_at` attribution.

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
      Ezagent.Behavior.Identity,
      Ezagent.Behavior.UserCredentials,
      Ezagent.Behavior.UserTokens
    ]

  @impl Ezagent.Kind
  def persistence, do: {:snapshot, :on_change}

  # V1 prevention (Allen 2026-05-21): User Kinds live under the identity
  # domain's UserSupervisor. `Ezagent.Kind.spawn/2` reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainIdentity.Application.UserSupervisor
end
