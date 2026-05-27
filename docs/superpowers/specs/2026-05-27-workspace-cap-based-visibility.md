# SPEC — Cap-based workspace visibility replaces `workspaces.visible` boolean

**Status:** r2 — CRIT-A1 + MED-C1 addressed. 2026-05-27.

**r2 changes:** §3.3 admin shortcut extended to include `holds_admin_caps?/1` (CRIT-A1 from r1 static review — the bootstrap admin's `kind: :any` wildcard cap does NOT match `holds_cross_workspace_admin_cap?/1`'s literal `kind: :workspace`, AND at boot `workspace://system.members` is empty per `ensure_system_workspace/0`, so without the new predicate the bootstrap admin would see `[]`). INV-8 added to §5 (MED-C1 — INV-7 alone passes against a boolean-restored-as-code-literal impl; INV-8 is a code-shape meta-test that fails when source files contain the `"system"` workspace-name literal outside of moduledoc/comment scope).

**Tier:** `apps/ezagent_domain_workspace/` data model + `Ezagent.Workspace` facade. Sweep across LV (`apps/ezagent_plugin_liveview/`), `live_auth` (`apps/ezagent_web/`), invariant tests, mix tasks, and the Phase 9 PR-8 SPEC's §13.1/§13.2.

**Trigger:** Allen 2026-05-27 Feishu — "cap-based 可见性：你看到的 workspace = 你 caps 里 workspace_uri 列出的 + member_of 里列出的。这样不需要 visible 字段，访问权决定可见性。"

