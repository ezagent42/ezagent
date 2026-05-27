# SPEC — URI canonicalization across boundaries (Bug 2)

**Status:** r1 — DRAFT for codex adversarial-review. 2026-05-27.

**Tier:** `apps/ezagent_core/` (`Ezagent.URI` parser/canonicalizer) + sweep across every Domain + Plugin that constructs `%URI{}` (`apps/ezagent_domain_*/`, `apps/ezagent_plugin_*/`, `apps/ezagent_web/`, `apps/ezagent_cli/`). Touches the test base too (helpers + fixtures) but production sites are the load-bearing scope.

**Trigger:** test failure `apps/ezagent_web/test/ezagent_web/live/home_live_test.exs:66` — wizard `create_session` flow returns `:grant_owner_orchestrator_admin_cap_failed` because `caller == owner` strict-equality fails between an `URI.parse`-built `@admin_uri` (authority:"user") and an `URI.new!`-built `owner_uri` (authority:nil) for the SAME canonical URI string `entity://user/system/admin`.

**Companion:** `2026-05-27-uri-canonicalization.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — NO dual-path. The canonical helper exists; producers route through it; non-canonical constructors at boundary sites are DELETED (not deprecated, not aliased, not feature-flagged). No "v2 toggle".
- `feedback_completion_requires_invariant_test` — merge gate is an invariant test that FAILS when a future contributor reintroduces a boundary call to stdlib `URI.parse/1` or `URI.new!/1` for an Ezagent-scheme URI (Section 5). Tests-pass + manual code review is not the gate; a structural test that catches the violation IS.
- `feedback_register_lookup_key_parity` — this bug IS the register/lookup-key-parity lesson playing out for URI struct representation. The canonical helper enforces parity on BOTH sides; partial migration of producers without the matching change at consumer comparison surfaces would reproduce the bug class.
- `feedback_north_star_plugin_isolation` — plugin authors writing a new Behavior must NOT know about `URI.parse` vs `URI.new!`. The canonical helper is the one boundary chokepoint; plugin code calls it, gets a canonical `%URI{}`, and never touches stdlib URI constructors for Ezagent-scheme URIs.
- `feedback_uuid_is_canonical_identifier` — the canonical form must NOT depend on display-mutable fields. The URI's identity is its string canonicalization; the `%URI{}` struct's `:authority` field is a parser quirk masquerading as identity. The canonical helper strips this asymmetry.
- `feedback_subagent_must_load_project_skills` — the impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_review_every_pr` — codex review of this SPEC + the impl PR carries the verbatim "no mix" clause.
- `feedback_destructive_migration_anti_pattern` — see §4.1 / §9: persisted URI strings already round-trip via `URI.new/1` (strict, RFC 3986) through `Ezagent.Ecto.URI.load/1`, so DB serialization stays byte-identical. NO destructive DB migration is required by this SPEC.

**Parent / historical context:**
- `docs/notes/uri-design.md` §5 — the SPEC v3 URI shape rules. This SPEC adds a STRUCTURAL canonicalization rule to that file (§5.15 — to be appended in the impl PR).
- `apps/ezagent_core/lib/ezagent/uri.ex:124-143` — `Ezagent.URI.parse!/1` ALREADY exists and ALREADY uses strict `URI.new/1` under the hood. The remediation lifts this existing function from "the scheme-allowlist validator for strings entering the system" to "the only canonical `%URI{}` constructor for Ezagent-scheme URIs anywhere in the codebase". No new module is introduced.
- `apps/ezagent_core/lib/ezagent/capability.ex:320-348` — `Capability.instance_match?/2` for two concrete URIs ALREADY compares via `URI.to_string/1`. The matcher path is immune. The bug surfaces are call sites that do raw struct `==` BEFORE reaching the matcher (e.g. `EzagentDomainChat.grant_owner_orchestrator_admin_cap/3` `has_equiv?` check; `Behavior.Identity.check_grant_authorized` `caller == owner` short-circuit).
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` — the existing hand-rolled `URI.parse(URI.to_string(uri))` round-trip is a localized, undocumented version of the canonical-form rule THIS SPEC formalizes. The impl PR deletes the round-trip in favor of `Ezagent.URI.parse!/1`.
- `2026-05-27-capability-action-axis.md` — concurrent SPEC adding the `:action` field. Independent: `:action` is an atom axis, not a URI axis. The two interact only in `Capability.identity_key/1` (which already routes through `normalize_uri_for_key/1` = `URI.to_string`); §8 enumerates.
- `2026-05-27-workspace-cap-based-visibility.md` — concurrent SPEC on cap-based visibility. Independent on the URI axis: workspace visibility consumes `caller_uri` + caps, both of which become canonical after this SPEC lands. §8 enumerates.

---

## 1. Problem statement — the exact divergence

### 1.1 The divergence

```elixir
URI.parse("entity://user/system/admin")
# %URI{
#   scheme: "entity",
#   authority: "user",    <— legacy RFC 2396 field, set
#   host: "user",
#   path: "/system/admin",
#   userinfo: nil, port: nil, query: nil, fragment: nil
# }

URI.new!("entity://user/system/admin")
# %URI{
#   scheme: "entity",
#   authority: nil,       <— RFC 3986, omitted
#   host: "user",
#   path: "/system/admin",
#   userinfo: nil, port: nil, query: nil, fragment: nil
# }
```

Both `URI.to_string/1` to the SAME 8-byte sequence `entity://user/system/admin`. As `%URI{}` structs they are NOT `==`.

stdlib `URI.parse/1` is deprecated since Elixir 1.13 because it is non-strict (RFC 2396). It sets the legacy `:authority` field to the host portion. stdlib `URI.new/1` (and the `!` variant) is strict (RFC 3986) and leaves `:authority` nil — RFC 3986 deleted the field. The two constructors yield structurally-different `%URI{}` for the same input.

### 1.2 The failure path (Bug 2 wizard test)

`apps/ezagent_web/test/ezagent_web/live/home_live_test.exs:66` — `submitting the wizard creates the session and navigates to /sessions`:

1. The seed at `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29` constructs `@admin_uri URI.parse("entity://user/system/admin")` at COMPILE TIME — authority:"user".
2. The wizard's `EzagentWeb.LiveAuth.parse_entity_uri/1` (`apps/ezagent_web/lib/ezagent_web/live_auth.ex:339-353`) routes through `Ezagent.URI.parse!/1`, which uses strict `URI.new/1` — authority:nil.
3. The two `%URI{}` reach `EzagentDomainChat.create_session/3 → do_create_session/3 → finalize_session_create/3 → grant_owner_orchestrator_admin_cap/3`.
4. `grant_owner_orchestrator_admin_cap/3`'s `has_equiv?` check (`apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:570-572`) uses `cap.instance == want.instance` raw struct equality. The held cap (admin's existing baseline) and the wanted cap (freshly constructed) differ on `:authority`, so `has_equiv?` is `false`.
5. The grant proceeds to `Ezagent.Invocation.dispatch/1` → `Behavior.Identity.invoke(:grant_cap, ...)` → `check_grant_authorized/2`.
6. `check_grant_authorized/2`'s `caller == owner` short-circuit (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:654`) is raw struct equality. `caller` is the wizard's `URI.new!`-built URI; `owner` is the `URI.parse`-built `@admin_uri` (via `Ezagent.CapabilityRegistry.data_owner_of/2`). They differ on `:authority`. The cond falls through to `{:error, :grant_not_owner}`.
7. `finalize_session_create/3` receives `{:error, {:orchestrator_admin_cap_grant_failed, :grant_not_owner}}`, the test fails.

