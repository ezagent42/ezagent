# SPEC — Capability struct gains the `action` axis

**Status:** r9.1 — IMPLEMENTATION-READY (after 9 codex adversarial-review rounds). 2026-05-27.

**r9.1 revision log:**
- codex r9 (low-effort confirm pass) flagged 2 more "admin role" residues at lines 33 + 242 — historical revision-log carryover from earlier revisions. r9.1 cleans both: line 33 revision-log entry now explicitly notes the cleanup; line 242 policy-table entry replaced with cap-holdings phrasing ("seeded admin user inherits this via SystemPrincipal.Catalog (cap-holdings, not a role)"). Lines 25 + 33's remaining "admin-role" mentions are DESCRIPTIVE of the rejected approach inside the revision-log block — preserved as historical context, not active prescription.
- After 9 rounds, the active SPEC sections (§3.x, §5, §6, §7, §8) are internally consistent. Implementation dispatch proceeds. PR-time codex review will catch any implementation defects per `feedback_codex_review_every_pr`.

**r9 revision log:**
- codex r8 MED: line 275 still said "role exemption" while line 253 had just established there's no role field. Single-line fix: replaced "via the role exemption" with explicit cap-holdings rationale (the admin caller's wildcard caps satisfy `holds_admin_caps?/1`; that's the structural mechanism, NOT a role-based exemption).

