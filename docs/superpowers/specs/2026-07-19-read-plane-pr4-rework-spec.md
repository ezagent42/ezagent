# Read-plane PR-4 rework — list-plane enumerator gate + authz-contract fixes

**Status:** coordinator spec (Claude), 2026-07-19. Supersedes the first PR-4 attempt (#1466) which codex returned **DO NOT MERGE**. Root cause: the bounded sub-steps each migrated a single reader correctly but **no completeness enumerator gate was run**, so several principal-facing readers were left bypassing the chokepoints.

**Goal:** every principal-facing *list/enumeration* read of sessions, agents, users, or templates, and every *global-registry* read, goes through a caller-authorizing chokepoint — enforced by a gate whose empty-allowlist red build IS the reader worklist.

---

## Part 1 — The authz contracts (coordinator owns; small, precise fixes)

### F2 (HIGH, real bug) — `WorkspaceReads.agents/2` admits cap-scoped non-members
Current: workspace authorization uses `Listing.list_workspaces_for/2`, which includes a workspace when the caller holds **any** concrete workspace-scoped capability (`listing.ex:132` does not restrict kind/behavior/action); and the per-row check (`workspace_reads.ex:244`) admits an agent because **the agent** is a declared workspace member — not because **the caller** has a relationship to it.

**Contract (required):**
- Workspace-authorization for the *shared-roster* branch requires the caller's **actual workspace membership**, not merely holding some workspace-scoped cap. If "member of workspace" is not directly expressible, gate every row by the **caller's own** ownership / manage / member-cap authority over that specific agent, and drop rows where the caller has no such relationship.
- Per-row predicate must evaluate a **caller→agent** relationship, never the agent's own membership.
- Apply the identical correction to `sessions/2` if it shares the same `list_workspaces_for` authorization path (audit it; sessions/2 currently also filters per-row via `SessionReads.authorized?/2`, which is caller-correct — confirm the *workspace-level* gate isn't the coarse `list_workspaces_for`).

### F5 (MEDIUM, real bug) — `OperatorReads` authority too narrow + swallows error
Current: `operator_reads.ex:52` gates on `Identity.admin?/1` = exact equality with the bootstrap-admin URI (`identity.ex:121`). A **promoted** system operator (accepted by `live_auth.ex:110` via `AdminAuthority.admin?/2`) gets `{:error,:unauthorized}` → and `admin_data.ex:205` translates that to an empty table, indistinguishable from "no rows."

**Contract (required):**
- `OperatorReads` accepts the caller's caps/context and authorizes via the **same** `Ezagent.Identity.AdminAuthority.admin?/2` the rest of the system uses (promoted operators included) — not `admin?/1`.
- Propagate `{:error,:unauthorized}` to the caller; the presenter (`admin_data.ex:205`) must **reject the route** (or render an explicit unauthorized state), not coerce to `[]`.

### F6 (MEDIUM, strictness) — DI-loss must strictly drop the row
`workspace_reads.ex:186` makes an unavailable `SessionReads.authorized?/2` evaluate false (good), but `:179` then re-admits the row through the **independent** public-session predicate (`:201`). Not a confidential leak (the row is public), but it violates strict fail-closed.

**Contract:** resolve and validate **all** required session-policy facades before fetching/filtering; if any required predicate dependency is unavailable, return `[]`. A public-session predicate is not a substitute for the membership predicate — both must resolve or the read fails closed.

---

## Part 2 — The list-plane enumerator gate (coordinator builds; the correctness guarantee)

New arch test, sibling to `message_read_chokepoint_boundary_test.exs`. Bans, in the **presenter/web/ui/feishu** tiers, any direct call to a *global/enumeration* read primitive outside the caller-authorizing chokepoints (`WorkspaceReads`, `OperatorReads`, `SessionReads`).

**Banned primitives (the complete set — a substring gate on just `KindRegistry.list_all` is insufficient):**
- `Ezagent.KindRegistry.list_all/0` (live global registry)
- `Ezagent.Ecto.KindSnapshot.list_all/0` (durable global scan)
- `EzagentDomainInstanceMessage.list_sessions/{1,2}` (session enumeration)
- the user-enumeration primitive behind `UserData.list_users` (workspace user scan)

**AST hardening (apply here AND back-port to the message-plane gate — codex check-5 on PR-2):** the matcher must catch evasions the current gate misses —
- root-qualified `Elixir.Ezagent.KindRegistry.list_all` (normalize away a leading `Elixir` segment),
- `import`ed bare `list_all/0` (local call form),
- function captures `&KindRegistry.list_all/0`,
- dynamic `apply(KindRegistry, :list_all, [])` / `apply/3`.
Self-tests must assert each evasion form is caught.

**Allowlist:** starts EMPTY. Running it empty produces the red worklist below. As each reader migrates, it drops off; the gate stays green thereafter and blocks re-introduction.

---

## Part 3 — The reader worklist (empty-allowlist output, hand-verified 2026-07-19)

Migrate every reader to a caller-aware chokepoint. `[me]` = coordinator (authz-sensitive); `[kimi]` = mechanical migration against the red gate.

| # | Reader (file:line) | Primitive | Target chokepoint | Owner |
|---|---|---|---|---|
| 1 | `uri_options.ex:169` build_options (command palette) | KindRegistry.list_all | `WorkspaceReads.sessions/2` + `agents/2` (+ user chokepoint) | kimi |
| 2 | `admin_data.ex:165` kpis | KindRegistry.list_all | `OperatorReads` (operator-authorized) | kimi |
| 3 | `admin_data.ex:225` template_rows | KindRegistry.list_all | `OperatorReads` | kimi |
| 4 | `identity_data.ex:344` entity rows | KindRegistry.list_all | `WorkspaceReads.agents/2` + user chokepoint | kimi |
| 5 | `identity_data.ex:74` → `UserData.list_users` | user scan | new caller-aware user chokepoint | me (contract) + kimi |
| 6 | `user_data.ex:10` list_users (account/security metadata) | Store + scan | new caller-aware user chokepoint | me + kimi |
| 7 | `workspace_plugin_data.ex:237` persisted templates | KindSnapshot.list_all | caller-aware template chokepoint | me + kimi |
| 8 | `workspace_plugin_data.ex:418` live templates | KindRegistry.list_all | caller-aware template chokepoint | me + kimi |
| 9 | `conversation_data.ex:692/725` invite options (dormant users/agents) | snapshot scan | `WorkspaceReads.agents/2` + user chokepoint | kimi |
| 10 | `mention_parser.ex:136` (feishu) mention resolution | KindRegistry.list_all | `WorkspaceReads.agents/2` (mention-scoped) | kimi |
| 11 | `conversation_session_state.ex:17/27` list_sessions/{1,2} | EzagentDomainInstanceMessage.list_sessions | `WorkspaceReads.sessions/2` | kimi |
| 12 | `kanban_share_controller.ex:101` | EzagentDomainInstanceMessage.list_sessions | `SessionReads.members` / `WorkspaceReads.sessions/2` | kimi |

Notes:
- `Ezagent.Workspace.Store.get_by_name/1` is a single-workspace **lookup**, NOT enumeration — do NOT ban it broadly (legitimate callers: `workspace_switch_controller`, `error_cards`, etc.). Only the readers that use it to build a principal-facing **user/member table** (`user_data`, `home_live:176`) are in scope, and they're covered by the user-chokepoint requirement, not a Store ban.
- `home_live.ex:20`/`user_data` doc-comment mentions of `list_all` are comments, not calls — excluded.

---

## Part 4 — Scope decisions (deliberate; track deferrals)

- **F3 router fix** (`/admin/*` under `:require_entity` not `:require_admin`, `router.ex:82/108`; `world_live.ex:802` calls `AdminData.state_for/2` with no admin check): this is operator-plane routing that **overlaps #187**. **DECISION: include in PR-4-rework** — it's the same operator-authz concern that makes `OperatorReads` effective; leaving it out means the OperatorReads gate is deep-linkable-around. Note the #187 overlap in the PR body; #187 remains for the audit/authz/cc_event *streams*.
- **feishu mention_parser (#10):** included — it's a live global agent enumeration reachable per inbound message.
- Nothing else from codex's report is deferred silently.

---

## Acceptance (fail-before / pass-after; these are the invariants the first attempt lacked)

1. **Enumerator gate, empty-allowlist:** red build names exactly the 12 readers above; after migration, green with empty allowlist.
2. **F2 bypass test:** a principal outside workspace X holding one narrow X-scoped cap gets `[]` from `agents/2` (was: full roster).
3. **F5 promoted-operator test:** a promoted (non-bootstrap) operator gets the full registry from `OperatorReads`; an ordinary authenticated non-admin gets `{:error,:unauthorized}` that the route surfaces as unauthorized (not empty).
4. **Command-palette test (F1):** an ordinary member does NOT receive labels/URIs for private sessions/agents they have no relationship to.
5. **Admin deep-link test (F3):** an authenticated non-admin hitting `/admin` / `/overview` / `/admin/templates` is rejected, not shown cross-tenant counts/templates.
6. **User-metadata test (F4):** a same-workspace principal does not receive other users' email/password-presence/confirmation/disablement metadata absent an authorizing relationship.
7. **AST-evasion self-tests:** `Elixir.`-prefixed, imported, captured, and `apply/3` forms of every banned primitive are all caught by the gate.
8. Full verify from umbrella root: `mix compile --warnings-as-errors`, `mix ezagent.check_invariants`, the new gate, and the migrated readers' domain suites.

---

## Re-review addendum (2026-07-19, codex re-review of the rework — 3 items, all landed)

The core authz fixes (F2/F5/F6/F3) and the 12-reader migration were confirmed landed by codex's re-review. Three residual items remained; this addendum records their resolution.

### R1 (REAL LEAK) — per-URI user deep-link gated

`/identities/users/:uri` served any authenticated caller another user's full account/security metadata (email, password-presence, confirmation, disablement) — including cross-tenant. Fixed by:

- **`Ezagent.Workspace.UserReads.user/2`** (new per-URI chokepoint, twin of `users/2`): authorizes BEFORE existence is checked (`{:error,:unauthorized}` is existence-neutral — no cross-tenant existence oracle). Allowed: self, operator (`AdminAuthority.admin?/2`), or a DECLARED member of the TARGET user's home workspace passing the workspace gate (the roster rule applied per-URI). Everyone else (incl. cross-tenant non-members) is denied the row.
- **`UserData.detail_state/4`** routes through it: denied → `user_unauthorized` shell (no account data); missing → `user_not_found`; allowed rows STILL per-field gate every sensitive field via `reveal_metadata?/2`, and carry `can_view_metadata` so the React surface renders a directory-level view (never a negated value) to non-operator viewers. The ungated `UserData.exists?/1` oracle is gone.
- Acceptance: `user_data_detail_test.exs` — member→other (metadata all `nil`), cross-tenant denied, ghost≡real indistinguishable, self/operator full, missing→`user_not_found`.

### R2 — gate inventory completed

Added the three still-existing global/workspace enumerators to the gate's banned set: `EzagentDomainInstanceMessage.list_sessions/0` (global KindRegistry scan), `EzagentDomainInstanceMessage.list_persisted_sessions/1`, `Ezagent.Entity.Agent.list_in_workspace/1`. The re-run empty-allowlist gate flagged **zero** current callers in the four presenter trees (allowlist stays EMPTY; the legal callers — the chokepoints — live outside the scanned tiers by construction).

### R3 — matcher hardened + limitation documented

The AST matcher now also catches qualified dynamic dispatch — `Kernel.apply(Mod, :fun, args)`, `:erlang.apply(Mod, :fun, args)` — and the 2-arity `apply(Mod, :fun)` form (0-arity primitives), with self-tests proving each. **Known limitation (pinned by a self-test, not claimed as covered):** module-variable indirection (`m = Mod; m.fun()`) and `apply` through a runtime module variable are not statically resolvable without flow analysis — the self-test trips if a future matcher upgrade closes the gap.
