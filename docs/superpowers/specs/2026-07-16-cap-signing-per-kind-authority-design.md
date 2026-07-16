# Cap-signing: per-Kind authority — DESIGN

**Status**: fresh redraft on the lead's mental model. **Supersedes** the central-signer line (`2026-07-15-cap-signing-strict-capstore-design.md`, v1–v11) — that design was driven by adversarial review to a sound-but-heavy place (central isolated signer + public keyring + global issuer-authentication); this model is simpler, more aligned with the system's dispatch structure, and distribution-friendly. Pending codex adversarial review.
**Implementer**: coordinator (Claude) directly (app + ezagent-deploy cutover).

## 0. The X problem (unchanged)
Capabilities are **forgeable / tamperable / retargetable** under soft verification (dual-read accepts unsigned) → privilege-escalation / credential-theft. **Close it**: every cap signed and strictly verified; unproven authority rejected.

## 1. Core model — each Kind is the authority for caps on itself
1. **The target signs.** A capability authorizes an action on a Kind `K`. **`K` is the sole authority for caps on itself: `K` signs it and `K` verifies it, with `K`'s own key.** The signer of a cap is ALWAYS the target Kind (granter == target == verifier).
2. **Verify at the target, always local.** Verification happens where the action dispatches — at `K`, which holds its key. **No party other than `K` ever verifies a cap-on-`K`.** (This is what makes symmetric per-Kind keys sufficient and the whole model distribution-friendly.)
3. **Issuance is a cap-gated action on `K`.** To make `K` issue a cap to a grantee, the caller invokes the `K.grant` action presenting a valid **authority-cap-on-`K`**; `K` verifies that authority-cap (own key) exactly like any other action, then signs the new cap for the grantee. Issuing is not special-cased — it's an action on `K`, gated by a cap. **This dissolves v11's "authenticate the issuer" problem**: `K` just cap-checks the grant request; nothing global to authenticate.
4. **Authority chain rooted at admin.** The delegation reads `admin → Alice → Bob`, but every cap in the chain is signed by its target Kind. Example: admin causes `W` to sign "Alice manage W" (Alice holds it, W-signed); Alice presents it to invoke `W.grant(Bob, create_session)`; `W` verifies Alice's manage-W cap (W's key) and signs Bob's `create_session` cap. Recursion bottoms out at **admin**, the root every Kind is anchored to trust.
5. **A cap is anchored to `(Kind, Action)`.** The ActionSet declares "this action requires a cap signed by this Kind, for this action." Verification is an **ActionSet-level macro** in the dispatch pipeline: before running a handler, the presented cap must be (a) signed by the target Kind's key, (b) for this action, (c) bound to the presenter. **This is THE single verify chokepoint** — it replaces v11's scattered ~20-consumer migration, because verification naturally lives at dispatch-to-target.

## 2. Retained invariants (salvaged from the v1–v11 work)
- **Born signed** — every cap is minted only through the issuance chokepoint (`K.grant`), signed by `K`. Nothing mints a cap another way.
- **One strict predicate, fail-loud** — the ActionSet macro is the only authorization decision: an unsigned / wrong-signer / wrong-action / wrong-presenter cap is **rejected, fail-loud**. Shape-matching a cap without verifying its signature is forbidden. No dual-read, no `verify_for`, no `require_signature`.
- **No bypass** — the only paths are issue-via-`K.grant` and verify-via-the-ActionSet-macro. Nothing else mints or authorizes.

## 3. Keys & custody
- **Per-Kind symmetric key.** Each Kind `K` holds its own signing/verifying key in **`K`'s process slice** (Elixir per-process heap isolation — another Kind's normal code cannot read it). Symmetric (sign == verify key) is correct because `K` always both signs and verifies its own caps; asymmetric would only help an *off-`K`* verifier, which does not exist here — it would add cert-chain machinery for no gain.
- **Admin root = crown jewel.** `admin` is the root of trust; its key warrants the strongest custody. Every Kind, at creation, is anchored to trust admin's **identity (`entity://admin`)** — NOT a specific admin key.
- **Identity-anchoring + key-versioning** (so future rotation is cheap): admin's key carries a version; Kinds trust the stable identity. Rotating admin's key = version-bump + re-provision to admin's node(s), **not** a fleet-wide re-anchor. Per-Kind keys rotate lazily / on-compromise (blast radius already contained to one Kind).
- **Residual & hardening.** BEAM privileged introspection (`:sys.get_state`, tracing) can dump any process's slice — but this is a **contained** risk (blast radius = one Kind) far smaller than a global seed, and hardened incrementally (restrict those BIFs in prod). Only the admin root warrants stronger custody. **No HSM/separate-security-domain requirement** for the general case (v11 needed one only because a single seed unlocked everything).

## 4. Distribution (friendly by construction)
- A cap is always verified at its target Kind, **on that Kind's node** → topology-independent; no cross-node key sharing. Each node holds only its own Kinds' keys → **node compromise blast radius = that node's Kinds only**. (Contrast v11: one seed on every node → any node compromise forges everything, everywhere — which is why distribution was deferred.)
- Distribution needs only ① cross-node transport/routing (the cap rides the message to the target's node) and ② bootstrap root-anchoring (each node's Kinds seeded at birth to trust the admin root) — **neither is a cap-signing change**. This model **unblocks** the workspace-per-ECS future.

