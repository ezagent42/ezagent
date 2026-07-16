# Cap-signing (per-Kind authority, Path A) — Implementation Plan

> **For codex:** implement every stage below on ONE target branch — do NOT open a PR per stage and do NOT wait for per-stage review. Merge each stage's work into the single target branch `feat/cap-signing-impl` (cut from latest `main`), in order. The coordinator reviews the final branch worktree at the end (not per stage). Each stage has a **RED-GATE**: a test/gate that MUST pass before moving to the next stage (self-check; the gate is your signal, not a human). The final acceptance is the **§F E2E suite**.

**Spec (authoritative):** `docs/superpowers/specs/2026-07-16-cap-signing-per-kind-authority-design.md` (v7, SOUND across 7 codex rounds). Read it fully first — this plan implements it; where this plan and the spec differ, the spec wins.

**Goal:** Replace soft dual-read cap authorization with born-signed + strict-verify per-Kind authority, closing capability forgery/tamper/retarget/issuer-impersonation as a priv-esc/credential-theft vector, under the **Path A (reviewed-code) threat model** (malicious in-VM code explicitly out of scope — `capbac.md §4.5`).

**Architecture (from the spec):** each target Kind K is the sole sign+verify authority for caps on itself (symmetric per-Kind key in a non-exporting authority compartment); issuance is a cap-gated `K.grant` action; one framework verifier dominates dispatch; presenter authenticated at the external edge via a light `origin` provenance (fail-closed); genesis is a one-time append-only CAS to canonical admin.

**Tech:** Elixir/OTP umbrella; EdDSA `:crypto.sign/verify` via `Ezagent.Cap.Signing`; the existing `Kind`/`Kind.Runtime`/`Kind.Server` dispatch; ecto for the durable authority record.

## Global constraints
- **Path A threat model** — defend ① accidental forgery ② review-missed arch-violation ③ external-ingress caller-spoofing. NOT malicious in-VM code. State this in every module doc that claims a boundary.
- **No `require_signature:false` soft path** — strict verify only; delete dual-read / `verify_for` / the self-healer / the old central-seed `Cap.sign_artifact` path.
- **Signing/key touched from exactly THREE framework sites** — authority genesis/custody, the verifier, the post-verifier `K.grant` issuance. Never Behavior/domain/plugin tiers.
- **Every dispatch envelope carries a positive `origin`** (`authenticated-external` | `trusted-internal`); unstamped → reject before authz.
- **Cutover is coordinator-only** — do NOT attempt the wipe+reseed deploy (§G); stop at "seeded-stack E2E green."
- Keep `main` mergeable: rebased on `main`, `mix precommit` + `check_invariants` green on the target branch at each stage's RED-GATE.

---

## Stage 1 — Per-Kind authority compartment + signing confinement
**What:** move the per-Kind signing key out of any slice into a framework-owned, non-exporting compartment (private top-level `Kind.Server` state or a scoped keystore process, per spec §3), and confine `Ezagent.Cap.Signing.sign/verify` + key access to the three framework sites.
- Add a per-instance key to the authority compartment; loaded on activation; never returned by generic slice reads / snapshots / events / logs / admin listings (spec §3).
- `sign(handle,cap)`/`verify(handle,cap,presenter)` become framework-internal; the raw key is never a value handlers can hold.
- Delete the central-seed `Cap.sign_artifact` derive-from-seed path (`cap.ex:204-220`, `cap/signing.ex` seed derivation).
**RED-GATE 1:** a test proving (a) a Behavior/plugin handler calling `Kind.get_slice`/snapshot on a Kind with a key gets NO key material; (b) `Cap.Signing.sign/verify` and the key field are referenced only from the three framework sites (grep/AST arch-gate — spec §10 property 3); (c) `mix compile --warnings-as-errors` + `check_invariants` green.

## Stage 2 — `origin` provenance + presenter (fail-closed) + ingress build-gate
**What:** add a light `origin` boolean/enum to `%Cmd{}` and `%Invocation{}` (spec §1.5); stamp `authenticated-external` at every external edge (from the authenticated session/bearer, overwriting `ctx.caller` server-side); stamp `trusted-internal` at every internal minter; **reject any unstamped envelope before authorization**.
- Edges to stamp (spec §1.5 inventory): `api_v1_controller`, `session_principal`, PTY/channel, `chat_completions_plug`, `world_uploads_controller`, `session_config_controller`, inbound email; **Feishu: HTTP webhook stays unstamped→rejected until it verifies the Feishu signature; WSS (`ws_client`) may stamp** (pass transport provenance INTO `InboundDispatcher`, do not stamp unconditionally).
- Internal minters: DeliveryOutbox (persist the authenticated presenter in the durable record + re-mint on replay), ExternalMirror (self-URI), SessionTemplate, CLI, EntityCaps/Identity facades.
- `Router.to_invocation/1` preserves `origin` Cmd→Invocation.
- **The ingress build-gate (spec §10):** an arch-gate that enumerates every `Router.dispatch/1`/`Invocation.dispatch/1` call site + every `%Cmd{}`/`%Invocation{}` constructor and FAILS the build if any does not set a positive `origin`.
**RED-GATE 2:** (a) an unstamped `%Invocation{}` reaching `Kind.Runtime` is rejected before authz; (b) a stolen cap presented with a spoofed `ctx.caller` over an `authenticated-external` edge is rejected (presenter = server-written identity); (c) the ingress arch-gate is green AND demonstrably reds when a new unstamped dispatch constructor is added (mutation test).

