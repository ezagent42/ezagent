# SPEC — Capabilities as Data Ownership (framework invariant)

**Status:** rev 3 (DRAFT) · 2026-05-25
**Tier:** `apps/ezagent_core/` (framework-level invariant + one new `Ezagent.Behavior` callback)
**Trigger:** Allen 2026-05-24 (Feishu) — "本质上每个 caps 都是对一类数据的 CRUD 操作的授权，bind 的操作是对什么数据进行的授权，caps 就应该由那个数据（或其创建者）赋权"
**Predecessors:**
- SKILL P15 (CapBAC shape; `module()` not atoms; scope shapes narrow)
- SKILL P11 / P1 (plugin isolation north star; receiver Kind on existing scheme)
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4 (`Ezagent.CapabilityRegistry` — cap-subject single-entry registry)
- `apps/ezagent_core/lib/ezagent/capability.ex:28-43` (`%Capability{}` — six fields: `kind, behavior, instance, workspace_uri, granted_by, granted_at`; **no `action` field**)
- `apps/ezagent_core/lib/ezagent/capability_registry.ex` (`register/3`, `register_default_grant/2`, `needed_for/3`, `default_grants_for/2`)
- `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` moduledoc §"Tightened admin predicate" + §"Threat model" — PR #303 HIGH-3 fix
**Sequencing:** Lands BEFORE `ExternalMirror r3`; r3's `Behavior.ExternalMirror`'s `data_owner/1` returns `session_owner`, and the default grant "session owner gets `Behavior.ExternalMirror` cap on their own session at session creation" is structurally derived from this SPEC — r3 cannot merge until `data_owner/1` is in core.
**Companion:** `2026-05-24-caps-data-ownership-v2.zh_cn.md` (Chinese mirror; per memory `feedback_bilingual_docs_convention`).

---

## 0. r2 revision notes (what changed vs r1)

r1 was returned needs-attention by codex (2 CRITICAL + 3 HIGH). r2 fixes all five structurally:

1. **CRITICAL-1 fixed.** Caps are **Behavior-scoped, NOT action-scoped**. `%Capability{}` has no `action` field (`apps/ezagent_core/lib/ezagent/capability.ex:28-29`); holding a cap on `Behavior.X` grants the holder ALL actions of X. The data class a cap protects is therefore **what the Behavior is for**, not an individual action. r1's 3-tuple `(Kind, Behavior, action)` audit table is wrong; r2 uses 2-tuple `(Kind, Behavior)` with a reference-only "actions exposed by this Behavior" column derived from each Behavior's real `cap_subjects/0`.
2. **CRITICAL-2 fixed.** `data_owner/1` signature widened: accepts the same `instance` shapes the stored cap can have (`URI.t() | :any | scope_tuple()`), returns `URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}`. Each shape's grant semantics is documented in §3.1.
3. **HIGH-1 fixed.** PR sequence reordered so each PR's acceptance test depends ONLY on code introduced in itself or a prior PR. PR-OWN-1 (framework callback + audit, tests use the in-test `TestBehavior` and a synthetic `TestEntityKind`, no real Behavior touched). PR-OWN-2 (Session migration — adds `Session.owner/1` lookup + `data_owner/1` on `Behavior.Chat`). PR-OWN-3+ (other Behaviors fan out only after PR-OWN-2).
4. **HIGH-2 fixed.** Audit table §6 re-built from real source. Per-Behavior `cap_subjects/0` was read from each file; actions confirmed (e.g. `Behavior.Echo` exposes `:say, :receive` — r1 said `:echo`; `Behavior.Workspace` exposes 9 actions — r1 listed 6; `Behavior.CurlAgent` exposes `:receive, :reset_conversation, :configure` — r1 said `:request`; `FeishuOutbound` exposes `:notify_external` — r1 said `:send_to_feishu`).
5. **HIGH-3 fixed.** OQ-OWN-2 (consent-via-target-cap) is dropped — dispatch reads `ctx.caps` = caller's caps, never target's; no mid-dispatch mechanism reads target caps. If target-side consent is ever needed, it requires a separate consent-ledger model; deferred to a future SPEC and noted in §10 (non-goals).

## 0a. r3 revision notes (what changed vs r2)

r2 was returned needs-attention by codex (1 CRITICAL + 3 HIGH). r3 fixes all four structurally:

1. **CRITICAL fixed (wildcard caps).** r2's §5.2 step 1 called `needed_cap.behavior.data_owner(needed_cap.instance)` unconditionally. But `%Capability{behavior: :any}` is a real shape (e.g. `User.default_caps/1` mints `{kind: :session, behavior: :any, instance: :any, workspace_uri: user_ws}`); `:any` is not a module so the call would crash. r3 §5.2 adds an explicit **pre-check** that fails closed on wildcard `behavior: :any` and `kind: :any` shapes — only the bootstrap admin can grant them. Documented as new rule §5.2(0).
2. **HIGH fixed (workspace_of on non-URI).** r2's §5.2 step 4 (now step 5) called `Capability.workspace_of(needed_cap.instance)` for the `owner == :any` branch — but `instance` may be `:any` or a scope tuple, and `workspace_of/1` is spec'd for `%URI{}` only (`apps/ezagent_core/lib/ezagent/capability.ex:319-345`). r3 uses `needed_cap.workspace_uri` for the workspace-admin authorization (the cap struct already carries the workspace dimension after Phase 9 PR-3); for `workspace_uri: :any` or malformed scope tuples, the rule fails closed.
3. **HIGH fixed (default-grant helper loses grantee).** r2's `default_grants_from_data_owner/2` returned `[Capability.t()]` — but `%Capability{}` carries `granted_by`, not a grantee field. Caller couldn't tell whose Identity slice to write the cap into. r3 changes the helper contract to return `[{grantee_uri :: URI.t(), Capability.t()}]` so the spawn path knows where to persist each cap. §4.2 acceptance now requires the test to assert the cap is persisted on the owner's Identity slice after spawn.
4. **HIGH fixed (FeishuOutbound module name).** r2's audit row #22 named `Ezagent.PluginFeishu.Behavior.FeishuOutbound`. Real module is `EzagentPluginFeishu.Behavior.FeishuOutbound` (`apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_outbound.ex:1`). r3 fixes the audit row in both en + zh_cn, and adds an explicit PR-OWN-FINAL acceptance: the invariant test cross-references `CapabilityRegistry` entries against the documented Behavior rows after plugins boot, so a future mis-namespaced row in this SPEC fails CI.

---

## 1. Problem statement

