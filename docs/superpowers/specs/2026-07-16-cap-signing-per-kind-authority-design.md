# Cap-signing: per-Kind authority — DESIGN

**Status**: fresh redraft on the lead's mental model. **Supersedes** the central-signer line (`2026-07-15-cap-signing-strict-capstore-design.md`, v1–v11) — that design was driven by adversarial review to a sound-but-heavy place (central isolated signer + public keyring + global issuer-authentication); this model is simpler, more aligned with the system's dispatch structure, and distribution-friendly. Pending codex adversarial review.
**Implementer**: coordinator (Claude) directly (app + ezagent-deploy cutover).

**Revision v2 (2026-07-16)** — closes codex adversarial-review round 1 (`NEEDS-REVISION`). The model direction held (per-Kind self-sign/verify, verify-at-target, issuance-as-cap-gated-action), but three architecture holes were grounded in `origin/main` and are now closed as hard implementation constraints:
1. **Key custody** — a raw key in a Behavior *slice* is NOT isolated: slices are cross-process-readable (`Kind.get_slice/2`/`get_raw_slice/2`, `slice_access.ex`), sibling reads are not cap-gated (`behavior.ex:409-436`), and keys serialize into full snapshots (`snapshot.ex:455-470`) that a system-scope query can list (`ecto/kind_snapshot.ex:44-64`) → any Kind's normal code, or any node sharing the Repo, could exfiltrate the key. **Fix: keys never live in a slice** — see §3.
2. **Presenter authenticity** — `ctx.caller` is caller-supplied and Router-preserved without authentication (`cmd.ex:75-117`, `router.ex:151-170`), so "bound-to-presenter" is forgeable with a stolen cap. **Fix: presenter identity from authenticated provenance** — see §1.5.
3. **Genesis + no-bypass** — seeding a K-signed anchor outside `K.grant` contradicts sole-mint (circular otherwise); `entity://admin` is not the canonical admin; and `authz_check` has live bypasses (`cap_exempt_actions`, `cap_issued`, rule-grants, `:vm_internal`). **Fix: one atomic canonical-admin genesis exception + one framework-owned verifier with no X-sensitive bypasses** — see §2, §5.

## 0. The X problem (unchanged)
Capabilities are **forgeable / tamperable / retargetable** under soft verification (dual-read accepts unsigned) → privilege-escalation / credential-theft. **Close it**: every cap signed and strictly verified; unproven authority rejected.

## 1. Core model — each Kind is the authority for caps on itself
1. **The target signs.** A capability authorizes an action on a Kind `K`. **`K` is the sole authority for caps on itself: `K` signs it and `K` verifies it, with `K`'s own key.** The signer of a cap is ALWAYS the target Kind (granter == target == verifier).
2. **Verify at the target, always local.** Verification happens where the action dispatches — at `K`, which holds its key. **No party other than `K` ever verifies a cap-on-`K`.** (This is what makes symmetric per-Kind keys sufficient and the whole model distribution-friendly.)
3. **Issuance is a cap-gated action on `K`.** To make `K` issue a cap to a grantee, the caller invokes the `K.grant` action presenting a valid **authority-cap-on-`K`**; `K` verifies that authority-cap (own key) exactly like any other action, then signs the new cap for the grantee. Issuing is not special-cased — it's an action on `K`, gated by a cap. **This dissolves v11's "authenticate the issuer" problem**: `K` just cap-checks the grant request; nothing global to authenticate.
4. **Authority chain rooted at admin.** The delegation reads `admin → Alice → Bob`, but every cap in the chain is signed by its target Kind. Example: admin causes `W` to sign "Alice manage W" (Alice holds it, W-signed); Alice presents it to invoke `W.grant(Bob, create_session)`; `W` verifies Alice's manage-W cap (W's key) and signs Bob's `create_session` cap. Recursion bottoms out at **admin**, the root every Kind is anchored to trust.
5. **A cap is anchored to `(Kind, Action)`, verified against an AUTHENTICATED presenter.** The ActionSet declares "this action requires a cap signed by this Kind, for this action." Verification is a **framework-owned pre-handler gate** in the dispatch pipeline (§2): before running a handler, the presented cap must be (a) signed by the **live target instance's** authority handle, (b) for this concrete `(instance, action)`, (c) bound to the **presenter** — and **the presenter identity is taken from authenticated provenance, never from the caller-writable `ctx.caller`**. A stolen cap does not authorize its thief, because the thief cannot also authenticate as the grantee. Presenter identity derives from the authenticated adapter/session that entered the request, or from unforgeable internal dispatch provenance — not from a field any `Cmd` constructor can set (`cmd.ex:75-117`, `router.ex:151-170` today accept it unauthenticated; that path must be closed). This is THE single verify chokepoint.

