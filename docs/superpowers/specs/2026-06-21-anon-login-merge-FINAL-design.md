# anon→login identity merge (physical relabel) — FINAL design

> Status: FINAL design (brainstormed + dual-adversarial-reviewed [Claude + codex] with Allen
> 2026-06-21). Closes #68. Supersedes the per-session cap-gated takeover on `feat/jia5-anon-takeover`
> and the rejected URI-alias resolve-chokepoint (A′) approach.
> **Depends on PR-1 (message session-scoping)** — see companion design
> `2026-06-21-message-session-scoping-design.md`.

## 1. Goal
When an anonymous viewer (`anon` = a registered user with `confirmed: false`, read-only,
public_view) **logs in**, physically relabel the anon's footprint → the confirmed login entity, then
delete the anon — seamless, with zero surviving `anon_uri` references. Bounded surface: `AnonBinding`
is one-anon-⇄-one-session for life, so the entire footprint is within ONE session.

## 2. Two end-states (unchanged)
- **Abandoned** (never logs in): existing `AnonUser.GC`/`Sweeper` 48h reap — UNCHANGED.
- **Logged-in** (this design): physical relabel → clean delete.

## 3. The relabel surface (all within the anon's one session)
| Reference | Storage | Relabel via |
|---|---|---|
| Membership | live Session Kind `:members`/`:last_seen`/monitors slice | `Session.merge_member/2` (§4) |
| **`:last_message` snapshot** | the SAME Session Kind slice (carries a `%Message{}`) | `Session.merge_member/2` rewrites it in the same atomic effect set — **resolves review B1** |
| Read markers | `read_markers.user_uri` rows | `ReadMarker.repoint/3` (reuse jia5) |
| `@`-mentions of the anon | `messages.mentions` (session-scoped after PR-1; `sender` defensive — anon never authors) | `MessageStore.relabel_identity/3` (§5) |
| anon's own `join_cap` | anon `caps_json` | dropped on anon delete |
| `AnonBinding` row | `socialware_anon_bindings` | deleted on anon retire |

Because PR-1 makes messages **session-scoped** (no multi-routing), relabeling `mentions` within the
session is safe (no cross-session corruption) — **B3 dissolved**. Every reference relabeled → anon
ends with zero surviving refs → **clean delete, NO safe-linger**.

## 4. `Session.merge_member(from_uri, to_uri)` — atomic slice relabel (B1)
A `Behavior.Session` action running INSIDE the Session Kind (like `handle_join`), emitting ONE effect
set that atomically updates the `:chat` slice:
1. compute post-dedup membership via a **direct `do_join` composition helper** (NOT by dispatching
   `handle_join`, whose already-online branch returns empty effects — review MED-7): if the login user
   is already a member, merge metadata deterministically; else add them (mount of confirmed-tier caps
   is done OUTSIDE the Kind — see §6/H4);