**r8 revision log (codex r7 findings):**
- MED RESIDUAL (cap/3 default contradicts §3.2): §8 failure-modes table wrongly said "cap/3 defaults the action via :any". Fixed — `cap/3` REQUIRES the third arg per §3.2; only direct `%Capability{...}` struct construction without `:action` key falls back to defstruct default `:any`.
- MED RESIDUAL (raw-map vs old-struct terminology conflation in §3.7 scope note): r8 distinguishes (i) truly raw map (no `__struct__` key — doesn't reach `ctx.caps` via any path) from (ii) old struct missing `:action` key (reaches `ctx.caps` via snapshot restore, handled by matcher-boundary `action_of/1` transparently). The `holds_admin_caps?/1` pattern works on shape (ii) without modification because Elixir struct pattern matching is non-exhaustive.
- HIGH NEW (§6 file manifest contradicted §3.7 strategy by listing `normalize_loaded/1` + `reconcile_after_load/2` as deliverables): r8 strikes those entries with explicit "REJECTED per §3.7 r3 strategy — do NOT implement" markers, replacing them with the actual file manifest (struct + helpers + matches?/2 via `action_of/1` + `to_map/from_map/1` updates).

**r7 revision log (codex r6 findings):**
- HIGH-1a (single-chokepoint inconsistency): §3.3 matcher snippet at line 152 + §5 A5 test description at line 304 still used direct field access while §3.3.1 claimed all readers route through `action_of/1`. r7 fixes both to use `Capability.action_of(cap)` form.
- Gap-C (line 352 `enforce_keys` contradiction): §3.1 says `:action` is NOT in `@enforce_keys` (defstruct default `:any` covers omission); the failure-modes table at line 352 wrongly said "must specify it (enforce_keys)". r7 fixes the table entry to match §3.1: defstruct default handles omission; runtime grant-boundary catches wildcards from non-privileged callers.
- MED (scope note overstated safety): codex r6 found 2 paths can insert raw maps without `from_map/1` (Identity.init_slice/1 ingestion + snapshot binary restore). r7 narrows the scope note to "production caps_json path is safe; the two narrower paths are pre-existing and independent of this SPEC". The matcher-boundary tolerance covers snapshot restore (path #2) structurally. The init_slice/1 case (path #1) is documented as a follow-up if the impl subagent audit surfaces real production risk.

**r6 revision log (codex r5 findings):**
- HIGH-1a (§3.6.1 still used direct `cap.action` reads): r6 routes both layers through `Capability.action_of/1` per the single-chokepoint contract from §3.3.1. Lines 232/234/283 updated.
- NEW-C (`holds_admin_caps?/1` only matches `%Capability{}` structs, not raw maps): scope clarified in §3.6.1 — the hot path (`Users.decode_caps/1` → `from_map/1` → struct) ALWAYS produces structs before `ctx.caps` is populated. Raw maps never reach `ctx.caps`. No change to `holds_admin_caps?/1` needed for correctness. r6 §3.6.1(b) adds an explicit scope note. (If a future code path inserts raw maps into `ctx.caps` bypassing `from_map/1`, that's its own bug — not introduced by this SPEC.)
- LOW-D (todo.md entry not yet added): r6 will commit it directly to `docs/futures/todo.md` in this commit (small addition; no need for a separate impl-PR touch).

**r5 revision log (codex r4 findings):**
- HIGH-1 (§3.3.1 inventory inaccurate — listed sites that don't read `.action`): r5 trims §3.3.1 to the actual real future reader sites confirmed by grep — `matches?/2` (`apps/ezagent_core/lib/ezagent/capability.ex:192`), `to_map/1` (`:525`), `from_map/1`. Stale paths dropped.
- HIGH-2 (admin-role exemption based on nonexistent role marker): r5 replaces it with `Behavior.Identity.holds_admin_caps?/1` (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:742`). This IS the existing canonical "is caller admin" check — it inspects the caller's actual caps for the full wildcard shape. NOT a URI match (which the codebase explicitly documents as non-security). NOT a role field (which doesn't exist). The §3.6.1(b) check uses this function — already used at `behavior/identity.ex:591, 631, 639` for the same purpose.
- HIGH-C (NEW codex r4 — admin promotion lifecycle): out-of-scope for this SPEC. "Promote to system" via `users_live.ex:224-229` adds workspace membership; demotion at `:248-250` removes membership but doesn't sweep granted caps. If an admin grants wildcard caps to a temporary system member, those caps survive demotion. PRE-EXISTING gap, independent of action-axis. Documented in §11 + `docs/futures/todo.md` as a separate cap-lifecycle PR.
- MED-2 (lv-anon-mount stale in allowlist): per codex r4 evidence, this principal has empty caps (`catalog.ex:268`), not wildcards. r5 removes from `@wildcard_allowlist` (matches codex `no_wildcard_system_principals_test.exs:77-82` which already exempts empty-cap entries from wildcard matching).
- LOW-B NEW (test guidance using `action_of/1`): r5 §6 adds a guidance note — tests asserting Capability action SHOULD use `Capability.action_of/1`; direct `.action` permitted only when explicitly testing freshly-constructed struct fields where the key is known to be present.
- LOW-D NEW (action-selector dropdown not in `docs/futures/todo.md`): r5 commits to add the entry to `docs/futures/todo.md` as part of the impl PR's docs touch — tracked as a §10 "out of scope" item with explicit todo.md target.

**r4 revision log (codex r3 findings):**
- HIGH-1 (Map.get not only in matches?/2 — `to_map/1` and admin/entity LV display also crash on missing `:action`): §3.3.1 added enumerating the full reader set. Pattern: every direct `cap.action` field read becomes `Map.get(cap, :action, :any)` — applies to `to_map/1` at `apps/ezagent_core/lib/ezagent/capability.ex:525`, admin/entity caps LV display at `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_caps_live.ex:151` + `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex:183-273`, and any audit/telemetry emit.
- HIGH-2 (admin LV grant form regression — `build_cap/2` doesn't pass action, runtime check would reject admin): §3.6.1(b) clarified — "non-privileged caller" means a caller whose `ctx.caps` does NOT satisfy `holds_admin_caps?/1` (i.e. holds no full-wildcard cap). Admin authority is structurally cap-holdings-based: the seeded admin user gets a wildcard cap from `SystemPrincipal.Catalog` at boot; that cap satisfies the predicate; the admin LV form's grant dispatches pass through. (r5 originally used "admin role" terminology — r9 cleaned that up because no role field exists in the codebase; r9.1 also strips it from this revision-log entry and the §3.6.1 policy table at line 242 for full consistency.) Future-PR note: extend the entity-caps LV form with an action selector so admins don't NEED wildcard grants for narrow surfaces.
- HIGH (struct enforce_keys): `:action` is NOT in `@enforce_keys` — only defstruct default of `:any`. Construction sites that don't pass action (existing `build_cap/2` in LV at `entity_caps_live.ex:182-191`) silently default to `:any`. r4 §3.1 updated to make this explicit; the runtime grant-boundary check is the enforcement, not enforce_keys.
- MED-1 (B3 test text stale — assumed normalization happens; r3 strategy doesn't normalize on load): B3 reworded to "matcher tolerance" — simulate an old-format cap (Map.delete the `:action` key), dispatch through `matches?/2` against a concrete-action needed-cap, assert wildcard semantics + no raise.
- MED-2 (C2 catalog allowlist — 6+ legitimate `:any` entries exist today: boot-reconciler, template-materialize, orchestrator-tools, session-internal, workspace-loader, feishu-binding-policy, plus chat-router/chat-reply/bootstrap/mix-task/lv-anon-mount wildcards): replace "0 unjustified wildcards" with `@wildcard_allowlist` MapSet enumerating exactly those principal URIs. Any new wildcard entry NOT in the allowlist fails the test — guards future drift, allows current legitimate state.
- MED-3 (plugin-check 11 scope — gates only plugin Behaviors, not umbrella core/domain): r4 §3.6.1(a) acknowledges the scope gap. The umbrella-wide A5 test (`apps/ezagent_core/test/ezagent/behavior_required_caps_action_invariant_test.exs`) iterates ALL Behaviors (core + domain + plugin) and asserts `entry_key == cap.action OR cap.action == :any` — this is the structural gate; plugin-check 11 is defense-in-depth at plugin compile time.
- LOW-2 (sweep count 184 vs 185): §6 corrected to 184; the false-positive was a doc-comment string in `capability.ex:80`.

**r3 revision log (codex r2 findings):**
- CRIT (still): codex r1's CRIT fix shape was wrong — `normalize_loaded/1`'s clause ordering raised on old structs (`%__MODULE__{} = cap` matched first; then `%{cap | action: :any}` raised on missing key). **r3 changes the strategy**: rather than normalize-on-load, `matches?/2` uses `Map.get(cap, :action, :any)` to treat a missing `:action` key as the wildcard at the matcher boundary. Backward-compat becomes structural at the only point that matters (cap-check); the normalize-on-load function becomes a cosmetic cleanup, not a correctness gate. This collapses CRIT + idempotence-HIGH + save-side-staleness-HIGH into one fix.
- HIGH (idempotence): resolved by structure — `Map.get/3` with default is idempotent on any cap shape.
- HIGH (save-side staleness window): resolved — in-flight Kinds running new code on old in-memory structs work correctly because `matches?/2` reads missing `:action` as `:any`. No save-side normalize needed; snapshots written with old shape still load correctly.
- HIGH residual §4.3 JSONB: r3 strikes the remaining "JSONB" sentence.
- MED (counts): r3 records the exact counting rule (`%Capability{` includes literal '`%Capability` followed by `{`; 185 raw, one false positive in a comment string = 184 real).
- MED (cross-PR): r2 codex's gh proxy failed; r3 reaffirms verification from the main agent (`gh pr list --state open` returned empty). Memo note: re-verify at impl PR open time.
- MED (`action: :any` policy): r3 adds two enforcement layers — (a) plugin-check 11 also verifies `cap.action == action OR cap.action == :any`; (b) `Identity.grant_cap/3` rejects `cap.action == :any` when caller is NOT a system principal (the policy becomes runtime-enforced at the grant boundary, not just code-review).
- MED (B1 "NO existing caps" imprecision): r3 acknowledges default Identity self-cap + `Users.create/3` default caps; the test SETUP spells out that none of those satisfy `:add_member`'s required cap.
- C2 (codex r2 calls it "weak as least-privilege regression"): r3 strengthens C2 to also assert that NO catalog entry has a `:any` action atom paired with a non-system principal caller surface; reframed as a least-privilege regression test.
- LOW (plugin-check 11): confirmed structurally additive (codex r2 retested).

**r2 → r3 file:line of changes:**
- §3.3 matches?/2: missing-key tolerance via `Map.get(cap, :action, :any)`
- §3.7 normalize_loaded: demoted from correctness-gate to cosmetic cleanup; clause ordering fixed; idempotence trivially holds
- §3.6.1: adds enforcement layer (b) — grant-time `:any` rejection
- §4.3: JSONB sentence struck
- §5 B1: setup precision (default-caps acknowledged)
- §5 C2: strengthened to least-privilege regression

**r2 revision log (codex r1 findings):**
- CRIT: `kind_snapshots.state_binary` (term_to_binary / binary_to_term) bypasses any JSON parse-time shim — §3.7 added (`Behavior.reconcile_after_load/2` on caps-holding Behaviors normalizes the loaded slice).
- HIGH: `users.caps_json` is Ecto `:string` / DB TEXT containing JSON, not JSONB (the SPEC's shim works regardless; r2 fixes the storage-type description).
- MED: real sweep counts (184 `%Capability{}` literals, 98 `Capability.cap(` calls, 24 Behaviors w/ `required_caps/0`, 65 map entries, 49 test files / 105 test hits) — §6 + §10 updated; ~100 was an under-estimate.
- MED: no open PRs (verified via `gh pr list`), one stale branch `feat/caps-cc-2-v2-required-caps` (its work is on main already) — rebase note dropped.
- MED: explicit `action: :any`-on-behavior policy — §3.6.1 added.
- MED: B1 invariant test setup spelled out concretely — §5 B1 amended.
- C2: `system://chat-router` currently uses `bootstrap_wildcard()`; the SPEC's "send-only" assumption was wrong. C2 replaced with a `system://session-internal` audit (a catalog entry that DOES name a Behavior wildcard).
- LOW: plugin-check 11 implementation confirmed structurally additive at `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex:724`.
**Tier:** `apps/ezagent_core/` framework rectification + sweep across every grant site, every `required_caps/0`, every test that constructs a cap.
**Trigger:** Allen 2026-05-27 Feishu — "显然应该恢复 action 字段". PR #408 + #409 surfaced the long-known over-grant: a workspace member granted `Behavior.Workspace :create_session` also satisfies the cap-check for `add_member`, `remove_member`, `set_routing_rules`, `create_agent`, …, because the cap struct discards the action argument.
**Companion:** `2026-05-27-capability-action-axis.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim, no dual-path. Action is added as a real struct field; default `:any` is the wildcard, not a sentinel-discarded value.
- `feedback_completion_requires_invariant_test` — the PR's merge gate is an invariant test that proves an `:add_member` cap on workspace://X does NOT satisfy `Behavior.Workspace :create_session`'s cap-check on the same workspace (today it does — that's the bug).
- `feedback_north_star_plugin_isolation` — plugin-author UX stays as `Capability.cap(:chat, __MODULE__, :send)`; the third arg becomes load-bearing rather than documentation.
- `feedback_subagent_must_load_project_skills` — the impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_companion_no_mix` — codex reviews on this SPEC + impl PR carry the verbatim "no mix" clause.

**Parent / historical context:**
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` r4 §0d — established struct-kept decision after reverting the PR-CC-2a/2b string-cap experiment. r4 chose to keep the existing 6-field struct shape; the action axis was discussed but **never implemented**.
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2 — even shows `action: :send` in the example struct construction (line 73 of that SPEC's signature block). The *intent* to encode action existed; the codebase never realized it.
- `docs/futures/todo.md` §"Capability struct lacks an action axis (codex PR #356 r1 CRIT)" — PR #356 codex r1 surfaced the gap; PR #408 round-3 reconfirmed it; this SPEC resolves it.

---

## 1. Problem in one paragraph

A capability today is a 4-axis match: kind × behavior × instance × workspace. The behavior axis carries the module name (`Ezagent.Behavior.Workspace`), so a cap "on the Workspace Behavior" is shape-equivalent across every action that Behavior defines. Most Behaviors today mix privilege tiers within one module — `Behavior.Workspace` has `list_members` (read-only), `add_member` (admin), and `create_session` (member-ok). Granting any single Workspace cap to a non-admin member opens the cap-check gate for every Workspace action on the same workspace. The same trap exists on every multi-action Behavior in the umbrella (Routing, ApiKeys, UserTokens, Feishu UserBinding, …). The fix is to add an explicit action axis to the cap match, so a cap granted for `:create_session` matches only `:create_session`'s gate, not `add_member`'s.

## 2. Why this can no longer wait

| Surface | Privilege mix today | Risk realized |
|---|---|---|
| `Behavior.Workspace` | list × admin × member | PR #408 round-3 — workspace member gets de-facto admin |
| `Behavior.Routing` | declare × set rules × list | low (no member-level grant site today) |
| `Behavior.IdentityAdmin` | grant × revoke × list | high — a "list-only" grant would also authorize grant/revoke |
| `Behavior.ApiKeys` | mint × revoke × list | high — same shape as IdentityAdmin |
| `Behavior.FeishuUserBinding` | bind × unbind × list | medium — exposed to plugin-author misuse |
| `Behavior.Template` (AgentTemplate + SessionTemplate) | read × write × instantiate × delete | high — instantiate is operator-tier; read is plugin-tier |

The PR #356 carve-out workaround (split each privileged action into its own Behavior module) is a partial mitigation that bloats the Behavior count and bleeds module names into UX surfaces. It is not the structural answer.

## 3. Design — one field, real comparison

### 3.1 Struct grows by one field — `:action` defstruct default `:any`, NOT in enforce_keys (r4 fix)

```elixir
@enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]
defstruct kind: nil,
          behavior: nil,
          action: :any,             # ← NEW field. Default :any (wildcard).
          instance: nil,            #    NOT in enforce_keys — old construction
          workspace_uri: nil,       #    sites that don't pass action silently
          granted_by: nil,          #    get :any. The runtime grant-boundary
          granted_at: nil           #    check (§3.6.1.b) is the enforcement.
```

**Why `:action` is NOT in `@enforce_keys`** (codex r3 HIGH): the existing `entity_caps_live.ex` admin grant form constructs caps via `build_cap/2` at `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex:182-191` WITHOUT passing an action field. Adding `:action` to enforce_keys would raise on every admin grant attempt — instant regression. Default `:any` + runtime check at the grant boundary is the structural fix: the form keeps working (silently produces a wildcard cap), the grant boundary rejects wildcards from non-privileged principals (§3.6.1.b).

Old grant sites that pass no action become `action: :any` — the wildcard — preserving current admin / system-principal semantics. Going forward, every new grant-site author writes the action explicitly per the §3.6.1 policy.

### 3.2 Constructor stops discarding the action arg

```elixir
def cap(kind, behavior, action) when is_atom(kind) and is_atom(behavior) and is_atom(action) do
  %__MODULE__{
    kind: kind,
    behavior: behavior,
    action: action,            # ← was `_action`, the third-arg-discard hole
    instance: :any,
    workspace_uri: :any,
    granted_by: @plugin_declared_granter,
    granted_at: @compile_time_granted_at
  }
end

def cap(kind, behavior, action, instance, workspace_uri)
    when is_atom(kind) and is_atom(behavior) and is_atom(action) do
  %__MODULE__{
    kind: kind,
    behavior: behavior,
    action: action,
    instance: instance,
    workspace_uri: workspace_uri,
    granted_by: @plugin_declared_granter,
    granted_at: @compile_time_granted_at
  }
end
```

The signature is unchanged — only the body stops dropping the third arg on the floor.

### 3.3 `matches?/2` gains action as the fifth match dimension — missing-key tolerant

```elixir
def matches?(%__MODULE__{} = cap, %{kind: k, behavior: b, action: a, instance: i, workspace_uri: w}) do
  # codex r2 fix: read action via Map.get with default :any so deserialized
  # OLD caps (struct without the :action key) match transparently as
  # wildcard. This removes the hard dependency on normalize-on-load: an
  # in-flight Kind running new code on old in-memory structs works
  # correctly without a save-side normalize step.
  field_match?(cap.kind, k) and
    field_match?(cap.behavior, b) and
    field_match?(action_of(cap), a) and
    instance_match?(cap.instance, i) and
    workspace_match?(cap.workspace_uri, w)
end
```

The needed-cap shape (the second arg) gains `:action`. Today's needed-cap is constructed by `Ezagent.Kind.Runtime`'s `authz_check` from the dispatch target + action atom; that call site needs one new field (`action: <the action atom>`).

**Why `Map.get` instead of `cap.action` direct access**: Elixir struct field access compiles to `case cap do %Cap{action: a} -> a end` which requires the key to be present on the map. A deserialized OLD cap (from `binary_to_term` of a pre-SPEC snapshot) is a map without `:action` — `cap.action` would crash. `Map.get(cap, :action, :any)` returns `:any` for missing keys without crashing. This makes the match always-correct regardless of when the cap was last serialized.

**Performance**: `Map.get` is one extra map lookup per match call vs direct field access — negligible. Hot-path overhead measured in nanoseconds; not perf-sensitive.

### 3.3.1 The cap readers that will read `cap.action` after this SPEC — single helper chokepoint

codex r4 HIGH-1 correction: a grep today (`rg -nP "\.action\b" apps/` + filter for Capability-related) shows NO existing `cap.action` access — because the field doesn't exist yet. After this SPEC adds the field, exactly THREE production paths will read it:

| Site | File:line | Today | After SPEC |
|---|---|---|---|
| Matcher | `apps/ezagent_core/lib/ezagent/capability.ex:192` (`matches?/2`) | No `cap.action` access | Uses `Capability.action_of/1` per §3.3 |
| Serializer | `apps/ezagent_core/lib/ezagent/capability.ex:525` (`to_map/1`) | No action field in output map | `"action" => Capability.action_of(cap) \|> atom_or_module_to_string()` |
| Deserializer | `apps/ezagent_core/lib/ezagent/capability.ex` `from_map/1` | No `:action` parse | `Map.put_new(parsed, "action", "any")` before atomization |

LV display sites (admin_caps_live.ex, entity_caps_live.ex) inherit correctness from `to_map/1` since they render via that path — no direct `.action` field access in those LV templates today.

**The `Capability.action_of/1` helper is the single chokepoint:**

```elixir
@doc """
Read the action axis of a cap, defaulting to `:any` for caps loaded
from pre-action-axis snapshots (missing `:action` key).
"""
@spec action_of(t() | map()) :: atom()
def action_of(cap), do: Map.get(cap, :action, :any)
```

Every cap reader uses `action_of/1` rather than direct field access or scattered `Map.get`. One place to evolve the rule if needed.

**Sweep instruction for impl subagent**: after adding the field, `rg -nP "(?<!action_of\()cap\.action|\.action\s*==\s*:|\.action\s*\|>" apps/` to catch any non-helper-route direct reads. Expected: zero hits after the conversion sweep.

### 3.4 Persistence: `caps_json` JSON gains a 7th field, with a backward-compat read path

**Storage shape** (codex r1 HIGH correction): `users.caps_json` is Ecto `:string` (DB `TEXT`) containing serialized JSON (`apps/ezagent_domain_identity/lib/ezagent/users.ex:27`, `apps/ezagent_core/priv/repo/migrations/20260520000000_phase4_users.exs:8`). Not JSONB. The shim works regardless of column type — atomization happens in `Capability.from_map/1` at `apps/ezagent_domain_identity/lib/ezagent/users.ex:212`.

| Read direction | Old row (6 fields, no `action`) | New row (7 fields) |
|---|---|---|
| Load → struct | Default `action: :any` injected before atomization | Read as-is |
| Save → JSON | All 7 fields serialized | All 7 fields serialized |

The backward-compat read path is **not a shim per the let-it-crash policy** — it is the canonical interpretation of an old row: a 6-field cap was always semantically "any action on this Behavior", and `:any` is precisely how the new shape spells that. The read path is one line: `Map.put_new(parsed_map, "action", "any")` in `Capability.from_map/1` before key-atomization. No migration required; old rows promote on first read.

### 3.5 `Behavior.required_caps/0` semantics — action is now load-bearing

Every Behavior's `required_caps/0` already enumerates one entry per action. Today the *map key* differentiates actions but the *cap struct* is shape-equivalent. After this SPEC, the struct's `action` field equals the map key — they double-encode the action, which is fine (the map key is the dispatch lookup, the struct field is the matcher input).

The plugin-author API stays identical:

```elixir
def required_caps do
  %{
    send: Capability.cap(:chat, __MODULE__, :send),
    receive: Capability.cap(:chat, __MODULE__, :receive)
  }
end
```

The third arg becomes load-bearing without any plugin-author migration.

### 3.6 Wildcard grants stay wildcard

`User.admin_uri()` and `system://bootstrap` already get a `kind: :any, behavior: :any, instance: :any, workspace_uri: :any` cap. After this SPEC they additionally get `action: :any` — same wildcard semantics. Catalog entries that named specific actions (`SystemPrincipal.Catalog`'s 14 entries) gain a real action value; their narrowing effect becomes structurally meaningful.

### 3.6.1 Policy: when `action: :any` is OK and when it is not (codex r1 MED-F)

After this SPEC, three cap shapes coexist:

| Shape | Example | Allowed grant surface |
|---|---|---|
| Full wildcard | `%Capability{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any}` | `system://bootstrap` only; the seeded admin user inherits this via `SystemPrincipal.Catalog` (cap-holdings, not a role). NOT exposed to plugin grant paths. |
| Behavior-wildcard | `%Capability{kind: :workspace, behavior: Workspace, action: :any, instance: :any, workspace_uri: :any}` | Closed system principals only (existing catalog pattern, e.g. `Capability.cap(:workspace, Workspace, :any)` at `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:205`). NOT a default grant for users. |
| Narrow | `%Capability{kind: :workspace, behavior: Workspace, action: :create_session, instance: <uri>, workspace_uri: <uri>}` | The default grant shape for all user-facing flows (the auto-grant on `add_member` in PR #408 is one example). |

**Policy rule**: any grant site that takes a user-supplied or member-supplied principal MUST pass a concrete action atom. Behavior-wildcard caps are reserved for the catalog (which is closed by `feedback_let_it_crash_no_workarounds` and never user-extensible).

**Enforcement (codex r2 MED — promoted from code-review-only)**: two layers, both shipped in this PR.

1. **Compile-time (plugin-check 11)**: extend the existing check at `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex:724` to also verify `Capability.action_of(required_caps[action]) == action OR Capability.action_of(required_caps[action]) == :any`. A behavior-wildcard in `required_caps/0` is rare but legitimate for orchestrator-style Behaviors (per the existing PR-CC-2-v2 §4 "any_action escape hatch" doc). The check enforces map-key / cap-action-axis coherence, blocking drift at compile time. (Uses `action_of/1` per §3.3.1 — required-caps maps are populated at compile time so the cap always has the field, but routing through the helper keeps the SPEC's "single chokepoint" invariant.)

2. **Runtime grant-boundary (Identity.grant_cap/3)**: at the grant entrypoint inside the `IdentityAdmin :grant_cap` action body (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` — locate the `invoke(:grant_cap, ...)` clause), if `Capability.action_of(cap_to_grant) == :any` AND the caller does NOT pass `holds_admin_caps?/1`, return `{:error, :wildcard_action_grant_requires_admin_authority}`. (Uses `action_of/1` since `cap_to_grant` could arrive from any caller — defensive against arbitrary-shape input.)

**The privileged check** uses the EXISTING `holds_admin_caps?/1` predicate at `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:742` (codex r4 HIGH-2 fix). This function inspects the caller's actual caps for the full-wildcard shape `%Capability{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any}` — it is THE canonical "is caller admin" check, already used for the same gating purpose at lines 591, 631, 639.

**Backward-compat scope (codex r5 SPEC option-B clarification)**: this SPEC's matcher-boundary tolerance (`action_of/1` defaulting missing `:action` to `:any` per §3.3) ONLY applies at the **dispatch step 5.5 matcher**. The admin predicates (`holds_admin_caps?/1`, `holds_workspace_admin_cap?/2`, `holds_cross_workspace_admin_cap?/1`, `Capability.admin_invariant?/1`, `ExternalMirror.cap_admin_shape?/1`) require **explicit `action: :any`** — they do NOT accept missing-key shapes. Pre-SPEC admin caps loaded from snapshots without `:action` are NOT auto-recognized as admin; operators must re-grant via `Identity.grant_cap` (which writes `action: :any` via `normalize!/2`). This is an intentional design choice (option B) — see SPEC option-B revision log for the empirical rationale (Map.delete forge and genuine legacy snapshot caps produce indistinguishable shapes; legacy fallback at admin layer was equivalent to accepting Map.delete forgery).

This is NOT a role-field check. The codebase has no `role` field; the URI-based `Identity.admin?/1` predicate is explicitly documented as NON-security (`apps/ezagent_domain_identity/lib/ezagent/identity.ex:266-269`). Privilege is based on the caller's actual cap holdings — the only structural marker that survives spoofing attempts.

**Scope note on cap shape in `ctx.caps`** (codex r5 NEW-C, narrowed per codex r6 MED, terminology corrected per codex r7 MED): TWO distinct shapes need to be distinguished:

(i) **Truly raw map** (no `__struct__` key, e.g. `%{kind: ..., behavior: ..., ...}`): would fail BOTH `matches?/2`'s struct pattern AND `holds_admin_caps?/1`'s pattern. The `%__MODULE__{} = cap` pattern at §3.3 line 149 doesn't match. There's no path that puts truly-raw maps into `ctx.caps` in this codebase — `from_map/1` always reconstructs to a struct.

(ii) **Old struct missing the `:action` key** (post-deserialization from a pre-SPEC snapshot — `%{__struct__: Ezagent.Capability, kind: ..., behavior: ..., instance: ..., workspace_uri: ..., granted_by: ..., granted_at: ...}` with no `:action` field): Elixir struct pattern matching is NON-exhaustive, so `%__MODULE__{} = cap` DOES match. `action_of/1` (`Map.get(cap, :action, :any)`) returns `:any` as designed. The matcher boundary handles this transparently.

`holds_admin_caps?/1`'s pattern at `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:745` is **`%Ezagent.Capability{kind: :any, behavior: :any, action: :any, instance: :any, workspace_uri: :any}`** — REQUIRES explicit `action: :any`. Per option-B (codex r5 SPEC clarification), shape (ii) is REJECTED at admin predicates. The matcher boundary (§3.3) keeps the missing-key tolerance for legacy non-admin caps; the admin predicate layer is strict to close the Map.delete-forge surface. Pre-SPEC admin caps in snapshots need re-grant — operator runs `mix ezagent identity grant_cap ...` (via dispatch which goes through `normalize!/2` and writes `action: :any`).

This is NOT a correctness gap for the **production caps_json path**: `Users.decode_caps/1` at `apps/ezagent_domain_identity/lib/ezagent/users.ex:209-212` calls `Capability.from_map/1` which returns `%Capability{}`; `SystemPrincipal.caps/1` at `apps/ezagent_core/lib/ezagent/system_principal.ex:156-163` also produces structs via Catalog at `catalog.ex:125-128, 285-293`.

**Acknowledged narrower-scope concern** (codex r6 MED): two paths CAN insert raw maps into a slice without re-validating through `from_map/1`:
1. `Behavior.Identity.init_slice/1` at `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:92-98` accepts `%MapSet{}` or list-from-init-args as-is. Practical risk: zero in production (args come from `Users.create/3` which has already gone through `from_map`), but a test fixture or future caller could push raw maps here.
2. Snapshot restore path `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:72-98` decodes the slice via `binary_to_term` and merges without normalization — raw maps stored pre-SPEC would still be raw maps post-restore.

This SPEC's `Map.get`/`action_of/1` tolerance at the matcher boundary handles path #2 transparently (missing `:action` → `:any` → wildcard preserved). Path #1's failure mode (raw map in `init_slice/1`) is independent of this SPEC and predates it. The admin-cap predicate `holds_admin_caps?/1` is upstream of dispatch and structurally fed by `Users.decode_caps/1` for every real cap-load — raw-map insertion would have been broken before this SPEC.

**No SPEC change to `holds_admin_caps?/1` proposed**; if the impl subagent's audit surfaces a real production path where raw maps reach `ctx.caps`, that's a follow-up PR.

**Future-PR note** (`docs/futures/todo.md`): extend the entity-caps LV grant form with an action selector dropdown (populated from the target Behavior's `actions/0`), so admins can grant narrow caps via the UI without falling back to wildcard. This SPEC's runtime check + admin exemption is the bridge; the action selector is the long-term fix.

This makes the policy structurally enforced for non-admin paths, not just documented. A plugin author writing `required_caps/0` can't drift (compile check 11); a user-facing grant path can't accidentally widen (runtime check rejects); the admin LV form continues working today because the logged-in admin caller's wildcard caps satisfy `holds_admin_caps?/1` and the runtime check passes (NOT a "role exemption" — admin authority IS the caller's cap-holdings).

### 3.7 Snapshot binary restore — handled structurally at `matches?/2`, not by reconcile-on-load (codex r2 fix)

The naïve fix attempted in r2 was to `reconcile_after_load/2` normalize Identity slice caps post-restore. Codex r2 BLOCKed it: the proposed `normalize_loaded/1` clause ordering raised on the primary missing-key shape, and a save-side staleness window remained (long-running Kinds in new code can write old-shape snapshots before the first restart).

**r3 strategy**: handle the missing-`:action` key transparently at the SINGLE point that matters — `Capability.matches?/2`. §3.3 uses `Map.get(cap, :action, :any)` for the action field read. This means:

1. **Old in-memory cap structs (no :action key) work correctly** — `Map.get` returns `:any` (wildcard), `matches?/2` proceeds as if action were unspecified. Behavior is identical to today's "no action axis" semantics. ✅
2. **Old snapshot-restored caps work correctly** — same reason. No `reconcile_after_load/2` needed for correctness. ✅
3. **Save-side staleness window vanishes** — there's nothing to "stale". An old cap written to a new snapshot loads correctly via the same `Map.get` path. ✅
4. **New caps with concrete `:action`** — `Map.get` returns the concrete atom, narrow match applies as designed. ✅

**Cosmetic cleanup (not correctness-required)**: A best-effort `Capability.normalize_loaded/1` + an Identity `reconcile_after_load/2` callback can be added in a SEPARATE PR after this one lands, to eventually rewrite old-shape caps with explicit `:action` on first restore. Marked as a `docs/futures/todo.md` follow-up, not a blocker for this PR.

```elixir
# Future PR — cosmetic only. THIS SPEC does not require it.
def normalize_loaded(%__MODULE__{} = cap) do
  cap |> Map.put_new(:action, :any)  # works on both old (no :action) and new caps; idempotent
end
```

Notice the simpler shape — `Map.put_new` on a struct map works regardless of whether `:action` is present, because the struct is itself a map. No clause-ordering hazard.

**Alternative considered + rejected (codex r2 raised it as r2's CRIT)**: the `Behavior.reconcile_after_load/2` approach. Rejected for this PR because (a) it requires Identity to know about Capability's internal shape (cross-module coupling), (b) the clause-ordering correctness depends on Elixir struct-pattern semantics in a non-obvious way, (c) it doesn't solve the save-side staleness window for long-running Kinds. The matcher-boundary fix (§3.3) is structurally cleaner: ONE function knows about the missing-key shape, everyone else sees a normal cap struct.

## 4. Migration strategy

### 4.1 Single coordinated PR — no dual-path

Allen's `feedback_let_it_crash_no_workarounds` forbids dual-path. The PR lands all of:

1. Capability struct + helpers + matches?/2 — one commit
2. All `required_caps/0` action threading audit — one commit (mostly verifies the third arg matches the map key; expect ≤5 typo fixes)
3. All grant sites (`Identity.grant_cap`, `IdentityAdmin`, `SystemPrincipal.Catalog`) — one commit
4. `caps_json` backward-compat read shim (the `Map.put_new(..., "action", "any")` line + a Capability.from_map/1 audit) — one commit
5. Invariant test + per-Behavior coverage tests — one commit
6. The over-grant regression test (PR #408 round-3's exact case: workspace member with `:create_session` cap is denied `:add_member`) — one commit

### 4.2 Compile-time check 10

`:ezagent_plugin_check`'s existing check 10 ("every action has a required_caps entry") gains a sibling check 11: `Capability.action_of(required_caps[action]) == action OR :any` — guarantees the map key and cap-action-axis don't drift.

### 4.3 No DB schema migration

`caps_json` is Ecto `:string` (DB `TEXT`) holding serialized JSON (codex r2 HIGH correction). New rows write 7-field JSON; old rows parse with the `Map.put_new("action", "any")` shim before atomization. No `alter table` needed. The schema migration list in this PR is empty — that is the design.

## 5. Acceptance criteria

| # | Test | Pass condition |
|---|---|---|
| A1 | `Capability.cap(:chat, Chat, :send).action == :send` | unit test |
| A2 | `Capability.matches?/2` with held `action: :send` and needed `action: :join` → false | unit test |
| A3 | `Capability.matches?/2` with held `action: :any` and needed `action: :send` → true (wildcard preserved) | unit test |
| A4 | Old JSON row (6 fields) loads with `action: :any` | unit test |
| A5 | `required_caps/0` entries: every `Behavior` has `Capability.action_of(entry[action]) == action OR :any` | umbrella-wide property test |
| A6 | Compile-time check 11 fails a deliberately-broken fixture (`%{send: cap(.., .., :join)}`) | plugin-check test |
| **B1** | **The PR #408 regression test (THE merge gate)** — concrete setup: (1) spawn `workspace://X` via the normal Workspace facade; (2) create a non-admin user `entity://user/X/member-1` via `Users.create/3` — note that `Users.create` grants default caps at `apps/ezagent_domain_identity/lib/ezagent/users.ex:76-84` and `Behavior.Identity.create_user/3` adds a self-Identity cap at `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:113-122`; the test relies on those defaults NOT matching `Behavior.Workspace :add_member`'s required cap (kind axis differs: defaults are `:user` / `:session`-scoped, `:add_member` requires `:workspace`); (3) seed exactly one additional cap: `%Capability{kind: :workspace, behavior: Ezagent.Behavior.Workspace, action: :create_session, instance: workspace_uri, workspace_uri: workspace_uri, granted_by: SystemPrincipal.uri("template-materialize"), granted_at: <now>}` on the user via `Identity.grant_cap`; (4) dispatch `Invocation{target: URI.parse("workspace://X?action=workspace.add_member"), mode: :call, args: %{member: <other_user_uri>}, ctx: %{caller: member_uri, caps: <slice-loaded>, ...}}`; (5) assert `{:error, :unauthorized}` is returned from dispatch step 5.5 at `apps/ezagent_core/lib/ezagent/kind/runtime.ex:121` BEFORE `invoke(:add_member, ...)` runs (verify by reading the workspace slice's `members` after the call — must equal pre-call members; the dispatched user must NOT have been added). | invariant test |
| B2 | Same member, same cap, dispatch to `workspace://X?action=workspace.create_session` — assert `{:ok, _, _}` (the cap matches; creation succeeds) | invariant test |
| **B3** | **Matcher tolerance for missing :action (codex r3 r4 reframe)** — (1) construct a cap as `Map.delete(%Capability{kind: :chat, behavior: Chat, instance: :any, workspace_uri: :any, granted_by: <some>, granted_at: <now>}, :action)` — simulates the post-`binary_to_term` shape of an OLD snapshot; (2) `term_to_binary` and `binary_to_term` round-trip to confirm the deserialized map is still missing `:action`; (3) call `Capability.matches?(deserialized_cap, %{kind: :chat, behavior: Chat, action: :send, instance: <uri>, workspace_uri: <uri>})`; (4) assert returns `true` (Map.get default `:any` matches concrete `:send`); (5) assert no `KeyError` or other crash. Does NOT assert post-load normalization — that's a future-PR cosmetic cleanup, not gating this PR. | invariant test |
| C1 | Admin wildcard cap (`kind: :any, behavior: :any, action: :any, …`) still satisfies every action | regression test |
| C2 | **`SystemPrincipal.Catalog` wildcard allowlist regression** — (a) every catalog entry's concrete action atom (when not `:any`) matches a real `actions/0` entry of the named Behavior; (b) the test module defines `@wildcard_allowlist` as a MapSet of principal URIs CURRENTLY known to legitimately carry wildcard caps: `system://bootstrap`, `system://mix-task`, `system://chat-router`, `system://chat-reply`, `system://boot-reconciler`, `system://template-materialize`, `system://orchestrator-tools`, `system://session-internal`, `system://workspace-loader`, `system://feishu-binding-policy`. EXCLUDED: `system://lv-anon-mount` (per codex r4 evidence, this principal has empty caps at `catalog.ex:268` — handled by `apps/ezagent_core/test/ezagent/system_principal/no_wildcard_system_principals_test.exs:77-82` already, no allowlist entry needed); (c) every catalog entry with a `:any`-action cap MUST have its principal URI in `@wildcard_allowlist` — any NEW catalog wildcard entry added without an allowlist update fails this test, preventing drift | catalog audit test |

## 6. Files affected (estimated)

**Core changes (small):**
- `apps/ezagent_core/lib/ezagent/capability.ex` — struct (+`:action` defstruct, NOT in @enforce_keys) + helpers (`cap/3`, `cap/5` stop discarding third arg) + `matches?/2` (uses `action_of/1` for missing-key tolerance) + new `action_of/1` helper + `to_map/1` adds the field via `action_of/1` + `from_map/1` reads `"action"` with `Map.put_new("action", "any")` shim. Stale references to `normalize_loaded/1` / `reconcile_after_load/2` from earlier SPEC revisions are REJECTED per §3.7 r3 strategy change — do NOT implement them.
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` — authz_check needed-cap construction (one field added)
- `apps/ezagent_core/lib/ezagent/identity/admin.ex` — grant_cap / revoke_cap may need to normalize action on input
- `apps/ezagent_domain_identity/lib/ezagent/users.ex:212` — `Capability.from_map/1` adds `Map.put_new("action", "any")` before atomization
- ~~`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` — implement `reconcile_after_load/2` to walk + `Capability.normalize_loaded/1` over slice.caps~~ — **REJECTED per §3.7 r3 strategy** (matcher-boundary fix at §3.3 supersedes; no Identity change required for correctness)
- ~~Any other Behavior whose slice carries caps via snapshot — audit + implement `reconcile_after_load/2`~~ — **REJECTED per §3.7 r3 strategy**. The matcher-boundary tolerance (§3.3 + §3.3.1's `action_of/1`) handles old-shape caps transparently in every reader.

**Sweep (mechanical, real counts from codex r1 grep):**
- **184** direct `%Capability{}` struct literals (production + test) — codex r3 LOW-2 fix: 185 raw `rg %Capability{` minus 1 false-positive at `apps/ezagent_core/lib/ezagent/capability.ex:80` (doc-comment string referencing the struct, not a real construction)
- **98** `Capability.cap(` calls (3-arity + 5-arity)
- **24** `def required_caps do` Behavior implementations
- **65** entries inside those required_caps maps
- **49** test files / **105** test hits referencing `%Capability{}` or `%Ezagent.Capability{}`

The plugin-author API (`Capability.cap(:chat, Chat, :send)`) needs zero changes — the 98 `cap(` call sites already pass the right action atom as the third arg. The 184 direct `%Capability{}` literals each need an `action:` field added; expect to write a quick `mix script` or sed-like batch with a manual-review pass for `action: :any` vs `action: :concrete`.

**New tests:**
- `apps/ezagent_core/test/ezagent/capability_action_test.exs` — A1–A4 + C1
- `apps/ezagent_core/test/ezagent/behavior_required_caps_action_invariant_test.exs` — A5
- `apps/ezagent_core/test/integration/cap_action_axis_invariant_test.exs` — **B1 + B2** (the merge gate; setup spelled out above)
- `apps/ezagent_core/test/integration/cap_action_axis_snapshot_restore_test.exs` — **B3** (snapshot-bypass regression — codex r1 CRIT)
- `apps/ezagent_core/test/ezagent/system_principal_catalog_action_audit_test.exs` — C2 (per-entry action atom validity)

## 7. Out of scope

- Cryptographic cap fields (signature, nonce, issued_at) — `2026-05-25-caps-cleanup-v1.md` r4 §44 mentions these as "additive future extensions"; this SPEC is one field at a time.
- `Capability.matches?/2` returning a structured reason for denial (today: boolean). Useful for diagnostics, separate PR.
- Renaming `cap_subjects/0` or any registry API. Existing UI / catalog flow unchanged.
- Removing the PR #356 `WorkspaceUserAdmin` carve-out — that module exists for a different reason (privilege isolation by registration) and stays.
- **Admin promotion cap-lifecycle cleanup** (codex r4 HIGH-C). Pre-existing gap: `users_live "Promote to system"` adds workspace membership; demotion removes membership but doesn't sweep caps that were granted DURING promotion. Wildcard caps granted to a temporary system member can survive demotion. INDEPENDENT of this SPEC — exists today regardless of action-axis. Tracked in `docs/futures/todo.md` as a separate cap-lifecycle PR.
- **Entity-caps LV action-selector dropdown** (codex r4 LOW-D). The admin grant form at `entity_caps_live.ex:182-191` doesn't expose an action field; defaults to `:any`. Per §3.6.1(b) the runtime check allows this from admin callers. Future PR adds a dropdown populated from the target Behavior's `actions/0`. Tracked in `docs/futures/todo.md` (the impl PR for this SPEC includes the todo.md entry).
- **Test code sweep using `action_of/1`** (codex r4 LOW-B). The 105 test hits accessing `.action` directly remain valid IF they assert on freshly-constructed caps where the key is known present. Where tests read caps from snapshot-loaded state (rare), they SHOULD use `Capability.action_of/1`. Pragmatic guidance, not strict requirement — the impl subagent makes the call per-site.

## 8. Risks / failure modes considered

| Failure | Behavior |
|---|---|
| A grant site forgets to specify action and passes nothing | `cap/3` REQUIRES the third arg (per §3.2 signature) and stores it as `action: action` — no Elixir-level default. Only direct `%Capability{...}` struct construction without an `:action` key falls back to the defstruct default `:any` (per §3.1 — `:action` is NOT in `@enforce_keys`). The runtime grant-boundary check at §3.6.1(b) is the structural enforcement: non-privileged callers granting `action_of(cap) == :any` are rejected. The plugin-check 11 catches `required_caps/0` drift at compile time. |
| Two callers race writing caps_json with overlapping cap shapes | Existing Ecto optimistic concurrency / slice revision-CAS unchanged. |
| Old row reads as `:any` but the user's intent was a narrow cap | Impossible by construction — old code never wrote a narrow cap (the field didn't exist). `:any` is the only correct interpretation. |
| Plugin author's required_caps map key differs from the third arg | Compile-time check 11 fails the build. |
| `SystemPrincipal.Catalog` regression breaks boot | Catalog audit test in section 5 C2 catches it pre-merge. |
| Action atom typo passes compile but fails at runtime cap-check | Same as today's action-atom typos in `actions/0` — caught by integration tests. |

## 9. Codex adversarial review questions

1. **Backward-compat boundary**: is `Map.put_new("action", "any")` truly the canonical interpretation of an old 6-field row, or does it silently broaden a previously-narrow grant? Verify against an actual `caps_json` row from a running dev DB.
2. **Wildcard cascade**: a cap with `action: :any` plus `behavior: :any` plus `instance: :any` is the admin wildcard. After this SPEC, is there any way to construct a cap that authorizes the admin wildcard's behavior but NOT every action? Should there be?
3. **`SystemPrincipal.Catalog` 14 entries**: do all 14 entries' action atoms match real `actions/0` entries on the corresponding Behavior? Run a grep + cross-check.
4. **`Behavior.required_caps/0`'s implicit invariant `entry_key == cap.action`**: is the compile-time check 11 enforceable in `:ezagent_plugin_check`'s existing structure, or does it need a new AST walker?
5. **Cross-Behavior caps**: any Behavior whose `required_caps/0` references *another* Behavior's action (rare but possible — e.g. a derived action that internally calls dispatch on another Kind)? Action axis must match the OUTER action, not the inner.
6. **Test impact**: how many existing tests construct `%Capability{}` directly without going through `Capability.cap/N`? Each is a manual-edit site.
7. **Race condition between deployment of new code and reading old caps_json rows**: the read path's `Map.put_new("action", "any")` runs in-process when loading. Any path that bypasses it? (E.g. raw Repo.all where the cap struct is reconstructed by `Ecto.Schema.load/2` outside the from_map shim.)
8. **`Catalog` test C2 specificity**: `system://chat-router :send` denied `:receive` on the same Session — does the catalog actually grant `:send` only, or does it also grant `:receive`? Verify what the catalog currently encodes.

## 10. Open questions for Allen

1. **Cap-axis ordering for diagnostics**: when a cap-check fails, the error message could name which axis didn't match (`action mismatch: held :send, needed :join`). Useful for plugin-author debug. Default: log-only at debug level; UI surfaces a generic "unauthorized". Scope this in or out?
2. **`cap_exempt_actions/0`** — Behaviors that intentionally bypass cap-check for some actions (declared via `cap_exempt_actions/0`). After action-axis, exempt-action handling stays per-action; no change. Confirm OK.
3. **Future grant audits**: should the audit trail (`Ezagent.Audit`) start recording the action that was checked alongside the cap that authorized it? Today it records the cap but not the action match — a minor diagnostic improvement.

## 11. Rollback plan

Single-PR change. Rollback = revert the merge commit. The backward-compat read path means rolled-back code can still read rows written by the new code (they have an extra `action` field; old code ignores unknown JSON keys via the existing parse path). Risk: a row written with a narrow action under the new code reverts to "any action" semantics on rollback — strictly broader, never denies. Acceptable as a one-step rollback safety net.

---

## Appendix A — Why this SPEC is short

Per `feedback_explain_problem_not_code_structure`, the SPEC describes the problem + design intent. The PR's implementation subagent will execute the sweep mechanically — it's mostly threading one atom through a hundred call sites that already pass the right atom as the third arg. The interesting work is in the invariant test (B1) and the catalog audit (C2).

## Appendix B — Why the PR-CC-2-v2 SPEC's example showed `action: :send` even though the field doesn't exist

PR-CC-2-v2's SPEC at `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2 line 73 has:

```elixir
%Capability{
  kind: :chat,
  behavior: Ezagent.Behavior.Chat,
  action: :send,           # ← in SPEC, never in struct
  ...
}
```

This is a SPEC-vs-code drift dating to 2026-05-25. The SPEC reflected the *desired* shape; the implementation kept the existing 6-field struct. Allen's 2026-05-27 directive closes the drift by making the SPEC's intent the actual implementation. **The action field was never in the struct — the SPEC just promised it would be.**
