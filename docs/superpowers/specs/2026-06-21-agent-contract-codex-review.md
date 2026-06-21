# Codex adversarial review — agent-contract specs (2026-06-21)

Reviewer: `codex exec` (codex-cli 0.141.0), read-only, grounded against `main`.
Verdict: **NOT ready for implementation handoff.** 4 × P1 blocker, 3 × P2. All findings carry real `file:line` evidence and are **accepted** (the specs over-idealized vs the real code contracts; the overall architecture — two-layer contract, manifest, `flavor.compile`, team-routing reuse — survived).

---

## P1 — blockers

### P1-1 (spec-2 §3.2/§4, master §7) — manifest caps must NOT reach `ctx.caps` (CapBAC self-authorization hole)
Spec said tool dispatch builds `ctx = %{caller: agent, caps: agent_caps}` and `tools[].caps` are "declared caps". The runtime authorizes **`ctx.caps` before** checking held Identity caps (`kind/runtime.ex:395,405,539,557`); real grants flow through Identity (`identity.ex:404`). Copying manifest-declared caps into `ctx.caps` lets **tenant-authored YAML self-authorize any dispatch**.
**Fix:** manifest `caps` are **desired caps only**; the tool endpoint reconstructs *granted* caps from Identity (or relies on `holds_cap?`), and **never** copies manifest caps into the dispatch `ctx`. Add a falsifier: a malicious manifest cap must NOT authorize.

### P1-2 (spec-2 §3.3) — participant join omits join-authority provisioning + participation-cap mounting
"existing entity URI → `chat.join` only" is incomplete. `session.join` is cap-gated (`session.ex:145`); join authority is **provisioned separately** (`membership.ex:258`, granted `:386`); participation caps are **mounted post-join** (`:442`). `Tools.join_member/5` only dispatches join with the caller's caps, no provisioning (`tools.ex:310`).
**Fix:** specify the inviter/session-side policy that provisions join authority + participation caps (esp. for a human operator), without overbroad grants. Add E2E: invited human can send/leave/subscribe, nothing more.

### P1-3 (spec-1 §3.3/§4, master §6) — fallback contradicts the real `fresh?`/adopted spawn + side-effect ownership
Spec assumed `compile` is pure and `Kind.spawn` + "post-spawn obligations unchanged". Real: `spawn_from_template_content/4` runs lineage/workspace/sandbox obligations **only when `fresh?: true`** (`template_spawn.ex:271,314`); `instantiate/3` can return `fresh?: false` (`cc_agent.ex:369`); config-dir creation, grant revalidation, PTY launch + cleanup live **inside** the plugin spawn path (`cc_agent/spawn.ex:105,169,181`), not in a detachable compile step; framework persistence expects instantiate meta (`kind/template.ex:106`).
**Fix:** either make `compile` genuinely pure (no FS/PTY) and keep side effects under `instantiate`/provision ownership, or define explicit **per-candidate cleanup** (config dirs / grants / half-spawned workers) for failed fallback attempts, and require explicit `fresh?: false` handling in the fallback loop.

### P1-4 (spec-3 §3.1/§3.2) — version-pin model is wrong; named API is deleted
`Session.spawn_from_template/2` **does not exist** (live creation is `SessionCreator.create_session/3`, `session_template.ex:119`). Versioning is an **immutable hash URI + mutable tag mapping** (`session_template.ex:17`, `template_tags.ex:6`), NOT an implicit `template_uri@version` pin. Repair/session-manager already read `template_working_copy.session_template_uri` (`template_resolver.ex:62`, `session_manager.ex:357`).
**Fix (also SIMPLIFIES spec-3):** the pin **already exists** — it is the immutable `session_template_uri` in the working copy. Resolve tags only at create/publish boundaries; moving `current` structurally cannot affect an existing session (it holds the old immutable URI). Drop the deleted-API reference; add a falsifier that moving `current` cannot affect existing sessions.

---

## P2 — should-fix

### P2-5 (spec-3 §3.3) — `migrate_session` is not a session-wide transaction; same-URI edits unhandled
`update_member_template/3` is a **per-member** swap with local compensation (`member_template.ex:275,411`), **rejects same-URI in-place edits** (`:426`); routing updates are single-rule receiver rewrites (`:484`, `rule_store.ex:295`), not atomic rule-set migration.
**Fix:** add a migration **ledger/status** in the session working copy (resumable) OR require all-or-nothing compensation. State how a **same-template soul/slot edit** is represented — if soul/slots are part of the hashed content the URI changes (not same-URI); if referenced, it IS same-URI and `update_member_template` can't handle it. Resolve this explicitly.

### P2-6 (spec-1 §4) — split Role retirement; `Role` is still live in orchestrator bootstrap
`Role.Materialize` is prototype-only (safe to delete), but `Role` + composition are **live** in `orchestrator_role.ex:1,115` + `orchestrator_bootstrap.ex:70,86`.
**Fix:** delete only `Role.Materialize` in spec-1 (after grep/test); **keep `Role`** until `AgentManifest` replaces `OrchestratorRole.recipe` + bootstrap role install.

### P2-7 (spec-2 §3.2) — curl/no-MCP "tools = no-op" violates no-silent-drop (P18)
A nonempty `tools[]` on a flavor with no tool transport silently doing nothing violates P18 (`CLAUDE.md:166`, `design-principles.md:139`).
**Fix:** nonempty `tools[]` on a tool-less flavor must **fail compile** or surface an explicit **degraded-state warning**, unless each tool is marked `optional`.

---

## Verdict (codex)
Not ready for handoff. Top 3 first: (1) lock the manifest/tool CapBAC model so YAML cannot populate `ctx.caps`; (2) redesign spec-1 fallback around the real `fresh?`/adopted spawn + cleanup contract; (3) rewrite spec-3 around the real immutable `session_template_uri` pin + an explicit migration ledger. Then split Role retirement from manifest work and add falsifiers for human-participant caps, fallback residue, tag movement, and curl tool drops.

Full trace: `/tmp/codex-spec-review.md` (848KB).