## Stage 3 — Genesis CAS authority record
**What:** a durable append-only, non-deletable-by-runtime/plugin authority record (spec §5): one winning INSERT atomically generates the per-Kind key, emits ONE K-signed anchor to `Ezagent.Entity.User.admin_uri/0` (`entity://system/user/admin`), stores key version + sealed flag; anchor read FROM the row. Admin self-row written FIRST (no verifier). Option-B reincarnation: reject reused-URI creation until an append-only admin re-genesis activates a new generation; row selection keys on active generation. Confirm the destroy-clears-rehydration invariant holds (it does on `origin/main` — `lifecycle.ex:747-777` deletes snapshot → `ever_created?` false → `create` branch).
**RED-GATE 3:** (a) genesis runs once per Kind and re-invocation collides (sealed); (b) admin self-anchors without a pre-existing cap (non-circular); (c) delete/recreate a Kind URI → new generation, old authority row never silently rehydrated; (d) every `{:genesis, arbitrary_uri}` form removed (`cap.ex:21-27,169-172,227-229`) + arch-gated.

## Stage 4 — Single framework verifier + structural cap/non-cap split + intent-freeze
**What:** one `Kind.Runtime` verifier dominates every handler/state-mutating route (spec §2); it reads the presenter per `origin`, verifies the presented cap (target-Kind-signed + `(instance,action,grantee)` + authenticated presenter), fail-loud. Freeze the framework-validated grant intent at validation time (before `pre_handle`/`post_handle`). **Structural cap/non-cap split (spec §10 property 2, preferred):** cap-gated actions in a declaration class where the verifier ALWAYS applies (no exempt flag); non-cap actions a separate class each carrying its own predicate. If the macro refactor is too large this pass, INTERIM = closed static allowlist of the enumerated non-cap classes (identity persistence, cascade_notify_managers, agent/user receive, publisher snapshot/history, session admission + composition_consent — each with its predicate); delete the `cap_issued`/rule shortcuts + close `:vm_internal` all-cap for cap-gated actions.
**RED-GATE 4:** (a) no handler/state-mutating route reaches a handler without the verifier (arch-gate + runtime instrumentation); (b) a cap-gated action cannot carry `cap_exempt_actions`/`cap_issued`/`authorization_rule`/`:vm_internal`; (c) a `post_handle`/`pre_handle` that rewrites the grant does NOT change the signed intent.

## Stage 5 — `K.grant` issuance
**What:** `K.grant` is an unconditionally cap-gated action requiring an authority-cap-on-K; the handler returns an `{:issue_cap, …}` intent effect; the framework post-verifier issuance step signs (binding the frozen validated intent) and returns the new cap to the grantee. Wire the admin→delegate→grantee chain (every cap signed by its target Kind).
**RED-GATE 5:** (a) `K.grant` rejects a caller lacking a valid authority-cap-on-K; (b) a legit `K.grant` mints a target-Kind-signed cap accepted by the verifier; (c) the delegation chain (admin→Alice directs W→Bob) works end-to-end, recursion bottoming at admin.

## Stage 6 — §10 arch-gate suite + delete legacy
**What:** land the full §10 gate set (spec §10): no-bypass-flags (static), declaration-parity (static), + the ratchet+runtime properties (verifier dominance, signing/key confinement, key-egress absence, presenter authenticity, unique target-key binding, genesis one-shot, ingress-completeness). Delete: dual-read / `verify_for` / default-off `require_signature` / self-healer / central-signer+keyring / `{:genesis,URI}` / the authz_check cap-gated bypasses.
**RED-GATE 6:** the whole arch-gate suite green; a grep proves the deleted paths are gone; `check_invariants` + `mix precommit` green.

---

## §F — Final E2E acceptance (the goal gate)
On a **freshly seeded stack**, each an INDEPENDENT assertion (spec §9), proving the attempt reached the authorization boundary:
- **forge** (unsigned), **tamper** (mutated-after-sign), **retarget** (A-signed presented at B), **stolen-cap+spoofed-presenter** (external), **wrong-target-key**, **issuer-impersonation** (`K.grant` without authority-cap), **genesis-seal** (re-genesis rejected), **key-egress** (slice/snapshot/admin-listing returns no key) — EACH rejected fail-loud; **legit** (`K.grant`-minted cap, authenticated grantee) accepted.
- Representative actions: session.send, create_session, PTY read, kanban write, world read_unfiltered.
- **Note:** forge/tamper/retarget will *fail on today's `origin/main`* (soft dual-read) — that red is the proof the gate is real; the positive `K.grant` path lands with this implementation.
**Done = §F green on the seeded stack + all RED-GATES green + `main`-rebased target branch.** Return the target branch name + a summary of each stage's RED-GATE result. STOP here — do not deploy.

## §G — Cutover (COORDINATOR ONLY — not codex)
wipe+reseed on ezagent-deploy (quiesce → wipe cap-bearing data → deploy → seed admin-first then per-Kind key+anchor, all caps re-issued signed → resume). No app-side migration code. Coordinator handles this after §F is green and reviewed.

## Out of scope (separate tasks)
- **Feishu webhook transport-auth** — the unauthenticated HTTP webhook (`webhook_plug.ex`) is a standalone pre-existing security fix (verify Feishu signature/secret); Stage 2 only *classifies* it (unstamped→rejected until fixed). Track separately.
- Cap-storage consistency (multi-home/revoke-completeness); full distributed cross-node transport (design supports it, impl deferred).