Today every capability in ezagent is a `%Ezagent.Capability{kind, behavior, instance, workspace_uri, granted_by, granted_at}` struct (`apps/ezagent_core/lib/ezagent/capability.ex:28-43`). `Capability.matches?/2` pattern-matches the held cap against a needed cap shape on those four matching fields. `Ezagent.CapabilityRegistry` (PR #264) collects cap **subjects** (`{kind, action, behavior, description, dispatchable?}`) so the system can enumerate "what caps exist."

What is **NOT** collected anywhere is the answer to the question: **for a given cap, who is allowed to grant it in the first place?** The codebase has an implicit pattern — a User gets `default_caps/1` on session-class data inside their own workspace at user-creation time, a routing-rule mutation cap on `workspace://X` is implicitly held by whoever holds an admin cap, a notifications-admin cap is implicitly anything that satisfies a hand-written predicate. But:

- There is no framework-level rule saying "cap C on data D may only be granted by the owner of D."
- There is no callback on `Behavior` that lets a Behavior author say "I gate data class D; D's owner is `f(instance_uri)`."
- `Behavior.Identity.grant_cap` exists (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:44`) but the caller is not structurally checked against "are you the owner of the data this cap is about" — only against "do you hold an admin cap on the target principal."
- Plugin authors writing a new Behavior have to *invent* the trust model for their cap subjects every time. The result is bug-prone predicates, scattered across modules.

### Concrete failures this implicit model has already produced

1. **PR #303 (NotificationSubscriptions) HIGH-3 — round-1 admin predicate matched any `:any` cap, not just notifications-admin.**
   In the round-1 implementation, the predicate determining "is this caller allowed to unsubscribe someone else from notifications" was effectively `has_any_cross_workspace_cap?(caller)`. A user holding a *narrow* cross-workspace cap on, say, `Behavior.Chat` would silently satisfy the predicate and become able to unsubscribe any notifications subscriber. Codex round-2 caught it; the fix tightened the predicate to require `behavior == Ezagent.Behavior.Notifications AND workspace_uri == :any` (see `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex:55-61`). **Root cause:** the predicate had no structural anchor — it could not say "the data class here is `notifications-stream-for-user-X`, and only the owner of that data class (User X) or a delegate authorized BY User X may grant the admin-grade unsubscribe cap." With no `data_owner/1` callback, the predicate fell back to a free-form cap pattern that happened to be too wide.

2. **`User.default_caps/1` documents `:any` as a circular-dep workaround.**
   `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:104-116` grants the new user a cap of shape `{kind: :session, behavior: :any, instance: :any, workspace_uri: user_ws}`. The `behavior: :any` is documented (file lines 85-92) as a circular-dep workaround (identity domain cannot reference `Ezagent.Behavior.Chat`). This means every new user gets a *workspace-wide, all-Behavior* session-class cap because there is no way to express "the actual data this cap is about is the user's OWN to-be-spawned sessions." Without `data_owner/1`, the grant scope is wider than the data ownership justifies.

3. **`Behavior.Workspace`'s implicit grantor question.**
   Today, the cap to act as workspace admin (any of the 9 actions in `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:60-73`) is grantable by anyone already holding `Behavior.Workspace` cap on that workspace. But who is the workspace's data owner? Code says "whoever holds admin cap." The workspace itself has no recorded `created_by` / `owner_uri`. If two admin caps were minted with different `granted_by` chains, both can grant; nobody can tell which one is structurally legitimate. Multi-admin federation later will need to resolve this; the current code defers it implicitly.

4. **Routing rules on `system://routing/default` have no owner.**
   `Ezagent.Behavior.Routing` is registered on the System Kind (`apps/ezagent_core/lib/ezagent_core/application.ex:149-152`) — but `system://routing/default` has no `created_by` URI. Cap is held by admin via the catch-all `instance: :any` shape. There is no answer to "who can grant the global routing-admin cap to a new operator?" beyond "admin can." That works for v1 (single admin) but is brittle once a second admin appears.

### Why this matters for ezagent's plugin-isolation north star (SKILL P1)

The single rule that drives every other decision is "plugin authors stay out of core." When a plugin author writes a new Behavior with new cap subjects, they currently have to read 4–5 deep docs (CapabilityRegistry SPEC, scope tuples Decision Log entry, default_grants prose in ARCHITECTURE §7.3, the existing predicates scattered across plugin code) and *invent* a trust model. The PR #303 HIGH-3 finding shows even reviewers miss the gaps.

If the framework instead asks the plugin author **one** question — "for the data your Behavior gates, return the URI of its owner" — then:

- Default grants derive structurally (owner gets cap on own data at creation).
- The grant-cap entry point can enforce "caller must own the data or hold a delegation chain back to the owner."
- The admin predicate question dissolves: there's no "admin-grade predicate" to write — there's just "I own this data, so I can grant" + "I was granted the delegation, so I can grant on the owner's behalf."

The principle in one sentence: **a capability is authorization on a class of data; the data's owner (or a creator-acting-for-the-owner) is the only legitimate grantor.**

---

## 2. Mental model

Four nouns, defined precisely so the rest of the SPEC has unambiguous referents. **Important framing**: ezagent's actual `%Capability{}` struct has no `action` field — a cap binds `{kind, behavior, instance, workspace_uri}` and grants the holder ALL actions exposed by that Behavior. The unit of data ownership is therefore the **Behavior**, not the action.

1. **Cap subject (storage form)** = the **three-tuple `{kind, behavior, instance_or_:any}`** that the cap struct stores. Actions are exposed via `Behavior.cap_subjects/0` for catalog / docs / `mix ezagent.caps.list` purposes, but they are NOT in the cap struct and NOT a unit of grant. Holding `%Capability{kind: :session, behavior: Behavior.Chat, instance: S, workspace_uri: W}` authorizes ALL of `Behavior.Chat`'s actions (`:send`, `:receive`, `:join`, `:leave`, `:set_working_copy`) on S. If finer-grained gates are needed, the right structural answer is **declare two Behaviors** (e.g. `Behavior.NotificationsReader` + `Behavior.NotificationsWriter`) — not extend the cap struct (see OQ-OWN-6).

2. **Data owner** = the URI (or sentinel `:any` / `:no_owner`) that has unique grant authority for the data class a Behavior gates. For a per-tenant Behavior, the data owner is a function of the target instance URI:
   - The owner of `entity://user/team-alpha/alice`'s identity data is the user themself (`entity://user/team-alpha/alice`).
   - The owner of `session://default/team-alpha/standup`'s chat data is the session's creator (recorded as a session slice field; see §3.4 for the lookup rule).
   - The owner of `workspace://team-alpha`'s routing data is "any workspace admin" (cap-class — the workspace itself is multi-admin).
   - The owner of `system://routing/default` is "system admin only" (`:no_owner` — no per-instance owner; only bootstrap-system can grant).

3. **Default grant** = the bootstrap rule encoding "the data owner of any newly-created instance D in Behavior B automatically gets cap `{kind, B, D, workspace_of(D)}` at instance-creation time." Today implemented per-Kind in scattered places (`User.default_caps/1`; Session and Template Class spawning paths sometimes grant, sometimes don't). The SPEC formalizes the rule: **for every Behavior B registered against Kind K, and every newly-spawned instance D of K, the framework grants cap `(K.type_name(), B, D, workspace_of(D))` to the URI returned by `B.data_owner(D)` — provided that return is a concrete `URI.t()`.** Behavior authors do not write a `default_grant_fn` — it is derived from `data_owner/1`.

4. **Delegated grant** = "the data owner explicitly granted the cap to another entity via a recorded grant action." Implemented today as `Behavior.Identity.invoke(:grant_cap, ...)` mutating the target principal's `:identity` slice. The SPEC formalizes the precondition: **the caller of `grant_cap` MUST be (a) the data owner of the cap being granted, OR (b) hold a recorded delegation cap previously granted by the data owner (or a delegation chain ending at the owner).**

Two boundary cases that the framework has to name explicitly so plugin authors don't reinvent them:

- **Workspace-scoped data** (e.g. workspace-management actions, workspace-scoped routing rules): there is no single owner — the workspace is multi-admin by design. Encoded as `data_owner/1` returning `:any`, meaning "any workspace admin grants." The admin status is itself a cap on the workspace (the `Behavior.Workspace` cap), gated by membership.
- **System-scoped data** (e.g. URI scheme registry, scheduler config, bootstrap rules): no owner at all. Encoded as `data_owner/1` returning `:no_owner`. Only the bootstrap admin (`entity://user/system/admin`) — which holds the `kind: :any, behavior: :any, instance: :any, workspace_uri: :any` cap as a structural invariant (`apps/ezagent_core/lib/ezagent/capability.ex:193-202`) — can grant.

---

## 3. New Behavior callback: `data_owner/1`

### 3.1 Signature

```elixir
@callback data_owner(instance :: URI.t() | :any | Ezagent.Capability.scope_tuple()) ::
            URI.t()
            | :any
            | :no_owner
            | {:scope, :within_session | :within_workspace | :spawned_by, URI.t()}
```

Added to `Ezagent.Behavior` alongside the existing `cap_subjects/0` and `dispatchable?/0` callbacks (per `2026-05-23-capability-registry.md` §3.1). Marked `@optional_callbacks` for backward compatibility — Behaviors that don't define it default to `:no_owner` (the safest default — only system admin can grant).

The function is called with the same `instance` value the stored cap carries. Per `Ezagent.Capability` (`apps/ezagent_core/lib/ezagent/capability.ex:31-43`), that value can be one of three shapes:

| Input shape | When the framework calls with this | Meaning |
|---|---|---|
| `%URI{}` | Default-grant time (per spawn) AND `grant_cap` time when the needed cap targets a concrete instance | Concrete target — Behavior MUST resolve the owner of THIS instance |
| `:any` | `grant_cap` time when the needed cap shape is `instance: :any` (a class-wide cap) | "What's the owner of the WHOLE class?" — most Behaviors return `:any` (only workspace admin grants class-wide) or `:no_owner` (only system admin) |
| `{:within_session, %URI{}}` / `{:within_workspace, %URI{}}` / `{:spawned_by, %URI{}}` | `grant_cap` time when the held cap uses scope-bounded delegation (Decision #137) | "Who can grant a scope-bounded cap?" — Behavior may resolve the scope URI's owner (e.g. `{:within_session, S}` → `Session.owner(S)`) |

Four legal return shapes:

| Return | Meaning | Who can grant via `grant_cap` |
|---|---|---|
| `%URI{}` | Per-instance / per-scope owner | That URI's principal, or a delegate holding a chained cap |
| `:any` | Workspace-scoped (any workspace admin grants) | Any holder of `Behavior.Workspace` cap on `workspace_of(needed.instance)` |
| `:no_owner` | System-scoped (no per-instance owner) | Only the bootstrap admin (or holder of an explicit system-level grant) |
| `{:scope, scope_kind, scope_uri}` | Forward to the scope's owner | Use the scope's owner; e.g. `{:scope, :within_session, S}` means "Session.owner(S) grants" |

The fourth shape is the bridge for Behaviors that gate data inside a scope (e.g. `Behavior.Routing` on a Session resolves to the session owner; on a Workspace resolves to `:any`; on System resolves to `:no_owner` — see §3.3). It lets a Behavior author defer the lookup to whichever scope is appropriate, without computing the owner URI itself.

Concrete examples for each input × return combination:

```elixir
# Concrete instance — direct owner
Behavior.Identity.data_owner(%URI{scheme: "entity", host: "user", ...})
#=> %URI{scheme: "entity", host: "user", ...}  (the user themself)

# Concrete instance — scope forwarding
Behavior.Routing.data_owner(%URI{scheme: "session", ...} = session_uri)
#=> {:scope, :within_session, session_uri}

# Class-wide query at grant_cap time — most Behaviors don't allow it
Behavior.Chat.data_owner(:any)
#=> :no_owner   # class-wide Chat caps require bootstrap admin

# Scope-bounded held cap → resolve via scope
Behavior.Chat.data_owner({:within_session, session_uri})
#=> {:scope, :within_session, session_uri}   # session owner grants
```

The framework's `Behavior.Identity.grant_cap` entry point (§5) uses this return to enforce the grant rule structurally — Behavior authors never write a custom predicate.

### 3.2 Why a function and not a static field

The owner is a function of the instance URI because the same Behavior gates many instances, each with its own owner. `Behavior.Chat` runs on every session — each session has a different creator. The function shape lets the Behavior author write a one-line lookup against persistent state (`Ezagent.Persistence` or the slice itself) without baking ownership into the Behavior module attributes.

Performance note: `data_owner/1` is called in two places:
- At cap-creation / default-grant time (rare; one call per spawn).
- At `grant_cap` time (rare; admin actions).

It is **not** on the hot dispatch path (step 5.5's `Capability.matches?/2` runs on the held cap struct alone; the owner question was already resolved at grant time). So the function may safely do an ETS lookup or a small DB read. P22's hot-path discipline is preserved.

### 3.3 Examples — 5 existing Behaviors, what `data_owner/1` should return

Walking through real files (full audit table in §6):

**`Ezagent.Behavior.Identity`** (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:44`) — exposes `:list_caps`, `:has_cap?`, `:grant_cap`, `:revoke_cap`; registered on User + Agent (`apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:233-243`):

```elixir
def data_owner(%URI{scheme: "entity", host: "user"} = uri), do: uri
def data_owner(%URI{scheme: "entity", host: "agent"} = uri) do
  # An agent's identity data is owned by the agent's spawner.
  case Ezagent.AgentLineage.lookup(uri) do
    {:ok, spawner} -> spawner
    :error -> uri   # bootstrap-time admin Agent: owner = self
  end
end
def data_owner(:any), do: :no_owner   # class-wide Identity grants are bootstrap-only
def data_owner({:scope, _, _} = scope), do: scope
def data_owner({:within_session, _} = t), do: {:scope, elem(t, 0), elem(t, 1)}
# (etc. — all three scope shapes forward unchanged)
```

Rationale: the User's identity data (their cap set) is owned by the User themself; a User may grant caps from their own holding to another User they trust. An Agent is owned by its spawning principal (the human or orchestrator that ran `Agent.spawn/4`), so the spawner can grant caps to the agent or revoke them. If lineage is unknown (e.g. bootstrap-time admin Agent), default to the agent itself owning its data (which means only system-admin can grant on it because the agent can't legitimately self-grant in the bootstrap path).

**`Ezagent.Behavior.Chat`** (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:60`) — exposes `:send`, `:receive`, `:join`, `:leave`, `:set_working_copy`; registered on Session (for first four actions) and User/Agent (for `:receive`) (`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:453-461`):

```elixir
def data_owner(%URI{scheme: "session"} = uri) do
  # Session is owned by the principal who spawned it
  # (PR-OWN-2 adds the lookup via Ezagent.Entity.Session.owner/1).
  Ezagent.Entity.Session.owner(uri)
end
def data_owner(%URI{scheme: "entity", host: "user"} = uri), do: uri
def data_owner(%URI{scheme: "entity", host: "agent"} = uri) do
  case Ezagent.AgentLineage.lookup(uri) do
    {:ok, spawner} -> spawner
    :error -> uri
  end
end
def data_owner(:any), do: :no_owner
def data_owner({:within_session, s_uri}), do: {:scope, :within_session, s_uri}
def data_owner({:within_workspace, w_uri}), do: {:scope, :within_workspace, w_uri}
def data_owner({:spawned_by, p_uri}), do: {:scope, :spawned_by, p_uri}
```

Rationale: a session's owner can grant any `Behavior.Chat` cap on that session to other principals (this is how session membership works). A user's `Behavior.Chat` cap on their own URI (the `:receive` registration) belongs to the user themself.

**`Ezagent.Behavior.Workspace`** (`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:60-73`) — exposes 9 actions: `:list_members`, `:add_member`, `:remove_member`, `:list_templates`, `:add_template`, `:remove_template`, `:list_routing_rules`, `:set_routing_rules`, `:instantiate`; registered on Workspace (`apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:44-46`):

```elixir
def data_owner(%URI{scheme: "workspace"}), do: :any  # workspace-scoped
def data_owner(:any), do: :no_owner
def data_owner({:within_workspace, w_uri}), do: {:scope, :within_workspace, w_uri}
```

Rationale: a workspace is multi-admin by design; any workspace admin can grant workspace-management caps. The admin status is itself a `Behavior.Workspace` cap on the workspace, scoped by membership (see OQ-OWN-1 for whether to upgrade this to a single `workspace_owner_uri`).

**`Ezagent.Behavior.Routing`** (`apps/ezagent_core/lib/ezagent/behavior/routing.ex:62-69`) — exposes `:add_rule`, `:delete_rule`, `:disable_rule`, `:enable_rule`; registered on Workspace (`apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:54-56`), Session (`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:471-473`), and System (`apps/ezagent_core/lib/ezagent_core/application.ex:149-152`):

```elixir
def data_owner(%URI{scheme: "workspace"}),    do: :any         # workspace admin grants
def data_owner(%URI{scheme: "session"} = uri), do: {:scope, :within_session, uri}
def data_owner(%URI{scheme: "system"}),       do: :no_owner    # only bootstrap admin grants
def data_owner(:any),                          do: :no_owner
def data_owner({:within_session, s}),          do: {:scope, :within_session, s}
def data_owner({:within_workspace, w}),        do: {:scope, :within_workspace, w}
```

Rationale: a routing rule on a workspace is workspace-scoped data; on a session, the session-owner is the grantor; on `system://routing/default` is system-scoped (no per-instance owner, only bootstrap admin can grant).

**`Ezagent.Behavior.Template`** (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/template.ex:128`) — exposes `:read`, `:write`, `:instantiate`, `:fork`; registered on AgentTemplate + SessionTemplate (`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:499-502`):

```elixir
def data_owner(%URI{scheme: "template"} = uri) do
  # Template is owned by the principal who wrote it (recorded at
  # `:write` time as a slice field; PR-OWN-3 adds Template.writer/1).
  # Until then, owned by :any workspace admin (pre-write templates aren't useful).
  Ezagent.Entity.Template.writer(uri) || :any
end
def data_owner(:any), do: :no_owner
def data_owner({:within_workspace, w}), do: {:scope, :within_workspace, w}
```

Rationale: a Template is owned by whoever wrote it; that owner can grant `:read` / `:fork` to other principals. The workspace fallback handles the bootstrap case where no writer is recorded.

### 3.4 Session.owner lookup — what PR-OWN-2 adds

There is **no `Session.owner/1` function in the codebase today** (verified via `grep` against `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex`). Session is spawned with `owner_uri` (`apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:121`) but the value is not stored in any retrievable slice. PR-OWN-2 introduces the lookup, with three implementation options ranked by preference:

- **(a)** Add `:owner_uri` field to the `:chat` slice initialised at spawn (cheapest — `Behavior.Chat.init_slice/1` already runs at every Session spawn; one line addition).
- **(b)** Add a dedicated `Ezagent.Entity.Session` slice carrying `{owner_uri, created_at}` — cleaner conceptually but requires a new Behavior or extending an existing one.
- **(c)** Derive from the URI segment (`derive_session_uri/3` at `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:286-298` encodes owner_name in the URI itself: `session://<class>/<workspace>/<owner_name>-<template_name>`) — works but requires reverse-lookup to a `%URI{}` (owner_name is a display segment, not a full URI).

PR-OWN-2 picks **(a)** because it's a one-line slice addition that doesn't fight the existing spawn flow. `Session.owner/1` becomes a Kind state read via `Ezagent.Kind.Runtime.get_slice/2` (already used by other lookups). If a future SPEC introduces a dedicated Session entity module, the lookup can migrate without breaking `Behavior.Chat.data_owner/1`.

---

## 4. Default-grant migration

### 4.1 The structural identity

`CapabilityRegistry.register_default_grant/2` keeps its public shape unchanged — the framework keeps a `grant_fn :: (URI.t() | :any -> [Capability.t()])` mapped per-Kind. What changes is **how a Behavior author derives the grant_fn**: it is no longer a hand-written function, it is mechanically derived from `data_owner/1`.

The rule, expressed once in the framework:

> For every Behavior `B` registered against `Kind K`, and for every newly-created instance `target_uri` of `K`, the framework grants a cap `%Capability{kind: K.type_name(), behavior: B, instance: target_uri, workspace_uri: Capability.workspace_of(target_uri), granted_by: bootstrap_or_owner_uri, granted_at: now}` to the URI returned by `B.data_owner(target_uri)` — provided that return is a concrete `URI.t()`. Returns of `:any` / `:no_owner` / `{:scope, _, _}` produce NO default grant (those subjects rely on explicit grant via `grant_cap`).

This is the **derivable** default-grant rule. A Behavior author who declares `data_owner/1` correctly gets the right default grants for free. Note the cap is **per-Behavior**, not per-action — one default grant grants the holder all actions of that Behavior on that instance, matching the cap struct's actual semantics.

### 4.2 What stays, what changes

**Stays unchanged:**
- `%Capability{}` struct (still 6 fields — `kind, behavior, instance, workspace_uri, granted_by, granted_at`).
- `Capability.matches?/2` semantics (still pattern-matches the four `kind/behavior/instance/workspace_uri` fields).
- ETS storage of caps and of `CapabilityRegistry` subjects/default-grants.
- `CapabilityRegistry.register_default_grant/2` API (Behaviors with custom grant needs still call it).
- `User.default_caps/1` function (existing callers — `Users.create/3`, Feishu `BindingPolicy`, `mix ezagent.stress` — keep working unchanged; see §10 non-goal #3).

**Changes (additive):**
- New `Behavior` callback `data_owner/1` (optional, defaults to `:no_owner`).
- New helper `CapabilityRegistry.default_grants_from_data_owner(kind, target_uri)` that walks every Behavior registered for `kind`, calls `behavior.data_owner(target_uri)`, and returns `[{grantee_uri :: URI.t(), Capability.t()}]` — the tuple form is **mandatory** because `%Capability{}` has no grantee field (it carries `granted_by` only). The spawn path uses each tuple's `grantee_uri` to know whose Identity slice receives the cap. Used by spawn paths that opt into structural defaults (versus hand-written `default_caps/1`).

```elixir
# Helper contract (r3 — fixes r2 HIGH)
@spec default_grants_from_data_owner(kind :: module(), target_uri :: URI.t()) ::
        [{grantee_uri :: URI.t(), Capability.t()}]
def default_grants_from_data_owner(kind, %URI{} = target_uri) do
  # For each Behavior B registered against `kind`, ask B.data_owner(target_uri).
  # Only concrete URI returns produce a default grant; :any / :no_owner /
  # {:scope, _, _} produce no entry (caller relies on explicit grant_cap).
  #
  # r5 fix (codex round-4 HIGH): use the public `subjects_for_kind/1` API,
  # NOT raw `:ets.match`. Round-4 SPEC tried `{{kind, :_}, :"$1", :_}` but
  # the actual `CapabilityRegistry.register/3` insert shape is
  # `{{kind, behavior, action}, meta}` (2-element outer tuple, 3-element key)
  # — the round-4 match pattern returned ZERO rows so the entire helper
  # silently produced an empty list, defeating the cap-only fix.
  #
  # Why the public API and not `:ets.match_object/2` with the correct
  # shape `{{kind, :"$1", :_}, :_}`: `subjects_for_kind/1` is the
  # documented contract and changes-resistant to future ETS layout
  # tweaks (e.g. if the registry grows a sharded backing store).
  # Round-1 SPEC didn't catch this because it had the wrong abstraction
  # (BehaviorRegistry); round-4 didn't catch it because it had the
  # wrong ETS pattern; round-5 uses the typed public surface.
  behaviors_for_kind =
    kind
    |> Ezagent.CapabilityRegistry.subjects_for_kind()
    |> Enum.map(& &1.behavior)
    |> Enum.uniq()

  for behavior <- behaviors_for_kind,
      owner = data_owner_of(behavior, target_uri),
      match?(%URI{}, owner),
      uniq: true do
    cap = %Capability{
      kind: kind.type_name(),
      behavior: behavior,
      instance: target_uri,
      workspace_uri: Capability.workspace_of(target_uri),
      granted_by: bootstrap_uri(),
      granted_at: DateTime.utc_now()
    }
    {owner, cap}
  end
end
```

This is purely additive — no existing code path breaks. Migration is per-Behavior, opt-in (PR-OWN-2 onward). PR-OWN-2's acceptance test asserts: after spawning a session as Alice, `Ezagent.Behavior.Identity.list_caps(alice_uri)` includes the `Behavior.Chat` cap on the new session URI — i.e. the grant landed in Alice's identity slice, not just returned from the helper.

---

## 5. Grant action: `Behavior.Identity.grant_cap/3` becomes the single entry point

### 5.1 Today

`Ezagent.Behavior.Identity.invoke(:grant_cap, slice, args, ctx)` exists (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:44` — declared in `actions/0` and `cap_subjects/0`; the `invoke/4` clause is wired). The current cap check at dispatch step 5.5 verifies that the caller holds an admin-grade cap on the target principal — i.e., "do you have permission to mutate this user's caps." That check is necessary but not sufficient: it doesn't verify that the caller is *legitimate to grant THIS specific cap*.

### 5.2 SPEC change

`grant_cap`'s pre-invoke check is augmented with one structural rule: the caller (per `ctx.caller`) MUST be the data owner of the cap being granted, OR hold a recorded delegation cap previously granted by the data owner.

Concretely, before mutating the target's slice, `Behavior.Identity.invoke(:grant_cap, ...)` runs these steps in order. Steps 0 and 0.5 are r3 additions that fail closed on the cap shapes that `data_owner/1` cannot meaningfully be evaluated against; this prevents r2's CRITICAL (calling `:any.data_owner/1`) and HIGH (`workspace_of/1` on non-URI):

**0. Wildcard pre-check (r3 — CRITICAL fix).**
   If `needed_cap.kind == :any` OR `needed_cap.behavior == :any` → require caller to hold the bootstrap admin cap (`Capability.admin_invariant?/1`); otherwise return `{:error, :grant_wildcard_requires_admin}`. **Rationale**: `:any` is a sentinel, not a Behavior module; there is no `data_owner/1` to call. The bootstrap admin is the only legitimate granter for wildcard caps. This forecloses the path where `User.default_caps/1`'s `{behavior: :any}` shape (`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:104-116`) gets re-granted by a non-admin through `grant_cap`.

**0.5. Workspace dimension pre-check (r3 — HIGH fix).**
   For the `owner == :any` branch (step 4 below) to be evaluable, `needed_cap.workspace_uri` MUST be a concrete `workspace://` URI. If `needed_cap.workspace_uri == :any` (cross-workspace cap), require caller to hold the bootstrap admin cap; otherwise return `{:error, :grant_cross_workspace_requires_admin}`. **Rationale**: a cross-workspace grant has no single "workspace admin" to authorise against; only bootstrap admin can mint cross-workspace caps. This is a pre-check so the rest of the rule can rely on `needed_cap.workspace_uri` being a `%URI{}`.

**1. Resolve owner.**
   `owner = needed_cap.behavior.data_owner(needed_cap.instance)` — by step 0, `needed_cap.behavior` is a real module here. `needed_cap.instance` can be `%URI{}`, `:any`, or a scope tuple; the Behavior's `data_owner/1` clauses handle all three per §3.1.

**2. Normalise scope returns.**
   If `owner` is `{:scope, _scope_kind, scope_uri}`, recursively resolve via the scope-owning Behavior (e.g. `:within_session` → `Behavior.Chat.data_owner(scope_uri)`). Bounded recursion depth = 3 (raises `{:error, :grant_scope_cycle}` on cycle). The final resolved `owner` is one of `%URI{}`, `:any`, or `:no_owner`.

**3. `owner == :no_owner`.**
   Require caller to hold the bootstrap admin cap (`Capability.admin_invariant?/1`); otherwise `{:error, :grant_not_owner}`.

**4. `owner == :any`.**
   Require caller to hold a `Behavior.Workspace` cap on `needed_cap.workspace_uri` (which is a concrete `workspace://` URI by step 0.5). Use the cap struct's recorded workspace dimension; do NOT re-derive via `workspace_of/1` (the instance may be `:any` or a scope tuple).

**5. `owner` is a `%URI{}`.**
   Require `ctx.caller == owner` OR caller holds a `delegation` cap previously granted by `owner` (delegation cap shape per OQ-OWN-2).

**6. Audit log.**
   `granter_uri (ctx.caller) → grantee_uri (target) granted (cap_shape) — delegation_chain: [...]`. Logged after a successful check, before slice mutation.

The cap-check passes if and only if one of (0)/(0.5)/(3)/(4)/(5) is satisfied. Otherwise the action returns the corresponding distinct error code (NOT `:unauthorized`, to make the failure mode legible in logs). Error codes summary:

- `:grant_wildcard_requires_admin` — kind/behavior wildcard from non-admin
- `:grant_cross_workspace_requires_admin` — `workspace_uri: :any` from non-admin
- `:grant_scope_cycle` — `{:scope, _, _}` chain exceeds depth bound
- `:grant_not_owner` — caller is neither owner nor delegate, and not bootstrap-admin where required

### 5.3 Why a single entry point

Today, caps are also minted in:
- `Users.create/3` (via `User.default_caps/1` prepend)
- `Feishu BindingPolicy.ensure_user_default_caps/2`
- Various spawn paths (`Agent.spawn/4` etc., which compute initial caps)

The SPEC does NOT consolidate these into one entry — that would force a heavy migration. Instead:
- **Default grants** (instance-creation time): flow through the framework's `default_grants_from_data_owner/2` helper (or stay in hand-written `default_caps/1` for legacy paths). These are *structural* defaults; their legitimacy comes from "the framework granted them at the moment of instance creation, on behalf of the future owner" — no human granter is involved.
- **All other grants** (admin actions, delegations, user-initiated): MUST flow through `Behavior.Identity.invoke(:grant_cap, ...)`. The §5.2 check is the chokepoint.

An invariant test (PR-OWN-FINAL) scans production code for any other path that mints a `%Capability{}` and inserts it into a User/Agent's slice — flagging it as a bypass of the structural rule.

---

## 6. Audit of existing Behaviors (Kind × Behavior pairs)

Each Behavior file was read directly (sources cited in the table). Per CRITICAL-1 (caps are Behavior-scoped not action-scoped), rows are `(Kind, Behavior)` pairs — each pair is one cap subject in the storage sense. The "Actions exposed (for reference)" column is verbatim from `cap_subjects/0` and exists only for catalog purposes; holding the cap grants ALL listed actions.

The "Current implicit owner" column says what the current code de-facto treats as the granter. For most rows the answer is "admin (catch-all `:any` cap)" because no other rule exists.

| # | Kind registered against | Behavior | Actions exposed (for reference; verified at path:line) | Current implicit owner | Proposed `data_owner/1` return | Default-grant rule (derived) | Migration cost |
|---|---|---|---|---|---|---|---|
| 1 | `Ezagent.Entity.User` | `Ezagent.Behavior.Identity` | `:list_caps, :has_cap?, :grant_cap, :revoke_cap` (identity.ex:44) | admin (`:any`) | `URI` itself | user gets cap on own URI at creation | trivial — slice already exists |
| 2 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Identity` | (same as #1; identity.ex:44, registered at application.ex:242) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap at spawn time | trivial |
| 3 | `Ezagent.Entity.User` | `Ezagent.Behavior.ApiKeys` | `:list_api_keys, :put_api_key, :delete_api_key, :get_api_key` (api_keys.ex:52) | admin (`:any`) | `URI` itself | user gets cap on own URI at creation | trivial |
| 4 | `Ezagent.Entity.Workspace` | `Ezagent.Behavior.Workspace` | `:list_members, :add_member, :remove_member, :list_templates, :add_template, :remove_template, :list_routing_rules, :set_routing_rules, :instantiate` (workspace.ex:60-73) | admin (`:any`) | `:any` (workspace-scoped) | no per-instance default — workspace admin must explicitly grant | declare `:any` |
| 5 | `Ezagent.Entity.Workspace` | `Ezagent.Behavior.Routing` | `:add_rule, :delete_rule, :disable_rule, :enable_rule` (routing.ex:62-69; registered at workspace/application.ex:54-56) | admin (`:any`) | `:any` (workspace-scoped) | no per-instance default | declare `:any` |
| 6 | `Ezagent.Entity.Session` | `Ezagent.Behavior.Chat` | `:send, :receive, :join, :leave, :set_working_copy` (chat.ex:60-69; Session-side registered at chat/application.ex:453-459) | admin (`:any`) | `Session.owner(uri)` (PR-OWN-2 adds the lookup) | session owner gets `Behavior.Chat` cap on own session at spawn | small — add `:owner_uri` to `:chat` slice |
| 7 | `Ezagent.Entity.User` | `Ezagent.Behavior.Chat` | `:receive` (the User-registered action; chat/application.ex:460) | admin (`:any`) | `URI` itself | user gets `Behavior.Chat` cap on own URI at creation | trivial |
| 8 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Chat` | `:receive` (chat/application.ex:461) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap on spawned agent | trivial |
| 9 | `Ezagent.Entity.Session` | `Ezagent.Behavior.Routing` | `:add_rule, :delete_rule, :disable_rule, :enable_rule` (registered at chat/application.ex:471-473) | admin (`:any`) | `Session.owner(uri)` (reuses #6's lookup) | session owner gets `Behavior.Routing` cap on own session at spawn | small — shares #6 work |
| 10 | `Ezagent.Entity.System` | `Ezagent.Behavior.Routing` | (same actions; registered at core/application.ex:149-152) | admin (`:any`) | `:no_owner` | no default — only bootstrap admin grants | trivial |
| 11 | `Ezagent.Entity.AgentTemplate` | `Ezagent.Behavior.Template` | `:read, :write, :instantiate, :fork` (template.ex:128-137; registered at chat/application.ex:499-501) | admin (`:any`) | `Template.writer(uri) || :any` | writer gets cap at write time | small — add `:writer_uri` to `:template` slice |
| 12 | `Ezagent.Entity.SessionTemplate` | `Ezagent.Behavior.Template` | (same as #11; registered at chat/application.ex:500-501) | admin (`:any`) | `Template.writer(uri) || :any` | writer gets cap at write time | (covered by #11) |
| 13 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Pty` | `:write` (pty.ex:55-58; registered at chat/application.ex:486-488) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap on spawned agent at spawn | trivial |
| 14 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Lifecycle` | `:terminate` (lifecycle.ex:62-67; registered at chat/application.ex:516-518) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap at spawn | trivial |
| 15 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Sandbox` | `:read, :write_path, :destroy` (sandbox.ex:80-90; registered at chat/application.ex:527-529) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap at spawn | trivial |
| 16 | `Ezagent.Entity.User` | `Ezagent.Behavior.Notifications` | `:notify, :subscribe` (notifications.ex:26-31; cap-only — `dispatchable?/0 == false`; registered at core/application.ex:197-198) | admin (`:any`) | `URI` itself | user gets cap on own inbox at creation | trivial |
| 17 | `Ezagent.Entity.User` | `Ezagent.Behavior.Presence` | `:online` (presence.ex:28-30; cap-only; registered at core/application.ex:187) | admin (`:any`) | `URI` itself | user gets cap on own URI at creation | trivial |
| 18 | `Ezagent.Entity.Agent` | `Ezagent.Behavior.Presence` | `:online` (registered at core/application.ex:188) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap at spawn | trivial |
| 19 | `Ezagent.Entity.Echo` | `Ezagent.Behavior.Echo` | `:say, :receive` (echo.ex:47-52; plugin-registered) | admin (`:any`) | `URI` itself | echo entity owns its own echo (toy) | trivial |
| 20 | `Ezagent.Entity.CurlAgent` | `Ezagent.Behavior.CurlAgent` | `:receive, :reset_conversation, :configure` (curl_agent.ex:62-69; plugin-registered at plugin_curl_agent/application.ex:80-84) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap at spawn | trivial |
| 21 | `Ezagent.Entity.NpAgent` | `Ezagent.Behavior.NpAgent` | `:receive, :reset, :configure` (np_agent.ex:59-66; plugin-registered at plugin_np/application.ex:85-89) | admin (`:any`) | `AgentLineage.lookup(uri) || uri` | spawner gets cap at spawn | trivial |
| 22 | `Ezagent.Entity.Session` | `EzagentPluginFeishu.Behavior.FeishuOutbound` (real module name; r3 fix — r2 mis-namespaced as `Ezagent.PluginFeishu.Behavior.FeishuOutbound`) | `:notify_external` (feishu_outbound.ex:64-69; plugin-registered against `Ezagent.Entity.Session` at plugin_feishu/application.ex:86-93) | admin (`:any`) | `Session.owner(uri)` (reuses #6's lookup) | session owner gets `FeishuOutbound` cap on own session at spawn | trivial — shares #6 work |

Aggregate: 22 `(Kind, Behavior)` pairs across 15 Behavior modules. Migration is line-level — each Behavior gets one `data_owner/1` function (10–15 lines including all four input shapes) plus three slice-field additions (Session `:owner_uri`, Template `:writer_uri`, Agent lineage already exists in `Ezagent.AgentLineage` ETS table per `apps/ezagent_core/lib/ezagent/agent_lineage.ex`). No DB migration; the new fields ship with the next DB rebuild per the project's wipe-and-rebuild convention (SPEC v3 §8 / memory `feedback_let_it_crash_no_workarounds`).

---

## 7. Migration plan

Each PR is independently shippable (compiles, tests pass, no behavior change unless declared). The order below is **strict** — each PR's acceptance test depends ONLY on code introduced in itself or a prior PR (fixes r1 HIGH-1).

### PR-OWN-1 — Framework callback + audit baseline (no behavior change)

**Changes:**
- Add `@callback data_owner(URI.t() | :any | scope_tuple()) :: URI.t() | :any | :no_owner | {:scope, atom(), URI.t()}` to `Ezagent.Behavior` with `@optional_callbacks [data_owner: 1]`.
- Default lookup in `Ezagent.CapabilityRegistry.data_owner_of/2` (helper): if `function_exported?(behavior, :data_owner, 1)` → call it; else `:no_owner`.
- Add `CapabilityRegistry.default_grants_from_data_owner/2` helper — returns `[{grantee_uri :: URI.t(), Capability.t()}]` (tuple form, per §4.2 contract) by walking Behaviors registered for the kind. NOT YET CALLED by any spawn path (just available for opt-in).
- Add audit reporter `mix ezagent.caps.audit` task that walks every Behavior in `:code.all_loaded` whose name matches `Ezagent.*.Behavior.*` and prints which ones have / lack `data_owner/1`.
- Update `Ezagent.Behavior` moduledoc with the rule + the four boundary returns.

**Acceptance:**
- `mix compile --warnings-as-errors` clean.
- `mix ezagent.caps.audit` reports baseline (0 production Behaviors have `data_owner/1` after PR-OWN-1; `--strict` flag exits non-zero — used by PR-OWN-FINAL).
- Unit test in PR-OWN-1: define `Ezagent.TestSupport.OwnedBehavior` (a fresh test-only Behavior implementing `data_owner/1` and a synthetic Kind), assert `CapabilityRegistry.default_grants_from_data_owner/2` returns the expected `[{grantee_uri, %Capability{}}]` tuple list. This test depends ONLY on PR-OWN-1 code — no real Behavior is touched.
- **Registry-shape regression test (r5, codex round-4 HIGH)**: register a synthetic dispatchable Behavior with MULTIPLE actions (e.g. `:read`, `:write`) PLUS a cap-only Behavior (`dispatchable?: false`) against the same test Kind. Call `default_grants_from_data_owner/2` and assert BOTH owner/cap tuples are returned (the dispatchable Behavior once via `Enum.uniq`, plus the cap-only one). Without this test, round-4's wrong ETS pattern silently produced an empty list — locking the public-API enumeration via test prevents future drift if `subjects_for_kind/1` semantics change.
- No existing test breaks.

**LOC est:** ~120 (callback + helper + task + docs + test support).

### PR-OWN-2 — Session.owner lookup + Behavior.Chat data_owner (Session migration)

**Changes:**
- Add `:owner_uri` field to `Behavior.Chat.init_slice/1` (one line — `Map.put(slice, :owner_uri, Map.get(args, :owner_uri))`).
- Add `Ezagent.Entity.Session.owner/1` public function that does `Ezagent.Kind.Runtime.get_slice(session_uri, :chat) |> Map.get(:owner_uri)`.
- Wire `Session.spawn_from_template/2` to pass `owner_uri` into the Chat slice (already has the value — `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:121`).
- Declare `Behavior.Chat.data_owner/1` per §3.3 (uses `Session.owner/1`).
- Wire `Behavior.Identity.invoke(:grant_cap, ...)` to enforce §5.2 (the structural rule) — but ONLY for needed caps whose Behavior has `data_owner/1` declared. Behaviors without `data_owner/1` keep the old admin-cap check until they migrate (incremental rollout).
- **r4 fix (codex CRITICAL)**: update `Ezagent.Identity.grant_cap/3` facade at `apps/ezagent_domain_identity/lib/ezagent/identity.ex:149-164` to pass the **granter's REAL caps** via `Ezagent.Behavior.Identity.list_caps(granter_uri)` instead of the current hardcoded `Ezagent.Entity.User.admin_caps()`. The §5.2 pre-check is moot if the facade always sends admin caps — every grant trivially passes regardless of what granter actually holds. Backward compat: existing callers (`mix ezagent.user.create`, Admin LV grant button, all currently invoked with `granter_uri = admin_uri`) keep working because that admin DOES hold admin caps; new caller paths that pass a non-admin `granter_uri` now correctly hit the §5.2 wildcard pre-check + the data-owner rule. Acceptance test (e) added below.

**Acceptance:**
- All existing tests pass.
- New tests, all using code introduced by PR-OWN-1 + PR-OWN-2 only:
  - (a) Spawn a session as user Alice; `Session.owner(session_uri)` returns Alice's URI.
  - (b) Alice (session owner) calls `Behavior.Identity.invoke(:grant_cap, ...)` granting Bob a `Behavior.Chat` cap on Alice's session — succeeds.
  - (c) Bob (not session owner) attempts the same grant — denied with `:grant_not_owner`.
  - (d) A user with a narrow cross-workspace cap on `Behavior.Chat` (PR #303 HIGH-3 scenario equivalent) attempts to grant `Behavior.Chat` on a session they don't own — denied with `:grant_not_owner`.
  - (e) **r4 acceptance**: a non-admin `Ezagent.Identity.grant_cap/3` caller (passing their own URI as `granter_uri`) gets their REAL caps forwarded into dispatch ctx, not `User.admin_caps()`. Asserted by stubbing `granter_uri = non_admin_alice` and verifying the §5.2 check sees `ctx.caps = Behavior.Identity.list_caps(alice)` not `admin_caps`.

**LOC est:** ~120 (slice field + lookup + data_owner + grant_cap wiring + 4 tests).

### PR-OWN-3 — Identity + Workspace migration

**Changes:**
- Declare `Behavior.Identity.data_owner/1` per §3.3.
- Declare `Behavior.Workspace.data_owner/1` per §3.3 (returns `:any` for `workspace://`).
- Tests for both, depending on PR-OWN-1/2 code.

**Acceptance:**
- New tests:
  - Granting a `Behavior.Identity` cap on Alice's URI from a non-Alice caller without an Alice-granted delegation is denied with `:grant_not_owner`.
  - Granting a `Behavior.Workspace` cap on `workspace://team-alpha` from a non-team-alpha-admin caller is denied with `:grant_not_owner`.
  - Granting from a workspace admin succeeds.

**LOC est:** ~80.

### PR-OWN-4 — Routing + Template + Pty + Lifecycle + Sandbox + ApiKeys migration

**Changes:**
- Declare `data_owner/1` on `Behavior.Routing`, `Behavior.Template`, `Behavior.Pty`, `Behavior.Lifecycle`, `Behavior.Sandbox`, `Behavior.ApiKeys` per audit table.
- Add `Ezagent.Entity.Template.writer/1` lookup (parallel to `Session.owner/1` — adds `:writer_uri` to `:template` slice).
- Add `:writer_uri` to `Behavior.Template.init_slice/1`; populate at `:write` action time.

**Acceptance:**
- Grant of `:add_rule` Routing cap on workspace X from non-X-admin: denied.
- Grant of `:add_rule` Routing cap on session A from session B's owner: denied.
- Grant of `:read` Template cap on template T from non-writer: denied.

**LOC est:** ~180.

### PR-OWN-5 — Plugin Behaviors (Echo, CurlAgent, NpAgent, FeishuOutbound, Notifications, Presence)

**Changes:** declare `data_owner/1` per audit table. Notifications and Presence reuse the User-URI / spawner pattern.

**LOC est:** ~80.

### PR-OWN-6 — Notifications predicate cleanup (refactor only; no behavior change)

**Changes:**
- Replace `notification_subscriptions.ex`'s hand-written `has_admin_cap?` predicate with a `data_owner`-derived check (PR #303 HIGH-3 fix becomes structurally redundant — the registry derives the same answer).
- Keep the hand-written predicate behind a deprecated alias for one release; CI gate flags new call sites.

**Acceptance:**
- PR #303's regression tests still pass with the new predicate.

**LOC est:** ~60 net.

### PR-OWN-FINAL — Enforcement invariant

**Changes:**
- `data_owner_declared_for_all_test.exs` invariant test: every Behavior loaded in production (`:code.all_loaded` filtered to `Ezagent.*.Behavior.*` and the plugin namespaces e.g. `EzagentPluginFeishu.*`) MUST declare `data_owner/1`. Failures list the Behavior + the missing branch. Uses the same `:code.all_loaded` walk pattern as PR #264's `single_capability_registration_entry_test.exs`.
- `audit_table_matches_registry_test.exs` invariant test (r3 addition — closes the FeishuOutbound HIGH): boots the system, reads `CapabilityRegistry.list_grantable/0`, and asserts that every `(kind, behavior)` pair in the live registry appears in this SPEC's §6 audit table (parsed from the markdown source). Catches future SPEC drift / typos in Behavior module names against real registrations.
- `mix ezagent.caps.audit --strict` returns non-zero on any missing declaration.
- Update SKILL with a new principle `P28. Capability = CRUD on data class (Behavior-scoped); data owner is the only grantor` (cross-referenced from P15). Update GLOSSARY with `data_owner/1`, `data owner`, `delegated grant`.

**Acceptance:**
- All Behaviors declare `data_owner/1`; the invariant test gates future PRs from adding a Behavior without the callback.
- §6 audit table is structurally tied to the real registry; mis-namespaced module names in the SPEC fail CI.

**LOC est:** ~80 (was 50; +30 for the SPEC-vs-registry parser/asserter).

### Sequencing notes

- **Strict order**: PR-OWN-1 → PR-OWN-2 → PR-OWN-3 / PR-OWN-4 / PR-OWN-5 (parallel after PR-OWN-2) → PR-OWN-6 (after PR-OWN-5) → PR-OWN-FINAL (gates closeout).
- PR-OWN-2 must land before PR-OWN-3+ because PR-OWN-2 introduces `Session.owner/1` (used by `Behavior.Chat.data_owner`, `Behavior.Routing.data_owner` for session scope, `FeishuOutbound.data_owner`) AND wires the §5.2 grant check at the framework level (PR-OWN-3+ Behaviors plug into this wiring without re-implementing it).

---

## 8. Open questions for Allen

**OQ-OWN-1: workspace-scoped Behaviors (`Behavior.Workspace`, `Behavior.Routing` on workspace) — `data_owner/1` returns `:any` (any workspace admin grants) OR `workspace_owner_uri` (single grantor per workspace)?**

- **(a) `:any`** — any holder of a `Behavior.Workspace` cap can grant workspace-management caps. Matches current behavior (multi-admin workspace by default).
- **(b) `workspace_owner_uri`** — workspaces gain a single structural owner (the creator); only that owner can grant workspace caps unless they delegate.
- **(c) Both, switchable per workspace** — `workspace.solo_owned?` boolean.

**Recommended:** (a) for v1. Multi-admin workspaces are the operating reality (already supported by existing data model). (b) would force every existing workspace to have a recorded owner, which the schema doesn't have. (c) is feature-creep without a driving use case. We can upgrade to (b) later by adding a `workspace_owner_uri` column and switching `data_owner/1` returns.

**Trade-off:** (a) keeps the cross-workspace "any admin" grant surface wide. The PR #303 HIGH-3 mitigation already requires that the cap being granted be specifically a `Behavior.Notifications` cap, so the failure mode is bounded at the grantee-cap-class level — not the granter-identity level.

---

**OQ-OWN-2: revocation chain — if granter is a delegate, can revoke also chain backwards?**

When the original data owner O granted a delegation cap to A, who granted to B, who minted a cap on data D for C — can O revoke C's cap directly? Or must O revoke A's delegation cap (which transitively invalidates everything below)?

- **(a) Chain forward only** — revoking A's delegation cap does NOT auto-revoke C's cap (C's cap is independently stored in C's slice). O must walk the chain manually OR rely on a future "revoke transitively" tool.
- **(b) Chain backward auto** — caps store a `delegation_chain: [granter_uris]` field; O's revoke of A's delegation triggers a sweep removing any cap with A in its chain.
- **(c) Chain backward on demand** — O can call `revoke_descendants(cap_subject)` which finds and removes all caps minted under the delegation chain.

**Recommended:** (a) for v1. (b) is invasive — touches every cap struct, slows every grant. (c) is a future feature once the use case appears. v1 is honest: delegation is a one-shot "you can grant this cap," not a chain. Revocation of a delegate cap stops further minting; previously minted caps require a sweep.

**Trade-off:** (a) lets a malicious delegate mint caps before O notices and revokes the delegation, and those caps survive O's revoke. Mitigation: audit log shows the chain; manual cleanup is a script. v1's threat model (PR #303 §"Threat model") assumes plugins are trusted in-BEAM; cross-tenant malicious actors are out of scope.

---

**OQ-OWN-3: backward compat — existing caps minted before this SPEC (no `data_owner/1` legitimacy check ran): grandfather in, or re-audit?**

After PR-OWN-2/-3/-4 lands, every existing cap in `users.caps_json` and `agent` slice state was minted via either default_caps (pre-existing) or admin's grant_cap (also pre-existing). None went through the new §5.2 check.

- **(a) Grandfather in** — existing caps are valid as-is. New caps (from the moment each per-Behavior PR ships) flow through the new check.
- **(b) Re-audit** — a one-shot migration script walks every cap, computes its `data_owner/1` retroactively, and if the granter (recorded in `granted_by`) is not the owner / a legitimate delegate, the cap is REVOKED + flagged for re-grant.
- **(c) Soft re-audit** — same as (b) but caps are flagged but not removed; operator reviews and either re-grants or revokes.

**Recommended:** (a). v1's existing cap data was minted via admin (who satisfies any check). (b) and (c) introduce churn for zero security benefit at v1 scale. We can run (c) as a one-off `mix ezagent.caps.lint` later if multi-admin scenarios appear.

**Trade-off:** (a) means if an existing cap was minted *incorrectly* (the granter wasn't the legitimate owner) it stays valid. That risk is bounded by the small existing cap surface (one admin user).

---

**OQ-OWN-4: bootstrap caps — first admin's caps have no owner; carve-out shape?**

The bootstrap admin (`entity://user/system/admin`) holds the `kind: :any, behavior: :any, instance: :any, workspace_uri: :any` cap granted by `system://bootstrap/default` (`apps/ezagent_core/lib/ezagent/capability.ex:193-202`). This was minted before any `data_owner/1` could run (literally the first cap in the DB). What's the SPEC's structural story for it?

- **(a) Bootstrap-grant exemption** — `granted_by == system://bootstrap/default` is structurally legitimate, full stop. Recorded in `Capability.admin_invariant?/1` (already exists in code; just extend the moduledoc).
- **(b) The bootstrap admin IS the owner of `:no_owner` data** — system-scoped data is owned by bootstrap. `data_owner/1` for system-scoped Behaviors returns `entity://user/system/admin` instead of `:no_owner`. The bootstrap admin then satisfies the new §5.2 check by being their own owner.
- **(c) Bootstrap is a `:no_owner` exemption + every system action requires bootstrap-admin caller** — `:no_owner` means "only bootstrap admin can grant," and bootstrap admin is identified by holding the structural-invariant cap.

**Recommended:** (a) for clarity. The bootstrap path is exceptional by design (creates the system out of nothing); pretending it's a normal owner case adds confusion. The existing `admin_invariant?/1` check already gives the structural anchor. We document the rule: "the bootstrap cap is the seed; every other cap traces back to it via grant chain."

**Trade-off:** (a) keeps a structural exception in the framework; (b) would make the rule uniform at the cost of inventing a fictional ownership. We pick uniformity-of-rule-explanation over uniformity-of-mechanism.

---

**OQ-OWN-5: cross-Kind grant flows (e.g., Alice grants Bob a `Behavior.Chat` cap on Alice's session) — Bob's identity-mutation side is governed by Bob, not Alice. How is Bob's consent modeled?**

When user Alice (`entity://user/team/alice`) calls `grant_cap` on user Bob (`entity://user/team/bob`) to grant Bob `Behavior.Chat` on session S, two ownerships matter:
- The cap's data (`Behavior.Chat` on S) — owned by S's owner (Alice in this example).
- The slice being mutated (Bob's `:identity` slice) — owned by Bob.

§5.2 covers the first (Alice is owner ✓). The second is governed by ezagent's existing dispatch — `grant_cap` already requires the caller to hold a cap on the TARGET principal's Identity (`Behavior.Identity` cap on `entity://user/team/bob`), which exists because Alice was granted that cap when Bob accepted Alice as a friend / collaborator / etc.

There is **no mid-dispatch mechanism that reads Bob's caps** to verify "Bob consents to receive this cap" — dispatch reads `ctx.caps` = Alice's caps only. So:

- **(a) Status quo** — Alice satisfies §5.2 (owns the data) AND holds a `Behavior.Identity` cap on Bob (granted by Bob earlier). Two-gate model; Bob's consent is "Bob previously granted Alice the right to mutate Bob's identity."
- **(b) Consent ledger** — Bob's slice records a list of grant subjects Bob has opted in to receiving; dispatch reads the ledger before mutating. This is a separate SPEC — out of scope here.

**Recommended:** (a). r2 explicitly drops r1's OQ-OWN-2 (which proposed reading target caps mid-dispatch) per codex HIGH-3. The status-quo two-gate model is correct and already implemented: §5.2 adds the data-owner check; the pre-existing Identity-cap check covers grantee-side consent. (b) is a separate future SPEC if the use case appears.

---

**OQ-OWN-6: per-action granularity — should the cap struct grow an `action` field so e.g. "Bob can read notifications but not unsubscribe others" is expressible?**

Today the cap struct is Behavior-scoped (no `action` field), so holding `Behavior.Notifications` cap = full CRUD. CRITICAL-1 reframing makes this explicit in the SPEC.

- **(a) No** — keep cap struct as-is. If finer-grained gates are needed, the right answer is **declare two Behaviors** (e.g. `Behavior.NotificationsReader` exposing `:subscribe` only, `Behavior.NotificationsWriter` exposing `:notify` + admin actions). Each gets its own cap and its own `data_owner/1` return.
- **(b) Yes** — add `action :: atom() | :any` to `%Capability{}`, update `matches?/2` and `cap_for_action/3` and every persistence path.

**Recommended:** (a). The cap struct's shape is intentionally minimal (PR #303 lesson: more fields = more failure surfaces). Splitting a too-broad Behavior into two narrower Behaviors is the structural answer; it composes with the existing system without expanding the cap shape. (b) would touch every cap-touching file and break wire compatibility. The decision is also a P8 / P2 win: "less invented, more assembled" + let-it-crash on the existing shape.

**Trade-off:** (a) means a Behavior author who needs read-vs-write distinction has slightly more boilerplate (two modules instead of one). Existing Behaviors are coarse-grained by convention; no production use case has surfaced where two-level decomposition isn't sufficient.

---

## 9. Non-goals

1. **Does NOT change `Capability.matches?/2` semantics.** Still pattern-matches `kind / behavior / instance / workspace_uri` exactly as today (`apps/ezagent_core/lib/ezagent/capability.ex:105-110`). The data-ownership rule operates at **grant** time, not at **dispatch** time. Step 5.5 is unchanged.
2. **Does NOT change the `%Capability{}` struct shape.** Still six fields: `kind, behavior, instance, workspace_uri, granted_by, granted_at`. No `action` field added (see OQ-OWN-6 rationale).
3. **Does NOT change ETS-backed `CapabilityRegistry` storage.** Subjects + default-grant fns stay where they are. `data_owner_of/2` is a per-call function lookup, not an additional ETS table.
4. **Does NOT touch `Ezagent.Behavior.Notifications.subscribe` / `notification_subscriptions.ex` behavior.** PR #303 just shipped (round-7 ended with a working predicate). PR-OWN-5 will *declare* `data_owner/1` for Notifications but the predicate in `notification_subscriptions.ex` stays as-is; PR-OWN-6 (separate, optional) is the refactor that re-derives the predicate from the registry.
5. **Does NOT add cryptographic delegation tokens.** BEAM same-VM trust model (per PR #303 §"Threat model"). Delegation caps are `%Capability{}` structs stored in slice state; they have no signature; they trust the BEAM process boundary. Cross-node / cross-tenant delegation is a future SPEC.
6. **Does NOT add a `delegation_chain` field to `%Capability{}`.** v1 keeps the existing 6-field struct (per OQ-OWN-2 default). A future SPEC can add this when revocation-chain support is needed.
7. **Does NOT migrate existing caps.** OQ-OWN-3 chooses grandfather-in.
8. **Does NOT consolidate the four cap-mint paths.** Default-grant + admin grant_cap + spawn-path mints + Feishu binding-policy mints all keep their entry points. Only NEW post-SPEC mints flowing through `grant_cap` get the new check.
9. **Does NOT introduce a "read target's caps during dispatch" mechanism.** r1's OQ-OWN-2 (consent-via-target-cap) is conceptually broken because dispatch only reads caller caps (`ctx.caps`). If consent-from-target is ever needed, it requires a separate consent-ledger SPEC (off-band lookup) — explicitly out of scope here.

---

## 10. References to ExternalMirror r3

This SPEC must be approved (PR-OWN-1 + PR-OWN-2 minimum, because r3 needs `Session.owner/1`) before `ExternalMirror r3` starts. r3 uses the `data_owner/1` formalism in its cap design:

- `Behavior.ExternalMirror` (the whole Behavior — actions like `:bind`, `:unbind`, `:replay` are all granted together by the Behavior-scoped cap). `data_owner(session_uri)` returns `Session.owner(session_uri)` (the session creator). Default grant: session owner gets `Behavior.ExternalMirror` cap on their own session at session creation time. Effect: the user who created session S is the only principal who can bind S to an external system without an explicit delegation from them.

This formalism replaces what would otherwise be a hand-written "session-owner predicate" inside ExternalMirror. r3's SPEC will be ~30% shorter because the trust model is fully specified by `data_owner/1` returns.

---

## Appendix A — Cross-references

- SKILL P15 (CapBAC shape, module refs, scope shapes narrow) — `data_owner/1` extends P15 with the *who can grant* dimension.
- SKILL P1 (plugin isolation north star) — plugin Behavior authors implement ONE new callback, not a custom predicate.
- SKILL P2 (let-it-crash) — `data_owner/1` raises if Behavior author returns malformed shape; framework does NOT default-on-error.
- SKILL P3 (single source of truth) — the data owner is the ONLY grantor; no shadow grant paths.
- SKILL P6 (completion claim requires invariant test) — PR-OWN-FINAL ships `data_owner_declared_for_all_test.exs`; that test is the gate.
- ARCHITECTURE Decision Log #133 (User default cap baseline) — kept; `data_owner/1` provides a structural rationale for what was previously a circular-dep workaround.
- ARCHITECTURE Decision Log #137 (scope-bounded cap shapes) — orthogonal; scope shapes narrow `matches?/2`; `data_owner/1` narrows grant authority. r2's `data_owner/1` signature accepts `scope_tuple()` inputs so the two compose cleanly.
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4 — this SPEC is the next layer in the cap formalism stack.
- `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` moduledoc — PR #303 lesson that drove this SPEC.

## Appendix B — Worked example: PR #303 HIGH-3 with `data_owner/1` in place

Today (post-PR #303 round-7, `apps/ezagent_core/lib/ezagent/notification_subscriptions.ex` §"Tightened admin predicate"):

```elixir
defp has_admin_cap?(caps) do
  Enum.any?(caps, fn cap ->
    cap.behavior == Ezagent.Behavior.Notifications and
      cap.workspace_uri == :any
  end)
end
```

With `data_owner/1` in place (after PR-OWN-6):

```elixir
defp can_unsubscribe?(caller_uri, entity_uri, caps) do
  cond do
    caller_uri == entity_uri ->
      true   # self-unsubscribe

    true ->
      # owner of Notifications data for `entity_uri` is `entity_uri` itself
      # (user owns own inbox). Caller can only unsubscribe if they hold a
      # `Behavior.Notifications` cap on entity_uri that was granted_by the owner.
      owner = Ezagent.Behavior.Notifications.data_owner(entity_uri)

      Enum.any?(caps, fn cap ->
        cap.behavior == Ezagent.Behavior.Notifications and
          cap.instance == entity_uri and
          cap.granted_by == owner
      end)
  end
end
```

The "admin predicate" is no longer free-form: it asks "do you hold a cap on this specific inbox, granted by the legitimate owner?" The HIGH-3 failure mode (narrow cross-workspace cap accidentally satisfies admin predicate) is structurally impossible — the cap MUST target this specific inbox AND be `granted_by` the entity_uri (or its delegate), which a wildcard cross-workspace cap can never satisfy.

This is the v2 mental model in one example: predicates dissolve into "the framework already knows who can grant; just check that you hold a legitimate grant on the right data."
