# Unify URI Query — Design Spec (rev 6)

**Status:** rev 6 — incorporates codex r1–r5 + Allen's locked decisions. r5 broadened the PR-B/PR-E gate from `check_agent_uri`-only to the COMPLETE flavor-prefix-dependency category (the gated category must equal the breaking change's full dependency set). The two breaking changes (PR-D reorder, PR-E prefix-drop) are each now gated on their complete dependency category. codex confirmed no flavor provider beyond cc/codex/curl/echo/np. Approach validated since r1; residual verification (that the implemented scan truly enumerates each category) belongs to implementation + per-PR review. Ready for implementation. Authored 2026-06-05 (Claude + Allen, Feishu session). Branch/worktree: `unify-uri-query` (off `main` @ 53f3c48b, post `domain_chat → domain_instance_message` rename).

**Root cause (Allen's framing):** Two coupled defects, not "the cc_ flavor bug":
1. **URI inconsistency** — URIs encode mutable/secondary/creation-time attributes (agent **flavor** as a name prefix) and the segment order (`<type>/<workspace>`) does not reflect the real scoping hierarchy (type is workspace-scoped).
2. **Missing query capability** — no single sanctioned way to (a) construct a URI or (b) read an entity attribute; code hand-concatenates URI strings (~3800 literals) and hand-parses attributes/positions out of them, so the same thing is done many divergent ways and drifts. The `cc_` orchestrator bug was one symptom.

Fix the root cause AND prevent recurrence via a scan test ([[feedback_systematic_fix_over_local_entropy]]).

**No data migration:** not in production; dev data is wiped + re-seeded ([[feedback_e2e_in_docker_fresh_seed]]). Pure code change → adopt the clean final convention directly, no back-compat shims ([[feedback_let_it_crash_no_workarounds]]).

**codex r1 verdict was NO-SHIP** — it found the surface is larger than "mechanical": URI segments/prefixes are used as **dispatch, tenant authority, on-disk path, and routing/cap keys** in scattered places, and the registry has a known boot-race class. rev 2 addresses all four findings below.

---

## 1. The invariant

> 1. A URI is an **opaque, stable identifier** carrying ONLY: scheme + the **workspace** tenant segment + a structural **type** axis + a stable **name**.
> 2. **Uniform shape, workspace-first:** `<scheme>://<workspace>/<type>/<name>` for per-tenant schemes (type is scoped within a workspace — §2).
> 3. URIs are **constructed** only through typed builders in `Ezagent.URI` (never hand-concatenated).
> 4. Entity **attributes** (agent flavor, orchestrator/role, …) are **stored** and read only through `Ezagent.UriQuery.resolve/2` (never parsed out of a URI string).
> 5. The **type axis** value may be matched for *structural Kind routing* only (it is a closed/structural slot), but never used to carry or recover a *behavioral secondary attribute*. Agent **flavor must NOT live in the URI at all** (end state).

The `#30` scan enforces (3)(4)(5) mechanically and fails on any violation → recurrence is structurally prevented. Same principle as [[feedback_uuid_is_canonical_identifier]].

---

## 2. URI structure — workspace-first (LOCKED)

**Universal per-tenant shape: `<scheme>://<workspace>/<type>/<name>`** (was `<type>/<workspace>/<name>`).
Rationale: `type` is workspace-scoped — confirmed: default session templates are seeded **per workspace** (#559), so workspace A's `default` ≠ workspace B's. Workspace-first = the real containment hierarchy + aligns identity with the tenancy/routing boundary.

Per-scheme type axis:
- `entity://<workspace>/<type>/<name>` — `type ∈ {user, agent, worker}` (closed structural Kind; stays). **Drop the `<flavor>_` prefix from the agent name entirely** (§6 prerequisite). End state: `entity://<ws>/agent/<name>`, no flavor anywhere in the URI.
- `session://<workspace>/<template>/<name>` — **LOCKED option (i):** template stays as the type-axis value, 3-segment uniform. **Carve-out:** template may be matched structurally for routing/Kind but the scan FORBIDS parsing it to recover a behavioral attribute; the session's template association is read via `UriQuery.resolve(:session_template, _)` from storage, not from the URI. (Template is fixed at create ≈ immutable, so it is an acceptable structural type-axis value, analogous to entity's user/agent/worker.)
- `workspace://<name>`, `system://<type>/<name>` — cross-cutting, no workspace segment; **exempt from the reorder** (codex to confirm each).

### codex r1 HIGH-1 — positional parsing is NOT centralized (security-sensitive)
The "one-place accessor" premise is **wrong**. Tenant/position parsing is duplicated in callers that assume the OLD order; under the reorder they would bind to the wrong segment:
- `apps/ezagent_core/lib/ezagent/capability.ex:581-622` `workspace_of` → `workspace_from_3seg_path` assumes `<type>/<workspace>/<name>` (cap authority!).
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex` derives workspace from the first session path segment and builds worker URIs from it.
- Plus scattered `%URI{host:, path:}` pattern matches and `URI.to_string`-as-map-key flows.

**Required:** before the codemod, produce a COMPLETE inventory of every positional URI read (`%URI{host:…, path:…}` matches, all `workspace_of`/instance/subresource/worker/session derivations, URI-string key paths) and consolidate them onto `Ezagent.URI` accessors / `UriQuery`. The #30 scan must flag `%URI{host:, path:}` positional matches **outside** a narrow allowlist (the `Ezagent.URI` module). This is itself part of the "single query" goal: `capability.workspace_of` etc. become thin callers of `Ezagent.URI.workspace_of/1`.

---

## 3. Construction side — typed builders in `Ezagent.URI` (mandatory, incl. tests)

Today `Ezagent.URI` has only string constructors (`new!/1`, `parse/1`); the order lives in ~3800 literals. Add typed builders so order is defined ONCE:

```elixir
Ezagent.URI.entity(workspace, type, name)   # type :: :user | :agent | :worker
Ezagent.URI.session(workspace, template, name)
Ezagent.URI.template(workspace, type, name)
Ezagent.URI.resource(workspace, type, name)
Ezagent.URI.workspace(name)
Ezagent.URI.system(type, name)
```
- Workspace-first order encoded once here + in the centralized accessors (`instance/1`, `entity_workspace_uri/1`, `subresource/1`) — but see §2 HIGH-1: also consolidate the *duplicated* parsers.
- **Mandatory everywhere incl. tests** (Allen: option (1)). Codemod all ~3800 literals → builder calls. Scan forbids raw `<scheme>://` string construction outside `Ezagent.URI`.
- Add a test-ergonomic helper/sigil (e.g. `~u"…"` parse+validate at compile time) so tests stay legible without hand-built ordering.

---

## 4. Read side — `Ezagent.UriQuery` registry-dispatcher + readiness (codex r1 HIGH-3)

**Why a registry:** `Ezagent.URI`/`UriQuery` live in `ezagent_core`, which depends on NO domain (verified). A static facade can't call domains → `UriQuery` is a thin dispatcher; each domain **registers** resolvers at boot (established pattern: 10 registries incl. `agent_flavor_registry`, `scheme_registry`, `spawn_registry`). Satisfies plugin isolation ([[feedback_north_star_plugin_isolation]]).

```elixir
Ezagent.UriQuery.register(attr :: atom, resolver :: (term -> {:ok, term} | :none | {:error, term}))
Ezagent.UriQuery.resolve(attr :: atom, arg) :: {:ok, term} | :none | {:error, {:no_resolver, atom}} | {:error, term}
```

**Readiness semantics (REQUIRED — this umbrella already hit this exact race):** ExternalMirror `boot_reconciler.ex:31-48` had to add a retry loop because it called `SpawnRegistry` before the `session` handler registered (`{:error, {:no_spawn_fn, "session"}}`, leaving bindings unreconciled). So:
- **Unregistered resolver ≠ missing data.** `resolve/2` returns a DISTINCT fail-loud `{:error, {:no_resolver, attr}}` (never silently `:none`). `:none` means "resolver ran, no value".
- **Boot-time callers** must use a bounded retry / after-boot barrier (reuse the `boot_reconciler` pattern); steady-state callers treat `{:no_resolver,_}` as a crash-worthy bug.
- Register core resolvers as early as possible in each owning domain's `Application.start/2`.
- **Tests:** call `resolve/2` before registration (expect `{:error,{:no_resolver,_}}`) and exercise cross-app startup ordering.

Resolvers (registered by owning domain):
| attr | owner | reads |
|---|---|---|
| `:flavor` | every `agent_flavors/0` provider (cc/codex/curl/echo/np) | `AgentFlavorRegistry` / stored `AgentTemplate.flavor` (NOT URI) |
| `:orchestrator` | instance_message | session's stored `orchestrator_uri` field |
| `:member_by_role` | instance_message | member `:role_name` facet |
| `:session_template` | instance_message | session's stored template assoc |

**Add-a-capability workflow** (e.g. workspace-scoped default template): (1) `UriQuery.register(:default_session_template, &SessionTemplates.default_for/1)` in the owning domain's `Application`; (2) implement the resolver there; (3) callers `UriQuery.resolve(:default_session_template, ws)`. **Zero core/other-domain edits.**

---

## 5. Storage slots

| Attribute | Stored today? | Where | Action |
|---|---|---|---|
| agent **flavor** | ✅ | `AgentTemplate.flavor` + `AgentFlavorRegistry` | §6 prerequisite makes ALL consumers read it; then drop URI prefix |
| member **role** | ⚠️ | member `:role_name` facet | expose via `:member_by_role` |
| **orchestrator** of session | ❌ | (re-derived) | add stored `orchestrator_uri` on session, set once at create |
| session **template** | ✅ | session working-copy / creation meta | expose via `:session_template` (URL segment kept structurally per §2 (i), never parsed) |

---

## 6. PREREQUISITE sub-phase — flavor is DISPATCH, not display (codex r1 HIGH-2)

**This MUST land before dropping the `<flavor>_` prefix.** The prefix is a live Kind/flavor resolution + validation mechanism:
- `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex:1028-1044` resolves an agent's Kind by **splitting the entity-name prefix** (cc has NO cc-specific Kind module — flavor lives only in `entity://agent/<ws>/cc_<name>`).
- **Every** plugin's template `check_agent_uri` **rejects** an `agent_uri` whose name prefix ≠ flavor. This is the FULL set of registered flavor providers, not a hand-list — currently cc/codex/curl/echo **and `np`** (`apps/ezagent_plugin_np/lib/ezagent/template/np_agent.ex:78-103` still `String.split`s `entity_name`, accepts only `flavor == "np"`, returns `:missing_flavor_prefix` for prefixless names; `np` ships — `apps/ezagent_web/mix.exs:102`). codex r2 HIGH: omitting `np` would break it after the prefix drop.
- On-disk config-dir paths embed it: `cc-agents/<ws>/<flavor>_<name>/` (`sandbox/config_dir.ex`, workspace behavior path builders).

So a prefixless agent currently fails spawn / lifecycle / bridge delivery / template instantiation / config-dir resolution.

**Prerequisite work (own PR(s), before §7 prefix drop):**
1. Replace name-prefix Kind/flavor resolution with a **stored** lookup — `UriQuery.resolve(:flavor, agent_uri)` reading `AgentTemplate.flavor` / `AgentFlavorRegistry`; the instance_message Kind resolver uses that, not `String.split`.
2. **Registry-driven (codex r2):** enumerate EVERY registered flavor provider via the flavor registry (`AgentFlavorRegistry` / each plugin's `agent_flavors/0`) — do NOT hand-list. Convert each provider's `check_agent_uri` to validate against stored flavor, not the prefix. Currently that set is cc/codex/curl/echo/np; a future plugin is covered automatically. The #30 scan (§8) fails on ANY remaining `check_agent_uri` that prefix-splits, so a missed plugin cannot slip through.
3. Make config-dir / on-disk path builders take flavor from storage (paths may keep flavor as a directory component derived from the stored attr — that's a path, not a URI; acceptable).
4. Audit + convert: Domain.Agent lifecycle, instance_message Kind resolver, agent_bridge `derive_flavor` (`agent_bridge.ex:211`, `channel.ex:179`), mention_parser, `ezagent.agent.create`, LiveView (agent_detail/extensions/new), and **all** plugin template validators (cc/codex/curl/echo/np — driven from the flavor registry, step 2).
5. Only when nothing depends on the prefix for behavior: **drop `<flavor>_` from agent names** (end state: no flavor in any URI). Reseed dev.

---

## 7. Phase plan (codex r1: avoid leaving main semantically broken between PRs)

Order matters — each PR keeps main green. **Per-category gating principle (codex r3+r4):** the #30 scan is NOT monolithically deferred to PR-F. Each scan CATEGORY hard-fails at the PR that establishes the safety its corresponding breaking change relies on, and that breaking change's PR is explicitly gated on the category being green. PR-F is only the final catch-all that flips any remaining warn-only categories to hard-fail. Concretely:
- **flavor-prefix-dependency category (the COMPLETE §6 set, codex r5)** → hard-fails at **PR-B**, gates **PR-E** (prefix drop). This category is NOT just `check_agent_uri` — it is EVERY prefix-parse / derived-flavor-from-name usage: the instance_message Kind resolver (`application.ex:1028-1044`), `agent_bridge.derive_flavor` (`agent_bridge.ex:211`, `channel.ex:179`), `mention_parser`, `ezagent.agent.create`, LiveView (agent_detail/extensions/new), `session_creator` (`~1530`), config-dir/path builders, and all `agent_flavors/0` providers' `check_agent_uri`. A gate narrower than the breaking change's full dependency set is a gap.
- reorder-sensitive categories (positional URI reads outside `Ezagent.URI`; raw affected-scheme string construction outside the builder/sigil allowlist; hand-built URI map/cap/routing keys; tenant/worker derivations outside `Ezagent.URI`/`UriQuery`) → hard-fail at **PR-C**, gate **PR-D** (reorder).

- **PR-0 (#30 scan, warn-only):** AST scan enumerating violations (broadened per §8); reports, doesn't fail. Establishes the shrinking allowlist.
- **PR-A (UriQuery core):** dispatcher + readiness semantics + `:flavor`/`:orchestrator`/`:member_by_role`/`:session_template` resolvers registered. Tests incl. pre-registration + boot-order.
- **PR-B (flavor prerequisite, §6):** all flavor/Kind resolution + validators + paths read stored flavor. NO prefix drop yet (URIs unchanged) — main stays green. **HARD GATE (codex r3+r5):** PR-B does NOT complete until the **entire flavor-prefix-dependency category** returns **zero** — i.e. the COMPLETE §6 set (Kind resolver, `agent_bridge.derive_flavor`, mention_parser, `ezagent.agent.create`, LiveView flows, `session_creator`, config-dir/path builders, and all `agent_flavors/0` providers' `check_agent_uri`), NOT just `check_agent_uri`. This category hard-fails here (not warn-only) even though the rest of the #30 scan stays warn-only until PR-F. This whole-category zero is the proof PR-E depends on.
- **PR-C (builders + consolidate positional parsers, §2/§3):** add `Ezagent.URI` builders; consolidate `capability.workspace_of`, worker_spawn derivation, all `%URI{host,path}` matches onto accessors. NO reorder yet. **HARD GATE (codex r4):** PR-C does not complete until the reorder-sensitive scan categories return **zero** — zero positional URI reads outside `Ezagent.URI`, zero raw affected-scheme construction outside the builder/sigil allowlist, zero hand-built URI map/cap/routing keys, zero tenant/worker derivations outside `Ezagent.URI`/`UriQuery`. This is the proof PR-D depends on.
- **PR-D (codemod reorder):** flip to workspace-first; codemod ~3800 literals → builders in new order; update accessors. **Precondition (codex r4):** PR-C reorder-sensitive categories are green — PR-D must not merge otherwise. Reseed dev. tier2 E2E re-verify.
- **PR-E (drop flavor prefix):** remove `<flavor>_` from agent names. **Precondition (codex r3+r5):** the PR-B **whole flavor-prefix-dependency category** is green (zero — the complete §6 set, not only `check_agent_uri`) — PR-E must not merge otherwise. Reseed dev.
- **PR-F (#30 hard-fail):** allowlist is empty; scan enforces in CI. Completion gate.

---

## 8. #30 scan — BROADENED (codex r1)

Beyond `String.split`/literals, the scan must catch:
- `%URI{host: …, path: …}` **positional** pattern matches outside `Ezagent.URI`.
- all `workspace_of`/tenant-derivation + worker/session URI derivations outside `Ezagent.URI`/`UriQuery`.
- hand-built `<scheme>://` strings: interpolation `#{}`, `<>` concatenation, sigils, and interpolation **embedded inside larger strings**.
- URI-as-string map/cap **keys** and routing **receiver** strings built by hand.
- plugin template `check_agent_uri` validators that parse the name prefix — iterate ALL `agent_flavors/0` providers (cc/codex/curl/echo/np/future); fail on any remaining prefix split. **This sub-rule hard-fails at PR-B completion and gates PR-E** (codex r3), even while the rest of the scan is warn-only until PR-F.
- on-disk path builders that parse a URI for flavor/workspace (`Path.join`, config_dir).
AST matching (`Code.string_to_quoted/1`) strongly preferred over grep for the embedded-interpolation + pattern-match cases.

---

## 9. Known offender audit (new-main paths @ 53f3c48b — starting list; scan finds the rest)
- Orchestrator re-derive → stored `orchestrator_uri`: `instance_message/.../entity/session.ex:369,843,866`; `.../session_creator.ex:470,1167`; `.../orchestrator/health.ex:105`; hardcoded `template://agent/system/cc-orchestrator` pin `session.ex:370`.
- Flavor parsed/dispatched: `agent_bridge.ex:211`, `agent_bridge/channel.ex:179`; **Kind resolver** `instance_message/application.ex:1028-1044`; plugin `check_agent_uri` for ALL flavor providers — cc (`cc_agent.ex:~363`), echo (`echo_agent.ex:~114`), **np (`np_agent.ex:78-103`)**, codex, curl; `mention_parser.ex`; `ezagent.agent.create.ex`; LiveView agent_detail/extensions/new; `session_creator.ex:~1530` `"#{flavor}_#{session_unique}"`; config-dir paths `sandbox/config_dir.ex` + workspace path builders.
- Positional/tenant parsing (HIGH-1): `capability.ex:581-622`; `external_mirror/worker_spawn.ex`; scattered `%URI{host,path}` matches.
- Boot-race precedent to mirror: `external_mirror/boot_reconciler.ex:31-48`.
- Session reconstruction relying on class segment: `instance_message/.../orchestrator/mcp_server.ex` (enumerates snapshots).
- URI literals (codemod): ~3805 across `apps/**/*.{ex,exs}`.

## 10. Decisions — LOCKED
workspace-first reorder ✅ · mandatory builders incl. tests ✅ · UriQuery registry-dispatcher + fail-loud readiness ✅ · no data migration (code + dev reseed) ✅ · root-cause scope ✅ · **session = (i) 3-seg `session://<ws>/<template>/<name>`, template a carved-out structural type-axis, never parsed** ✅ · **flavor removal split into a prerequisite sub-phase (§6); end state = no flavor in any URI** ✅.

## 11. Constraints
[[feedback_let_it_crash_no_workarounds]] · [[feedback_codex_companion_no_mix]] (codex static-only) · [[feedback_no_hack_use_cli_on_live_node]] · [[feedback_subagent_must_load_project_skills]] (`esr-developer` + `elixir-phoenix-helper`) · [[feedback_north_star_plugin_isolation]] · [[feedback_codex_review_every_pr]].

## 12. Verification gate ([[feedback_completion_requires_invariant_test]])
#30 scan returns `[]` (hard-fail in CI) — incl. positional matches + dispatch + cap/receiver keys + plugin validators — AND full suite green AND tier2 live Feishu E2E round-trip still works with flavor read from storage and no flavor in any URI.
