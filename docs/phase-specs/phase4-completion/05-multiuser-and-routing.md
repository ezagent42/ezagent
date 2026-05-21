# Phase 4 Completion — Spec 05: Multi-user + Routing-table

**Status:** DRAFT for Allen review. NO CODE YET.
**Closes (Multi-user):** Decision #19 (CapBAC cap scopes) production wiring, Decision #24 (Identity Behavior) multi-user instantiation, Decision #81 (admin bootstrap) extended to non-admin Users, Decision #101 (hard-flip cap check) UI surfacing.
**Closes (Routing):** Decision #41 (additive rules) combinator gap, Decision #96 (5-leaf Matcher) and/or/not extension explicitly deferred to "Phase 4+", Decision #97 (Resolver fan-out) admin-editable rule path.
**Companion to:** specs 01–04 in `docs/phase-specs/phase4-completion/`.
**Reading time:** ~12 minutes (largest spec).

---

## 0. Why these two ship together

Allen grouped them. The coupling is shallow but real:

- The routing-table editor lives in admin LV pages. Once non-admin users land on those pages they must see only the rules they're allowed to. That's a **multi-user × routing** crossover point.
- The cap-deny surfacing pattern from Part A (flash_error on `{:error, :unauthorized}`) is reused verbatim in Part B's rule editor.
- Both share the Phase 3d real-cap-check substrate (`Ezagent.Kind.Runtime.authz_check/4` at `apps/ezagent_core/lib/esr/kind/runtime.ex:110-134`). Part A makes that path *fire* in the real UI; Part B *exercises* it from a second admin surface.

Otherwise the subsystems are independent. Each Part has its own decision-points block; implementation order is Part A → Part B (login must exist before per-user rule scoping is meaningful).

---

# Part A — Multi-user / Login

## A.1 Problem statement

Today every LiveView mount hard-codes the caller:

```elixir
# apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex:473-479
defp ctx do
  %{
    caller: Ezagent.Entity.User.admin_uri(),
    caps: Ezagent.Entity.User.admin_caps(),
    reply: :ignore
  }
end
```

Consequences:

1. **The cap check is never exercised in production.** Phase 3d shipped the real `Capability.matches?/2` gate at `runtime.ex:110-134`, but admin's triple-`:any` cap (`Ezagent.Entity.User.admin_caps/0` at `apps/ezagent_core/lib/esr/entity/user.ex:46-57`) grants everything. `[:ezagent, :authz, :denied]` telemetry never fires from the UI. The audit pipeline at `apps/ezagent_core/lib/esr/audit.ex:33-42` listens for it; the codepath is dead in production.
2. **Identity Behavior is single-tenant.** `Ezagent.Behavior.Identity` (`apps/ezagent_core/lib/esr/behavior/identity.ex`) holds per-user caps in `:identity` slice — built for many Users, used by one (admin).
3. **No path to add a User.** No `mix ezagent.user.create`, no /login, no session. Adding a non-admin User would require code-editing `chat plugin Application.start` (where admin is spawned).
4. **Operators have no way to test "deny."** Cannot demo cap differentiation, cannot QA a permission, cannot verify the `:denied` telemetry path before Phase 5 plugins (CC PTY, Feishu) start using caps.

Phase 4 completion needs the full loop: provision User → login → ctx.caller derived per request → cap denial surfaces in UI → audit row written.

## A.2 Design

### A.2.1 User provisioning (`mix ezagent.user.create`)

**Where:** new `apps/ezagent_core/lib/mix/tasks/ezagent.user.create.ex` (parallel to existing `ezagent.routing.add_rule.ex` task pattern).

**Invocation shape:**
```
mix ezagent.user.create user://allen \
    --password 'temp-pw-rotate-me' \
    --caps 'workspace.read,chat.send'
```