## 5. Bootstrap / genesis
- `admin` is created first (root); admin's key is established. At each Kind `K`'s creation, the trusted bootstrap (acting as admin) seeds `K` with (a) its own key and (b) a `K`-signed authority anchor "admin may direct my issuance" naming `entity://admin`. Genesis bottoms out at admin trusting itself. There is no `{:genesis, arbitrary_uri}` and no key passed as a plain argument.

## 6. Cutover (ezagent-deploy scope)
Self-use, disposable data → **wipe + reseed**: quiesce → wipe cap-bearing data → deploy the new build → seed (admin first, then Kinds each get a fresh key + admin anchor; all caps re-issued signed) → resume. **No app-side migration/backfill code.**

## 7. Non-goals
- **Cap-storage consistency** (a cap in multiple homes, revoke-clears-all) — separate concern.
- **Full distributed transport** — the model SUPPORTS distribution; the routing/bootstrap-anchoring *implementation* is a separate track (deferred). The design must not preclude it (§4).
- Opaque cap representation — not needed here (verify is local at the target with its key, not a global boundary).

## 8. Implementation shape (high-level)
- **Per-Kind key**: added to the Kind's durable slice at creation; loaded on activation; never leaves the Kind process (except admin-root custody, §3).
- **`Cap.sign(kind_key, cap)` / `Cap.verify(kind_key, cap, presenter)`** — used only inside the Kind's dispatch/ActionSet path.
- **The ActionSet macro** — a declaration on each action ("requires cap signed-by-me for this action") that the dispatch pipeline enforces before the handler runs: verify (target-Kind-signed + action + presenter) or fail-loud.
- **`K.grant` action** — cap-gated (requires an authority-cap-on-`K`); on success signs and returns the new cap to the grantee. Issuance = this one action, uniformly.
- **admin root** + key-versioning + identity anchoring; bootstrap ordering.
- **Delete**: dual-read / `verify_for` / `require_signature` / the self-healer / v11's central-signer + public-keyring machinery.

## 9. Behavioral tests (the X holes, closed)
Per representative cap-gated action (session.send, create_session, PTY read, kanban write, world read_unfiltered…):
- **Forge/tamper** — an unsigned cap, and a cap whose fields were mutated after signing, are rejected fail-loud at the ActionSet macro.
- **Retarget** — a cap signed by a **different** Kind than the target is rejected (verify uses the *target's* own key).
- **Issuer-impersonation** — `K.grant` rejects a caller lacking a valid authority-cap-on-`K`; the delegation recursion to the admin root is exercised and proven non-circular.
- **Bootstrap** — admin-first, each Kind anchored to `entity://admin`; strict verify holds end-to-end on a freshly seeded stack.
- **Distribution locality** — verify is always local to the target Kind (topology/multi-hop test asserts no cross-node verify).

## 10. Gate plan (this is a first-class deliverable, not just tests)
Two enforcement layers, following the ezagent static-gate discipline (`check_invariants` → `ci.local` full-suite; run pre-push):

**A. Completion / invariant gate — behavioral, fail-when-the-goal-is-unmet.** One end-to-end `/goal`-style test on a freshly seeded stack that a reviewer runs and reads pass/fail: forged, tampered, retargeted, and issuer-impersonated caps are EACH rejected fail-loud, and a legitimately `K.grant`-minted cap is accepted. This test **fails on today's `origin/main`** (soft dual-read accepts unsigned) — that red is the proof it gates the real hole.

**B. Structural arch-gate — static AST/grep, enforces no-bypass, ratcheting.** In `check_invariants`:
1. The symmetric **sign** primitive is referenced ONLY from the issuance chokepoint (`K.grant`); **verify** ONLY from the ActionSet macro. No other module calls them.
2. **Every** cap-gated action DECLARES its ActionSet cap requirement (the macro is present); an action that consumes a cap without the declared macro is a gate failure.
3. No authorization decision reads cap fields **outside** the ActionSet macro (best-effort AST — see limit below).
4. The per-Kind **key** field is read ONLY inside sign/verify — not exfiltrated by any other code path.

**Honest enforceability limit** (carried from the v11 work): caps are public Elixir structs, so "no cap-field authz outside the macro" is not *perfectly* statically provable — the guarantee is **runtime** (the dispatch pipeline consults ONLY the ActionSet macro for the authorization decision) **plus** the best-effort AST regression gate above. **The new model makes this gate materially stronger than v11**: v11 had to gate ~20 scattered cap-matcher consumers; here verification collapses to ONE dispatch macro and minting to ONE `K.grant`, so the "only-these-two-chokepoints" scan surface is minimal and the ratchet can hold at a tight bound.

## 11. Open (impl-level)
- Exact per-Kind key storage in the slice + activation-load; symmetric primitive (HMAC vs a symmetric AEAD/MAC).
- The ActionSet macro's precise hook point in the dispatch pipeline (where authorize currently is).
- admin-root key custody mechanism (mounted secret) + version scheme.
- Bootstrap sequencing (admin root established before any Kind anchors to it).
