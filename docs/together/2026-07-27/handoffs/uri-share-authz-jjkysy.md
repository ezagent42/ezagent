# Handoff → jjkysy: unified URI-share / delegation authz

**Owner: jjkysy** (this is your proposal — PR #1583 — and your implementation). This doc does NOT replace your
own design `docs/together/2026-07-27/handoffs/socialware-share-generalization.md` (on `feat/kanban-collab-round2`
/ #1474) — it **records the PO decisions + the main-verified factual corrections + the kanban residual worklist**
so you can finalize your design against them. **Decomposition, PR-split, sequencing, and the two hard design
questions are yours to decide.** cc will NOT modify this after handoff — it's yours.

## The goal (unchanged from your proposal)
One **URI-agnostic share/delegation primitive** in the cap/identity layer that every domain/plugin uses to
share a URI's resource, instead of each biz re-composing cap-mint + cap-holder-query + share-token +
request/approve. Backend treats all URIs uniformly (share ≡ delegate a cap toward a URI, scoped to that
resource's actionset: read/operate); the use-layer renders per business (session = invite/join; kanban =
access+operate the board URI). Consistent with actor-isolation (the just-shipped #201 A-full lesson:
consolidate a core concern into ONE owner-gated primitive; don't let each plugin re-build it).

## PO decisions (Allen, 2026-07-27) — fixed constraints
- **(甲) Unify on cap-as-truth / person-cap.** Holding a cap ≡ having the access; upgrade/downgrade =
  mint/revoke an action-scoped cap. A unified URI-share goes through the **person-cap model (bearer → mint)**;
  session's live-membership participation semantics are a use-layer rendering of the same caps, not a second
  mechanism. **Correction (verify against main):** the "member truth" is holding the **tier-1 member/receive
  cap**, NOT `session.join` — `:join` is a single-use tier-0 entitlement consumed at join (`member_cap.ex`,
  invariant M-9 in `check_invariants.ex`). cap-as-truth is already invariant-locked.
- **(乙) Access = holding a cap toward the URI, never an auto-created display session.** **Correction (main
  verified):** your proposal's premise "creating a resource/agent auto-creates a display-only owner-session"
  does NOT hold on current `origin/main` — the standalone socialware-session Kind was deleted (P5-1b substrate
  collapse), `resource://` is not a creatable stateful Kind, `create_session` is a separate
  `caps:[:create_session]` action (not chained off `create_agent`), and agent creation writes only a **latent,
  cap-gated `session_templates` blueprint** (`agent_create.ex`), with template-read (`template_reads.ex`) and
  session-listing (`workspace_reads.ex`) both authorizing the caller first. So (乙) becomes a **non-regression
  guard** + close the two REAL residuals: `KanbanRender.boards_for/1` (`kanban_render.ex:113`, a render path
  with no caller / no cap-filter) and the `:members` roster (already a cap-derived projection — confirm).

## Main-verified corrections to your proposal's inventory (build on these, not the originals)
- **Reuse base is bigger than framed:** `mint_cap/4` (`composition_caps.ex:140`, the single non-bypassable mint
  chokepoint, granter ≡ `data_owner`) + `Mount`/`MountRow` with the person-scope axis `mount_for_person/5`
  (`mount.ex:97`) already constitute a URI-agnostic "grant a cap toward a URI + durable record" primitive. The
  gaps are peripheral glue.
- **Share tokens: 6 salts exist but only 2 are genuine URI-shares** — `DownloadToken` (grantee-bound,
  `download_token.ex:199`, type-locked to `uploads`) and kanban `world_kanban_share` (pure bearer). The other 4
  (chat-feed identity, upload anti-laundering grant, hello continuation, anon cookie) are NOT URI-shares —
  exclude them.
- **Visibility: 4 bespoke sites, not 3** — the agent one (`workspace_reads.ex:132`) was missed; **`caps_toward`
  does not exist** and **`union_cap_boards`** is kanban-private (hardcodes `behavior: Ezagent.ActionSet.Kanban`,
  `world_data.ex`). The real duplication = divergent enumeration sources + 3 different caps-loading paths.
- **`CompositionConsent`** state machine + `pending_for_owner/1` owner-todo-box are URI-agnostic; ONLY its entry
  is composition-bound (`sync(%CompositionBinding{})`, `command(binding_id, session_uri, …)`) — that's what you
  generalize to accept `(grantee, target_uri, actions)`.

## The primitive to build (your 4 pieces, corrected)
1. A generic **bearer share-token axis** (generalize `DownloadToken` beyond `uploads`, or a sibling) — retires
   the 6 hand-rolled salts down to 2 real ones on one seam.
2. A generic **`caps_toward(holder, behavior)` reverse index** — retires the 4 bespoke visibility enumerators
   (today `EntityCaps` only has whole-bag `load/1`; no reverse holders index).
3. A generic **`/socialware/claim` receiving landing** (plugin-registrable) — retires the per-plugin claim
   controllers.
4. **Generalize `CompositionConsent`'s entry** from `CompositionBinding`+`session_uri` → `(grantee, target_uri,
   actions)` — so any URI's owner-todo-box + approve/deny state machine is reused.

## kanban residual burn-down (AFTER the primitive lands)
kanban is **already ~decomposed on #1474** (board_provision moved domain→plugin; `Mount`/`MountRow` deleted;
share controller thinned). Only its **authorization layer** is the true remaining "infra was missing a seam"
(X) — 3 bespoke bits to point at the new seams:
- **bearer token** (salt `"world_kanban_share"` hand-aligned across `kanban_share_controller.ex` +
  `world_share_actions.ex:28-30`) → piece #1.
- **rule-8 approval** (`world_share_actions.ex:187-244` `approve_edit_result` — mints via `CompositionCaps.mint_cap`
  correctly but **hand-rolls the request/approve workflow, bypassing `CompositionConsent`**) → piece #4.
- **`union_cap_boards`** (hardcoded `behavior: Kanban`) → piece #2.
(Note: hello is NOT a template for this — hello's share just posts a URL string, never mints a cap. The template
is this primitive + `CompositionConsent`.)

## #1474 — your call
Whether/when to merge #1474 is yours. **Recommended order:** complete the URI-share primitive first → **rebase
#1474** onto it → merge, so kanban's residuals land ON the primitive rather than before it exists. #1474 is
already correctly scoped (doesn't over-extend the bespoke set; explicitly defers the authz generalization to
this infra PR) — no re-scope needed.

## Left to you (do not treat as decided)
- **Token binding model: grantee-bound vs pure bearer** (the crux for the generic share axis).
- **How to unify the 4 visibility enumeration sources** behind `caps_toward`.
- Decomposition / PR-split / sequencing of the primitive + the residual burn-down.

## Acceptance-invariant sketch (recommended)
An enumerator/drift gate modeled on `attachment_plane_chokepoint_boundary_test.exs` (AST/allowlist, empty-run =
the exhaustive absorb worklist): fail if a plugin re-builds share-token signing / cap-mint / cap-holder-query /
request-approve OUTSIDE the primitive — so the "next shareable thing = zero duplicate code" property is enforced,
not just documented.
