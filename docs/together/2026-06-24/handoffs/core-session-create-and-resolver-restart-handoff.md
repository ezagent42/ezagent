# Handoff: two core (core/domain) reliability bugs — for @林懿伦

> **Owner:** @林懿伦 (allenwoods) — both are core/domain-internal (session create path + the resource resolver registry), so the lead takes them directly.
> **Date:** 2026-06-24 · **Branch (suggested):** `fix/core-session-create-and-resolver-restart` (or one branch per bug).
> **Goal served:** ① get ezagent running inside the team — both bugs can make a session or a resource type silently unavailable, which blocks the in-team rollout.

This handoff covers two independent bugs; they can be two separate PRs.

---

## Bug A — session-create snapshot race (`:no_such_actor` on a freshly-created session)

**Symptom (found by @李震宇 in the 2026-06-23 `world-deploy-e2e-pg` run, return §7):** a session can reach the UI **without a respawnable snapshot**, so `:session :send` returns `:no_such_actor` — and the error is **swallowed by the `:cast` path** (silent). Send works fine on a session that *did* get snapshotted (`{:ok, stored: true}`).

**Root cause (root-caused, proven by an in-node `:erpc` positive control):** `create_session` times out at the **5 s framework dispatch limit**, AND **snapshot-on-create races that budget** — the reviewer's repro: two identical timed-out creates → one got snapshotted, one didn't. So the create "succeeds" enough to mount in the UI but the durable snapshot the respawn path needs isn't there.

**What already landed (do NOT redo):** the **session-create ↔ orchestrator decouple** (spec #902 → impl #912, MERGED). It removed the 90 s wait/kill/rollback gate and made `create_session` return a usable session without waiting for orchestrator startup. That removes the *orchestrator-coupling* contributor to the timeout — but the **snapshot-on-create race itself is NOT confirmed fixed** (the decouple return was marked `out_of_scope` for the race).

**The task:**
1. **Verify first** — on the post-#912 main, reproduce @李震宇's repro (concurrent/back-to-back `create_session`): is the race still present now that the orchestrator wait is gone? (If create is now fast + synchronous-snapshot, it may be cleared — confirm before fixing.)
2. If still present: make snapshot-on-create **not race the dispatch budget** — i.e. the create path must not return "session usable" until its respawnable snapshot is durably stored (snapshot ordered *before* the session is announceable), OR the 5 s budget must not apply to the snapshot write. The fix is bounded — send itself works on a snapshotted session.
3. **Stop the silent swallow** — the `:session :send` → `:no_such_actor` on the `:cast` path should surface (log/telemetry), not vanish, so this class is never silent again.
4. Regression test: a created session is **immediately respawnable** (snapshot present) before it is announceable; a concurrent double-create both snapshot.

**Files:** `apps/ezagent_domain_session` (the `create/1` + snapshot-on-create path; `Ezagent.Kind.Server` persist path), the `:session :send` `:cast` dispatch. Evidence: `docs/together/2026-06-23/evidence/` + the `world-deploy-e2e-pg` return §7.

---

## Bug B — resolver Registry restart drops plugin-contributed resource types

**Symptom (found 2026-06-24 during the resource-type PR-2 work; also codex HIGH-2 on the PR-1 spec):** `Ezagent.Resource.FsResolver.Registry` is a `:protected`-table-owning GenServer. On an **isolated restart** of that GenServer, `init/1` re-applies **only** the core `boot_registrations/0` (`cc-agents`, `codex-agents`, `uploads`). **Plugin-contributed types** (`world-layouts`, and any future plugin `resource_types/0`) are **NOT replayed** — they were published once at the plugin's `Plugin.boot/1` Phase-2 and are now gone. `FsResolver.resolve/2` then returns `:none` for them (fail-CLOSED — denies, never grants), so the type is **silently unavailable** until the owning plugin app restarts.

**Already mitigated (not a full fix):** PR-1 made a malformed plugin decl no longer *crash* the Registry (removing the main trigger), and the posture is fail-closed (`:none` denies). It is documented in `docs/futures/todo.md` as a MED OPEN item. But "a plugin resource type silently vanishes after a Registry crash" is a real availability bug for the in-team rollout (e.g. world layouts / uploads become unresolvable after one crash).

**The task (design choice for @林懿伦):** make a Registry restart restore the FULL allowlist, NOT just core. Options to weigh:
- (a) On restart, re-trigger each loaded plugin's `resource_types/0` publish (the Registry re-collects from `Application` + the plugin contract at `init/1`) — restores plugin types without a per-plugin restart.
- (b) Supervise so a Registry crash escalates to re-run the plugin layer's Phase-2 (cleaner OTP, heavier).
- (c) Accept fail-closed + make it loud/observable (telemetry) so an operator restarts the owning app — smallest change, but leaves the availability gap.
- Preserve the security property (PR-1): owner-only, write-once on both `<type>` and `backend_component`, no overwrite — whatever restores the allowlist must not let a forged type slip in.

**Files:** `apps/ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex` (init + restart), `apps/ezagent_core/lib/ezagent/plugin.ex` (Phase-2 publish). Spec context: `docs/superpowers/specs/2026-06-24-plugin-resource-type-registration-design.md` §5; the todo.md MED entry.

---

## 讨论项（早会 standup — who needs to be in the room）

- **Bug A — is it still live post-#912?** participants: **@林懿伦 @李震宇** — @李震宇 has the repro + runs today's 人肉; align on whether the snapshot race still reproduces before @林懿伦 writes the fix (avoid fixing a cleared bug). This gates goal ① ("跑起来").
- **Bug B — priority + approach (a/b/c).** participants: **@林懿伦** (+ Claude for resolver context if needed) — decide whether it blocks the in-team rollout this week (does a crash realistically drop world-layouts/uploads in the team setup?) and which restore option. Security invariant (PR-1 write-once) must hold.
- **Disposable stack retired this week** (per @林懿伦): all dev tracks run on each dev's **own host**; to view another dev's running work, use the **intranet Tailscale (tailnet) address**, not a shared stack. (Recorded in today's plan.)