## 2. Retained invariants + the single framework verifier
- **Born signed** — every cap is minted only through the issuance chokepoint (`K.grant`), signed by `K`. The **only** exception is the one-time atomic genesis transition (§5); nothing else mints a cap.
- **One strict predicate, fail-loud** — an unsigned / wrong-signer / wrong-`(instance,action)` / wrong-presenter cap is **rejected, fail-loud**. Shape-matching a cap without verifying its signature is forbidden. No dual-read, no `verify_for`, no default-off `require_signature`.
- **One framework-owned verifier that dominates every entrypoint.** The ActionSet macro declares only *immutable authorization metadata*; a single verifier in `Kind.Runtime` runs before **every** handler invocation and every state-mutating dispatch route — no handler is reachable without it. This is the no-bypass core, and today's dispatch has explicit escape hatches that MUST be closed for any target-cap-gated action:
  - Delete the `cap_issued` grant shortcut and the rule-authorized grant/revoke shortcuts in `authz_check` (`kind/runtime.ex:344-361`); `K.grant` is **unconditionally** target-cap-gated (its authority-cap is verified like any other).
  - No target-cap-gated action may carry `cap_exempt_actions` (`behavior.ex:341-356`), an `authorization_rule` allow, or ambient `:vm_internal` all-cap authority (`kind.ex:247-255`). Every action is classified **target-cap-gated** or **explicitly internal-only**; internal-only provenance is unforgeable by untrusted code.
  - The signing/verifying primitive is reachable **only** through the K-owned authority module (§3); direct `:crypto`/`Signing` calls and dynamic invocation cannot bypass it.
- **No bypass** — the only paths are mint-via-`K.grant` (or the one genesis exception) and authorize-via-the-single-framework-verifier. An arch-gate (§10) proves no other route mints or authorizes.

