# dev-together review — 2026-06-22 (lead: Claude, autonomous close)

End-of-day retrospective for the close of 4 returns, + tomorrow's plan (Allen's
request before AFK). Full per-entry detail + merged SHAs in `stack.md`.

> 2026-06-23 backfill: the original day had a placeholder-only `plan.md`, one
> missing return (`agent-console`), one superseded duplicate world return, and
> three GitHub PRs left open after their code landed through the lead close path.
> This review now records those gaps explicitly. PR #890/#891/#892 were
> comment+closed on 2026-06-23 as subsumed by `main`.

## Ledger accounting (2026-06-23 backfill)

| Item | Status | Evidence |
|---|---|---|
| Original plan | Invalid / placeholder-only | `plan.md` had only the scaffold line and no task ledger. |
| Active returns counted | 4 | `pg-compat-audit`, `world-beautify`, `hello`, `agent-console` (backfilled). |
| Superseded return | 1 | `world-beautification-restructure.md` was an older world-beautify snapshot. |
| Late returns | 3 | `pg-compat-audit` ledger record, `hello`, and `agent-console` all arrived after the nominal 20:00 +08:00 deadline. |
| On-time return but late integration | 1 | `world-beautify` was close-ready before 20:00, but integration completed at 23:52. |
| GitHub PR closure | Fixed on 2026-06-23 | #890/#891/#892 comment+closed as subsumed by lead squash/subsumed main SHAs. |

## What landed on `main` (all 4 returns)

| Return | SHA | gates (all under PostgreSQL) |
|---|---|---|
| pg-compat-audit (PostgreSQL-only) | `db1fb574` | precommit 4577/0 · agent-browser login→world E2E · pg_dump/restore |
| world-beautify #83 (shadcn/typed-slot) | `28a90831` | precommit 4584/0 · vite build · check:mounts · agent-browser shadcn-world E2E |
| hello #891 (@json-render pages) | `d8c4a7f9` | precommit 4611/0 · vite/check:mounts · anon /socialware/customer page E2E |
| agent-console #892 (Phase-0 demo) | `798f46bd` | precommit 4611/0 · /agent-console-demo loads+renders |

Final `main` end-to-end `mix precommit`: **GREEN — 4611 tests, 0 failures** (clean
run on an unloaded machine, `3e600405`).

