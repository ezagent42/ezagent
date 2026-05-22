# URI Design — current state + open questions

Status: draft for discussion (Allen ↔ uri-design subagent)
Date opened: 2026-05-19
Owner / decider: Allen

The goal is to converge every URI in the codebase to one consistent shape so plugin authors don't have to guess where the "type" lives, where a sub-resource starts, or whether a host means "identity" vs "namespace". The structural rule we already have (`<instance>[/<sub-resource>]`) is sound. What's inconsistent is **what `<instance>` looks like** scheme-by-scheme.

---

## §1 Inventory

Every URI scheme currently constructed or parsed in `apps/`. Columns:

- **Scheme** — `xxx://`
- **Instance shape** — what identifies the Kind
- **Sub-resource?** — does anything append `/...` after the instance
- **Spawned via** — registration mechanism
- **Persisted?** — does it survive a phx restart
- **Defining file** — canonical place that constructs the URI

| Scheme | Instance shape | Sub-resource | Spawned via | Persisted | Defining file (line) |
|---|---|---|---|---|---|
| `agent://` | `agent://<type>/<name>` (PR #131, typed) | `/behavior/<kind>/<action>` | `SpawnRegistry("agent")` → `AgentTypeRegistry` | yes (via Workspace.session_templates) | `apps/ezagent_core/lib/ezagent/agent_type_registry.ex:96` |
| `session://` | `session://<name>` (flat) | `/behavior/<kind>/<action>` | `SpawnRegistry("session")` | snapshot | `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:176` |
| `user://` | `user://<name>` (flat) | `/behavior/identity/<action>` | `SpawnRegistry("user")` | snapshot | `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:71` |
| `workspace://` | `workspace://<name>` (flat) | `/behavior/workspace/<action>` | n/a — created by Workspace API | snapshot | `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:78` |
| `template://` | `template://<class>/<name>[@<hash>]` — TWO host values: `agent` (versionless) and `session` (`@hash`) | `/behavior/...` allowed in principle | `SpawnRegistry("template")` switches on `uri.host` (`agent` vs `session`) | snapshot | `apps/ezagent_domain_chat/lib/ezagent/entity/session_template.ex:136`, `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex:19` |
| `resource://` | `resource://uploads/<filename>` — host is a "namespace" | none today | not a live Kind — pure data ref | filesystem on disk | `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:230` |
| `system://` | `system://bootstrap`, `system://other` (flat sentinel) | none | not spawned — fixed sentinels | n/a | `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:24`, `apps/ezagent_core/lib/ezagent/capability.ex:10` |
| `message://` | `message://<uuid16>` (16 hex chars, auto-gen) | none | not a Kind — opaque ref | yes (messages table) | `apps/ezagent_core/lib/ezagent/message.ex:101` |
| `feishu://` | `feishu://<chat_id>` (e.g. `oc_…`) | `/behavior/chat/<action>` (Receiver Kind) | `SpawnRegistry("feishu")` | ephemeral (rule in DB points at it; spawn on demand) | `apps/ezagent_plugin_feishu/lib/ezagent/entity/feishu_chat.ex:44` |
| `pty-input://` | `pty-input://default` (singleton) | `/behavior/pty/write` | spawned at boot | ephemeral | `apps/ezagent_plugin_cc/lib/ezagent/entity/pty_input.ex:32` |
| `routing-admin://` | `routing-admin://default` (singleton) | `/behavior/routing_admin/<action>` | spawned at boot | ephemeral | `apps/ezagent_core/lib/ezagent/entity/routing_admin.ex:33` |

**Legacy / removed**:
- `curl-agent://<name>` — gone (PR #131 rewrote to `agent://curl/<name>`).
- `agent://<name>` (no type segment) — gone same PR; validate-time error.

**Notes on parse layering** (`apps/ezagent_core/lib/ezagent/uri.ex`):

- `parse!/1`'s `@known_schemes` is `~w(agent session user resource system)` — **5 schemes**.
- Reality has **11+** schemes in use (table above) plus `feishu://` and the singletons.
- So `Ezagent.URI.parse!/1` would crash on `workspace://default`, `template://session/X@hash`, `feishu://oc_xxx`, `message://abcd`, `pty-input://default`, `routing-admin://default`.
- In practice everyone uses `URI.parse/1` (stdlib) directly for these — bypassing the allowlist. The allowlist is, today, partial documentation rather than an enforced invariant.
- `instance/1` and `subresource/1` are scheme-aware via two clauses: `agent://` (path = `/<name>/<sub>...`) vs everything else (path = `/<sub>...`). `template://session/X@hash` happens to work because `subresource("/")` is empty when no further path is present, but if anyone tried `template://session/X@hash/behavior/...` the agent-style 2-segment split would incorrectly take `X@hash` as the name and `behavior/...` as sub-resource — which happens to be correct! — but only by coincidence; the code path is the "non-agent" branch which gobbles the entire path.

---

## §2 Inconsistencies

### 2.1 Authority layout — agent and template have a "type", everyone else doesn't

| Pattern | Schemes |
|---|---|
| `<scheme>://<name>` (host = identity, no sub-namespacing) | `session`, `user`, `workspace`, `message`, `feishu`, `pty-input`, `routing-admin`, `system` |
| `<scheme>://<type>/<name>` (host = type, 1st path seg = name) | `agent`, `template` |
| `<scheme>://<namespace>/<filename>` (host = namespace, 1st path seg = item id) | `resource` |

Three different "what is the host?" conventions. A plugin author writing a new scheme has to read every existing scheme to know which one applies — the convention is implicit.

### 2.2 `template://` overloads the host two ways

- `template://agent/<name>` — host="agent" means "Class is AgentTemplate", versionless.
- `template://session/<name>@<hash>` — host="session" means "Class is SessionTemplate", content-addressed via `@hash`.
- `template://session/<name>:<tag>` — same scheme, but `:tag` instead of `@hash` (mutable pointer; `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:74` mentions it but I didn't find a writer — may be design-only).

So `template://` is doing four jobs at once:
1. Saying "this is a template" (scheme).
2. Distinguishing Kinds within templates (host = "agent" vs "session").
3. Naming the template (1st path segment).
4. Optionally pinning a version (`@hash`) or tag (`:tag`).

That's the same pattern `agent://<type>/<name>` solves with the type segment — except `template://` adds versioning, which `agent://` doesn't.

### 2.3 `resource://uploads/...` uses host as a flat namespace

`resource://uploads/<filename>` has only one namespace today ("uploads"). The shape signals "I might grow more namespaces later" (`resource://snapshots/X`? `resource://logs/Y`?) but none exist. The host segment is doing the same job as `agent://`'s type but it's called something different conceptually ("namespace" vs "type") and there's no `ResourceTypeRegistry` mirror of `AgentTypeRegistry`.

### 2.4 Behavior sub-path: scheme-agnostic in spirit, scheme-specific in code

The sub-resource `/behavior/<kind>/<action>` is universal — every Kind dispatches through it. But its **starting position** in the URI depends on scheme:

- `agent://cc/demo-builder/behavior/chat/receive` — sub-path starts at `/behavior/...` which is path segment 2 (after `/<name>`).
- `session://main/behavior/chat/send` — sub-path starts at `/behavior/...` which is path segment 1 (right after host).

PR-A (PR #132) addressed the **parser** ambiguity with a positional split (the parser knows where the instance ends per scheme). But the **convention** is still scheme-specific: a fresh contributor reading `agent://X/Y/behavior/Z/W` could reasonably guess `Y` is part of the behavior path. The positional split works because of an out-of-band rule (agent has 2 instance segments, others have 1).

### 2.5 Content-addressing only exists for `template://`

`@hash` is unique to SessionTemplate. No other scheme has any version/content addressing. If, say, an Agent Kind ever wanted snapshot-immutable identity (e.g. `agent://cc/demo-builder@v3`), there's no shared convention to lean on — we'd invent it per scheme.

### 2.6 Scheme allowlist drift

`Ezagent.URI.@known_schemes` lists 5; the codebase uses 11. Anyone reaching for `Ezagent.URI.parse!/1` instead of stdlib `URI.parse/1` would hit a phantom failure. This is documentation rot, but it's also the safety net that doesn't catch anything.

### 2.7 Singleton synthetic schemes diverge from instance schemes

`pty-input://default` and `routing-admin://default` are administrative singletons. Their URIs use `default` as a stand-in for "the only one". `system://bootstrap` uses `bootstrap` for the same purpose. Three sentinels, three naming styles.

### 2.8 Class string vs URI type segment carry the same information twice

A workspace template entry looks like (DB shape):

```json
{"class": "cc.agent", "agent_uri": "agent://cc/demo-builder"}
```

The `class` field encodes "cc" again. The pre-PR-D2 split (`cc.pty` vs `cc.channel_instance`) was being collapsed into `cc.agent` because the operator-visible "mode" was scheduled to move into the URI sub-resource (or query string) and out of the class string. So the class string is shrinking as the URI absorbs more semantics. Worth asking: at the limit, does `class` exist at all, or is `agent_uri` self-describing?

### 2.9 Plugin scheme registration is by-scheme, not by-type

`SpawnRegistry.register("feishu", ...)` claims an entire scheme. `AgentTypeRegistry.register("curl", ...)` claims a sub-namespace of `agent://`. So a plugin can choose either model — own a whole new scheme, or add a type under `agent://`. The cc plugin took the type route. The feishu plugin took the whole-scheme route. They face the same architectural choice (a plugin contributing one Kind type that participates in chat) and made different decisions. Both work, but the inconsistency is real.

---

## §3 Open design questions

Each question has a default proposal and the tradeoff against alternatives.

### Q1 — Uniform 2-segment authority: should every scheme adopt `<scheme>://<type>/<name>`?

**Status quo**: `agent://cc/demo-builder` is 2-segment; `session://main`, `user://admin`, `workspace://default` are 1-segment.

**Proposal A (uniform 2-segment)**: All schemes become `<scheme>://<type>/<name>`.
- `session://generic/main` (vs `template://session/main@hash`'s class)
- `user://human/admin`, `user://service/cron-runner`
- `workspace://default/feishu-seed` (where "default" is the only Class today)
- Pro: one rule, mechanically clear.
- Con: more typing for schemes with only one Class today (`session`, `workspace`).

**Proposal B (scheme IS the type)**: Roll back PR #131 — `cc-agent://demo-builder`, `curl-agent://my-deepseek`, keep `session://main` as-is.
- Pro: scheme = type, no nested namespacing needed.
- Con: scheme allowlist grows unboundedly; PR #131 explicitly went the other way. The reason it went the other way (Allen 2026-05-19 03:21): "agent" is the noun a user thinks in; "cc" / "curl" is implementation flavor. Mixing them in the scheme conflates user-facing identity with backend wiring.

**Proposal C (status quo + document)**: Keep current layout. Document the rule as: schemes with multiple implementations of the same noun use `<scheme>://<type>/<name>`; single-implementation schemes stay flat.
- Pro: minimal change.
- Con: every new scheme is a judgment call. The Feishu plugin chose "whole new scheme" because it's a fundamentally different noun from agent; `template://` chose "single scheme, host = class" because templates ARE templates. Either decision works locally; the global picture is harder to teach.

### Q2 — Should `template://` be split or kept unified?

**Status quo**: `template://agent/<name>` (versionless) and `template://session/<name>@<hash>` (versioned) — same scheme, different shape based on host.

**Proposal A (split)**: `agent-template://<name>` + `session-template://<name>@<hash>`. Per Q1-B, scheme = Kind.
- Pro: each scheme has one shape.
- Con: more schemes; "they're both templates" semantically.

**Proposal B (uniform 2-seg)**: Keep `template://<class>/<name>`; require `@hash` always (even for AgentTemplate). Today AgentTemplate is versionless because it's "human-edited" (`apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex:19`). Forcing a hash unifies the shape but loses the human-edited model.
- Pro: every template URI has the same shape.
- Con: AgentTemplate would need a versioning model it doesn't currently want.

**Proposal C (status quo + ban tags)**: Drop the never-implemented `template://session/X:<tag>` shape, document the explicit two-shape rule.

### Q3 — Behavior sub-path: positional vs query string

**Status quo**: `agent://cc/X/behavior/chat/say` — the `/behavior/...` is path, position depends on scheme.

**Proposal A (query string)**: `agent://cc/X?action=chat.say` — sub-resource becomes a query, parser is trivially scheme-agnostic.
- Pro: parser becomes scheme-agnostic. Capability matchers stay positional-on-instance.
- Con: route table syntax (`/behavior/chat/receive`) is everywhere. Big migration. `URI.to_string/1` puts query after path → still readable but different shape.

**Proposal B (always 2-segment authority for instance)**: Same as Q1-A. Then `/behavior/...` always starts at path[1]. No query needed.

**Proposal C (status quo + positional split)**: Already done in PR-A (PR #132). The parser is correct. The only cost is the implicit per-scheme rule.

### Q4 — `resource://` namespace: real generalization or de facto singleton?

**Status quo**: Only `resource://uploads/<filename>` exists. The host segment is reserved for future namespaces (`snapshots`, `logs`, etc.) — none exist yet.

**Proposal A (commit to namespacing)**: Add a `ResourceNamespaceRegistry` mirror of `AgentTypeRegistry`. Plugins register a namespace + fetcher.
- Pro: lays the groundwork for "any plugin can expose downloadable assets".
- Con: speculative — only one namespace today.

**Proposal B (collapse to flat)**: Drop the host segment — `resource://<filename>` with a flat uploads-only namespace. Add the host back when a second namespace shows up.
- Pro: simplest. Currently the only consumer is admin_live.ex line 230.
- Con: forward-incompatible breakage when (if) we add snapshots/logs.

**Proposal C (status quo + document)**: Keep the shape, document that `resource://<namespace>/<id>` is the convention and any plugin adding a namespace registers an unpacker.

### Q5 — Singleton sentinel naming: `default` vs `bootstrap` vs ???

**Status quo**: `pty-input://default`, `routing-admin://default`, `system://bootstrap`. Three sentinels, two names.

**Proposal**: Pick one. `default` for "the singleton instance of this Kind"; reserve `system://` for capability/audit sentinels where the sentinel name carries meaning (`system://bootstrap`, `system://migration-pr131`, `system://admin-override`).

### Q6 — Plugin scheme contribution: when do you own a scheme vs add a type?

**Status quo**: implicit. Feishu owns `feishu://`. Cc and Curl share `agent://`.

**Proposal**: Document the rule as a triangle. A plugin should:
- Own a scheme when its Kind is a distinct **noun** from anything in core (e.g. `feishu://` is a chat-platform receiver, not an agent).
- Add a type under an existing scheme when its Kind is a **flavor** of an existing noun (e.g. `agent://cc/...` is a flavor of agent).
- Anything else (e.g. plugin-supplied templates, plugin-supplied resources) extends an existing namespace via a sub-registry (TemplateRegistry, ResourceNamespaceRegistry).

This is the **plugin isolation north star** rule made specific to URIs.

### Q7 — `@hash` content addressing: only template, or extend?

**Status quo**: `template://session/X@hash` is the only content-addressed URI. Snapshot URIs, message URIs, agent URIs are all opaque identity (UUID or human name).

**Proposal A (extend to other versioned things)**: Allow `<scheme>://<type>/<name>@<hash>` anywhere a Kind has a content-versioned identity (future: blueprint snapshots, frozen agent configs).

**Proposal B (status quo)**: Keep `@hash` template-only; it's the only Kind whose identity is its content.

### Q8 — Should `Ezagent.URI.@known_schemes` be the source of truth?

**Status quo**: It lists 5 schemes; reality has 11+. It's documentation drift.

**Proposal A (close the loop)**: Have `SpawnRegistry.register/2` also call `Ezagent.URI.register_scheme/1`. The allowlist becomes a runtime ETS table fed by plugins. `Ezagent.URI.parse!/1` consults it. Singletons like `pty-input` register themselves at boot.

**Proposal B (delete the allowlist)**: It catches nothing — remove it from `parse!/1` and just delegate to stdlib `URI.parse/1`.

---

## §4 Discussion log

(Discussion appended here as it progresses. Newest entry at top within this section.)

### 2026-05-19 — Round 2: Workspace X confirmed + routing-admin rethink + feishu confirmation

**Workspace → X (Deployment Unit) ✓**

Allen confirms X and extends the scope hierarchy: `global ⊂ workspace ⊂ session ⊂ user/resource/...`

**Clarifying note on the extension.** "session ⊂ user/resource/..." conflates two ideas worth separating:

- **Scope = "where the rule applies"** — global / workspace / session. These are containment relationships (a session is inside a workspace; a workspace is inside global). A rule scoped to session://Y fires only when the dispatch is "within" Y.
- **Matcher condition = "what the rule matches on"** — caller URI, receiver URI, mention, etc. These filter WHICH dispatches inside a scope fire. `{type: mention, arg: agent://X}` is a matcher; it doesn't need user:// to be a scope level.

Today's `routing_rules.matcher_data` already lets a rule say "fires only when caller is user://Z" via the `from` matcher. So "user/resource as a scope level" is already expressible as a matcher condition WITHIN session/workspace/global. Adding them as scope levels would duplicate.

**Recommendation: scope levels stay 3 (global ⊂ workspace ⊂ session). Per-user / per-resource targeting stays a matcher condition.** Cleaner separation of concerns, no duplication.

If Allen actually wants user-scoped rules (e.g. "user Z has their own private rule table independent of any session"), that's a different feature — call it user preferences or per-user routing overrides — and worth designing as such, not by overloading scope.

**Q5 routing-admin rethink ✓ (Allen's alternative is cleaner)**

Allen: "为什么需要 routing-admin singleton 注入，而不是 `workspace://xxx/routing?action=add_rule&operator=xxx`?"

He's right — the singleton was a v1 expedient. Better model:

- **Workspace-scoped rule mutation**: dispatch to `workspace://X?action=routing.add_rule` (under Q3 query string). Cap check naturally scoped (caller needs `routing.add_rule` cap on `workspace://X`).
- **Global rule mutation**: dispatch to `system://routing?action=add_rule`. `system://` is already in @known_schemes; carries "this is platform-level, requires platform caps".
- **Session-scoped (per S-10)**: dispatch to `session://Y?action=routing.add_rule`.

**`routing-admin://default` synthetic singleton goes away.** Workspace + Session + System Kinds acquire a `routing` Behavior. Cleaner, eliminates a synthetic Kind, makes cap-scoping match the rule's actual scope.

Same logic applies to `pty-input://default` — it's another v1 synthetic singleton. PTY input dispatch could be `agent://cc/X?action=pty.write` (the input goes to the agent it targets, not to a global PTY-input singleton). PR-G candidate.

**Q6 feishu re-shape confirmed ✓**

Allen: "本来的考虑就是最好是向 `user://xxx/?feishu_id=oc_xxx` 发送，从而能复用 user/agent 本来已有的 behavior"

Exactly the target. The shape:

- **Sending to a user via feishu**: `user://X?action=chat.send&feishu_id=oc_xxx` (or, cleaner, the feishu_id is metadata in the Invocation args, not the URI query). The user binding lookup happens in the feishu plugin's outbound Behavior; the URI just identifies the user.
- **Sending to a session via feishu**: `session://Y?action=chat.send`. The session's feishu binding (the chat_id) is a sub-resource OR a UserBinding lookup — feishu plugin handles the side-channel.
- **`feishu://oc_xxx` Kind**: deleted. Receiver Behavior moves to register on User Kind (or Session Kind, for room-targeted receives).

**What this means concretely:**
- No more "feishu_user_bindings table is the source of truth for feishu_id → user_uri." That table stays as-is (a join table), but the URI shape changes.
- Existing routing rules referencing `feishu://oc_xxx` get rewritten by migration to the user/session URI form.
- KindRegistry entries for `feishu://*` go away.

Impact: substantial migration + plugin refactor. Worth doing in PR-F as planned. Risk is BroadcastInvariantTests for the feishu fan-out path — the plugin's Receiver Kind is currently a Process that holds an inbox; if Behavior moves to User, the inbox semantics need re-homing on the User process (which already has Identity Behavior — add Feishu Behavior alongside).

**Q4 (resource:// namespace) — now answerable under X + Q1 outcomes:**

Resources are platform-level downloadable assets that don't belong to any one workspace (uploads, snapshots, logs all cross workspaces). Resource URI shape per Q1: `resource://<type>/<id>`. Today: `resource://uploads/<filename>`. Future: `resource://snapshots/<id>`, `resource://logs/<id>`. ResourceNamespaceRegistry mirroring AgentTypeRegistry — plugin registers a `<type>` + fetcher. Decision A from §3 Q4.

---

### 2026-05-19 — Round 1: Allen's first pass

**Allen's verdicts on the 8 questions:**

| Q | Allen's call | Note |
|---|---|---|
| Q1 — uniform `<scheme>://<type>/<name>` | **Yes, uniform** | "多打几个 default 没问题" (an extra `default` path segment is fine) |
| Q2 — split `template://` or unify | **Unify with `@hash`** | Agent templates should ALSO be versioned |
| Q3 — `/behavior/...` path vs query string | **Query string** | "位置式指定资源，动作是 query" — path identifies the resource, action is a query param |
| Q4 — `resource://` namespace meaning | **Deferred** | Pending workspace discussion below |
| Q5 — singleton sentinel naming | **Open** | Allen: "我没有看明白，routing-admin:// 的路径是怎么回事？" — see clarification below |
| Q6 — plugin scheme vs type | **All plugins are core flavors** | "不应该有任何 plugin 不是 core 的风味" — `feishu://` is the wrong shape. `user://X/feishu/openid` or `session://X/feishu/chat_id` instead |
| Q7 — `@hash` extension | **Templates only** | "其它的好像没有知道内容版本的需要" |
| Q8 — `@known_schemes` as SoT | **Yes, lock down bypass paths** | Allowlist becomes load-bearing |

**Q5 clarification (asked by Allen):** `routing-admin://default` is a **synthetic singleton Kind**. It exists so routing rule mutations can dispatch through the regular cap-check pipeline. Source: `apps/ezagent_core/lib/ezagent/entity/routing_admin.ex:7`:

> "All routing rule mutations (add/delete/disable/enable) now go through `Ezagent.Invocation.dispatch` to `routing-admin://default/behavior/routing_admin/<action>`, which fires the Phase 3d real CapBAC check at dispatch step 5.5."

Dispatch target shape: `routing-admin://default/behavior/routing_admin/<action>`. The `default` is the singleton instance name (since there's only one routing-admin per cluster, the name doesn't carry meaning — it's a placeholder). Same pattern as `pty-input://default`.

Under Q3's query-string outcome, the path collapses to: `routing-admin://default?action=routing_admin.add_rule`. Even cleaner: under Q1's uniform 2-segment + Q3's query, sentinels become `routing-admin://singleton/default?action=...` — `singleton` as the type segment, `default` as the (still placeholder) instance name. Allen's "default vs bootstrap" question reduces to: pick ONE word for "the placeholder instance of a singleton Kind". Recommendation: `default`.

**Q6 follow-through (feishu re-shape):**

If `feishu://oc_xxx` becomes `session://X/feishu/chat_id` (or `user://X/feishu/openid`), then:

- The `feishu://oc_xxx` Receiver Kind shape goes away. Instead, the `session://X` Kind acquires a `feishu` sub-resource path that the feishu plugin's Behavior registers against (mirroring how `/behavior/<kind>/<action>` works today, but for plugin-supplied side-effects).
- The `feishu_user_bindings` table either stays as-is (a join table — fine, no scheme change needed) or its row keys become path-segment fragments under `user://X`.
- Existing `feishu://X` URIs in `KindRegistry`, routing rules, audit log need migration.

**This is a substantial refactor** — separate PR (call it PR-F). The URI design lock-in justifies it: keeping `feishu://` as a top-level scheme cements the "plugin can carve out its own world" anti-pattern.

### Open follow-up — Workspace's role (Allen's deferring Q4 to this)

Allen asks: **"workspace 究竟是做什么的？为什么我们需要独立的 workspace，而不是直接类似 Template 那样，提供 SessionWorkspace, UserWorkspace 这些具体的使用概念，workspace 当作文件夹使用？"**

**What workspace actually does today** (code reading):

`apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:1-22`:
> A `workspace://<name>` URI carries (a) a set of member Entity URIs that should be alive whenever the Workspace is "instantiated", (b) a list of session templates, (c) routing rules scoped to this Workspace. It is the **plugin-isolation north star** in action: a future plugin author adds a new Kind X, declares it in a Workspace template, and on cluster restart their Kind X comes back without any change to ezagent_core.

So workspace serves **two functions**:

1. **Declarative**: "when this instance boots, ensure these entities are alive + these templates are loaded + these rules are installed."  This is the bootable-config role; not a folder.

2. **Routing scope**: at dispatch time, the bound workspace_uri filters which routing rules apply. `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:127-137` resolves session_uri → workspace_uri via WorkspaceRegistry, passes that to the rule evaluator.

Allen's "as folder" framing probes whether workspace is **one concept too many**. Three coherent answers:

**Answer X — keep workspace as a Kind, clarify its role.** Workspace is "the unit of bootable configuration + the routing scope unit". Not a folder; a declaration. Document this. (Status quo with clearer framing.)

**Answer Y — collapse workspace into a tag-only concept.** Drop the Workspace Kind entirely. Replace with a `workspace: string` field on each entity. Rule scoping becomes `routing_rules.workspace = "X"`. The "boot-time guarantee that entities are alive" becomes a separate concept (a Manifest? a Deployment?). Lighter; less ceremony.

**Answer Z — replace workspace with per-type containers (Allen's suggestion).** `SessionWorkspace` holds sessions + their routing. `AgentWorkspace` holds agents that should be alive. `UserWorkspace` holds users (?). Each type has its own organizational unit.

**Trade-offs:**

- Y is the most reductive: workspace becomes a string. Lightest model; question is whether "I want these N agents alive at boot" needs a Kind to express, or just a field.
- Z splits concerns by entity type. Pro: clearer per-type semantics. Con: cross-type concerns (a routing rule that says "messages from this user go to this agent in this session" — which container owns it?) become ambiguous. SessionWorkspace? AgentWorkspace? Both?
- X keeps workspace as the "deployment unit" — clearer if we frame it like Kubernetes Namespace: a tenant boundary for shipped configuration.

**My recommendation: X with explicit re-framing.** Workspace is the **deployment unit** — like a tenant or a project root. SessionTemplate is the **conversation recipe** (one instance gets cloned per spawn). Workspace and SessionTemplate are different shapes:

- Workspace: "this is what should be alive after `mix phx.server`". One per cluster usually; multiple if you tenant by team/project.
- SessionTemplate: "this is what a conversation should look like when instantiated by an orchestrator". Many per workspace.

Under this framing:

- The routing-rule scope hierarchy becomes natural: global ⊂ workspace ⊂ session.
- S-10 (session-scoped rules) lands cleanly.
- SessionTemplate inherits the workspace's routing rules at save time (the working-copy captures them), and fork-instantiates them under the new session_uri scope (per S-10's session_uri column).

But: this is my read, not a decision. Allen's question is structural and deserves an explicit pick before Q4 (`resource://` namespace) gets answered, because if workspace becomes Y or Z, resource:// gets pulled in the same direction.

---

---

## §5 Final spec (v2)

> **Reference relationship**: §5 is the **deep normative spec** for URI shape (15 subsections, parser-enforced). The principle-level index entry — "URI shape — 6-scheme allowlist + 3-segment authority for per-tenant schemes + query-string action" — is **SKILL §Design Principles P20** in `.claude/skills/ezagent-developer/SKILL.md`. P20 points back at §5 as the deep normative spec. Skim P20 for the rule; come here for the parser-level detail (§5.1 authority shape, §5.6 scheme allowlist, §5.15 SPEC v3 3-segment per-tenant, etc.).

Consensus shape after Rounds 1-4 (Allen 2026-05-19). This section is **normative**. Every claim here is a constraint that downstream PRs (#141-#147) and future code must satisfy.

**SPEC v2 supersedes SPEC v1** (PR #139). The v1 → v2 deltas:
- `user://` + `agent://` collapsed into `entity://`
- `message://` scheme deleted (messages have plain string `id`, not URI)
- Agent flavor moves from URI type segment to free-form name prefix
- AgentTypeRegistry (PR #131) removed; Template owns kind_module wiring
- 8 schemes → 6 schemes

### §5.1 Authority — uniform 2-segment, scheme-defined type axis

Every Ezagent URI has the same authority shape:

    <scheme>://<type>/<name>

- `<scheme>` is a registered Ezagent scheme (see §5.6).
- `<type>` is the value on this scheme's **type axis**. Each scheme defines its own type-axis semantics (§5.6 table). Some axes are closed/registered (`entity`'s axis = {`user`, `agent`}), others free-form per-instance (`workspace`'s axis = tenant name).
- `<name>` is the instance identity within `<scheme>/<type>`. UUIDs, human names, flavor-prefixed names — opaque to the parser.

**Forbidden**:
- 1-segment authorities (`user://admin` without the type — `entity://user/admin` is the canonical form).
- 3+ segment paths (`entity://agent/cc/<name>` is wrong; use `entity://agent/cc_<name>`).
- Per-plugin top-level schemes (§5.6).

### §5.2 Sub-resource — query string for action; path is identity

Action invocation uses a query parameter, not a path suffix:

    <scheme>://<type>/<name>?action=<behavior>.<action>

- `?action=<behavior>.<action>` selects the Behavior + action to invoke (e.g. `?action=chat.send`).
- Path stays the identity. The previous `/behavior/<kind>/<action>` syntax is removed entirely by PR #146 — no transitional shim.
- Args to the action travel in the Invocation struct, NOT in the URL.

**Path attributes (`/quota`, `/acl`) are NOT allowed.** Such attributes become Behaviors on the Kind, accessed via `?action=quota.get`.

### §5.3 Content addressing — templates only

Templates carry a `@<hash>` suffix on the name segment:

    template://session/<name>@<hash>
    template://agent/<name>@<hash>

This is the ONLY sanctioned use of `@<hash>`. Other Kinds use opaque identity.

### §5.4 Scope hierarchy — global ⊂ workspace ⊂ session

Routing rules are scoped to exactly one of three levels:

| Scope | `routing_rules` column shape | Where rules apply |
|---|---|---|
| Global | `workspace_uri IS NULL`, `session_uri IS NULL` | Every dispatch in the cluster |
| Workspace | `workspace_uri` set, `session_uri IS NULL` | Every dispatch in any session bound to this workspace |
| Session | `workspace_uri IS NULL`, `session_uri` set | Every dispatch in this session |

Rules COMPOSE additively at dispatch time. **Matcher conditions** (`caller = entity://user/Z`) are SEPARATE from scope and live in `matcher_data`. Per-user filtering is a matcher condition, not a scope level.

### §5.5 Workspace = Deployment Unit (not folder, not container)

A Workspace is the **bootable configuration unit** — declares what entities should be alive and what templates/rules should be installed after `mix phx.server`. Analogous to a Kubernetes Namespace.

Workspace is NOT a folder, NOT a container that owns its members (sessions can unbind/rebind), NOT per-type (one Workspace Kind, not Per-Entity-Type-Workspace).

Most clusters have ONE Workspace. Multi-tenant deployments have N (where N = number of tenants).

### §5.6 Scheme allowlist — 6 schemes, `@known_schemes` as SoT

`Ezagent.URI.@known_schemes` is the single canonical list. `Ezagent.URI.parse!/1` rejects URIs whose scheme is not in the list (PR #145 enforces this at parse-time; no escape hatch).

| Scheme | Purpose | Type-axis semantics | Today's values |
|---|---|---|---|
| `entity://` | Dispatch-able actor identities | **closed set**: entity sub-kind | `user`, `agent` |
| `workspace://` | Deployment units | **free-form**: tenant name | `default` (single-tenant v1) |
| `session://` | Chat rooms | **free-form**: source template name | template name (e.g. `cc-orchestrator`), or `adhoc` |
| `template://` | Content-addressed recipes | **closed set**: template class | `agent`, `session` |
| `resource://` | Platform addressable assets | **registered per namespace** | `uploads` (future: `snapshots`, `logs`) |
| `system://` | Platform sentinels | **registered per sentinel** | `routing` (future: `bootstrap`, `migration-<id>`) |

**Deleted from v1**:
- `user://` — merged into `entity://user/<name>`
- `agent://` — merged into `entity://agent/<flavor>_<name>`
- `message://` — replaced by plain string `id` on Message struct (§5.13)
- `feishu://` — never gets back; plugins don't own schemes (§5.8)
- `routing-admin://`, `pty-input://` — synthetic singletons dissolved (§5.7)

**Plugins MUST NOT introduce a new top-level scheme.** Plugin Kinds are either:
- A new value under an existing scheme's type axis (only sometimes — agent flavor is free-form, not a registered value).
- A side-channel Behavior on an existing entity (no URI; metadata in the entity's slice — §5.8).

### §5.7 Synthetic singletons — dissolved

`routing-admin://default` and `pty-input://default` are deleted:

- **Routing rule mutation** dispatches to the rule's actual scope-owning Kind:
  - Workspace rules → `workspace://default/X?action=routing.add_rule`
  - Session rules → `session://<template>/Y?action=routing.add_rule`
  - Global rules → `system://routing/default?action=add_rule`
- **PTY input** dispatches to the target agent: `entity://agent/cc_X?action=pty.write`.

Workspace, Session, System, and the Agent Behavior pipeline each acquire the relevant action. Cap check naturally scopes to the rule's actual target.

### §5.8 Plugin side-channel rule (feishu et al. — no owned schemes)

A plugin connecting Ezagent to an external system (Feishu, Slack, etc.) MUST NOT own a top-level scheme. Pattern:

- Register a Behavior on the existing core Kind (User for per-user channels, Session for per-room channels).
- Store external-system identifier (feishu_open_id, slack_user_id) as metadata — entity slice or side join table.
- Receive + send through the core Kind's existing dispatch path.

Concrete Feishu target shapes:

- Send to user via Feishu: `entity://user/<name>?action=chat.send` with `feishu_id` in Invocation args.
- Send to room via Feishu: `session://<template>/<name>?action=chat.send`; feishu plugin's outbound side-channel resolves the room's chat_id binding.

`feishu://oc_xxx` Kind deleted (PR #143). No transitional URI shim.

### §5.9 Resource — flat URI; soft workspace binding via slice field

`resource://<type>/<id>` (e.g. `resource://uploads/<filename>`).

- URI is always flat (2 segments).
- Soft workspace binding via the resource's slice `workspace_uri` field. Dispatch reads it for quota/ACL/cleanup. URI doesn't change.
- Attributes (quota, ACL, lifetime) are Behaviors accessed via `?action=quota.get`, NOT path sub-segments.
- Hard URI-layer scoping (sub-pathing under workspace) deferred until isolation requirements emerge.

### §5.10 Singleton naming — `default`

The canonical name for a singleton instance is `default`. Examples: `workspace://default/main`, `system://routing/default`. `bootstrap` is reserved for cap-bearing sentinels where the name carries meaning (`system://routing/bootstrap` for migration-time variants).

### §5.11 No backward compatibility — clean rebuild

Existing DB data is wiped + rebuilt. No operator shorthand. No legacy URI form accepted. Every URI in CLI input, LV form input, stored data, audit log, KindRegistry, routing matchers — canonical from day 1.

Consequences:
- `Ezagent.URI.parse!/1` rejects un-canonical input. No `default`-injection logic. No 1-segment fallback.
- LV form placeholders show canonical form.
- Migration PRs (#141-#147) carry **no legacy-URI rewrite migrations**. Schema changes + code changes only. Dev DB refresh: `mix ezagent.db.reset` (drops + recreates + reseeds).

### §5.12 Entity:// — user + agent merged

`user://` and `agent://` schemes are deleted. The merged shape:

- **User**: `entity://user/<name>` — `<name>` is the user identity (e.g. `admin`).
- **Agent**: `entity://agent/<flavor>_<name>` — `<name>` carries the flavor convention by prefix (`cc_demo-builder`, `curl_my-deepseek`, `echo_default`). Flavor is FREE-FORM (user-defined at template-creation time); the parser doesn't enforce a set of flavor strings.

The `entity://` type axis is the closed set `{user, agent}`. Adding a third entity sub-kind requires registering it in the parser allowlist (rare event).

### §5.13 Message has no URI

Messages are session-internal data, not dispatchable entities. The `Ezagent.Message` struct's `uri` field is renamed `id` and stores a plain UUID string (no `message://` prefix). Reply-to references store the message id directly. LV stream `dom_id` uses the message id.

This removes `message://` from `@known_schemes` and simplifies the Message ↔ URI parser interaction.

### §5.14 Agent flavor lives in the name + the Template, not in URI type

`entity://agent/<flavor>_<name>` carries flavor as a free-form name prefix. The parser sees `<flavor>_<name>` as one opaque name string.

**Authoritative source for "which Behavior runs this agent"**: the AgentTemplate that instantiated the agent. The template's `kind_module` field declares the Behavior (`Ezagent.Entity.Agent`, `Ezagent.Entity.CurlAgent`, `Ezagent.Entity.Echo`, etc.). The agent's snapshot row carries the same kind_module for restart.

**Consequence**: `Ezagent.AgentTypeRegistry` (PR #131) is deleted. The chat plugin's `entity://` SpawnRegistry fn delegates to the Template that owns the agent_uri — not to a type-keyed lookup table.

Flavor names are operator-convention. `cc_*` for Claude Code agents, `curl_*` for HTTP-API agents, `echo_*` for the testing echo Kind. Future combined-plugin agents can use any convention (`cc+curl_polyglot`); the URI parser doesn't care.

### §5.15 SPEC v3 — Per-tenant URIs carry workspace segment (Phase 9 PR-2 + PR-7)

**Promoted from "SPEC v4 / Phase 10 future work" to in-scope by Allen 2026-05-21** (SPEC amendment 2 in `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md`).

Phase 9 extends the 2-segment authority rule (§5.1) to 3-segment for **per-tenant schemes**:

    <scheme>://<type>/<workspace>/<name>

| Scheme | SPEC v2 (Phase 7) | SPEC v3 (Phase 9) |
|--------|--------------------|--------------------|
| `entity://` | `entity://user/admin` | `entity://user/default/admin` |
| `session://` | `session://default/main` | `session://default/default/main` |
| `template://` | `template://agent/cc-orch` | `template://agent/default/cc-orch` |
| `resource://` | `resource://uploads/x` | `resource://uploads/default/x` |
| `workspace://` | `workspace://default` | **unchanged** (workspace IS tenant root) |
| `system://` | `system://routing/default` | **unchanged** (cross-cutting) |

For `session://`:
- First path segment is template name (unchanged from SPEC v2's `session://<template>/<name>` shape — that "template" was always the host-axis value)
- Second segment is workspace name (new)
- Third segment is session instance name

For `template://`:
- First: template type (`agent`, `session`)
- Second: workspace where the template lives
- Third: template name

For `resource://`:
- First: resource kind (`uploads`, etc.)
- Second: owning workspace
- Third: resource instance

**Why URI-carries-workspace (Option A) not envelope-context (Option B)**:
- URI is self-describing; no out-of-band lookup needed for "which workspace owns this entity"
- Auth tokens carry full URI; tenant context travels with the principal
- Same handle in two workspaces = two distinct entities (clean isolation; matches Keycloak realm-per-tenant model)
- Cap matcher (`Ezagent.Capability.workspace_of/1`) extracts workspace from URI string at O(1) — no ETS lookup

Option B (`%{workspace: ws_uri}` in dispatch envelope) was rejected: ambient context is easy to forget; cap matcher would need 2-key lookup; data leak risk if envelope isn't validated.

**Parser change** (`Ezagent.URI.parse!/1`):
- Accepts 3-segment authority path for per-tenant schemes
- **Rejects** 2-segment forms for those schemes with `ArgumentError: <scheme> URI must include workspace segment`
- Rejects 4+ segments (sub-resource positions reserved per §5.1)
- `Ezagent.URI.instance/1` for per-tenant schemes returns the full 3-segment path stripped of query/fragment
- New `Ezagent.URI.entity_workspace_uri/1` extracts the workspace URI from an entity URI

**`WorkspaceRegistry` demotion**:
- Pre-Phase 9: authoritative source-of-truth for "which workspace owns this session" (`bind/2` was required for dispatch correctness)
- Post-Phase 9: **consistency cache**. Workspace lives in URI directly; `workspace_of/1` extracts structurally
- New invariant test: every WorkspaceRegistry binding MUST equal the workspace segment of its session URI

**Migration strategy** (per §5.11 + `feedback_let_it_crash_no_workarounds`):
- Wipe + rebuild dev DB (no backfill scripts)
- All hardcoded URI strings rewritten (PR-2: 163 files for entity scheme; PR-7: 68 files for session/template/resource)
- No back-compat shim; 2-segment forms raise at parse time

**`workspace://system` exemption**: see SPEC v3 §13 — `workspace://system` is a real workspace (visible: false) whose members get cross-workspace authority by membership (`Ezagent.Capability.cross_workspace?/2`). The bootstrap admin migrates from `entity://user/default/admin` (SPEC v2) to `entity://user/system/admin` (SPEC v3).

**Invariant tests** (CI gates):
- `entities_have_workspace_test.exs` (PR-2) — 2-segment entity URI parse-time rejection
- `all_per_tenant_uris_have_workspace_test.exs` (PR-7) — same for session/template/resource

---

## §6 Migration sequence (v2)

Each PR is independently shippable. **No legacy-URI rewrite migrations** (§5.11); each PR carries schema changes + code changes only.

| PR | Title | Scope | Notes |
|---|---|---|---|
| **#140** | SPEC v2 (this PR) | Rewrite §5+§6 of `uri-design.md` | Doc-only |
| #141 | Entity-agnostic 3-piece (S-1+S-2+S-3) + scheme migration | `Ezagent.Entity.authenticate(uri, secret)`, CLI tokens for any Entity, `current_user_uri` → `current_entity_uri`, AND `user://` + `agent://` → `entity://` | Foundation. Big rename but mechanical. |
| #142 | Scope hierarchy + session-scoped rules + SessionTemplate fork replay (S-9+S-10) | Add `routing_rules.session_uri` column; `spawn_from_template/2` installs template's routing rules under new session_uri; UI unification of /admin/routing with Scope column | Schema additive |
| #143 | Feishu re-shape | Delete `feishu://` scheme + Kind; FeishuReceive Behavior moves to User; outbound dispatch via `entity://user/<name>?action=chat.send` | Significant feishu plugin refactor |
| #144 | Delete synthetic singletons | `routing-admin://default` + `pty-input://default` removed; Behaviors moved to Workspace/Session/System/Agent | Pure delete + add Behaviors |
| #145 | `@known_schemes` runtime ETS + `parse!/1` lockdown | SoT enforcement at parser level; no escape hatch | Locks the 6-scheme set |
| #146 | Query-string action syntax | `/behavior/X/Y` → `?action=X.Y` everywhere — including all docstrings, audit log writes, route table | LARGEST CODE CHANGE |
| #147 | Polish + AgentTypeRegistry removal | S-4..S-8 + delete `Ezagent.AgentTypeRegistry` (no longer needed per §5.14) + Message.uri → Message.id (§5.13) | Cleanup |

**Sequencing rationale**:
- #140 (this PR) is doc-only, lands immediately.
- #141 is foundation. ALL subsequent PRs assume `entity://` exists.
- #142 schema-additive (new column), no breaking.
- #143 deletes feishu plugin Kind — must come after #141 so the User Kind exists to receive the moved Behavior.
- #144 deletes synthetic singletons — orthogonal to feishu; could go before or after #143 but after #142 to ensure routing infrastructure is stable.
- #145 locks down schemes — must come after all scheme deletions (#143, #144) so the locked set is correct.
- #146 is the biggest code change — last so it has the fewest moving deps.
- #147 cleanup — picks up loose ends.

**Cross-cutting**: ARCHITECTURE.md, GLOSSARY.md, IMPLEMENTATION_ROADMAP.md, prototype-design-prompt.md (EN+ZH) get updated alongside the matching code PR. NOT their own PR — they ship with the code change they document. Special exception: ARCHITECTURE/GLOSSARY/ROADMAP gets a comprehensive alignment pass with #141 (the biggest scheme change), with smaller touch-ups in later PRs.
