# dev-together process improvement — stop tasks returning incomplete / divergent

> **Purpose:** grill artifact (per @林懿伦 2026-06-24). This analyzes the **process**
> (the dev-together skill), NOT the specific code of #956/#958. Goal: make it
> structurally hard for a task to come back **not finished** or **finished but not
> matching the goal**. Nothing here is applied to the skill yet — we grill first.

## 1. The evidence (today's three incidents)

| Incident | Surface symptom | What actually happened |
|---|---|---|
| **#956 hello** | "returned done", but never-green on its own tip | Failed `compile --warnings-as-errors` + **6** tests/gates on its own parent commit (its own generator/Spec tests stale vs its own shadcn migration; arch caps tripped). The lead found this only at `close`. |
| **#958 agent-console** | thorough return, "READY TO MERGE", but feels unfinished | Backend CRUD solid + tested **at the Invocation seam**; the **operator console UI/route has 0 automated tests** (a route 404 slipped to manual E2E); repoint UI deferred, echo unsupported, generic kv-editor vs "every field". DoD met a **re-scoped subset**, not the goal. |
| **official-site** | merged, but the page renders broken/ugly | #956 migrated the **backend** catalog to 36 shadcn types + its tests; the **frontend** renderer was never migrated. Per-layer tests passed; the **product** is broken. Classic "green tests, broken product". |

## 2. Root cause — one meta-failure, three faces

> **"Done" is self-asserted by the developer, against an author-chosen (often
> subset) Definition of Done, verified at the wrong layer or only once (a
> one-shot screenshot), with no machine-checkable gate between `return` and
> `close`.**

So the only thing standing between a not-really-done task and `main` is the
lead's diligence at `close` — which is **late** (work already "returned"),
**expensive** (lead re-derives the real DoD + re-runs everything), and
**silent-failure-prone** (if the lead is busy, it slips, as the official-site
desync did).