During close-out, intermittent failures surfaced in `apps/ezagent_domain_external_mirror`
— PG-sandbox `owner … exited` + a timing `assert_receive … 1000ms`. **Proven not
a close regression:** `git diff db1fb574..798f46bd -- apps/ezagent_domain_external_mirror`
is EMPTY (none of wb/hello/agent-console touch that domain — it is pg's, merged
first). They were **load-induced** (surfaced only while the dev `phx.server` +
vite + repeated E2E runs were hammering the box; the 4611/0 runs were on a quiet
box). One was a genuine bug worth fixing: `facade_test.exs` used bare
`ExUnit.Case` (the lone outlier — every other external_mirror DB test uses
`EzagentCore.DataCase`), so it borrowed an unsandboxed connection a sibling
spawn-storm could kill → **fixed by switching it to `EzagentCore.DataCase`**
(`3e600405`, the same remedy pg applied to `repair_orchestrator_test`). The
remaining timing-sensitive ones (`ExternalMirrorWorkerColdRestartTest`) pass on
an unloaded box; flagged in `docs/futures/todo.md` for the external_mirror owner
(don't run the full suite alongside a live phx + vite).

PG backup/restore
verified end-to-end: `pg_dump --format=custom` → fresh DB `pg_restore` → row
counts match (users 3=3, 28 tables); the one ignored `SET transaction_timeout`
is a benign PG-version-skew GUC, data intact.

## Conflict resolutions + decisions (for review / patch)

- **world_live.ex / admin_data.ex (pg ∩ wb ∩ hello, #893 login):** kept pg's
  Ecto `where_workspace/2` + wb's `shape_orchestrator_status/1`; dropped wb's
  stale raw-SQL `workspace_filter_sql/1` (`?1` placeholder → would fail the
  `database_agnostic_guard`). hello carried wb-era versions of admin_data /
  config/dev / endpoint → took main's (pg + #87 cookie/mailer).
- **Conversation.tsx (hello):** took hello's version (its `Page` tab +
  `HelloPagePreview` is a superset of main's wb-only file).
- **world-coordination.md (agent-console):** merged the table (kept #83 detail
  row [now MERGED] + #84 Phase-0 demo row).

## Debt flagged (follow-ups, not blockers)

1. **world_live.ex 1036 > 1000** — wb's UI dispatch regrew it past the
   oversized-module cap (pg had trimmed it via the CallerDisplay extraction).
   Cap-bumped `oversized_modules_gt_1000` 3→4 with an `# arch-cap-bump` reason.
   **Burn-down: re-extract from world_live.ex (mirror pg's CallerDisplay split)**
   — natural owner: zyli/world. (Joins the standing oversized burn-down in
   `docs/futures/todo.md`: session_creator 1071, server 1027, kind 1025.)
   **2026-06-23 status:** resolved on `main` by `ebccf695`; precommit 4611/0;
   oversized cap returned to 3. Do not carry this item into the 2026-06-23 plan.
2. **layout_manager.ex raw `Home.path("world/layouts")`** — wb added a new raw
   Home caller after the resource-unification lockdown. Currently kept as an
   `HomePathExceptions` anchor (line 164). **Proper fix: migrate to `resource://`**
   via FsResolver (the sanctioned chokepoint), like config_dir/uploads did.
3. **customer_app esbuild needs `zod`** — hello added `zod` to
   `apps/ezagent_web/assets/package.json` for the @json-render catalog. A clean
   build must run `mix assets.setup` (npm install) before `esbuild` or the
   customer bundle fails to resolve `zod`. (Not a regression — `assets.setup`
   handles it; flagged so CI/deploy ordering is explicit.)
4. **hello Phase-1+** (real LLM page generation, multi-agent fan-out) is the next
   hello phase; Phase-0 (fixed-spec path) is what merged + was E2E'd.

## Lessons (reinforced this session)

- **Never `git stash` in this repo** — an old `stash@{0}` from a prior session
  resurfaced during a LOC-comparison `stash pop`, corrupted `feishu_adapter.ex`,
  and aborted a commit. Use `git diff <ref>`/`git show <ref>:<path>`, never stash.
- **Background `mix precommit` exit code** — the task-notification "exit 0" is the
  wrapper shell; the authoritative result is the `EXIT=` line written into the log
  (and the `N tests, 0 failures` totals). Two "green" notifications were actually
  red precommits.
- **`--force` is mandatory** before trusting per-app test/compile — a direct
  `mix test` loaded a stale Exqlite `.beam` and threw a `DBConnection.Query`
  protocol error (SQLite vs Postgrex). precommit's `compile --force` is the gate.
- **agent-browser + HSTS** — `world.ezagent.chat` HTTPS-upgrades (HSTS) → blank on
  `:4020`. Use `world.localhost` (matches Phoenix `host: "world."` prefix,
  `*.localhost` auto-resolves to 127.0.0.1, never HSTS-upgraded).
- **Stale-base merges inherit arch-gate debt** — a branch built on an older base
  (wb @ a6fa6db3) passes its own gates but trips main's stricter ratchets on
  merge; resolve via the gates' sanctioned hatches (cap-bump / baseline / fix),
  document each.
- **Cross-BEAM seed must wait for the async snapshot commit** — `mix run` exits
  before the surface/page persists; poll the snapshot until durable before exit
  (the hello page wasn't visible until the seed waited).

---

## Tomorrow's plan (proposed — Allen to confirm/reorder)

Allen's three candidates + my consolidation analysis (he asked: is Agent Console
too complex → fold into a "socialware creator"? + any other `todo.md` merges).

### The unifying idea: **"socialware creator"** as one operator surface

socialware is already the unified session substrate (one Kind + composable
Behaviors + View classes — world-chat, hello, autoservice are all Views on it).
Three of the in-flight threads are really **the same surface** seen from
different angles:

- **Agent Console (#84)** = author/manage socialware sessions (Template Studio
  [cold: create/fork templates], Session Console [hot: members + routing],
  Migrate, Observability). That *is* a socialware creator/manager.
- **world hello化** = world adopting hello's `@json-render` + `Behavior.Surface`
  page-generation so world surfaces become AI-composable (the "world →
  @json-render/hello" vision). i.e. world becomes a socialware View that renders
  generated pages.
- **creation-unification** (`docs/.../creation-unification-pivot`, #533) = the
  one authorized template chokepoint all Kind creation flows through. Agent
  Console's Template Studio is precisely the *UI over that chokepoint*.

**Recommendation:** reframe Agent Console **not** as a standalone bespoke console
but as the **"socialware creator"** — the operator surface over (a) the
creation-unification template chokepoint and (b) socialware session management
(members/routing/views). This:
- collapses #84's 4 quadrants into "create (templates) + run (sessions)" on the
  substrate that already exists (no new bespoke domain);
- makes hello, world-chat, and autoservice *instances created through the same
  surface* (world hello化 falls out naturally — world is just another View);
- keeps the Manage-gate authz proposal (the genuinely new bit in #892) as the
  cap model for that one chokepoint, rather than a console-specific feature.

So Agent Console's Phase-0 demo + Manage-gate proposal stays valuable as the
**design** for the socialware-creator's authz; the *implementation* should be a
socialware-creator View, not a separate console app.

### Proposed task order for tomorrow

1. **Brainstorm: Agent Console → socialware creator** (spec). Decide scope: the
   creator surface = creation-unification chokepoint UI + session console
   (members/routing) + the Manage-gate cap. Fold #84 + the creation-unification
   pivot (#533) into one spec. *(brainstorm → spec → codex review; do not build
   the old bespoke console.)*
2. **world hello化** (depends on the framing above): make world a socialware View
   that can render `@json-render` pages via `Behavior.Surface` (reuse hello's
   TurnDriver/Surface path). Likely a handoff to the world owner (zyli) once #1's
   substrate framing is set.
3. **world 人肉测试 + deploy** — stand up a stable env for manual testing. Given
   docker dev/prod was decommissioned for CF Workers (#65), decide: disposable
   stack (host + fresh EZAGENT_HOME + PG) vs. a CF Workers deploy. PG is now the
   substrate, so the disposable-stack recipe in `docs/guide/` needs a PG refresh
   (it predates the SQLite→PG migration). **Smallest first step: update the
   disposable-stack / world-e2e-seed guide for PG**, then a human-test pass.
4. **Arch-debt burn-down (consolidated)** — one task: re-trim the 4 oversized
   modules (`world_live.ex` 1036, `session_creator.ex` 1071, `server.ex` 1027,
   `kind.ex` 1025) + migrate `layout_manager` to `resource://`. These are
   independent, low-risk extractions; bundling them keeps the ratchet moving.

### Other `todo.md` consolidation candidates

- **Oversized-module burn-down** is already multiple todo entries
  (session_creator, server, kind). Do **not** include `world_live` in this bucket
  for 2026-06-23; it was resolved on `main` by `ebccf695`.
- **#88 inbound email** (my parked task) stays separate — it now needs a rebase
  onto the PG main before the `ezagent_plugin_email` implementation (the plan +
  spec are codex-reviewed and ready on branch `plugin-email`).
  **2026-06-23 status:** Allen marked `plugin-email` #88 as an active small task
  already under development, so it must not be included in the 2026-06-23
  dev-together plan.

### Resume note (my parked work)

`#88 email` (`plugin-email` branch): plan codex-reviewed + fixed; **rebase onto
the new PG main before implementing** (pg rewrote `config/*.exs`).

---

## Addendum (2026-06-23): #896 protocol-api (5th return) — NOT merged, handed back

`external-adapter` / PR #896 (task #82, protocol-api Phase-0, OpenAI/Anthropic
inbound API) was pushed after the 4-return close and asked to close. It is based
on the **old `a6fa6db3`** (behind pg/wb/hello/ac + the PostgreSQL migration), so
it trips current-main gates. **Lead did the mechanical integration** on branch
`protocol-api-integrate` (pushed): squash-merge onto current main, resolved all
merge conflicts (endpoint→ours #87; mix.exs release+web-deps keep both
hello+protocol_api; docs→ours), fixed stale-base compile warnings, ported the
`protocol_api_keys` migration to `priv/repo_pg` (it was orphaned in the SQLite-era
`priv/repo`), and wired the plugin into web deps.

**NOT merged — blocked on author-domain arch-conformance** (the dev built on a
base whose gates have since tightened; these are design calls in protocol-api /
external_mirror, not merge mechanics):

1. **external_mirror Grill-5 invariants ×2 (the crux).** `Ezagent.ProtocolApi.Adapter`
   declares `adapter_kind: :request_scoped` (a NEW kind) with
   `cap_subject.behavior_module: nil` (its auth is API-key, not the bind-cap).
   `AdapterCapSubjectRegisteredTest` + `BindingAdapterGrill5Test` (post PR-EM-3
   authz hardening) don't recognize `:request_scoped` and require a cap_subject +
   :push binding pairing. **Decision needed** (external_mirror + protocol-api
   owners): either formally exempt `:request_scoped` in those invariants (if it
   legitimately bypasses the bind-cap), or give the adapter a real cap_subject.
   Lead did NOT blind-edit the invariant — it guards the HIGH-3 authz-bypass class.
2. **uri_query scan ×5** (drives 3 more mix-scan test failures): protocol-api code
   has `:raw_uri_construction` (`Ezagent.URI.new!("entity://system/agent/echo_default")`
   in openai_chat_plug.ex:41,178 → use `Ezagent.URI.agent/2` typed builder),
   `:flavor_prefix_dependency` (api_key_store.ex:61 split flavor from URI prefix →
   read via `Ezagent.UriQuery`), `:tenant_derivation` (openai_chat_plug.ex name
   split). Use typed builders / UriQuery, or baseline with rationale.
3. **manifest ratchet ×1**: `spawn_registry_call_sites` 37→40 (protocol-api's
   ConversationRegistry adds 3 `SpawnRegistry.spawn` sites) needs a
   `# arch-cap-bump:` annotation in `arch_baseline_manifest.exs`.

Lead-verified before handback: protocol_api's **own** app tests pass (52/0 etc.);
the failures are all the current-main gates above. Once 1–3 land, re-run PG
precommit + the echo + curl/DeepSeek E2E (DeepSeek key available to lead) →
merge. Branch `protocol-api-integrate` is the rebased starting point.
