# SPEC — Caps cleanup v1 (3-issue architectural rectification)

**Status:** **r4 (REVISED post-revert).** 2026-05-25. Issue 1 IMPLEMENTED (PR-CC-1 #345 merged). Issue 2 IMPLEMENTATION REVERTED (PR-CC-2a #347 + PR-CC-2b #348 reverted via #349); the `struct → string` cap representation switch this SPEC originally specified is now **withdrawn**. Issue 2's *structural* goals (declarative `Behavior.required_caps/0`, `Entity.holds_cap?/2` at the boundary, dispatch step 5.5 as the sole cap-check chokepoint) **remain valid** and will be re-implemented with the existing `%Ezagent.Capability{}` struct shape kept intact (wildcards via the existing `:any` atom field values). Issue 3 NOT STARTED. See §0d r4 revision notes below for the full decision path.

**Prior status:** r3-FINAL (MERGED). 2026-05-25. Trust-model accepted; MED-1 dedupe fix applied; proceeded to impl (PR-CC-1/CC-2/CC-3).
**Tier:** `apps/ezagent_core/` framework rectification + sweep across every domain + plugin.
**Trigger:** Allen 2026-05-25 (Feishu) — three verbatim directives addressing accumulated cap-system pathology surfaced during the data-ownership-v2 / external-mirror-audit work:

1. "在代码中，完全不应该体现 admin_caps 的特殊性。admin 的特殊性是在验证权限的时候，通过 wildcard 匹配实现的"
2. "caps 的调用应该仅仅在 entity x behavior 的领域中实现。behavior 实现的时候，要求调用的 entity 需要持有某个权限，entity 中提供这个权限的凭证（目前就是简单的字符串）。所有其他的域理论上应该是透明不感知 caps 存在的"
3. "使用宏是必要的吗？还是可以通过其它方式更直接地完成？" (re: compile-time enforcement)

**Predecessors (all merged on `main`, none replaced):**
- `docs/superpowers/specs/2026-05-23-capability-registry.md` rev 4 — `Ezagent.CapabilityRegistry` single-entry registration. This SPEC supersedes that one for cap *enforcement*; the *cap-subject catalog* purpose collapses into Behavior callbacks directly.
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` rev 3 — `data_owner/1` callback + the principle that caps are CRUD authorization on a data class with a single legitimate grantor. This SPEC PRESERVES the data-ownership principle and the `data_owner/1` callback; it changes only how the cap is *represented* and *checked*.
- `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md` r1 — 4-gate enforcement + FacadeNonceTable for forgery resistance. This SPEC PRESERVES FacadeNonceTable; it is orthogonal to cap representation.
- `apps/ezagent_core/lib/ezagent/capability.ex` — the 6-field struct this SPEC simplifies.
- `apps/ezagent_core/lib/ezagent/capability/parser.ex` — the existing string grammar this SPEC promotes from "operator CLI input" to "the canonical wire format".
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` — the existing compile-time gate this SPEC extends.

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` (Allen 2026-05-05) — every "delete" in this SPEC is a hard delete. No `User.admin_caps()` deprecation period. No "if struct, convert to string at boundary" shim. The old call sites raise at compile time.
- `feedback_completion_requires_invariant_test` (Allen 2026-05-05) — each of the 3 issues gets an invariant test that fails when the architectural goal is unmet (§9).
- `feedback_north_star_plugin_isolation` (Allen 2026-05-05) — tiebreaker for design choices is "keeps plugin authors out of core". Issue 2 is the direct application of this principle.
- `feedback_uuid_is_canonical_identifier` (Allen 2026-05-12) — cap strings name *kinds of authority*, not user names. The instance URI does the identity binding.
- `feedback_bilingual_docs_convention` — Chinese mirror at `.zh_cn.md`.

**Companion:** `2026-05-25-caps-cleanup-v1.zh_cn.md`.

---

## 0d. r4 revision notes (post-revert; struct stays)

> 🔄 **This SPEC has been amended after implementation.** PR-CC-2a + PR-CC-2b landed the string-cap representation switch as designed, then were reverted via PR #349 on Allen's 2026-05-25 13:18 directive. The body of this SPEC (§5, §6, §7, §8, §9) below still describes the **withdrawn string-cap design** as historical record. The currently-in-force design is summarised in this §0d. Future PRs MUST reconcile against §0d, not against the literal text of §5–§9.

### r4.1 What was reverted + what was kept

| PR | Status | Notes |
|---|---|---|
| PR-CC-1 #345 (Issue 1 — ambient authority removal) | ✅ MERGED, KEPT — **but see §0d.1b below for catalog cap-shape gap** | `User.admin_caps/0` deleted; `Ezagent.SystemPrincipal.Catalog` (14 system principals) in place; 16 call sites migrated. The catalog's cap-string values were written under the r1–r3 string assumption; in struct-kept r4 those strings are currently rendered by `SystemPrincipal.caps/1` as wildcard `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any}` instead of the narrowing per-principal cap declarations the catalog table names. Named-principal audit trail works; least-privilege does NOT. PR-CC-2-v2 must convert each catalog entry to its exact `%Capability{}` spec — see §0d.1b for the blocking gate. |
| PR-CC-2a #347 (additive primitives: `Ezagent.Cap` matcher + `Behavior.required_caps/0` + `Kind.holds_cap?/2`) | ❌ REVERTED via #349 | The `Cap` module + all 19 Behavior annotations + 109 new tests deleted. |
| PR-CC-2b #348 (dispatch flip + boot seed system principals + dual-path) | ❌ REVERTED via #349 | Dual-path step 5.5 + wildcard substitution + 14 boot seeds + `workspace_scoped?/0` enforcement all undone. The boot-seeding *intent* survives in §0d.5 below but uses the existing struct-cap shape. |
| PR-CC-1 `SystemPrincipal.caps/1` (legacy-shape bridge) | ✅ STILL THERE, NOW PERMANENT | The bridge returned `[%Capability{}]`; r4 makes that the permanent shape. No longer "legacy" or "transitional" — it's the API. Rename if/when convenient. |
| `Ezagent.Capability` struct (6 fields) | ✅ KEPT in `apps/ezagent_core/lib/ezagent/capability.ex` | Wildcards already supported via `:any` atom on `kind` / `behavior` / `instance` / `workspace_uri`. Future cryptographic fields (signature, nonce, issued_at) extend the struct additively. |
| `Ezagent.CapabilityRegistry` ETS | ✅ KEPT | Single-entry registration discipline + `cap_subjects/0` callback both stay. The Single-Path principle (one chokepoint for cap subject declaration) is unchanged. |
| `Identity.list_caps_for/1` / `grant_cap/3` / `revoke_cap/3` | ✅ KEPT, struct shape | API + caller signatures stay; r4 forward work uses these as-is. |
| `caps_json` DB column | ✅ struct JSON, NOT migrated | The SPEC §5.8 `caps_schema_version v1→v2` migration is **withdrawn**. Existing rows keep the `[%Capability{...}]` JSON shape. |
| `ctx.caps` field | ✅ KEPT | The `Invocation` struct keeps its `caps :: [%Capability{}]` field. The SPEC §5.3 r2 HIGH-3 "delete ctx.caps" decision is **withdrawn** — `ctx.caps` is the snapshot dispatch/action bodies read for sub-cap decisions, and the snapshot-staleness pathology that motivated deletion is better addressed via the existing revision-CAS in §5.3 step 8.5 (r3-FINAL design) than by deletion.

### r4.1b SystemPrincipal.Catalog cap-shape gap (PR-CC-2-v2 blocking gate)

PR-CC-1's `Ezagent.SystemPrincipal.Catalog` (`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`) declares 14 principals with **string-valued cap entries** like `["session.external_mirror.*"]`, `["session.chat.send", "session.chat.system_message"]`, etc. — written when this SPEC's §4.1 still assumed string caps were the post-cleanup wire format.

After the r4 revert keeps struct caps, the bridge `SystemPrincipal.caps/1` does NOT parse those strings into per-cap `%Capability{}` specs. Inspect `system_principal.ex` lines ~138/151/174: every non-empty string list collapses to a single wildcard cap `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any, granted_by: principal_uri, granted_at: now}`. That is the same authority shape as the deleted `User.admin_caps/0` — broader than the catalog table's narrowing strings document.

**What works today:**
- Named-principal audit trail (`ctx.caller = system://boot-reconciler` etc.) is correct. `/admin/audit` shows the real operating principal.
- Catalog membership enforcement (`SystemPrincipal.ensure/2` rejects URIs not in the table) works.

**What does NOT work today:**
- Least-privilege. `system://chat-router` (declared as `["session.chat.send", "session.chat.system_message"]`) currently holds full wildcard authority, same as the bootstrap admin. A bug in `Behavior.Chat`'s system-message dispatch path could write to ANY session via the chat-router principal.

