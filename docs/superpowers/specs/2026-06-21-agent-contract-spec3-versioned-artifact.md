# spec-3 — manifest + team as versioned artifact (publish / adopt / migrate)

- **Date:** 2026-06-21
- **Status:** Draft (for codex adversarial review → plan/handoff)
- **Parent design:** `2026-06-21-agent-definition-contract-design.md`
- **Lands on:** `main` for the version-pin + migrate **semantics**; the CR/release **file pipeline** is autoservice's publish front-end (consumer).
- **Gate owned:** G4 (publish → adopt → migration).
- **Depends on:** spec-1 (the manifest is the artifact being versioned).

---

## 1. Scope

**In (on `main`):**
1. **Version-pin model** — lean on the EXISTING immutable `session_template_uri@hash` a session already holds; new sessions adopt by tag-resolution at create; existing sessions are structurally unaffected by a publish.
2. **Adopt-on-create** — `SessionCreator.create_session/3` resolves the tag → immutable hash at create time and stamps it (NOT the deleted `Session.spawn_from_template/2`).
3. **Migrate primitive** — a session-level, **ledger-tracked** "re-point this session to template `@hash`" built on the per-member `MemberTemplate.update_member_template/3` (spawn-new→retire-old + route repoint).
4. Confirm the **manifest (spec-1) and team (SessionTemplate content) are the versioned artifacts** that flow through the above, with no new third concept.

**Out:** the CR/release/`_current` file storage + lint + publish UX (autoservice `ezagent_plugin_cr`/`Refresh`, on `feat/autoservice-*`) — spec-3 defines the semantics those consume; it does not rebuild them. Soul/slot authoring UI (admin skill). Auto-migration of live sessions (manual by design).

---

## 2. Current state on `main`

| Concern | Module / fn | Note |
|---|---|---|
| **version model** | `SessionTemplate` URI `template://session/<ws>/<name>@<version_hash>` — **SHA-256 over slice content, immutable per row** (`session_template.ex:17-32`) | the pin **IS** this immutable URI |
| **mutable tags** | `template_tags` registry `(name, tag) → version_hash` (`template_tags.ex:6`) | tags move; hashes don't (git-like) |
| **instantiate a session** | `EzagentDomainInstanceMessage.SessionCreator.create_session/3` (`session_template.ex:114,119,125`) | the live path; `Session.spawn_from_template/2` is **DELETED** (`:121`) |
| **session's template ref** | `template_working_copy.session_template_uri` (`template_resolver.ex:62`, `session_manager.ex:357`) | the durable pin a session already holds |
| new version | `update_template()` / `save_template_as()` / `persist_version/2` (`session_template.ex:86-109`) | new hash row; older sessions on prior hashes unaffected |
| team assembly | `TemplateTeam.materialize_template_team/4` | members(role→AgentTemplate) + prompt_templates + legends + rule-sets |
| per-member migrate | `MemberTemplate.update_member_template/3` (`member_template.ex:275`) | spawn-new→repoint(receivers + `{:from}`)→retire-old; rollback-safe; **rejects same-URI** (`:426`) |
| fork = config only | invariant #10 (`session_template.ex:116`) | migration must not replay message history |

**Not on main:** `EzagentPluginCr.CrEngine` (`CR → release/vN → _current → rollback`), `EzagentPluginAutoservice.Refresh` (re-render `CLAUDE.md`/curl prompt on publish). These are the **file-storage + publish front-end** that wrap spec-3's semantics.

---

## 3. Design

### 3.1 Version pin — already exists (codex P1-4)

There is **no new pin field**. A session's `template_working_copy.session_template_uri` is already an **immutable** `@version_hash` URI. A publish creates a NEW hash row and re-points a *tag*; it never mutates the existing row. So an existing session — holding the old immutable URI — is **structurally unaffected** by a publish. spec-3 just leans on this; it does not invent a pin and does not touch the deleted `Session.spawn_from_template/2`.

### 3.2 Adopt-on-create — resolve the published version at create only

**Design intent:** a new session adopts the **currently-published** version **at create time** and records the resolved immutable `session_template_uri`; an existing session keeps its frozen hash. So a publish affects only *future* creates, never a live session.

