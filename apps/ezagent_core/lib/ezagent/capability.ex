defmodule Ezagent.Capability do
  @moduledoc """
  Capability — a Push-based authorization grant carried in `ctx.caps`.

  A capability matches an `Ezagent.Invocation` when all FIVE fields
  match (with `:any` acting as wildcard for `kind` / `behavior` /
  `action` / `instance` / `workspace_uri`):

  - `kind` — Kind type atom (e.g. `:py_agent`); `:any` matches all
  - `behavior` — Behavior module ref (e.g. `Ezagent.ActionSet.PyAgent`);
    `:any` matches all
  - `action` — the action atom (e.g. `:send`, `:add_member`); `:any`
    matches all. NEW per SPEC 2026-05-27 (capability-action-axis).
    Default `:any` (defstruct). NOT in `@enforce_keys` — existing
    admin grant form (`entity_caps_live.ex` `build_cap/2`)
    constructs caps without passing `:action`; the runtime grant-
    boundary check (`Identity.holds_admin_caps?/1`) is the structural
    enforcement that rejects `:any`-action grants from non-privileged
    callers.
  - `instance` — target URI, scope tuple, or `:any`
  - `workspace_uri` — Phase 9 PR-3 (SPEC v3 §4): the
    `workspace://<workspace>` URI the cap is scoped to. `:any` is
    the structural cross-workspace marker reserved for the
    bootstrap admin cap + explicit cross-workspace grants. Required
    on construction — `@enforce_keys` rejects pre-PR-3 4-field caps
    at compile time so no silent drops can slip past.

  `revoke/2` is admin-protected per Decision #81: `entity://user/system/admin`'s
  all-caps capability (`%Ezagent.Capability{kind: :any, behavior: :any,
  action: :any, instance: :any, workspace_uri: :any, ...}` granted_by
  `system://bootstrap/default`) is a structural invariant and cannot
  be removed. The check lives here at the data-layer boundary so any
  caller path is forced through one chokepoint.
  """

  @enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]
  # SPEC 2026-05-27 (capability-action-axis) §3.1: `:action` is NEW with
  # defstruct default `:any` (wildcard). NOT in @enforce_keys — see
  # moduledoc.
  defstruct kind: nil,
            behavior: nil,
            action: :any,
            instance: nil,
            workspace_uri: nil,
            granted_by: nil,
            granted_at: nil,
            signature: nil,
            key_id: nil

  @type scope_tuple ::
          {:within_session, URI.t()}
          | {:within_workspace, URI.t()}
          | {:spawned_by, URI.t()}

  @type t :: %__MODULE__{
          kind: atom() | :any,
          behavior: module() | :any,
          action: atom() | :any,
          instance: URI.t() | :any | scope_tuple(),
          workspace_uri: URI.t() | :any,
          granted_by: URI.t() | :plugin_declared,
          granted_at: DateTime.t() | :compile_time,
          signature: binary() | nil,
          key_id: String.t() | nil
        }

  # Sentinel values for declarative caps (e.g. those returned by
  # `Behavior.required_caps/0`). Recorded here so callers using
  # `function/1` patterns can match them as well.
  @plugin_declared_granter :plugin_declared
  @compile_time_granted_at :compile_time

  # #154 genesis collapse — stable granted_at for the admin self-granted genesis
  # cap (provenance only; `admin_invariant?/1` matches on granted_by, not this).
  @genesis_granted_at ~U[2026-01-01 00:00:00Z]

  alias Ezagent.Capability.{Match, Normalize, Scope}

  @doc """
  Action atom for cap declarations: `:any` action axis.

  Provided so a Behavior author writing `required_caps/0` can declare a
  catch-all "any action on this Behavior" cap (used by
  `:ezagent_plugin_check` check 11d as the wildcard-action escape hatch
  for orchestrator-style Behaviors).
  """
  @spec any_action() :: :any
  def any_action, do: :any

  @doc """
  Construct a declarative capability for use in `Behavior.required_caps/0`
  or for issuing a grant.

  The 3-arity form fills `instance` and `workspace_uri` with `:any` (matches
  any target / any workspace) — the common shape for `required_caps/0`
  declarations. The 5-arity form takes explicit `instance` and
  `workspace_uri` for grant sites that need narrowing.

  `granted_by` defaults to `:plugin_declared` (sentinel meaning "this is a
  declarative requirement, not an issued grant"); `granted_at` defaults to
  `:compile_time`. At grant time (`Identity.grant_cap/3` etc.), callers
  override these fields to the actual granter URI + timestamp.

  ## Examples

      # required_caps/0 declaration
      Capability.cap(:session, Ezagent.ActionSet.Session, :send)
      # => %Capability{kind: :session, behavior: Ezagent.ActionSet.Session, action: removed,
      #                instance: :any, workspace_uri: :any,
      #                granted_by: :plugin_declared,
      #                granted_at: :compile_time}

      # narrow grant
      Capability.cap(:session, Chat, :send, session_uri, workspace_uri)

  ## Action axis

  Per SPEC 2026-05-27 (capability-action-axis), the `action` argument
  is now STORED in the struct's `:action` field (`atom() | :any`).
  The 3-arity form passes `instance: :any` + `workspace_uri: :any`
  (the common shape for `required_caps/0`); the 5-arity form takes
  explicit instance and workspace_uri for grant sites that need
  narrowing. The action atom equals the key in the `required_caps/0`
  map by convention — plugin-check 11 enforces parity at compile
  time.
  """
  @spec cap(atom() | :any, module() | :any, atom() | :any) :: t()
  def cap(kind, behavior, action)
      when is_atom(kind) and is_atom(behavior) and is_atom(action) do
    %__MODULE__{
      kind: kind,
      behavior: behavior,
      action: action,
      instance: :any,
      workspace_uri: :any,
      granted_by: @plugin_declared_granter,
      granted_at: @compile_time_granted_at
    }
  end

  @spec cap(
          atom() | :any,
          module() | :any,
          atom() | :any,
          URI.t() | :any | scope_tuple(),
          URI.t() | :any
        ) :: t()
  def cap(kind, behavior, action, instance, workspace_uri)
      when is_atom(kind) and is_atom(behavior) and is_atom(action) do
    %__MODULE__{
      kind: kind,
      behavior: behavior,
      action: action,
      instance: instance,
      workspace_uri: workspace_uri,
      granted_by: @plugin_declared_granter,
      granted_at: @compile_time_granted_at
    }
  end

  @doc "Does this capability authorize the given needed-cap shape?"
  @spec matches?(t(), %{
          required(:kind) => atom(),
          required(:behavior) => module(),
          required(:action) => atom(),
          required(:instance) => URI.t(),
          required(:workspace_uri) => URI.t() | :any
        }) :: boolean()
  def matches?(%__MODULE__{} = cap, needed), do: Match.matches?(cap, needed)

  @doc """
  Read the action axis of a cap, defaulting to `:any` for caps loaded
  from pre-action-axis snapshots (missing `:action` key).

  SPEC 2026-05-27 capability-action-axis §3.3.1 — single chokepoint for
  missing-key tolerance. All cap readers (matcher, serializer, LV
  display) route through this helper so the rule is encoded ONCE.

  Returns `:any` for raw maps without `:action`, the field value
  otherwise. `Map.get/3` on a struct map is equivalent to direct field
  access when the key is present, and returns the default when it's
  not — covering both fresh structs and pre-SPEC binary_to_term'd
  snapshots in one expression.
  """
  @spec action_of(t() | map()) :: atom()
  def action_of(cap), do: Match.action_of(cap)

  @doc """
  Remove a capability from a MapSet of caps.

  Refuses to remove the admin all-caps invariant — the admin entity
  `entity://system/user/admin`'s quadruple-`:any` capability self-granted
  (granted_by the admin URI) is the genesis trust root (Decision #81 + SPEC v3
  §4.4; #154 genesis collapse 2026-06-20 re-rooted it from the eliminated
  `system://bootstrap` principal to the admin entity itself) and removing it
  would break all authority.

  ## Identity-tuple match (codex review HIGH-1, 2026-05-26)

  The previous implementation used `MapSet.delete/2` directly, which
  is FULL-STRUCT equality. Provenance metadata (`granted_by`,
  `granted_at`) differs between the held cap (timestamped at original
  grant time) and a freshly-normalized revoke argument (timestamped
  at revoke-call time): the cap-to-delete and the cap-in-slice are
  structurally distinct, MapSet.delete silently no-ops, and the
  function returns `{:ok, caps}` while the cap remains in force.

  Fix: match on the IDENTITY tuple (kind + behavior + instance +
  workspace_uri) via `identity_key/1`, ignoring provenance
  metadata. The revoke removes every cap that matches the identity
  tuple (in practice exactly one — `:grant_cap` only adds one row
  per identity tuple; a duplicate-with-different-timestamp is a
  test-only edge case).

  Returns `{:ok, new_caps}` on success (whether or not a row was
  actually removed — idempotent), `{:error, :cannot_revoke_admin}`
  if the input cap is the admin all-caps invariant.
  """
  @spec revoke(MapSet.t(t()), t()) :: {:ok, MapSet.t(t())} | {:error, :cannot_revoke_admin}
  def revoke(%MapSet{} = caps, %__MODULE__{} = cap) do
    if admin_invariant?(cap) do
      {:error, :cannot_revoke_admin}
    else
      target_key = identity_key(cap)

      new_caps =
        caps
        |> Enum.reject(fn held -> identity_key(held) == target_key end)
        |> MapSet.new()

      {:ok, new_caps}
    end
  end

  @doc """
  The GENESIS all-caps capability — the irreducible trust root.

  #154 genesis collapse (2026-06-20): the root authority is the admin ENTITY
  `entity://system/user/admin` self-granting its quadruple-`:any` wildcard
  (`granted_by == the admin URI`), replacing the former abstract
  `system://bootstrap` principal. Every real cap now traces to a real entity —
  including the genesis, which roots in itself. `admin_invariant?/1` recognizes
  exactly this shape (it is the revoke-protected admin cap); `User.initial_caps_for_spawn/1`
  mints exactly this for the admin entity. Co-located here so recognizer + minter
  never drift.
  """
  @spec admin_genesis_cap() :: t()
  def admin_genesis_cap do
    %__MODULE__{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: admin_genesis_granter(),
      granted_at: @genesis_granted_at
    }
  end

  # The genesis self-granter = the admin entity URI (core-constructible via
  # `Ezagent.URI.user/2`, no dep on the identity app). #154: a real entity, not
  # the abstract `system://bootstrap` principal.
  defp admin_genesis_granter, do: Ezagent.URI.user(:system, :admin)

  @doc false
  # SPEC v3 §4.4 — admin's structural invariant is the FIVE-axis wildcard.
  # #154 genesis collapse: identified by `granted_by == the admin entity`
  # (self-granted genesis), NOT the eliminated `system://bootstrap` principal.
  # This is the REVOKE-PROTECTED cap (`revoke/2` refuses to remove it).
  def admin_invariant?(%__MODULE__{
        kind: :any,
        behavior: :any,
        action: :any,
        instance: :any,
        workspace_uri: :any,
        granted_by: granted_by
      }),
      do: same_uri?(granted_by, admin_genesis_granter())

  # codex r4 SPEC option-B: legacy fallback REMOVED. Pre-SPEC admin caps
  # missing `:action` no longer recognized — operators MUST re-grant
  # admin authority via `Identity.grant_cap` (which goes through
  # `normalize!/2` and writes `action: :any` explicitly).
  # Rationale: `Map.delete(cap, :action)` produces a shape structurally
  # indistinguishable from a real legacy snapshot, so the legacy
  # fallback was redundant defense at this layer (matcher-boundary
  # tolerance per SPEC §3.3 still handles legacy at dispatch step 5.5).
  def admin_invariant?(%__MODULE__{}), do: false

  @doc """
  Predicate A (#154 genesis collapse, 2026-06-20) — is this cap's authority
  granted by a REAL ENTITY (not an abstract `system://` principal)?

  The standing runtime guard that no `system://` principal can ever again confer
  authorization. After the genesis collapse, every legitimate authorizing cap
  traces to a real spawned Kind — `entity://` (users/agents), `session://`,
  `workspace://`, etc. — minted either by the grant chokepoint (which validates
  an `entity` granter) or inline at a dispatch site with the actor's own URI as
  `granted_by`. A cap whose `granted_by` is a `system://` URI is, by
  construction, the artifact this program eliminated; it MUST NOT authorize a
  dispatch.

  Dispatch step 5.5 (`Ezagent.Kind.Runtime`) filters BOTH authorizing cap sets
  (inline `ctx.caps` and slice-held caps) through this predicate before the
  `matches?/2` check, so a `system://`-granted cap is inert as an authorizer —
  even if a caller forges one into `ctx.caps`, or a stale pre-collapse snapshot
  carries one. (The `needed` cap's `granted_by` — e.g. the `:plugin_declared`
  sentinel — is never an authorizer and is unaffected; `matches?/2` ignores it.)

  Returns `true` for any non-`system://` `granted_by` (entity/session/workspace
  schemes pass); `false` for a `system://` granter.
  """
  @spec granted_by_entity?(t()) :: boolean()
  # Rejects EXACTLY a `system://` granter (Allen's predicate A: "reject all
  # permissions not granted by an entity" — the `system://` principal is what
  # #154 eliminated). Everything else passes: entity/session/workspace granters,
  # and the `:plugin_declared` atom / `nil` sentinels that `Capability.cap/5`
  # stamps on declared + ad-hoc caps (those are NOT `system://` principals, and
  # rejecting them breaks legitimate `cap/5`-built authorizers, e.g. turn-drive
  # caps). The "granter must be a real `entity://`" rule is enforced at the GRANT
  # chokepoint (`Identity.Grant`); this runtime predicate is the narrower
  # standing backstop that no `system://` principal authorizes a dispatch.
  def granted_by_entity?(%__MODULE__{granted_by: %URI{scheme: "system"}}), do: false
  def granted_by_entity?(%__MODULE__{}), do: true

  # Canonical-string URI equality (tolerant of representation differences from
  # snapshot round-trips). Non-URI granted_by (e.g. the `:plugin_declared`
  # sentinel on needed-caps) → false.
  defp same_uri?(%URI{} = a, %URI{} = b), do: URI.to_string(a) == URI.to_string(b)
  defp same_uri?(_, _), do: false

  @doc """
  Is `cap` a cross-workspace cap (arity-1, structural form)?

  Phase 9 PR-4 (SPEC v3 §5.1) — returns true when the cap's
  `workspace_uri` is `:any`. Retained for back-compat with
  call-sites that don't have a caller URI in hand (e.g. some test
  fixtures and the `to_map/1` serialization sanity check).

  New code should prefer `cross_workspace?/2` which also honors the
  membership-based bypass per SPEC v3 §13.3.
  """
  @spec cross_workspace?(t()) :: boolean()
  def cross_workspace?(%__MODULE__{} = cap), do: Scope.cross_workspace?(cap)

  @doc """
  Is `cap` a cross-workspace cap OR is the caller a member of
  `workspace://system`?

  Phase 9 PR-8 (SPEC v3 §13.3) — Keycloak realm-admin model. ANY
  cap held by a `workspace://system` member is treated as
  cross-workspace by membership (not by explicit `:any` grant on
  the cap itself). Regular users still need a `workspace_uri: :any`
  cap to dispatch across workspaces — only system-workspace
  membership grants the structural bypass.

  Used by `Ezagent.Kind.Runtime` step 5.6 to decide whether to
  override workspace isolation when caller and target differ.
  """
  @spec cross_workspace?(t(), URI.t() | :vm_internal | nil) :: boolean()
  def cross_workspace?(%__MODULE__{} = cap, caller_uri),
    do: Scope.cross_workspace?(cap, caller_uri)

  @doc """
  Caller's HOME workspace IS `workspace://system` (admin's
  structural URI shape: `entity://user/system/<name>`). Pre-existing
  structural admin path used by `cross_workspace?/2` and (SPEC
  2026-05-27-workspace-cap-based-visibility OQ-4 r5) by
  `Ezagent.Identity.AdminAuthority.admin?/2`.

  Returns `false` for non-entity callers or malformed URIs (the
  inner `workspace_of_caller_safe/1` catches the
  `Ezagent.URI.entity_workspace_uri/1` raise).
  """
  @spec home_is_system?(URI.t()) :: boolean()
  def home_is_system?(caller_uri), do: Scope.home_is_system?(caller_uri)

  @doc """
  Caller is listed in `workspace://system`'s `members`. SPEC v2 PR-D
  (Allen 2026-05-24): the "Promote to system" admin action grants
  cross-workspace authority by MEMBERSHIP — a regular user
  (`entity://user/<their-ws>/<name>`) becomes admin-equivalent
  without needing a special URI host.

  SPEC 2026-05-27-workspace-cap-based-visibility OQ-4 (r5 — option b):
  promoted to public so `Ezagent.Identity.AdminAuthority.admin?/2`
  can compose the 4-predicate admin shortcut. Lazy lookup via
  `apply/3` to avoid a compile-time `ezagent_core` →
  `ezagent_domain_workspace` circular dep.
  """
  @spec member_of_system?(URI.t()) :: boolean()
  def member_of_system?(caller_uri), do: Scope.member_of_system?(caller_uri)

  @doc """
  Derive the workspace scope of a target URI.

  SPEC v3 §4.2 / §5.3. Promoted from private in Phase 9 PR-4 so
  `Ezagent.Kind.Runtime` step 5.6 can reuse the same workspace
  derivation that `cap_for_action/3` uses for the `needed` map —
  keeping the two sides in lock-step structurally.

  - `entity://<workspace>/<type>/<name>` →
    `Ezagent.URI.entity_workspace_uri/1` (PR-2 — structural)
  - `session://<workspace>/<template>/<name>` →
    workspace path segment (PR-7 — structural, no registry lookup)
  - `template://<workspace>/<type>/<name>` →
    workspace path segment (PR-7)
  - `resource://<workspace>/<type>/<name>` →
    workspace path segment (PR-7)
  - `workspace://<name>` → the URI itself
  - `system://`, unknown schemes → `:any`
    (cross-cutting; workspace boundary doesn't apply)

  `:any` for a target means "cross-workspace by structural design"
  — step 5.6 should skip the isolation check for these.

  ## PR-7 — WorkspaceRegistry demoted to consistency cache

  Before PR-7, `workspace_of/1` for `session://` consulted
  `Ezagent.WorkspaceRegistry`. After URI unification, the workspace
  is in the URI path — extraction is O(1) string split. The registry
  is retained for back-edge lookups by code that hasn't migrated yet
  (e.g. tooling that holds a session URI and wants to know its
  workspace without re-parsing). Per SPEC v3 §3.6, every registry
  binding MUST equal the workspace segment of the URI it's bound
  for — guarded by `all_per_tenant_uris_have_workspace_test.exs`.
  """
  @spec workspace_of(URI.t()) :: URI.t() | :any
  def workspace_of(%URI{} = uri), do: Scope.workspace_of(uri)

  @doc """
  Serialize a Capability to a JSON-safe map (for `users.caps_json`
  storage per Phase 4-completion Spec 05 Part A).

  Atoms become strings; modules become strings; URIs become strings.
  `workspace_uri` is serialized via `uri_or_any_to_string/1` (SPEC v3
  §4 — `:any` round-trips as `"any"`). Inverse of `from_map/1`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = cap), do: Normalize.to_map(cap)

  @doc """
  Deserialize a Capability from a JSON-decoded map.

  SPEC v3 §4 — pre-PR-3 caps_json rows lack the `workspace_uri`
  key; per the "no back-compat shim" rule (memory
  `feedback_let_it_crash_no_workarounds` + SPEC v3 §8 wipe-and-
  rebuild), the DB is reset on Phase 9 migration. To preserve
  round-trip soundness on test fixtures however, a missing key
  defaults to `:any` (the cap won't be authored without the field
  in any post-PR-3 code path).
  """
  @spec from_map(map()) :: t()
  def from_map(%{} = m), do: Normalize.from_map(m)

  @doc """
  Coerce any of the three accepted grant-cap input shapes to a
  `%Capability{}` struct, stamping `granted_by` with the granter URI
  and `granted_at` with the current time when those fields aren't
  present on the input.

  Accepted shapes (Bug 2 fix, Allen 2026-05-26):

  - `%Ezagent.Capability{}` — passed through unchanged (already canonical).
  - **Atom-keyed** map (`%{kind: _, behavior: _, instance: _,
    workspace_uri: _}` — produced by Elixir callers like
    `Ezagent.Identity.grant_cap/3`) — built into a struct with
    `Map.get` defaults of `:any` for missing field axes plus
    granter-stamped metadata.
  - **String-keyed** map (`%{"kind" => _, "behavior" => _, ...}` —
    produced by the CLI's `Optimus :map` arg type, which is
    `Jason.decode/1` output) — routed through `from_map/1` then
    `granted_by` overridden with the supplied granter URI (since
    CLI input never carries a `"granted_by"` field — the caller's
    identity comes from the dispatch ctx, not the JSON payload).

  Anything else raises `ArgumentError` per
  `feedback_let_it_crash_no_workarounds` — no silent fallback,
  no defensive shims.

  This is the SINGLE chokepoint for cap-shape normalization on the
  grant path; `IdentityAdmin.invoke(:grant_cap, ...)` calls it
  before mutating the slice so a CLI-supplied JSON map and an
  Elixir-supplied struct produce the exact same in-slice
  representation. Without this, JSON input lands in the MapSet as
  a bare string-keyed map, and downstream `Capability.matches?/2`
  (which pattern-matches `%__MODULE__{}`) silently denies every
  invocation the cap was supposed to authorize.
  """
  @spec normalize!(t() | map(), URI.t() | String.t()) :: t()
  def normalize!(cap_or_map, granter), do: Normalize.normalize!(cap_or_map, granter)

  @doc """
  Identity-tuple key of a capability — `{kind, behavior, action, instance,
  workspace_uri}`.

  Two caps with the same identity tuple are LOGICALLY the same cap,
  even if their `granted_by` / `granted_at` provenance metadata
  differ. Used by `IdentityAdmin.invoke(:revoke_cap, ...)` to match
  a CLI-supplied revoke target against the slice cap (which carries
  the original grant timestamp) — without this, `MapSet.delete/2`'s
  full-struct equality silently fails the revoke (codex review HIGH-1,
  2026-05-26).

  SPEC 2026-05-27 capability-action-axis (codex impl PR review HIGH-1
  follow-up): the identity tuple now INCLUDES action via
  `action_of/1`. Pre-SPEC the tuple was 4-axis; collapsing per-action
  grants/revokes onto the same key silently merged authorities on
  the same Behavior. Post-SPEC, `:read` and `:write` on the same
  Behavior+instance+workspace are DISTINCT identities — grant/revoke
  must treat them as such.

  Note: `instance` and `workspace_uri` are `%URI{}` structs whose
  raw struct comparison can be brittle (`authority` field divergence
  between `URI.parse/1` and `URI.new!/1`). For canonical equality
  we'd compare `URI.to_string/1`; the tuple here is a CHEAP first-cut
  used as a MapSet/group key — callers performing the actual logical
  match should use `Capability.matches?/2` (which handles the URI
  canonicalization). For revoke-via-MapSet.delete the producer of
  both halves (`normalize!/2` plus `from_map/1` on snapshot reload)
  routes URIs through the same `URI.parse/1`, so tuple equality
  holds in practice; pinned by `identity_grant_cap_shape_test.exs`.
  """
  @spec identity_key(t()) ::
          {atom() | :any, module() | :any, atom() | :any, URI.t() | :any | scope_tuple(),
           URI.t() | :any}
  def identity_key(%__MODULE__{} = cap),
    do: Match.identity_key(cap)

  @doc """
  Compute the `needed` cap shape for a given (Kind module, action,
  target URI) tuple — for dispatch step 5.5 to feed into `matches?/2`.

  Phase 3d (P3-D6 hard flip + #P1-8): the target URI is required so
  we can extract the `instance` part (e.g. `session://default/team-alpha/main` from
  `session://default/team-alpha/main?action=session.send`). `behavior` is looked up via
  `BehaviorRegistry.lookup(kind_module, action)` — same lookup
  `Kind.Runtime` does for invoke routing.

  ## Workspace derivation (Phase 9 PR-3 / SPEC v3 §4.2)

  `workspace_uri` is derived from the target URI:

  - `entity://<workspace>/<type>/<name>` — `Ezagent.URI.entity_workspace_uri/1`
  - `session://<workspace>/<template>/<name>` — `Ezagent.WorkspaceRegistry.lookup/1`
    (raises if unbound — invariant 4)
  - `workspace://<name>` — the URI itself IS the workspace
  - `system://`, `template://`, `resource://` — `:any`
    (cross-cutting schemes; workspace boundary doesn't apply)

  Returns the 4-field map `Capability.matches?/2` expects:
  `%{kind: atom, behavior: module, instance: %URI{}, workspace_uri: %URI{} | :any}`.
  """
  @spec cap_for_action(module(), atom(), URI.t()) :: %{
          kind: atom(),
          behavior: module(),
          action: atom(),
          instance: URI.t(),
          workspace_uri: URI.t() | :any
        }
  def cap_for_action(kind_module, action, %URI{} = target_uri),
    do: Match.cap_for_action(kind_module, action, target_uri)
end

# Remediation SPEC 2026-05-30 C-C: make %Capability{} JSON-encodable so the
# `{:emit, :cap_granted | :cap_revoked, %{cap: %Capability{}}}` effect actually
# persists to EventLog. Pre-fix the emit raised `Jason.Encoder not implemented
# for Ezagent.Capability` and Kind.Runtime swallowed it ("continuing") — every
# cap-grant/revoke audit event was silently dropped (337+ raises in a single
# test run). We implement an EXPLICIT encoder (not a blanket EventLog
# normalization layer, which would mask the NEXT non-encodable struct): URI
# fields stringify, scope tuples become lists, atoms/DateTime pass through.
defimpl Jason.Encoder, for: Ezagent.Capability do
  def encode(%Ezagent.Capability{} = cap, opts) do
    Jason.Encode.map(
      %{
        kind: cap.kind,
        behavior: json_safe(cap.behavior),
        action: cap.action,
        instance: json_safe(cap.instance),
        workspace_uri: json_safe(cap.workspace_uri),
        granted_by: json_safe(cap.granted_by),
        granted_at: cap.granted_at,
        signature: encode_signature(cap.signature),
        key_id: cap.key_id
      },
      opts
    )
  end

  # URI struct → canonical string; scope tuple → list; everything else
  # (atoms incl. `:any`, module atoms, strings, DateTime) is Jason-native.
  defp json_safe(%URI{} = u), do: URI.to_string(u)
  defp json_safe(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.map(&json_safe/1)
  defp json_safe(v), do: v

  defp encode_signature(nil), do: nil

  defp encode_signature(signature) when is_binary(signature),
    do: Base.url_encode64(signature, padding: false)
end