2. remove the anon key from `:members`/`:last_seen`, demonitor the anon;
3. **rewrite `:last_message`** if it carries the anon as sender/mention (B1);
4. emit `member_joined`/`member_left` events the live feed depends on.
`ReadMarker.repoint(session_uri, anon_uri, login_uri)` is triggered as part of the merge (reuse jia5
Task 2) — but see §4a for atomicity. `merge_member` stays **socialware-symbol-free** (review #5);
the anon retire (socialware) is the orchestrator's job (§6).

## 4a. Cross-store atomicity (B2) — idempotent merge + claim/repair
The merge spans 3 stores (Kind slice [memory+snapshot] · `read_markers` DB · `messages` DB) — NOT
atomically committable together. So make it **idempotent + recoverable**, like the `AnonBinding`
reaping claim:
- A durable **merge-claim** record (e.g. on `AnonBinding`: `merging_to`, `merge_state`) marks the
  merge in-flight; each step is idempotent (re-runnable).
- The anon is **deleted ONLY after a verify step** confirms BOTH the Kind membership AND the DB
  relabels (read_markers, messages) have converged. A crash mid-merge leaves a claimed, repairable
  state (a repair pass re-runs the unfinished steps); never a half-merged delete.

## 5. `MessageStore.relabel_identity(session_uri, from_uri, to_uri)` (sanctioned mutation)
`Message` is a plain Ecto schema; `MessageStore` already has ONE controlled mutation precedent
(`mark_visibility/2`). Add `relabel_identity/3` as its sibling — the SINGLE sanctioned way a message
row is rewritten for an identity merge: rewrite `sender` (defensive) + `mentions` entries from→to.
**Safe after PR-1** (session-scoped messages: the row belongs to one session). Authz lives at the
merge orchestrator (§6), not on Message.

## 6. Trigger + authority (H4/H5/H6)
- **Single post-auth hook** (review HIGH-5): all THREE login paths (`session_controller` credentials,
  `magic_link_controller`, `registration_controller`) converge on `SessionPrincipal.put/3` — hang the
  anon-merge on ONE shared hook there so coverage is complete. It fires only on a **verified signed
  anon cookie**.
- **`AnonCookie.verify_any/1`** (H5): the current `verify/2` needs an already-known `session_uri`,
  which a generic login request lacks. Add `verify_any/1`: verify the signature → return
  `{anon_uri, session_uri}` → confirm `AnonBinding.get(anon_uri)` matches.
- **Authority = signed-cookie POSSESSION + binding confirm** (H6): the proof is the signed cookie
  (128-bit random anon name + HMAC), NOT mere `AnonBinding` row existence (which a non-possessor could
  observe). Never select `anon_uri` from request params / member lists / binding existence alone.
- **Caps caller-side** (H4): the orchestrator (web/socialware layer, outside the Session Kind)
  provisions join authority (jia5's `provision_join_authority`) BEFORE dispatch and mounts confirmed
  participation caps (`mount_participation_caps`) AFTER a successful merge. `merge_member` stays
  slice-only (avoids the Kind self-deadlock the existing code deliberately prevents).
- **No new cap axis** (review LOW-8): do NOT reintroduce jia5's persisted `:takeover` cap; authority
  is the named-orchestrator model above. No `system://` principal (#154; passes p13 + cap-elim gates).

## 7. The orchestrator (where it all comes together)
A socialware-layer `AnonTakeover` orchestrator (sees both web-cookie + socialware `AnonBinding` +
session dispatch) invoked by the post-auth hook:
1. `verify_any` the cookie → `{anon_uri, session_uri}` + binding confirm;
2. claim the merge (B2);
3. provision join authority + dispatch `Session.merge_member(anon, login)`;
4. `MessageStore.relabel_identity(session, anon, login)`;
5. mount confirmed caps for login;
6. verify convergence → retire anon (`Users.delete` + `AnonBinding.delete`, reuse GC reap primitives);
7. clear the claim.

## 8. #154 / gates
No `system://` principal; `granted_by` = real entities. Passes `system_principal_elimination` /
`no_unowned` / `no_admin` / `no_wildcard` / p13 (no `== admin_uri()`) / `check_invariants` /
`arch.scan` / `doc.scan`. Each PR: implement → codex adversarial review → full gate suite +
agent-browser E2E (anon browses public session → logs in → footprint claimed) → merge.

## 9. Acceptance (closes #68)
An anon views a public session, logs in (any of the 3 paths); their membership + read-markers +
mentions are now under the login entity; the anon user + binding are gone; no dangling `anon_uri`
anywhere; a non-possessor cannot trigger a merge; gates green.

## 10. Cross-references
- Prereq: `2026-06-21-message-session-scoping-design.md` (dissolves B3).
- Reuse: `ReadMarker.repoint/3`, `mount_participation_caps/2`, `provision_join_authority`,
  `MessageStore.mark_visibility/2` (precedent), `AnonUser.GC` reap primitives, `AnonCookie`.
- Supersedes: jia5 plan (#68); A′ analysis (git history, design/uri-alias-anon-merge @ cb069bd3).