> **Plan-time (not spec):** the published-version pointer is the mutable **tag** (`TemplateTags`), but `create_session/3` does not consult it today (the tag API is currently unused — it resolves a matching hash directly). Wiring tag-resolution into `create_session/3` (so "publish" = move a tag and new creates follow it) is a plan-time task. The spec fixes the *adoption semantics* (create-time resolution, existing sessions frozen), not which lookup `create_session/3` calls. (Falsifier: moving the published pointer mutates an existing session's behaviour.)

### 3.3 Migrate primitive (session-level) — ledger-tracked (codex P2-5)

`update_member_template/3` is **per-member** (local compensation), **not** a session-wide transaction, and **rejects same-URI** swaps (`member_template.ex:426`). So `migrate_session` is an orchestration over per-member swaps with an explicit **ledger**:

```
migrate_session(session_uri, target_template_uri):       # target is an immutable @hash URI
  write migration ledger to working_copy: %{target, members: %{role => :pending}}   # resumable anchor
  for each member whose source AgentTemplate URI differs (pinned vs target):
     MemberTemplate.update_member_template(role_name, new_source_template_uri, …)   # spawn-new→repoint→retire-old
     ledger[role] = :done | :failed                                                # checkpoint each member
  repoint changed routing_rules via RuleStore (scoped: created_by == session_uri)
  on full success: set working_copy.session_template_uri = target; clear ledger
  on partial failure: ledger persists → re-run resumes from :pending/:failed (idempotent; converges)
```

- **Same-URI resolution (P2-5):** a soul/slot edit MUST mint a **new** AgentTemplate version (new `source_template_uri`), mirroring the SessionTemplate immutable-hash model — so a member edit is always a *changed-URI* swap that `update_member_template` handles, never the rejected same-URI case. **Dependency:** if AgentTemplate is not yet content-hash-versioned on main, spec-3 (or spec-1) must add per-edit version minting; the autoservice `release/vN` pipeline already provides this immutability for its content.
- Built on **existing** primitives (`update_member_template`, `RuleStore`); spec-3 adds only the ledger + session-level orchestration + the final pin re-point. Manual by design; no auto-migrate.

### 3.4 Artifact identity

The **manifest** (spec-1, per agent) and the **team** (SessionTemplate content: members + rules + legends + prompt_templates) ARE the versioned artifacts. The autoservice CR/release pipeline snapshots them into `release/vN`; on main the same content is a `SessionTemplate` version. No third concept (master §15 confirm).

---

## 4. Invariants / CI gates

- **G-INV-9** The pin is the **immutable** `session_template_uri@hash`; a publish (new hash row + tag move) never mutates an existing session's URI, so it is never auto-advanced.
- **G-INV-10** Migration reuses `update_member_template` (no new live-PTY-mutation path; `feedback_let_it_crash_no_workarounds`); a member edit always mints a **new** `source_template_uri` so swaps are changed-URI, never the rejected same-URI.
- **G-INV-11** Migration is scoped to the target session's own rules (`created_by == session_uri`) — never touches another session's routing.
- **G-INV-12** Fork/version carries config only, never message history (invariant #10).
- **G-INV-13** A partial migration is **resumable** via the working-copy ledger (re-run idempotent, converges) — no half-migrated session left without a recovery anchor.

---

## 5. VERIFICATION

### E2E
- **G4** — author a team at hash `h1`; create session A (holds immutable `…@h1`). Edit a member's soul/slot + publish → new hash `h2`, tag `current → h2`. Create session B → resolves `current → h2`, holds `…@h2`. Session A → **still `…@h1`** (publish never touched its frozen URI). Run `migrate_session(A, …@h2)` → A's changed member regenerated (new `source_template_uri`, new backend config), routes repointed, pin now `h2`; A never lost its members mid-migration (spawn-new→retire-old). Inject a mid-migration failure → ledger persists → re-run resumes and converges.

### Unit / integration
- pin is recorded at spawn; survives restart; not advanced by a publish.
- `migrate_session` over: (a) member whose source template changed → regenerate; (b) routing rule changed → RuleStore replace; (c) partial failure → resumable, no orphan, other session untouched.
- adopt-on-create resolves "current" consistently for two sessions created across a publish boundary.

### Falsifiers (must stay red)
- a publish silently changing an existing pinned session's behaviour without `migrate_session`; a migration touching another session's rules; message history appearing in a forked/migrated session; a live-PTY mutation instead of regenerate; **a soul/slot edit that does NOT mint a new `source_template_uri`** (would hit the rejected same-URI path); **a partial migration with no resumable ledger** (half-migrated session stuck).

---

## 6. Dependencies & risks

- **spec-1** first (the manifest is the artifact).
- **autoservice CR pipeline** (file storage + `Refresh`) is the publish front-end on a sibling branch — spec-3's semantics must match what `CrEngine.publish`/`Refresh` expect; verify the contract at the seam (publish writes a version → spec-3's adopt/migrate consume it).
- **Partial-migration semantics** (resume vs all-or-nothing for a multi-member team) — pick + document.
- Shared (master §15): SessionTemplate vs AgentTemplate naming.