The hand-rolled `URI.parse(URI.to_string(uri))` round-trip at `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307` patches the SAME bug for the `Session.spawn_from_template/2` path but NOT for the direct `EzagentDomainChat.create_session/3` path. Two patches needed, one applied — the parity drift IS the bug.

### 1.3 The bug class

Raw `==` of `%URI{}` structs anywhere in the codebase where producers may use different constructors is silently denial-of-authority. The matcher (`Capability.instance_match?/2`) was hardened (line 347: `URI.to_string(held) == URI.to_string(needed)`). The non-matcher comparison surfaces — equivalence checks, owner-shortcut comparisons, MapSet keys built from raw structs, `List.member?/2` membership checks — are not.

The codebase is 226 production `URI.parse/1` sites + 79 `URI.new!/1` sites. Without a structural rule, every future PR that adds a new URI-producing site is a potential reintroduction of this bug class.

---

## 2. Decision

**Option D — single canonical constructor at the boundary.** Adopted.

`Ezagent.URI.parse!/1` (already in `apps/ezagent_core/lib/ezagent/uri.ex:124-143`, already wraps strict `URI.new/1`) becomes THE constructor for any `%URI{}` whose scheme is in the SchemeRegistry allowlist. All production code routes URI-from-string through `Ezagent.URI.parse!/1`. Direct stdlib `URI.parse/1` is deleted from production code. Direct stdlib `URI.new!/1` is deleted from production code EXCEPT for constructing the `?action=...` query-bearing form (a stylistic carve-out, see §3.4).

Why D over A/B/C:

- **A (migrate everything to `URI.new!/1`)** is half the solution. It fixes the AUTHORITY divergence but doesn't establish a chokepoint for SchemeRegistry validation. Plugin authors writing a new Behavior would still need to remember to use `URI.new!` (not `URI.parse`). The bug class returns the moment one site reverts.
- **B (migrate everything to `URI.parse/1`)** preserves the non-strict authority quirk forever. Future Elixir versions may delete the deprecated `URI.parse/1` (deprecated since 1.13). Contradicts RFC 3986 alignment. Rejected.
- **C (use `URI.to_string/1` for every comparison)** is a workaround — `feedback_let_it_crash_no_workarounds` rules it out explicitly. Forces every comparison site to know "URIs are special". Doesn't compose with MapSet/struct-keyed maps. The matcher fix at `instance_match?/2` is the precedent — but generalizing it to every comparison surface is the wrong direction. Fix the producer, not the consumer.
- **D (canonical helper)** locks the producer side. Every `%URI{}` for an Ezagent-scheme URI is constructed via the single chokepoint. Plugin authors don't think about it. The comparison surfaces (raw `==`, MapSet, List.member) get correct semantics for free because both halves are now identically-shaped.

The chokepoint already exists. The SPEC is to LIFT it (formalize the rule, sweep producers, add the invariant test) rather than INTRODUCE it.

---

## 3. Semantics — canonical URI rule

### 3.1 The rule (one sentence)

**For any URI whose scheme is in `Ezagent.URI.SchemeRegistry` (i.e. an Ezagent-domain URI), the canonical `%URI{}` in-memory representation is the one returned by `Ezagent.URI.parse!(string)`. No code path may construct an Ezagent-scheme `%URI{}` by any other route.**

### 3.2 What "canonical" guarantees

Given two `%URI{}` values `a` and `b` produced via `Ezagent.URI.parse!/1` on inputs that `URI.to_string/1` to the same string:

1. **Struct equality:** `a == b` is `true`.
2. **Pattern match:** `%URI{scheme: s, host: h, path: p} = a` and `%URI{scheme: s, host: h, path: p} = b` bind identical `s/h/p`.
3. **`:authority` field:** `a.authority == b.authority == nil` (RFC 3986).
4. **Round-trip:** `URI.to_string(Ezagent.URI.parse!(URI.to_string(a))) == URI.to_string(a)`.
5. **DB round-trip:** `Ezagent.Ecto.URI.load(Ezagent.Ecto.URI.dump(a) |> elem(1)) == {:ok, a}` (already true today because `load/1` uses `URI.new/1`).

(1) is the load-bearing guarantee. (2)–(5) are derivatives.

### 3.3 Who calls `Ezagent.URI.parse!/1`

THE boundary surfaces — these are the FIVE input boundaries where strings enter:

**B1. CLI input.** `apps/ezagent_cli/lib/ezagent_cli/{exec,dispatch,tree_builder,coercion}.ex` already parse strings to URIs; the SPEC sweep replaces every `URI.parse/1` / `URI.new/1` / `URI.new!/1` here with `Ezagent.URI.parse!/1`.

**B2. HTTP / Phoenix params.** `apps/ezagent_web/lib/ezagent_web/live_auth.ex:341` already calls `Ezagent.URI.parse!/1`. The pattern: every `parse_*_uri` helper in `apps/ezagent_plugin_liveview/lib/*_live.ex` (16 files — `case URI.new(decoded)` etc) routes through `Ezagent.URI.parse!/1`.

**B3. DB load.** `Ezagent.Ecto.URI.load/1` (`apps/ezagent_core/lib/ezagent/ecto/uri_type.ex:43-48`) uses `URI.new/1` today. Migrated to `Ezagent.URI.parse!/1` for Ezagent-scheme strings; non-Ezagent schemes (e.g. external `http://feishu.cn`) fall through to plain `URI.new/1` (since SchemeRegistry rejects them and `parse!/1` would raise). See §3.7 for the dual-fallback contract.

**B4. Snapshot reload.** `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:160` (`URI.new`), `:361` (`URI.parse`), `:159-164` (`URI.new` in `reconcile_after_load_behaviors`). All migrate to `Ezagent.URI.parse!/1`. Failure (raise) bubbles to the supervisor; let-it-crash per `feedback_let_it_crash_no_workarounds`.