The three faces:
- **Self-asserted gates** (#956): "all gates green" was prose, not proof. Nobody re-ran it until `close`.
- **Author-subset DoD** (#958): the dev measured "done" against the handoff's literal items + its own deferrals, not against the goal; and adjudicated its own "READY TO MERGE".
- **Wrong-layer / one-shot verification** (#958, official-site): a backend-seam test + a manual screenshot "demonstrate" the feature without a regression test through the real user-facing surface, and without an end-to-end product proof for cross-layer changes.

## 3. What the process already gets right (change surgically, don't rewrite)

The skill is not naive — these rules exist and are good:
- **DoD = demonstrable artifact** ("tests pass is necessary, not sufficient"; UI→screenshot, agent→real-channel transcript).
- **Gates green + the work's own invariant test** (in both `return` and `close`).
- **Adversarial review before build** (discuss-first triggers) — catches wrong-approach.
- **Per-task branch + lead is the only path to `main`** — one accountable integration point.

The incidents didn't happen because these are missing; they happened because each
is **self-reported and checked too late**, the DoD is **author-defined**, and the
**verification layer/durability** isn't pinned.

## 4. Where each incident slipped a specific existing rule

- `return.md` step 1 *says* "all gates green + own invariant test passes" — but it's a **prose claim by the dev**, with no artifact. #956 claimed it falsely.
- `handoff-standard` *says* UI→agent-browser screenshot — #958 gave screenshots, but a **screenshot is a one-shot, not a regression test**, and it tested a happy path while the **route** itself 404'd. The rule didn't demand an automated test *through the surface*.
- `handoff-standard` defer rules *say* "deferrable only when flagged with a target" — but they let the **dev** flag-and-proceed; #958 self-declared "READY TO MERGE" while deferring repoint UI + echo. **Who adjudicates the deferral** is unspecified → defaulted to the dev.
- Nothing requires the DoD to be **enumerated from the goal** (a superset of what a reviewer checks). #958's DoD was a convenient subset; the official-site migration's DoD never listed **frontend↔backend parity** at all.

## 5. Proposed process changes (6) — process only

Each: the rule, the incident it kills, where it lands in the skill.

**P1 — The return gate is machine-checked, not prose. (`return.md`, `handoff-standard`)**
A `return` is invalid unless: (a) the PR's CI (`precommit + check_invariants`,
now live + branch-protected) is **green on the PR head**, and (b) the branch is
**rebased onto current `main`**. The return block must carry the **CI run URL +
green status** and the **rebase base SHA** — not the words "gates green".
*Kills #956 (never-green / stale).* CI now makes this structural; the skill must
codify it so a red/stale branch can't even be `return`ed.

**P2 — DoD is goal-derived and enumerated by the LEAD, and the dev can't narrow it. (`handoff.md`, `handoff-standard`)**
The handoff states the DoD as a **closed, checkable list derived from the goal** —
every sub-capability the goal implies. For **migration/replacement** tasks the
list is **enumerated from the source of truth** (e.g. "frontend catalog == backend
catalog", parity diff == ∅), not hand-picked. `return`/`close` check **every
line**, each with its own evidence. A dev may *defer* a line (see P4) but may not
*delete* it.
*Kills #958 subset-done + the official-site missing-parity-line.*

**P3 — Verify at the user-facing layer, with an automated regression test. (`handoff-standard`)**
The demonstrable artifact for a UI/feature must include an **automated test through
the real surface** (LiveViewTest that mounts the route / agent-browser script that
drives it) that **fails if the feature breaks** — the screenshot is the human-
readable companion, not the proof. Seam/unit tests alone do not satisfy a UI DoD.
*Kills #958's wrong-layer coverage (the route-404 a UI test would have caught).*

**P4 — Deferrals are lead-adjudicated, never dev-declared. (`return.md`)**
If a return defers any DoD line, its `deadline_status` is **`deferred`** (never an
implicit "READY TO MERGE"), and each deferred line is listed as an **explicit open
decision for the lead**. "Ready to merge" is the **lead's** verdict at `close`,
not the dev's at `return`.
*Kills #958's self-adjudicated scope.*

**P5 — Cross-layer changes carry a parity checklist + an end-to-end PRODUCT proof. (`handoff-standard`)**
When a change spans a contract and its consumers (backend catalog ↔ frontend
renderer; schema ↔ migration ↔ UI), the handoff must (a) enumerate the parity
items from the contract and (b) require an **E2E proof of the actual product**
(generate → render → eyeball/screenshot), not just per-layer unit tests.
Backend-only "done" on a cross-layer task is rejected at `return`.
*Kills the official-site "green tests, broken product" class.*

**P6 — The close review feeds the skill. (`review.md`)**
Every `close`-review finding names (a) the gap, (b) the owner, and (c) **the
process rule (existing or new) that would have caught it**. A finding with no
mapped rule is a signal to add one. This makes the retrospective a closed loop
into dev-together, not just a list of complaints.

## 6. The shape of the fix (one sentence)

Move the "is it really done?" check **earlier and onto a machine** (P1, P3), make
**the lead own the DoD and the deferral verdict** (P2, P4), and make
**cross-layer + migration tasks prove the product, not the layer** (P5) — so
`close` becomes a confirmation, not the first real inspection.

## 7. Open questions for the grill (where I'm unsure)

1. **Cost vs friction (P1/P3):** CI-green-as-return-gate adds ~15 min/return and
   an automated-UI-test burden. For tiny/mechanical tasks is that overkill? Do we
   tier it by task size, or hold the line uniformly?
2. **Who writes the goal-derived DoD (P2)?** The lead authors handoffs — but the
   lead may not know every sub-capability up front (the official-site frontend
   parity wasn't obvious until the backend landed). Is P2 a lead duty, or a
   **dev-proposes-DoD → lead-ratifies** handshake at `dive`?
3. **"Every field / parity == ∅" (P2/P5)** can be a moving target as the contract
   evolves. Do we freeze the parity list at handoff time, or re-derive at return?
4. **Agent devs vs human devs:** these incidents were agent-authored returns
   (codex/cc). Should the gates differ by dev kind, or is uniform better?
5. **Does P4 (lead adjudicates deferral) re-centralize too much** on the lead and
   slow the fleet? What's delegable?
6. **Enforcement vs guidance:** P1 is now structurally enforceable (CI + branch
   protection). P2–P5 are still *discipline*. Which of these can become a
   **mechanical gate** (a checklist the `return`/`close` scripts validate) vs a
   judgement we just write down?

---

## 8. GRILL CONCLUSION — locked design (with @林懿伦, 2026-06-24)

The grill reframed the root cause and resolved every open question. Locked:

**Reframed root cause (Allen's upstream axis).** "Tasks sliced too big" is the
*symptom*; the disease is **handing off a BUILD task while its scope / requirements
/ feasibility are still unknown**. So there are two complementary axes — **upstream
scoping/research** (owns *divergence*: #958, official-site) and **downstream
verification** (owns *never-green / green-tests-broken-product*: #956). Upstream is
more fundamental: a tight DoD + machine gate on a mis-scoped task just rigorously
verifies the wrong thing.

**dev-together is already a PDCA loop** (`plan`/`handoff`=Plan, `dive`/`return`=Do,
`push`/`close`=Check, `review`=Act). We do **not** import a new framework; we
**complete the loop we have** by adding two phases that were implicit/weak —
**without adding new commands** (vocabulary stays at 8; we add one task flag + one
return field).

### Locked decisions
1. **Front phase = clarify/research (the missing "Study/Clarify").** When a task
   hits the **existing discuss-first triggers** (reused as the tiering criterion),
   that round's `handoff` is a **research handoff** (deliverable = findings +
   proposed build slices + **the DoD**), lead-ratified, **before** any build
   handoff. The research task reuses `dive`/`return`. New surface: a `clarify_first`
   task flag (auto-lit by the triggers). **Tiering:** triggers miss → fast path
   (`plan`→build→CI gate→merge); small/mechanical work is not forced through the
   full loop.
2. **DoD = four properties** (replaces "DoD = a demonstrable artifact" in
   `handoff-standard`): **(a) goal-derived** (enumerated from the goal; for
   migration/replacement, from the source — parity diff == ∅), **(b) verifiable +
   carries its proof**, **(c) at the user-facing layer** (UI → a LiveViewTest
   mounting the route / agent-browser driving it; a screenshot is a human-readable
   companion, not the proof), **(d) a closed set** (a dev may *defer* a line, never
   *delete* one; done = every line green). Litmus: if all lines pass, a fresh
   reviewer agrees the **goal** is met with nothing important unproven
   (superset-of-human-review). **The research front-phase is what produces this
   DoD** — it is unknowable before research (the lead couldn't have known echo
   needed #918).
3. **Back phase = method-writeback (capture → promote).** The skill is a
   single-writer team contract, so the **dev does not edit it**. Instead: **capture
   (dev, at `return`)** via a mandatory **"DoD reconciliation"** field — *every*
   return fills it (even "DoD fully met" is signal): was the DoD met? where did it
   diverge / what was deferred? what was unknown at handoff that should have been
   clarified first? **Promote (lead, in `review`)** — triage the reconciliation
   signal; real method gaps become a **dev-together PR** (or tracked process-debt).
   `review.md` gains a **mandatory "method deltas" section** (even "none"), so
   skipping the learning step is visible. Bonus: the DoD-reconciliation field also
   surfaces **divergence at `return`** (the diverging dev is first to know),
   instead of at `close`.
4. **Verification axis stays (sizing doesn't fix #956):** the `return` gate is
   **machine-checked** — PR CI (`precommit + check_invariants`, now live +
   branch-protected) green on the PR head + branch rebased onto current `main`;
   "gates green" prose is no longer accepted. **Deferrals are lead-adjudicated**
   (`deadline_status: deferred` + the deferred lines listed as open decisions);
   "READY TO MERGE" is the lead's verdict at `close`, never the dev's at `return`.
5. **Cross-layer / migration tasks** carry a parity checklist enumerated from the
   contract + an **end-to-end product proof** (generate → render → eyeball), not
   per-layer unit tests alone. Backend-only "done" on a cross-layer change is
   rejected at `return`.

### Where it lands in the skill
- `references/handoff-standard.md` — replace the DoD section with the four-property
  definition; add the research/clarify front-phase + tiering; add the cross-layer
  parity + product-proof rule.
- `commands/handoff.md` — the `research handoff` mode + `clarify_first` flag.
- `commands/return.md` — mandatory **DoD reconciliation** field; machine-checked
  return gate (CI green + rebased); lead-adjudicated deferrals.
- `commands/review.md` — mandatory **method deltas** section; capture→promote.
- `SKILL.md` — name the two phases + the tiering criterion; note CI as the
  structural return gate.