**PR-CC-2-v2 acceptance gate (c'):**
PR-CC-2-v2 MUST convert each catalog entry to the equivalent `%Capability{}` list. The catalog table value type changes from `[String.t()]` to `[%Capability{}]`. The conversion is mechanical (parse each existing string per §5.4 grammar's atom mapping → struct fields), with the parsed atom for `:behavior` derived from the catalog's "Operating context" column. Invariant test added in PR-CC-2-v2: every principal's caps list has no `%Capability{kind: :any, behavior: :any, instance: :any}` entry unless the principal is `system://bootstrap` (the only legitimate wildcard).

Until PR-CC-2-v2 lands, system principals run with broader-than-documented authority. This is **acceptable v1 limit** per `feedback_let_it_crash_no_workarounds` + SPEC §10.5 in-VM trust model (in-VM is trusted; a buggy Behavior writing via an over-broad system principal is bounded by deployment hygiene), but it is NOT acceptable post-v1 — the gate above is blocking.

### r4.2 Why string was reverted (Allen 2026-05-25 13:18)

> 仔细思考，我觉得应该 revert 回 struct，因为未来我们不可能简单的使用 string 匹配的形式，必然要通过 token 验证等密码学方式来确保 caps 的有效性，到时候，还是要转回 struct

Translation: the future cap-verification model will use cryptographic signatures (caller presents a token; system verifies the signature against issued caps) — that requires structured caps with metadata fields (signature, nonce, issued_at, granted_by). Migrating to string now and then re-migrating to struct + signature later is a wasted round-trip. Better to keep the struct from the start and add cryptographic fields additively when the verification work lands.

This forward-looking concern was **not represented in r1–r3** of this SPEC. r1–r3 optimised for plugin-author UX (`%{send: "session.chat.send"}` is shorter than struct construction) and IAM/RBAC-industry alignment, both of which remain true — but neither outweighs the round-trip cost when token verification is on the near-term roadmap.

### r4.3 What survives of Issue 2's structural goals (G2)

The original G2 outcome statement still applies:

> **G2 — Caps live only at Behavior × Entity.** `Behavior.required_caps/0` declares per-action [caps]. `Entity.holds_cap?/2` decides membership. `Invocation.dispatch/1` step 5.5 calls both. Every other module is cap-transparent.

The only change: `[caps]` is `%{required(atom()) => %Capability{}}` (struct-valued), not `%{required(atom()) => String.t()}`. Everything else about G2 — declarative caps at the Behavior boundary, single chokepoint at dispatch step 5.5, no scattered cap-checks in `_live` modules / plugin facades / hand-written predicates — is **still a goal worth pursuing**. The string vs struct decision was an implementation choice, not the architectural goal.

Concretely, the future Issue-2 PR (PR-CC-2-v2) re-attempts the boundary cleanup with struct-shape callbacks:

- `Behavior.required_caps/0 :: %{required(atom()) => %Capability{}}` — declarative struct map per action. Wildcards via `:any` atom fields (e.g. `%Capability{kind: :chat, behavior: Chat, action: :send, instance: :any, workspace_uri: :any, granted_by: ..., granted_at: ...}` for "any chat session, any workspace").
- `Entity.holds_cap?/2 :: (URI.t() | atom(), %Capability{}) :: boolean()` — default impl reads the entity's `:identity` slice's `caps` field, filters via `Capability.matches?/2` (existing function), returns boolean.
- Dispatch step 5.5: `needed = behavior.required_caps()[action]; if !Kind.holds_cap?(caller, needed), do: {:error, {:unauthorized, needed}}`. Same logical structure as PR-CC-2b's design, but the comparison operand is a struct, not a string.
- `Behavior.workspace_scoped?/0` callback: optional, default `true`. Step 5.6 gates cross-workspace dispatches via this.
- `CapabilityRegistry` ETS + `cap_subjects/0` + `dispatchable?/0` callbacks **all stay**. The original §5's "delete CapabilityRegistry" was a string-era simplification that is no longer warranted when struct caps remain.

### r4.4 What survives of Issue 3 (G3 — compile-time enforcement)

The original G3 outcome statement still applies, modulo the parse-strict check now becoming a struct-shape check:

> **G3 — Compile-time enforcement is data, not macros.** Every `@behaviour Ezagent.Behavior` module exports a valid `required_caps/0`. Build fails with a precise diagnostic if (a) the callback is missing, (b) the key set differs from `actions/0`, or (c) any value is not a valid `%Capability{}`.

`(c)` updates: "is a binary cap string parseable by `Cap.Parser.parse_strict/1`" → "is a `%Capability{}` struct whose fields match the parent Kind's `type_name/0` AND the Behavior's `state_slice/0`". §6.1 check 10 / 11 stay with adjusted predicates.

### r4.5 Migration plan amendment (§7 withdrawn)

The original §7 was 4 sub-PRs (CC-2a/2b/2c/2d) for the struct→string switch + DB migration. With struct kept, §7 reduces to a **single PR (PR-CC-2-v2)**:

1. Add `Behavior.required_caps/0` callback to `Ezagent.Behavior` (mandatory).
2. Add `Entity.holds_cap?/2` callback to `Ezagent.Kind` (mandatory) with default impl.
3. Annotate every Behavior with its `required_caps/0` map (struct shape).
4. Switch dispatch step 5.5 from `CapabilityRegistry.lookup_required_cap/3` (or whatever the current path is) to `behavior.required_caps()[action]` + `Kind.holds_cap?/2`.
5. Hard-delete any scattered cap-check code that the new chokepoint replaces (§1.2 Pathology B list).
6. Invariant test §9.2 — the 12 probes (P1-P12) for cap-transparency outside the chokepoint, **kept** with grep targets adjusted from string-shape literals to struct-construction literals.

No DB migration. No `caps_schema_version` bump. `caps_json` column shape unchanged.

### r4.6 Forward note — cryptographic cap validation (post-v1)

Out of scope for this SPEC, but documented here so the §0d decision is traceable to its motivation:

After PR-CC-2-v2 lands, the `%Ezagent.Capability{}` struct can grow optional fields additively without breaking the boundary discipline:

- `signature :: binary() | nil` — Ed25519 signature of `(kind, behavior, action, instance, workspace_uri, granted_by, granted_at, nonce, target_principal_uri)` by the granter.
- `nonce :: binary() | nil` — anti-replay.
- `issuer_pubkey_fingerprint :: binary() | nil` — fingerprint of the granter's signing key (looked up via a future `signing_keys` table).

`Capability.matches?/2` grows a signature-verification branch when `signature != nil`. The matching API stays the same shape; plugin authors don't change anything; the cryptographic upgrade is a single-PR additive change. Cap strings would have required re-introducing the struct first, then growing it — two PRs of churn instead of one.

The full threat model — replay-cache semantics, revocation list / TTL design, signing-key rotation, signature-verification failure modes (degrade-vs-deny, telemetry on bad signatures, audit-on-revoked-cap) — is **out of scope for this SPEC** and deferred to a future cryptographic-cap SPEC. The fields listed above are non-normative motivation showing the additive path exists; the future SPEC owns the formal specification.

### r4.7 Action items

1. ✅ This SPEC amendment (r4 notes) — landed in this PR.
2. ⛔ **BLOCKING for PR-CC-2-v2** — open follow-up `2026-05-25-caps-cleanup-v1-r4-impl.md` SPEC describing in concrete file:line terms: (a) `Behavior.required_caps/0` callback signature + return type; (b) `Entity.holds_cap?/2` callback + default impl; (c) PR-CC-2-v2 §9.2 12-probe invariant grep targets re-pointed to struct construction sites; (d) the catalog cap-shape conversion gate from §0d.1b; (e) §9.3 G3 compile-time check 10/11 struct-shape predicates. Without this sibling SPEC the PR-CC-2-v2 dispatch will hit the same SPEC-vs-implementation drift codex flagged in PR #350 r1.
3. ✅ Mirror this §0d into `.zh_cn.md` — done in this PR.
4. ⏳ Issue 3 (G3) compile-time enforcement: PR-CC-3 still planned, scoped to struct-shape checks.

### r4.8 Memories validated

- `feedback_let_it_crash_no_workarounds` — the revert is itself a let-it-crash decision: the string-cap shim (`SystemPrincipal.caps/1`, dual-path step 5.5, the Kind.holds_cap?/2 transitional struct→string filter) were anti-pattern shims that grew during PR-CC-2a/b implementation. The revert clears them in one move.
- `feedback_completion_requires_invariant_test` — Issue 2 is NOT complete because the boundary discipline has no test asserting it. PR-CC-2-v2 ships with the §9.2 12-probe invariant.
- `feedback_north_star_plugin_isolation` — plugin authors writing `required_caps/0` as struct maps is slightly more verbose than string maps. Mitigation: a `Ezagent.Capability.cap/N` constructor helper (`Capability.cap(:chat, Chat, :send)` builds the struct with sensible defaults for instance/workspace_uri/granted_by/granted_at) makes the call site only marginally longer than the string form. Net plugin-author-out-of-core property holds.

---

## 0c. r3-FINAL revision notes (what changed after codex r3)

Codex r3 returned three findings: HIGH-1 (principal forgery), HIGH-2 (system-caller workspace iso default), MED-1 (`Enum.uniq_by` in compile gate dedupes by Behavior alone). Allen 2026-05-25 ruling:

1. **HIGH-1 ACCEPTED as v1 limit.** Documented in new §10.5: the BEAM boundary is the trust boundary; in-VM principal forgery is out of scope for v1 cap enforcement, addressed by deployment hygiene + plugin code review. v2 will move `caller_uri` from dispatch parameter to server-stamped context.
2. **HIGH-2 ACCEPTED as v1 limit.** Documented in new §10.5: `system://` principals carry `workspace_uri: :any` by default; this is the documented contract for cross-workspace operations (BootReconciler, AdapterInstall, etc.), not a bug. Non-system callers remain workspace-iso-enforced per §5.5.
3. **MED-1 FIXED structurally.** §6.1 check 10 (`check_required_caps_values_parse_strict`) `Enum.uniq_by/2` key changed from `fn {_, _, b} -> b end` to `fn {k, a, b} -> {k, b, a} end`. The Behavior-only key silently dropped registrations of the same Behavior under different Kinds (or with different per-action cap subjects), leaving their required_caps unchecked. Triple-keyed dedupe collapses only TRUE duplicates.

Proceeding to impl. No r4 codex round per Allen 2026-05-25 manual call.

---

## 0b. r3 revision notes (what changed vs r2)

Codex r2 returned **needs-attention** with 3 HIGH + 1 MEDIUM. r3 closes all four structurally:

1. **HIGH fixed — §8.5 CAS lost-update race (was in §5.3 step 8.5).** r2's CAS compared CALLER revision against itself across cap-mutating dispatches. But `grant_cap` mutates the TARGET slice, not the caller's. Two concurrent grants on the same target T (with unchanged caller revision) both pass r2's CAS — last-write wins, the earlier grant silently dropped. r3 (a) snapshots the TARGET slice at new step 5.0b, (b) makes step 8.5's CAS check the TARGET's revision, (c) requires the mutation to commit via `Ezagent.Identity.cas_update_caps/2` — an atomic check-then-write via `:ets.select_replace/2` (not the racy `:ets.lookup` + `:ets.insert` pair). §9.6 grows two new invariants: a concurrent-grant lost-update test, and a 50-task contention test asserting every reported-ok grant survives in the final cap list.
2. **HIGH fixed — dispatch admission doesn't enforce SystemPrincipal.Catalog (was §5.3 step 5.0a + §4.x).** r2's catalog had compile-time check 11 (greps source literals) and boot-time `SystemPrincipal.ensure/1`. Both miss runtime-constructed `system://` URIs (test helpers spawning ad-hoc principals, hot-loaded code, atom-interpolated URIs). r3 adds **dispatch-time enforcement** at step 5.0a: if `caller.scheme == "system"`, MUST be in `Catalog.member?/1` — otherwise `{:error, :unknown_system_principal}` + telemetry `[:ezagent, :authz, :unknown_principal]`. §9.5 grows a new invariant that force-seeds an uncataloged `system://...` slice and asserts dispatch rejects it BEFORE step 5.5 — the only test that exercises layer 3 of the three-layer catalog enforcement.
3. **HIGH fixed — zh_cn §6.1 left as r1 binary-only check (was §6.1 in `.zh_cn.md`).** The Chinese SPEC's §6.1 retained r1's `check_required_caps_values_are_strings` (binary-only) instead of r2's `check_required_caps_values_parse_strict` + check 11 catalog enforcement. Per `feedback_bilingual_docs_convention`, both files must be parallel. r3 fully syncs `.zh_cn.md` §6.1 with the English content — no "see English" stubs.
4. **MEDIUM fixed — §9.2 G2 invariant used one hardcoded narrow probe (was §9.2 single regex).** A single grep alternation catches ~5 specific call shapes; a savvy bypass with different syntax slips through. r3 decomposes §9.2 into **12 probes** (P1-P12), each pinned to one of §1's pathologies (A: ambient authority, B: scattered cap-check, C: macro enforcement) or one of the 6 concerns. Includes probes for: ambient authority (P1-P2), scattered cap-check (P3, P8, P9, P11), discovery/registry leak (P4-P5), mutation API leak (P6-P7), caller spoofing (P10), macro declaration (P12). A 13th leak shape → a 13th probe + SPEC amendment is the regression-lock contract.

---

## 0a. r2 revision notes (what changed vs r1)

Codex r1 returned **needs-attention** with 4 HIGH + 1 MEDIUM. r2 closes all five structurally:

1. **HIGH fixed — migration widens workspace-scoped grants (was §5.8 conversion table).** r1's `CapMigration.convert/1` dropped the `workspace_uri` field on the assumption that the instance URI would carry workspace info. But for cap shapes with `instance: "any"` AND a concrete `workspace_uri` (e.g. the `User.default_caps/1` shape `{kind: :session, behavior: :any, instance: :any, workspace_uri: workspace://team}`), the migration produced a globally-scoped string like `"session.*"` — silently widening the original workspace-A grant into authorization on workspace B. r2 introduces a workspace suffix in the cap grammar (`;ws=<workspace_uri>`) AND extends the migration to preserve workspace dimension on every cap whose original `workspace_uri` is concrete. New invariant test §9.4 asserts no migrated cap authorizes a workspace it was not originally scoped to. Workspace iso (§5.5) gains a second arm: when a cap carries `;ws=` it constrains BOTH whether the cap matches AND the workspace check.
2. **HIGH fixed — system principal catalog not enforceable (was §4.1 / §4.2).** r1's `SystemPrincipal.ensure/2` accepted any `system://` URI and any cap list. r2 makes the catalog an executable allowlist: `Ezagent.SystemPrincipal.Catalog` (compile-time module) declares the 14 principals AND their permitted caps. `ensure/2` reads the catalog and rejects any URI not in it; the catalog is the single source of truth. A new invariant test §9.5 greps every `system://` URI literal in `apps/*/lib` and asserts it appears in the catalog. Compile-time check via `:ezagent_plugin_check` extension §6.1 check 11 — any module containing a `system://` URI literal that isn't in `SystemPrincipal.Catalog` fails the build.
3. **HIGH fixed — dispatch reads mutable slice without snapshot semantics (was §5.3).** r1's `read_caller_slice/1` did a fresh ETS read per dispatch with no version contract; concurrent grant/revoke could reach §5.5 / §5.6 / facade Gate 1-3 each seeing different cap states. r2 adds a cap-snapshot contract: `Ezagent.Identity.get_slice_versioned/1` returns `{caps :: [String.t()], revision :: pos_integer()}`. Dispatch reads it ONCE at dispatch admission (new step 5.0a) and propagates `{caps, revision}` through `ctx.caps_snapshot` for ALL downstream cap-consuming code (5.5, 5.6, facade gates). Cap mutations (`grant_cap`, `revoke_cap`) bump the revision; the action body's first CAS step (new step 8.5 — only for caps-mutating actions) verifies the snapshot revision still matches the entity's current revision before commit. If not, the action returns `{:error, :cap_snapshot_stale}` and the caller retries. Defines clear admission-time semantics that close the TOCTOU window.
4. **HIGH fixed — compile gate too weak (was §6.1 check 10).** r1 only verified values are binaries. r2 extends `:ezagent_plugin_check` to PARSE every `required_caps/0` value through `Ezagent.Cap.Parser.parse_strict/1` (new strict variant — rejects unknown kind atoms, unknown behavior atoms, malformed `@instance`, malformed `;ws=` suffixes). Cross-validates: cap's `kind` segment MUST match the parent Kind's `type_name/0`; cap's `behavior` segment MUST match the Behavior's `state_slice/0` OR `*`; cap's `action` segment MUST be one of the Behavior's `actions/0` OR `*`. Special strings `"*"` and `"cross-workspace:*"` are added to a SHORT explicit allowlist in the parser — documented, not undocumented exceptions. Runtime warn-only typo check (was §10.3) PROMOTED to compile-time hard failure.
5. **MEDIUM fixed — §0 OQs treated as ship-ready (was §0).** r2 moves the 6 OQs into "decisions" status with explicit closure rationale. The picked option becomes the decision; alternatives stay documented for traceability. PR-CC-2c (the irreversible migration sub-PR) gains a new acceptance gate: "all §0 decisions stamped 'Allen-approved YYYY-MM-DD' before merge." If Allen has not stamped a decision by then, PR-CC-2c blocks at review.

---

## 0. Decisions (formerly Open Questions)

Six decisions surfaced by brainstorm. Each carries the picked option as the SPEC's decision; alternatives stay documented for traceability. PR-CC-2c acceptance gate (§8) requires every decision stamped `Allen-approved YYYY-MM-DD` before merge — until then PR-CC-2c blocks at review.

Six questions surfaced by the brainstorm. SPEC currently picks the option marked **[picked]**; Allen approval flips any of them before implementation.

### OQ-CC-1 — Cap string format: does `@<instance_uri>` survive?

The existing `Capability.Parser` grammar already accepts `"chat.send@session://default/team/standup"` (kind.behavior@instance). Allen's verbatim says "目前就是简单的字符串" but does not pin whether instance-scoping survives.

- **[picked] Option A — Instance suffix DOES survive.** A cap string is `<kind>.<behavior>[.<action>|.*][@<instance_uri>]`. Without instance-scoping, the data-ownership-v2 invariant collapses: a session-owner cap (instance-bound to their session) cannot be distinguished from a global session-admin cap. Examples: `"session.chat@session://default/team/standup"`, `"workspace.workspace@workspace://team"`, `"*"`.
- Option B — Drop instance-scoping; caps become `<kind>.<behavior>` only. Simpler, but breaks data-ownership-v2 entirely. Would require a separate "scoped-by" mechanism (likely a 2-string-tuple), which is worse than just keeping the suffix.

**Why A:** preserves the structural invariant we just shipped (data-ownership-v2 rev 3), no new mechanism needed, the grammar already exists.

### OQ-CC-2 — Workspace iso mechanism after cap simplification

Today workspace iso lives in `Capability.matches?/2` via the `workspace_uri` field on the cap struct + dispatch step 5.6's `cross_workspace?/2` predicate. With strings, the cap no longer carries a workspace field.

- **[picked] Option A — Workspace iso becomes a per-Behavior callback `workspace_scoped?/0` (default `true`).** Cross-workspace bypass = caller is a member of `workspace://system` (existing Keycloak realm-admin model from Phase 9 PR-8) OR caller holds the explicit cross-workspace cap string `"cross-workspace:*"`. Dispatch step 5.6 keeps its position but reads the Behavior callback instead of cap struct fields.
- Option B — Workspace iso encoded in cap string as `@workspace://X.<rest>` prefix. Mixes two concerns into one syntax; harder to reason about; the suffix already does instance-scoping.
- Option C — Drop workspace iso from dispatch entirely; each Behavior does it in `invoke/4`. Violates "all domains transparent" — every Behavior writes the same check; classic primitive-in-each-plugin anti-pattern (memory `feedback_north_star_plugin_isolation`).

**Why A:** workspace iso is a structural property of *what data this Behavior operates on*, declared once per Behavior, enforced once at dispatch.

### OQ-CC-3 — Cap-only Behaviors (Presence pattern) after simplification

Today `Behavior.Presence` returns `dispatchable?/0 == false` — it exists only to declare a cap subject (`:online`) used by `NotificationSubscriptions` as an auth gate, without being a dispatch target. After simplification, the cap subject catalog goes away — the cap is just a string and the gate that consumes it reads `required_caps/0` from the Behavior.

- **[picked] Option A — Drop cap-only Behaviors entirely.** The pattern was a workaround for "I want to declare a cap subject without exposing a dispatchable action." Without a central subject catalog, the workaround is unnecessary: `Behavior.Presence` becomes a normal Behavior whose `:online` action is dispatchable (or it converts the gate-consumer to read the cap string directly without going through a Behavior). Audit shows exactly TWO cap-only Behaviors today: `Presence` and `Sandbox`. Both are migratable in 1-2 PRs of PR-CC-2.
- Option B — Keep `dispatchable?/0` as a Behavior callback. Preserves the existing pattern but keeps a vestigial concept around (a "Behavior" that cannot be invoked is conceptually a tag, not a Behavior).

**Why A:** simpler conceptual model; the pattern was load-bearing only because `CapabilityRegistry` existed; with `CapabilityRegistry` deleted, the pattern dissolves.

### OQ-CC-4 — `Behavior.IdentityAdmin` split — keep or merge back?

Today `Behavior.Identity` is split into safe `Identity` (`:list_caps`, `:has_cap?`) + privileged `Behavior.IdentityAdmin` (`:grant_cap`, `:revoke_cap`) per data-ownership-v2 PR-OWN-3. The split exists because cap struct is Behavior-scoped — granting one cap on `Behavior.Identity` would have authorized *both* read and grant.

After simplification: `required_caps/0` is per-action, so `Behavior.Identity` could re-merge — `:list_caps` requires `"user.identity.list_caps"`, `:grant_cap` requires `"user.identity.grant_cap"` — different cap strings.

- **[picked] Option A — Keep the split.** Even with per-action cap strings, the two-Behavior split keeps the privilege boundary visible in the module tree (anyone reading `Behavior.IdentityAdmin` knows "this is sensitive"). Re-merging would save 1 module but bury the privilege difference behind action-name discipline. The split is independent of cap representation; it's about module organization.
- Option B — Re-merge into single `Behavior.Identity`. 1 fewer module, but a future reader of the merged module has to inspect each action's `required_caps/0` to know which are admin-only.

**Why A:** module split is cheap; the visibility benefit persists.

### OQ-CC-5 — How does Issue 1's system principal catalog interact with Issue 2's cap shape?

Each system principal (e.g. `system://boot-reconciler`) needs caps for what it's allowed to dispatch. After Issue 2, those caps are strings. So `system://boot-reconciler`'s caps are something like `["session.external_mirror.*"]`. Where are they stored?

- **[picked] Option A — System principals are persisted Entity slices, same shape as Users.** Each system principal is spawned at boot as an Entity Kind (with `:identity` slice carrying its cap list). Stored in the existing `users` table (or a separate `system_principals` table with identical schema). `Ezagent.Identity.list_caps_for(uri)` works uniformly for both. Bootstrap script seeds the catalog (the 16+ principals listed in §4.1). The User Kind handles "system://" URIs too — no new Kind needed; just the URI scheme distinguishes.
- Option B — System principals are in-memory only, stored in a `SystemPrincipal` ETS table. Avoids DB migration but loses crash-safety (principals must re-seed every boot from compiled-in defaults).
- Option C — System principals don't exist; each call site passes a hardcoded cap list. Re-introduces ambient authority via a different name; rejected by Allen's "audit log shows the actual principal" requirement.

**Why A:** uniformity with User caps means no new primitive; the existing snapshot path persists them; the existing `:identity` slice contract works as-is; LV `/admin/caps` page sees them via the existing path.

### OQ-CC-6 — Migration data path: in-place or wipe-and-rebuild?

Existing users have `caps_json` column storing `[%Capability{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`. New shape is `[String.t()]`. The struct → string conversion is lossy in TWO places:

- `granted_by` / `granted_at` are dropped (the cap string carries no provenance). Provenance moves to a separate `grants` audit table (or is dropped entirely — see Q below).
- `workspace_uri` is dropped from the cap (per OQ-CC-2 Option A — workspace iso moves to Behavior callback). The cap string's instance suffix carries workspace info via URI structure.

- **[picked] Option A — Wipe and rebuild dev DB; ship a one-shot conversion script for production.** Matches the data-ownership-v2 / external-mirror-domain pattern (Phase 9 SPEC v3 §8). The conversion script: read every `caps_json` row, derive the cap string per the mapping table in §5.8, write back. Provenance dropped (an explicit Allen decision needed — see sub-question below). Dev `mix ezagent.reset` regenerates fresh.
- Option B — In-place migration with provenance retained in a parallel `cap_grants` audit table. More moving pieces; more PRs.

**Sub-question — provenance:** drop granted_by/granted_at entirely, OR retain in a separate audit table?

- **[picked] Drop entirely.** Today no production code path reads `granted_by` (verified via grep — only test fixtures and serialization round-trip use it). The data-ownership-v2 grant-chain idea (cap-A delegated by cap-B-holder) was deferred to a future SPEC and never landed. If we ever need provenance, it's a `cap_grants` audit table that lives next to caps_json — additive change.

**Why A + drop:** matches the wipe-and-rebuild convention; no consumer of provenance today; provenance can be added back additively if a future use case appears.

---

## 1. Context — how we got here

ezagent's cap system today conflates SIX concerns into one `%Ezagent.Capability{}` struct + one `CapabilityRegistry` ETS + one `User.admin_caps()` hatch:

1. **What** authority (kind + behavior fields)
2. **On which target** (instance field)
3. **In which workspace** (workspace_uri field)
4. **By whom granted** (granted_by field)
5. **When granted** (granted_at field)
6. **Discovery / catalog** (CapabilityRegistry — what caps exist, what their descriptions are, who their data owner is)

The conflation produced three pathologies that have eaten 5+ rounds of codex review each over the last 3 SPECs:

### 1.1 Pathology A — Ambient authority via `User.admin_caps()`

When a system-internal operation (BootReconciler, AdapterInstall, migration mix task, ChatRouter reply dispatch, Worker publish) needs to dispatch, it has no real user URI. The convenient escape is `User.admin_caps()` — a structurally-:any cap MapSet that matches everything. Audit shows **16 production sites + 21 test sites** doing this (the 57 grep results, less 20 docstring mentions and comment references):

| Site category | Sample call sites |
|---|---|
| Boot / reconciler | `EzagentDomainIdentity.Application` (admin User spawn), `EzagentDomainInstanceMessage.Application` (CC orchestrator seed), `EzagentDomainWorkspace.Workspace.Loader` (boot loader) |
| Mix tasks | `mix ezagent.agent.create`, `mix ezagent.demo.seed_cc_agent`, `mix ezagent.demo.seed_cc_sandbox` |
| Plugin reply dispatch | `Plugin.CurlAgent` (LLM reply dispatch), `Plugin.NP` (NP-agent reply), `Plugin.CC.Channel` (channel reply), `Plugin.Echo` (echo reply), `Plugin.Feishu.BindingPolicy` |
| Chat domain internals | `Behavior.Chat` (reply send, system messages), `Behavior.Template` (template materialization), `Entity.Session` (member sync, slice mutations), `Entity.Agent` (default caps grant), `Orchestrator.{MCPServer, Tools, CCSeed}` |
| LV admin defaults | `terminal_live`, `agent_extensions_live`, `agent_detail_live`, `entity_caps_live`, `agent_new_live`, `admin_live`, `routing_live` (when caller is `nil`) |
| Web root | `home_live` (when no current_entity) |
| Worker | `Behavior.ExternalMirrorWorker` (publish-to-adapter dispatches) |

Each site is *spoofable* (the calling code declares "I am admin") and *untraceable* (audit log says "admin did X", not "BootReconciler did X").

### 1.2 Pathology B — Cap-check logic scattered across non-Behavior layers

The contract today is "dispatch step 5.5 checks caps via `Capability.matches?/2`". But the current code has cap-check copies / paraphrases in:

- `Behavior.Identity.invoke(:grant_cap, ...)` — `check_grant_authorized/2` re-checks the cap shape against data-ownership rules (200+ LOC)
- `Behavior.ExternalMirror` facade — Gates 1, 2, 3 in `Ezagent.ExternalMirror.bind/5` (200+ LOC of facade-level cap checks per external-mirror-audit §2)
- `NotificationSubscriptions` admin predicate — `has_admin_cap?/1` with hand-written shape matching
- `MemberPanel` LV — `cc_agent_uri?/1` workspace-membership check
- `SenderResolver` (Feishu) — `Ezagent.Identity.list_caps_for(bound_uri)` then membership inspection
- Various `_live` modules — `MapSet.member?` checks for cap-driven UI gating

Plugin authors have to *invent* the trust model every time. PR #303 NotificationSubscriptions HIGH-3 finding was exactly this: a hand-written predicate was too wide because there was no framework-level "you must hold cap-X on data-D" gate.

### 1.3 Pathology C — Compile-time enforcement spread across `use Macro` + after_compile + Mix compiler

Today `Behavior` is enforced via `@behaviour Ezagent.Behavior` (compile warning) + `cap_subjects/0` lookup at `CapabilityRegistry.register/3` time (raises if action missing). Some plugin authors have added `use SomeMacro` patterns over the top. The compile-time gate is split across three mechanisms. Allen's Q3: "使用宏是必要的吗？还是可以通过其它方式更直接地完成？" — answer is NO. The existing `:ezagent_plugin_check` Mix compiler is already the right surface; it just needs to grow the cap-related checks.

### 1.4 What this SPEC fixes

This SPEC unwinds all three pathologies in one coordinated cleanup:

- **Issue 1** removes ambient authority. System operations declare their own named principals. Admin's wildcard authority remains, but via data (caps MapSet on the admin Entity) not via code (`User.admin_caps()` deleted).
- **Issue 2** moves cap declaration to per-action Behavior callbacks. Entities hold cap strings. All other code is cap-transparent — dispatch is the only place the gate runs. `Capability` struct + `CapabilityRegistry` ETS + `Identity.{grant_cap,list_caps_for,revoke_cap}` all delete or simplify.
- **Issue 3** moves enforcement into the existing `:ezagent_plugin_check` Mix compiler. No macros. ~50-100 LOC of additions.

---

## 2. Goals (outcome statements)

> 🔄 **r4 amend:** G1 is fulfilled by PR-CC-1 (#345 merged). G2's STRUCTURAL goal (caps only at Behavior×Entity; single chokepoint; other modules cap-transparent) stays valid — the phrase "per-action cap strings" below is superseded by §0d.3 (per-action `%Capability{}` struct map). G3's "valid cap string" is superseded by §0d.4 (valid `%Capability{}` shape per parent Kind + Behavior). G2 admin authority phrasing — "the wildcard `\"*\"` cap string" — supersedes to "the wildcard `%Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any}` cap" per §0d.1.

After this SPEC's 3 PRs are merged:

**G1 — Ambient authority is gone.** `grep -rn "User.admin_caps" apps/` returns 0 results outside `test/support/`. Every dispatch carries a real principal URI in `ctx.caller`. Audit log shows the actual operating principal for every internal operation. The admin Entity's caps slice still contains the wildcard `"*"` cap string — admin authority is data, not code.

**G2 — Caps live only at Behavior × Entity.** `Behavior.required_caps/0` declares per-action cap strings. `Entity.holds_cap?/2` decides membership. `Invocation.dispatch/1` step 5.5 calls both. Every other module is cap-transparent. `grep -rn "Capability.matches\|cap_subjects\|list_caps_for\|grant_cap" apps/` returns 0 production results outside `apps/ezagent_core/lib/ezagent/{behavior,entity,invocation,kind}*.ex` and `apps/ezagent_domain_identity/lib/ezagent/{identity,behavior/identity}*.ex`.

**G3 — Compile-time enforcement is data, not macros.** Every `@behaviour Ezagent.Behavior` module exports a valid `required_caps/0`. Build fails with a precise diagnostic if (a) the callback is missing, (b) the key set differs from `actions/0`, or (c) any value is not a binary cap string. Zero macros added; the `:ezagent_plugin_check` compiler grows by ~50-100 LOC.

---

## 3. Non-goals

> 🔄 **r4 amend:** the phrasing "cap strings" / "struct → string" / "the cap *representation* changes (struct → string)" throughout §3 is superseded — r4 keeps the struct shape per §0d. The "NOT switching to RBAC" intent stays; the "NOT touching dispatch's other steps" intent stays; the "NOT changing `data_owner/1`" intent stays; the "NOT adding cap provenance audit table" intent stays. Where a non-goal bullet hinges on the string switch, treat it as withdrawn (e.g. dropping `granted_by`/`granted_at` is withdrawn — those fields stay in the struct).

- **NOT switching to RBAC** (role-based) — the cap model stays. A "role" is just a named bundle of cap strings that callers can grant atomically.
- **NOT replacing the FacadeNonceTable** from external-mirror-audit. Trust transfer between facade Task and action body is orthogonal to cap simplification.
- **NOT touching dispatch's other steps** (1–4, 5.1–5.4, 5.6–10, 11–12). Only step 5.5 (CapBAC) and 5.6 (workspace iso) change. Step 5.5 reads `Behavior.required_caps()` + calls `Entity.holds_cap?/2`; step 5.6 reads `Behavior.workspace_scoped?/0`.
- **NOT changing `data_owner/1`** from data-ownership-v2. The callback signature and default-grant derivation stay. Only the cap *representation* changes (struct → string); the data-ownership *rule* (only the owner grants caps on their data) is preserved.
- **NOT adding cap provenance audit table in this SPEC.** Dropping `granted_by` / `granted_at` per OQ-CC-6. If provenance becomes needed, it lands as a separate `cap_grants` audit-only table additively.
- **NOT changing UI cap-list display** beyond the field reduction. `/admin/caps` LV still enumerates "what cap strings exist" via `Behavior.required_caps/0` aggregation across all registered Behaviors.

---

## 4. Issue 1 — Ambient authority removal

### 4.1 System principal catalog

Each system-internal dispatch gets a named principal URI under the `system://` scheme. Principal URIs are spawned as Entity Kinds at app boot (per OQ-CC-5 Option A), with their cap lists seeded from a compiled-in catalog.

| Principal URI | Operating context | Required cap strings |
|---|---|---|
| `system://bootstrap` | Admin User spawn at first boot (only used to mint the admin Entity itself) | `"*"` (single use, granted from compiled-in constants) |
| `system://boot-reconciler` | `EzagentDomainExternalMirror.BootReconciler` — reconciles persisted bindings against running adapters at boot | `"session.external_mirror.*"` |
| `system://adapter-install` | `EzagentDomainExternalMirror.AdapterInstall` — installs adapter cap subjects against Session Kind at plugin boot | `"session.*.bind"` (registers per-adapter Behaviors) |
| `system://chat-router` | `Behavior.Chat`'s system-message dispatch path (system-sent welcome msgs, reaction notifications) | `"session.chat.send"`, `"session.chat.system_message"` |
| `system://chat-reply` | Plugin reply dispatches (Echo, CurlAgent, NP, CC, Feishu) — the "agent's response to a session" path | `"session.chat.send"`, `"session.chat.reaction"` |
| `system://worker-publish` | `Behavior.ExternalMirrorWorker` outbound publish dispatches | `"session.external_mirror.publish"` |
| `system://template-materialize` | `Behavior.Template` template-instantiation dispatch | `"workspace.template.*"`, `"session.*"` |
| `system://orchestrator-tools` | `Orchestrator.{MCPServer, Tools, CCSeed}` agent-tool dispatches | `"session.*"` (agent operates within its session lineage) |
| `system://session-internal` | `Entity.Session` slice-internal dispatches (member sync, scope mutations) | `"session.chat.*"`, `"workspace.workspace.read"` |
| `system://agent-internal` | `Entity.Agent` default-caps grant at agent spawn | `"user.identity.grant_cap"` (scoped to the spawned agent) |
| `system://workspace-loader` | `Workspace.Loader` boot path that re-spawns persisted workspaces | `"workspace.workspace.*"` |
| `system://mix-task` | `mix ezagent.agent.create`, `mix ezagent.demo.seed_*` operator tasks | `"*"` (operator already has shell access; principal exists for audit traceability) |
| `system://feishu-binding-policy` | `Plugin.Feishu.BindingPolicy.apply/2` re-grant of default session caps | `"user.identity.grant_cap"` |
| `system://lv-anon-mount` | LV mount path when no `current_entity_uri` is in session | `[]` (empty — LV anon mounts cannot dispatch; replaces the silent `User.admin_caps()` fallback that hid auth bugs) |
| `system://credential-materializer` | #17 cascade PR-0 — credential-materializer audit identity (per-grant narrow `sandbox.read`, no standing cap) | `[]` (empty audit identity) |
| `system://socialware-gc` | #51 §3.4 — in-app GC sweeper (`Socialware.AnonUser.Sweeper`) `chat.leave`s abandoned anon-Users (the `users`/binding row deletes are direct context fns, no dispatch) | `cap(:session, Behavior.Session, :leave)` (narrowed to exactly Session `:leave`) |

Total: 16 principals (14 original + `credential-materializer` (#17) + `socialware-gc` (#51)). **The list is enforced closed — `Ezagent.SystemPrincipal.Catalog` is the single source of truth (per r2 HIGH-2 fix).** Adding a 15th principal requires (a) editing `Catalog`, (b) editing this SPEC, (c) shipping in a separate PR. The catalog is enforced at three layers:

1. Runtime: `SystemPrincipal.ensure/2` rejects URIs not in the catalog (raise).
2. Compile-time: `:ezagent_plugin_check` check 11 greps every `system://` URI literal in app source and asserts membership in the catalog (build fails).
3. Invariant test (§9.5): same grep, fail-loud at test time as defense in depth.

### 4.2 Catalog module (r2 HIGH-2)

`Ezagent.SystemPrincipal.Catalog` (new compile-time module in `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex`):

```elixir
defmodule Ezagent.SystemPrincipal.Catalog do
  @moduledoc """
  The closed allowlist of system principal URIs and their permitted caps.

  Any `system://` URI used as a dispatch principal MUST appear here.
  `:ezagent_plugin_check` enforces this at compile time; the runtime
  `SystemPrincipal.ensure/2` enforces it at boot.

  Adding a 15th principal requires:
  1. Add row here.
  2. Update SPEC `caps-cleanup-v1.md` §4.1 catalog table.
  3. Ship in a separate PR (review surface = "are we adding ambient authority?").
  """

  @catalog %{
    "system://bootstrap"                 => ["*"],
    "system://boot-reconciler"           => ["session.external_mirror.*"],
    "system://adapter-install"           => ["session.*.bind"],
    "system://chat-router"               => ["session.chat.send", "session.chat.system_message"],
    "system://chat-reply"                => ["session.chat.send", "session.chat.reaction"],
    "system://worker-publish"            => ["session.external_mirror.publish"],
    "system://template-materialize"      => ["workspace.template.*", "session.*"],
    "system://orchestrator-tools"        => ["session.*"],
    "system://session-internal"          => ["session.chat.*", "workspace.workspace.read"],
    "system://agent-internal"            => ["user.identity.grant_cap"],
    "system://workspace-loader"          => ["workspace.workspace.*"],
    "system://mix-task"                  => ["*"],
    "system://feishu-binding-policy"     => ["user.identity.grant_cap"],
    "system://lv-anon-mount"             => []
  }

  @doc "Is this URI a registered system principal?"
  @spec member?(URI.t() | String.t()) :: boolean()
  def member?(uri), do: Map.has_key?(@catalog, normalize(uri))

  @doc "Permitted caps for this principal. Raises if not in catalog."
  @spec caps_for!(URI.t() | String.t()) :: [String.t()]
  def caps_for!(uri) do
    key = normalize(uri)

    case Map.fetch(@catalog, key) do
      {:ok, caps} -> caps
      :error -> raise ArgumentError,
        "#{key} is not in SystemPrincipal.Catalog (caps-cleanup-v1 §4.1). " <>
        "Add the row to Catalog + SPEC + open a separate PR."
    end
  end

  @doc "List every catalog URI (for invariant test §9.5)."
  @spec uris() :: [String.t()]
  def uris, do: Map.keys(@catalog)

  defp normalize(%URI{} = u), do: URI.to_string(u)
  defp normalize(s) when is_binary(s), do: s
end
```

### 4.3 Seed flow

Each domain Application that needs a system principal seeds it in its `start/2` via:

```elixir
Ezagent.SystemPrincipal.ensure(URI.parse("system://boot-reconciler"))
```

`Ezagent.SystemPrincipal.ensure/1` (new module in `apps/ezagent_core/lib/ezagent/system_principal.ex`):
- Reads the cap list from `Catalog.caps_for!/1` — no second arg; caller cannot pass arbitrary caps.
- Spawns an Entity Kind with `:identity` slice carrying the cap list (same as a User Kind, but URI is `system://...` not `entity://user/...`).
- Idempotent: if already spawned, no-op.
- Persists via the same `users` table (column `caps_json` carries the list of strings).
- Hard-raises if URI is not in the catalog OR is non-`system://` (defense in depth).

`Behavior.Identity.init_slice/1` already handles the slice shape — only the URI scheme changes.

### 4.4 Migration of system call sites

> 🔄 **r4 amend:** "DELETE — `ctx.caps` field removed per r2 HIGH-3 fix" in the table below is **withdrawn**. `ctx.caps` stays per §0d.1. The 16 call-site migration of `caller: User.admin_uri()` → `caller: URI.parse("system://<service>")` did land in PR-CC-1 #345 and is preserved on main. The catalog cap-shape gap from §0d.1b applies to all rows here.

| Old | New |
|---|---|
| `caps: User.admin_caps()` in dispatch ctx | DELETE — `ctx.caps` field removed per r2 HIGH-3 fix (§5.3 cap-snapshot). Dispatch reads caller slice from caller URI directly; system principals are loaded via the same path |
| `caller: User.admin_uri()` in dispatch ctx | `caller: URI.parse("system://<service>")` |
| Bare `User.admin_caps()` call | DELETE — function deleted from `Entity.User` (compile error if used) |

Each LV that today falls back to `User.admin_caps()` for anonymous mounts (`agent_extensions_live`, `terminal_live`, etc.) switches to `system://lv-anon-mount` with EMPTY caps. The LV mount path that previously silently elevated to admin will now correctly deny anonymous access. This is the existing auth-bug surfacer — anonymous LV mounts SHOULD have been denied; the `User.admin_caps()` fallback was hiding it. Per memory `feedback_let_it_crash_no_workarounds`, the fix is to make the bug visible at the gate, not to preserve the fallback.

### 4.5 Audit log changes

`telemetry.execute([:ezagent, :authz, :granted], ...)`'s `caller` field today shows `entity://user/system/admin` for both real admin operations AND every system-internal dispatch. After this PR, those split: real admin operations still show admin URI; system operations show `system://<service>`.

Codex r2 will demand the audit consumers (today: `audit.ex` writes to `audit_events` table) handle the new URI scheme. They already do — `audit_events.caller` is a String column with no constraint on scheme. The CSV / `/admin/audit` LV displays the URI verbatim.

### 4.6 Invariant test

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs` (new):

```elixir
test "no production code calls User.admin_caps/0" do
  offenders =
    Path.wildcard("apps/*/lib/**/*.ex")
    |> Enum.filter(fn path -> not String.contains?(path, "test/support") end)
    |> Enum.filter(fn path ->
      File.read!(path) =~ ~r/\bUser\.admin_caps\(\)|Ezagent\.Entity\.User\.admin_caps\(\)/
    end)

  assert offenders == [],
         "ambient authority leak: #{inspect(offenders)} call User.admin_caps()"
end

test "User module does not export admin_caps/0" do
  refute function_exported?(Ezagent.Entity.User, :admin_caps, 0),
         "Ezagent.Entity.User.admin_caps/0 must be deleted per caps-cleanup-v1 §4"
end
```

The first asserts the cleanup is complete; the second asserts the escape hatch is structurally removed.

---

## 5. Issue 2 — Caps at Behavior × Entity boundary

> 🔄 **r4 amend:** the entirety of §5 below describes the **withdrawn string-cap design**. See §0d.3 for the in-force struct-cap version. The structural goals (§5.1 `required_caps/0` callback, §5.2 `holds_cap?/2`, §5.3 dispatch step 5.5 as single chokepoint, §5.5 workspace iso via `workspace_scoped?/0`) **all still apply** — only the cap *type* is `%Capability{}` not `String.t()`. §5.4 cap-string grammar is withdrawn (struct fields replace it). §5.6 / §5.7 / §5.8 (data migration + Identity API shape changes) are withdrawn. The body below stays as historical record.

### 5.1 `Behavior.required_caps/0` callback (plain function)

Added to `Ezagent.Behavior` as a mandatory callback (no macros):

```elixir
@doc """
Map from action atom to required cap string. Read by Invocation.dispatch/1
step 5.5 to derive the cap the caller must hold.

The cap string follows the grammar in §5.4. Examples:

    %{
      send: "session.chat.send",
      receive: "session.chat.receive",
      join: "session.chat.join"
    }

Every action returned by `actions/0` MUST have an entry here.
Compile-time enforced by `:ezagent_plugin_check` (Issue 3).
"""
@callback required_caps() :: %{required(action()) => String.t()}
```

The Behavior author writes ONE map. No macros, no DSL, no separate "register at boot" step.

### 5.2 `Entity.holds_cap?/2` callback (default impl + wildcard semantics)

Added to `Ezagent.Kind` (the Entity contract — Entities are Kinds with persistence + identity):

```elixir
@doc """
Does this entity's persisted state grant the given cap string?

Default implementation reads `slice[:identity][:caps]` and matches via
glob (`*` = wildcard segment). Plugin authors override only when
the cap-source is non-standard (rare).
"""
@callback holds_cap?(entity_slice :: map(), cap_string :: String.t()) :: boolean()

# Default impl provided by Ezagent.Kind (concrete Kinds inherit unless
# they override). Walks the cap list, glob-matches each held cap
# against the needed string per §5.4 wildcard semantics.
def holds_cap?(slice, cap_string) when is_binary(cap_string) do
  caps = get_in(slice, [:identity, :caps]) || []
  Enum.any?(caps, &Ezagent.Cap.matches?(&1, cap_string))
end
```

`Ezagent.Cap.matches?/2` (new helper module in `apps/ezagent_core/lib/ezagent/cap.ex`):
- `matches?("*", _needed)` → true (admin wildcard)
- `matches?("chat.*", "session.chat.send")` → true (kind-glob)
- `matches?("session.chat.*", "session.chat.send")` → true (action-glob)
- `matches?("session.chat.send", "session.chat.send")` → true (exact)
- `matches?("session.chat@session://X", "session.chat.send@session://X")` → true (instance-scoped, same instance)
- `matches?("session.chat@session://X", "session.chat.send@session://Y")` → false (different instance)
- `matches?("session.chat", "session.chat.send")` → true (behavior-level cap grants all actions on the behavior — preserves the cap struct's "no action field" semantics)

The matcher is ~50 LOC, fully unit-tested, no external dependencies.

### 5.3 Dispatch step 5.5 simplification + cap snapshot contract (r2 HIGH-3)

Today `apps/ezagent_core/lib/ezagent/kind/runtime.ex:215-239` (`authz_check/4`) reads `Capability.cap_for_action/3` + iterates `ctx.caps` MapSet through `Capability.matches?/2`. After this SPEC:

**New step 5.0a — cap snapshot at dispatch admission (r3 HIGH-2 extension — catalog gate for `system://` callers).** `Invocation.dispatch/1` (after step 1's idempotency, before step 5.5) does TWO things atomically before any cap is loaded:

1. **Catalog gate (r3 HIGH-2):** if `URI.parse(ctx.caller).scheme == "system"`, the caller URI MUST be a member of `Ezagent.SystemPrincipal.Catalog`. Reject `{:error, :unknown_system_principal}` otherwise. This closes the gap where an uncataloged `system://migration-script` or `system://fixture` could spawn an Identity slice (via direct ETS write or test helper) and dispatch — bypassing both compile-time check 11 (which only greps source literals) and `SystemPrincipal.ensure/1` (which only guards the boot-seed path, not dispatch).
2. **Snapshot:** read the caller's caps ONCE per dispatch and pin them to `ctx.caps_snapshot`. The snapshot is the ONLY source of caller caps for the lifetime of the dispatch.

```elixir
defp admit_cap_snapshot(%Invocation{ctx: ctx} = inv) do
  caller_uri = URI.parse(URI.to_string(ctx.caller))  # idempotent if already URI

  # --- r3 HIGH-2 — catalog gate for system:// callers ---
  with :ok <- enforce_system_principal_catalog(caller_uri),
       {:ok, %{caps: caps, revision: rev}} <- Ezagent.Identity.get_slice_versioned(ctx.caller) do
    snapshot = %{caps: caps, revision: rev, taken_at_us: System.monotonic_time(:microsecond)}
    {:ok, %{inv | ctx: Map.put(ctx, :caps_snapshot, snapshot)}}
  else
    {:error, :unknown_system_principal} = err ->
      # Uncataloged system:// caller — reject hard. The catalog is the
      # SINGLE SOURCE OF TRUTH for valid system principals (§4.1).
      # Do NOT raise — return an error so dispatch can record the rejection
      # in telemetry [:ezagent, :authz, :unknown_principal] for audit.
      err

    :not_found ->
      # Caller URI not spawned — non-system principals MUST be spawned at
      # login. Hard-raise per feedback_let_it_crash_no_workarounds — no
      # silent empty-caps fallback (that's the User.admin_caps() pathology
      # in a new costume).
      raise ArgumentError,
        "caller #{URI.to_string(ctx.caller)} has no Identity slice; cannot dispatch"
  end
end

defp enforce_system_principal_catalog(%URI{scheme: "system"} = uri) do
  if Ezagent.SystemPrincipal.Catalog.member?(uri) do
    :ok
  else
    :telemetry.execute(
      [:ezagent, :authz, :unknown_principal],
      %{},
      %{caller: URI.to_string(uri), reason: :uncataloged_system_uri}
    )
    {:error, :unknown_system_principal}
  end
end

defp enforce_system_principal_catalog(%URI{}), do: :ok  # entity://, workspace://, etc. pass through
```

Steps 5.5 (CapBAC), 5.6 (workspace iso), and any facade-internal cap re-checks (ExternalMirror Gates 1-3) read `ctx.caps_snapshot.caps` — never re-read the slice.

**Three-layer enforcement of the catalog (r3 HIGH-2 — defense in depth):**
1. Compile-time (`:ezagent_plugin_check` check 11, §6.1) — every `system://` URI LITERAL in source must be in the catalog. Catches static call sites.
2. Boot-time (`SystemPrincipal.ensure/1`, §4.3) — only catalogued URIs can be seeded. Catches mis-spawned principals.
3. **Dispatch-time (new — this step 5.0a) — every dispatch whose `caller.scheme == "system"` is checked against the catalog before the cap snapshot is taken.** Catches dynamic / runtime-constructed system principals that slipped past layers 1+2 (e.g. test fixtures that spawn ad-hoc principals, hot-loaded code, atom-interpolated URIs that check 11's regex misses).

Without layer 3, a malicious or buggy code path could:
```elixir
# spawn ad-hoc system principal — no compile-time literal, no
# SystemPrincipal.ensure call — passes layers 1+2.
Ezagent.Identity.init_slice(URI.parse("system://my-backdoor"), %{caps: ["*"]})
# dispatch with that caller — r2 admission would accept it
Invocation.dispatch(%Invocation{caller: URI.parse("system://my-backdoor"), ...})
```
Layer 3 catches this: the URI is not in the catalog → `:unknown_system_principal`.

**Step 5.5 — uses the snapshot:**

```elixir
defp authz_check(kind_module, action, target, ctx) do
  behavior = lookup_behavior(kind_module, action)  # same as today
  needed_cap = Map.fetch!(behavior.required_caps(), action)
  needed_with_instance = "#{needed_cap}@#{URI.to_string(Ezagent.URI.instance(target))}"

  if cap_in_snapshot?(ctx.caps_snapshot.caps, needed_with_instance) do
    :telemetry.execute([:ezagent, :authz, :granted], %{revision: ctx.caps_snapshot.revision},
                       meta(ctx, target, action, needed_with_instance))
    :ok
  else
    :telemetry.execute([:ezagent, :authz, :denied], %{revision: ctx.caps_snapshot.revision},
                       meta(ctx, target, action, needed_with_instance))
    {:error, :unauthorized}
  end
end

defp cap_in_snapshot?(caps_list, needed) when is_list(caps_list) do
  Enum.any?(caps_list, &Ezagent.Cap.matches?(&1, needed))
end
```

**New step 8.5 — CAS guard for cap-mutating actions (r3 HIGH-1 fix — CAS the TARGET, not the caller).** For actions whose `Behavior.mutates_caps?/0` returns `true` (default `false`; only `Behavior.IdentityAdmin.grant_cap` / `revoke_cap` override), Kind.Server's invoke wrapper performs a CAS on the **TARGET**'s Identity slice revision — the same slice the action is about to mutate. The contract is:

1. Step 5.0a snapshots the CALLER's caps + revision (used by step 5.5 to authorize the dispatch). This is `ctx.caps_snapshot`.
2. Step 5.0b (new — only for cap-mutating actions) ALSO snapshots the TARGET's Identity slice + revision and pins to `ctx.target_caps_snapshot`. The action body MUST derive its mutation as `new_caps = mutate(target_caps_snapshot.caps)`.
3. Step 8.5 compares `ctx.target_caps_snapshot.revision` against the TARGET's current Identity slice revision INSIDE the same ETS update transaction that will write the new caps. The ETS update is conditional: only commits if the target revision is unchanged. If drifted, returns `{:error, :cap_snapshot_stale}` and the caller may retry.

Why this matters (r3 HIGH-1 lost-update scenario closed):
- Caller-A holds `"user.identity_admin.grant_cap"`. Targets user-T (currently `caps = ["x"]`, `revision = 5`).
- D1: snapshot-target gives `{caps: ["x"], revision: 5}`; D1 wants to add `"y"` → new caps `["x", "y"]`.
- D2: snapshot-target gives `{caps: ["x"], revision: 5}`; D2 wants to add `"z"` → new caps `["x", "z"]`.
- r2 (BROKEN) CAS'd on caller revision: caller's revision unchanged across both dispatches → both pass → D2 overwrites D1, `"y"` silently lost.
- r3 CAS on target revision: D1 commits first, T's revision bumps 5 → 6. D2's CAS fails (snapshot says 5, current says 6) → D2 returns `:cap_snapshot_stale`, caller retries with fresh snapshot `{caps: ["x", "y"], revision: 6}` and now correctly produces `["x", "y", "z"]`.

```elixir
# Step 5.0b — snapshot TARGET caps for cap-mutating actions ONLY.
defp admit_target_snapshot(%Invocation{} = inv) do
  behavior = lookup_behavior(inv.kind, inv.action)

  if behavior_mutates_caps?(behavior, inv.action) do
    case Ezagent.Identity.get_slice_versioned(inv.target) do
      {:ok, %{caps: caps, revision: rev}} ->
        %{inv | ctx: Map.put(inv.ctx, :target_caps_snapshot,
                              %{caps: caps, revision: rev,
                                taken_at_us: System.monotonic_time(:microsecond)})}

      :not_found ->
        # Target Entity must exist for cap mutation. Let-it-crash.
        raise ArgumentError,
          "target #{URI.to_string(inv.target)} has no Identity slice; cannot mutate caps"
    end
  else
    inv
  end
end

# Step 8.5 — conditional write of the cap-mutation, gated on
# target revision unchanged. Implemented inside Ezagent.Identity to
# bind the CAS check + the write into ONE ETS update_counter /
# update_element atom (a non-atomic check-then-write would not close
# the race).
defp commit_cap_mutation(inv, new_caps) do
  Ezagent.Identity.cas_update_caps(
    inv.target,
    expected_revision: inv.ctx.target_caps_snapshot.revision,
    new_caps: new_caps
  )
  # cas_update_caps/2 returns:
  #   {:ok, new_revision}
  #   {:error, :cap_snapshot_stale}   # target revision drifted
end
```

For non-cap-mutating actions (the 99% case — chat send, session join, etc.) BOTH the target snapshot step (5.0b) and the CAS commit step (8.5) are skipped: those actions don't read or write the target's Identity slice.

**Note — caller revision and target revision are independent.** The caller's snapshot at 5.0a authorizes the dispatch (cap check at 5.5). The target's snapshot at 5.0b protects against lost-updates on the mutation. Both can drift independently and the failure modes are different:
- Caller revision drift between 5.0a and 8.5 is NOT checked because the dispatch's authorization (the cap check at 5.5) is allowed to be slightly stale — revoking grant_cap from the caller mid-dispatch doesn't retroactively unauthorize a dispatch already past step 5.5. (Idempotency / atomic-action semantics.)
- TARGET revision drift between 5.0b and 8.5 MUST be detected because the mutation is read-modify-write and lost-updates corrupt the slice.

If a future requirement needs caller-revision CAS too (e.g. revoking a granter's grant_cap power should immediately invalidate any in-flight grants by that granter), that's a SEPARATE concern: add a second CAS arm on caller revision in step 8.5 and return `{:error, :caller_authority_revoked}`. Out of scope for v1; documented here so the SPEC is honest about the boundary.

**Identity slice revision semantics.** Added to `Ezagent.Identity` slice:
- New slice key `:revision` — monotonically increasing counter, per-Entity.
- `grant_cap` and `revoke_cap` bump `:revision` atomically with the cap-list mutation (single ETS update — `cas_update_caps/2` is the only mutation API; bare list-write is removed).
- `get_slice_versioned/1` reads `{caps, revision}` in one ETS lookup (used by step 5.0a + 5.0b).
- `get_revision/1` reads `revision` alone (kept for telemetry / debug only).
- `cas_update_caps/2` is the conditional-write primitive: takes `expected_revision` + `new_caps`, returns `{:ok, new_revision}` or `{:error, :cap_snapshot_stale}`. Implementation uses `:ets.select_replace/2` to make the check + write a single atomic operation (NOT `:ets.lookup + :ets.insert` — that's the lost-update window in another shape).

Revision is per-Entity. A grant on user-A doesn't bump user-B's revision; concurrent dispatches against different users never CAS-fail each other.

**Key changes summary:**
- `ctx.caps` is GONE (was the pre-loaded MapSet that needed `User.admin_caps()` as fallback). Replaced by `ctx.caps_snapshot` set at admission.
- Cap check reads from snapshot, not from live ETS.
- Cap-mutating actions CAS-guard against stale snapshots; other actions skip the check.
- `Capability.matches?/2` is GONE — replaced by `Ezagent.Cap.matches?/2`.
- `Capability.cap_for_action/3` is GONE — replaced by `Behavior.required_caps()[action]` lookup.
- All facade-internal cap-rechecks (ExternalMirror Gates 1-3) read `ctx.caps_snapshot.caps` — never re-fetch.

### 5.4 Cap string format (canonical grammar — r2 HIGH-1 + HIGH-4)

```
cap_string := allowlisted_special | scoped_cap
allowlisted_special := "*" | "cross-workspace:*"
scoped_cap := authority instance_suffix? workspace_suffix?
authority := kind "." behavior ( "." action | ".*" )?
instance_suffix := "@" instance_uri
workspace_suffix := ";ws=" workspace_uri
kind := atom_string | "*"
behavior := atom_string | "*"
action := atom_string
instance_uri := URI.t() string form (no '@', no ';' inside path)
workspace_uri := full workspace:// URI string

Examples:
"*"                                                     # admin all (allowlisted)
"cross-workspace:*"                                     # cross-workspace bypass (allowlisted)
"session.*"                                             # all session-kind actions, ANY workspace
"session.*;ws=workspace://team-alpha"                   # all session-kind actions, only in team-alpha workspace
"session.chat"                                          # all session.chat.* actions, ANY workspace
"session.chat.send"                                     # specific action, ANY workspace
"session.chat@session://default/team/main"              # all chat actions on one session (workspace structural via instance)
"session.chat.send@session://default/team/main"         # one action on one session
"session.chat.send;ws=workspace://team-alpha"           # one action, scoped to team-alpha workspace (no specific instance)
```

**Workspace suffix `;ws=<workspace_uri>` (r2 HIGH-1 fix).** When the cap has no instance suffix but the original `%Capability{}` carried a concrete `workspace_uri`, the suffix preserves that dimension. Matching semantics (§5.2 `Cap.matches?/2` extended):

- A cap WITHOUT `;ws=` matches a needed cap in ANY workspace.
- A cap WITH `;ws=W` matches a needed cap only if the needed cap's target is in workspace W (or its instance URI structurally derives to W).
- The `@instance_uri` suffix is STRONGER than `;ws=` — if both are present, the instance URI's workspace MUST equal the `;ws=` value (compile-time contradictions like `session.chat@session://default/team/main;ws=workspace://other` fail the parser).

**Allowlisted specials.** The two strings `"*"` and `"cross-workspace:*"` are NOT regular cap shapes — they're documented escape hatches with explicit allowlist in the parser. Adding a third special requires SPEC amendment. This closes codex r1's "unstated exceptions" concern (HIGH-4).

**Strict parser `Cap.Parser.parse_strict/1`** (r2 HIGH-4):
- Used by `:ezagent_plugin_check` at compile time.
- Rejects unknown kind atoms (via `String.to_existing_atom` — kind must be a registered Kind name).
- Rejects unknown behavior atoms similarly.
- Rejects unknown action atoms (must be in declaring Behavior's `actions/0`).
- Rejects malformed `@instance_uri` (URI parse must succeed; scheme must be one of the registered scheme allowlist).
- Rejects malformed `;ws=` (must parse to `workspace://*` URI).
- Rejects unknown specials (only `"*"` and `"cross-workspace:*"` admitted).

The lenient `Cap.Parser.parse/1` exists for runtime / CLI input where the cap may reference plugins not yet loaded — it falls back gracefully (same behavior as today's `Capability.Parser`).

The grammar is a strict extension of the existing `Capability.Parser` grammar — every string today's CLI accepts continues to work; the new `;ws=` suffix and explicit allowlist are additive.

### 5.5 Workspace iso separation (per OQ-CC-2)

`Behavior.workspace_scoped?/0` (new optional callback, default `true`):

```elixir
@doc """
Should dispatch enforce workspace isolation for actions on this Behavior?

Default `true` — caller's workspace must match target's workspace, OR
caller must hold `"cross-workspace:*"` cap, OR caller must be a member of
workspace://system.

Behaviors operating on cross-cutting data (e.g. system://, template://,
resource://) override to `false`. Examples today: `Behavior.Routing`
on System Kind, `Behavior.Template` on cross-workspace template lookup.
"""
@callback workspace_scoped?() :: boolean()
```

Dispatch step 5.6 reads this callback in place of the cap struct's `workspace_uri: :any` predicate:

```elixir
defp workspace_isolation_check(behavior, target, ctx) do
  if behavior.workspace_scoped?() do
    caller_ws = workspace_of_caller(ctx.caller)
    target_ws = Ezagent.URI.workspace_of(target)
    snapshot_caps = ctx.caps_snapshot.caps  # r2 HIGH-3 — snapshot, not live

    cond do
      caller_ws == :any -> :ok                                          # system caller
      target_ws == :any -> :ok                                          # cross-cutting target
      caller_ws == target_ws -> :ok                                     # same workspace
      Enum.member?(snapshot_caps, "cross-workspace:*") -> :ok           # explicit bypass cap
      caller_in_system_workspace?(ctx.caller) -> :ok                    # membership bypass (Phase 9 PR-8)
      true -> {:error, :cross_workspace_denied}
    end
  else
    :ok
  end
end
```

The cap struct's `workspace_uri` field is gone; iso is per-Behavior data + per-caller membership + the `;ws=<workspace_uri>` cap suffix (which the §5.5 `Cap.matches?/2` consults so a cap scoped to workspace A cannot authorize an action in workspace B — see §5.4 for matching semantics).

### 5.6 FacadeNonceTable interaction (PRESERVED)

External-mirror-audit's `FacadeNonceTable` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/facade_nonce_table.ex`) is UNCHANGED. The nonce protects the trust-transfer between the facade Task and the action body — it's a separate forgery-resistance primitive that operates BELOW the cap check. After this SPEC:

- Facade still runs Gates 1, 2, 3 via the new `holds_cap?` flow (3 cap-check call sites updated to read `required_caps/0` + `Kind.holds_cap?/2`).
- Gate 4 (target_ownership_check) unchanged — it's adapter I/O, not a cap check.
- FacadeNonceTable claim/consume unchanged.
- Dispatch step 5.5 still runs as defense-in-depth — invariant test from external-mirror-audit §6 continues to verify.

### 5.7 Migration of cap-check call sites

| Surface | Count | Migration |
|---|---|---|
| `Capability.matches?/2` direct calls | 4 prod + ~30 test | Delete prod calls (dispatch handles); test calls move to `Ezagent.Cap.matches?/2` |
| `CapabilityRegistry.register/3` calls | 5 sites | Delete — Behaviors declare via `required_caps/0` callback; compiler reads it |
| `CapabilityRegistry.needed_for/3` calls | 0 prod (only dispatch internals) | Delete with the module |
| `CapabilityRegistry.lookup_subject/2` calls | 4 sites (mostly tests asserting registration) | Delete; tests migrate to `Behavior.required_caps()[:action]` direct call |
| `Identity.list_caps_for/1` calls | 22 sites (LV mounts, MCPServer, BindingPolicy, etc.) | DELETE the function; dispatch reads slice directly. LV mounts that needed the list for *display* use new `Identity.read_caps_for_display/1` (read-only, no dispatch, returns `[String.t()]`) |
| `Identity.grant_cap/3` calls | ~10 sites | Replace with `Ezagent.Entity.add_cap/3(entity_uri, cap_string, granter_uri)` — direct slice mutation through dispatch on `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` (the cap_string is the arg; dispatch step 5.5 verifies granter holds `"user.identity_admin.grant_cap"` for the data owner per data-ownership-v2) |
| `Identity.revoke_cap/3` calls | ~5 sites | Same as grant_cap pattern |
| Inline `MapSet.member?(caps, ...)` cap checks in plugin code | ~8 sites (LV, Feishu, NP, CC) | DELETE — these are the symptoms of cap-check leaking into non-dispatch surfaces. Route through dispatch on the relevant Behavior |
| `Behavior.Identity.check_grant_authorized/2` (200 LOC) | 1 module | Move logic INTO dispatch step 5.5 — data-ownership-v2's owner-check is now part of the standard cap-check path |
| `Behavior.ExternalMirror` facade Gates 1, 2, 3 | 1 module | Update to read `required_caps/0` + `holds_cap?/2`; logic shape preserved |

Total touched files: ~50-70 across PRs CC-2a..2d (which we sub-split per §7.2 below).

### 5.8 Data migration

Existing `users.caps_json` rows store `[%{kind, behavior, instance, workspace_uri, granted_by, granted_at}]`. One-shot conversion script (`apps/ezagent_core/priv/repo/data_migrations/20260525_caps_to_strings.exs`).

**r2 HIGH-1 fix — workspace dimension MUST be preserved.** r1's migration dropped `workspace_uri` on the assumption that `instance` would carry it. But for caps with `instance: "any"` AND concrete `workspace_uri` (the `User.default_caps/1` shape is the canonical example), the converted string `"session.*"` is GLOBALLY scoped — silently widening a workspace-A grant into authorization on workspace B. The fix uses the `;ws=<workspace_uri>` suffix from §5.4 to preserve the scope:

```elixir
defmodule CapMigration do
  # Admin's structural cap: all dimensions :any → the allowlisted special.
  def convert(%{"kind" => "any", "behavior" => "any", "instance" => "any",
                "workspace_uri" => "any"}), do: "*"

  # Admin's cross-workspace cap shape (rare).
  def convert(%{"kind" => "any", "behavior" => "any", "instance" => "any",
                "workspace_uri" => ws}) when ws != "any" do
    # Even admin gets workspace-pinned if the original was workspace-scoped.
    # (Pathological — admin caps SHOULD all be :any. Migration preserves
    # whatever was on disk; an invariant test catches stragglers.)
    "*;ws=#{ws}"
  end

  # Common case: kind+behavior-scoped, no specific instance,
  # original was workspace-scoped (e.g. User.default_caps shape).
  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => "any",
                "workspace_uri" => ws}) when ws != "any" do
    "#{kind}.#{deatomize_behavior(behavior)};ws=#{ws}"
  end

  # Kind+behavior-scoped, cross-workspace (rare; explicit admin grant).
  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => "any",
                "workspace_uri" => "any"}) do
    "#{kind}.#{deatomize_behavior(behavior)}"
  end

  # Instance-scoped: instance URI carries workspace structurally.
  # Assert workspace_uri matches the instance URI's workspace OR is :any
  # — else the original cap was malformed and we hard-raise (let-it-crash).
  def convert(%{"kind" => kind, "behavior" => behavior, "instance" => instance_str,
                "workspace_uri" => ws}) do
    instance_ws = Ezagent.URI.workspace_of_string(instance_str)

    cond do
      ws == "any" or ws == instance_ws ->
        "#{kind}.#{deatomize_behavior(behavior)}@#{instance_str}"

      true ->
        raise "Cap migration sanity check failed: cap on instance #{instance_str} " <>
              "(workspace #{instance_ws}) has workspace_uri=#{ws} which does not " <>
              "match. Original cap is structurally malformed."
    end
  end

  defp deatomize_behavior("any"), do: "*"
  defp deatomize_behavior("Elixir.Ezagent.Behavior." <> name), do: Macro.underscore(name)
end
```

Provenance (`granted_by`, `granted_at`) is dropped per §0 decision OQ-CC-6.

The script:
1. Reads every `users` row.
2. JSON-decodes `caps_json`.
3. Converts each cap map to a string via `CapMigration.convert/1`.
4. Writes back the new JSON list of strings.
5. Bumps a `caps_schema_version` column from `1` to `2`.

Application boot reads `caps_schema_version` — if `1`, refuses to start with a `MIGRATION_REQUIRED` log line. Per Phase 9 SPEC v3 §8 convention. Dev `mix ezagent.reset` regenerates fresh.

### 5.9 Plugin author flow (the north-star payoff)

After this SPEC, a plugin author adding `Plugin.CC` with a new "create session" action writes:

```elixir
defmodule Ezagent.Plugin.CC.Behavior.CreateSession do
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:create]

  @impl true
  def required_caps, do: %{create: "session.create_session.create"}

  @impl true
  def workspace_scoped?, do: true

  @impl true
  def invoke(:create, slice, args, ctx) do
    # Plain action body. NO cap-check code. Dispatch already gated.
    # NO admin-fallback. ctx.caller is the real principal.
    # NO ambient authority. The Session being created carries
    # ctx.caller as its created_by field, structurally.
    new_session = build_session(args, created_by: ctx.caller)
    {:ok, Map.put(slice, :sessions, [new_session | slice.sessions])}
  end
end
```

Total cap-system contact surface for the plugin author: 2 callback lines (`required_caps/0`, `workspace_scoped?/0`). They never touch `CapabilityRegistry` (deleted), `Capability` struct (deleted), `Identity.grant_cap` (renamed + dispatch-only), `User.admin_caps` (deleted).

This IS the north-star: plugin authors stay out of core (memory `feedback_north_star_plugin_isolation`).

---

## 6. Issue 3 — Compile-time enforcement via `:ezagent_plugin_check`

> 🔄 **r4 amend:** §6's overall shape stays — extend the existing `:ezagent_plugin_check` Mix compiler with checks 10/11 — but every "string parses via `Cap.Parser.parse_strict/1`" predicate becomes "is a `%Capability{}` struct with valid fields" per §0d.4. The `Ezagent.Cap.Parser.parse_strict/1` function reference is withdrawn (string-era artifact). The triple-keyed `Enum.uniq_by/2` MED-1 fix from r3-FINAL stays — that's a dedupe shape, not a cap-shape, decision.

### 6.1 Extension to existing compiler

`apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` grows three new checks (~80 LOC):

```elixir
# New check 8 — every @behaviour Ezagent.Behavior module exports
# required_caps/0
defp check_required_caps_exported(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_kind, _action, behavior} -> behavior end)
  |> Enum.uniq()
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    cond do
      not function_exported?(behavior, :required_caps, 0) ->
        [diagnostic("#{inspect(behavior)} (a declared Behavior) does not " <>
          "export required_caps/0. Every Behavior MUST declare per-action " <>
          "cap strings (caps-cleanup-v1 SPEC §5.1).") | acc]

      true ->
        acc
    end
  end)
end

# New check 9 — required_caps/0 keys equal actions/0
defp check_required_caps_keys_match_actions(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.map(fn {_, _, b} -> b end)
  |> Enum.uniq()
  |> Enum.filter(&function_exported?(&1, :required_caps, 0))
  |> Enum.reduce(diagnostics, fn behavior, acc ->
    declared_actions = MapSet.new(behavior.actions())
    cap_keys = MapSet.new(Map.keys(behavior.required_caps()))

    cond do
      declared_actions == cap_keys -> acc

      true ->
        missing = MapSet.difference(declared_actions, cap_keys)
        extra = MapSet.difference(cap_keys, declared_actions)
        [diagnostic("#{inspect(behavior)}: required_caps/0 keys must " <>
          "equal actions/0 exactly. Missing: #{inspect(MapSet.to_list(missing))}; " <>
          "extra: #{inspect(MapSet.to_list(extra))} (SPEC §6).") | acc]
    end
  end)
end

# New check 10 — every required_caps/0 value parses with the strict
# cap parser AND cross-validates against the declaring Behavior/Kind
# (r2 HIGH-4 fix — was "is_binary?" only;
#  r3-FINAL MED-1 fix — dedupe key is {Kind, Behavior, action} triple, not
#  Behavior alone. The same Behavior may be registered under multiple Kinds
#  (e.g. `Behavior.Chat` on both `Kind.Session` and `Kind.Agent`) OR with
#  different cap subjects per (Kind, action) pair. Deduping by Behavior
#  silently dropped the second and subsequent registrations, leaving their
#  required_caps unchecked. New triple-keyed dedupe collapses only TRUE
#  duplicates — same Kind + same Behavior + same action — which `behaviors/0`
#  may legitimately list more than once when a Behavior re-exports.)
defp check_required_caps_values_parse_strict(diagnostics, plugin_module) do
  plugin_module.behaviors()
  |> Enum.uniq_by(fn {k, a, b} -> {k, b, a} end)
  |> Enum.filter(fn {_, _, b} -> function_exported?(b, :required_caps, 0) end)
  |> Enum.reduce(diagnostics, fn {kind, _action, behavior}, acc ->
    Enum.reduce(behavior.required_caps(), acc, fn {action, cap_str}, inner_acc ->
      cond do
        not is_binary(cap_str) ->
          [diagnostic("#{inspect(behavior)}: required_caps/0[#{inspect(action)}] " <>
            "is #{inspect(cap_str)}; must be a binary cap string (SPEC §6).") | inner_acc]

        true ->
          case Ezagent.Cap.Parser.parse_strict(cap_str,
                  expected_kind: kind, expected_behavior: behavior, expected_action: action) do
            :ok -> inner_acc

            {:error, reason} ->
              [diagnostic("#{inspect(behavior)}: required_caps/0[#{inspect(action)}] " <>
                "= #{inspect(cap_str)} fails strict parse: #{inspect(reason)} " <>
                "(SPEC §5.4 + §6).") | inner_acc]
          end
      end
    end)
  end)
end

# New check 11 — every `system://` URI literal in app source must
# appear in Ezagent.SystemPrincipal.Catalog (r2 HIGH-2 fix)
defp check_system_principals_in_catalog(diagnostics) do
  source_files = Path.wildcard("lib/**/*.ex")

  system_uri_pattern = ~r/"(system:\/\/[a-zA-Z0-9_\-\/]+)"/

  unauthorized =
    source_files
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      Regex.scan(system_uri_pattern, content, capture: :all_but_first)
      |> Enum.map(fn [uri] -> {file, uri} end)
    end)
    |> Enum.reject(fn {_file, uri} -> Ezagent.SystemPrincipal.Catalog.member?(uri) end)

  if unauthorized == [] do
    diagnostics
  else
    msg = Enum.map_join(unauthorized, "\n  ", fn {f, u} -> "#{u} in #{f}" end)

    [diagnostic("System principal URIs found in source that are NOT in " <>
      "Ezagent.SystemPrincipal.Catalog. Add to the catalog (caps-cleanup-v1 §4.2) " <>
      "OR remove the literal:\n  #{msg}") | diagnostics]
  end
end
```

Wired into the existing `run/1` pipeline:

```elixir
diagnostics =
  []
  |> check_uses_behaviour(plugin_module)
  |> check_declared_modules(plugin_module)
  |> check_agent_flavors(plugin_module)
  |> check_adapters(plugin_module)
  |> check_spawns_empty(plugin_module)
  |> check_config_surface(plugin_module)
  |> check_no_direct_registry_calls()
  |> check_required_caps_exported(plugin_module)              # NEW (8)
  |> check_required_caps_keys_match_actions(plugin_module)    # NEW (9)
  |> check_required_caps_values_parse_strict(plugin_module)   # NEW (10, r2)
  |> check_system_principals_in_catalog()                     # NEW (11, r2)
```

Plus `ezagent_core` itself needs a parallel check for `@behaviour Ezagent.Behavior` modules that live in `ezagent_core` / `ezagent_domain_*` (the compiler runs against EACH app, with the same wiring). Each domain app already wires `:ezagent_plugin_check` in `mix.exs` (or gets it added in PR-CC-3).

### 6.2 Failure modes

- Missing `required_caps/0` → build fails with `(ezagent_plugin_check) Ezagent.Behavior.X (a declared Behavior) does not export required_caps/0...`
- Key mismatch with `actions/0` → build fails with diff of missing + extra keys.
- Non-string value → build fails listing the bad entries.
- **Strict-parse failure (r2 HIGH-4)** — cap string with unknown kind atom / behavior atom / action atom, or malformed `@instance_uri` / `;ws=` suffix, or unrecognized special string fails the build with the parser's `{:error, reason}`. The runtime warn-only typo check from r1 §10.3 is DELETED — typos fail at compile time.
- **Uncataloged `system://` URI (r2 HIGH-2)** — any source file containing a `system://...` literal not in `SystemPrincipal.Catalog` fails the build.

Per memory `feedback_let_it_crash_no_workarounds`: NO warning + degrade. The build fails. CI catches it before merge.

---

## 7. Historical migration plan (withdrawn — see §0d.5)

> 🔄 **r4 amend:** §7 below describes the **withdrawn 3+1 PR sequence**. In-force plan per §0d.5: a single PR-CC-2-v2 implementing §0d.3's struct-shape callbacks. No `caps_json` DB migration. No `caps_schema_version` bump. The "PR-CC-2 was originally split into 2a/2b/2c/2d" detail is historical — the v2 attempt is a single coordinated PR because the struct kept means no shim window exists.

### 7.1 PR-CC-1 — Issue 1 (Ambient authority removal)

**Branch:** `feat/caps-cleanup-pr1-ambient-authority`
**Effort:** 3-5 days (focused; 14 principals × seed + ~30 prod call sites to migrate).

Scope:
- Add `Ezagent.SystemPrincipal` module (§4.2).
- Seed 14 principals in their owning Application's `start/2` (§4.1).
- Migrate 30 prod call sites from `User.admin_caps()` → `SystemPrincipal.caps(...)` per the catalog.
- Migrate 21 test sites — most become `SystemPrincipal.test_principal("test-xyz")` (a test-only helper that mints a principal with arbitrary caps).
- DELETE `Ezagent.Entity.User.admin_caps/0` (let-it-crash — build fails on remaining call sites; sweep follows).
- Add invariant test §4.5.
- Audit log already accepts non-`entity://` URIs — no schema change.

Acceptance:
- `grep -rn "User.admin_caps" apps/ | grep -v test/support` returns 0 results.
- All existing tests pass.
- Invariant test §4.5 passes.
- `/admin/audit` shows `system://` callers for at least 3 distinct system operations.

Independent of PR-CC-2 — can ship alone.

### 7.2 PR-CC-2 — Issue 2 (Caps at Behavior × Entity)

The biggest PR. Sub-split into 4 sub-PRs to keep each reviewable:

**PR-CC-2a — Add new primitives (additive, no deletions):**
- `Ezagent.Cap.matches?/2` (the string matcher, §5.2).
- `Behavior.required_caps/0` callback declaration in `Ezagent.Behavior` (mandatory; new optional callback initially).
- `Behavior.workspace_scoped?/0` callback (optional, default true).
- `Kind.holds_cap?/2` default impl (additive).
- Every Behavior implements `required_caps/0` (29 Behaviors × 2-line addition each). At this point both old and new paths exist.

**PR-CC-2b — Switch dispatch to new path:**
- Dispatch step 5.5 rewritten per §5.3 (read `required_caps/0`, call `holds_cap?/2`).
- Dispatch step 5.6 rewritten per §5.5 (read `workspace_scoped?/0`, drop cap struct's workspace field reads).
- All tests pass with NEW path. Old `Capability.matches?/2` still exists but unused.

**PR-CC-2c — Migration of caps slices + cap-check call sites:**
- Data migration script (§5.8) — wipe-dev, run script on staging/prod.
- Bump `caps_schema_version` to 2.
- Migrate all `Identity.list_caps_for/1` call sites (22) per §5.7 table.
- Migrate all `Identity.grant_cap/3` call sites (~10) per table.
- Migrate inline `MapSet.member?` cap checks in plugin LVs.
- Update `Behavior.Identity.invoke(:grant_cap, ...)` to consume cap strings.
- Update `Behavior.ExternalMirror` facade Gates 1, 2, 3 to new API (preserve FacadeNonceTable).

**PR-CC-2d — Delete old machinery:**
- Delete `Ezagent.Capability` struct (`apps/ezagent_core/lib/ezagent/capability.ex`).
- Delete `Ezagent.CapabilityRegistry` (`apps/ezagent_core/lib/ezagent/capability_registry.ex` + `apps/ezagent_core/lib/ezagent/capability_registry/`).
- Delete `Ezagent.Identity.list_caps_for/1`, `grant_cap/3`, `revoke_cap/3` (replace exports with `Ezagent.Entity.add_cap/3`, `remove_cap/3`, `read_caps_for_display/1`).
- Delete `Behavior.cap_subjects/0` callback (per OQ-CC-3 collapse — replaced by `required_caps/0`).
- Delete `Behavior.dispatchable?/0` callback (per OQ-CC-3 — cap-only Behaviors removed; Presence + Sandbox become normal dispatchable Behaviors).
- Update `Capability.Parser` → `Cap.Parser` (CLI grammar same).

**Effort:** 2 weeks across the 4 sub-PRs (CC-2a = 2 days, CC-2b = 2 days, CC-2c = 5 days, CC-2d = 2 days).

Acceptance per sub-PR:
- 2a: All Behaviors export `required_caps/0`; CI green; nothing dispatch-side changed yet.
- 2b: Dispatch uses new path; `[:ezagent, :authz, :granted]` telemetry has new shape with `needed_cap` as string.
- 2c: `caps_schema_version == 2` on all envs; old cap-check call sites all migrated; grep §G2 returns 0 results.
- 2d: Old modules deleted; build green; grep `Capability\.matches\|CapabilityRegistry\|admin_caps` returns 0 results.

### 7.3 PR-CC-3 — Issue 3 (Compile-time enforcement)

**Branch:** `feat/caps-cleanup-pr3-compile-time-gate`
**Effort:** 1-2 days.

Scope:
- Add the 3 new checks per §6.1 to `:ezagent_plugin_check` compiler.
- Wire the compiler into every domain app's `mix.exs` (those that don't already have it — audit shows most do, but `ezagent_core` itself does not run the gate against its own Behaviors; the new checks should run against core + domains too).
- Verify build fails when:
  - A Behavior is added with `actions: [:foo]` but no `:foo` key in `required_caps/0`.
  - A Behavior's `required_caps/0` returns `%{foo: :not_a_string}`.

Acceptance:
- Adding a deliberately-broken Behavior to a fixture app fails the build with a precise diagnostic.
- All existing Behaviors pass the new checks (PR-CC-2a already added `required_caps/0` to all of them).

---

## 8. Acceptance criteria (per-PR)

> 🔄 **r4 amend:** §8.1 (PR-CC-1) acceptance criteria all PASSED on the merged PR #345 — preserve as-is. §8.2 (original PR-CC-2 acceptance) and §8.3 (original PR-CC-3) describe string-era criteria; the in-force PR-CC-2-v2 acceptance gates are: (a) every `@behaviour Ezagent.Behavior` module exports `required_caps/0` returning `%{atom() => %Capability{}}`; (b) `Entity.holds_cap?/2` callback present with default impl; (c) dispatch step 5.5 reads `required_caps/0`; (d) no production code outside the chokepoint allowlist calls `Capability.matches?/2` directly (the §9.2 12-probe invariant — kept, with grep targets adjusted to struct construction sites).

| PR | Gate |
|---|---|
| CC-1 | (a) Invariant `no_admin_caps_fallback_test.exs` passes; (b) `grep -rn "User.admin_caps" apps/lib` returns 0 lines; (c) audit log on `/admin/audit` shows `system://` URI for boot-reconciler dispatch within 5 seconds of fresh boot |
| CC-2a | All 29 Behaviors export `required_caps/0`; `mix test apps/ezagent_core` green |
| CC-2b | Dispatch `[:ezagent, :authz, :granted]` telemetry payload includes `needed_cap` as a binary; old `Capability.matches?/2` invoked 0 times in a full test run (verify via :telemetry hook in invariant test) |
| CC-2c | (a) `caps_schema_version == 2`; (b) all 22 `list_caps_for/1` call sites removed (grep `Identity\.list_caps_for` outside test/support returns 0); (c) existing user with seeded caps still authorized for their session post-migration (e2e test); (d) **§0 decisions stamped `Allen-approved YYYY-MM-DD`** — PR-CC-2c is BLOCKED at review until every decision row in §0 carries Allen's explicit stamp (r2 MEDIUM-5 fix); (e) invariant test §9.4 passes (no migration widening) |
| CC-2d | `Capability`, `CapabilityRegistry`, `Identity.{list_caps_for,grant_cap,revoke_cap}` modules / functions deleted; `mix compile` green; full test suite green |
| CC-3 | Deliberately-broken fixture Behavior fails build with `(ezagent_plugin_check)` diagnostic; existing Behaviors all pass |

---

## 9. Invariant tests (the architectural gates per `feedback_completion_requires_invariant_test`)

> 🔄 **r4 amend:** §9.1 G1 invariant (`no production-lib reference to User.admin_caps/0`) PASSED on PR #345 — preserved. §9.2 G2 12-probe invariant **kept** but with grep targets re-pointed: P1-P2 (ambient authority) unchanged; P3-P5 / P7-P11 (cap-check leakage / mutation-API leak / caller-spoofing / etc.) re-aimed at `%Capability{}` construction sites + `Capability.matches?/2` calls outside the chokepoint, instead of cap-string parse sites; P12 (macro declaration) unchanged. §9.3 G3 (compile-time gate) re-aimed at struct shape per §0d.4. §9.4 / §9.5 / §9.6 (workspace-suffix migration / catalog enforcement / cap-snapshot CAS) — §9.4 withdrawn (no DB migration); §9.5 kept (catalog enforcement is cap-shape-agnostic); §9.6 kept (CAS is a TOCTOU fix, orthogonal to cap shape).

Each issue's structural goal is gated by a test that fails when the goal is unmet — these are the locks against future regression.

### 9.1 G1 — Ambient authority gone

`apps/ezagent_core/test/invariants/no_admin_caps_fallback_test.exs` (§4.5):
1. No production file calls `User.admin_caps/0`.
2. `User` module does not export `admin_caps/0`.

### 9.2 G2 — Caps only at Behavior × Entity boundary (r3 MEDIUM-1 — comprehensive probe set)

`apps/ezagent_core/test/invariants/caps_only_at_boundary_test.exs` (NEW).

**Why a probe set, not a single regex (r3 MEDIUM-1 fix).** Codex r2 correctly identified that a single grep on one cap-pattern is too narrow — a savvy bypass using different syntax slips through. This invariant decomposes into ONE probe per anti-pattern, each pinned to a §1 pathology (A: ambient authority, B: cap-check scattered across non-Behavior layers) or a §1 concern (1-6). A new anti-pattern needs a new probe.

```elixir
# ----- Test infra: a shared file set + an "allowed paths" allowlist. -----

@allowed_paths [
  "apps/ezagent_core/lib/ezagent/behavior",         # Behavior callback definitions
  "apps/ezagent_core/lib/ezagent/entity",           # Entity holds_cap? default
  "apps/ezagent_core/lib/ezagent/invocation",       # Dispatch (5.0a, 5.0b, 5.5, 5.6, 8.5)
  "apps/ezagent_core/lib/ezagent/kind",             # Kind runtime
  "apps/ezagent_core/lib/ezagent/cap.ex",           # The matcher itself
  "apps/ezagent_core/lib/ezagent/cap/",             # Cap parser, etc.
  "apps/ezagent_core/lib/ezagent/system_principal", # SystemPrincipal catalog + ensure
  "apps/ezagent_domain_identity/lib/ezagent"        # Identity facade (read-only path)
]

defp prod_source_files do
  Path.wildcard("apps/*/lib/**/*.ex")
  |> Enum.reject(fn p ->
    String.contains?(p, "test/support") or
      Enum.any?(@allowed_paths, &String.starts_with?(p, &1))
  end)
end

defp offenders_for(pattern) when is_struct(pattern, Regex) do
  prod_source_files()
  |> Enum.filter(fn p -> File.read!(p) =~ pattern end)
end

# ----- Probe 1 (Pathology A — concern: ambient authority via User.admin_caps()) -----

test "P1: no production file references User.admin_caps/0 or its aliases" do
  # Catches: User.admin_caps(), Ezagent.Entity.User.admin_caps(),
  # rebinding aliases (alias Ezagent.Entity.User, as: U; U.admin_caps()).
  offenders = offenders_for(~r/\b(?:[A-Z][A-Za-z0-9_]*\.)*User\.admin_caps\s*\(\s*\)/)
  assert offenders == [],
         "Pathology A leak — User.admin_caps fallback: #{inspect(offenders)}"
end

# ----- Probe 2 (Pathology A — concern: ambient caps MapSet) -----

test "P2: no production file hard-codes 'admin' caps fields in dispatch ctx" do
  # Catches: %{caps: User.admin_caps(), ...}, caps: MapSet.new([...all the things...]),
  # `caps: admin_caps()`, and the per-LV `defp default_caps, do: User.admin_caps()` pattern.
  offenders = offenders_for(~r/\bcaps:\s*(?:User\.admin_caps|admin_caps|MapSet\.new\(\s*\[\s*%Ezagent\.Capability)/)
  assert offenders == [],
         "Pathology A leak — ambient cap MapSet construction: #{inspect(offenders)}"
end

# ----- Probe 3 (Pathology B — concern: cap-check at non-Behavior layer) -----

test "P3: no production file calls Capability.matches? / cap_for_action outside core dispatch" do
  # Catches: the legacy struct-matcher used in random LVs / plugins.
  offenders = offenders_for(~r/\bEzagent\.Capability\.(?:matches\??|cap_for_action)\s*\(/)
  assert offenders == [],
         "Pathology B leak — Capability struct matcher outside dispatch: #{inspect(offenders)}"
end

# ----- Probe 4 (Pathology B — concern: CapabilityRegistry direct access) -----

test "P4: no production file calls CapabilityRegistry" do
  # The module is deleted per §7.2 PR-CC-2d. Any remaining reference
  # is dead code that must be removed (compile would fail too —
  # belt-and-braces invariant).
  offenders = offenders_for(~r/\bEzagent\.CapabilityRegistry\b|\bCapabilityRegistry\.(?:register|needed_for|lookup_subject)\s*\(/)
  assert offenders == [],
         "Pathology B leak — CapabilityRegistry references: #{inspect(offenders)}"
end

# ----- Probe 5 (Pathology B — concern: cap subjects callback) -----

test "P5: no production file declares or invokes cap_subjects/0 callback" do
  # The callback is removed per OQ-CC-3 / §7.2 PR-CC-2d (replaced by
  # required_caps/0). Any leftover `def cap_subjects` or
  # `behavior.cap_subjects()` is a regression.
  offenders = offenders_for(~r/\bdef\s+cap_subjects\s*\(|\.cap_subjects\s*\(/)
  assert offenders == [],
         "Pathology B leak — cap_subjects/0 callback survives: #{inspect(offenders)}"
end

# ----- Probe 6 (Pathology B — concern: list_caps_for outside Identity facade) -----

test "P6: list_caps_for/1 is called only from Identity facade or LV display path" do
  # The mutation-grade list_caps_for/1 is deleted per §5.7 / §7.2 PR-CC-2d.
  # LV display path uses read_caps_for_display/1 instead.
  offenders = offenders_for(~r/\b(?:Ezagent\.)?Identity\.list_caps_for\s*\(/)
  assert offenders == [],
         "Pathology B leak — Identity.list_caps_for (deleted API): #{inspect(offenders)}"
end

# ----- Probe 7 (Pathology B — concern: grant_cap/revoke_cap outside Behavior.IdentityAdmin) -----

test "P7: grant_cap / revoke_cap is called via dispatch on Behavior.IdentityAdmin, never directly" do
  # Catches: Identity.grant_cap(...), Ezagent.Identity.grant_cap(...),
  # Identity.revoke_cap(...). The new path is dispatch:
  # Ezagent.Invocation.dispatch(%Invocation{kind: User, action: :grant_cap, ...}).
  offenders = offenders_for(~r/\b(?:Ezagent\.)?Identity\.(?:grant_cap|revoke_cap)\s*\(/)
  assert offenders == [],
         "Pathology B leak — direct grant_cap/revoke_cap (must go through dispatch): #{inspect(offenders)}"
end

# ----- Probe 8 (Pathology B — concern: inline cap-set membership checks) -----

test "P8: no production file does inline MapSet/Enum cap-set membership against ctx.caps" do
  # Catches: MapSet.member?(ctx.caps, ...), Enum.member?(caps, ...),
  # ctx.caps |> Enum.any?(..., ctx.caps_snapshot |> MapSet.member?
  # OUTSIDE allowed paths. The ONLY place this should happen is
  # core dispatch step 5.5 / 5.6.
  offenders = offenders_for(~r/(?:MapSet|Enum)\.(?:member\?|any\?)\s*\(\s*(?:ctx\.caps|ctx\.caps_snapshot|caps_snapshot)\b/)
  assert offenders == [],
         "Pathology B leak — inline cap-set membership outside dispatch: #{inspect(offenders)}"
end

# ----- Probe 9 (Pathology B — concern: hand-rolled cap string substring matching) -----

test "P9: no production file does substring/prefix matching on a cap string outside Cap matcher" do
  # Catches: String.starts_with?(cap, "admin"), cap == "*",
  # cap_string =~ ~r/admin/, String.contains?(cap, "grant_cap").
  # These reimplement Cap.matches? badly and break wildcard semantics.
  pattern = ~r/\b(?:String\.(?:starts_with\?|contains\?|ends_with\?)|=~)\s*\(?\s*(?:cap|cap_string|needed_cap|cap_str)\b/
  offenders = offenders_for(pattern)
  assert offenders == [],
         "Pathology B leak — hand-rolled cap string matching: #{inspect(offenders)}"
end

# ----- Probe 10 (Pathology A — concern: instance string substitution / spoofing) -----

test "P10: no production file builds a dispatch ctx by substituting an arbitrary caller URI" do
  # Catches the "fake the caller" anti-pattern:
  # %Invocation{caller: URI.parse("entity://user/admin"), ...},
  # ctx = %{caller: URI.parse("system://" <> name), ...} where name
  # is non-literal (atom interp / variable). The catalog gate at 5.0a
  # catches system:// at runtime; this probe catches it at source.
  pattern = ~r/caller:\s*URI\.parse\(\s*(?:"entity:\/\/user\/admin"|"system:\/\/"\s*<>\s*\w)/
  offenders = offenders_for(pattern)
  assert offenders == [],
         "Pathology A leak — caller URI spoofing in dispatch ctx: #{inspect(offenders)}"
end

# ----- Probe 11 (Pathology A — concern: multi-channel cap check / parallel auth paths) -----

test "P11: no production file does cap-check at >1 layer for the same call" do
  # The data-ownership-v2 PR landed `check_grant_authorized/2` INSIDE
  # Behavior.Identity. That logic moves into dispatch step 5.5 per §5.7.
  # Detect any file with BOTH a `check_*authoriz*` private function AND
  # a `dispatch` or `Invocation` call within the same module — likely
  # the duplicate-check anti-pattern.
  offenders =
    prod_source_files()
    |> Enum.filter(fn p ->
      content = File.read!(p)
      content =~ ~r/defp\s+check_\w*authoriz\w*\s*\(/ and
        content =~ ~r/\b(?:Invocation\.dispatch|Ezagent\.Invocation)\b/
    end)
  assert offenders == [],
         "Pathology B leak — duplicate cap-check layer: #{inspect(offenders)}"
end

# ----- Probe 12 (Pathology C — concern: macro-based cap declaration) -----

test "P12: no production file uses macros to declare caps" do
  # Allen's Q3 — "使用宏是必要的吗". Answer: no. required_caps/0 is a
  # plain function callback. Detect `use Ezagent.{Caps,Capability}.*`,
  # `defmacro required_caps`, `__using__` patterns that inject caps.
  pattern = ~r/\buse\s+Ezagent\.(?:Caps|Capability)\b|defmacro\s+required_caps\b|defmacro\s+cap_subjects\b/
  offenders = offenders_for(pattern)
  assert offenders == [],
         "Pathology C leak — macro-based cap declaration: #{inspect(offenders)}"
end
```

**Probe-to-pathology map** (each anti-pattern surfaced by codex history or §1 analysis gets exactly one probe):

| Probe | Pathology (§1) | Concern (§1) | Anti-pattern detected |
|---|---|---|---|
| P1 | A | ambient authority | `User.admin_caps()` calls |
| P2 | A | ambient authority | `caps: MapSet.new(...)` / `caps: admin_caps` hardcoded in dispatch ctx |
| P3 | B | scattered cap-check | `Capability.matches?` outside dispatch |
| P4 | B | discovery (#6) | `CapabilityRegistry` references (module deleted) |
| P5 | B | discovery (#6) | `cap_subjects/0` callback survives (deleted per OQ-CC-3) |
| P6 | B | mutation API leak | `Identity.list_caps_for/1` direct call (replaced by `read_caps_for_display` for read, dispatch for mutate) |
| P7 | B | mutation API leak | `Identity.grant_cap` / `revoke_cap` direct call (must go through dispatch) |
| P8 | B | scattered cap-check | inline `MapSet.member?(ctx.caps, ...)` |
| P9 | B | scattered cap-check | hand-rolled string match (`String.starts_with?(cap, ...)`) |
| P10 | A | caller spoofing (#2 + #4) | hardcoded `caller: URI.parse("entity://user/admin")` or atom-interp `system://` |
| P11 | B | scattered cap-check | duplicate `check_*authoriz*/2` private fn alongside dispatch |
| P12 | C | enforcement | macros for cap declaration (`use Ezagent.Caps`, `defmacro required_caps`) |

**Coverage statement.** The 12 probes cover every leak pattern surfaced by codex review history on cap-related PRs (the 5 rounds Allen referenced in his trigger message). When a 13th leak appears, a 13th probe lands as a SPEC amendment + this test grows by one — that IS the regression-lock contract.

**Non-redundancy note.** Probes P3-P8 look adjacent but each catches a distinct call shape; deleting any one would leave a documented escape hatch. The redundancy is INTENTIONAL — defense in depth against future shape-shifting bypasses.

### 9.3 G3 — Compile-time enforcement is non-bypassable

`apps/ezagent_core/test/invariants/required_caps_compile_gate_test.exs` (NEW):

```elixir
test "build fails when a Behavior omits required_caps/0" do
  # Create a fixture app under tmp/, copy a minimal mix.exs + a Behavior
  # with actions/0 but no required_caps/0, run mix compile, assert the
  # build fails with the ezagent_plugin_check diagnostic.
  fixture = create_broken_fixture(omit: :required_caps)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "(ezagent_plugin_check)"
  assert output =~ "does not export required_caps/0"
end

test "build fails when required_caps/0 keys differ from actions/0" do
  fixture = create_broken_fixture(mismatch_keys: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must equal actions/0 exactly"
end

test "build fails when required_caps/0 has a non-string value" do
  fixture = create_broken_fixture(non_string_value: true)
  assert {output, 1} = System.cmd("mix", ["compile"], cd: fixture, stderr_to_stdout: true)
  assert output =~ "must be cap strings"
end
```

The 3 sub-tests cover the 3 failure modes from §6.2. Each spawns a real `mix compile` on a fixture to verify the gate is non-bypassable.

### 9.4 — Workspace dimension preserved across migration (r2 HIGH-1)

`apps/ezagent_core/test/invariants/cap_migration_no_widening_test.exs` (NEW):

```elixir
test "no migrated cap authorizes a workspace it was not originally scoped to" do
  # Read pre-migration snapshot (a fixture file representing the
  # actual schema-v1 caps_json shape from prod) + post-migration
  # output. For every (user, original_cap) → migrated_cap pair,
  # assert that migrated_cap.matches?(needed) ⇒
  # original_cap.matches?(needed) for every needed shape involving
  # a different workspace.

  pre = load_fixture("pre_migration_caps_v1.json")
  post = CapMigration.run(pre)

  for {user_uri, old_caps} <- pre, {user_uri_p, new_caps} <- post, user_uri == user_uri_p do
    Enum.zip(old_caps, new_caps)
    |> Enum.each(fn {old, new} ->
      # The cross-workspace probe: for every workspace OTHER than the
      # original's workspace_uri, the migrated cap MUST NOT authorize.
      other_ws = "workspace://probe-#{:rand.uniform(1_000_000)}"
      needed = "session.chat.send@session://default/#{other_ws}/probe"

      if old["workspace_uri"] != "any" do
        refute Ezagent.Cap.matches?(new, needed),
               "Cap migration widened: original cap #{inspect(old)} was scoped to " <>
               "workspace #{old["workspace_uri"]} but migrated cap #{inspect(new)} " <>
               "now authorizes #{needed} (different workspace)."
      end
    end)
  end
end
```

This is the structural lock against r2 HIGH-1's regression.

### 9.5 — System principal catalog closed (r2 HIGH-2 + r3 HIGH-2 dispatch gate)

`apps/ezagent_core/test/invariants/system_principals_in_catalog_test.exs` (NEW):

```elixir
test "every system:// URI literal in source is in SystemPrincipal.Catalog" do
  source_files = Path.wildcard("apps/*/lib/**/*.ex")

  uri_pattern = ~r/"(system:\/\/[a-zA-Z0-9_\-\/]+)"/

  found =
    source_files
    |> Enum.flat_map(fn file ->
      Regex.scan(uri_pattern, File.read!(file), capture: :all_but_first)
      |> Enum.map(fn [uri] -> {file, uri} end)
    end)

  uncataloged = Enum.reject(found, fn {_f, u} ->
    Ezagent.SystemPrincipal.Catalog.member?(u)
  end)

  assert uncataloged == [],
         "Uncataloged system:// URIs found:\n  " <>
         Enum.map_join(uncataloged, "\n  ", fn {f, u} -> "#{u} in #{f}" end)
end

test "SystemPrincipal.ensure rejects URIs not in catalog" do
  assert_raise ArgumentError, ~r/not in SystemPrincipal.Catalog/, fn ->
    Ezagent.SystemPrincipal.ensure(URI.parse("system://hypothetical-ambient-authority"))
  end
end

test "dispatch admission rejects uncataloged system:// caller even with seeded slice (r3 HIGH-2)" do
  # The bypass scenario the r2 SPEC did not close: somehow an
  # uncataloged system:// URI obtains a real Identity slice (via
  # direct test helper, hot-loaded code, or atom-interpolated URI
  # that compile-check 11's regex misses). Dispatch MUST reject the
  # call BEFORE step 5.5 reads any caps.
  bypass_uri = URI.parse("system://test-only-uncataloged-#{:rand.uniform(1_000_000)}")
  refute Ezagent.SystemPrincipal.Catalog.member?(bypass_uri),
         "test setup invariant: probe URI must not be in catalog"

  # Force-seed an Identity slice for this URI (simulating the bypass):
  # bypass_seed_for_test! is a test-only helper that goes around
  # SystemPrincipal.ensure and writes directly to the slice table.
  Ezagent.Identity.bypass_seed_for_test!(bypass_uri, caps: ["*"], revision: 1)

  # Build a dispatch with the bypass URI as caller.
  inv = build_invocation(bypass_uri, some_target(), :any_action, %{})

  # MUST reject with :unknown_system_principal — the catalog gate at
  # step 5.0a fires before any cap check.
  assert {:error, :unknown_system_principal} = Ezagent.Invocation.dispatch(inv)

  # Telemetry [:ezagent, :authz, :unknown_principal] MUST have fired
  # with the bypass URI for audit forensics.
  assert_received {:telemetry, [:ezagent, :authz, :unknown_principal], _,
                   %{caller: caller_str, reason: :uncataloged_system_uri}}
  assert caller_str == URI.to_string(bypass_uri)
end

test "dispatch admission accepts cataloged system:// caller" do
  # Positive control: a real catalog entry must pass admission.
  cataloged = URI.parse("system://boot-reconciler")
  assert Ezagent.SystemPrincipal.Catalog.member?(cataloged)

  Ezagent.SystemPrincipal.ensure(cataloged)
  inv = build_invocation(cataloged, some_target(), :some_action, %{})
  # Either :ok (action authorized) or {:error, :unauthorized} (cap missing for action)
  # but NEVER :unknown_system_principal.
  assert match?({:error, :unknown_system_principal}, Ezagent.Invocation.dispatch(inv)) == false
end

test "non-system:// callers bypass the catalog gate" do
  # User and workspace callers are not subject to the SystemPrincipal
  # catalog — only the system:// scheme triggers the layer-3 check.
  user_uri = URI.parse("entity://user/test-user-#{:rand.uniform(1_000_000)}")
  Ezagent.Identity.bypass_seed_for_test!(user_uri, caps: [], revision: 1)

  inv = build_invocation(user_uri, some_target(), :some_action, %{})
  # Reaches the cap check at step 5.5 (not blocked at 5.0a):
  refute match?({:error, :unknown_system_principal}, Ezagent.Invocation.dispatch(inv))
end
```

The third test (`dispatch admission rejects uncataloged system:// caller even with seeded slice`) is the load-bearing r3 HIGH-2 invariant: it exercises the bypass that r2's two-layer (compile + boot) enforcement misses.

### 9.6 — Cap snapshot CAS for cap-mutating actions (r2 HIGH-3 + r3 HIGH-1 lost-update)

`apps/ezagent_core/test/invariants/cap_snapshot_cas_test.exs` (NEW):

```elixir
test "concurrent grant_cap dispatches against the SAME target detect lost-update (r3 HIGH-1)" do
  # The lost-update scenario the r2 CAS did not close: two dispatches
  # mutate the same target T's caps. r2 CAS'd on CALLER revision
  # (unchanged → both pass → last-write wins → grant lost). r3 CAS's
  # on TARGET revision (D1 bumps T's revision; D2's snapshot now
  # stale → :cap_snapshot_stale).
  {caller, target} = setup_users()
  target_rev = Ezagent.Identity.get_revision(target)

  inv1 = build_invocation(caller, target, :grant_cap,
                          %{cap: "session.chat.send"}, target_rev: target_rev)
  inv2 = build_invocation(caller, target, :grant_cap,
                          %{cap: "session.chat.join"}, target_rev: target_rev)

  # Dispatch D1 inline → commits, target revision bumps.
  assert :ok = Invocation.dispatch(inv1)

  # D2's target snapshot is now stale → step 8.5 CAS fails.
  assert {:error, :cap_snapshot_stale} = Invocation.dispatch(inv2)

  # Confirm D1's grant survived (this is THE lost-update assertion):
  assert "session.chat.send" in Ezagent.Identity.list_caps_for_display(target)
  refute "session.chat.join" in Ezagent.Identity.list_caps_for_display(target)
end

test "retry with fresh target snapshot succeeds" do
  # After :cap_snapshot_stale, the caller re-reads target's snapshot
  # and retries — should now commit on top of D1's mutation.
  {caller, target} = setup_users()

  inv1 = build_grant_invocation(caller, target, "session.chat.send")
  assert :ok = Invocation.dispatch(inv1)

  # Retry with a fresh snapshot.
  inv2_retry = build_grant_invocation(caller, target, "session.chat.join")
  assert :ok = Invocation.dispatch(inv2_retry)

  caps = Ezagent.Identity.list_caps_for_display(target)
  assert "session.chat.send" in caps
  assert "session.chat.join" in caps
end

test "concurrent grants against DIFFERENT targets do not CAS-fail each other" do
  # Per-Entity revision: D1 on T1 must not invalidate D2 on T2.
  {caller, t1} = setup_users()
  {_, t2} = setup_users()

  inv1 = build_grant_invocation(caller, t1, "session.chat.send")
  inv2 = build_grant_invocation(caller, t2, "session.chat.send")

  assert :ok = Invocation.dispatch(inv1)
  assert :ok = Invocation.dispatch(inv2)
end

test "non-cap-mutating dispatch skips both target snapshot + CAS guard" do
  # The 99% case: send a chat message; concurrent grant_cap on either
  # caller OR target slice must NOT cause the chat dispatch to fail.
  {caller, target_session} = setup_chat_user_session()

  chat_inv = build_chat_send_invocation(caller, target_session)

  # Concurrently bump revisions on adjacent entities.
  Task.async(fn -> grant_unrelated_cap(caller) end)
  Task.async(fn -> grant_unrelated_cap_to_session_member(target_session) end)

  assert :ok = Invocation.dispatch(chat_inv)
end

test "cas_update_caps is atomic — no lost update under heavy contention" do
  # Hammer one target with N concurrent grant_cap dispatches, each
  # granting a unique cap string. Some MUST fail with :cap_snapshot_stale,
  # but every successful grant MUST appear in the final cap list (no silent loss).
  {caller, target} = setup_users()
  n = 50

  results =
    1..n
    |> Task.async_stream(fn i ->
      retry_grant(caller, target, "session.chat.send@session://probe-#{i}", max_retries: 10)
    end, max_concurrency: 16, timeout: 5_000)
    |> Enum.to_list()

  ok_count = Enum.count(results, &match?({:ok, :ok}, &1))
  final_caps = Ezagent.Identity.list_caps_for_display(target)

  # Either every retry eventually succeeded (preferred), or some gave up;
  # in either case the count of caps starting with "session.chat.send@session://probe-"
  # MUST EQUAL ok_count — no lost grant.
  granted = Enum.count(final_caps, &String.starts_with?(&1, "session.chat.send@session://probe-"))
  assert granted == ok_count,
         "lost-update detected: #{ok_count} grants reported ok but only #{granted} survive"
end
```

The r3 fix is specifically the FIRST and FIFTH test — they fail against r2's caller-revision CAS and pass only when CAS is on target revision with atomic check-then-write.

---

## 10. Risks + rollback

> 🔄 **r4 amend:** rollback discussion below assumes a `caps_schema_version v1→v2` migration ran. Per §0d.5 that migration is withdrawn; `caps_json` column shape unchanged. The "rollback by re-running the migration in reverse" path is N/A. The in-VM trust model §10.5 stays. The forward note in §0d.6 covers post-v1 cryptographic verification design space.

### 10.1 Risk — PR-CC-2 mid-flight conflicts with concurrent SPECs

`feat/workspace-default-to-system-impl` (#335) and `feat/agent-duplicate-simple-from-flag` (#338) are in flight. Both touch caps adjacently. Mitigation: PR-CC-1 is independent and can land first; PR-CC-2 waits for those to merge OR coordinates a synchronized rebase.

### 10.2 Risk — Data migration on production stale state

If a production user has a cap shape unforeseen by `CapMigration.convert/1`, the script raises. Mitigation: dry-run the script on a snapshot first; the script logs every conversion; failures are reported with the offending row UUID for manual fixup. Per `feedback_let_it_crash_no_workarounds`, no fallback — better to surface unknown shapes than silently default.

### 10.3 Risk — Cap-string typos (CLOSED by r2 HIGH-4 fix)

**RESOLVED in r2.** r1 §10.3 proposed a runtime warn-only typo check. Codex r1 HIGH-4 correctly identified this as too weak — the spec's compile-time enforcement goal demands that `"session.chta.send"` fail at build time. r2 §6.1 check 10 (`check_required_caps_values_parse_strict`) calls `Ezagent.Cap.Parser.parse_strict/1` which cross-validates the cap's `kind` segment against the parent Kind's `type_name/0`, the `behavior` segment against `state_slice/0`, and the `action` segment against the Behavior's `actions/0`. Typos fail the build with a precise diagnostic. The runtime warning path is DELETED.

### 10.4 Rollback

Each sub-PR is rebase-and-revert-clean. The migration script is one-way (no undo) — `caps_schema_version` bump is a Rubicon. Rollback past PR-CC-2c requires DB restore, not a code revert. This is acceptable because the wipe-and-rebuild pattern matches Phase 9 SPEC v3 §8 and the deployment story for that was Allen's explicit choice.

### 10.5 Accepted v1 limits — in-VM caller is trusted (the trust model)

ezagent v1 follows the standard Elixir release trust model: **the BEAM boundary IS the trust boundary**. Any code that runs inside the VM is "deployed" by the operator and considered trusted; the principal field on `Invocation.dispatch/1` is informational + auditable, not cryptographically authenticated.

Codex r3 raised two findings (HIGH-1 principal forgery, HIGH-2 system-caller workspace iso) that are NOT bugs in v1 — they're explicit, documented consequences of the trust model. Allen 2026-05-25 confirmed the model + acceptance.

**What this DOES protect against:**
- Operator audit + accountability: who (claimed) caller per invocation in `invocations` table, including telemetry `[:ezagent, :authz, :unknown_principal]` for catalog misses (§5.3 step 5.0a).
- Cap-shape validation: caller can't dispatch an action without the matching cap (§5.5).
- Workspace iso for non-system callers: regular user URIs are workspace-derived and enforced (§5.5 second arm, §9.4).

**What this DOES NOT protect against:**
- **Principal forgery (codex r3 HIGH-1):** in-VM code can call `dispatch(%{caller_uri: "system://anything-in-catalog"})`; the system principal catalog (§4.2) only verifies that the URI is in the allowlist, not that the caller actually IS that principal. Mitigation: external code injection is prevented at the OS/deployment layer (vetted Elixir releases, no third-party RCE surface, plugin code review at deploy time). The only way to forge a principal is to run unauthorized code in the VM, which is the same threat that lets you read the DB encryption key directly — out of scope for cap-level enforcement.
- **System caller workspace iso (codex r3 HIGH-2):** `system://` principals are configured with `workspace_uri: :any` by default, intentionally bypassing workspace iso so cross-workspace operations (BootReconciler, AdapterInstall, migration scripts, etc.) work. This is not a bug — it's the documented contract for system principals. Non-system callers (every `user://`, `agent://`, `session://` URI) are workspace-iso-enforced as normal per §5.5.

**v2 requirement** (post-multi-tenant / plugin-marketplace introduction):
- Principal authentication via server-stamped context (Plug.Conn-style `assigns`); `caller_uri` moves from dispatch parameter to derived-from-context value, computed by an authentication layer that cannot be forged by the dispatch caller.
- New SPEC `caps-cleanup-v2` will redesign dispatch context. Reference: this section + the codex r3 HIGH-1 + HIGH-2 findings are the v2 input set.

Documented in `feedback_let_it_crash_no_workarounds` style: we choose explicit acceptance + a documented future plan over silent partial mitigation that gives a false sense of security.

---

## 11. Out-of-scope (futures)

> 🔄 **r4 amend:** any "future" bullet that proposes extending the cap-string grammar (instance suffix, workspace suffix, role/group syntax) is withdrawn — struct keeps make those extensions struct-field additions, not string-grammar parsing. The cryptographic-verification future moves to §0d.6.

- **Cap provenance audit table** — if a future use case needs "who granted me cap X", a `cap_grants(grantee_uri, cap_string, granter_uri, granted_at)` table lands additively without changing the cap shape.
- **Role bundles** — operator UX for granting "frontend-admin" as a named bundle of cap strings is a UI feature, not a structural change. The cap shape is unchanged; the bundle is just a server-side expansion at grant time.
- **Cross-workspace cap delegation** — today only admin holds `"cross-workspace:*"`. A future SPEC may allow per-Behavior cross-workspace grants (e.g. "User-X may dispatch chat actions across workspaces"). Would land as a new cap-string syntax (`"session.chat@*"` perhaps); orthogonal to this SPEC.
- **Cap expiration / TTL** — caps today are persistent. If TTL becomes needed, the cap string format gains a `;expires=<iso8601>` suffix; the matcher checks at runtime. Orthogonal.

---

## 12. Sequencing for codex review history

- **r1 codex:** `needs-attention` — 4 HIGH + 1 MEDIUM. Closed in r2 per §0a.
- **r2 codex:** `needs-attention` — 3 HIGH + 1 MEDIUM. Closed in r3 per §0b.
- **r3 codex:** `needs-attention` — 2 HIGH + 1 MEDIUM. Closed in r3-FINAL per §0c: HIGH-1 + HIGH-2 ACCEPTED as documented v1 trust-model limits (§10.5); MED-1 dedupe key FIXED structurally (§6.1). No r4 codex round per Allen 2026-05-25 manual ruling.
- **r4 (post-revert, not codex-driven):** Allen 2026-05-25 13:18 ruling — revert the string-cap representation (PR-CC-2a #347 + PR-CC-2b #348) via PR #349 to keep struct-shape caps in anticipation of future cryptographic verification. SPEC body §5–§9 preserved as historical record; §0d documents the in-force struct-shape design. PR-CC-2-v2 will re-implement Issue 2's structural goals with struct callbacks per §0d.3.

If r3 codex still HIGH/CRIT, focus review on:
- **Target CAS atomicity** (§5.3 step 8.5, §9.6 invariant) — review whether `Ezagent.Identity.cas_update_caps/2` via `:ets.select_replace/2` is truly atomic under concurrent-grant load (or if it needs a serialized `GenServer.call` instead).
- **Catalog dispatch gate** (§5.3 step 5.0a, §9.5 new invariant) — review whether the bypass test's `bypass_seed_for_test!` is representative of real-world bypass shapes, and whether telemetry `[:ezagent, :authz, :unknown_principal]` propagates to the audit table.
- **Anti-pattern probe set** (§9.2 P1-P12) — review whether the 12 probes have false-positive risk on test-support code (the `@allowed_paths` allowlist) or false-negative gaps (a 13th pattern shape).
- **Bilingual sync** (`.zh_cn.md` §6.1 and elsewhere) — codex spot-check that English and Chinese §6.1 / §9.2 / §9.5 / §9.6 say the same things.