**B5. External plugin payloads.** Feishu mention parser, MCP socket auth payload, etc. — `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/mention_parser.ex:77`, `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/socket.ex:24`, `apps/ezagent_domain_chat/lib/ezagent/orchestrator/mcp_socket.ex:51`. These do `URI.new/1` today (with case-pattern error handling). Migrate to `Ezagent.URI.parse!/1` wrapped in try/rescue at the boundary (so a malformed inbound payload produces a graceful `{:error, _}` to the external surface, NOT a process crash — Invariant #9 "no silent drops at user-facing surfaces").

### 3.4 Constructing query-bearing dispatch targets

The codebase pattern `URI.new!("#{URI.to_string(uri)}?action=behavior.action")` (89 production sites) builds an action-bearing URI from a canonical instance URI. Two equivalent forms:

- **A:** `URI.new!("#{URI.to_string(uri)}?action=#{behavior}.#{action}")`
- **B:** `Ezagent.URI.parse!("#{URI.to_string(uri)}?action=#{behavior}.#{action}")`

Both yield `:authority == nil`. B additionally re-validates the scheme via SchemeRegistry. The SPEC mandates B at production sites (89 sweep targets). Test fixtures and mix tasks may use either. The carve-out for `URI.new!/1` is style: this is the ONLY case where stdlib `URI.new!/1` is permitted in production, and only because `URI.to_string(uri)` is by construction a canonical-form string (the input `uri` came from `parse!/1`).

To eliminate the carve-out entirely and re-route through `parse!/1` everywhere: a future PR can introduce `Ezagent.URI.with_action(uri, behavior, action)` helper that performs the concatenation + parse in one call. Out of scope here; flagged §10 OQ-2.

### 3.5 Compile-time constants

Module attributes like `@admin_uri` (`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29`) need a compile-time-callable form. `Ezagent.URI.parse!/1` calls `Ezagent.URI.SchemeRegistry.registered?/1` which reads ETS — ETS isn't available during module compilation. Two routes:

- **Route 1:** Use `URI.new!/1` at compile time (the strict canonical form, since SchemeRegistry validation isn't needed for a hard-coded constant). Mark the attribute with a comment referencing this SPEC.
- **Route 2:** Defer to a `Macro.escape`-bypassing function call evaluated at runtime via `Application.compile_env` + a startup hook.

Route 1 is the pragmatic answer. The carve-out is: COMPILE-TIME module attributes that hold a hard-coded URI MAY use `URI.new!/1`. The compile-time use does NOT bypass canonical form (it's equivalent to `parse!/1` for that input modulo the SchemeRegistry check, which is unnecessary for a known-good constant). The invariant test (§5) catches `@constant URI.parse(...)` but allows `@constant URI.new!(...)`.

Affected constants enumerated in §4.

### 3.6 Producers inside dispatch (`Invocation`, etc.)

`Ezagent.URI.instance/1` returns a `%URI{}` derived from a canonical input (the dispatch target). It produces `:authority == nil` because the input is canonical. No change required to `instance/1` itself — its output is canonical because its input is.

`Capability.workspace_of/1` constructs a new `%URI{}` via `URI.new!("workspace://" <> workspace_name)` (line 592). This is canonical-by-construction (`URI.new!/1` is strict, and SchemeRegistry doesn't need re-validation for a structural derivation). Keeps `URI.new!/1` per the §3.4 carve-out.

`Ezagent.URI.entity_workspace_uri/1` (line 305) uses `URI.new!/1`. Canonical-by-construction. No change.

### 3.7 Non-Ezagent-scheme URIs

External URIs (Feishu webhook, http URLs) are NOT Ezagent-scheme. They route through plain stdlib `URI.new/1` (or `URI.parse/1` in legacy plugin code). `Ezagent.URI.parse!/1` would raise on them (SchemeRegistry rejection).

The SPEC scope is Ezagent-scheme URIs (6 schemes: `entity, workspace, session, template, resource, system` — `Ezagent.URI.SchemeRegistry` allowlist). For non-Ezagent URIs, `URI.new/1` strict is the default; the helper carve-out at `Ezagent.Ecto.URI.load/1` (§3.3 B3) makes the dual-fallback explicit:

```elixir
# in Ezagent.Ecto.URI.load/1
def load(s) when is_binary(s) do
  try do
    {:ok, Ezagent.URI.parse!(s)}
  rescue
    ArgumentError -> URI.new(s)  # external scheme — strict but no allowlist
  end
end
```

(The exact implementation is in the impl PR; this SPEC fixes the contract: Ezagent-scheme → canonical via `parse!/1`; everything else → strict via `URI.new/1`.)

### 3.8 What stays raw `URI.parse/1`

ONLY documentation / comments / inspect / module-level docstrings illustrating the deprecated form for didactic purposes (the comments at `apps/ezagent_core/lib/ezagent/capability.ex:325-332` are an example — they explain the bug for future readers). The invariant test (§5) excludes `.md` files and lines inside comments / `@moduledoc` strings.

---

## 4. Migration plan

### 4.1 Phase order

PR-1 (this SPEC): no code. SPEC merged for codex adversarial-review.

PR-2: deletion-and-sweep, one production app at a time. Order:

1. `apps/ezagent_core/` — base. Fixes `Ezagent.Ecto.URI.load/1`, `Kind.Snapshot.*`, `Capability.parse_granter/1`, `Capability.string_to_uri_or_any/1`, `Capability.decode_uri_or_any_strict!/2`, `WorkspaceRegistry.lookup/1`, `Persistence.workspace_uri_for/1`, `Audit.*`, `NotificationSubscriptions.*`, `AgentLineage.*`, `Notifications.*`, `Presence.*`, `Routing.Resolver.*` (already partially uses `parse!/1`), `SystemPrincipal.parse!/1`, `CapabilityRegistry.bootstrap`. 33 production call sites.
2. `apps/ezagent_domain_identity/` — fixes `@admin_uri`, `@system_bootstrap_uri` constants (§3.5 Route 1: `URI.new!`), `Identity.parse_uri/1`, `Entity_presenter.*`. 8 call sites.
3. `apps/ezagent_domain_chat/` — fixes `Session.spawn_from_template/2` round-trip at 303-307 (DELETE the hand-roll; rely on caller-side canonicality from `parse!/1`), all 89 query-target sites, `read_marker`, `mcp_registry`, `mcp_socket`, `orchestrator/tools`, `template/generic_session`, `entity/agent_template`, `entity/session_template`, `entity/agent`, `entity/session`, `behavior/chat`, `behavior/template`. 89 call sites total (most are §3.4 query-target form — keep `URI.new!/1` or move to `parse!/1` per the helper choice).
4. `apps/ezagent_domain_workspace/` — fixes `behavior/workspace`. 6 call sites.
5. `apps/ezagent_domain_agent_bridge/` — fixes `registry`, `token_store`. 4 call sites.
6. `apps/ezagent_domain_python/` — already uses `Ezagent.URI.parse!/1`. 0 changes.
7. `apps/ezagent_domain_external_mirror/` — already uses canonical patterns. 0 prod changes.
8. `apps/ezagent_domain_ui/` — fixes `primitives.ex`. 1 call site.
9. `apps/ezagent_web/` — fixes `home_live`, `api_v1_controller`, `workspace_switch_controller`. 3 call sites (mostly already `URI.new!/1` query-target form).
10. `apps/ezagent_cli/` — fixes `exec`, `dispatch`, `tree_builder`, `coercion`. 7 call sites.
11. `apps/ezagent_plugin_*/` — sweep all plugins. ~30 call sites across cc / curl_agent / echo / feishu / liveview / np.

PR-3: invariant test (§5). Lands in the same PR as the final sweep OR a follow-up.

PR-4: append `docs/notes/uri-design.md` §5.15 (canonical-form rule formalization).

**No DB migration.** Persisted strings round-trip byte-identically through `URI.to_string/1` regardless of constructor. The bug is in-memory only.

### 4.2 The DELETE-don't-keep contract

Per `feedback_let_it_crash_no_workarounds`: every `URI.parse/1` and `URI.new!/1` call site in production lib/ is REPLACED, not kept-alongside. No `if Application.get_env(:legacy_uri_parse, false), do: ...`. No transitional shim. The sweep is the entirety of the change.

### 4.3 Compile-time constant migration

Specific changes to compile-time module attributes:

- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:29` — `@admin_uri URI.parse("entity://user/system/admin")` → `@admin_uri URI.new!("entity://user/system/admin")`. Per §3.5 Route 1.
- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:30` — `@system_bootstrap_uri URI.parse("system://bootstrap/default")` → `URI.new!(...)`.
- `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:98` — `@bootstrap_granted_by URI.parse("system://bootstrap/default")` → `URI.new!(...)`.
- `apps/ezagent_core/lib/ezagent/entity/system.ex:47` — `URI.parse("system://routing/default")` (inside `def routing_default_uri`) → `URI.new!(...)` (runtime fn but no SchemeRegistry need since the scheme is structurally known).

### 4.4 Test fixture migration

Test files (`test/**/*.exs`) MAY use `URI.parse/1` or `URI.new!/1` freely — the bug class is in PRODUCTION code where producer and consumer disagree. Tests construct both halves themselves and may use either as long as they're consistent within a test. The invariant test (§5) ONLY scans `apps/*/lib/`, not `test/`.

OPTIONAL follow-up sweep: standardize tests on `URI.new!/1`. Out of scope for this SPEC.

### 4.5 Already-correct sites (no change)

- `apps/ezagent_core/lib/ezagent/uri.ex` — the canonical helper itself.
- `apps/ezagent_core/lib/ezagent/routing/resolver.ex:353, 388` — already use `Ezagent.URI.parse!/1`.
- `apps/ezagent_domain_python/lib/ezagent/domain/python.ex:56` — already uses `Ezagent.URI.parse!/1`.
- `apps/ezagent_domain_external_mirror/lib/mix/tasks/ezagent_external_mirror_cli.ex:45` — comment references the canonical form, code already aligned.
- `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.{user,agent,workspace}.*.ex` — already use `Ezagent.URI.parse!/1`.
- `apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_user_admin.ex:204` — already uses `Ezagent.URI.parse!/1`.
- `apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex:246` — already uses `Ezagent.URI.parse!/1`.

---

## 5. Invariant test

**File:** `apps/ezagent_core/test/invariants/uri_canonicalization_test.exs` (new).

**Purpose:** Catch a future contributor who introduces `URI.parse/1` or stdlib `URI.new!/1` at an Ezagent-scheme boundary in production code.

**Structure** — three orthogonal assertions:

### 5.1 No `URI.parse/1` in production lib/

```elixir
test "no stdlib URI.parse/1 calls in apps/*/lib (excluding comments)" do
  lib_files = Path.wildcard("apps/*/lib/**/*.ex")

  violations =
    for path <- lib_files,
        {line, lineno} <- Enum.with_index(File.stream!(path), 1),
        line_is_call_to_uri_parse?(line),
        not in_comment_or_docstring?(line),
        path != "apps/ezagent_core/lib/ezagent/uri.ex" do
      {path, lineno, String.trim(line)}
    end

  assert violations == [], format_violations(violations)
end
```

The helper `line_is_call_to_uri_parse?/1` matches `~r/\bURI\.parse\(/` (word boundary, no leading `Ezagent.`, no leading `String.` etc). `in_comment_or_docstring?/1` is a heuristic on `~r/^\s*#/` plus `~S(""")` triple-quote stripping.

Sole allowlisted file: `apps/ezagent_core/lib/ezagent/uri.ex` (itself, since `parse!/1` internally calls `URI.new/1`; no `URI.parse/1`).

### 5.2 No bare stdlib `URI.new!/1` in production lib/ EXCEPT the §3.4 carve-out

```elixir
test "no stdlib URI.new!/1 in apps/*/lib outside query-target idiom + compile-time constants" do
  violations =
    for path <- lib_files,
        {line, lineno} <- Enum.with_index(File.stream!(path), 1),
        matches_uri_new_bang?(line),
        not is_query_target_idiom?(line),
        not is_module_attribute?(line),
        not in_comment_or_docstring?(line) do
      {path, lineno, String.trim(line)}
    end
  assert violations == [], ...
end
```

`is_query_target_idiom?/1` matches `~r/URI\.new!\(.*\?action=/` (line includes both `URI.new!(` and `?action=`). `is_module_attribute?/1` matches `~r/^\s*@\w+\s+URI\.new!\(/`. These are the two carve-outs from §3.4 + §3.5.

### 5.3 Round-trip property

```elixir
test "canonical URI round-trips through to_string/parse! unchanged" do
  cases = [
    "entity://user/system/admin",
    "entity://agent/team-alpha/cc_demo",
    "session://default/system/main",
    "session://template-x/team-alpha/main?action=chat.send",
    "template://agent/system/cc-orchestrator",
    "template://session/team-alpha/code@abc123",
    "resource://uploads/team-alpha/file-abc",
    "workspace://team-alpha",
    "workspace://system",
    "system://bootstrap/default",
    "system://routing/default"
  ]

  for s <- cases do
    a = Ezagent.URI.parse!(s)
    b = Ezagent.URI.parse!(URI.to_string(a))
    assert a == b, "round-trip diverged for #{s}"
    assert a.authority == nil, "expected authority:nil for #{s}, got #{inspect(a.authority)}"
    assert URI.to_string(a) == s, "to_string non-idempotent for #{s}"
  end
end
```

### 5.4 Parity test for the specific Bug 2 surface

```elixir
test "admin_uri produced any-which-way is canonical-equal" do
  from_constant = Ezagent.Entity.User.admin_uri()
  from_parse = Ezagent.URI.parse!("entity://user/system/admin")
  from_string_via_ecto =
    {:ok, uri} = Ezagent.Ecto.URI.load("entity://user/system/admin")
    uri

  assert from_constant == from_parse
  assert from_constant == from_string_via_ecto
  assert from_constant.authority == nil
end
```

This is the test that would have CAUGHT Bug 2 before the wizard test reproduced it. Pinning it as an invariant prevents reintroduction.

### 5.5 Why these four together pass the `feedback_completion_requires_invariant_test` gate

§5.1 + §5.2 + §5.3 + §5.4 each catch a different reintroduction shape:

- §5.1 catches a contributor copy-pasting `URI.parse(...)` from old code or stdlib docs.
- §5.2 catches a contributor using `URI.new!/1` outside the carve-out (e.g. `URI.new!("entity://user/system/admin")` at a runtime call site in lib/).
- §5.3 catches a contributor breaking `parse!/1`'s round-trip invariant (e.g. by adding a transformation that changes the struct shape).
- §5.4 catches the SPECIFIC Bug-2 admin_uri parity surface, the regression case for THIS bug.

A partial migration where 95% of sites use canonical but 1 boundary skipped is caught by §5.1 OR §5.2 (whichever construction shape the skipped site used). The invariant test is grep-based and exhaustive over `apps/*/lib/**/*.ex`.

---

## 6. Plugin isolation analysis

### 6.1 What plugin authors see today

A plugin author writing a new Behavior in `apps/ezagent_plugin_<x>/` constructs URIs in three contexts:

1. **Slice initialization** — building a `%URI{}` for use in slice state (e.g. a session URI to chat into).
2. **Dispatch target construction** — building `URI.new!("#{URI.to_string(target)}?action=...")` to invoke another Behavior.
3. **External payload deserialization** — parsing a string from an inbound webhook/MCP/etc. payload into a URI.

The two URI surfaces a plugin author has to know about are: (a) the `?action=` query-target idiom (§3.4), and (b) the external-payload parser (§3.7 fallback contract). Under SPEC: (a) uses `Ezagent.URI.parse!/1` or `URI.new!/1` (both yield canonical); (b) uses `Ezagent.URI.parse!/1` wrapped in try/rescue.

The plugin author does NOT need to know:
- That `URI.parse/1` exists (it's deleted from production code).
- That `URI.parse/1` and `URI.new!/1` produce structurally different structs.
- That `:authority` is a field.

The skill `ezagent-developer/anti-patterns.md` gains a new entry: "Do not use stdlib `URI.parse/1` in lib/. Use `Ezagent.URI.parse!/1` for all Ezagent-scheme URIs. The invariant test in `apps/ezagent_core/test/invariants/uri_canonicalization_test.exs` enforces this."

### 6.2 The chokepoint stays in core

`Ezagent.URI.parse!/1` lives in `apps/ezagent_core/` (the core tier). No plugin owns canonicalization logic. No plugin contributes scheme-specific canonicalization. The single function answers "give me a canonical %URI{} from this string" for the entire codebase. This satisfies `feedback_north_star_plugin_isolation` — plugin authors call the function, get the result, move on.

### 6.3 Future-proofing for new schemes

When a plugin registers a new scheme via `Ezagent.SpawnRegistry.register/2` (which co-registers in `SchemeRegistry`), `Ezagent.URI.parse!/1` automatically accepts the new scheme — no `parse!/1` change required. The scheme appears in the allowlist; downstream canonical-form rules apply uniformly.

---

## 7. Trade-offs / alternatives considered

### 7.1 Option A — migrate all to `URI.new!/1`

**Pro:** Simple. Pure-stdlib. No `Ezagent.URI` dependency.
**Con:** No SchemeRegistry chokepoint. Plugin authors must remember "use `URI.new!`, not `URI.parse`". Bug class returns the moment one site reverts. Doesn't establish the structural invariant — "Ezagent-scheme URIs flow through Ezagent.URI.parse!/1".
**Rejected.**

### 7.2 Option B — migrate all to `URI.parse/1`

**Pro:** Preserves the existing `:authority == "user"` form everywhere. Zero behavior change in the matcher (which is already to_string-based, so it doesn't care anyway).
**Con:** `URI.parse/1` is deprecated since Elixir 1.13. Future Elixir versions may delete it. Contradicts RFC 3986. The `:authority` field is a parser quirk masquerading as identity. Locks the codebase to a deprecated API. Rejected by `feedback_uuid_is_canonical_identifier`'s spirit (canonical identifier should not include mutable display fields).
**Rejected.**

### 7.3 Option C — compare via `URI.to_string/1`

**Pro:** Localized fix per comparison surface. The matcher fix (`instance_match?/2`) is precedent.
**Con:** Violates `feedback_let_it_crash_no_workarounds`. Forces every comparison surface to "know URIs are special". Doesn't work for MapSet/struct-keyed maps without `:custom_hash`. Doesn't work for List.member?. Doesn't work for `caller == owner` (pattern guard). Leaks the abstraction.
**Rejected.**

### 7.4 Option D — canonical helper (CHOSEN)

**Pro:** Single chokepoint. Plugin-isolated. Backwards-compatible with existing matcher fix (the matcher remains correct; raw struct `==` ALSO becomes correct because both sides are canonical). Aligns with RFC 3986. Test-enforced via §5.
**Con:** Migration touches ~226 production sites. The §3.4 / §3.5 carve-outs for `URI.new!/1` introduce two "ok" forms in production (the helper and the carve-outs). Reading the invariant test requires understanding why `URI.new!/1` is sometimes allowed.
**Net:** Pros outweigh cons. The carve-outs are precisely formalized in the invariant test (§5.2), so the contributor decision tree stays mechanical.

### 7.5 Sub-option D' — introduce `Ezagent.URI.canonical/1` for `%URI{}` → `%URI{}`

A normalize-from-struct variant: takes ANY `%URI{}` (parse-built or new-built) and returns the canonical form via `URI.to_string/1` round-trip. Useful at INTERNAL boundaries where the producer is uncontrolled (e.g. third-party library returns a URI; we want to canonicalize before storing).

The SPEC chooses NOT to introduce this, because:
1. No production site currently has this need — every site that handles a `%URI{}` either constructed it locally (and can be made to use `parse!/1`) or received it from upstream Ezagent code (which is itself canonical post-SPEC).
2. Adding `canonical/1` creates a second helper that does almost the same thing as `parse!/1`. Two helpers invite drift.
3. If the need emerges (e.g. a new external library returns URIs), the helper can be added in a follow-up. Out of scope. Flagged §10 OQ-1.

---

## 8. Interaction with concurrent SPECs

### 8.1 `2026-05-27-capability-action-axis.md` (#410)

That SPEC adds an `:action` atom field to `%Capability{}`. Independent of this SPEC. The capability's URI fields (`instance`, `workspace_uri`, `granted_by`) are governed by THIS SPEC's canonical-form rule. `Capability.identity_key/1` already routes URIs through `URI.to_string/1` (line 928) — that path is immune to the bug class and remains immune after this SPEC.

The action axis itself is an atom — no URI canonicalization concern. No interaction at code level. Documents stay independent.

### 8.2 `2026-05-27-workspace-cap-based-visibility.md` (#423)

That SPEC introduces `list_workspaces_for(caller_uri, caps)`. The two arguments are URIs. Under THIS SPEC's canonicalization rule, both arguments are canonical (caller_uri came from `live_auth.ex` → `parse!/1`; caps' `workspace_uri` came from `Capability.from_map/1` → post-SPEC routes through `parse!/1`). String-equality comparison (the workspace SPEC §3.3 (a) clause) holds correctly because both halves are canonical.

The workspace SPEC's `member_of_workspaces/1` compares `members` list URIs to `caller_uri` via string-equality. The `members` list strings come from `Workspace.Store.list_all/0` which returns the persisted JSON column. Under `feedback_register_lookup_key_parity`, both halves must canonicalize through the same parser — under THIS SPEC, they do (both go through `parse!/1` at their respective boundaries).

No code-level conflict. The two SPECs are orthogonal layers.

### 8.3 Forward compatibility

Any future SPEC introducing a new URI-shape constraint (e.g. URN sub-resources, multi-tenancy axis additions) layers on top of canonical-form. The canonical-form rule is the foundation; downstream rules consume canonical URIs.

---

## 9. Backwards compatibility / external API

### 9.1 Persisted data

DB rows in `kind_snapshots`, `users.caps_json`, `messages.sender`, `routing_rules`, `template_tags`, `workspaces.member_uris` — all store URI strings (via `Ezagent.Ecto.URI.dump/1` = `URI.to_string/1`). The string form is byte-identical whether the in-memory struct was `URI.parse`-built or `URI.new!`-built. **No DB migration required.**

The on-disk format does NOT change. The in-memory `%URI{}` shape DOES change (`:authority` always nil for Ezagent-scheme URIs post-SPEC). Snapshot reload paths (which `binary_to_term` a struct from disk) produce canonical structs because the encode side wrote canonical structs.

### 9.2 `:erlang.binary_to_term/2` on old serialized %URI{}

If a `kind_snapshots` row was written BEFORE this SPEC's migration with a `URI.parse`-built `%URI{}` baked into the snapshot binary, replaying that row post-SPEC reproduces the OLD struct (with `:authority == "user"`). This is the cross-version snapshot risk.

`apps/ezagent_core/lib/ezagent/kind/snapshot.ex:36` uses `:erlang.binary_to_term(binary, [:safe])`. The `:safe` flag rejects unknown atoms but does NOT canonicalize URI structs.

**Mitigation:** `Kind.Snapshot.reconcile_after_load_behaviors/3` (line 159) is the post-load reconcile hook. The impl PR adds a SLICE-level canonicalization pass: walk the decoded state, replace any `%URI{authority: a}` with `a != nil` AND `scheme ∈ SchemeRegistry` by `Ezagent.URI.parse!(URI.to_string(uri))`. The hook fires AFTER decode but BEFORE the matcher / dispatch sees the state, so old snapshots become canonical on load.

This is a one-time-per-process cost on first reload. No on-disk migration; the snapshot is rewritten on next slice-change anyway (snapshots use `{:snapshot, :on_change}` cadence, so a few minutes of operation re-writes all hot Kinds).

**Codex question for review (§11):** is this reconcile-on-load step sufficient, or do we need a forced "rewrite all snapshots" mix task at deploy time? §11 Q4.

### 9.3 Operator-facing URIs

Scripts (`scripts/*.sh`), docs (`docs/**/*.md`), scenarios (`scenarios/*.yaml`), mix-task help text — all reference URI STRINGS, not struct form. No change.

CLI commands accept URI strings — `Ezagent.URI.parse!/1` is the boundary. Already aligned.

### 9.4 External plugin payloads (Feishu, MCP)

Feishu webhook events deliver bare strings (chat_id, user_id) which are translated to URIs in the plugin. The Feishu `mention_parser.ex` and binding policy already wrap inbound parses in case/rescue (graceful degradation per Invariant #9). Migration to `parse!/1` retains the wrap. Operator-facing semantics unchanged.

### 9.5 API v1 controller

`apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex:201` constructs `URI.new!("#{...}?action=...")` — query-target idiom (§3.4 carve-out). Stays as `URI.new!/1` post-SPEC.

---

## 10. Open questions for Allen

**OQ-1.** §7.5 — should we introduce `Ezagent.URI.canonical/1` (struct → canonical-struct normalizer) NOW or defer? Current call: defer until a concrete need surfaces. Reconsider in 1-2 release cycles.

**OQ-2.** §3.4 — should we introduce `Ezagent.URI.with_action(uri, behavior, action)` to eliminate the `URI.new!/1` carve-out entirely? Current call: defer. The 89 query-target sites are mechanical to migrate; introducing a helper now adds API surface for marginal benefit.

**OQ-3.** §5.1 — the invariant test relies on a `~r/\bURI\.parse\(/` regex over .ex files. Is the comment-detection heuristic robust enough? Alternatives:
  - (a) Use `Code.string_to_quoted/1` and walk the AST, catching `{:., _, [URI, :parse]}` nodes. Robust but slow.
  - (b) Use `mix dialyzer` with a custom check. Heavyweight setup.
  - (c) Keep the regex; accept rare false-positives that contributors can `# uri-canonical-allow` comment-suppress.

  Current call: (c) with an `# uri-canonical-allow` suppression comment. Robust enough; matches the codebase style for other invariant tests (e.g. `dispatch_uses_required_caps` uses a similar grep).

**OQ-4.** §9.2 — reconcile-on-load OR forced snapshot rewrite? Current call: reconcile-on-load is sufficient. Snapshots naturally rewrite on slice-change; cold Kinds with no traffic carry old shape briefly but are canonicalized as soon as reloaded. Codex will likely challenge this; flagged §11 Q4.

**OQ-5.** §4.4 — should the test fixture sweep be in-scope? Current call: NO (separate follow-up). The bug is production-only; tests construct both halves.

---

## 11. Codex adversarial review questions

When dispatching `codex:codex-rescue` for adversarial review, ask explicitly:

**Q1 (root cause).** Is Option D actually solving the root cause, or shifting it? Specifically: by making `URI.new!/1` permitted in two carve-outs (§3.4 query-target, §3.5 compile-time constants), do we preserve a smaller-but-similar bug class where a contributor uses `URI.new!/1` outside the carve-out and we don't catch it? (Expected answer: §5.2 catches it via regex; manually verify the regex with three adversarial examples.)

**Q2 (enumeration completeness).** Has the SPEC enumerated ALL `URI.parse/1` and `URI.new!/1` production call sites? Codex should grep the repo against the SPEC's §4.1 phase-order list and find any missed sites. Specifically check `apps/ezagent_domain_external_mirror/` and `apps/ezagent_plugin_*/` which the SPEC sketches with "~30 sites" rather than enumerating.

**Q3 (invariant test).** Does the §5 invariant test catch a partial migration where 95% of sites use canonical but 1 boundary skipped? Specifically:
  - If a contributor adds `URI.parse("entity://...")` to `apps/ezagent_plugin_feishu/lib/foo.ex`, does §5.1 catch it? (Expected yes.)
  - If a contributor adds `URI.new!("entity://user/system/admin")` to `apps/ezagent_domain_chat/lib/bar.ex` (NOT in `?action=` form, NOT a module attribute), does §5.2 catch it? (Expected yes.)
  - If a contributor adds `URI.new("entity://...")` (NOTE: non-bang variant, returns `{:ok, _}`), does any §5 test catch it? (Expected NO — this is a gap. Codex should flag.)

**Q4 (snapshot cross-version).** §9.2 describes a reconcile-on-load step in `Kind.Snapshot.reconcile_after_load_behaviors/3` that canonicalizes any pre-SPEC `%URI{}` in slice state. Is this sufficient? Specifically:
  - If a Kind has been live for weeks without slice-change (cold-but-alive), its in-process state still has pre-SPEC URIs. Does this matter? (The Kind constructs needed-caps via `Ezagent.URI.instance/1` whose output is canonical — so it only matters for state-state comparisons within the slice. Enumerate which Behaviors do state-state URI `==` comparisons.)
  - Does `:erlang.binary_to_term` on a serialized `%URI{}` from a different Elixir version preserve the `:authority` field? (Cross-OTP risk. Codex should verify.)

**Q5 (`URI.to_string` byte parity).** §9.1 asserts that `URI.to_string/1` produces byte-identical output for `URI.parse`-built and `URI.new!`-built structs of the same canonical string. Verify:
  - For `entity://user/system/admin`: both forms `to_string` to `"entity://user/system/admin"`. (Spot-checked manually — confirm.)
  - Edge case: URIs with embedded `?action=...` query — `URI.to_string` may sort or re-encode the query. Verify byte-identical for our action-bearing URIs.
  - Edge case: URIs with `%`-encoded path segments (e.g. `template://session/team-alpha/code%20review`). Confirm byte-identical.
  - **If any URI form serializes to a DIFFERENT string between the two constructors, this SPEC's "no DB migration" assertion fails, and the impl PR needs a forced snapshot/DB rewrite step.**

**Q6 (concurrent SPECs).** §8 asserts independence from cap-action-axis (#410) and workspace-cap-visibility (#423). Verify: are there shared code paths where the three SPECs' changes overlap and the merge order matters?

**Q7 (plugin contract).** §6 claims plugin authors don't need to know about the URI quirk. Verify by reading `references/how-to-recipes.md` in the `ezagent-developer` skill: would a contributor following the "add a new Behavior" recipe naturally write canonical code, or do they need an explicit instruction in the recipe? If the latter, the SPEC should update the skill in the impl PR.

**Q8 (let-it-crash compliance).** §3.3 B5 has the external-payload parse wrap `Ezagent.URI.parse!/1` in try/rescue → `{:error, _}`. Is this a let-it-crash violation? (Defense: per Invariant #9 "no silent drops at user-facing surfaces", inbound transports MUST translate malformed input to a user-visible error reaction. The rescue is the structural translation, not a workaround.)

Verbatim subagent constraint: **"Do NOT run mix test, mix compile, mix deps.get, or any mix command. Static analysis only."**

---

## 12. Rollback plan

If the impl PR lands and causes production regression:

**Step 1.** Revert the impl PR. Persisted data is byte-identical (§9.1), so reverting the in-memory struct shape doesn't strand any DB rows. The matcher (`instance_match?/2` line 347) already does to_string comparison — fine either way.

**Step 2.** Restore the hand-rolled round-trip at `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:303-307`. Bug 2 returns.

**Step 3.** Delete the invariant test temporarily. The codebase regresses to its pre-SPEC state.

**Step 4.** File a follow-up issue with the regression reproduction. Re-spec.

**Acceptance:** The revert is mechanical (single git revert + delete invariant test file). No data migration to undo. No external API change to coordinate with operators.

**Verification of safe rollback:** the impl PR's pre-merge CI run includes `mix test` (the existing Bug 2 test reproduction — `home_live_test.exs:66` — passes post-SPEC, would FAIL post-revert). The CI signal is therefore a structural rollback indicator.

---

## Appendix A — call site enumeration (production lib/, total ~226)

(Codex Q2 challenge target — verify exhaustiveness.)

### `apps/ezagent_core/lib/`

- `ezagent/uri.ex:305` — `URI.new!` inside `entity_workspace_uri` (canonical-by-construction, OK).
- `ezagent/system_principal.ex:110, 169` — `URI.parse("system://..." <> _)` → migrate to `parse!/1`.
- `ezagent/workspace_registry.ex:108` — `URI.parse(w)` lookup result → migrate to `parse!/1`.
- `ezagent/capability_registry.ex:429` — `URI.parse("system://bootstrap/pr-own-1")` → migrate to `parse!/1` (or `URI.new!/1` per §3.5 if compile-time-constant).
- `ezagent/presence.ex:135` — `URI.parse(s)` → migrate to `parse!/1`.
- `ezagent/audit.ex:393` — `URI.parse(s)` → migrate to `parse!/1`.
- `ezagent/notification_subscriptions.ex:488` — `URI.parse(s)` → migrate to `parse!/1`.
- `ezagent/persistence.ex:101` — `URI.parse(uri)` → migrate to `parse!/1`.
- `ezagent/capability.ex:809, 877, 955` — `parse_granter`, `decode_uri_or_any_strict!`, `string_to_uri_or_any` → migrate to `parse!/1`.
- `ezagent/agent_lineage.ex:77` — `URI.parse(s)` → migrate to `parse!/1`.
- `ezagent/notifications.ex:180` — `URI.parse(s)` → migrate to `parse!/1`.
- `ezagent/entity/system.ex:47` — `URI.parse("system://routing/default")` → `URI.new!` (§3.5).
- `ezagent/kind/snapshot.ex:160, 361` — `URI.new`, `URI.parse(s)` → migrate to `parse!/1`.
- `ezagent/system_principal/catalog.ex:98` — `@bootstrap_granted_by URI.parse(...)` → `URI.new!` (§3.5).
- `ezagent/ecto/uri_type.ex:33, 44` — `URI.new(s)` in `cast`/`load` → dual-fallback per §3.7.
- `ezagent/capability/parser.ex:117` — `URI.new(instance_str)` → migrate to `parse!/1`.
- `ezagent/runtime/pid_file.ex:274` — `URI.new("entity://...")` → migrate to `parse!/1`.
- `ezagent/routing/resolver.ex` — already uses `parse!/1` at 353, 388. Line 277 uses `URI.new!(receiver)` — query-target adjacent, verify.
- `mix/tasks/ezagent.stress.ex:504` — `URI.new!(s)` test/mix helper — out of scope (tests).

### `apps/ezagent_domain_identity/lib/`

- `ezagent/entity/user.ex:29, 30` — `@admin_uri`, `@system_bootstrap_uri` → `URI.new!` (§3.5).
- `ezagent/identity.ex:105, 152, 188, 265` — mix of `URI.parse` and `URI.new` → migrate to `parse!/1`.
- `ezagent/entity_presenter.ex:61` — `case URI.new(uri_str)` → migrate to `parse!/1` rescue.

### `apps/ezagent_domain_chat/lib/`

- `ezagent_domain_chat.ex:116, 156, 494, 578, 631` — mix of `URI.new!` and `User.admin_uri()` (which becomes canonical post-§3.5 fix) → migrate runtime URI constructions to `parse!/1` where not §3.4.
- `ezagent/entity/session.ex:65, 304-307, 523, 709, 852, 918-923, 1073, 1175, 1215, 1240, 1541, 1629, 1672, 1695, 2018, 2055, 2107, 2136, 2227, 2228` — heavy URI surface, mix of forms. The 303-307 hand-roll DELETED; other sites migrated per §3.4 / §3.5 rules.
- `ezagent/entity/session_template.ex:188, 425, 585, 627, 686, 718` — migrate per §3.4 / §3.5.
- `ezagent/entity/agent_template.ex:275` — `URI.parse("#{...}?action=template.fork")` → migrate to `parse!/1` (query-target form).
- `ezagent/entity/agent.ex:232, 653` — `URI.new!` query-target form, OK; verify `653`'s constructor is canonical.
- `ezagent/behavior/chat.ex:805, 986, 1176, 1186, 1203` — mix; sweep.
- `ezagent/behavior/template.ex:408, 413, 514, 536, 649, 675, 692, 720` — mix; sweep.
- `ezagent/chat/read_marker.ex:327, 339` — `URI.parse(session_str)` etc → migrate.
- `ezagent/orchestrator/tools.ex:57, 323, 532, 1004, 1056, 1258, 1438, 1516, 1582, 1583, 1699, 1739` — heavy site; sweep.
- `ezagent/orchestrator/mcp_registry.ex:149, 157` — `URI.parse` → migrate to `parse!/1`.
- `ezagent/orchestrator/mcp_socket.ex:51` — `URI.new(agent_uri_str)` in `with` chain → migrate to `parse!/1` rescue.
- `ezagent/orchestrator/health.ex:144` — `URI.new!(...)` constant-style → OK or move to module attr.
- `ezagent/template/generic_session.ex:97, 118, 121, 161` — mix; sweep.
- `ezagent_domain_chat/application.ex:415-416` — `URI.new!` for seed, OK.

### `apps/ezagent_domain_workspace/lib/`

- `ezagent/workspace.ex:603, 651, 696, 727` — `URI.new!` query-target form, OK.
- `ezagent/behavior/workspace.ex:888, 930, 1225` — mix; sweep.

### `apps/ezagent_domain_agent_bridge/lib/`

- `ezagent/agent_bridge/registry.ex:98, 111` — `URI.parse(key)` lookup → migrate to `parse!/1`.
- `ezagent/agent_bridge/token_store.ex:55, 69` — `URI.parse(agent_str)` → migrate to `parse!/1`.

### `apps/ezagent_domain_python/lib/`

- Already uses `Ezagent.URI.parse!/1`. No changes.

### `apps/ezagent_domain_external_mirror/lib/`

- Mostly clean. Spot-check `ezagent/external_mirror.ex:474` and `gates.ex:321` — these are `==` comparisons, not constructions. No change.

### `apps/ezagent_domain_ui/lib/`

- `ezagent_domain_ui/primitives.ex:103` — `URI.new(str)` → migrate to `parse!/1`.

### `apps/ezagent_web/lib/`

- `live_auth.ex:341` — already canonical via `parse!/1`. OK.
- `live/home_live.ex:170` — `URI.new!` query-target. OK.
- `controllers/workspace_switch_controller.ex:65` — `URI.new!("workspace://" <> _)` — canonical-by-construction. OK or rewrite to `parse!/1`.
- `controllers/api_v1_controller.ex:201` — `URI.new!` query-target. OK.

### `apps/ezagent_cli/lib/`

- `dispatch.ex:125, 128, 136, 264` — mix of `URI.new` and `URI.parse` → migrate to `parse!/1`.
- `exec.ex:151` — `URI.parse(entity_uri_str)` → migrate to `parse!/1`.
- `tree_builder.ex:216` — `case URI.new(s)` → migrate to `parse!/1` rescue.
- `coercion.ex:53` — `case URI.new(s)` → migrate to `parse!/1` rescue.

### `apps/ezagent_plugin_*/lib/`

- `cc/lib/ezagent/plugin_cc/channel.ex:102, 109` — `URI.new!` query-target + constructor. Sweep.
- `cc/lib/ezagent/plugin_cc/socket.ex:24` — `URI.new(agent_uri_str)` → migrate.
- `cc/lib/ezagent/template/cc_agent.ex:254` — `URI.new(uri_str)` → migrate.
- `cc/lib/mix/tasks/ezagent.demo.seed_cc_agent.ex:62, 63, 142` — mix; sweep (mix task is operator-facing, treat as production).
- `curl_agent/lib/ezagent/behavior/curl_agent.ex:293, 315` — sweep.
- `curl_agent/lib/ezagent/template/curl_agent.ex:73` — sweep.
- `echo/lib/ezagent/behavior/echo.ex:142, 213` — sweep.
- `echo/lib/ezagent/template/echo_agent.ex:117` — sweep.
- `feishu/lib/ezagent/plugin_feishu/binding_policy.ex:241` — sweep.
- `feishu/lib/ezagent/plugin_feishu/mention_parser.ex:77` — sweep.
- `feishu/lib/ezagent/plugin_feishu/behavior/user_binding.ex:482` — sweep.
- `liveview/lib/ezagent_plugin_liveview/*.ex` — 16 files; sweep.
- `np/lib/ezagent/behavior/np_agent.ex:277` — sweep.

**Total ~226 production sites by SPEC enumeration.** Codex Q2 challenge target.

---

## Appendix B — invariant test pseudo-code (full draft of §5)

```elixir
defmodule Ezagent.URICanonicalizationTest do
  use ExUnit.Case, async: true

  @allowlisted_files [
    "apps/ezagent_core/lib/ezagent/uri.ex"
  ]

  @lib_glob "apps/*/lib/**/*.ex"

  test "no stdlib URI.parse/1 in production lib/" do
    violations = scan_for(~r/\bURI\.parse\(/, fn _line -> false end)

    assert violations == [],
           """
           Found #{length(violations)} use(s) of stdlib URI.parse/1 in production lib/.
           Use Ezagent.URI.parse!/1 instead for Ezagent-scheme URIs (SPEC 2026-05-27-uri-canonicalization §3).
           Violations:
           #{format(violations)}
           """
  end

  test "no stdlib URI.new!/1 in production lib/ outside the §3.4/§3.5 carve-outs" do
    violations =
      scan_for(~r/\bURI\.new!\(/, fn line ->
        is_query_target_idiom?(line) or is_module_attribute?(line)
      end)

    assert violations == [], format(violations)
  end

  test "canonical URI round-trip" do
    for s <- [
      "entity://user/system/admin",
      "entity://agent/team-alpha/cc_demo",
      "session://default/system/main",
      "workspace://team-alpha",
      "system://bootstrap/default"
    ] do
      a = Ezagent.URI.parse!(s)
      b = Ezagent.URI.parse!(URI.to_string(a))
      assert a == b
      assert a.authority == nil
      assert URI.to_string(a) == s
    end
  end

  test "admin_uri canonical-equal across constructors" do
    from_const = Ezagent.Entity.User.admin_uri()
    from_parse = Ezagent.URI.parse!("entity://user/system/admin")
    {:ok, from_load} = Ezagent.Ecto.URI.load("entity://user/system/admin")

    assert from_const == from_parse
    assert from_const == from_load
    assert from_const.authority == nil
  end

  defp scan_for(regex, exclude?) do
    for path <- Path.wildcard(@lib_glob),
        path not in @allowlisted_files,
        {line, lineno} <- Enum.with_index(File.stream!(path), 1),
        Regex.match?(regex, line),
        not String.contains?(line, "# uri-canonical-allow"),
        not in_comment?(line),
        not exclude?.(line) do
      {path, lineno, String.trim(line)}
    end
  end

  defp is_query_target_idiom?(line),
    do: String.contains?(line, "URI.new!(") and String.contains?(line, "?action=")

  defp is_module_attribute?(line),
    do: Regex.match?(~r/^\s*@\w+\s+URI\.new!\(/, line)

  defp in_comment?(line), do: Regex.match?(~r/^\s*#/, line)
end
```

(Full impl-grade version goes in the impl PR; this is the SPEC-grade reference.)
