# Fan-out principal elimination — design (chat-reply / chat-router / session-internal + per-session caps)

**Date:** 2026-06-19 · **Status:** design (the remaining hard 6 of the #154 north-star). **Not yet implemented.**

After the clean re-attributions (worker-publish / agent-internal / workspace-loader / mix-task /
orchestrator-tools → ratchet 6+genesis), the remaining principals are NOT mechanical re-attributions —
they need a **new grant/feature**, and they intersect a refactor that already failed once
(`feat/per-session-default-caps`, 8 join-authorization failures, reverted). This note grounds the design
so implementation doesn't repeat the failure.

## The partition (advisor, 2026-06-19)
- **Subagent-safe** = pure re-attribution: `caller → existing real entity + inline ctx.caps cap`. (Done: the 5 above.)
- **Design-first** = needs a NEW grant. The fan-out send/receive caps are here.

## What the prior `feat/per-session-default-caps` branch (commit e5b51888) did, and why it failed
It removed `User.default_caps/1`'s broad `cap(:session, behavior: :any, action: :any, instance: :any)`
baseline (granted by `system://bootstrap`) and replaced it with a **per-session participation grant at
join** (`Membership.grant_participation_caps/3`): for a USER member it grants, scoped to the concrete
session, `cap(Session,:send)` + `cap(Session,:leave)` + `cap(Publisher.SessionImpl,:subscribe_from)`,
under `{:rule, :session_participation, owner}` (owner = configurer + `granted_by` entity), via `:async`
(`:cast`) router dispatch (best-effort, errors swallowed — and the `:cast` dodges the
Session→IdentityAdmin→`Session.owner`→`get_slice` **deadlock**, the same hazard `grant_first_join_owner_cap`
documents). No-ops for non-users / anon / ownerless.

**Why it failed (the 8 failures):** the **join chicken-and-egg**. `Session.join` is itself cap-gated, and
the cap that authorized *joining* came from the broad `default_caps` baseline that was being removed. The
participation caps are granted *at/after* join — but you need authority to join in the *first* place. Remove
the baseline and self-join paths lose join authority before the per-session grant can run.

**The crux to fix before re-attempting:** join authority must come from **the entity ADDING the member**
(owner/orchestrator-mediated add), or the **first-join-becomes-owner** self-authorized path — NOT from a
pre-held broad baseline on the joiner. Audit the 8 failing paths: each is a self-join that relied on the
baseline. Either (a) route those joins through an inviter's authority, or (b) keep a *narrow* `Session:join`
(only) baseline and per-session-grant the rest. (b) is the smaller, safer move and is likely the intended
shape — narrow the baseline to `join`-only rather than to empty.

## Per-principal elimination design

### chat-reply (4 sites: curl_agent, codex/echo/np bridge adapters) — agent SEND
Agents reply into their session. Today agents hold NO send (Agent default `initial_caps` is empty by design,
"chat receive only") so the bridge adapters borrow `system://chat-reply`. **Fix = provision the agent its own
session-scoped `cap(:session, Session, :send, instance: session)` at SPAWN** (the advisor's spawn-time path —
sidesteps the join deadlock entirely, since spawn already carries session context). Granter = the spawner
(orchestrator/owner) → **`entity://system/user/admin` fallback for ownerless** (the established
`anon_user.public_view_granter/1` precedent). Then the 4 bridge adapters use the agent's OWN caps instead of
chat-reply. This is the #17/per-agent provisioning seam (`initial_caps_for_spawn` is on User today; Agent needs
the equivalent threaded with the session URI at spawn). Deletes `chat-reply`.

### chat-router (3 sites) — receive fan-out + cross-session forward + sync_result
- `agent/receive.ex:280` **sync_result** → re-attribute to the agent's OWN authority (self; the agent returning
  its own result). Likely subagent-safe inline cap once isolated.
- `delivery.ex:140` **receive fan-out** (`dispatch_receive_call`, `caller: session_uri`) — the SESSION delivers
  `<entity>.receive` to each MEMBER. The prior branch deliberately KEPT chat-router here ("receive is NOT a
  member cap"). Options: (a) **membership-gated cap-exempt** — flip `User.Receive`/`Agent.Receive`
  `data_owner→:no_owner` + `cap_exempt_actions→[:receive]`, gated UPSTREAM by the Resolver `valid_member?`
  filter (the fan-out loop is the ONLY dispatcher of `:receive` — verified); or (b) **member receive cap**
  granted at join, `granted_by` member (self-consent). (a) widens the trust surface (advisor caution); (b) is
  in-CapBAC but adds another join-grant. Lean (b) for north-star purity IF the join chicken-and-egg fix above
  lands; else (a) as a scoped, documented exemption.
- `delivery.ex:80` **cross_session_forward** (Decision #97) → `{:rule, :cross_session_forward, created_by ||
  ws-admin}` + **same-workspace guard** (target ws == source ws). **Grep-verified safe:** zero cross-workspace
  `cross_session_forward` dependents; every `cross_workspace` ref in the tree is a reject-guard — the guard is
  consistent with the existing posture, not a #97 regression.
Deletes `chat-router` once all three move.

### session-internal (MIXED — verify each site, NOT workspace-loader-class)
- `template_team.ex:214` + `materializer.ex:167` — session **creation/materialization** → the CREATOR's
  authority (orchestrator/owner doing the materialize), not a self-dispatch. Verify the creator URI is in scope.
- `legends.ex:114` (`system_set_legends`) + `config_actions.ex:135/166` — session acting on its OWN
  legends/config slice. **Check for self-dispatch deadlock** (session → itself); if self-dispatch, use the
  inline-self-cap pattern (like agent-internal's `do_record_sandbox_state`) which also dodges the deadlock.
- `home_live.ex:213` — a LiveView read → use the **viewing user's** authority (the LV already has
  `current_entity_uri`), not an ambient principal.

### Anon family (lv-anon-mount, socialware-gc) — fold with #51
- `lv-anon-mount` — the LV anon-mount caller; ties to the #51 anon-entity model. The real anon access path
  already self-caps (`anon_user.mint_for_public_session` mints the anon its OWN join cap); migrate the LV mount
  caller off the principal to the anon's own authority.
- `socialware-gc` — the GC sweeper reaps abandoned anons via `chat.leave`. Re-attribute to either the anon
  leaving itself (self-authority) or `{:rule, :anon_gc, admin}` (system-policy). Same owner→admin precedent.

### bootstrap (genesis, LAST)
`system://bootstrap` → `entity://system/user/admin`. The irreducible primitive; collapse only after all others.

## Recommended sequence
1. **(design-first, me) Per-session user participation caps** — re-land the reverted branch with the
   join-chicken-egg fix (narrow `default_caps` to `join`-only, not empty). Independent of fan-out; unblocks the
   "grant-at-join" machinery the receive option (b) reuses.
2. **chat-reply** — spawn-time agent send cap (per-agent provisioning seam). Subagent-assistable once the seam exists.
3. **chat-router** — sync_result (self) + cross_session_forward (rule + same-ws guard) + receive (option b if (1) lands, else (a)).
4. **session-internal** — per-site (creator / self-cap / viewer authority).
5. **Anon family** (lv-anon-mount, socialware-gc) — fold with #51.
6. **bootstrap** genesis collapse — last.

**Open decision for Allen:** (1) is the refactor that failed before — re-land now, or review the design first?
Default per AFK mandate: proceed with this design, narrow-baseline fix first.