**Companion:** `2026-05-27-workspace-cap-based-visibility.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim, no dual-path. The `visible` column is DELETED (DROP COLUMN), not deprecated. No "v2 toggle".
- `feedback_completion_requires_invariant_test` — the PR's merge gate is an invariant test that (i) the system workspace is NOT in `list_workspaces_for(non-admin, no caps, no system membership)` AND (ii) the same workspace IS in `list_workspaces_for(workspace://system member)`.
- `feedback_north_star_plugin_isolation` — plugin authors call `list_workspaces_for/1` and DO NOT know about visibility. The workspace domain owns the cap-based query; the LV plugin never references `visible` or membership/caps logic directly.
- `feedback_destructive_migration_anti_pattern` — `ALTER TABLE … DROP COLUMN visible` is a destructive migration. THIS SPEC EXPLICITLY MARKS THE MIGRATION AS A HUMAN-REQUIRED STEP (operator stops phx, runs `mix ecto.migrate`, restarts). NO subagent autoruns it.
- `feedback_subagent_must_load_project_skills` — the impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_review_every_pr` — codex review of this SPEC + the impl PR carries the verbatim "no mix" clause.

**Parent / historical context:**
- `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md` §13.1 + §13.2 + §13.4 — introduced `visible: false` as the mechanism to keep `workspace://system` out of the regular workspace selector. This SPEC supersedes that decision.
- `apps/ezagent_core/test/invariants/workspace_sot_test.exs` + `system_workspace_membership_test.exs` — encode the old "`list_visible/0` is the SoT for operator-facing surfaces" discipline. Both invariant tests need adaptation (§4.2 enumerates the changes).
- `2026-05-27-capability-action-axis.md` — concurrent SPEC adding the `:action` axis to the capability struct. Independent — this SPEC operates on the `workspace_uri` axis only, no interaction with `:action`.

---

## 1. Problem statement — what's wrong with `visible: false`

The `workspaces.visible` boolean was introduced in Phase 9 PR-8 (SPEC v3 §13.1) as a mechanism to keep `workspace://system` out of the regular operator workspace-selector dropdown for non-system members. It is the wrong abstraction for three structural reasons.

**(a) Premature generalization.** The boolean exists to special-case exactly ONE workspace (`workspace://system`). There is no production code path that creates ANY other `visible: false` row — `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:269-275` is the only producer (`ensure_workspace("system", %{visible: false})`). The "field" is a sentinel masquerading as a generic visibility axis: every other workspace is `visible: true` by `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:66` default. A field whose value space is `{:always true, this one special row false}` is not modeling visibility — it's marking the system workspace with a poorly-named tag.

**(b) Doesn't compose with caps.** Capabilities already carry a `workspace_uri` axis (`apps/ezagent_core/lib/ezagent/capability.ex:21-26`). Whether a user can ACT on a workspace is fully determined by their caps + membership. Whether they SEE a workspace ought to be the same answer: showing a user a workspace they cannot reach is a privilege-disclosure surface (they learn that a workspace exists which they cannot enter) — the very concern the `workspace_sot_test.exs` invariant test (`apps/ezagent_core/test/invariants/workspace_sot_test.exs:10-15`) was added to enforce. The boolean is downstream of cap-holdings; making it the primary mechanism inverts the axis ordering. A user holding `Behavior.Workspace.add_member` on `workspace://X` should see `workspace://X` because they HAVE THE CAP — not because `X.visible == true`.

**(c) Doesn't extend to per-tenant hidden workspaces.** If a future feature requires "this workspace is hidden from users B, C, D but visible to user A", the boolean can't express it — `visible` is a single global flag. The cap-based model handles it natively (A's caps include `workspace://X`; B/C/D's don't). Anticipated examples: per-tenant staging workspaces, archived workspaces visible only to operators, role-gated workspaces (e.g. only finance can see `workspace://billing`). All require per-user visibility, which `workspaces.visible` cannot express.

**(d) The boolean is already redundant.** Every code path that today checks `visible: false` is paired with a path that checks system membership or admin caps. For example, `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:328-332` reinjects `workspace://system` into the picker (because the admin needs to see it after `list_visible/0` filtered it out). The boolean and the system-member check both encode the same predicate; the system-member check is the real one (cap-derived), the boolean is the leaky abstraction.

The bug class this prevents: every NEW operator-facing surface that lists workspaces must remember to call `list_visible/0` and not `list_all/0` or `list_persisted/0`. PR #290 (`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex` history) and the subsequent `workspace_sot_test.exs` invariant exist BECAUSE this discipline was violated once already. Removing the boolean eliminates the discipline — there is no longer a `list_visible/0` to forget to call. The query is `list_workspaces_for(caller_uri)` for everyone; you cannot accidentally see hidden workspaces because the query SHAPE is parameterised on the caller.

## 2. Decision

Replace the `workspaces.visible` boolean field with **cap-based visibility**. The field is DELETED (DROP COLUMN). No shim, no dual-path, no transitional period — per `feedback_let_it_crash_no_workarounds`.

The single operator-facing query becomes:

```elixir
Ezagent.Workspace.list_workspaces_for(caller_uri :: URI.t(), caps :: [Capability.t()] | MapSet.t())
  :: [Workspace.Store.decoded()]
```

There is no longer a `list_visible/0`. The functions `list_all/0` (admin / loader / mix-task internal use) and `list_persisted/0` (alias of `list_all/0`) remain — they are intentionally unscoped and used ONLY for system-internal purposes (loader rehydration, the cross-prefix cleanup mix task, the no-default-seeded invariant test). The `workspace_sot_test.exs` invariant test is RENAMED + REFRAMED — see §4.2 — to gate "operator-facing surfaces use `list_workspaces_for/2`, never `list_all/0`".

## 3. Semantics — `list_workspaces_for/2` defined precisely

### 3.1 Inputs

- `caller_uri` — a `%URI{}` of the caller (typically `entity://user/<ws>/<name>`, but accepting `%URI{scheme: "entity"}` generally so agent callers work too).
- `caps` — the caller's loaded capability set (`MapSet.t(%Capability{})` or `[%Capability{}]`). Sourced from `Identity` slice / `Users.decode_caps/1` / `SystemPrincipal.caps/1` upstream by the call site (e.g. `live_auth.ex` already loads it before mounting LVs).

The two arguments are kept distinct on purpose: the caller URI determines membership; caps determine cap-scope. Neither subsumes the other (a system member's caller URI carries authority NOT encoded in their cap list; a delegated workspace admin's caps carry authority NOT encoded in their URI).

### 3.2 Output

A list of `Workspace.Store.decoded()` rows the caller can act on. Each entry includes the same shape returned today by `list_all/0` (`id`, `name`, `uri`, `members`, `session_templates`, `routing_rules`, `created_by`, `created_at`, `updated_at`) — MINUS the `visible` key (which no longer exists). Ordering: by `name` ASC, identical to today's `list_visible/0`.

### 3.3 Union definition

```
list_workspaces_for(caller_uri, caps) =
  if   holds_admin_caps?(caps)                        -- (i) bootstrap wildcard
       or  holds_cross_workspace_admin_cap?(caps)     -- (ii) structural workspace-only admin
       or  member_of_system?(caller_uri)              -- (iii) system-member admin
  then list_all()                                     -- admin shortcut
  else union(
         member_of_workspaces(caller_uri),            -- (a) membership
         workspaces_for_caps(caps)                    -- (b) cap-scope
       )
```

The three contributing sources:

**(a) `member_of_workspaces(caller_uri)`** — every persisted workspace whose `members` list contains `caller_uri` (string-equality compare). Implementation walks `Workspace.Store.list_all/0` once + filters; this is intentionally O(N) over the workspace count. N is bounded by operator-created workspaces (today: a handful; growth model: per-tenant ≈ one workspace). If N grows past a regression threshold we add an index — `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:55-68` schema already has `member_uris` as Jason-encoded text, so the index would be a sidecar `workspace_members` join table, but that's out of scope for this SPEC (§7).

**(b) `workspaces_for_caps(caps)`** — every persisted workspace whose `uri` matches the `workspace_uri` field of any cap in `caps`. Caps with `workspace_uri: :any` contribute NOTHING to this branch (they would otherwise return all workspaces — but the admin shortcut already does that, and `:any` from a non-admin caller is a structural cross-workspace marker, not a "all workspaces" enumeration). Caps with `workspace_uri: %URI{}` contribute the matching workspace if one exists in `Store.list_all/0`. Implementation: collect `cap.workspace_uri` values, filter to `%URI{}` (drop `:any`), look up each in `Store.list_all/0` (or `Store.get_by_uri/1` if added — see §10 OQ-3). The lookup tolerates caps that reference deleted workspaces by simply skipping them.

**Admin shortcut** — the union of THREE predicates returns ALL workspaces:

- (i) `holds_admin_caps?(caps)` (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:835-868`) — matches the full-wildcard bootstrap shape `kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any`. The bootstrap admin (`entity://user/system/admin`) holds EXACTLY this cap shape (minted by `Ezagent.SystemPrincipal.caps("system://bootstrap")`).
- (ii) `holds_cross_workspace_admin_cap?(caps)` (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:728-755`) — matches the narrower workspace-only admin shape `kind: :workspace, behavior: Workspace, action: :any, instance: :any, workspace_uri: :any` (delegated cross-workspace admin via a workspace-Behavior cap, NOT a kind:any wildcard).
- (iii) `member_of_system?(caller_uri)` (`apps/ezagent_core/lib/ezagent/capability.ex:493-507`) — matches a caller whose URI is listed in `workspace://system`'s `members`. This is the "Promote to system" path (LV `users_live.ex:232`).

The three are NOT subsumed by each other. The bootstrap admin satisfies (i); a delegated cross-workspace operator (e.g. a future "tenant-admin" role) satisfies (ii); a system-promoted regular user satisfies (iii). A SPEC r1 design that omitted (i) would regress the bootstrap admin to `[]` because (a) the bootstrap admin's `members` row in `workspace://system` is created only by the LV promote path (NOT by `ensure_system_workspace/0` at `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:269-275`, which seeds an EMPTY system workspace), and (b) the bootstrap wildcard cap's `kind: :any` does NOT match the literal `kind: :workspace` in (ii). r2 includes (i) explicitly to close this gap.

The order `admin shortcut → union` is deliberate: the union is more expensive (it walks two sources); admin callers skip it. The shortcut is functionally equivalent to the union for an admin (a system member is a member of `workspace://system` AND holds wildcard caps, so the union would also return everything) — but cheaper, AND it surfaces the structural intent: an admin's view is unconditional, not derived from per-cap arithmetic.

### 3.4 What about `workspace://system` specifically?

`workspace://system` appears in the output iff the admin shortcut fires — i.e. the caller is a system member, OR holds a bootstrap-wildcard cap (kind:any/behavior:any/action:any/instance:any/workspace_uri:any), OR holds a structural cross-workspace admin cap (kind:workspace/behavior:Workspace/action:any/instance:any/workspace_uri:any). A regular member of `workspace://X` who satisfies none of the three predicates will NOT see it — same effective behavior as today's `list_visible/0`. The difference: it's no longer because the row has `visible: false`; it's because the caller's caps + membership don't include `workspace://system`.

### 3.5 Edge case — `system://bootstrap` / `system://*` callers

Non-entity callers (e.g. `system://workspace-loader` invoking `Loader.load_all/0`) DO NOT use `list_workspaces_for/2`. They use the unscoped `list_all/0` directly — that's the LOADER path, which legitimately needs every workspace regardless of caller identity. `list_workspaces_for/2` is for operator-facing surfaces; system-internal callers bypass it. The `workspace_sot_test.exs` invariant test (renamed `operator_facing_workspace_listing_test.exs` — see §4.2) gates LV / `live_auth` / mix task files; it does NOT gate `Loader` or `Application.start/2` callbacks.

### 3.6 Edge case — caller URI we can't derive a workspace from

If `caller_uri` is not a parseable 3-segment entity URI, `Ezagent.URI.entity_workspace_uri/1` (`apps/ezagent_core/lib/ezagent/uri.ex:301`) raises. `list_workspaces_for/2` MUST NOT raise on a malformed caller — it returns `[]` for unparseable callers, with `member_of_workspaces/1` short-circuiting (no membership can be established) and `workspaces_for_caps/1` running independently on the caller's caps. This is the principled answer: an unparseable caller has no membership; their visibility is purely cap-derived. Letting it crash would surface inside the LV mount lifecycle — at a layer that has no useful recovery path. The function is a READ; readability of "you see no workspaces" is the structural fallback when caller identity is corrupt.

(Note: the upstream `live_auth.ex` already enforces canonical 3-segment URIs at session-cookie validation per `feedback_register_lookup_key_parity`. A malformed caller would imply that gate failed — an independent bug. The `[]` return here is defensive depth, not the primary path.)

## 4. Migration plan

### 4.1 Destructive DB migration — HUMAN-REQUIRED step

The migration file `apps/ezagent_core/priv/repo/migrations/<timestamp>_drop_workspaces_visible.exs` does:

```elixir
defmodule EzagentCore.Repo.Migrations.DropWorkspacesVisible do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      remove :visible, :boolean, null: false, default: true
    end
  end
end
```

**This migration MUST NOT be run by the impl subagent** (per `feedback_destructive_migration_anti_pattern`). The hard rule: a subagent CANNOT `mix ecto.migrate` against a dev DB that a running `phx.server` is using — the migration acquires a lock on `workspaces`, and the live phx process's slice writes / loader queries crash the BEAM.

**The migration is an explicit operator step in the PR's checklist:**

1. Operator stops `phx.server` (Ctrl+C twice).
2. Operator runs `mix ecto.migrate` (or `MIX_ENV=dev mix ecto.migrate`).
3. Operator restarts `phx.server`.

The PR description and the SPEC implementation plan both flag this as `human-required:db-migration`. The impl subagent ships the migration file and the code changes; the operator runs the migrate. If the operator forgets, the post-merge boot WILL crash on the first `Workspace.Store.list_all/0` call because Ecto's schema-loader compiles `field :visible, :boolean` but the column doesn't exist — that crash IS the structural reminder, no defensive sidecar needed.

(Conversely, the `Workspace.Store` schema definition's `field :visible, :boolean, default: true` line is DELETED in the same PR commit as the migration file. So a post-migrate boot loads fine; a pre-migrate boot crashes loudly. The mismatch is the structural gate.)

### 4.2 Code changes — every caller of `list_visible/0` and `list_all/0`

The sweep enumerates every call site found by `grep -rn "list_visible\|Workspace\.list_all\|Workspace\.Store\.list_all" apps/ --include="*.ex" --include="*.exs"`. Below: file:line + what it becomes.

**Operator-facing callers (USE `list_workspaces_for/2` POST-SPEC):**

| File:line | Today | After |
|---|---|---|
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspaces_live.ex:61` | `Ezagent.Workspace.list_visible()` | `Ezagent.Workspace.list_workspaces_for(socket.assigns.current_entity_uri, socket.assigns.current_caps)` |
| `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:324-332` | `list_visible/0` + manual `workspace://system` prepend for admin | `list_workspaces_for/2` — the admin shortcut already includes `system`; the manual prepend at line 329 is DELETED |
| `apps/ezagent_web/lib/ezagent_web/live_auth.ex:310` | `Ezagent.Workspace.list_visible()` | `Ezagent.Workspace.list_workspaces_for(caller_uri, caps)` from the session principal |
| `apps/ezagent_web/test/ezagent_web/controllers/onboarding_controller_test.exs:89` | `Ezagent.Workspace.list_visible() \|> Enum.any?(&(&1.name == ws_name))` | `Ezagent.Workspace.list_workspaces_for(test_caller, test_caps) \|> Enum.any?(...)` — TEST update |

**System-internal callers (KEEP `list_all/0` POST-SPEC):**

| File:line | Today | After | Rationale |
|---|---|---|---|
| `apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex:284` | `Workspace.Store.list_all()` | unchanged | Loader rehydrates EVERY persisted workspace at boot regardless of caller |
| `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:814` | `Ezagent.Workspace.Store.list_all()` | unchanged | Agent-flavor resolution walks every workspace's templates; not operator-facing |
| `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.workspace.cleanup_cross_prefix_members.ex:93` | `Ezagent.Workspace.Store.list_all()` | unchanged | Audit-only mix task; operator-tier (runs under operator shell, not user surface) |
| `apps/ezagent_domain_identity/test/ezagent/registration_test.exs:36` | `Ezagent.Workspace.list_all()` | unchanged | Test-only; reads back what the test just created |
| `apps/ezagent_core/test/invariants/no_default_workspace_seeded_test.exs:50` | `Ezagent.Workspace.list_all()` | unchanged | Invariant test asserting no `default` row exists |
| `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs:103` | `Ezagent.Workspace.list_all()` | unchanged (but neighboring `list_visible/0` line 102 is removed — see below) | Cross-checks system row exists |
| `apps/ezagent_domain_workspace/test/ezagent/workspace/store_test.exs:85` | `Store.list_all()` | unchanged | Store-internal test |

**Functions DELETED in this PR:**

| Function | File:line | Rationale |
|---|---|---|
| `Ezagent.Workspace.list_visible/0` | `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:510` | Replaced by `list_workspaces_for/2`. No remaining callers after the sweep above. |
| `Ezagent.Workspace.Store.list_visible/0` | `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex:187-191` | Underlying Store-level query, no remaining callers. |
| `Ezagent.Workspace.list_persisted/0` | `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:488` | Alias of `Store.list_all()` — was kept only for the historical "use `list_visible` not `list_persisted`" discipline. With cap-based listing, no one should reach for the unscoped function from operator surfaces; system-internal callers go through `Store.list_all/0` directly. |

**Invariant tests REWRITTEN:**

| Test | File | Change |
|---|---|---|
| `EzagentCore.Invariants.SystemWorkspaceMembershipTest` | `apps/ezagent_core/test/invariants/system_workspace_membership_test.exs` | Drop the `visible: false` assertion at line 93. Drop the `list_visible/0` excludes/includes test at line 99-116. Add: `list_workspaces_for(regular_user, []) excludes system`; `list_workspaces_for(system_member, []) includes system`; `list_workspaces_for(admin, [wildcard_cap]) returns all`. Fixture creation at lines 47-48 drops `visible: false` / `visible: true` keys. |
| `EzagentCore.Invariants.WorkspaceSotTest` | `apps/ezagent_core/test/invariants/workspace_sot_test.exs` → renamed `operator_facing_workspace_listing_test.exs` | `@forbidden_patterns` rewritten: forbid `Workspace.list_visible(` (gone) AND `Workspace.list_all(` AND `Workspace.Store.list_all(` in operator scope. The single allowed reader is `Workspace.list_workspaces_for(`. |
| `EzagentCore.Invariants.NoDefaultWorkspaceSeededTest` | `apps/ezagent_core/test/invariants/no_default_workspace_seeded_test.exs` | Unchanged. Still uses `list_all/0`; this is system-internal and remains valid. |
| `EzagentCore.Invariants.PromoteToSystemGrantsCrossWorkspaceTest` | `apps/ezagent_core/test/invariants/promote_to_system_grants_cross_workspace_test.exs:26` | Drop `%{visible: false}` arg — `Store.create("system", %{})` works post-SPEC since visible no longer exists. |
| `EzagentCore.Invariants.WorkspaceLvCliParityTest` | `apps/ezagent_core/test/invariants/workspace_lv_cli_parity_test.exs:51` | Drop `list_visible` from `@read_only_exemptions`; replace with `list_workspaces_for`. |

**Boot seed REWRITTEN:**

`apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:273` — the call becomes `:ok = ensure_workspace("system", %{})` (no `visible: false`). The `ensure_workspace/2` helper at line 277-319 needs no change beyond passing `attrs` through unchanged.

### 4.3 Phase 9 PR-8 SPEC amendment

`docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md` §13.1 + §13.2 + §13.4 are AMENDED in this same PR:

- §13.1 paragraph 2 (`workspace://system is NOT visible in the regular workspace selector UI for non-system members`) is rewritten: "`workspace://system` does not appear in the per-caller workspace listing for callers who lack `workspace://system` membership or cross-workspace admin caps. Mechanism: `Ezagent.Workspace.list_workspaces_for/2` (SPEC `2026-05-27-workspace-cap-based-visibility.md`). Visibility is cap-derived, not field-based."
- §13.2 paragraph 5 (regular workspace members never see `workspace://system` in the selector) is reaffirmed; the parenthetical "(it's hidden per §13.1)" becomes "(they are not members; their caps don't reference it)".
- §13.4 boot seed snippet (`Workspace.create("system", %{visible: false})`) is updated to `Workspace.create("system", %{})`. The `visible: false` field on workspaces is NEW — defaults to true sentence (§13.4 paragraph 2) is DELETED.

The corresponding Chinese SPEC file `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.zh_cn.md` is amended in lockstep (per `feedback_bilingual_docs_convention`).

### 4.4 Single coordinated PR — no dual-path

Per `feedback_let_it_crash_no_workarounds` + the parent SPEC's r1-r9 pattern, this lands in ONE coordinated PR:

1. Schema removal (`Workspace.Store` defstruct + decode + `list_visible/0`) — 1 commit
2. Facade rewrite (`Ezagent.Workspace.list_workspaces_for/2` + `list_visible/0` deletion) — 1 commit
3. Migration file — 1 commit
4. All caller sweep — 1 commit
5. Invariant test rewrites — 1 commit
6. Phase 9 PR-8 SPEC amendment (en + zh_cn) — 1 commit
7. PR-level checklist with `human-required:db-migration` flag — in PR description, not a commit

The impl subagent ships commits 1-6; the operator runs the migration; the operator (or auto-merge gate) closes the PR.

## 5. Invariant test — the merge gate

Per `feedback_completion_requires_invariant_test`, this PR is "done" iff the invariant test below passes AND would fail when the architectural goal is unmet.

**Test file:** `apps/ezagent_core/test/invariants/cap_based_workspace_visibility_invariant_test.exs`

**Setup** (DataCase, `async: false`):

1. Create three persisted workspaces:
   - `workspace://system` (via `Ezagent.Workspace.Store.create("system", %{})`)
   - `workspace://team-alpha` (via `Ezagent.Workspace.Store.create("team-alpha", %{})`)
   - `workspace://team-beta` (via `Ezagent.Workspace.Store.create("team-beta", %{})`)
2. Define three callers:
   - `regular_user_no_caps` = `URI.parse("entity://user/team-alpha/regular")`, caps = `MapSet.new()`
   - `team_alpha_member_no_caps` = `URI.parse("entity://user/team-alpha/member")`, caps = `MapSet.new()` — but ALSO add the URI to `workspace://team-alpha`'s `members` via `Ezagent.Workspace.add_member("team-alpha", caller_uri)`
   - `system_member` = `URI.parse("entity://user/system/admin")`, caps = `MapSet.new()` — added to `workspace://system`'s members (the bootstrap admin pattern)
3. Define a "delegated admin" caller:
   - `delegated_workspace_admin` = `URI.parse("entity://user/team-alpha/admin")`, caps = `MapSet.new([%Capability{kind: :workspace, behavior: Ezagent.Behavior.Workspace, action: :add_member, instance: URI.parse("workspace://team-alpha"), workspace_uri: URI.parse("workspace://team-alpha"), granted_by: User.admin_uri(), granted_at: DateTime.utc_now()}])` — NOT a system member; holds a single workspace-scoped cap.

**Assertions:**

| # | Caller | Expected `list_workspaces_for(...)` |
|---|---|---|
| INV-1 | `regular_user_no_caps` | `[]` — NO system, NO team-alpha (not a member), NO team-beta. Lookups by URI return EMPTY. |
| INV-2 | `team_alpha_member_no_caps` | `[team-alpha]` — exactly one row, name `"team-alpha"`. Does NOT include system. Does NOT include team-beta. |
| INV-3 | `system_member` | `[system, team-alpha, team-beta]` — all three (admin shortcut). |
| INV-4 | `delegated_workspace_admin` | `[team-alpha]` — exactly one row via cap-scope branch. Does NOT include system (no system membership, cap doesn't reference system). Does NOT include team-beta. |

**Mutation regression assertions (the structural gate):**

- INV-5: After `Ezagent.Workspace.add_member("team-beta", regular_user_no_caps_uri)`, re-running `list_workspaces_for(regular_user_no_caps, [])` returns `[team-beta]`. (Adding the user to a workspace as a member changes their visibility set with no extra cap grant.)
- INV-6: After granting `regular_user_no_caps_uri` a `Behavior.Workspace.list_members` cap scoped to `workspace://team-alpha` (via `Ezagent.Workspace.grant_initial_caps/3` or direct `Identity.grant_cap`), re-running `list_workspaces_for(regular_user_no_caps, [the_new_cap])` returns `[team-alpha]`. (Cap-scope branch fires.)
- INV-7: The system workspace assertion specifically: `regular_user_no_caps` NEVER sees `workspace://system` regardless of which non-admin caps are added. Test asserts this by granting a `Behavior.Workspace.list_members` cap scoped to `workspace://team-alpha` AND a `Behavior.Workspace.add_member` cap scoped to `workspace://team-beta`, then asserting the result list does not contain `"system"`.

- INV-8 [r2 — addresses MED-C1 from r1 static review]: **Code-shape meta-test** asserting the implementation source files do NOT contain the workspace-name literal `"system"` outside of moduledoc / `@moduledoc` / line-comment scope. Targets:
  - `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex`
  - `apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex`

  Test mechanism:
  ```elixir
  for path <- [
    "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
    "apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex"
  ] do
    src = File.read!(path)
    # strip moduledocs (heredoc) and line comments before searching
    sanitized =
      src
      |> String.replace(~r/@moduledoc\s+"""[\s\S]*?"""/, "")
      |> String.replace(~r/@doc\s+"""[\s\S]*?"""/, "")
      |> String.split("\n")
      |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
      |> Enum.join("\n")

    refute sanitized =~ ~r/"system"/,
      """
      INV-8 violation: #{path} contains the literal string "system" in code
      (not in moduledoc/comments). This catches the boolean-restoration
      anti-pattern — `if workspace.name == "system"` is forbidden because
      it re-introduces the field-shaped special-case in code form. The
      system workspace's hiding from non-members is structural (cap +
      membership absence), NOT a literal-match filter.
      """
  end
  ```

  **Why INV-8 is a code-shape meta-test, intentionally:** INV-7 tests the negative direction only (non-admin doesn't see system). A partial impl that hardcodes `if ws.name == "system" and !system_member, exclude` would pass INV-7 — the test fixture's regular user gets `team-alpha` + `team-beta` caps, so the system literal-string filter would correctly exclude system for the non-member. INV-8 catches this anti-pattern at the source level rather than the behavior level. It is a deliberate exception to the "test behavior not implementation" principle: the specific behavior (the boolean-restoration shape) is structurally indistinguishable from the correct impl at the test fixture's chosen cap shapes, so a behavior test cannot discriminate. The fix is to test the code shape directly.

  Trade-off acknowledged: INV-8 would fail if a future refactor legitimately needs the string `"system"` in workspace.ex (e.g. a doc-string code example, a log message). The sanitizer strips moduledocs/comments; if a non-doc legitimate use arises (e.g. error message format), INV-8's regex needs updating with a justified exception list. The exception list IS the audit trail — adding to it requires explaining why this isn't a boolean restoration.

**Why this gates the architectural goal:**

- A partial impl that returns `list_all()` for everyone fails INV-1 and INV-4 and INV-7 (visibility too broad).
- A partial impl that returns `[]` for everyone fails INV-2, INV-3, INV-4, INV-5, INV-6.
- A partial impl that gets membership right but drops cap-scope fails INV-4 and INV-6.
- A partial impl that gets cap-scope right but drops membership fails INV-2 and INV-5.
- A partial impl that recovers the boolean as a code literal (`if ws.name == "system" and !system_member, exclude`) PASSES INV-7 — the test fixture's caps don't reference system, so the literal filter excludes system for non-members and the assertion holds. INV-7 alone cannot catch this. **INV-8 catches it** by grep-asserting the source files do not contain the `"system"` literal in code scope.
- A partial impl that gets the admin shortcut wrong (e.g. accidentally includes system for `team_alpha_member_no_caps`) fails INV-2.

**Cannot pass with a partial impl** — codex r1 review question #3 (§9) explicitly attacks this; if codex finds a partial impl that passes, the test is strengthened in the next round.

## 6. Plugin isolation analysis

Per `feedback_north_star_plugin_isolation`, the goal is "future devs work on different plugins without coordination". The architectural seam:

| Layer | Knows about | Does NOT know about |
|---|---|---|
| `ezagent_core` | `Capability.workspace_uri` axis | workspaces.visible (no such concept) |
| `ezagent_domain_workspace` (the domain) | `list_workspaces_for/2` implementation: membership + cap-scope + admin shortcut | LV-specific rendering, admin-promotion UX |
| `ezagent_plugin_liveview` (the LV plugin) | Calls `list_workspaces_for/2`; iterates results to render | The internal union logic, the admin shortcut criteria, the `member_of_system?` predicate location |
| `ezagent_web` (the auth plugin) | Calls `list_workspaces_for/2` from `live_auth.ex` mount | Same as LV plugin |

A future LV plugin author writing a new "workspace picker" surface calls `list_workspaces_for/2` and is structurally correct. They cannot reach for `list_all/0` because the operator-facing-listing invariant test (§4.2) blocks it. They cannot reach for `Capability.cross_workspace?` or `member_of_system?` because those are NOT exposed by the workspace facade — they're implementation details inside `Ezagent.Workspace.list_workspaces_for/2`.

The asymmetry: today, an LV plugin author can ACCIDENTALLY call `list_persisted/0` and leak hidden workspaces. The fix today is the invariant test. POST-SPEC, the asymmetry vanishes — `list_workspaces_for/2` is the ONLY operator-facing query, and it's caller-scoped by construction.

Tiebreaker test (per `feedback_north_star_plugin_isolation` "keeps plugin authors out of core"): does `list_workspaces_for/2` expose any cap struct internals to the LV plugin? Answer: NO. The LV passes the caps list (which it already has from `live_auth` → session principal) and gets a workspace list back. The cap struct stays opaque inside `ezagent_domain_workspace` and `ezagent_domain_identity`. ✅

## 7. Trade-offs / alternatives considered

### 7.1 Keep `visible` field AND add cap-based listing (additive)

**Rejected.** Two visibility mechanisms confuse callers ("do I check the field, or do I check caps, or both?"). The discipline of "always use both" is the same kind of contributor-cognitive-load that the original Phase 9 PR-8 design failed at (one LV used `list_persisted/0`, the other used `list_visible/0` — same discipline failure mode). A single mechanism is structural; two mechanisms is policy.

### 7.2 URI scheme `system://` instead of `workspace://system`

**Rejected.** The `system://` scheme exists today (`apps/ezagent_core/lib/ezagent/uri.ex` — six-scheme allowlist) but is used for system-internal principals (`system://bootstrap`, `system://workspace-loader`), NOT workspaces. Promoting `workspace://system` to `system://workspace` would (a) break the URI consistency for the workspace scheme — all other workspaces are `workspace://<name>`, why this one different? (b) require every workspace-aware code path to handle both schemes (`workspace://` AND `system://`) when checking workspace-scope, which is a worse contributor-load story than the cap-based fix. The system workspace IS a workspace — making its URI scheme reflect that is the right invariant. The "system-ness" is encoded in membership, not in the URI scheme.

### 7.3 Hardcode "system is hidden" without the visible field

**Rejected.** Same anti-pattern (per `feedback_let_it_crash_no_workarounds` no-defaults / no-whitelist). A literal `if workspace.name == "system"` filter is the boolean's shape moved into code — exactly what Allen's brief rejects in the trigger directive. Worse: it makes the system workspace's hiding implicit in code rather than declarative in the data model. Cap-based visibility makes the rule structural ("you see workspaces you have a cap on or are a member of"), no naming-based filter.

### 7.4 Per-tenant `visible` (e.g. `visible_to_users`, `hidden_from_users`)

**Rejected.** Even if implemented, it duplicates the cap-membership axis: `hidden_from_users` ≈ "users WITHOUT a cap or membership". Implementing both is two-source-of-truth (per `project_uuid_is_canonical_identifier` analog: visibility is mutable display-only over a canonical authority axis). A workspace's authority-set IS its visible-set; making them the same expression by construction is the structural fix.

### 7.5 Capability-policy filter at LV render time

**Rejected.** Pushing the filter into the LV ("LV fetches `list_all/0`, filters by checking each row's URI against the caller's caps") moves domain logic into the plugin layer. Per `feedback_north_star_plugin_isolation`: keeps plugin authors out of core — the workspace domain owns the cap-based logic. An LV calling `list_workspaces_for/2` is structurally enforced to use the domain's algorithm.

## 8. SPEC §3.6.1(b) interaction — wildcard-action-grant check

The concurrent SPEC `2026-05-27-capability-action-axis.md` §3.6.1(b) introduces a runtime grant-boundary check: `Identity.grant_cap/3` rejects `Capability.action_of(cap) == :any` from non-privileged callers (callers not satisfying `holds_admin_caps?/1`).

**Question:** Does this SPEC affect that check?

**Answer:** No. The interaction surface:

- `list_workspaces_for/2` is a READ. It does not grant caps. It does not call `Identity.grant_cap/3`.
- `holds_cross_workspace_admin_cap?/1` (used by `list_workspaces_for/2`'s admin shortcut) requires `action: :any` per the parent SPEC's option-B narrowing (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:737-754`). This means a delegated workspace admin with a `:add_member`-only cap does NOT trigger the admin shortcut — they go through the cap-scope branch (correctly producing exactly their scoped workspace). This is the design.
- The `:any` action axis on a cap with `workspace_uri: :any` is the admin wildcard; `list_workspaces_for/2`'s admin shortcut path matches it (returns `list_all/0`). A caller holding such a cap is admin by both axes (per the parent SPEC's policy table at §3.6.1).
- A future grant-side change to `Identity.grant_cap/3` (e.g. tightening which actions can be granted at all) does not change `list_workspaces_for/2`'s semantics. The two SPECs are orthogonal: action-axis is about WHAT the cap permits at dispatch; workspace-axis (this SPEC) is about WHICH workspaces the cap surfaces to the caller in a listing.

**The seam:** if a future grant-policy change makes it impossible to mint a narrow `Behavior.Workspace.add_member` cap on `workspace://team-alpha` for a non-admin caller, INV-4 above becomes unachievable in tests — the test fixture must be relaxed (e.g. grant via system principal, or test via a different cap-bearing scenario). The test setup notes this dependency: "delegated_workspace_admin's cap is minted by `User.admin_uri()` in the test setup; if a future policy restricts even admin-minted narrow caps, update the setup but not the assertion."

## 9. Backwards compatibility / external API

### 9.1 Mix tasks

- `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.workspace.cleanup_cross_prefix_members.ex:93` uses `Workspace.Store.list_all/0` and does NOT reference `visible`. Unchanged.
- No other mix task in `apps/*/lib/mix/tasks/` references `list_visible/0` or `visible`. Verified via grep:
  ```
  rg -nP "list_visible|\.visible\b" apps/*/lib/mix/tasks/ → 0 hits
  ```

### 9.2 CLI / shell scripts

- `scripts/` directory: no references to `visible` or `list_visible`. (`grep -rn "visible" scripts/ → 0 hits`.)
- The cc-openclaw bootstrap (`cc-openclaw-ds.sh`, etc.) does not interact with workspace visibility. Unchanged.

### 9.3 Documentation references

- `docs/runbook/`: `common-failures.md:266` references "deliberate visibility" in an unrelated migrations context. Unchanged.
- `docs/notes/2026-05-24-architecture-audit-v1.md:59-63` describes the `list_persisted/0 → list_visible/0` migration in Phase 9 PR-8. KEPT (historical record). A new note `docs/notes/2026-05-27-cap-based-workspace-visibility.md` is OPTIONAL — not required by this SPEC (the SPEC itself is the durable record).
- `docs/scenarios/` directory: does not exist. No scenario impact.

### 9.4 External JSON / API endpoints

- No public HTTP/JSON API today exposes a workspace's `visible` field. The `Workspace.Store.decoded()` shape is internal; LV templates render `ws.name` / `ws.uri` / `ws.members` / `ws.session_templates` / `ws.routing_rules` — never `ws.visible`.
- The `tmpl.visible` confusion does not exist: SessionTemplate Kinds don't have a `visible` field; the `workspaces.visible` was the only one.

### 9.5 External integrations (Feishu, MCP, plugin authors)

- Plugin authoring contract (`docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md`): no reference to workspace visibility.
- Feishu / MCP: workspace visibility is an internal concept; not surfaced externally.

**Net assessment**: zero external-API impact. The `visible` field is pure internal infrastructure.

## 10. Open questions for Allen

1. **OQ-1: `caps` arg shape.** `list_workspaces_for(caller_uri, caps)` accepts caps as `MapSet.t() | [Capability.t()]`. Should we normalize to one shape at the API boundary? Today's predicate `holds_cross_workspace_admin_cap?/1` (`identity.ex:728`) accepts both; staying consistent. OK?

2. **OQ-2: Caps-loading caller-site responsibility.** The LV / `live_auth.ex` already loads `caller_caps` before mounting (via `Users.decode_caps/1`). `list_workspaces_for/2` REQUIRES caps to be passed in — it does NOT re-fetch them from `Identity` slice. This avoids a second DB round-trip per mount but means a stale `caps` argument produces a stale workspace list. Acceptable, OR should the function fetch caps itself from `caller_uri`?

3. **OQ-3: `Store.get_by_uri/1` accessor.** The cap-scope branch (§3.3.b) needs to look up workspaces by URI. Today `Store.get_by_name/1` exists but no `get_by_uri/1`. Add a thin wrapper, or filter in-memory from `list_all/0`? In-memory is simpler (one DB query for all workspaces, then filter) and aligns with the loader pattern; a `get_by_uri/1` could be added later if performance demands. Default: in-memory filter.

4. **OQ-4: `member_of_system?` reuse.** `Capability.member_of_system?/1` (`capability.ex:493-507`) is currently a private function used only by `cross_workspace?/2`. Promoting it to a public `Workspace.member_of_system?/1` to share with `list_workspaces_for/2`'s admin shortcut creates a domain-level helper for system-membership checks. Acceptable, OR should `list_workspaces_for/2` re-implement the lookup against `Store.get_by_name("system")`?

5. **OQ-5: Caps with `:any` action axis from non-admin callers.** Per the concurrent SPEC `2026-05-27-capability-action-axis.md` §3.6.1, runtime grant-boundary rejects non-admin `:any` grants. Should `list_workspaces_for/2` also skip wildcards from non-admin callers in the cap-scope branch — i.e. if `cap.workspace_uri == :any` AND caller is NOT admin, treat the cap as not contributing to the listing? Current §3.3 says: caps with `:any` workspace_uri contribute NOTHING. The admin shortcut handles the legitimate `:any` case. This is a defensive design — flag for explicit confirmation.

6. **OQ-6: Drift / forensic recovery.** If a future op accidentally re-introduces `visible` (e.g. a migration revert), the schema-load mismatch will crash at boot. Is that the desired forensic signal, or should we add a startup check that asserts the column does NOT exist?

## 11. Codex adversarial review questions (for the round-1 review)

1. **System member with no `members` row in the system workspace. [RESOLVED in r2 — see #6.]** What if `workspace://system` exists but its `members` list does not include `entity://user/system/admin` (boot order race, snapshot misload, OR — as r1 confirmed — at boot in general, since `ensure_system_workspace/0` seeds an empty members list)? `list_workspaces_for/2`'s admin shortcut path would not fire on `member_of_system?/1` for the admin — they'd see only workspaces from the cap-scope branch (which, for a bootstrap admin holding `kind: :any, behavior: :any, instance: :any, workspace_uri: :any, ...`, contributes NOTHING — because `:any` is filtered out in the cap-scope branch). r2 closes this: the admin shortcut also fires on `holds_admin_caps?(caps)`, which matches the bootstrap wildcard shape directly. The boot-order question is now moot — the bootstrap admin's authority is cap-derived (via `SystemPrincipal.caps("system://bootstrap")`), not membership-derived.

2. **Caps minted by `system://workspace-loader` (closed catalog principal).** The cleanup mix task dispatches as `system://workspace-loader`. Does `list_workspaces_for/2` ever receive caps held by `system://workspace-loader`? If yes, does the cap-scope branch produce the right answer? (Likely NO — operator-facing surfaces don't load workspace-loader caps; but verify.)

3. **The invariant test §5 — can it pass with a partial impl?** Specifically: can an impl that returns `member_of_workspaces(caller_uri)` alone (dropping the cap-scope branch entirely) pass INV-4? — No (INV-4's `delegated_workspace_admin` is not a member of `team-alpha`; would return `[]`). Can it pass INV-1 / INV-2 / INV-3? — INV-1 yes (`[]`), INV-2 yes (`[team-alpha]`), INV-3 yes IF the admin shortcut is also implemented. So a partial impl that has membership + admin-shortcut but no cap-scope passes 3/4 of the four basic INVs; fails INV-4 + INV-6. The test gates the structural goal.

4. **The destructive DB migration (DROP COLUMN visible).** What ALTER TABLE behavior does SQLite have around DROP COLUMN? Verify: SQLite added native `ALTER TABLE … DROP COLUMN` in 3.35.0 (2021-03). Ecto's SQLite adapter (Exqlite) supports it. Any older sqlite_dev DB version that would fail? (Unlikely in 2026, but flag.) Operator-side post-merge: the operator's working dev DB has the column; the migration removes it. The schema's removed `field :visible, :boolean, default: true` matches post-migrate. Any path the migration could fail silently? (E.g. SQLite limitation: if there's an active index on the column. There isn't one — the migration at `20260602000000_phase9_pr8_workspace_visible.exs` did not add one. Verify.)

5. **Does dropping the boolean break any operator-facing pinned artifact?** Per §9.1, mix tasks do not reference visible. Per §9.4, no public API. The grep audit is complete. Are there pinned snapshot files / fixtures in `apps/*/test/support/fixtures/` that would deserialize an old `Workspace.Store.decoded()` map with `visible: ...` and break? (Likely NOT — fixtures don't typically serialize internal maps; they create rows via `Store.create/2`. Verify by grep.)

6. **The cross-workspace cap path. [CONFIRMED in r1 — fix folded into §3.3 in r2.]** `holds_cross_workspace_admin_cap?/1` matches `kind: :workspace, behavior: Workspace, action: :any, instance: :any, workspace_uri: :any` (`identity.ex:738-744`). The admin caller's primary cap (bootstrap shape) has `kind: :any, behavior: :any, action: :any, ...` — NOT `kind: :workspace`, so it does NOT pass `holds_cross_workspace_admin_cap?/1`. It DOES pass `holds_admin_caps?/1` (`identity.ex:835-868`). Furthermore: at boot, `workspace://system`'s `members` is EMPTY (`apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:269-275` seeds an empty members list; the admin is added only by the LV "Promote to system" path at `users_live.ex:232`). So `member_of_system?/1` ALSO returns false for the bootstrap admin at boot. Without `holds_admin_caps?/1` in the shortcut, the bootstrap admin falls through to the cap-scope branch, which drops `workspace_uri: :any` per §3.3.b, returning `[]` — a regression vs today's `list_visible/0` (which used `list_all/0` for admins). **r2 resolution:** §3.3 admin shortcut is the three-predicate UNION `holds_admin_caps?(caps) or holds_cross_workspace_admin_cap?(caps) or member_of_system?(caller_uri)`. Appendix A diagram updated. The r1 static review identified this as CRIT-A1.

## 12. Rollback plan

Revert the merge commit. Post-revert state:
- The schema's `field :visible, :boolean, default: true` is restored.
- The DB column is GONE (the migration ran). The schema-load mismatch — `field` declared, no column — crashes on every `Repo.all(Workspace)` call.
- **Operator MUST also revert the migration**: `MIX_ENV=dev mix ecto.rollback --step 1` restores the column.

This is a TWO-STEP revert (code + DB). The PR description's revert plan documents both. Cost: operator runtime; benefit: explicit + audited rollback rather than a silent backward-compat shim. Per `feedback_let_it_crash_no_workarounds`.

The 2-step revert is the safety net acknowledgment, not a defense against the change. If this SPEC's design is wrong, the revert is feasible; the SPEC's `:any` interaction (§8) and the §5 invariant test give multiple structural gates BEFORE a revert would be the right answer.

---

## Appendix A — Sequence diagram (mount-time flow)

```
LiveAuth.on_mount/4         (apps/ezagent_web/lib/ezagent_web/live_auth.ex)
  │
  │  caller_uri ← parse_entity_uri(session["entity_uri"])
  │  caps      ← Users.decode_caps(caller_uri)        ← already loaded today
  │
  ▼
Ezagent.Workspace.list_workspaces_for(caller_uri, caps)
  │
  │  cond:
  │    holds_admin_caps?(caps)                    → list_all()    -- bootstrap wildcard
  │    holds_cross_workspace_admin_cap?(caps)     → list_all()    -- structural workspace admin
  │    member_of_system?(caller_uri)              → list_all()    -- system-member promotion
  │    otherwise:                                 → union(
  │                                                   member_of_workspaces(caller_uri),
  │                                                   workspaces_for_caps(caps)
  │                                                 )
  │
  ▼
[Workspace.Store.decoded()]  — sorted by name ASC
  │
  ▼
LV assigns :workspaces        — used by AppShell.app_shell perspective rendering
```

## Appendix B — Why this SPEC is medium-length

The SPEC is longer than the action-axis SPEC because it sweeps across MORE call sites (12 file:line edits vs. ~3 cap struct edits) AND requires an upstream SPEC amendment (Phase 9 PR-8 §13). The decision is small; the carrying-out is mechanical. The mechanical detail is in §4.2's tables, not in §3's semantics. Reviewers focus §3 (semantics) + §5 (invariant test); the rest is implementation manifest.

## Appendix C — Why r1 leaves §10 OQs unresolved

Per `feedback_brainstorming` discipline — when a decision branches into a side-question that doesn't gate the structural answer, flag it as OQ and proceed. The 6 OQs in §10 each have a default answer in this SPEC (OQ-1: accept both shapes; OQ-2: caller passes caps; OQ-3: in-memory filter; OQ-4: promote to public; OQ-5: skip wildcards from non-admin in cap-scope; OQ-6: no startup check, schema mismatch is the signal); Allen may confirm or override on any one. The impl subagent proceeds with the defaults if Allen does not override.