**Caps string grammar (string form chosen for CLI ergonomics):**
- `*` → triple-`:any` (admin-equivalent; refuse unless `--allow-allcaps` to prevent accidental admin-clones)
- `kind.behavior` → `%Capability{kind: :workspace, behavior: Ezagent.Behavior.Workspace, instance: :any, ...}`
- `kind.behavior@instance_uri` → instance-scoped (e.g. `workspace.workspace@workspace://main`)
- `kind.*` → kind-scoped, any behavior (Decision #19 `:kind` scope)
- Multiple caps comma-separated

**What the task does (4 steps):**

1. **Parse + validate caps grammar.** Lookup behavior module names via `Ezagent.BehaviorRegistry`; reject unknown atoms early (memory `feedback_let_it_crash_no_workarounds`: fail at user-action time, not at next boot).
2. **Insert SQLite row** into new `users` table (schema A.2.2 below). Password is bcrypt-hashed at insert time; caps stored as JSON-encoded list of cap-shapes.
3. **If the BEAM is running** (interactive `mix ezagent.user.create` against a live node — Phase 4 nice-to-have, see Q-MU-3): also spawn the User Kind via `Ezagent.SpawnRegistry.spawn(URI.parse(user_uri))` so the new principal is live immediately, no restart.
4. **Print confirmation** including the URI and resolved cap shapes.

**No interactive prompts.** All inputs are CLI flags so the task is scriptable / idempotent-friendly.

### A.2.2 `users` SQLite table (new)

**Decision:** *separate* table from any User-Kind snapshot, despite the duplication smell. See Q-MU-2 for the alternative.

Schema:
```
id            integer primary key
uri           string  unique  (e.g. "user://allen")
password_hash string  not null
caps_json     text    not null   -- JSON-encoded [%{kind,behavior,instance,granted_by,granted_at}]
created_at    utc_datetime_usec
updated_at    utc_datetime_usec
```

**Why separate from User-Kind snapshot:**

- The User Kind's `:identity` slice (`apps/ezagent_core/lib/esr/behavior/identity.ex:23-25`) is `%{caps: MapSet.t(Capability.t())}` — runtime shape, MapSet not JSON-native, and caps are *granted* not *configured*.
- The `users` table is **provisioning config**: "these credentials exist and these are the initial caps." Identity Behavior's slice is **runtime state**: "the live admin grant set, possibly mutated by ops."
- Boot flow: plugin Application.start reads `users` table → for each row, `SpawnRegistry.spawn` the User Kind with `initial_caps:` decoded from `caps_json`. Identity Behavior's `init_slice/1` (`identity.ex:49-59`) already handles this exact shape via `args[:initial_caps]`.
- Persistence-wise: User Kind today is `persistence: {:snapshot, :on_change}` (`user.ex:73`). After Phase 4 cap-grant mutation lands, the Kind's snapshot will diverge from `users.caps_json` — at which point `users` is "first-boot seed" and the snapshot is source-of-truth. **For Phase 4, no in-flight cap mutation — `users` stays authoritative.**

**Migration:** add `priv/repo/migrations/<ts>_create_users.exs` creating the table. Insert one row for `user://admin` at migration time so the seed step is data-only (admin's caps come from `User.admin_caps/0` constant; the row's `caps_json` mirrors that constant for symmetry with non-admins).

### A.2.3 Login flow

**Decision:** *controller-rendered login form* (not LiveView) for the login page itself. Reasoning:

- LV-on-login adds a websocket dependency to credential entry — failure mode is worse (websocket can't connect → blank screen) than a plain POST form.
- After login, all admin surfaces are LV.

**New module:** `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`

- `GET /login` → renders a minimal form (controller-side EEx; no LV).
- `POST /login` → reads `user_uri` + `password`; looks up `users` row by URI; `Bcrypt.verify_pass/2`; on success puts `current_user_uri` in Plug session; redirects to `/admin`. On failure, re-renders with `flash[:error]`.
- `DELETE /logout` (also `POST /logout` for non-JS clients) → `clear_session/1` + redirect to `/login`.

**Router additions** (`apps/ezagent_web/lib/ezagent_web/router.ex` after line 24):
```
scope "/", EzagentWeb do
  pipe_through :browser
  get  "/login",  SessionController, :new
  post "/login",  SessionController, :create
  delete "/logout", SessionController, :delete
end
```

**Plug `:require_user`** (new `apps/ezagent_web/lib/ezagent_web/plugs/require_user.ex`):

- Reads `current_user_uri` from session.
- If absent → `redirect(to: "/login")` + halt.
- If present → `assign(conn, :current_user_uri, URI.parse(uri_str))` + continue.

Add this plug to the `:browser` pipeline, but **only inside the scopes that need auth**. The home `/` page (`HomeLive` in `router.ex:22-26`) probably stays public; admin scopes opt in:

```
scope "/", EzagentWebLiveview do
  pipe_through [:browser, :require_user]
  live "/admin", AdminLive
  live "/admin/workspaces", WorkspacesLive
  live "/admin/workspaces/:name", WorkspaceDetailLive
end
```

**LV mount integration:** Phoenix LV already passes `session` to `mount/3` (admin_live.ex:45 currently ignores it as `_session`). New mount derives ctx from session:

```
def mount(_params, session, socket) do
  caller_uri = URI.parse(session["current_user_uri"])
  {:ok, caps} = Ezagent.Identity.list_caps_for(caller_uri)
  socket = socket
    |> assign(:caller_uri, caller_uri)
    |> assign(:caps, caps)
    ...
```

`Ezagent.Identity.list_caps_for/1` is a thin facade (`apps/ezagent_core/lib/esr/identity.ex` — new ~20 LOC) that dispatches `user://allen/behavior/identity/list_caps` and returns the MapSet. This *uses the dispatch path* (so the cap check fires against admin's caps when admin reads its own list_caps — pleasingly symmetric), but read-list_caps is a `:list_caps` Identity Behavior action which any cap-holder can call on themselves (see Q-MU-5 on whether to enforce "only self can read own caps").

**`ctx/0` replacement** (admin_live.ex:473-479):
```
defp ctx(assigns) do
  %{caller: assigns.caller_uri, caps: assigns.caps, reply: :ignore}
end
```
All call-sites updated from `ctx()` to `ctx(socket.assigns)`. Trivially mechanical.

### A.2.4 Cap-deny surfacing in LV

The dispatch path already short-circuits with `{:error, :unauthorized}` (`runtime.ex:131-134`) and emits `:denied` telemetry. The LV side just needs to **render** that result instead of silently logging.

The existing `handle_event` clauses (admin_live.ex:144-294) already pattern-match `{:error, reason}` and set `flash_error`. With real cap differentiation that path becomes live:

- Allen logs in with `chat.send` only.
- Allen clicks "Add member to session" → dispatches `chat/join` → cap check fails (`chat.join` ≠ `chat.send`) → `{:error, :unauthorized}` propagates → flash shows "Add member failed: :unauthorized".
- The `:denied` row also appears in admin's `/admin` audit stream (Allen can't see it; admin can).

**One quality polish:** map `:unauthorized` to a friendlier message in the flash:

```
{:error, :unauthorized} ->
  {:noreply, assign(socket, :flash_error,
    "You don't have permission for this action. Contact admin for cap grant.")}
```

This is a 5-line helper, not a structural change.

**No `/admin/*` route-gate beyond login.** Any logged-in user can hit `/admin`; what they can *do* on it is cap-gated. This matches Decision #81's "admin is structural, not a UI gate" stance.

### A.2.5 Bootstrap & lifecycle

- **Admin always exists.** `Ezagent.Entity.User.admin_uri/0` + `admin_caps/0` are structural per Decision #81; the migration's seed row mirrors them.
- **Admin's password:** seed-time the admin row has a password but no one knows it. Provide `mix ezagent.user.set_password user://admin --password '...'` (or have it print a generated password at first migration — see Q-MU-1).
- **Adding more users:** `mix ezagent.user.create` only. No LV UI for user management in Phase 4 — that's a Phase 5 admin surface. **Listing** users in a read-only `/admin/users` page is a 30-LOC stretch goal — recommend deferring to Phase 5 to keep this PR scoped.
- **Removing users:** out of scope this PR; admin can `DELETE FROM users WHERE uri = ...` manually. Production-grade revoke wiring is Phase 5+.

## A.3 UX walkthrough (Part A)

**Operator (admin):**
1. After migration: `mix ezagent.user.set_password user://admin --password 'admin-pw'` (one-time).
2. To onboard Allen: `mix ezagent.user.create user://allen --password 'allen-pw' --caps 'chat.send,workspace.read'`.
3. Tells Allen the URL + creds.

**Allen (non-admin user):**
1. Visits `/` (logged out) — the home page stays public.
2. Visits `/admin` — `:require_user` plug bounces him to `/login`.
3. Enters `user://allen` + `allen-pw` → POST → redirect to `/admin`.
4. Lands on admin shell with `caller=user://allen`, `caps={chat.send, workspace.read}`.
5. Can compose a chat message (cap `chat.send` matches) — works.
6. Clicks "Add agent to session" — dispatch → `chat.join` cap-check fails → flash: "You don't have permission for this action."
7. Audit log on admin's session shows `denied caller=user://allen target=session://main/behavior/chat/join`.

**Admin in parallel:**
1. Visits `/admin/users` (deferred — Phase 5) or just reads `users` table.
2. Sees Allen's `:denied` in `/admin`'s real-time audit pane.
3. If wanted: `mix ezagent.user.create allen2 --caps '*' --allow-allcaps` to make a second admin.

## A.4 Dev-author experience (Part A)

**Zero impact on plugin authors.** Multi-user is entirely inside `ezagent_web` + `ezagent_core` + chat plugin's Application bootstrap. The plugin-isolation north star (memory `feedback_north_star_plugin_isolation`) holds: a plugin author writes Kinds + Behaviors, never touches login or `users`.

**One contract emerges:** `Ezagent.Identity.list_caps_for(uri)` becomes the canonical way to get a principal's caps from any non-LV code path (Phase 5 Feishu plugin will use this to derive ctx for a Feishu-originated invocation, instead of inlining `User.admin_caps/0`).

## A.5 Decision points — Multi-user

| # | Question | Default if you don't answer |
|---|----------|------------------------------|
| Q-MU-1 | Admin's initial password: **generate-and-print at migration** (one-time secret, must capture) vs **require `mix ezagent.user.set_password` before first login** (zero secret in logs). | Require `set_password` first; migration leaves `password_hash` empty and SessionController refuses login for empty-hash rows. |
| Q-MU-2 | `users` table **separate** from User-Kind snapshot vs **one source of truth** (read caps from Kind snapshot file at login time). Separate is simpler this PR; unified is structurally cleaner long-term. | Separate (this spec). Revisit when Phase 5 brings live cap mutation. |
| Q-MU-3 | `mix ezagent.user.create` on a **live BEAM**: spawn the new User Kind immediately (no restart) vs **require restart** to pick up the new user. Live spawn requires the mix task to connect to the running node or share a code path with the plugin's Application.start. | Live spawn via `SpawnRegistry.spawn/1` if the chat plugin app is started in the mix task's BEAM (it is — `Application.ensure_all_started(:ezagent_plugin_chat)` like the routing task does at `ezagent.routing.add_rule.ex:45`). |
| Q-MU-4 | Auth backend: **bcrypt password** (this spec) vs **opaque token** (`mix ezagent.user.create allen --token X` and user pastes token into a form). Token is simpler crypto but worse UX. | Bcrypt password. `:bcrypt_elixir` is the de-facto Elixir choice. |
| Q-MU-5 | Can a user read **their own** `:identity/list_caps`? Symmetric reading via the cap-checked dispatch path means a freshly logged-in user with `{chat.send}` cap can't call `list_caps` on themselves (no `identity.list_caps` cap). Two options: (a) bake a self-grant (every spawned User gets `%Capability{kind: :user, behavior: Identity, instance: own_uri}` automatically in `init_slice`); (b) bypass cap check for self-list (`Identity.list_caps_for/1` reads the Kind state directly via `:sys.get_state` instead of dispatching). | (a) self-grant. Cleaner semantics, no `:sys.get_state` shortcut in production code. ~5 LOC in `identity.ex:init_slice`. |

## A.6 Test strategy (Part A)

| Test | Location | Asserts |
|------|----------|---------|
| `users` table + `Ezagent.Users` facade unit | `apps/ezagent_core/test/esr/users_test.exs` (new) | create / lookup-by-uri / password verify / cap-decode round-trip |
| Caps parser unit | `apps/ezagent_core/test/esr/capability_parser_test.exs` (new) | `"chat.send"` → correct shape; `"*"` rejected without flag; instance-scoped grammar; bad input fails fast |
| SessionController integration | `apps/ezagent_web/test/ezagent_web/controllers/session_controller_test.exs` (new) | GET form / POST happy / POST bad creds / POST unknown user / logout clears session |
| `:require_user` plug | `apps/ezagent_web/test/ezagent_web/plugs/require_user_test.exs` (new) | bounces unauthed / passes authed |
| **LV cap-deny integration** ★ | `apps/ezagent_web_liveview/test/ezagent_web_liveview/cap_deny_integration_test.exs` (new) | Spawn user with `{chat.send}` only; mount admin_live with that session; submit "Add member" → assert flash contains "permission" + assert `:denied` telemetry fired with `caller=user://allen` |
| Audit row for denied | extend `apps/ezagent_core/test/esr/audit_test.exs` | Trigger denied via dispatch → assert SQLite row with `authz="denied"` |

★ This is the **Part A architectural gate** (memory `feedback_completion_requires_invariant_test`): an end-to-end test where a non-admin login → real cap check at dispatch → denial surfaces in UI + audit. Until this passes, Phase 3d's hard-flip remains theoretical in production.

## A.7 LOC estimate (Part A)

| File | New/Δ | LOC |
|------|-------|-----|
| `apps/ezagent_core/lib/mix/tasks/ezagent.user.create.ex` | New | ~70 |
| `apps/ezagent_core/lib/mix/tasks/ezagent.user.set_password.ex` | New | ~40 |
| `apps/ezagent_core/lib/esr/users.ex` (facade: create/lookup/verify) | New | ~70 |
| `apps/ezagent_core/lib/esr/identity.ex` (`list_caps_for/1` facade) | New | ~25 |
| `apps/ezagent_core/lib/esr/capability_parser.ex` (string → cap struct) | New | ~50 |
| `apps/ezagent_core/priv/repo/migrations/<ts>_create_users.exs` | New | ~25 |
| `apps/ezagent_core/lib/esr/behavior/identity.ex` (Q-MU-5 self-grant) | Δ | +5 |
| Chat plugin `Application.start` (load users → spawn all) | Δ | +20 |
| `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex` | New | ~60 |
| `apps/ezagent_web/lib/ezagent_web/controllers/session_html.ex` + EEx templates | New | ~40 |
| `apps/ezagent_web/lib/ezagent_web/plugs/require_user.ex` | New | ~20 |
| `apps/ezagent_web/lib/ezagent_web/router.ex` (login routes + plug) | Δ | +12 |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/admin_live.ex` (ctx + flash polish) | Δ | +25 |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/workspaces_live.ex` (same ctx shift) | Δ | +10 |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/workspace_detail_live.ex` (same ctx shift) | Δ | +10 |
| **Subtotal impl** | | **~480** |
| Tests (all rows in A.6) | New + Δ | ~220 |
| **Part A total** | | **~700** |

This is above the per-PR red line (Decision #72 ~1100 hard cap for impl+tests). **Recommend splitting Part A into two PRs:** A-prov (users table + mix tasks + Identity facade, no UI changes — ~250 impl + ~110 tests = ~360) then A-ui (controller + plug + LV ctx shift + flash + cap-deny integration — ~230 + ~110 = ~340). Each fits comfortably.

## A.8 Test dependencies (Part A)

- `:bcrypt_elixir` (mix.exs new dep) — only Phase-4-completion dep added.
- `Phoenix.ConnTest` for controller tests (already in `:ezagent_web` test deps).
- `Phoenix.LiveViewTest` for cap-deny integration (already used by `admin_live_test.exs`).

---

# Part B — Routing 表 (Combinators + LV editor + Workspace.routing_rules wiring)

## B.1 Problem statement

Three coupled gaps in the routing subsystem:

1. **No combinators.** `Ezagent.Routing.Matcher` (`apps/ezagent_core/lib/esr/routing/matcher.ex`) ships 5 leaf matchers (`mention/from/text_contains/text_matches/always`). The moduledoc explicitly defers and/or/not to "Phase 4+". Today admins can express "urgent" OR "@oncall" only as **two separate rules** (additive semantics per Decision #41). Real scenarios — e.g. "urgent text AND from cc-builder" — cannot be expressed.

2. **No LV editor for routing rules.** Today rules are added via `mix ezagent.routing.add_rule` (`apps/ezagent_core/lib/mix/tasks/ezagent.routing.add_rule.ex`) only. `WorkspaceDetailLive` (`apps/ezagent_web_liveview/lib/ezagent_web_liveview/workspace_detail_live.ex:160-169`) renders `routing_rules` as a read-only `<pre>` JSON block. Admin can't add/edit/delete rules from a browser.

3. **`Workspace.routing_rules` is dead config.** The Workspace Behavior persists `routing_rules :: [map]` (`apps/ezagent_core/lib/esr/behavior/workspace.ex:11-12,115-117`) and the Loader passes them through to `init_slice` (`apps/ezagent_core/lib/esr/workspace/loader.ex:59`), but **nothing reads them**. `Resolver` queries only the plugin-declared global tables (`MentionRouting`, `SessionRouting` — declared at `apps/esr_plugin_chat/lib/esr_plugin_chat/application.ex:155-158`) via `Application.get_env(:ezagent_core, :routing_tables, @default_routing_tables)` (`resolver.ex:51`). Workspace-scoped rules don't exist as a runtime concept.

The three gaps are coupled because **any LV editor design forces a decision on scope**: is the editor adding to the global `RuleStore` (whose rules apply cluster-wide) or to `Workspace.routing_rules` (whose rules apply only within this workspace)? Choosing one without acknowledging the other ships a confusing surface.

## B.2 Design

### B.2.1 Matcher combinators

**Extension to `Ezagent.Routing.Matcher` type:**

```
@type matcher ::
        # existing 5 leaves (unchanged)
        {:mention, String.t()}
        | {:from, String.t()}
        | {:text_contains, String.t()}
        | {:text_matches, String.t()}
        | {:always}
        # new combinators
        | {:and, [matcher()]}
        | {:or,  [matcher()]}
        | {:not, matcher()}
```

**Evaluator additions to `match?/2`:**

```
def match?({:and, items}, %Message{} = msg), do: Enum.all?(items, &match?(&1, msg))
def match?({:or,  items}, %Message{} = msg), do: Enum.any?(items, &match?(&1, msg))
def match?({:not, item},  %Message{} = msg), do: not match?(item, msg)
```

**Constructors (avoid `Kernel.and/2` collision — use `all_of`/`any_of`/`negate`):**

```
def all_of(items) when is_list(items), do: {:and, items}
def any_of(items) when is_list(items), do: {:or, items}
def negate(item),                       do: {:not, item}
```

Naming rationale: `Matcher.and([...])` would shadow `Kernel.and/2` inside any module that `import`s it, and reads ambiguously. `all_of` / `any_of` / `negate` are non-ambiguous and match `Enum.all?` / `Enum.any?` vocabulary.

**JSON serde additions:**

```
def to_json({:and, items}), do: %{"type" => "and", "items" => Enum.map(items, &to_json/1)}
def to_json({:or,  items}), do: %{"type" => "or",  "items" => Enum.map(items, &to_json/1)}
def to_json({:not, item}),  do: %{"type" => "not", "item" => to_json(item)}

def from_json(%{"type" => "and", "items" => items}) when is_list(items) do
  with {:ok, parsed} <- map_from_json(items), do: {:ok, all_of(parsed)}
end
# similar for or/not
```

`map_from_json/1` is a small helper that folds `from_json` over a list, short-circuiting on first `{:error, _}`. Recursive — depth limit Q-RT-1.

**Mix task parser extension** (`ezagent.routing.add_rule.ex:71-92`):

The current matcher_spec grammar is flat (`mention:URI` / `from:URI` / etc.). Two grammar options:

- **(a) S-expr style:** `and(mention:agent://X,from:agent://Y)` — recursive parens, requires real parser.
- **(b) JSON literal in flag:** `mix ezagent.routing.add_rule Tbl --matcher-json '{"type":"and","items":[...]}' receivers:...` — bypass the spec string entirely for combinators.

Recommendation: **add (b) as `--matcher-json` flag; keep the existing positional spec syntax for leaves.** Hand-typing nested parens is unpleasant; admins composing combinators will paste from the LV editor's preview anyway.

**Backward compat:** existing 5-leaf rows in `routing_rules` SQLite table load unchanged (`to_json`/`from_json` for leaves are untouched). No migration needed.

### B.2.2 Workspace.routing_rules scope decision

Three options for what `Workspace.routing_rules` means at runtime:

**Option α: Workspace-scoped table family.** New `Ezagent.Routing.WorkspaceScoped` declared per-Workspace at Loader-time (key: `(workspace_uri, matcher_tuple)`, value: `[receiver_uri]`). Resolver consults both globals + workspace-scoped. Hard problem: Resolver doesn't know "which workspace is this message in" — there's no `Message.workspace_uri` field. Would need plumbing through `current_session_uri → workspace_uri` reverse-lookup. Significant new index.

**Option β: Global table with implicit workspace prefix.** New `from_workspace(URI)` leaf matcher. Every workspace rule's matcher is auto-wrapped in `all_of([from_workspace(ws_uri), <user matcher>])`. Simpler than α (no new registry table), but requires the same `Message.workspace_uri` field for evaluation. Same plumbing problem, repackaged.

**Option γ: Workspace.routing_rules is config-only; ops separately manages global RuleStore.** Workspace detail page shows `routing_rules` as "rules tagged as owned by this Workspace" — metadata for documentation, NOT a runtime scoping mechanism. All actual routing remains in `RuleStore` global tables. LV editor at `/admin/routing` writes to RuleStore; LV editor on Workspace detail page also writes to RuleStore but tags rows with `workspace_uri` so they appear in the right Workspace's section.

**Recommendation: Option γ.** Three reasons:

1. **Avoids the `Message.workspace_uri` plumbing problem.** Messages today don't carry workspace context; adding it touches every dispatch site that builds a Message. Significant blast radius (memory `feedback_north_star_plugin_isolation` — every dispatch site is a plugin extension point).
2. **Matches multi-user reality (Part A coupling point).** Workspaces in Phase 4 are *cluster-shape config*, not security boundaries. A user with `chat.send` cap on `session://main` doesn't care which Workspace declared the routing — they see messages routed by global rules. If we later want Workspace = security boundary, that's a Phase 5+ scoping primitive that affects more than routing (member visibility, audit access, etc.).
3. **Reversible.** If γ proves insufficient, β can be layered on later by introducing the `from_workspace` matcher without changing the storage shape. α requires a new registry table family — much harder to add later.

**Concrete γ implementation:**

- `RuleStore` schema gains a `workspace_uri` nullable column. NULL = global. Populated = "tagged as owned by Workspace X."
- `RuleStore.list_by_workspace(workspace_uri)` and `RuleStore.list_global()` for the two LV editor surfaces.
- `Resolver` behavior **unchanged** — it still queries all rows from `RoutingRegistry`. The `workspace_uri` column is metadata, not a filter.
- `Workspace.routing_rules` slice becomes a **derived view** ("which rules in RuleStore are tagged with this workspace's URI"). Either:
  - **γ.1** Drop `routing_rules` from Workspace state entirely; Workspace detail LV reads `RuleStore.list_by_workspace(ws.uri)` on mount.
  - **γ.2** Keep `routing_rules` as a write-cache of the rule IDs; on rule mutation Workspace re-fetches.

Recommend **γ.1** — single source of truth (RuleStore), zero cache invalidation. The Workspace's `:set_routing_rules` action becomes a no-op or is deleted (back-compat: keep it accepting `[map]` but log a deprecation; production migration removes it Phase 5).

### B.2.3 LV editor for routing rules

**Two surfaces (both ship in this PR):**

**B.2.3.1 `/admin/routing` — global rules editor (new LV).**

- New `apps/ezagent_web_liveview/lib/ezagent_web_liveview/routing_live.ex`.
- Lists rows from `RuleStore.list_global/0` grouped by `table_name`.
- "Add rule" form: table picker (dropdown of `Ezagent.RoutingRegistry`'s declared tables — read via a new `RoutingRegistry.list_tables/0`), matcher builder (B.2.3.3), receivers (multi-select of known URIs from `KindRegistry.list_all`).
- "Delete rule" button per row → `RuleStore.delete/1` + `RuleStore.load_into_registry/1` to refresh live ETS.
- Router add: `live "/admin/routing", RoutingLive` inside the auth scope.

**B.2.3.2 Workspace detail page (extend existing).**

- `WorkspaceDetailLive` "Routing rules" section (currently `:160-169` read-only JSON pre) → replaced with the same form component but pre-filtered to `RuleStore.list_by_workspace(ws.uri)` and pre-populating `workspace_uri:` on add.
- Same form component (`EzagentWebLiveview.RuleFormComponent`) imported in both pages.

**B.2.3.3 The matcher builder — UI approach.**

This is the hardest UX problem. Three approaches:

- **Approach 1: Nested form.** Each matcher row has a "type" dropdown; selecting `and`/`or` reveals N sub-rows. Phoenix LV nested forms are technically possible but the param shape (`%{"items" => [%{"type" => "mention", ...}, ...]}`) requires careful `inputs_for`/array-of-maps handling. Visual depth gets bad past 2 levels.
- **Approach 2: Textarea + spec-string preview.** Admin types a spec like `and(text_contains:urgent,not(from:agent://bot))`, LV parses on every keystroke and shows a "preview" panel ("Matches: urgent text NOT from bot"). Fast to build, requires admin to learn syntax.
- **Approach 3: Hybrid — simple leaves via form fields; combinators via paste-JSON.** "Add rule" form has the existing 5-leaf shape. For combinators: separate "Advanced (JSON)" toggle that swaps the matcher input for a `<textarea>` with `Matcher.from_json/1` validation on submit + live preview rendering.

Recommend **Approach 3**. Reasoning:

- Most rules will be single leaves (Decision #41 additive semantics already gets you OR for free across rules).
- Admins composing combinators are doing power-user work; pasting JSON from docs/preview is acceptable.
- Nested-form complexity (Approach 1) is not justified for a feature that the Phase 4 demo will exercise lightly. **Deferring guided-builder UI to Phase 5** is explicitly aligned with the spec-01 "stub button" pattern (it's OK to ship CLI-only paths for power features).

JSON validation feedback live as admin types (`phx-change` with `Matcher.from_json/1`) keeps the UX from being completely opaque.

### B.2.4 Cap requirements (multi-user coupling)

Per Part A, non-admin users land on `/admin/routing` and `/admin/workspaces/:name`. The rule-add/delete actions need a cap:

- New cap shape: `%{kind: :_routing_admin_, behavior: ..., instance: ...}` — except routing isn't a Kind. There's no Kind for "routing rules."
- Two real options:
  - **(a) Define a synthetic Kind** `Ezagent.Kind.RoutingAdmin` with one Behavior `Ezagent.Behavior.RoutingAdmin` exposing `:add_rule` / `:delete_rule` actions. Then the cap shape is natural: `routing_admin.routing_admin@*`. Rule-edit goes through dispatch like everything else (cap check fires, audit row written).
  - **(b) Bypass dispatch for rule edits;** add a plain function-cap check `Ezagent.Routing.RuleStore.add/4` does at its entry, looking at ctx.caps for a specific marker cap. Inconsistent with the rest of the system.

Recommend **(a)** — synthetic `RoutingAdmin` Kind. It's ~50 LOC and keeps the dispatch+cap+audit pipeline as the single chokepoint. The "Kind" is virtual (no instance URI other than `routing-admin://global`); the spawn function is trivial; the win is **consistent telemetry and audit** — `:granted` and `:denied` fire from rule edits exactly like every other operation.

**Coupling-point with Part A:** non-admin users can't edit rules until admin grants `routing_admin.*`. Admin's all-caps covers it by default. This is the only place where Part A and Part B share code: a new Kind that exists *because* multi-user exists.

## B.3 UX walkthrough (Part B)

**Admin composes a global rule with combinator:**

1. Admin logs in, visits `/admin/routing`.
2. Sees existing rules grouped by table (`MentionRouting`, `SessionRouting`).
3. Clicks "Add rule" → form appears.
4. Picks table = `MentionRouting`, toggles "Advanced (JSON)" for matcher.
5. Pastes `{"type":"and","items":[{"type":"text_contains","arg":"urgent"},{"type":"not","item":{"type":"from","arg":"agent://bot"}}]}`.
6. Live preview panel shows: "Matches when: body text contains 'urgent' AND sender is NOT agent://bot."
7. Receivers = `session://oncall` (multi-select; one chosen).
8. Submit → `RuleStore.add(...)` + `RuleStore.load_into_registry(MentionRouting)` → row appears in the live list.
9. Audit log shows `:granted` for `routing-admin://global/behavior/routing_admin/add_rule`.

**Admin composes a Workspace-scoped rule:**

1. Admin visits `/admin/workspaces/main`.
2. "Routing rules" section now has an editor (no longer read-only JSON).
3. Form is identical to /admin/routing form, but a hidden `workspace_uri` field is pre-populated and submit goes through `RuleStore.add(..., workspace_uri: ws.uri)`.
4. Row appears in this Workspace's routing list **and** in the global `/admin/routing` list (with a "scope: workspace://main" badge).

**Non-admin (Allen with `chat.send` only):**

1. Allen visits `/admin/routing` → page renders read-only (no "Add" button because cap missing).
2. Allen clicks a hypothetical Delete button (if the UI shows it) → dispatch → cap check fails → flash: "You don't have permission to delete routing rules."

## B.4 Dev-author experience (Part B)

- **`Ezagent.Routing.Matcher` API additions** (`all_of`/`any_of`/`negate`) are pure extensions. Existing plugin code using `Matcher.mention/from/etc.` unchanged.
- **`RoutingRegistry.list_tables/0`** added so the LV editor can populate the table picker — plugin-author-visible (their declared tables show up automatically; no central list to update).
- **No plugin-level wiring changes.** Rule editing remains operator-facing; plugins still only `declare_table` at boot.

## B.5 Decision points — Routing

| # | Question | Default if you don't answer |
|---|----------|------------------------------|
| Q-RT-1 | Combinator nesting depth limit: **unlimited recursion** (fine in pure Elixir; cap_for_action complexity unaffected) vs **hard cap at depth N** (defensive against pathological JSON via /admin/routing paste). | Hard cap at depth 8 in `Matcher.from_json`. Defensive bound; >8 is almost certainly a bug. |
| Q-RT-2 | Workspace.routing_rules scope: **α (workspace-scoped tables)** / **β (global with workspace prefix matcher)** / **γ (config-only metadata)** as detailed in B.2.2. | γ. See B.2.2 rationale. |
| Q-RT-3 | LV combinator UI: **Approach 1 (nested form)** / **Approach 2 (textarea + spec-string)** / **Approach 3 (hybrid form + JSON toggle)** per B.2.3.3. | Approach 3. |
| Q-RT-4 | Synthetic `RoutingAdmin` Kind vs function-level cap check vs **no cap check, admin-only via Part A route gate**. The route-gate option is simplest if we accept "rule editing is admin-only forever." | Synthetic `RoutingAdmin` Kind (option a in B.2.4). Costs ~50 LOC, gains uniform audit + granular cap delegation. |
| Q-RT-5 | Keep `Workspace.routing_rules` slice field after γ ships: **delete entirely** (Phase 5 migration to drop the column) vs **keep, deprecated** (warn on set; ignored at runtime). | Deprecate this PR; delete column Phase 5. Avoids touching the snapshot schema in Phase 4. |
| Q-RT-6 | Should the LV editor support **combinators on day 1** or ship leaf-only and defer combinators to Phase 5? Combinators are the harder LOC slice (~80 of B's ~250 impl). | Ship combinators in editor. Approach 3 keeps the LOC delta manageable; not shipping them means admin still goes to CLI/JSON for the interesting cases. |

## B.6 Test strategy (Part B)

| Test | Location | Asserts |
|------|----------|---------|
| Matcher combinator unit | `apps/ezagent_core/test/esr/routing/matcher_combinator_test.exs` (new) | and/or/not evaluation; constructors; nested combos; JSON round-trip incl. nested; depth-limit enforcement (Q-RT-1); empty list cases (`{:and, []}` → true vacuously? recommend define explicitly) |
| RuleStore workspace_uri column | extend `apps/ezagent_core/test/esr/routing/rule_store_test.exs` | add with workspace_uri / list_by_workspace / list_global / migration runs cleanly with existing rows |
| RoutingRegistry.list_tables | extend `apps/ezagent_core/test/esr/routing_registry_test.exs` | returns all declared tables; respects owner-pid; empty when none declared |
| RoutingAdmin Kind unit | `apps/ezagent_core/test/esr/kind/routing_admin_test.exs` (new) | `:add_rule` action wraps `RuleStore.add`; cap check fires (Part A test pattern reused) |
| **LV rule add round-trip** ★ | `apps/ezagent_web_liveview/test/ezagent_web_liveview/routing_live_test.exs` (new) | Mount `/admin/routing` as admin → submit leaf rule → assert row in RuleStore + appears in live list; submit combinator JSON → same assertion; submit invalid JSON → flash error, no row written |
| **Workspace-scoped rule round-trip** | extend `apps/ezagent_web_liveview/test/ezagent_web_liveview/workspace_detail_live_test.exs` | Add rule via Workspace detail form → row has `workspace_uri = ws.uri` → appears in both /admin/routing global list (with scope badge) and Workspace's local list |
| Combinator e2e | `apps/esr_plugin_chat/test/integration/combinator_routing_test.exs` (new) | Build `all_of([text_contains("urgent"), negate(from("agent://bot"))])` → persist via RuleStore → load_into_registry → dispatch a matching message → Resolver returns expected receivers; a non-matching message → empty |

★ The LV rule-add round-trip is **Part B's architectural gate** — proves the editor → SQLite → ETS registry → Resolver path closes the loop. If this passes, the rule-management UX is genuinely landed.

## B.7 LOC estimate (Part B)

| File | New/Δ | LOC |
|------|-------|-----|
| `apps/ezagent_core/lib/esr/routing/matcher.ex` (combinators + JSON + constructors) | Δ | +60 |
| `apps/ezagent_core/lib/esr/routing/rule_store.ex` (workspace_uri column + list_by_workspace/global) | Δ | +35 |
| `apps/ezagent_core/priv/repo/migrations/<ts>_routing_rules_workspace_uri.exs` | New | ~15 |
| `apps/ezagent_core/lib/esr/routing_registry.ex` (`list_tables/0`) | Δ | +10 |
| `apps/ezagent_core/lib/esr/kind/routing_admin.ex` + Behavior + spawn fn | New | ~80 |
| `apps/ezagent_core/lib/mix/tasks/ezagent.routing.add_rule.ex` (`--matcher-json` flag) | Δ | +25 |
| `apps/ezagent_core/lib/esr/behavior/workspace.ex` (deprecate `:set_routing_rules`) | Δ | +5 |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/routing_live.ex` | New | ~150 |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/components/rule_form_component.ex` | New | ~110 |
| `apps/ezagent_web_liveview/lib/ezagent_web_liveview/workspace_detail_live.ex` (replace pre with editor) | Δ | +30 |
| `apps/ezagent_web/lib/ezagent_web/router.ex` (`/admin/routing` route) | Δ | +1 |
| **Subtotal impl** | | **~520** |
| Tests (all rows in B.6) | New + Δ | ~240 |
| **Part B total** | | **~760** |

Part B is also above the per-PR red line. **Recommend splitting Part B:**

- **B-matcher** (combinator AST + JSON + tests + mix task flag): ~110 impl + ~80 tests = ~190
- **B-store** (RuleStore workspace_uri + RoutingAdmin Kind + tests): ~135 impl + ~60 tests = ~195
- **B-ui** (RoutingLive + RuleFormComponent + WorkspaceDetail extension + e2e tests): ~290 impl + ~100 tests = ~390

B-ui is still hefty; if it crowds the cap, the Workspace-detail integration can defer to a B-ui-2 PR.

## B.8 Test dependencies (Part B)

- No new deps. Phoenix.LiveViewTest, Ecto sandbox, telemetry-test already wired.

---

# 3. Combined picture (Multi-user × Routing)

## 3.1 Coupling points

| Point | Description |
|-------|-------------|
| **Login → ctx → routing edit** | The routing editor's cap check fires the Phase 3d `:denied` path. Without Part A, you can't test "non-admin can't edit rules" in production. |
| **Synthetic `RoutingAdmin` Kind** | Only exists because we want delegate-able rule-edit caps. Without multi-user there's no value in a cap-protected rule editor (admin can edit everything anyway). |
| **Workspace = doc, not security boundary (γ)** | Phase 4 Workspace is cluster-shape config; rule scoping = metadata. Phase 5+ may revisit if "Workspace as security boundary" becomes a requirement — but that's a Part-A-shaped decision (member visibility / cap-by-workspace), not a Part-B problem. The honest report: **per-workspace rule visibility is partly a multi-user concern**, currently parked under γ as "all logged-in users see all rules; UX badge shows which workspace 'owns' each row." If that's wrong we re-do scoping in Phase 5. |
| **Audit storyline** | Part A + Part B together produce the demo-able story: "Allen logs in → tries to edit a rule → gets denied → admin sees `:denied` in audit log." Either part alone is incomplete. |

## 3.2 PR sequencing recommendation

Six PRs total, ordered by dependency:

1. **A-prov** (users table + mix tasks + Identity facade)
2. **A-ui** (controller + plug + LV ctx shift + cap-deny integration)
3. **B-matcher** (combinator AST + JSON + mix task flag) — parallelizable with A-* once A-prov merges
4. **B-store** (RuleStore workspace_uri + RoutingAdmin Kind) — depends on A-prov (uses caps)
5. **B-ui** (RoutingLive + RuleFormComponent + WorkspaceDetail editor) — depends on A-ui + B-matcher + B-store
6. **(optional)** B-ui-2 if B-ui crowds the LOC cap

Total LOC: ~1460 (impl) + ~460 (tests) = **~1920** across 5–6 PRs. Average per PR ~320 — well inside the comfort budget.

## 3.3 Architectural gate (combined)

Per memory `feedback_completion_requires_invariant_test`, this phase ships an **invariant test** that proves multi-user + routing genuinely lands:

> `apps/esr_plugin_chat/test/integration/multiuser_routing_invariant_test.exs` (new):
> 1. Create user `user://demo` with caps `{chat.send}` only.
> 2. Spawn the User Kind via `SpawnRegistry.spawn`.
> 3. Build an Invocation with `ctx.caller = user://demo, ctx.caps = list_caps_for(user://demo)` targeting `routing-admin://global/behavior/routing_admin/add_rule`.
> 4. Dispatch → assert `{:error, :unauthorized}` + assert `:denied` telemetry fired with `caller=user://demo` + assert audit SQLite row exists.
> 5. Build the same Invocation with admin's caps → dispatch → assert `:ok` + rule appears in RuleStore.

If this fails, neither subsystem is genuinely landed.

---

# 4. Glossary / Decisions touched

**Multi-user:** Decision #19 (cap 3-tier scope — used by the caps parser grammar), #24 (Identity Behavior — provides the slice contract for non-admin Users), #81 (admin bootstrap — extended with provisioning for non-admin), #82 (stub→real flip — UI now exercises the real path), #101 (hard-flip invariant — Part A's cap-deny integration test extends the runtime_phase3d gate).

**Routing:** Decision #41 (additive rules — combinators add intra-rule composition without breaking inter-rule additivity), #71 (plugin boundary — Matcher additions stay in core because they read core Message), #95 (RoutingRegistry owner-pid — `list_tables/0` respects this), #96 (Matcher 5-leaf — explicitly extended this PR), #97 (Resolver fan-out — unchanged; combinators happen inside Matcher.match?/2 below Resolver).

---

# 5. Migration / backward compat

| Scenario | Behavior |
|----------|----------|
| Existing 5-leaf rules in `routing_rules` table | Load unchanged. `to_json/from_json` for leaves untouched. |
| Existing rules with `workspace_uri` NULL after migration | All rows backfilled NULL (= global) by migration default. No data loss. |
| Existing call to `Ezagent.Workspace.set_routing_rules/2` | Logs deprecation warning, no-op on RuleStore (writes to Workspace slice only — slice-only persistence harmless until column dropped Phase 5). |
| Existing chat plugin Application.start (no users table read) | Add migration runs first; chat plugin reads `users` table after admin row is seeded. Boot ordering: ecto repo → migration → chat plugin Application.start. |
| Anonymous browser hitting `/admin` | Bounced to `/login`. Was: rendered with admin caps. **Behavior change for anyone running on localhost without auth — call this out in PR description.** |

---

# 6. What worries me (read this last)

1. **Login behavior change is the riskiest UX delta.** Today every dev who runs `mix phx.server` lands on `/admin` as full admin. After this PR they need to remember a password. Mitigation: dev-mode shortcut env var `EZAGENT_DEV_AUTOLOGIN=user://admin` that bypasses `:require_user` (only in `:dev` mix env). ~10 LOC. Should this be in scope or out of scope? **Suggest in scope for A-ui PR.**

2. **The `Ezagent.Identity.list_caps_for/1` self-grant (Q-MU-5 option a) is subtle.** Auto-adding a self-cap to every spawned User means the User's `:identity/list_caps` action is always callable by themselves. Fine for caps reading. But it sets a precedent: "every Kind has implicit cap on itself." Phase 5 might want this for other Behaviors too (e.g. a User can always set their own avatar). **Flag this as a pattern that will recur**, not a one-off.

3. **Option γ for routing scope is "right for now, possibly wrong for Phase 5."** If Phase 5 decides Workspaces are security boundaries, we'll re-do rule scoping (the metadata column becomes a real filter). The migration is mechanical (add a query filter, deprecate the badge). Not a Phase 4 blocker, but worth Allen confirming the directional bet is OK.

4. **The synthetic `RoutingAdmin` Kind is a new pattern.** It's a Kind that exists purely as a cap-check chokepoint — no real state, no real lifecycle. Spawn at boot, never persists, never receives messages from outside admin LV. Risk: this pattern proliferates ("synthetic Kind for every admin surface"). Counter: it might be the right pattern — every admin surface deserves the dispatch+audit pipeline. **Worth a glossary entry once landed.**

5. **Approach 3 (B.2.3.3) for combinator UI is a punt.** Real form-builder UX needs design work (nested visual blocks, drag-to-reorder). Pasting JSON is a workaround. If admin combinator usage is heavy in Phase 5 demos, this will need investment. **Flagged as Phase 5 polish in the PR.**

6. **LOC totals (~1900 across 5-6 PRs) is ambitious for "Phase 4 completion."** Realistic timeline assumes Allen pre-approves the decision matrix before any PR opens — otherwise re-spec churn doubles the cost. **The decision points sections are deliberately exhaustive so this can happen as one back-and-forth, not six.**

---

**END SPEC.** Awaiting Allen's answers to Q-MU-1…Q-MU-5 and Q-RT-1…Q-RT-6 before A-prov PR opens.
