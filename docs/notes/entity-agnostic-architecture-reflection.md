# Entity-Agnostic Architecture — Reflection

Companion to `docs/notes/prototype-design-prompt.md` §1, which (revised 2026-05-19) re-states the four-point ezagent thesis with **entity-type-agnostic** as point #1.

This reflection asks the engineer-facing question: **where does the current codebase actually live up to that principle, and where does it not?** All citations point at the live tree on branch `chore/todo-uri-canonical` (HEAD = 0fbd267 as of 2026-05-19).

---

## §1. The principle

From the revised designer brief (`docs/notes/prototype-design-prompt.zh_cn.md` §1, Allen's authoritative wording):

> ezagent 是一个 **多智能体编排平台**。四件事最重要：
>
> 1. **实体类型无关。** 无论参与者是人类还是智能体，他们都可以使用同一套界面（人类通过浏览器，Agent通过agent-browser等自动化工具），同一套API，同一套CLI，没有只能人类使用或者只能智能体使用的操作接口。
> 2. **人类与智能体对话。**
> 3. **智能体之间互相对话。**
> 4. **一切都通过 Session 介导。**

Restated for engineering: **no system surface — UI, API, CLI, routing, capability, persistence — may be reserved for one Entity sub-type.** A `user://` and an `agent://` URI are interchangeable everywhere except in narrow places that genuinely model the human/machine distinction (password vs token credential; PTY view vs API view; etc.). Where a surface is human-only or agent-only today, that is an _accident of incrementalism_, not a feature.

The corollary: every time we encode a sub-type split in code, we owe a justification. Most current splits cannot produce one.

---

## §2. Where the codebase IS entity-agnostic

These are the load-bearing pieces — the principle works because they exist.

### 2.1 URI scheme separation is just a routing prefix, not a separate object model

`apps/ezagent_core/lib/ezagent/uri.ex:46` declares `@known_schemes ~w(agent session user resource system)` as a flat allowlist. Every scheme parses through the same `parse!/1` (`uri.ex:53`), splits into `instance/1` (`uri.ex:94`) and `subresource/1` (`uri.ex:166`) via the same positional rules, and is dispatched by the same `Invocation.dispatch/1` (`apps/ezagent_core/lib/ezagent/invocation.ex:80`).

There is no "if scheme == user, do X; if scheme == agent, do Y" anywhere in the dispatch path. The runtime looks up the instance in `KindRegistry` by URI string and delegates to whatever `Ezagent.Kind` is registered there.

### 2.2 Spawn is URI-scheme-keyed, not sub-type-keyed

`apps/ezagent_core/lib/ezagent/spawn_registry.ex:62` — `SpawnRegistry.spawn(%URI{scheme: scheme})` looks up the registered spawn fn for the scheme and returns `{:ok, pid}`. The plugin that owns `agent://` (`ezagent_domain_instance_message` for the User Kind, etc.) is symmetrical with the plugin that owns `user://`. Both register identically:

```elixir
Ezagent.SpawnRegistry.register("agent", fn uri -> ... end)
Ezagent.SpawnRegistry.register("user",  fn uri -> ... end)
```

The Loader at app start iterates `[{:member, URI}]` tuples and calls `SpawnRegistry.spawn/1` without caring whether a member is a User or an Agent.

### 2.3 KindRegistry holds URI → pid uniformly

`apps/ezagent_core/lib/ezagent/kind_registry.ex:42` — `put_new(uri, pid)` is the sole registration entrypoint. It keys on the full URI string (`kind_registry.ex:77`). The registry has no concept of Entity sub-type; it just maps every Live thing's URI to its owning process. `lookup/1` (`kind_registry.ex:60`) and `list_all/0` (`kind_registry.ex:73`) are equally uniform.

### 2.4 Capability check applies uniformly to every dispatch

`apps/ezagent_core/lib/ezagent/kind/runtime.ex:67` — every dispatched action goes through `authz_check(kind_module, action, target, enriched_ctx)`, which calls `Ezagent.Capability.cap_for_action/3` (`apps/ezagent_core/lib/ezagent/capability.ex:227`) and matches against `ctx.caps`. The check has zero knowledge of whether `ctx.caller` is `user://...` or `agent://...`. Admin's wildcard cap (`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:44`) is the only short-circuit, and even that is just a `:any/:any/:any` shape rather than a sub-type bypass.

### 2.5 Session membership is a `members` map of URIs, not two parallel maps

`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:73` — the Chat slice's `members` field is `%{URI => %{online: bool}}`. `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:242` — `invoke(:join, slice, %{member: %URI{} = member_uri}, ctx)` accepts any URI and merges it in without inspecting scheme. Routing fan-out at `chat.ex:130` (`in_session_members = Map.keys(slice.members)`) treats every member identically.

### 2.6 Auto-derived REST API is the entity-agnostic dispatch surface

`apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex:46` — `POST /api/v1/:kind/:action` looks up the Behavior in `BehaviorRegistry`, builds an `Ezagent.Invocation`, and dispatches. Caller identity comes from a bearer token (`api_v1_controller.ex:124`); the token can in principle belong to any User or Agent URI (the lookup goes through `Ezagent.Users.lookup_by_cli_token/1`, see §3.2 for the limitation). Any Entity that can present a token can drive any Behavior — same path, same checks.

### 2.7 CLI is symmetric to the API at the dispatch layer

`apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:99` — `derive_caller/1` resolves caller identity from either a per-process override (set by `EzagentCli.Exec.exec/2` after token auth, `apps/ezagent_cli/lib/ezagent_cli/exec.ex:46`) or the `--as <uri>` flag. Once a caller URI is in hand, the rest of the path is `Ezagent.Invocation.dispatch/1` — identical to the LV path, identical to the API path.

### 2.8 Agent Kind carries the Identity Behavior too

`apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex:57` — `def behaviors, do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Identity]`. Agents and Users share the Identity Behavior, so caps live in the same slice shape for both, and the same `identity/grant_cap` action works against `user://X` and `agent://X` interchangeably.

---

## §3. Where the codebase is NOT entity-agnostic

These are the breakages. Each one is a place where an `agent://` URI cannot do what a `user://` URI can, or vice-versa, without justification.

### 3.1 Login is hard-coded to `user://` and bcrypt passwords

`apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex:65` — `def create(conn, %{"user_uri" => uri_str, "password" => password})` accepts only a URI string + a password. The verification path goes through `Ezagent.Users.verify_password/2` (`apps/ezagent_domain_identity/lib/ezagent/users.ex`), which reads the `users` SQLite table — a User-Kind-only provisioning store (`users.ex:24`: `schema "users" do field :uri, :string ...`).

There is no path for an `agent://curl/bot` URI to log in via `/login`. An agent driving agent-browser would need to either:
(a) impersonate a `user://` URI it has been granted credentials for, or
(b) bypass `/login` and go straight to `/api/v1` with a bearer token.

Path (b) works for API calls but **excludes the entire LV surface** — there is no way for an agent to drive `/admin` LVs because `/admin` requires a session cookie set by `/login`, which only accepts `user://`.

This is the largest principled break in the codebase. The `Ezagent.Users` table itself is a "user" namespace by name and by `users.ex:24` schema.

### 3.2 CLI bearer tokens are stored on Users rows only

`apps/ezagent_domain_identity/lib/ezagent/users.ex:29` — `field :cli_token, :string`. `lookup_by_cli_token/1` (`users.ex:191`) returns `{:ok, user_uri}` only. There is no `agents` table with a `cli_token` column. An agent that wants to drive the API or CLI must therefore borrow a User's token — which conflates the agent's identity with the human's for audit purposes.

`apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex:127` and `apps/ezagent_cli/lib/ezagent_cli/exec.ex:46` both consume the result as `{caller_uri, caller_caps}` and put it straight into `ctx.caller` — but the URI is always `user://...` because that's the only thing the token table can return.

### 3.3 LiveView /admin presumes a `user://` cookie session

`apps/ezagent_web/lib/ezagent_web/live_auth.ex:38` — `on_mount(:require_user, _, session, socket)` reads `session["current_user_uri"]` and assigns it to `socket.assigns.current_user_uri`. The naming alone advertises the bias. Every LV that reads `socket.assigns.current_user_uri` (admin_live, workspace_detail_live, etc.) assumes the value is `user://...`. An agent that drove the cookie-session path (if §3.1 were lifted) would still find LV code that mostly behaves correctly — but the assign name signals the wrong invariant.

The `EzagentWeb.Plugs.RequireUser` plug (`apps/ezagent_web/lib/ezagent_web/plugs/require_user.ex:15`) shares the bias.

### 3.4 Mention dropdown lists `agent://` URIs only

`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:512` — `list_session_agent_uris/1` filters `read_session_members(session_uri) |> Enum.filter(&String.starts_with?(&1, "agent://"))`. The compose dropdown at `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin/chat_window.ex:75` is fed from that list, so a human in a multi-human Session cannot `@mention` another human via the UI even though the Routing layer (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:130`) and the matcher DSL have no such restriction.

### 3.5 Floating-agent and Agents pages are agent-only by name

`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:520` — `list_floating_agents/0` filters `String.starts_with?(uri_str, "agent://")`. `/admin/agents` (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agents_live.ex`) shows only `cc.agent` rows. There is no `/admin/entities` or `/admin/live` analogue that surfaces every URI in `KindRegistry` regardless of sub-type. The Users page (`/admin/users`) is structurally different — it manages provisioning rows, not live presence — so a human asking "who is alive right now?" has no surface that answers symmetrically for both sub-types.

### 3.6 `--as` flag in the CLI is gated behind an env var, but only for User URIs in practice

`apps/ezagent_cli/lib/ezagent_cli/dispatch.ex:113` — `EZAGENT_CLI_ALLOW_AS=1` gates the `--as <uri>` impersonation flag. The flag accepts any URI string but `derive_other_user/1` (`dispatch.ex:121`) calls `lookup_identity_caps/1` (`dispatch.ex:132`) which only finds caps via `KindRegistry.lookup(uri)` — that works for both sub-types, so the CLI _is_ entity-agnostic _provided_ the agent already has caps. But there is no documented path for an Agent operator to obtain a CLI token in the first place — see §3.2.

### 3.7 The `users` and `agents` provisioning stories are asymmetric

User Kinds are provisioned by `mix ezagent.user.create` writing to the `users` table. Agent Kinds are provisioned implicitly: either via Workspace `session_templates` (operator adds a `cc.agent` row in the LV) or via bridge announce. There is no `mix ezagent.agent.create` analogue that creates a standalone Agent with a credential it can use to log itself in later. The mental model is "Users are accounts; Agents are workers" — which contradicts the entity-type-agnostic principle.

### 3.8 The word "user" leaks into shared code

A grep for `current_user_uri`, `the user`, etc. across `apps/ezagent_web/` and `apps/ezagent_plugin_liveview/` returns dozens of hits. Most are harmless — they're assigns or comments in code paths that genuinely happen to involve a human. But the lexicon trains the next contributor to think User-first. A rename to `current_entity_uri` (and `RequireEntity` plug, etc.) would make the principle structurally visible.

### 3.9 Comments and docstrings still call out a User/Agent split

E.g. `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex:8`: "an Agent is a peer of admin User in the Session — it can send messages [...] and receive messages [...]." The split is described as a near-symmetry. The fact that we have to say "peer" — rather than "another Entity" — reveals that the model is two siblings under an implicit parent that has no Elixir module.

---

## §4. Suggested changes (proposals, do not implement)

Ranked by impact on the principle, not by scope. Scope estimates are rough sketches for prioritisation only.

### S-1. Lift `/login` to accept any Entity URI + matching credential type. (Medium)

**What:** Introduce `Ezagent.Entity.authenticate(uri, secret) :: {:ok, caps} | :error` as a single auth entrypoint. Internally it dispatches by URI scheme: `user://` → bcrypt password check against `Ezagent.Users`; `agent://<type>/<name>` → shared-secret or token check against a new `agent_credentials` table (or the same `cli_token` mechanism, broadened to agents per S-2).

**Why:** Removes the principal break in §3.1. Once `/login` accepts agent URIs, the entire LV surface becomes reachable by agents driving agent-browser, with the same cookie/WS auth path humans use.

### S-2. Make CLI tokens issuable to any Entity URI. (Small-Medium)

**What:** Move the `cli_token` column off `users` into a polymorphic `entity_tokens` table keyed by `entity_uri :: text`. Or, simpler still: add an `agents` table with the same `cli_token` shape and have `lookup_by_cli_token/1` query both, returning a unified `{:ok, entity_uri}`.

**Why:** Removes §3.2. Agents can authenticate to `/api/v1` and to the CLI under their own identity, so audit and `granted_by` lineage reflect reality.

### S-3. Rename `current_user_uri` → `current_entity_uri` across LV + plug surface. (Small, mechanical)

**What:** Rename `EzagentWeb.LiveAuth`'s assign, `EzagentWeb.Plugs.RequireUser` → `RequireEntity`, `session["current_user_uri"]` → `session["current_entity_uri"]`, plus the 30-odd downstream reads.

**Why:** §3.3 + §3.8. Lexicon shapes future contributions. The rename costs an afternoon and removes a structural hint that humans are first-class and agents are not.

### S-4. Expand the mention dropdown to list every member of the current Session. (Small)

**What:** Replace `list_session_agent_uris/1` (`admin_live.ex:512`) with `list_session_member_uris/1` that returns every member URI minus the caller's own. Add an icon column in the dropdown to disambiguate.

**Why:** §3.4. The dropdown is the most visible Entity-agnostic gap in the UI. Routing already supports human mentions; the UI is what stops them.

### S-5. Add a `/admin/live` (or `/admin/entities`) page that lists every KindRegistry entry. (Small)

**What:** Mirror the existing `/admin/agents` page but filter on _no_ scheme — every URI registered in `Ezagent.KindRegistry.list_all/0`. Group rows by Kind, but treat User, Agent, Session, Workspace identically in the list shape (URI, kind module, status dot, link to `/admin/auto/:kind/:uri`).

**Why:** §3.5. Today the operator's mental "what's alive?" question is answered by three separate pages (Sessions sidebar, Floating agents, /admin/agents). A unified Live page makes it clear that the same Entity model holds for all four sub-types.

### S-6. Document and ship `mix ezagent.agent.create`. (Small)

**What:** Parallel to `mix ezagent.user.create user://X --password Y --caps ...`, ship `mix ezagent.agent.create agent://<type>/<name> --token-bootstrap --caps ...` that creates an Agent with a self-owned token. Requires S-2.

**Why:** §3.7. Closes the provisioning-asymmetry gap so a new agent can come into existence the same way a new user does — from a single CLI invocation, not as a side-effect of a Workspace template.

### S-7. Audit + remove "the user" docstring leaks. (Small, ongoing)

**What:** Grep for "the user", "the operator", "a user" in `apps/ezagent_*/lib/**/*.ex` moduledocs and rewrite to "the Entity" / "the caller" where the code is actually sub-type-agnostic. Leave the term in places where the human-only constraint is real (the `/login` controller, the `Ezagent.Users` schema until S-1/S-2 land).

**Why:** §3.9. Smaller cousin of S-3. The point is to make the codebase teach the principle by example.

### S-8. Make the WS reconnect path Entity-aware. (Small once S-1 + S-3 land)

**What:** `EzagentWeb.LiveAuth.on_mount/4` should accept either `user://` or `agent://` URI strings from the session and parse uniformly. This is essentially free once S-1 and S-3 land, but worth calling out because the WS reconnect path historically had its own auth fallback (PR #123).

**Why:** Without this, even after S-1 an agent's LV WebSocket might silently degrade to admin caps on reconnect. The same bug class as PR #123, prevented by the same vigilance.

### S-9. Collapse `/admin/routing` + workspace-detail + (future) session-detail routing surfaces into ONE UI with a Scope column. (Small-Medium)

**What:** The data layer is already unified — one `routing_rules` table with a nullable `workspace_uri` column. `workspace_uri = NULL` is the global rule; non-NULL is workspace-scoped. Dispatch evaluates all global rules + the bound workspace's rules. Today three UI entries (`/admin/routing` global, workspace detail page, and conceptually the session detail page) edit partial views of this one table. Collapse to: ONE editor at `/admin/routing` with a Scope picker (global / workspace://X / session://Y if S-10 lands). Workspace detail and session detail become read-only summaries with a "Rules affecting this surface (N) — edit at /admin/routing →" link.

**Why:** Surfaced by Allen 2026-05-19. Three UI entries for one table fragment the operator's mental model ("if I want a rule for THIS session, which page?"). Unifying mirrors what S-3 / S-4 do for the entity vocabulary: one true source surface, scope-filterable views elsewhere. Bonus: makes Scope a first-class concept, which sets up S-10.

### S-10. Add session-scoped routing rules (`routing_rules.session_uri` column) + fix the SessionTemplate fork gap. (Medium)

**What:** Today `Ezagent.Routing.RuleStore.list/1` rules carry an optional `workspace_uri`. Add an optional `session_uri` column. Scope hierarchy becomes global ⊂ workspace ⊂ session. Dispatch evaluation walks all three layers. SessionTemplate's working-copy slice (built by `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools.ex:build_working_copy/4`) snapshots rules by session_uri; on `spawn_from_template/2` they're replayed under the new session's URI — fork isolation is automatic.

**Why:** Two latent bugs surfaced by Allen 2026-05-19 reading the SessionTemplate code:

  1. **`spawn_from_template/2` doesn't replay routing rules.** `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:spawn_from_template/2` spawns a fresh session URI, binds it to `workspace://generated-sessions`, spawns an orchestrator, and stops. The template's slice contains routing_rules (captured at save time by `build_working_copy/4`), but they are never installed into RuleStore for the new session. Symptom: forks have no routing wiring beyond global rules. Marked TODO in `default_workspace_for_session` ("PR 46 era").
  2. **Even if (1) is fixed, all forks share `workspace://generated-sessions`.** Every `spawn_from_template/2` call hardcodes the same workspace URI. If rules are installed by workspace_uri, fork A's rules land in the same workspace as fork B's — cross-pollution. Session-scoped rules dodge this because each fork gets a unique session_uri naturally.

Path Y (this proposal) keeps workspace as the operator-organized scope and adds session as the fork-scoped scope. Cleaner than Path X (which would require minting a unique workspace per fork — workspaces become per-session noise, defeating their organizational purpose). Ship as its own PR-E so the schema change + migration + spawn_from_template fix land together.

---

## Open question (not a suggestion — flag for Allen)

**Should `user://` and `agent://` collapse into a single `entity://` scheme** eventually, or do we want to keep the schemes as a visible Entity sub-type marker while making every surface treat them identically? Today's URIs encode the sub-type as the scheme; if S-1 through S-8 all land, the sub-type marker is _useful_ (for routing rules, for display) but no longer _structural_. Both choices are coherent. The current revision of the designer brief leaves the schemes split; whether that's the long-term answer is worth a separate brainstorm.

---

## How to use this document

- When a PR touches login, mention-routing, CLI auth, or the cookie session, check it against §3 for new violations or against §4 for opportunities.
- When a new plugin adds a Kind, the structural test for entity-agnosticism is: "can an agent URI dispatch this Behavior the same way a user URI can?" If not, justify it like we justified `cc.agent` keeping a PTY-only mode.
- §4 is a backlog, not a roadmap. Each item is a separable PR. S-1 + S-2 + S-3 together close the load-bearing gap; everything else is polish.
