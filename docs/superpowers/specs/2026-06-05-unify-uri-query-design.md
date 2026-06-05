# Unify URI Query — Design Spec

**Status:** ready for codex adversarial-review → implementation. Authored 2026-06-05 (Claude + Allen, via Feishu design session). Branch/worktree: `unify-uri-query` (off `main` @ 53f3c48b, post `domain_chat → domain_instance_message` rename).

**Root cause this fixes (Allen's framing):** Two coupled defects, not "the cc_ flavor bug":
1. **URI inconsistency** — URIs encode mutable/secondary/creation-time attributes (agent **flavor** as a name prefix; session **template** as a segment) and the segment order (`<type>/<workspace>`) does not reflect the real scoping hierarchy (type is workspace-scoped).
2. **Missing query capability** — there is no single, sanctioned way to (a) construct a URI or (b) read an entity attribute; code hand-concatenates URI strings (~3800 literals) and hand-parses attributes out of them (`String.split` on the path), so the same thing is done many divergent ways and drifts (the `cc_` orchestrator bug was one symptom).

The fix targets the root cause AND prevents recurrence (a scan test), per [[feedback_systematic_fix_over_local_entropy]].

**No data migration:** the system is not in production. Existing dev data is wiped + re-seeded ([[feedback_e2e_in_docker_fresh_seed]]). This is a **pure code change** — so we adopt the clean final convention directly, no back-compat shims ([[feedback_let_it_crash_no_workarounds]]).

---

## 1. The invariant

> 1. A URI is an **opaque, stable identifier** carrying ONLY: scheme + the **workspace** tenant segment + the structural **type** axis + a stable **name**.
> 2. **Uniform shape, workspace-first:** `<scheme>://<workspace>/<type>/<name>` for the per-tenant schemes (because `type` is scoped *within* a workspace — see §2).
> 3. URIs are **constructed** only through typed builders in `Ezagent.URI` (never hand-concatenated).
> 4. Entity **attributes** (agent flavor, orchestrator/role, session template, …) are **stored** and read only through `Ezagent.UriQuery.resolve/2` (never parsed out of a URI string).

A `#30` scan test enforces (3) and (4) mechanically and fails on any violation → recurrence is structurally prevented.

This is the same principle already accepted for identifiers: [[feedback_uuid_is_canonical_identifier]] (canonical id is opaque; mutable attributes are looked up, never keyed-on).

---

## 2. URI structure — workspace-first, and why

**Change the universal per-tenant shape from `<scheme>://<type>/<workspace>/<name>` to `<scheme>://<workspace>/<type>/<name>`.**

Rationale (Allen): `type` is **workspace-scoped**, so workspace is the outer namespace. Confirmed in code — default *session templates are seeded per workspace* (#559: `seed_default_session_templates_for_existing_workspaces`, `ensure_default_session_template(workspace_uri)`), so workspace A's `default` template and workspace B's `default` are different entities. Putting workspace first makes the URI read as the real containment hierarchy (workspace ▸ type ▸ name) and aligns identity with the tenancy/routing boundary.

The 6 registered schemes (`apps/ezagent_core/lib/ezagent_core/application.ex:185`): `entity` · `workspace` · `session` · `template` · `resource` · `system`. The `type` axis per scheme:
- `entity://<workspace>/<type>/<name>` — `type ∈ {user, agent, worker}` (structural Kind; stays, but **drop the `<flavor>_` prefix from the agent name** — flavor is an attribute, §4).
- `session://<workspace>/<template>/<name>` — template now correctly *after* workspace (it is workspace-scoped). (Codex: confirm whether template stays as the type-axis value or whether session collapses to `session://<workspace>/<name>` with template purely stored — **lean: keep it as the type-axis value** so all schemes keep the uniform 3-segment shape; it is never parsed for behavior, only constructed/displayed.)
- `workspace://<name>` and `system://<type>/<name>` — cross-cutting; keep their shape (no workspace segment by definition). Codex confirms these are exempt from the reorder.

`entity://<type>` keeping `user/agent/worker` is NOT a violation — that is the immutable structural Kind the URI legitimately routes on. Only **flavor** (agent) is the offending attribute baked into the agent name.

---

## 3. Construction side — typed builders in `Ezagent.URI` (mandatory)

Today `Ezagent.URI` has only string constructors (`new!/1`, `parse/1`); the segment order therefore lives in ~3800 hand-built string literals. Add typed builders so the order is defined in **one place**:

```elixir
# in apps/ezagent_core/lib/ezagent/uri.ex (codex finalizes signatures)
Ezagent.URI.entity(workspace, type, name)          # type :: :user | :agent | :worker
Ezagent.URI.session(workspace, template, name)
Ezagent.URI.template(workspace, type, name)
Ezagent.URI.resource(workspace, type, name)
Ezagent.URI.workspace(name)
Ezagent.URI.system(type, name)
```

- Workspace-first order is encoded ONCE here. A future reorder = edit these builders + the centralized accessors (`instance/1`, `entity_workspace_uri/1`, `subresource/1`) — NOT 3800 call sites.
- **Mandatory everywhere, including tests** (Allen chose option (1)). Replace all ~3800 `"<scheme>://…"` literals with builder calls (mechanical codemod). The scan then forbids any raw `<scheme>://` string construction outside `Ezagent.URI` itself.
- For test readability, add a thin helper/sigil (e.g. `~u"…"` parsing+validating at compile time, or `Ezagent.URI.test_*` helpers) so tests stay legible while still routing through the canonical parser. Codex picks the ergonomic form; it must NOT reintroduce hand-built ordering.

Accessors that parse positions (`instance/1`, `entity_workspace_uri/1`, `subresource/1`, the `host:`/`path:` matches) are already centralized in `Ezagent.URI` — update them for the new order in one place.

---

## 4. Read side — `Ezagent.UriQuery` registry-dispatcher

**Why a registry, not a static facade:** `Ezagent.URI`/`UriQuery` live in `ezagent_core`, and `ezagent_core` depends on **no** domain (verified: domains depend on core, never the reverse). A static facade in core therefore *cannot* call into domain stores. So `UriQuery` is a thin **dispatcher**; each domain **registers** its attribute resolvers at boot — exactly the codebase's established pattern (10 existing registries incl. `ezagent_core/.../agent_flavor_registry.ex`, `scheme_registry.ex`, `spawn_registry.ex`). This also satisfies the plugin-isolation north star ([[feedback_north_star_plugin_isolation]]): a new flavor/plugin adds its own query without touching core.

```elixir
# core (apps/ezagent_core/lib/ezagent/uri_query.ex)
Ezagent.UriQuery.register(attr :: atom, resolver :: (term -> {:ok, term} | :none | {:error, term}))
Ezagent.UriQuery.resolve(attr :: atom, arg) :: {:ok, term} | :none | {:error, term}
```

Core attribute resolvers registered by their owning domains at boot:
| attr | registered by (domain Application.start) | resolver reads |
|---|---|---|
| `:flavor` | cc/codex/curl flavors (or instance_message) | `AgentFlavorRegistry` / `AgentTemplate.flavor` (NOT the URI prefix) |
| `:orchestrator` | `ezagent_domain_instance_message` | session's new stored `orchestrator_uri` field (NOT `derive_orchestrator_uri/2`) |
| `:member_by_role` | `ezagent_domain_instance_message` | member `:role_name` facet on the chat slice |
| `:session_template` | `ezagent_domain_instance_message` | session's stored template assoc |

**Add-a-capability workflow** (e.g. "workspace-scoped default session template"):
1. In the owning domain's `Application.start/2`: `Ezagent.UriQuery.register(:default_session_template, &SessionTemplates.default_for/1)`.
2. Implement `SessionTemplates.default_for(workspace_uri)` in that domain.
3. Callers anywhere: `Ezagent.UriQuery.resolve(:default_session_template, workspace_uri)`.
→ **Zero edits to `ezagent_core`/`UriQuery`; zero edits to other domains.**

(Ergonomics: domains MAY expose typed wrappers in their own namespace delegating to `resolve/2`; the scan whitelists `UriQuery.resolve/2` either way.)

---

## 5. Storage slots

| Attribute | Stored today? | Where | Action |
|---|---|---|---|
| agent **flavor** | ✅ | `AgentTemplate.flavor` ("cc") + `AgentFlavorRegistry` | readers switch to `UriQuery.resolve(:flavor, _)`; drop `<flavor>_` from agent name |
| member **role** | ⚠️ partial | member `:role_name` facet | expose via `:member_by_role` resolver |
| **orchestrator** of session | ❌ | (re-derived) | **add stored `orchestrator_uri` field on session**, set once at create |
| session **template** | ✅ (known at create) | session working-copy / creation meta | expose via `:session_template`; stop relying on URI segment for behavior |

---

## 6. Phase #30 — the scan test (write FIRST, must fail)

A test that mechanically enumerates violations and **fails until zero**. It IS the completion gate + the recurrence guard.

1. Source the finite legitimate forms from `Ezagent.URI.SchemeRegistry` (6 schemes) — not a hardcoded list.
2. Statically scan `apps/**/*.{ex,exs}` (exclude `Ezagent.URI*` and `Ezagent.UriQuery` themselves) for:
   - **(C-construct)** any string literal / interpolation forming a `<scheme>://…` URI (hand-construction) outside the builders;
   - **(P-parse)** any `String.split`/`String.starts_with?`/regex extracting flavor/role/template/type from a URI's `path`/`host`/instance, outside the centralized accessors;
   - any call to the to-be-removed `derive_orchestrator_uri/2`, `derive_orchestrator_instance_name/1`, or the bridge `derive_flavor/1`.
3. Assert the violation set is **empty**. While #31 is in progress, the set is an explicit shrinking allowlist that must reach `[]`.

Prefer AST matching (`Code.string_to_quoted/1`) over grep for robustness; a grep first-cut is acceptable if AST proves too heavy (codex decides). The scan must be runnable as an ExUnit test in CI.

---

## 7. Phase #31 — fix-all (mechanical, one pass)

Drive the scan to zero:
1. **Builders + reorder:** add the §3 builders; codemod all ~3800 literals → builder calls in the new workspace-first order; update centralized accessors. (~740 non-test + ~3000 test sites — mechanical, scan-verified.)
2. **`UriQuery`:** add the core dispatcher; register the §4 resolvers in each owning domain's `Application`.
3. **Orchestrator:** add stored `orchestrator_uri` to session state; set once in `session_creator`; replace the 4 derive sites (`session.ex:369`, `session_creator.ex:470/1167`, `health.ex:105`) with `UriQuery.resolve(:orchestrator, session_uri)`. Remove `derive_orchestrator_uri/*`. Drop the hardcoded `template://agent/system/cc-orchestrator` pin (`session.ex:370`) — resolve the orchestrator template per the session's flavor/config.
4. **Flavor:** repoint bridge `derive_flavor/1` (`agent_bridge.ex:211`, `channel.ex:179`) → `UriQuery.resolve(:flavor, agent_uri)`. Drop `<flavor>_` from new agent names; convert display sites (mention_parser, agent.create, the 3 LiveViews) to read flavor via `UriQuery` rather than string-split.
5. Run the scan → `[]`; full suite green; tier2 live Feishu E2E still works (flavor now read from store).

Split into reviewable PRs (each gets codex review — [[feedback_codex_review_every_pr]]): (a) builders + codemod + accessors; (b) UriQuery + resolvers; (c) orchestrator store-the-URI; (d) flavor read-through + name-prefix drop; (e) the #30 scan flips to enforcing. Order: ship the scan as warn-only first, then each PR shrinks the allowlist, last PR makes it hard-fail.

---

## 8. Known offender audit (new-main paths @ 53f3c48b — starting list, scan finds the rest)

- **Orchestrator re-derive (→ stored `orchestrator_uri`):** `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:369,843,866`; `…/session_creator.ex:470,1167`; `…/orchestrator/health.ex:105`; hardcoded template pin `session.ex:370`.
- **Flavor parsed from URI (→ `UriQuery.resolve(:flavor,_)`):** `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge.ex:211`; `…/agent_bridge/channel.ex:179`.
- **`<flavor>_<name>` parse/assemble (audit display vs addressing):** `apps/ezagent_plugin_feishu/.../mention_parser.ex`; `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex`; `apps/ezagent_plugin_liveview/.../agent_detail_live.ex`, `agent_extensions_live.ex`, `agent_new_live.ex`; `…/session_creator.ex:~1530` (`"#{flavor}_#{session_unique}"`); cc/echo template prefix validation; cc-agents file-path layout.
- **URI literals (codemod target):** ~3805 `<scheme>://` literals across `apps/**/*.{ex,exs}`.

---

## 9. Decisions — locked + open

**Locked (this session):** workspace-first reorder ✅ · mandatory builders incl. tests ✅ · UriQuery registry-dispatcher ✅ · no data migration (code-only + dev reseed) ✅ · root-cause scope (not flavor-only) ✅.

**Open for codex / Allen:**
- session URI: keep template as the type-axis value (`session://<ws>/<template>/<name>`, uniform 3-seg, recommended) vs collapse to `session://<ws>/<name>` (template stored only).
- exact builder signatures + the test-ergonomic helper/sigil form.
- AST vs grep for the scan.

## 10. Constraints (codex must honor)
[[feedback_let_it_crash_no_workarounds]] (no shims/back-compat) · [[feedback_codex_companion_no_mix]] (codex verification static-only) · [[feedback_no_hack_use_cli_on_live_node]] (prototype on throwaway docker node only) · [[feedback_subagent_must_load_project_skills]] (load `esr-developer` + `elixir-phoenix-helper`) · [[feedback_north_star_plugin_isolation]] (registry keeps plugins out of core).

## 11. Verification gate (completion test — [[feedback_completion_requires_invariant_test]])
The #30 scan returns `[]` (hard-fail in CI) **and** full suite green **and** tier2 live Feishu E2E round-trip still works with flavor read from the store, not the URI.