## 3. Keys & custody — a non-exporting per-Kind authority compartment
- **The key is NEVER a Behavior-slice field.** Codex round 1 falsified the "slice = isolation" premise: slices are cross-process-readable via `Kind.get_slice/2`/`get_raw_slice/2` (`slice_access.ex:54-112`), `Kind.Server` returns any requested slice key without authorization (`server.ex:526-533`), sibling-slice reads are not cap-gated and are injected straight into handler context (`behavior.ex:409-436`, `kind/runtime/context.ex:40-53`), and a durable field serializes into the full snapshot (`snapshot.ex:455-470`) which a system-scope query can enumerate (`ecto/kind_snapshot.ex:44-64`). Any Kind's ordinary code — or any node sharing the Repo — could therefore read a slice-resident key and sign/verify off-`K`.
- **Per-Kind key lives behind a K-owned, non-exporting authority compartment.** Each Kind `K` has its own **per-instance** symmetric key held in **private non-slice server state**, or behind an **opaque handle** to a scoped keystore. The key material is never returned by generic slice reads, sibling reads, raw reads, snapshots, events, logs, or admin listings — only an opaque authority handle is ever observable. **`sign`/`verify` accept the handle and execute only inside `K`'s own dispatch process**; no API exports the raw key.
- **Symmetric is still correct** (sign == verify at `K`, which holds its own key); asymmetric would only help an off-`K` verifier, which does not exist here (see §4 for the distributed case, where the cap is routed to `K`'s owner runtime rather than verified remotely).
- **Admin root = crown jewel.** `admin` is the root of trust. Every Kind, at creation, is anchored to trust the **canonical admin identity** — resolved from the single code authority `Ezagent.Entity.User.admin_uri/0` (`user.ex:30-32`), **not** the literal `entity://admin` (a non-canonical URI lacking the required workspace/type/name components, `uri.ex:420-428`). The anchor names the identity, not a specific admin key.
- **Identity-anchoring + key-versioning** (cheap future rotation): admin's key carries a version; Kinds trust the stable canonical identity. Rotating admin's key = version-bump + re-provision, **not** a fleet-wide re-anchor. Per-Kind keys rotate lazily / on-compromise (blast radius contained to one instance).
- **Residual.** With keys out of slices/snapshots, the residual is privileged BEAM introspection (`:sys.get_state`, tracing) of `K`'s live process — contained to one instance and hardened incrementally (restrict those BIFs in prod). The admin root warrants the strongest custody (owner-scoped storage / KMS). **No global-seed HSM requirement** — each compartment holds only its own key.

## 4. Distribution (friendly by construction — with the key-custody constraint)
- A cap is always verified at its target Kind's **owner runtime**. Today dispatch already requires the local runtime to own the target workspace (`invocation.ex:121-140`, `workspace_owner_gate.ex:22-52`, placement local-only `workspace_placement.ex`); remote routing (deferred, §7) must **forward the opaque cap + authenticated presenter to the authoritative owner runtime**, where the single local verifier runs. No cap-on-`K` is ever verified off-`K`.
- **Blast-radius containment depends on §3.** The per-node claim only holds once keys are out of shared plaintext: a slice-resident key serializes into snapshots that a **system-scope query lists across all nodes** (`ecto/kind_snapshot.ex:44-64`) — so a shared-Repo node would NOT be limited to its own Kinds' keys. With §3's non-exporting compartment (owner-scoped storage / KMS, never in snapshots), **node compromise is contained to that node's live Kinds**. Placement transfer must atomically transfer or rotate the authority handle.
- Distribution then needs only ① remote transport/routing to the owner runtime and ② bootstrap root-anchoring — **neither is a cap-signing-model change**. This **unblocks** workspace-per-ECS, and is strictly better than v11's seed-on-every-node.

## 5. Bootstrap / genesis — one atomic, one-time, canonical-admin transition
The tension codex flagged: `K.grant` requires a pre-existing authority-cap-on-`K`, but "born signed" says every cap comes from `K.grant` — so seeding an anchor is either a mint *outside* `K.grant` (breaks sole-mint) or circular. Resolution: **one explicit, narrowly-scoped genesis exception.**
- **Genesis transition** — for a *never-initialized* `K` only: `K` internally generates its own key (into its non-exporting compartment, §3) and mints **exactly one** `K`-signed authority anchor naming the **canonical admin** (`Ezagent.Entity.User.admin_uri/0`), then **irreversibly seals genesis** (the transition can never run again for that `K`). This is the *single* explicit exception to ordinary `K.grant`; everything after goes through the normal cap-gated path.
- **Admin uses the same transition** to create its own self-anchor, after which genesis is permanently disabled system-wide. Root bottoms out at admin trusting itself — non-circular because the transition is a one-shot state change, not a cap-check.
- **Delete + arch-gate** every `{:genesis, arbitrary_uri}` authorization form (`cap.ex:21-27,169-172,227-229`). No caller may supply a root identity; the canonical admin URI comes from the single code authority, never a passed argument. No key is ever passed as a plain argument.

## 6. Cutover (ezagent-deploy scope)
Self-use, disposable data → **wipe + reseed**: quiesce → wipe cap-bearing data → deploy the new build → seed (admin first, then Kinds each get a fresh key + admin anchor; all caps re-issued signed) → resume. **No app-side migration/backfill code.**

## 7. Non-goals
- **Cap-storage consistency** (a cap in multiple homes, revoke-clears-all) — separate concern.
- **Full distributed transport** — the model SUPPORTS distribution; the routing/bootstrap-anchoring *implementation* is a separate track (deferred). The design must not preclude it (§4).
- Opaque cap representation — not needed here (verify is local at the target with its key, not a global boundary).

## 8. Implementation shape (high-level)
- **Per-instance key in a non-exporting compartment** (§3): generated at genesis into `K`'s private non-slice state (or a scoped keystore behind an opaque handle); never a slice field, never in snapshots/events/logs/admin-listings.
- **`sign(handle, cap)` / `verify(handle, cap, authenticated_presenter)`** — take the opaque authority handle, execute ONLY inside `K`'s dispatch process; the raw key is never returned or passed as a value.
- **The framework verifier** — the ActionSet macro declares immutable metadata; one `Kind.Runtime` verifier dominates every handler/state-mutating route (§2), consuming the **authenticated** presenter (not `ctx.caller`), and comparing the signed concrete `(instance, action, grantee)` against the live dispatch. Verify or fail-loud.
- **`K.grant` action** — unconditionally cap-gated (requires an authority-cap-on-`K`); on success signs and returns the new cap. Issuance = this one action, uniformly; no `cap_issued`/rule shortcut.
- **Genesis transition** (§5) — one-shot per `K`, canonical admin, self-sealing.
- **Authenticated presenter provenance** — derive presenter identity at the adapter/session boundary or from unforgeable internal dispatch provenance; stop trusting caller-supplied `ctx.caller` (`cmd.ex`, `router.ex`).
- **Delete**: dual-read / `verify_for` / default-off `require_signature` / the self-healer / v11's central-signer + public-keyring machinery / `{:genesis, URI}` / the `authz_check` cap_exempt·cap_issued·rule·`:vm_internal` bypasses for cap-gated actions.

## 9. Behavioral tests (the X holes, closed — each an INDEPENDENT assertion)
Per representative cap-gated action (session.send, create_session, PTY read, kanban write, world read_unfiltered…), each vector is its own test proving the attempt reached the authorization boundary and was rejected:
- **Forge** — an unsigned cap is rejected fail-loud.
- **Tamper** — a cap whose fields were mutated after signing is rejected.
- **Retarget** — a cap signed for a different instance/Kind is rejected under the live target's own handle; cap-controlled `key_id` cannot select another Kind's key.
- **Stolen-cap + spoofed-presenter** — a valid cap presented by a caller spoofing the grantee's URI via `ctx.caller` is rejected, because presenter identity comes from authenticated provenance (§1.5).
- **Wrong-target-key** — verification uses the live target's authority handle, not one selected by the cap.
- **Issuer-impersonation** — `K.grant` rejects a caller lacking a valid authority-cap-on-`K`; recursion to the canonical admin root is exercised and proven non-circular.
- **Genesis** — the one-time transition anchors each `K` to `admin_uri/0`, then re-invocation is rejected (sealed); strict verify holds end-to-end on a freshly seeded stack.
- **Key egress** — generic slice read, sibling read, raw read, snapshot, event, and admin-listing of `K` never return raw key material (only an opaque handle).
- **Legit** — a properly `K.grant`-minted cap, presented by the authenticated grantee, is accepted.

## 10. Gate plan (this is a first-class deliverable, not just tests)
Two enforcement layers, following the ezagent static-gate discipline (`check_invariants` → `ci.local` full-suite; run pre-push):

**A. Completion / invariant gate — behavioral, fail-when-the-goal-is-unmet.** The §9 vectors as **independent** `/goal`-style assertions on a freshly seeded stack (each proves the attempt reached the authorization boundary, not a shared monolith): forge, tamper, retarget, stolen-cap+spoofed-presenter, wrong-target-key, issuer-impersonation, genesis-seal, key-egress rejected; legit accepted. The forge/tamper/retarget cases **fail on today's `origin/main`** (dispatch authorizes via provenance+structural match without `Cap.verify`, `authorization.ex:6-18`, `kind/runtime.ex:539-545`; `require_signature` default-off, `cap.ex:42-63`) — that red proves each gates a real hole. (The positive `K.grant` path does not exist on `origin/main` yet, so the suite lands with the implementation, not before it.)

**B. Structural arch-gate — static AST/grep, enforces no-bypass, ratcheting.** In `check_invariants`, each property independently:
1. **Verifier dominance** — no handler or state-mutating dispatch route is reachable without the single framework verifier; the verifier is the sole authorization decision.
2. **No bypass flags** — no target-cap-gated action carries `cap_exempt_actions`, `cap_issued`, an `authorization_rule` allow, or `:vm_internal`; the `cap_issued`/rule grant shortcuts are deleted.
3. **Sign/verify confinement** — the crypto primitive is referenced ONLY through the K-owned authority module; `sign` only from `K.grant` + genesis; `verify` only from the framework verifier. Direct `:crypto`/`Signing` calls and dynamic invocation cannot reach it.
4. **Declaration parity** — every cap-gated action declares its cap requirement (leverages existing required-cap coverage check, `behavior.ex:307-318`).
5. **Key egress absence** — the key field appears in no slice schema, snapshot serializer, event, log, or admin-listing path; only opaque handles cross those boundaries.
6. **Presenter authenticity** — the verifier's presenter comes from authenticated provenance; no path lets a caller-supplied `ctx.caller` stand in for it.
7. **Unique target-key binding** — verification uses the live target instance's handle and exact `(instance, action, authenticated presenter)`; no cap-controlled key selection.
8. **Genesis** — exactly one mint exception, one-shot, fixed to canonical `admin_uri/0`; every `{:genesis, URI}` path removed.

**Honest enforceability limit** (carried from v11): caps are public Elixir structs, so *discovering arbitrary semantic field reads* is best-effort AST — but that limit does NOT excuse leaving explicit runtime bypasses or plaintext-key egress ungated (codex round 1). Those (properties 1–8) ARE statically enforceable and gated. The residual best-effort surface is only "some code pattern-matches a cap field for a non-authorization purpose"; the authorization guarantee itself is runtime (the single verifier) + these ratchets. Verification collapsing to ONE framework verifier and minting to ONE `K.grant` keeps the scan surface minimal.

## 11. Open (impl-level)
- The non-exporting compartment mechanism: private `Kind.Server` state vs a scoped keystore process behind an opaque handle; symmetric primitive (HMAC vs a symmetric AEAD/MAC).
- Where the framework verifier hooks in `Kind.Runtime` (relative to today's `authz_check`, `kind/runtime.ex:142-162,319-361`) and how internal-only provenance is minted unforgeably.
- The authenticated-presenter source of truth: which adapter/session boundary stamps it, and how internal dispatch carries unforgeable provenance instead of `ctx.caller`.
- admin-root key custody (owner-scoped storage / KMS) + version scheme; the exact genesis-seal state marker.
- Bootstrap sequencing (admin genesis before any Kind anchors); enumerating today's `{:genesis, URI}` and bypass-flag call-sites to delete.
