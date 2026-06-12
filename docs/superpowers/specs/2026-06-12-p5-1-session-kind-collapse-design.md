# P5-1 Session-Kind Collapse — Design (brainstorm draft for Allen 拍板)

> Draft produced overnight 2026-06-12 to give P5-1 the deep cross-app dependency
> analysis the decomposition spec's P5 section lacked. Pending: P5-1a data point
> (customer-delivery move cleanliness), codex adversarial review, Allen decisions.

## Problem

Today there are TWO Session Kinds, both `kind_type "session"`:
- `Ezagent.Entity.Session` (chat) — in `ezagent_domain_instance_message` — `behaviors/0 = [Session, Publisher.SessionImpl, ExternalMirror]`.
- `Ezagent.Entity.SocialwareSession` — in `ezagent_domain_socialware` — `behaviors/0 = [Session, Turn, Surface, Publisher.SessionImpl]`.

P5-1 collapses them into ONE parameterized Session Kind whose `behaviors/0` is the UNION `{Session, Publisher.SessionImpl, ExternalMirror, Turn, Surface}`; Templates select the per-instance subset via P1's `BehaviorSet.init_set/2` + the `:kind_base` slice; the load-bearing gate is **P1 per-instance denial holds on the superset Kind** (a chat instance denies `turn.*`/`surface.*`; a socialware instance allows them).

## The core obstacle: the union Kind cannot name all 5 behaviors without a cross-app cycle

The 5 union behaviors are split across two apps:
- instance_message (the proto-`domain.session`): `Behavior.Session` (was Chat), `Publisher.SessionImpl`, `ExternalMirror`.
- socialware: `Behavior.Turn`, `Behavior.Surface`.

Dependency direction is `socialware → instance_message` (one-way). So:
- A unified Kind in **instance_message** can't name `Turn`/`Surface` (socialware) → cycle.
- A unified Kind in **socialware** CAN name all 5 — BUT the spawn sites (`session_creator.ex`, the `"session"` SpawnRegistry, all in instance_message) name `Entity.Session` directly; routing session spawns to a socialware Kind re-creates the cycle on the spawn side.

So the union requires **consolidating all session behaviors into instance_message** (the session domain), so the one Kind lives where every spawn site already is.

## The entanglement that blocks the consolidation (the P5-1a finding)

`Turn`/`Surface` reach socialware ONLY through `Settlement`. But `Settlement` is NOT a clean leaf:
- `Settlement → CustomerFeed.topic/1` (the `"socialware:customer:<session>"` PubSub topic).
- `Settlement → CustomerOutbox` (the `socialware_customer_outbox` table, 9 call sites).

So `Turn/Surface → Settlement → {CustomerFeed, CustomerOutbox}` — the customer-delivery substrate. Moving Settlement to instance_message while CustomerFeed/Outbox stay in socialware = `instance_message → socialware` cycle.

### Verified facts (re-derived after 2 wrong reads)
- `CustomerOutbox` = pure Ecto schema, zero Ezagent deps → moves cleanly.
- The customer topic = a pure string builder (`"socialware:customer:" <> uri`) → trivially extractable.
- `CustomerFeed` is deep View-layer machinery (CustomerAuth, Uploads, Surface render, customer_tree) → STAYS in the View layer.
- `ezagent_web` (customer_channel/socket, consumers of the topic) already deps instance_message.
- `Settlement` otherwise deps only core (MessageStore, Repo); `Turn` also uses identity (`Identity`, `ConfigStore`) — instance_message already deps identity.

## Decisions for Allen

### D1 — Union Kind home: **instance_message (the session domain)**. (Recommended; the only no-cycle option given spawn sites.)

### D2 — Customer-delivery substrate placement — **VALIDATED by P5-1a (proven clean)**
The thing that decouples Settlement. **Recommended:** the customer-delivery DATA (`CustomerOutbox` table + the customer PubSub topic) moves to the **session domain** (instance_message) — it is where settled session content is queued for customer delivery (a session-turn outcome). The customer **feed/view** (`CustomerFeed` render+auth, the SPA, `ezagent_web` channel) STAYS in the View layer (socialware/web), reading the session-domain outbox/topic. Pattern: "session owns the data; view projects it" (same as P5-A's publisher-read).
- Mechanics: extract the topic to `Ezagent.Session.CustomerDelivery.topic/1` (instance_message); move `CustomerOutbox` + `Settlement(+Message,+Record)` + `Turn` + `Surface` → instance_message; `CustomerFeed` (socialware) reads them via the dep.
- **P5-1a STATUS (branch `socialware-p5-1-union` @ 550c91e7, UNMERGED, pending this spec's review):** executed this move and PROVED it clean — no-cycle grep clean (no instance_message→socialware ref), compile/arch/lifecycle green, im standalone 657 tests (6 baseline-proven flavor-plugin artifacts, identical on base b493622d), socialware 148/0, web 185/0, zero-new-failures proven on a fresh base checkout. So D2 is mechanically validated; only the *decision to adopt it* awaits 拍板.
- Alternative considered & rejected: invert `Turn → Settlement` to an event/subscription so Turn doesn't dep Settlement (bigger redesign; defers the coupling rather than placing it).

### D3 — Spawn / routing cutover
All `session://` spawns must resolve to the ONE unified Kind. Sites: `session_creator.ex:363/463`, the `"session"` `SpawnRegistry` (`application.ex:705`), advisor's `Kind.spawn(SocialwareSession,…)` (`advisor_session.ex:103`). After the union (unified Kind = the surviving `Entity.Session` in instance_message), repoint advisor + retire `SocialwareSession`. NO `kind_type` migration (both already `"session"`); the Template-selected `:kind_base` set distinguishes instances.

### D4 — Snapshot migration
Existing `Entity.Session` + `Entity.SocialwareSession` rows are both `kind_type "session"`; they rehydrate under the unified Kind with the per-instance set from their (P5-0-backfilled) `:kind_base`. Need to confirm: a pre-collapse socialware row's `:kind_base` already lists `[Session, Turn, Surface, Publisher]` (P5-0 backfill did this) → loads correctly on the union Kind. A chat row's `:kind_base` lists `[Session, Publisher, ExternalMirror]`. So NO new snapshot rewrite needed IF P5-0 backfill covered both — VERIFY. Reversible (no destructive change).

### D5 — P1 denial gate (the load-bearing merge gate)
A test that a chat-template instance of the unified Kind DENIES `turn.*`/`surface.*` (out-of-its-`:kind_base`-set) and a socialware-template instance ALLOWS them. This is the safety proof that the superset Kind doesn't widen authority. MUST pass before merge.

### D6 — App rename timing (`instance_message → domain.session`)
The app is the legacy-named proto-session domain. Renaming the OTP app (name + deps + dirs + `EzagentDomainInstanceMessage` namespace) is large + snapshot-key-coupled. **Recommended:** defer to PR-9 (per spec); the module moves now don't double-touch. (Open: Allen may want it now to avoid a half-named state — his call.)

## Sequencing (post-拍板)
1. P5-1a: consolidate customer-delivery + Turn/Surface/Settlement → session domain (data point in flight).
2. P5-1b: union `Entity.Session.behaviors/0`; Template subset selection; retire `SocialwareSession`; spawn/routing cutover.
3. P5-2: snapshot rehydration verification (likely no rewrite; reversible).
4. P5-3: delete dead `SocialwareSession`.
5. E2E: every socialware + chat scenario green on the collapsed Kind + the P1 denial gate.

DEFER valve (spec §6.3): if the P1 denial can't hold or a deeper entanglement appears, P5 stays deferred — P0–P4 substrate value is already delivered.
