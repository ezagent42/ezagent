# SPEC — Ezagent state model migration to EventStore + Commanded (CQRS / event-sourcing)

**Status:** r7 — **§1.5.7 added + codex-r1-reviewed; verdict = Option B'' (native consolidation)**. Allen's directive 2026-05-28 09:33: ezagent has been DIY-implementing the event-sourcing primitives organically for 9 months (invocations table = event log; kind_snapshots = aggregate snapshots; Behavior.invoke = combined execute+apply; ExternalMirror.BootReconciler = state recovery; Persistence + slice policy = snapshot policy) — just never **named** them as ES primitives. §1.5.7 formalizes what's there + adds the missing 30%, informed by Commanded's design lessons + CQRS principles. New top recommendation: **Option B'' — native consolidation**, ~880 LOC across 5 internal modules (`EventLog`, `SnapshotStore`, `StateRebuilder`, `SagaRunner`, `EventSubscriber`), ~2-3 weeks. Option B (Sage + ex_audit + Oban) remains as first fallback if B'' design fails; Option A (Commanded full migration) is second fallback if replay (P5) enters the 6-month horizon. B'' is **pro-future-Commanded**: by naming the abstractions correctly now, the eventual migration to Commanded shrinks from ~10-12 weeks (Option B) to ~6-14 weeks (r7-honest range per §1.5.7.5(e); floor depends on saga inventory + Kinds opted in). Codex r1 review on §1.5.7 returned REJECT with 3 HIGH + 2 MED + 1 LOW; all 6 addressed inline (synthetic-event replay-safety honesty, User Kind replay readiness checklist, SagaRunner-PM 1:1 claim downgraded, EventLog ordering tie-breaker, EventSubscriber partition mode pulled to Phase 2, audit args/result population gap acknowledged). Previous r6 verdict (CONDITIONAL Option B) is downgraded to first-fallback. The prior r4-FINAL status (4-round codex budget exhaustion, 7 carry-over limitations) still applies to §2-§12 if Option A is ever revisited. 2026-05-28.

## r7 changelog (delta from r6)

Allen's directive 2026-05-28 09:33 — "ezagent has been doing event sourcing organically; name it + add the missing 30%, informed by Commanded; B'' becomes the recommended path; B'' is pro-future-Commanded, not anti".

- **§1.5.7 INSERTED** — "Native consolidation path (Option B'') — formalize what ezagent already builds, informed by Commanded". 7 sub-sections, ~600 lines:
  - §1.5.7.1 — premise: ezagent has been doing ES organically (inventory of existing primitives + correction to §1.3's claim that there is no event log)
  - §1.5.7.2 — concept-by-concept comparison (ezagent today | Commanded canonical | B'' refined) across 8 ES concepts: event log, command/event split, aggregate identity, snapshot, state recovery, saga, projection, event versioning
  - §1.5.7.3 — CQRS principles applied (5 principles cited with source URLs + concrete module-signature shape changes): C/Q separation (Greg Young), Event as source of truth (Fowler), Aggregate boundary discipline (Vernon), Eventual consistency for reads (Young), Idempotency
  - §1.5.7.4 — five concrete new internal modules (`Ezagent.EventLog`, `Ezagent.SnapshotStore`, `Ezagent.Kind.StateRebuilder`, `Ezagent.SagaRunner`, `Ezagent.EventSubscriber`) with signatures + extension points + test strategy + LOC estimate (total ~880 LOC)
  - §1.5.7.5 — future extension points roadmap (5 scenarios: archive table, per-Kind replay opt-in, saga durability outbox, projection tables, future Commanded migration)
  - §1.5.7.6 — 4-option comparison table (A vs B vs B' vs B'') across 14 dimensions including the critical "migration cost to Commanded if needed later" row (B'' shortest at ~4-6 weeks)
  - §1.5.7.7 — recommendation: B'' primary, Option B first fallback, Option A second fallback
- **§1.5.5 verdict UPDATED** — B'' becomes primary recommendation; the r6 CONDITIONAL Option B becomes first fallback if B'' design has issues; Option A second fallback. Cost comparison updated to include all 4 options.
- **§1.5.6 downstream impacts UPDATED** — companion SPEC slate changes from "1 broad / 3 small Path B SPECs" to "5 small B'' SPECs (one per new module from §1.5.7.4)". Each lands in ~2-3 weeks independently.
- **Top-of-file Status banner** rewritten — verdict = Option B''; fallback ordering documented.

§1.5.1-§1.5.4 (alternatives table + library risk + per-scenario deep-dives) UNCHANGED — they describe Option B's evidence, which still stands as the first-fallback rationale.

§2-§12 (Commanded full-migration material) UNCHANGED — retained for the second-fallback scenario.

**r7 codex r1 review (2026-05-28, after initial r7 commit 2816befd)** — adversarial review on §1.5.7 returned **REJECT — 3 HIGH + 2 MED + 1 LOW**. All 6 findings addressed inline; §1.5.7 expanded ~200 lines.

- **HIGH-1 — Legacy `invoke/4` synthetic events not replay-safe (§1.5.7.2.b)**. Initial draft treated `%SliceMutated{}` synthetic events as a viable fallback path including for replay. Codex traced `Behavior.Chat.invoke(:send)` (`chat.ex:297-370, 408-414`) and showed `MessageStore.write` + PubSub broadcast + recipient dispatch happen alongside slice mutation — none reconstructible from slice diff alone. **Fix**: §1.5.7.2.b rewritten — `%SliceMutated{}` is explicitly audit/notification/cross-Kind-trigger only; events-as-truth opt-in requires the atomic triplet (`events_for/4` + `apply_event/2` + `effects/2`) per Behavior; legacy Behaviors are EXCLUDED from replay until the triplet ships.
- **HIGH-2 — User Kind replay path was theoretical (§1.5.7.5(b))**. Initial draft said "first Kind needs replay → that Kind implements events_for/4 + apply_event/2 on each Behavior, ~2-3 weeks". Codex pulled the actual User Kind inventory (`Identity`, `UserCredentials`, `UserTokens`, `IdentityAdmin` per `user.ex:226-231` + `application.ex:271-284`) and showed `UserCredentials.invoke(:set_password)` does bcrypt + `users.password_hash` DB write, `UserTokens.invoke(:mint_token)` does bcrypt + `entity_tokens` INSERT, `UserTokens.invoke(:revoke_token)` does pre-read + DELETE — these are NOT pure slice folds. **Fix**: §1.5.7.5(b) rewritten with per-Behavior replay-readiness assessment + concrete `effects/2` extraction plan + revised ~3-4 weeks per-Kind cost.
- **HIGH-3 — SagaRunner ↔ Commanded PM "1:1" overclaim (§1.5.7.5(e))**. Initial draft said B'' → Commanded migration was "~4-6 weeks (swap 3-4 internal modules)" with SagaRunner mapping "1:1 to Commanded PM". Codex correctly flagged: PM is stateful (3 callbacks: `interested?/1` + `handle/2` + `apply/2` + correlation-id PM-state-per-instance); SagaRunner is stateless (2 functions, closures). Not 1:1. **Fix**: §1.5.7.5(e) rewritten with honest per-component breakdown — `EventLog`/`SnapshotStore`/`EventSubscriber` are near-1:1 wraps (~1 week each); `SagaRunner` → PM requires translation (~3-4 weeks per non-trivial saga + extra for cross-call workflows); slice-per-Behavior → single-aggregate-state requires fusion or split decision. Revised total: ~6-14 weeks range. The comparison table row + §1.5.7.7 recommendation #3 updated to match.
- **MED-4 — EventLog ordering tie-breaker (§1.5.7.4 #1)**. Initial draft ordered `stream_by_aggregate/2` by `inserted_at` only; under same-microsecond collisions order is unstable. **Fix**: ordering contract added — `(inserted_at ASC, id ASC)` using existing `invocations.id` integer primary key as tie-breaker; cursor pagination uses the pair.
- **MED-5 — EventSubscriber partition mode under-specified (§1.5.7.4 #5)**. Initial draft included `{:partition, key}` return shape from `interested?/1` without lifecycle/GC/ordering/restart contract. **Fix**: partition mode pulled out of v1 callback return type; v1 returns `boolean` only; partition mode lands in Phase 2 with explicit contract for (i) ownership, (ii) per-key ordering, (iii) crash replay, (iv) GC, (v) duplicate-handler protection.
- **LOW-6 — Audit args/result not populated today (§1.5.7.1, §1.5.7.2.a)**. SPEC implied every `invocations` row has args + result JSON; current `Audit.Writer` (`audit.ex:93-116`) only populates these on failure paths, not on successful dispatches. **Fix**: §1.5.7.1 acknowledges the gap; B'' commits to extending `Audit.Writer` to capture full args + result via the EventLog naming companion SPEC; the "more SQL-queryable than Commanded" comparison narrowed to apply after args/result populated.
- **Bonus correction — slice-per-Behavior vs single-aggregate-state (§1.5.7.1)**. Codex implicitly flagged that ezagent Kinds host multiple Behaviors per Kind, fundamentally different from Commanded's single-aggregate-state. **Fix**: §1.5.7.1 adds an explicit acknowledged-asymmetry paragraph — slice-per-Behavior is genuinely different; B'' does NOT pretend 1:1; future Commanded migration must decide fuse-vs-split per Kind.

The revised verdict (Option B'' primary, Option B first fallback, Option A second fallback) is **unchanged** after codex r1 — the findings were structural-honesty fixes, not verdict-flips.

## r6 changelog (delta from r5)

Codex round on §1.5 (the r5 insert) returned **REJECT — 3 HIGH + 2 MED**. r6 addresses all 5 findings inline within §1.5; §2-§12 untouched.

- **HIGH-1 — P5 roadmap claim unsupported inline (§1.5.3 P5)**. r5 cited "nothing in incident retros or future-work cites replay" without inline evidence. r6 downgrades to "not currently evidenced HERE in §1.5; verdict assumes Allen confirms during grill-with-doc" + adds 4 plausible future replay drivers (regulatory compliance, AI training data, post-incident debug, schema migration backfill) + estimates Path B→Option A migration cost (~3-4 months wall-time, comparable to a fresh Option A done today).
- **HIGH-2 — Sage durability gap underweighted (§1.5.2 matrix + §1.5.3 P1/P3)**. r5 said Sage covers P1/P3 fully and dismissed Commanded's durable PM state as "pure overhead." r6 downgrades Sage P1/P3 ✅ → ⚠️ in matrix; rewrites P1 verdict to require Path B to include a durable saga log / outbox (Oban candidate) for cross-restart resilience; acknowledges destroy hasn't shipped, so "no observed mid-cascade incidents" is not evidence.
- **HIGH-3 — Library-staleness risk not priced (§1.5.4 NEW)**. r5 dismissed Sage 2022-09 + ex_audit 2023-02 staleness as a one-liner. r6 adds entire §1.5.4 "Library risk + dependency posture" subsection: fork-and-maintain costs, Ecto coupling per-lib, 5-year scenarios (Sage abandoned, ex_audit abandoned, both abandoned), mitigation cost (~2-4 weeks worst-case DIY pivot). Even worst-case Option B → DIY pivot is cheaper than Option A's day-one cost; staleness doesn't flip the verdict but requires pin discipline + annual audit.
- **MED-1 — Sage overclaimed for P4 (§1.5.2 matrix)**. r5 gave Sage P4 ✅ because "Sage runs inside a transaction." r6 changes Sage P4 to "—" (orchestration lib, not race-fix); L1 (Ecto.Multi + DB constraints) is the explicit P4 owner.
- **MED-2 — Companion Path B scope (§1.5.6)**. r5 named `2026-05-28-destroy-cascade-sage-ex_audit.md` but Option B covers P1+P2+P3+P4. r6 §1.5.6 offers Allen two options during grill-with-doc: (2a) one broader SPEC `2026-05-28-native-workflow-audit-race-hardening.md`, or (2b — recommended) split into three independent companion SPECs (race-hardening first, audit second, workflow+outbox third) matching cap-vis / URI-canonical's small-fast-converging precedent.

**Renumber**: r5 §1.5.4 "Verdict" → r6 §1.5.5; r5 §1.5.5 "What changes downstream" → r6 §1.5.6. r6 adds §1.5.4 "Library risk + dependency posture" between r5 §1.5.3 and r5 §1.5.4.

## r5 changelog (delta from r4, retained for trail)

Added per Allen's 2026-05-28 08:15 directive — SPEC must self-justify why Commanded specifically vs lighter native-Phoenix paths. Previously the SPEC jumped from §1 Problem to §2 Decision with zero alternatives analysis (0 mentions of Sage, ex_audit, "alternatives considered").

- **§1.5 inserted** between §1 (Problem) and §2 (Decision) — "Alternatives considered — native-Phoenix lighter paths". Structure: 5 candidate paths (L1 Ecto.Multi, L2 Sage, L3 ex_audit, L4 Oban Workflow, L5 DIY) × 5 pain points (P1 destroy cascade, P2 audit, P3 cross-Kind workflow, P4 races, P5 replay) honesty matrix + 5 per-scenario paragraphs.
- **§1.5 verdict = Option B** (r5 framing; r6 codex review downgraded to CONDITIONAL Option B — see r6 changelog above).
- **⚠️ Pre-§2 note added** at the top of §2 — flags that §2-§12 reflects the **rejected** Commanded path and should not be merged as-is. §1.5.6 (was §1.5.5 in r5) lists concrete next steps (pause #442, draft Path B SPEC).
- §2-§12 themselves are UNCHANGED — kept verbatim for context / future revisit if P5 enters the roadmap.

## Known Limitations after r4 (carried into grill-with-doc)

Codex r4 returned REJECT with 4 HIGH + 3 MED unresolved findings. These are documented here rather than blocking the SPEC because (a) the 4-round budget set up-front is exhausted, (b) each remaining item is implementation-detail level (specific column names, exact macro mechanism, narrative consistency in carried-over text), not architectural-foundation level. The SPEC's core architectural decision (CQRS/ES with Commanded + per-Phase forward-import + facade-aware consistency) is sound; the residue is impl-PR-level cleanup that future SPECs or impl PRs resolve.

**Carry-over items for Allen go/no-go discussion:**

1. **HIGH — §6.1 Phase 10-A has two protocol blocks (r2 ExternalMirror-migration + r4 Worker-only-via-PubSub).** Codex flagged that both r2 and r4 phrasings remain in the section, creating ambiguity. The r4 changelog says option (a) is the default (Session stays fully legacy), but the §6.1 body still carries r2 deliverables like "Migrate `Behavior.ExternalMirror` actions on Session aggregate". **Allen decision required:** Phase 10-A scope is either (A) Worker only + PubSub-bridging saga (r4 option a; Session 100% legacy in 10-A) or (B) Worker + Session ExternalMirror slice (r2; partial Session migration). Pick one; the impl PR-A1 SPEC sub-doc resolves it concretely.

2. **HIGH — §4.8 `@consistency` enforcement mechanism is described, not specified.** Plain Elixir `@attr` doesn't structurally attach to functions; the invariant test must use a macro/registry (e.g. `defwrite name, consistency:, projections:`). The SPEC describes the contract but not the macro shape. **Resolution:** impl-PR creates the macro; the macro signature is a sub-SPEC.

3. **HIGH — §6.0 parity gate column names don't match actual schemas.**
   - `entity_profiles` primary key is `entity_uri`, not `uri`; has no `registered_at` column (uses `timestamps()`).
   - `entity_tokens` has no `token_id`/`scope`/`minted_at` columns; has `id`, `token_hash`, `label`, `expires_at`, `last_used_at`, `workspace_uri`, `entity_uri`, timestamps.
   - **Resolution:** impl-PR Phase 10-B's verify-task SPEC normalizes column names — projection columns map to `entity_uri` + `inserted_at` per actual schemas; the aggregate event payload field names align with the projection column names (not necessarily with the SPEC's idealized names).

4. **HIGH — §6.0 MessageStore SQL templates use signature `recent_in_session/3` etc; actual API is `in_session_since/2` + `recent_in_session/2` + `older_than/3`; `in_session_since` uses strict `>` not `>=` and caps replay.** **Resolution:** impl-PR adjusts SQL to match actual cursor semantics + arities. The architectural choice (UNION over archive+projection) is unchanged.

5. **MED — §4.3 Sandbox row still says "test fixture only"; §4.1.5 correctly classifies as production.** Narrative inconsistency in the table that wasn't updated when §4.1.5 was corrected. **Resolution:** trivial edit at impl-PR start.

6. **MED — §3.8 has stale "from projections" text in saga state comments + step 2 still reads from `AgentLineage` projection in the example.** The execute snippet itself is correct (reads aggregate state), but the narrative around it carries r3 language. **Resolution:** impl-PR Phase 10-C saga sub-SPEC scrubs the stale text; the architectural choice (authoritative aggregate state) is unchanged.

7. **MED — §6.4 cleanup execute has crash window: DROP succeeds → process crashes → `.consumed` marker never written → next run of execute (with same receipt) sees no marker and would re-attempt the DROP.** Note: the DROP itself is idempotent (DROP IF NOT EXISTS), so re-attempt doesn't corrupt; but the audit trail loses the original execution_nonce. **Resolution:** impl-PR adds DB advisory-lock + writes `in_progress` audit row BEFORE the DROP within the same execution path; finalizes to `consumed` after.

**The SPEC is ready for Allen grill-with-doc with these 7 carry-overs explicit.**

---

## r4 changelog (delta from r3, retained for trail)

Addresses 6 HIGH + 2 MED + 1 corollary HIGH from codex r3 REJECT (final budgeted round per cap-vis/URI-canonical 4-round pattern):

- **HIGH-1 (§4.1.5 still misclassifies):** r3 left `Echo` and `NpAgent` as vague "per-flavor" — actually both `:ephemeral` (`echo.ex:21`, `np_agent.ex:65`); `Sandbox` was "test fixture only" but production `Ezagent.Entity.Agent` lists it at `agent.ex:75` exposing `:read/:write_path/:destroy` actions at `sandbox.ex:86`. **r4 fix:** §4.1.5 table updates Echo + NpAgent to `:ephemeral`. Sandbox row added to behavior list with explicit migration disposition: stays as Agent aggregate behavior (real `:read`/`:write_path`/`:destroy` commands on Agent aggregate). The "test fixture only" line removed.

- **HIGH-2 (§4.1 stale "no migration" mapping contradicts §6.0):** r3 §4.1 row for `kind_snapshots` still said migrated Kinds "do NOT migrate existing snapshots; first command creates fresh event-sourced state" while §6.0 mandates import. **r4 fix:** §4.1 row REWRITTEN to: "For migrated Kinds: existing snapshot data is forward-migrated via §6.0 snapshot-import as Step 0 of each Phase. The `kind_snapshots` table itself is read-only post-import; deletion gated by §6.4 preflight." This removes the contradiction and aligns §4.1 with §6.0.

- **HIGH-3 (§4.8 AST gate cannot trace facades):** r3 AST gate only matched direct `Ezagent.CommandedApp.dispatch/2` in `handle_event/3`. Actual LV writes route through facades: `Ezagent.Workspace.add_template/3` @ `workspace_detail_live.ex:307`, `EzagentDomainChat.create_session/3` @ `admin_live.ex:804`, `chat.join` dispatches @ `admin_live.ex:1019`, session routing CRUD @ `admin_live.ex:1381`, `EzagentPluginFeishu.bind/2` @ `feishu_bindings_live.ex:88`, `ExternalMirror.bind/4` @ `session_external_mirror_live.ex:221`. **r4 fix:** §4.8 dual-gate architecture:
  - **Facade declaration:** every domain-context write facade (e.g. `Ezagent.Workspace.add_template/3`, `EzagentDomainChat.create_session/3`, `EzagentPluginFeishu.bind/2`) declares a `@consistency :strong | :eventual | {:named, [projector]}` module attribute on its function head. The attribute is the API contract; callers see it via docs + `@type`.
  - **AST gate widened:** `Ezagent.Invariants.ConsistencyMatrixTest` walks each facade module, asserts every public `def` that ends in a `Commanded.App.dispatch/2` call has a `@consistency` attribute; then walks each LV `handle_event/3`, for each facade call, looks up the declared `@consistency` and asserts the LV's subsequent `assign/2` re-read is compatible with that attribute (i.e. if the LV re-reads, the facade must be `:strong` or a named-projector list covering the projection). Facade-to-projection coverage map lives in §5.1 (each projection lists the facades that update it).
  - The hand-table in §4.8 is now annotated with the FACADE name + the dispatching LV file:line. The full list of facades + their `@consistency` declarations is in a new Appendix D.

- **HIGH-4 (§6.1 split-brain unsafe for bind→spawn→subscribe):** r3 had two state stores per Session URI; current bind persists row at `external_mirror.ex:394`, spawns worker at `:421`, then worker subscribes back via legacy publisher at `external_mirror_worker.ex:639`. r3's event-store binding race with legacy publisher subscription is unsafe. **r4 fix:** Phase 10-A drops the slice-split protocol. Two options:
  - **Option (a) — DEFAULT for r4: bind→spawn→subscribe modeled as a single `BootstrapWorkerSaga` from the start.** The saga in 10-A subscribes to the legacy Session's `:slice_change` topic via existing PubSub, NOT to the new event stream. The saga's commands target the new Worker aggregate (now `:aggregate`). The Session itself stays fully legacy in 10-A — `:external_mirror` slice writes remain on the Session GenServer; the saga reads those writes via the legacy slice subscription, not via an event stream. The split disappears; Session is wholly legacy in 10-A, Worker is wholly aggregate, the saga bridges via PubSub.
  - **Option (b) — fallback if Worker reverse-callback to Session publisher cannot be retained legacy: migrate the full Session aggregate in 10-A (Chat + Publisher + ExternalMirror + OrchestratorAdmin together).** Big-bang scope; rejected unless (a) proves infeasible at impl PR-A1.

  Option (a) commits r4. The split-brain protocol from r3 §6.1 is REMOVED. SessionRouter is removed; Session stays entirely legacy in 10-A. `Ezagent.Invariants.SessionSplitBrainConsistencyTest` is removed (no longer needed).

- **HIGH-5 (§6.0 UNION missing workspace scope + wrong cursor type):** r3 UNION filters/orders by `m.inserted_at` but omits `m.workspace_uri == ?` (required per `message_store.ex:174`/`:201`). r3 says `older_than(session_uri, msg_id)` — actual cursor type is `DateTime`, not `msg_id`, per `message_store.ex:195`. **r4 fix:** §6.0 UNION rewritten to include `m.workspace_uri = $workspace_str` predicate + `r.session_uri = $session_uri` join key + ordering by `r.inserted_at`. `older_than` cursor corrected to `DateTime` per the existing API. Three parity-preserving SQL templates added (one per query), matching the current `MessageStore.recent_in_session/3`, `older_than/3`, `in_session_since/3` signatures.

- **HIGH-6 (§5.1 + §6.0 User projection parity not carried):** r3 said §5.1 was updated but field-level parity gates in §6.0 verify still referenced generic `kind_snapshots.state_binary` parity. **r4 fix:** §5.1 projection list explicitly enumerates COLUMNS for each User projection (no more "etc"). §6.0 `mix ezagent.aggregate.verify --kind user` definition expanded with explicit per-table parity asserts: it queries every row of `entity_profiles`, asserts a matching `user_profile_projection` row exists with `display_name + email + workspace_uri + registered_at` equal; then queries `entity_tokens`, asserts matching `user_tokens_projection` row with `token_hash + label + last_used_at + workspace_uri` equal. The generic parity step survives FOR `users.caps_json` (handled via `user_caps_projection`); the new explicit asserts are additional.

- **MED-7 (§4.2.3 working-copy nested field names wrong):** r3 had `source_template_uri` — actual field per `chat.ex:257` is `source_agent_template_uri` + `live_worker_uri` + `generation`. **r4 fix:** §4.2.3 working-copy nested shape rewritten to match `default_template_working_copy/0` verbatim — `agent_slots: [{slot_name, source_agent_template_uri, live_worker_uri, generation}]`. Replay parity test reaches per-nested-field, not just "5 fields exist".

- **HIGH-8 (§3.8 step 0 reads stale projections):** r3 `%CaptureDestroyPreSnapshot{}` read caps/sessions/lineage from projections (eventually-consistent). Lineage source is ETS (`agent_lineage.ex:31`); caps are slice state (`identity.ex:89`). Reading projections for compensation baseline is stale-by-design. **r4 fix:** Step 0 captures from AUTHORITATIVE sources directly. The aggregate's `execute/2` for `%CaptureDestroyPreSnapshot{}` reads:
  - Caps from the Agent aggregate's OWN state (the aggregate has `caps: MapSet.new()` in its defstruct; `%DestroyPreSnapshotCaptured{}.caps = aggregate.caps`).
  - Lineage parent from the aggregate's OWN state (`aggregate.lineage_parent_uri`).
  - Session memberships from the aggregate's OWN state (`aggregate.sessions`).

  The aggregate's state IS the authoritative source — it was hydrated from events on aggregate-load; no projection lag concern. The saga's PM state retains the snapshot for fast compensation lookup, but the snapshot's source-of-truth is the event-replayed aggregate state at command-time. No external projection read in step 0.

- **MED-9 (§6.4 cooldown is actually expiry, not cooldown):** r3 said `expires_at = drill_completed_at + 24h` and called that a cooldown; but `execute` permits `now > drill_completed_at` — DROP can run immediately, not after a cooldown. **r4 fix:** §6.4 receipt schema adds explicit `earliest_execute_at = drill_completed_at + cooldown_hours` (default 24h, configurable). `expires_at` becomes a separate field (default `drill_completed_at + 7d`). `cleanup.execute` verifies `earliest_execute_at < now < expires_at`. Receipt is one-time consumed: `cleanup.execute` writes a marker file `priv/cleanup_receipts/<timestamp>.consumed` after a successful DROP; replays of the same receipt see the marker and fail. An `execution_nonce` is generated by `cleanup.execute` and recorded in an `audit_events` row for forensic trail.

---

## r3 (prior) status

## r3 changelog (delta from r2, retained for trail)

Addresses 6 HIGH + 2 MED from codex r2 REJECT (no CRIT in r2 — r1 CRITs closed):

- **HIGH-1 (§4.1.5 inventory still wrong):** r2 misclassified `Ezagent.Workspace` as `{:snapshot, :on_change}` (actually `:ephemeral` at `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:61`), `Ezagent.Entity.ExternalMirrorWorker` as `:on_terminate` (actually `:ephemeral` at `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex:71`); omitted `Ezagent.Entity.System` (a real Kind with Routing behavior, `:ephemeral` at `apps/ezagent_core/lib/ezagent/entity/system.ex:32`); omitted `Ezagent.Behavior.IdentityAdmin` (separate behaviour module in same file as `Identity`, at `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:328`). **r3 fix:** §4.1.5 rewritten with statically-verified persistence values from each module. New §4.1.5-table-note clarifies that `:ephemeral` Kinds (`Workspace`, `ExternalMirrorWorker`, `System`) are durable via *external persistence* (Workspace = `workspaces` SQLite table via `Workspace.Store`; Worker = `external_mirror_bindings` reconciliation; System = config-derived bootstrap). Their migration target reads from those external sources at aggregate creation, not from `kind_snapshots`. The §6.0 import task is adjusted per-Kind to read from the correct source.

- **HIGH-2 (§4.8 consistency matrix incomplete and references wrong files):** r2 referenced nonexistent `agents_live.ex` (actual: `agent_new_live.ex`), used TBD rows, and missed many write→read sites. **r3 fix:** §4.8 is rewritten with statically-verified file:line. New sites added: `users_live.ex:202` (set_password), `users_live.ex:230` (promote_to_system), `users_live.ex:250` (revoke from system), `workspace_detail_live.ex:255` (remove member), `routing_live.ex:307` (delete_rule), `agent_api_keys_live.ex:159` (delete_api_key). `agent_new_live.ex:120` corrected for create-agent. The matrix is now declared as the *source of truth*; r3 promotes the invariant to a structural AST scan via `Ezagent.Invariants.ConsistencyMatrixTest` that walks every LV `handle_event/3` clause AST-side and asserts: any dispatch followed by an `assign/2` re-read of the modified projection uses `consistency: :strong`. The hand-table is a doc artifact; the invariant test is the gate.

- **HIGH-3 (§6.1 Phase 10-A still self-contradictory):** r2 left the "Worker first (smallest Kind) — One Kind migrated; everything else unchanged" phrasing while expanding to include Session ExternalMirror behavior. **r3 fix:** Phase 10-A renamed "ExternalMirror slice + Worker — the bind-spawn coupling boundary". The "smallest Kind" framing is dropped. New paragraph explicitly enumerates the split-brain protocol: Session's `Behavior.Chat` + `Behavior.Publisher.SessionImpl` + `Behavior.OrchestratorAdmin` slices stay GenServer-hosted; only the `:external_mirror` slice moves to the new Session aggregate. The Session GenServer is alive AND the Session aggregate has events on its stream — they are TWO state stores for one URI during 10-A. The pre-dispatch pipeline routes commands by which Behavior the command targets: ExternalMirror commands → aggregate; Chat/Publisher/OrchestratorAdmin commands → legacy. A new `Ezagent.SessionRouter` module owns the routing decision (`route_session_command/1 :: :legacy | :aggregate`). The invariant: any test that exercises a Session URI must drive BOTH the GenServer slice + the aggregate state into consistency.

- **HIGH-4 (§6.0 messages archive plan wrong column / wrong join):** r2 said "filter by `created_at`"; actual schema column is `inserted_at` per `apps/ezagent_core/priv/repo/migrations/20260516070500_phase2_messages.exs:23`; per-session history is a `message_routings → messages` join per `apps/ezagent_core/lib/ezagent/message_store.ex:174`. **r3 fix:** §6.0 messages archive paragraph rewritten: the permanent query is an ordered union over (a) the archive `message_routings ⋈ messages` join filtered `inserted_at < <cutover_at>`, and (b) the new `session_messages_projection` filtered `inserted_at >= <cutover_at>`. Parity gates added for `recent_in_session`, `older_than`, `in_session_since` query shapes.

- **HIGH-5 (§4.2.1 User projections still omit fields):** r2 added profile/token fields to aggregate state but the §5.1 projection table rows didn't reflect them. **r3 fix:** §5.1 projection table updated — `user_profile_projection(uri, workspace_uri, display_name, email, registered_at, destroyed?)`; `user_tokens_projection(uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, revoked_at, workspace_uri)`. Field-level parity gates added against `entity_profiles` + `entity_tokens` during the §6.0 import: every row in those tables must produce a matching projection row post-replay.

- **MED-6 (§4.2.3 Session working-copy shape underspecified):** r2 had `template_working_copy: nil` — actual default is a structured map at `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:255` with `agent_slots`, `routing_rules`, `orchestrator_template_uri`, `default_workspace_uri`, `description`. **r3 fix:** §4.2.3 expanded — `template_working_copy` is now a sub-struct with the 5 named fields, default per `default_template_working_copy/0`. Replay test added: a Session with a populated working copy reconstructs all 5 fields.

- **HIGH-7 (§3.8 saga step 0 was commentary, not code):** r2 documented `pre_destroy_caps` / `pre_destroy_sessions` / `pre_destroy_lineage_parent` in saga defstruct comments but the actual `defstruct` line didn't include them. **r3 fix:** §3.8 saga is REWRITTEN with explicit step 0:
  ```elixir
  def handle(%__MODULE__{step: nil}, %AgentDestroyRequested{} = ev) do
    %CaptureDestroyPreSnapshot{agent_uri: ev.agent_uri}  # NEW: step 0 dispatches a snapshot-capture command FIRST
  end
  def handle(%__MODULE__{step: :pre_snapshotted}, %DestroyPreSnapshotCaptured{} = ev) do
    %RevokeAllCapsHeldBy{agent_uri: ev.agent_uri}  # step 1 now reads snapshot from aggregate state
  end
  ```
  The `DestroyPreSnapshotCaptured` event payload carries the pre-destroy caps/sessions/lineage_parent; the aggregate's `apply/2` writes these into the aggregate's own state (NOT into the saga). The compensation reverse commands read those snapshot fields directly from the aggregate at compensation time. defstruct EXTENDED with these fields. Step 2 DestroyChildAgents stays declared non-compensable per saga forward-only doctrine; the post-r3 runbook documents the operator-repair path (`mix ezagent.saga.repair --saga DestroyAgentSaga --uri <uri>` reads partial residue + emits manual cleanup commands).

- **MED-8 (§6.4 cleanup gate spoofable by fake ticket):** r2 only checked "matches docs/runbooks entry"; not a real artifact gate. **r3 fix:** §6.4 preflight requires a *drill receipt*: a signed JSON artifact at `priv/cleanup_receipts/<timestamp>.json` containing `{backup_path, backup_sha256, live_row_count, restored_row_count, parity_report_sha256, operator_email, drill_completed_at, expires_at: drill_completed_at + 24h}`. The `mix ezagent.cleanup.drill` task is the ONLY writer of that file; it computes the SHAs at drill time. The `mix ezagent.cleanup.execute` task verifies: (i) receipt exists, (ii) SHAs match the *current* live DB state, (iii) `drill_completed_at < now < expires_at`, (iv) `operator_email` is on `priv/cleanup_operators.allowlist` (committed file). Any tampering invalidates the SHA. The receipt cannot be forged via `--operator-approved` flag alone.

---

## r2 (prior) status

## r2 changelog (delta from r1, retained for trail)

Addresses 2 CRIT + 4 HIGH + 2 MED from codex r1 REJECT:

- **CRIT-1 (forward data migration plan was missing — §4.1 / §6 / §8):** r1 claimed migrated Kinds "do NOT migrate existing snapshots; first command creates fresh event-sourced state". That drops live User/Session/Agent/Workspace state at cutover. **r2 fix:** new §6.0 (Forward Data Migration) is mandatory at the start of every Phase (10-A through 10-C). It defines a per-Aggregate "snapshot import" event class (e.g. `%UserSnapshotImported{}`) emitted ONCE per existing URI by a `mix ezagent.aggregate.import --kind <kind>` task BEFORE production dispatch is routed to the aggregate. The import event carries the full pre-existing slice payload. The aggregate's `apply/2` has a dedicated clause for the snapshot import event that hydrates the aggregate state. A parity gate (read-back from event-replayed aggregate vs `kind_snapshots` row) is the import-step success criterion; the cutover does NOT happen until parity is green. §6.0 + §6.1/6.2/6.3 expanded to include the import task as Step 0 of each Phase.
- **CRIT-2 (Phase 10-A bridge gap — §6.1 / §8.2):** r1 had Phase 10-A migrate Worker only, but legacy Session `Behavior.ExternalMirror` still calls `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params)` directly at `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:394` + `:677`. No `BindingCreated` event is emitted while Session remains a GenServer, so `BootstrapWorkerSaga` never fires. **r2 fix:** Phase 10-A is REVISED to either (a) migrate Session ExternalMirror behavior+Worker together (preferred — they're tightly coupled at the bind callsite) OR (b) ship an explicit `Ezagent.MigrationBridge.LegacyBind` shim that translates legacy `Kind.spawn(Worker, params)` calls into `%SpawnWorker{}` commands on the new aggregate AND emits a synthetic `%BindingCreated{}` event into the new event stream so saga triggers fire. Option (a) is taken as r2 default; option (b) documented as fallback if Session-side migration proves too entangled. §6.1 expanded to include the Session ExternalMirror behavior delta.
- **HIGH-3 (read-after-write consistency matrix was missing — §3.3 / §6.2):** r1 said "opt to :strong per dispatch site" without enumerating sites. r2 adds §4.8 (LV / Channel / CLI Consistency Matrix) — a table listing every write callsite that immediately re-reads state, with the required consistency mode. Sites already inventoried statically: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:137` (create→list_users), `workspace_detail_live.ex:165` (add member→get_by_name), `entity_caps_live.ex:142` (grant cap→reload caps), `routing_live.ex:235` (add rule→reload rules). All MUST use `consistency: :strong` (or named-projector list). The Phase 10-B/10-C invariant tests assert each enumerated site does so; a CI grep gate rejects `consistency: :eventual` on these specific dispatch paths.
- **HIGH-4 (Kind/Behavior inventory was incomplete — §4.2 / §4.3):** r1 said "5 entity Kinds" + "11 Behavior modules" — actual count is much larger. r2 adds §4.1.5 (complete Kind/Behavior inventory) statically enumerated from the checkout: 15+ Kind modules (including durable `Ezagent.Entity.AgentTemplate` + `Ezagent.Entity.SessionTemplate`, both `{:snapshot, :on_change}`, plus per-flavor `CurlAgent` / `Echo` / `NpAgent`), 24 Behavior modules (added: `ApiKeys`, `Template`, `OrchestratorAdmin`, `Pty`, `UserBinding`, `FeishuAllow`, plus the 4 plugin agent-flavor behaviors). Each gets a per-Phase migration disposition column. §4.3 rewritten with the full list.
- **HIGH-5 (Session aggregate state omitted durable fields — §4.2.3):** r1's Session aggregate state struct missed `owner_uri`, `last_seen`, `monitors`, `last_message_id`, `last_message`, `send_cursor`, `recent_messages`, `template_working_copy`, plus Publisher's `ring` / `cursor` / `retention` (all durable — `Behavior.Chat.init_slice` at `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:144`-`:242` + `Publisher.SessionImpl.init_slice` at `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:150`-`:165`). r2 fix: §4.2.3 Session aggregate state struct is REWRITTEN to enumerate every durable field; non-durable runtime fields (`monitors` — process refs that don't survive restart) are explicitly excluded with a comment. Replay tests for rejoin / external mirror dedupe / publisher cursor catchup are added as Phase 10-B invariant tests.
- **HIGH-6 (User projection schema missed profile + token fields — §4.2.1 / §4.7):** r1's `user_profile_projection` had only `(uri, workspace_uri, registered_at, destroyed?)`. Current `Entity.Profile` schema (`apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:21`) has `display_name` (required) + `email`. Current `Entity.Token` schema (`apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:43`) has `token_hash`, `label`, `last_used_at`. **r2 fix:** §4.2.1 User aggregate gains a `:profile` field (`%{display_name, email}`) + commands `%UpsertProfile{}` / events `%ProfileUpserted{}`. Token aggregate state + events extended to carry hash/label/last-used. Projections in §5.1 updated to match.
- **MED-7 (DestroyAgentSaga compensation was only retry/stop — §3.8 / §4.4):** r1's saga `error/3` retried then stopped. Current cleanup paths (`apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:189` session-create rollback, `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:240` sandbox-destroy cleanup) do explicit reverse-operations. **r2 fix:** §3.8 DestroyAgentSaga is REWRITTEN to use `{:continue, [%ReverseCommand{}, ...], context}` per-step compensation in the `error/3` callback. Each step is documented with: (a) idempotency contract; (b) residue on failure; (c) reverse command; (d) resume behavior. Step-failure tests are Phase 10-C invariants.
- **MED-8 (Phase 10-D destructive cleanup lacked operator gate — §6.4 / §8.4):** r1 said "delete `kind_snapshots` after a final data dump". Per `feedback_destructive_migration_anti_pattern` + `feedback_completion_requires_invariant_test`, that's not a gate. **r2 fix:** §6.4 Phase 10-D `DROP TABLE kind_snapshots` is gated on: (a) operator approval flag in the migration script (mix task requires `--operator-approved <ticket-id>`); (b) verified backup restore drill — operator restores last snapshot dump to a temp DB and asserts row count matches; (c) post-restore parity check — the import-replay vs original snapshots must equal across all migrated URIs. The gate is itself a `mix ezagent.cleanup.preflight` task that exits non-zero unless (a)+(b)+(c) hold. SPEC §8.4 expanded.

---

## r1 (initial) status

**Tier:** Cross-cutting architectural migration. Touches `apps/ezagent_core/` (Kind / Behavior / Invocation / Persistence / Snapshot / Audit), all `apps/ezagent_domain_*/` (User, Session, Agent, Workspace, ExternalMirror Worker entity Kinds), the LiveView reading layer (`apps/ezagent_plugin_liveview/`), the CLI (`apps/ezagent_cli/`), the web dispatch surface (`apps/ezagent_web/`), and every plugin authoring example. Introduces three new umbrella apps (`ezagent_event_store`, `ezagent_commanded_app`, `ezagent_projections`) and a runtime hybrid period where some Kinds are Aggregates and others remain GenServers.

**Trigger:** Allen 2026-05-28 06:31 — pause SPEC #440 (entity-destroy lifecycle) after 4 codex REJECT rounds. The destroy cascade's 3 critical findings (no transactional cross-Kind atomicity; partial-failure inconsistency window; saga-like recovery requires structural primitives the current Kind=GenServer model does not provide) all dissolve under event-sourced semantics with Process Managers. Allen flagged the deeper hypothesis: **every multi-Kind workflow we have built (boot reconciler, spawn registry races, cap grant-time check, workspace cap-vis 5-round iteration) hits the same wall**. The destroy-lifecycle blockage is the most visible instance of a class.

**Companion:** `2026-05-28-eventstore-commanded-migration.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim / dual-path. If we adopt CQRS/ES, the snapshot table becomes a cache for Aggregate replay, NOT a parallel source of truth. The migration is committed (per-Kind hard flip), not toggled.
- `feedback_completion_requires_invariant_test` — Phase gates are invariant tests that FAIL when the architectural goal is unmet. For each migrated Kind, the gate is "this Kind's state reconstructs deterministically from its event stream alone" (no slice/snapshot fallback). For Sagas: "this multi-Kind workflow runs through a Process Manager (not direct cross-Kind GenServer.call)".
- `feedback_north_star_plugin_isolation` — plugin authors write Commands + Events + an Aggregate `execute/2` + `apply/2`. They do NOT touch `Commanded.Application`, the event store config, projection wiring, or the saga registry. The boundary tightens.
- `feedback_destructive_migration_anti_pattern` — see §6 / §8. The migration adds a new event store DB; it does NOT destroy existing snapshot data. The unwind path in §12 explicitly forks back to slice/snapshot for any Phase whose migration aborts.
- `feedback_register_lookup_key_parity` — Aggregate identity must canonicalize the same way as the existing Kind URI (`Ezagent.URI.parse!/1`). The `:identify` clause on the router uses the canonical URI string; divergent canonicalization between dispatch sites would silently mis-route a command to a fresh Aggregate ID. §4.6 enforces.
- `feedback_uuid_is_canonical_identifier` — Aggregate UUIDs MUST be the canonical URI string of the existing Kind URI. We do NOT mint a new UUID column. The URI IS the identifier.
- `feedback_subagent_must_load_project_skills` — every Phase impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_review_every_pr` — codex review of THIS SPEC + every Phase impl PR carries the verbatim "no mix" clause.
- `feedback_phase_planning_reads_main_docs` — Phase numbering in §6 conforms to `IMPLEMENTATION_ROADMAP.md` §1.1 (current latest is Phase 6 / partial). This migration would be Phase 10 (post-Phase-9 PR-CC follow-ups complete, post-Phase-6 closeout).
- `feedback_explain_problem_not_code_structure` — §1 leads with the problem class (multi-Kind workflows lack atomicity primitives), §2 leads with the decision (CQRS/ES), code shape lives in §4-§5.

**Parent / historical context:**
- `IMPLEMENTATION_ROADMAP.md` §1.1 — Phase 0-6 are complete or in-flight. This SPEC would become Phase 10 (skipping reserved-but-unstarted Phase 7-9 follow-up work).
- `ARCHITECTURE.md` Decision Log #84 — chose path B (`@behaviour Ezagent.Kind` + shared `Kind.Server` GenServer) over path A (`use Ezagent.Kind` macro). This SPEC supersedes both with path C (`Commanded.Aggregate`).
- `ARCHITECTURE.md` Decision Log #59 + #60 — sync `on_change` snapshot writes + async batch writer for `periodic`. The event-sourced model REPLACES this with synchronous event append + optional aggregate snapshot every N events.
- `apps/ezagent_core/lib/ezagent/kind/server.ex` — the shared Kind GenServer that hosts every Kind today. Becomes deprecated post-Phase-10-D for each migrated Kind.
- `apps/ezagent_core/lib/ezagent/invocation.ex` (steps 1-4, 11-12) + `apps/ezagent_core/lib/ezagent/kind/runtime.ex` (steps 5-10) — the 12-step dispatch flow. Steps 5-10 collapse into `Commanded.Application.dispatch/2` after migration; steps 5.5 (CapBAC) + 5.6 (workspace isolation) move to a pre-dispatch authz pipeline (§4.5).
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` — the per-Kind snapshot table. Becomes the Commanded aggregate snapshot store for migrated Kinds; remains in service for any not-yet-migrated Kind during the hybrid window.
- `apps/ezagent_core/lib/ezagent/audit.ex` + `Ezagent.Audit.Writer` — the SQLite `invocations` audit table. Becomes redundant for migrated Kinds (the event stream IS the audit log); REMAINS for un-migrated Kinds and for cross-cutting telemetry that isn't a domain event (e.g. `[:ezagent, :authz, :denied]` deny-side audit).
- `docs/superpowers/specs/2026-05-27-uri-canonicalization.md` — the canonical `%URI{}` chokepoint. Aggregate ID derivation in §4.6 routes through `Ezagent.URI.parse!/1` and emits `URI.to_string/1` for the router `:identify` clause.
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` — the dispatch-time authz invariant (step 5.5 chokepoint). §4.5 of this SPEC explains how the authz check moves out of `Kind.Runtime.handle_dispatch/4` into a pre-dispatch pipeline that wraps `Commanded.Application.dispatch/2`, preserving the chokepoint.

**Reference libraries:**
- [commanded](https://github.com/commanded/commanded) — CQRS/ES framework for Elixir. v1.4.10 latest. ([hexdocs](https://hexdocs.pm/commanded))
- [eventstore](https://github.com/commanded/eventstore) — PostgreSQL-backed event store for Elixir. v1.4.8 latest.
- [commanded_eventstore_adapter](https://hex.pm/packages/commanded_eventstore_adapter) — adapter wiring `commanded` to `eventstore`.
- [commanded_ecto_projections](https://hex.pm/packages/commanded_ecto_projections) — Ecto-backed read-model projector helpers.
- [Conduit reference app](https://github.com/slashdotdash/conduit) — Phoenix + Commanded Medium clone.
- [Gift-card demo](https://github.com/slashdotdash/gift-card-demo) — Phoenix LiveView + Commanded reference.

---

## 1. Problem statement — why migrate

### 1.1 The destroy-lifecycle 4-round codex failure as proof

SPEC #440 (entity destroy lifecycle) hit 4 consecutive codex REJECT rounds without converging. Each round addressed a different facet of the same structural shortfall:

- **r1 REJECT — atomicity:** the 7-step destroy cascade (revoke caps → unbind external mirrors → terminate child agents → drop session memberships → unlink lineage → terminate Kind processes → write deletion-audit row) cannot be atomic under the current Kind=GenServer model. Each step is a separate `Invocation.dispatch/1` against a different Kind; if step 4 raises (target Kind crashes mid-leave), steps 1-3 already committed and there is no transactional roll-back primitive. Mitigation proposed: "destroy_lock" GenServer per parent URI to serialize concurrent destroys. Codex flagged: lock acquisition does not give atomicity, only serialization; the partial-failure window persists.
- **r2 REJECT — fence/saga:** proposed a "destroy fence" mechanism — a sweeper that re-runs steps until idempotent. Codex flagged: the sweeper requires re-entrant idempotency on every step's invoke handler, retrofitting that onto 11 existing behaviors is a different SPEC; and the sweeper's progress is itself a workflow that needs its own state machine.
- **r3 REJECT — destroy-as-state-flag:** proposed a `:destroyed_at` slice column on each Kind so dispatch could deny invocations on a tombstoned Kind. Codex flagged: tombstone is a soft delete; the requirement was hard delete + cap unwind + audit; tombstone leaks the dead URI forever and does not address cascade.
- **r4 REJECT — destroy_log table:** proposed a side-table that records cascade progress + a reconciler that resumes interrupted destroys on boot. Codex flagged: this IS event-sourcing, badly. The `destroy_log` table is a hand-rolled append-only event stream; the reconciler is a hand-rolled Process Manager; we are reimplementing Commanded primitives one ad-hoc table at a time.

**Codex r4 verdict text (quoted from the review):** *"The destroy_log approach is event-sourcing without the framework. Every problem you're trying to solve — multi-aggregate atomic operations, mid-failure resumption, audit trail invariant — is what Commanded was designed for. This SPEC keeps re-inventing Commanded internals piecemeal. Step back: do you need to keep the GenServer+slice model, or is the architectural ceiling here?"*

That codex verdict is the proximate cause of THIS SPEC. The atomic-destroy problem is intractable in the current model. The CQRS/ES model has structural primitives — Aggregates carry their own state from events, Process Managers orchestrate multi-aggregate workflows with built-in compensation, EventStore append is the audit log, snapshots are a cache not a source of truth — that resolve all 4 codex blocker classes without re-invention.

### 1.2 The bigger class — every multi-Kind workflow hits this

Destroy is the most acute case, but the same pattern recurs:

- **`BootReconciler`** (Phase 3 PR-EM-9, external-mirror-domain SPEC §3.1) — on Application boot, scan the `external_mirror_bindings` projection table and re-spawn Workers for each persisted binding. The reconciler is a hand-rolled scan-and-spawn loop that races against Session boot (Worker `post_init/2` may run before its target Session reaches `:ready`, requiring a buffer + retry layer in `PendingDelivery`). Under CQRS/ES, "Worker for binding X exists when binding X exists in the read model" is a saga that subscribes to `BindingCreated` events and emits `SpawnWorker` commands. No boot scan; no race; the saga state machine encodes the ordering.
- **`SpawnRegistry` race classes** (Phase 2-3 incident retros) — concurrent `Kind.spawn/2` calls for the same URI race on `DynamicSupervisor.start_child`, with `{:error, {:already_started, pid}}` handled idempotently by callers BUT the second caller's `init_slice/1` args silently lost (the first call wins). Under CQRS/ES, "first command at this aggregate ID creates it" is a primitive — the aggregate doesn't exist until the create command lands; subsequent create commands fail with `{:error, :already_created}` deterministically; the aggregate state is built from the events of the FIRST creation regardless of which process emitted them.
- **Capability grant-time check ambiguity** (PR-CC-2 / caps-cleanup-v1 SPEC) — `Behavior.Identity.grant_cap` must verify the granter held the underlying ownership cap AT GRANT TIME, but caps are a slice that mutates on every grant — the check is a read-after-write against the granter's own slice. The current model resolves this with synchronous `GenServer.call` ordering (`Kind.Server.handle_call` serializes per-instance). Under CQRS/ES, the granter's caps at grant time are derivable from the granter Aggregate's event-replayed state at the instant the grant command was applied; the command's `execute/2` reads the aggregate state and emits the `CapGranted` event atomically (the aggregate-level serialization gives the same property; it's also durable in the event stream, so the audit query "what caps did the granter hold when they granted X" becomes a stream filter, not a forensic snapshot read).
- **Workspace cap-vis 5-round iteration** (`2026-05-27-workspace-cap-based-visibility.md`) — 5 codex rounds REJECT mostly over policy-helper placement + admin-bypass corner cases. The cap-vis SPEC itself was straightforward (`list_workspaces_for(caller, caps)`); the rounds went into "where does the helper live"; "does the helper match cross-workspace runtime semantics"; "does the helper handle the wildcard cap path"; "does the system-membership predicate live on Identity or Capability". Under CQRS/ES, "workspace visibility for caller" is a read-model query against a `workspace_visibility_per_caller` projection — the projection encodes the policy in one place at projection-time; the query at LV-read-time is `SELECT workspace_uri FROM ... WHERE caller_uri = ?`. Policy iteration happens in the projector, not at every read site, and the read site cannot drift from the policy.

The thread: **every multi-Kind workflow exposes a missing primitive in the current model — atomic cross-Kind operations, deterministic saga resumption, queryable historical state, single-place policy projection.** CQRS/ES provides each of these as a framework feature. The current model rebuilds each one ad-hoc per SPEC, and each ad-hoc rebuild costs 3-5 codex rounds.

### 1.3 Diagnosis — current architecture has CRUD but no event log

The current ezagent state model is structurally:

```
External request (LV / CLI / Feishu / MCP / HTTP)
  → Adapter constructs %Invocation{}
  → Invocation.dispatch/1
    → Idempotency check (step 1)
    → ReadyGate gate (step 4)
    → Kind.Runtime.handle_dispatch (steps 5-10):
      - BehaviorRegistry lookup
      - CapBAC step 5.5
      - Workspace isolation step 5.6
      - Behavior.invoke/4 — returns {:ok, new_slice} | {:ok, new_slice, result}
      - Kind.Server merges new_slice into state.state[slice_key]
      - Persistence write (if :on_change and changed)
      - Telemetry emit
    → reply/2 routes result to caller
```

State mutation is **CRUD-shaped**: each `Behavior.invoke/4` is a function `(slice, args) -> new_slice`. There is no formal command/event split. The audit log (`invocations` table) is a side-channel recording of `(caller, target, action, result)` tuples written by a telemetry handler — it is NOT the source of truth (the slice/snapshot is). Cross-Kind workflows are sequences of `Invocation.dispatch/1` calls strung together imperatively in caller code (e.g. `EzagentDomainChat.create_session/3` orchestrates 5 dispatches across 4 Kinds with try/rescue cleanup at each step).

The shape this leaves us with:
- **No formal command** — `Behavior.invoke/4`'s `args` argument is just a map; there is no Command struct, no router, no central catalog of what commands exist.
- **No formal event** — `Behavior.invoke/4`'s return is a new slice + optional result; the slice mutation is not named, not durable, not subscribable.
- **No saga primitive** — multi-Kind orchestration is imperative caller code with manual try/rescue cleanup; partial-failure compensation is ad-hoc per call site.
- **No replay** — restart restores the latest snapshot only; the history between snapshots is lost (audit table is a side-channel, not replayable into Kind state).
- **No subscription** — LV reads slice directly via `Kind.get_slice/2` (sync `GenServer.call`); to react to a slice change, LV must poll OR rely on `Phoenix.PubSub` broadcasts from Behavior code (e.g. `Behavior.Chat` broadcasts `:message_appended`). Each broadcast is opt-in per Behavior; there is no automatic event stream.

### 1.4 Hypothesis — CQRS/ES provides the missing primitives structurally

Commanded + EventStore provides:
- **Command** as a struct, dispatched through a router with `:identify` clauses that route by aggregate UUID. Catalog is the router config.
- **Event** as a struct, emitted by `Aggregate.execute/2`, persisted to the event stream BEFORE `Aggregate.apply/2` mutates the in-memory state. Audit is the event stream.
- **Aggregate** as a process, restored from event replay (+ optional snapshot every N events). State IS derived from events.
- **Process Manager (Saga)** as a stateful event subscriber that emits commands in response to events. Multi-aggregate workflows are explicit + resumable + compensable.
- **Projection** as an event-subscribing read-model updater (Ecto-backed via `commanded_ecto_projections`). LV reads the projection table; the projector updates it from events. Read-model decoupling is built-in.
- **Consistency mode** — `dispatch(cmd, consistency: :strong)` blocks until strong-consistent projectors have caught up; `:eventual` returns immediately. The read-after-write problem is a flag at dispatch time, not a hand-rolled wait loop.

Every one of §1.2's pain points dissolves to a framework primitive. The migration cost is real (Phase plan in §6), but the recurring cost of NOT migrating is 3-5 codex rounds per SPEC that touches a multi-Kind workflow — and we have one or more such SPECs every week.

---

## 1.5 Alternatives considered — native-Phoenix lighter paths

Before adopting Commanded + EventStore — a 3-month migration that retires `Kind.Server`, `KindRegistry`, `SpawnRegistry`, `Audit.Writer`, `Persistence` (for slices), and introduces Postgres into the dev loop — what could the BEAM/Phoenix ecosystem solve §1's pain points with using **native primitives or lighter pure-Elixir libraries**?

This section steel-mans the lighter path. Allen's directive (2026-05-28 08:15): the SPEC must self-justify why Commanded specifically, not "the heaviest hammer wins by default." Per `feedback_let_it_crash_no_workarounds`, false ❌s here would be the same anti-pattern as manufactured Commanded-only advantages — both hide structural truth.

### 1.5.1 The 5 candidate lighter paths

| Path | Library / Pattern | Stars / Age / Stability |
|---|---|---|
| **L1** | Pure [`Ecto.Multi`](https://hexdocs.pm/ecto/Ecto.Multi.html) — tighter transaction scope | builtin (`ecto_sql`) — every Phoenix app already has it |
| **L2** | [Sage](https://github.com/Nebo15/sage) — pure-Elixir saga compensation | 962⭐, dep-free, last release Sep 2022 (stable; not actively-developed but production-used) |
| **L3** | [ex_audit](https://github.com/ZennerIoT/ex_audit) — Ecto changeset → audit log w/ revert | 380+⭐, active maintenance |
| **L4** | [Oban Pro Workflow](https://oban.pro/docs/pro/1.5.0-rc.7/Oban.Pro.Workflow.html) — DAG of jobs with deps + compensation | paid lib, mature, in active dev |
| **L5** | DIY GenServer + append-only event journal table (no library) | builtin |

(`Honeydew`, `Flow`, `GenStage` were considered and rejected outright — they solve concurrency / streaming, not multi-aggregate atomicity or audit. Not listed.)

### 1.5.2 Pain-point matrix — each lighter path vs each §1 pain point

| # | Pain point (from §1) | L1 Ecto.Multi | L2 Sage | L3 ex_audit | L4 Oban Workflow | L5 DIY event log | Commanded |
|---|---|---|---|---|---|---|---|
| **P1** | Cross-Kind destroy cascade — 7 steps, compensation on partial failure | ❌ same-DB-transaction only; cross-Kind = cross-process | ⚠️ canonical compensation pattern, BUT state is in-memory across `execute/1` — mid-cascade crash leaves orphan; needs **durable saga log / outbox (e.g. Oban) bolted on** for cross-restart resilience | — (not a workflow lib) | ✅ async-only — caller doesn't see result synchronously | ✅ feasible — but you're hand-rolling Sage | ✅ Process Manager — durable state across crash/restart natively |
| **P2** | Audit log queryable by ad-hoc SQL ("what caps did user X hold yesterday at 14:00?") | ⚠️ partial — needs side `audit_log` table maintained by hand | — (not an audit lib) | ✅ canonical — `Ecto.Changeset` → `version_table` row, SQL-queryable | — (not an audit lib) | ✅ DIY — same data shape as ex_audit, but you maintain the trigger | ⚠️ event stream is the audit, but **NOT directly SQL-queryable** — needs an `audit_projection` table populated by an event handler (an extra hop ex_audit doesn't need) |
| **P3** | Cross-Kind workflow orchestration (session create cascade, worker bootstrap, cap-grant verify) | ❌ same as P1 — DB-transaction scope only | ⚠️ same single-call constraint as P1; multi-invocation flows (e.g. async worker bootstrap on `BindingCreated`) need PubSub + supervised GenServer + outbox instead | — | ✅ async, with retries | ✅ DIY | ✅ Process Manager with persistent state across invocations |
| **P4** | Race conditions (read-then-lock, grant-time cap check, register/lookup parity) | ✅ — tighter Ecto.Multi + DB constraints (unique index, exclusion constraint, FK cascade) is the canonical answer | — (Sage is an orchestration lib; races are not in its scope — L1 owns this row) | — | — | ✅ — DIY w/ DB constraints | ⚠️ — **same problem, different location** — aggregate-process serialization is identical to current `Kind.Server.handle_call` serialization; the actual race fix is DB constraints regardless of model |
| **P5** | Time-travel replay / "rebuild state at timestamp T from history" | ❌ | ❌ | ⚠️ — data is there (audit table), but no replay-into-state machinery | ❌ | ⚠️ — DIY (you have events, write a replay fn) | ✅ — aggregate state IS derived from event replay; this is the native primitive |

**Honest cell semantics**: ✅ = the path solves this pain point with the named mechanism. ⚠️ = partial / needs an extra hop or carries a documented caveat (see §1.5.3 per-scenario). ❌ = the path doesn't address this dimension. "—" = not in scope for this lib (don't penalize a lib for being focused).

**r6 codex-fix note**: r5 marked Sage ✅ for P1/P3 and P4. r6 codex review (HIGH-2 + MED-1) downgraded Sage P1/P3 to ⚠️ because Sage state is in-memory across `execute/1` — durable cross-restart resilience requires Path B to bolt on an outbox (e.g. Oban) or accept the gap. Sage P4 dropped to "—" because Sage is an orchestration lib, not a race-fix; L1 (Ecto.Multi + DB constraints) is the explicit P4 owner.

### 1.5.3 Per-scenario deep dive

#### P1 — destroy cascade (the trigger for this whole SPEC)

**Sage solves this directly.** The 7-step cascade in §3.8 maps to Sage's `run/compensate` pairs:

```elixir
defmodule Ezagent.DestroyAgent do
  import Sage

  def destroy(agent_uri, workspace_uri) do
    new()
    |> run(:snapshot,           &capture_pre_destroy_snapshot/2, &noop_compensate/3)
    |> run(:revoke_caps,        &revoke_all_caps_held_by/2,      &restore_caps_from_snapshot/3)
    |> run(:destroy_children,   &destroy_child_agents/2,         &respawn_children/3)
    |> run(:drop_memberships,   &drop_all_session_memberships/2, &restore_memberships_from_snapshot/3)
    |> run(:unlink_lineage,     &unlink_lineage/2,               &relink_lineage_from_snapshot/3)
    |> run(:terminate,          &terminate_agent/2,              &noop_compensate/3)
    |> run(:audit,              &write_destroy_audit_row/2,      &noop_compensate/3)
    |> execute(%{agent_uri: agent_uri, workspace_uri: workspace_uri})
  end

  defp restore_caps_from_snapshot(error, effects_so_far, %{agent_uri: uri}) do
    Ezagent.Capability.restore_for(uri, effects_so_far.snapshot.caps)
    {:ok, :restored}
  end
end
```

This is the **canonical** Sage pattern. Sage's contract is exactly what §3.8's DestroyAgentSaga needs: each step has a forward action + a compensate action; if step N fails, compensations 1..N-1 run in reverse. Sage handles the orchestration; the steps are just functions.

**Concrete failure modes**:
- Sage compensations MUST NOT raise (semantically — if a compensate fails, the saga aborts in an undefined state). This is the same constraint Commanded Process Managers have (a `handle/2` clause that raises during compensation is equally fatal). Not a Sage-specific weakness.
- **Sage state is in-memory across the `execute/1` call (r6 codex HIGH-2)**. If the orchestrator process crashes mid-execute — BEAM node restart, `kill -9`, OS reboot, supervisor restart — the saga loses progress and we're left with partial state. Commanded Process Managers persist their state in the event store, so cross-restart resume is native.
  - The r5 draft argued "we haven't observed a mid-cascade crash in 6 months of dogfood." Codex correctly flagged that **destroy hasn't shipped yet** — "no observed incidents" is not evidence for a feature that has not been exercised at scale. The honest position: we don't know how frequent mid-cascade crash will be.
  - **Path B mitigation requirement**: companion Path B SPEC MUST include a durable saga log (Oban as outbox candidate, or a hand-rolled `saga_executions` table) so a partial cascade can be resumed or compensated after BEAM restart. Without this, Path B has a real correctness gap vs Commanded.

**Honest verdict for P1**: Sage solves the destroy cascade IF the Path B SPEC includes a durable saga log / outbox. Without that, Commanded Process Manager has a genuine resilience advantage. Verdict assumes the mitigation lands in Path B.

#### P2 — audit log queryable by ad-hoc SQL

The SPEC's §1.3 diagnoses the current audit table as a "side-channel telemetry recording" (`(caller, target, action, result)` tuples written by a telemetry handler). The needed shape is: "for any historical SQL query (who had cap X at time T; what was session S's member list yesterday at 14:00), the answer is in a queryable table."

**`ex_audit`** is the canonical pure-Phoenix answer:

```elixir
schema "capabilities" do
  field :uri, :string
  field :scope_uri, :string
  field :verb, :string
  field :holder_uri, :string
  # ex_audit injects:
  # - changes table tracking every Ecto.Changeset mutation
  # - SQL-queryable: `from c in CapabilityVersion, where: c.holder_uri == ^uri and c.recorded_at < ^t`
end
```

The audit table is **directly SQL-queryable**. No projection step, no event-replay-then-fold.

**By contrast**: Commanded's event stream IS the audit log, but querying "what caps did user X hold at time T" requires either:
1. A purpose-built `caps_history_projection` table populated by a `CapsHistoryProjector` (extra hop, extra LOC, projector lag is a thing), OR
2. Replaying X's aggregate event history up to T (server-side, slow, only works for one aggregate at a time).

For ad-hoc admin queries — the kind a human types into psql to debug an incident — `ex_audit` + raw SQL **beats** Commanded's event stream. The event stream wins on "subscribe to future audit entries" (Commanded handlers) but loses on "answer this historical SQL question."

**Honest verdict for P2**: ex_audit is BETTER than Commanded's event stream for the SPEC's stated audit need. Commanded's audit-via-events is a downgrade for SQL-ergonomic queries.

#### P3 — cross-Kind workflow orchestration

Same shape as P1. Sage handles `CreateSessionSaga`, `CreateUserInWorkspaceSaga`, `BootstrapWorkerSaga`, `RevokeCapCascadeSaga`, `CapGrantOwnershipVerifySaga` identically — each is `new() |> run(...) |> run(...) |> execute(ctx)`.

**The one differentiator**: Sage's state is in-memory across `execute/1`; if you need a workflow that spans multiple separate caller-invocations (e.g. "user clicks Create, then 30s later worker bootstraps async after binding event"), Sage's single-execute scope doesn't fit — you'd implement it as two separate Sages each in their own caller. Commanded PM's persistent state would carry across.

**But**: looking at the §4.4 saga inventory:
- `DestroyAgentSaga`, `DestroyUserSaga`, `DestroySessionSaga`, `DestroyWorkspaceSaga`: all single-call cascades. Sage fits.
- `CreateSessionSaga`, `CreateUserInWorkspaceSaga`: single-call. Sage fits.
- `BootstrapWorkerSaga`: triggered by `BindingCreated` event in a separate transaction. **This one** is genuinely event-driven across caller boundaries — Sage doesn't fit, but neither do you need it as a saga in the native model; it's just a `Phoenix.PubSub.subscribe(:bindings)` + handler in a supervised GenServer. The "saga" framing is a Commanded-shaped solution to a problem that doesn't exist outside CQRS.
- `RevokeCapCascadeSaga`: triggered by membership revoked. Same as bootstrap — PubSub handler suffices.
- `CapGrantOwnershipVerifySaga`: this is a SINGLE-COMMAND check (verify granter has cap, then either grant or reject). It's not a saga at all — it's a guard clause. The "saga" framing is over-modeling.

**Honest verdict for P3**: 5 of the 9 sagas in §4.4 are single-call cascades → Sage handles (with the P1 durability caveat). 2 are event-triggered cross-call → PubSub handler in a supervised GenServer; **these need an outbox to survive worker restart between event arrival and effect application** (an Oban job per event-trigger is the canonical solution). 2 are not sagas at all. Commanded's framing inflates the count, but Commanded does carry the cross-restart durability natively where Sage requires bolt-on.

#### P4 — race conditions (read-then-lock, grant-time check, register/lookup parity)

This is the pain point where §1's hypothesis is **weakest** under scrutiny.

§1.4 claims: "Under CQRS/ES, the granter's caps at grant time are derivable from the granter Aggregate's event-replayed state at the instant the grant command was applied; the aggregate-level serialization gives the same property."

**Read that again**: "aggregate-level serialization gives the same property." That's literally the current model. `Kind.Server.handle_call` serializes per-instance; a `Commanded.Aggregates.Aggregate` process serializes per-aggregate-UUID. Same shape. The race fix isn't event-sourcing — it's process-serialization-per-key. Both models have it.

The **actual** race fix, the one cap-vis-SPEC + URI-canonical-SPEC converged on, is:
1. Unique indexes (`uri` column NOT NULL UNIQUE on every entity table)
2. Exclusion constraints where two grants on the same scope/verb pair can't coexist
3. Foreign key cascade (delete user → cascade caps held)
4. Tighter `Ecto.Multi` transaction boundaries (the grant + the audit row in one transaction)

These are DB-level constraints. They work regardless of Commanded vs current model. Commanded doesn't add anything to race resolution — it just relocates the serialization point from `Kind.Server` to `Commanded.Aggregates.Aggregate`. The races that DB constraints fix are fixed in both. The races that aggregate serialization fixes are also fixed by `Kind.Server` serialization today.

**Honest verdict for P4**: Commanded does NOT solve races better than the current model. The fix is L1 (tighter Ecto.Multi + DB constraints), regardless of which actor model wraps it.

#### P5 — time-travel replay

This is the ONE pain point where Commanded has a structural advantage no lighter path matches. Aggregate state IS event-derived; rewinding to time T means replay events up to T and you have the historical state. Native Elixir + ex_audit gives you the audit data, but rebuilding "what was the slice at time T" requires hand-rolled fold-over-history code per Kind.

**Critical question — has ezagent ever needed replay?**

Searching the docs/ futures, IMPLEMENTATION_ROADMAP, and codex-rejection trail for "replay", "time-travel", "rebuild state at T":
- §3.7 mentions replay as a Commanded capability (positive framing).
- §1.4 lists "no replay" as a current-model gap.
- **Within §1.5's review scope** the cited search of docs/issues cannot be verified by a reviewer reading §1.5 in isolation (r6 codex HIGH-1). The r5 draft asserted "nothing on the roadmap" without inline evidence; this r6 downgrades the claim to **"replay is not currently evidenced as a roadmap item HERE in §1.5; the verdict assumes Allen confirms during grill-with-doc."**
- The destroy-cascade resume-after-crash story is the closest analog, and that's solved by Sage compensation + **durable saga log mitigation** (see P1).

**Plausible future drivers for replay** (so reviewers can sanity-check whether they're imminent):
- **Regulatory compliance** — e.g. SOC 2 / GDPR "show the state of user X's caps at 2025-09-12 14:00 UTC" demands reconstructable historical state. ezagent doesn't currently serve regulated workloads but may. If we ship to enterprise B2B, this becomes table stakes.
- **AI training data reconstruction** — replaying historical agent conversation + tool-call state for offline RLHF datasets. Not on the roadmap but plausible 12-month horizon.
- **Post-incident debugging** — rewinding system state to reproduce a bug that depended on specific historical config. Currently we patch forward; replay would make root-cause faster.
- **Schema migration backfill** — if we add a new derived field, replay events to compute the value for all historical instances. Current model needs per-Kind backfill scripts.

**Migration cost back to Commanded if Option B ships first and replay becomes needed later**:
- Add event-log infra (Postgres + `eventstore` lib): 1-2 weeks
- Per-Kind: dual-write to event log alongside current writes for cutover window: 2-3 weeks
- Per-Kind: write `apply/2` event-fold + state-from-events handler: 1-2 weeks per Kind × 5 Kinds = ~7 weeks
- Saga rewrite from Sage → Commanded PM: 1-2 weeks
- Production cutover + tail-event-drain: 1 week
- **Total: ~3-4 months wall-time**, comparable to a fresh Option A migration today. **The migration cost is NOT free if we defer.**

**Honest verdict for P5**: Replay is the ONE structural Commanded-exclusive advantage. The r5 claim "not on the roadmap" survives if Allen confirms it during grill-with-doc. If replay becomes a roadmap item in 12-24 months, the Option B → Option A migration cost is ~3-4 months — comparable to doing Option A today, so **the verdict is "defer migration cost unless replay enters the requirement set this calendar year."**

### 1.5.4 Library risk + dependency posture (r6 — codex HIGH-3 fix)

The r5 verdict didn't price ongoing dependency risk for Sage + ex_audit. Codex flagged this as a HIGH gap. Here's the honest posture:

| Lib | Last release | LOC | Ecto coupling | Fork-and-maintain cost if abandoned | Recommended posture |
|---|---|---|---|---|---|
| **Sage** | 2022-09 | ~400 (pure Elixir, dep-free) | none — operates on plain maps | Low — single-file core, ezagent could vendor + maintain in-tree if needed | Pin minor version; CI fixture; annual health audit |
| **ex_audit** | 2023-02 | ~1500 | tight — wraps `Ecto.Changeset` lifecycle | Medium — Ecto API drift could break it; fork+maintain would cost 1-2 dev-weeks per major Ecto bump | Pin minor; vendor-as-needed; if 12-month no-release, switch to DIY `Ecto.Multi` + audit_log table (P2 cell L5 is the fallback) |

**Five-year scenarios + mitigations**:
1. **Sage abandoned, BEAM/Elixir 27+ breaks something** → vendor Sage core in `apps/ezagent_common/lib/ezagent/sage_local.ex` (single file, ~400 LOC). Low-risk fork.
2. **Ex_audit abandoned, Ecto 4.x renames `Ecto.Changeset` internals** → swap to L5 DIY pattern: `audit_log` table populated by `Ecto.Multi` callbacks. ~2-week migration. The data format is identical (changeset diff per row), only the writer changes.
3. **Both abandoned simultaneously + Elixir community drift** → unlikely correlated risk, but the L1+L5 DIY fallback still works on stock Ecto. Worst case: Path B's "Sage + ex_audit" surface becomes "thin DIY orchestration + thin DIY audit," still no Commanded migration needed.

**The mitigation cost is bounded** (~2-4 weeks if both libs go cold). Compare that against Option A's 3-month upfront migration: **even worst-case Option B → DIY pivot is cheaper than Option A's day-one cost.** Library staleness alone doesn't flip the verdict to Option A; it does require pin discipline + annual audit.

### 1.5.5 Verdict (r7 — Option B'' primary; Option B first fallback; Option A second fallback)

**Option B'' (native consolidation) — recommended primary path** (see §1.5.7 for full design). ~880 LOC across 5 new internal modules (`Ezagent.EventLog`, `Ezagent.SnapshotStore`, `Ezagent.Kind.StateRebuilder`, `Ezagent.SagaRunner`, `Ezagent.EventSubscriber`), ~2-3 weeks day-1 cost. Names the ES primitives already in the running codebase and adds the missing 30% (formal command/event split as opt-in, SagaRunner contract, EventSubscriber behaviour, generalized StateRebuilder). **Crucially: B'' shrinks the eventual migration cost to Commanded from Option B's ~10-12 weeks to ~4-6 weeks** (swap 3-4 internal module implementations), so adopting B'' does NOT close the Commanded door — it makes it cheaper to walk through when needed.

**Option B (Sage + ex_audit + Ecto.Multi + Oban outbox) — first fallback** if B'' design fails codex review or impl drafting hits a structural snag. Conditional on three predicates from r6:

- **(a)** Library-risk audit (§1.5.4) confirms Sage + ex_audit fork-and-maintain costs are acceptable for ezagent's 5-year posture.
- **(b)** Path B SPEC's saga design includes a **durable saga log / outbox** (Oban as outbox candidate) for cross-restart resilience.
- **(c)** Replay (§1.5.3 P5) confirmed by Allen as NOT a roadmap item for the next 12 months.

**Option A (Commanded full migration per §2-§12) — second fallback** if BOTH B'' and B prove infeasible, OR if replay (P5) becomes a roadmap item within the next 6 months. Commanded's durable-state primitives + event-log replay become differentiators worth the 3-month migration cost.

Aggregate cost comparison across all four options:
- **Option A (Commanded)**: 3-month migration, retire 7 internal modules, introduce Postgres to dev loop, +5x dispatch latency hot-path (per §7.1), 1500-2000 LOC saga code (per §4.4), every aggregate's snapshot tuning is a new ops knob.
- **Option B (lighter + outbox)**: ~3-4 weeks to add Sage + ex_audit + Oban (outbox), write 9 Sage modules (~50-150 LOC each), build saga-execution outbox table + worker, tighten Ecto.Multi scopes in existing domain modules, retire 0 internal modules, no dev-loop change, no latency hit, BUT inherits Sage 2022-09 + ex_audit 2023-02 staleness risk.
- **Option B' (DIY Ecto.Multi + DIY event log)**: ~4-5 weeks, ~1200-1800 LOC, no dependency risk, but every team writes its own orchestration / audit / constraints pattern → drift over time.
- **Option B'' (native consolidation)**: **~2-3 weeks, ~880 LOC, no new umbrella apps, no Postgres in dev loop, no retired modules, no dependency risk.** Names the structural primitives already in the code; preserves the option to migrate to Commanded later at ~4-6 weeks instead of ~10-12.

**Verdict: B''**. Allen 2026-05-28 09:33 directive. The verdict is no longer "conditional Option B" — B'' replaces Option B as the top recommendation because it dominates on every comparison axis except "long-term replay native today" (which only Option A wins, and is deferred per (c) above for both B and B''). See §1.5.7 for the full design + §1.5.7.6 for the comparison table.

### 1.5.6 What changes downstream of this verdict

This SPEC was drafted with the implicit assumption that the destroy-cascade 4-round codex failure (§1.1) required CQRS to resolve. **That assumption is now contested by §1.5.7's premise (§1.5.7.1)**: ezagent has been DIY-implementing the ES primitives organically for the last 9 months — the `invocations` table IS an append-only event log; `kind_snapshots` IS aggregate snapshots; `Behavior.invoke/4` IS a combined `execute + apply`; `ExternalMirror.BootReconciler` IS state recovery. The destroy cascade is solvable by naming + connecting what's already there (SagaRunner from §1.5.7.4 module #4) + the missing 30% from §1.5.7.

Concrete next steps (NOT committed by this SPEC — these are recommendations for Allen):

1. **Pause PR #442** (do not merge §2-§12 as-is; the Decision is now superseded by §1.5.7's B'' recommendation).

2. **Draft five companion B'' SPECs**, one per new module from §1.5.7.4. Each is small + independent + landable in 2-3 weeks:
   - `2026-05-28-ezagent-eventlog-naming.md` — name the existing audit-writer pipeline as `Ezagent.EventLog`; add `stream_by_aggregate/2` query helper; ~150 LOC
   - `2026-05-28-ezagent-snapshotstore-naming.md` — consolidate `Snapshot.Writer` + `Kind.Snapshot` policy logic under `Ezagent.SnapshotStore`; add `:tolerate_failure` explicit flag; ~200 LOC
   - `2026-05-28-ezagent-saga-runner.md` — inline ~200 LOC `Ezagent.SagaRunner`; rewrite §4.4's saga inventory (destroy cascade, session-create, etc.) against it; replaces ad-hoc `try/rescue` in current call sites
   - `2026-05-28-ezagent-event-subscriber.md` — name the `Ezagent.EventSubscriber` behaviour; refactor the 2 existing PubSub-driven cross-call workflows (ExternalMirror worker bootstrap, RevokeCapCascade) onto it; ~250 LOC
   - `2026-05-28-ezagent-state-rebuilder.md` — lift `Kind.Server.init/1` recovery into the `Ezagent.Kind.StateRebuilder` behaviour; generalize `BootReconciler` from ExternalMirror; ~80 LOC

   **Land order**: EventLog first (foundational); SnapshotStore next (no deps); SagaRunner third (solves the destroy cascade — the original §1.1 trigger); EventSubscriber fourth (refactors existing PubSub patterns); StateRebuilder fifth (sets up the per-Kind replay opt-in extension point). Each SPEC gets codex adversarial-review per `feedback_codex_review_every_pr`.

3. **If the 5 B'' SPECs ship and land**: this SPEC (#442) can be closed `wontfix-superseded-by-B''` with §1.5 preserved as the rationale. The §2-§12 Commanded material stays in git history for the future-replay-need scenario.

4. **If B'' design fails review badly** (e.g. one of the 5 module shapes can't be made backward-compatible with existing Behaviors): fall back to **Option B** (Sage + ex_audit + Ecto.Multi + Oban outbox) per §1.5.5 conditions (a)(b)(c). The r6 framing of Option B remains the rigorous fallback contract; the §1.5.6 r6 "1 broad / 3 small SPEC" guidance still applies if Option B activates.

5. **If replay (P5) becomes a roadmap item within 6 months**: trigger the second fallback — Option A (Commanded full migration per §2-§12). B'' makes this migration ~4-6 weeks (swap 3-4 internal module implementations) instead of starting from scratch.

6. **If both B'' and Option B prove infeasible**: revisit Option A as primary. The Path B → Option A migration cost is ~3-4 months wall-time per §1.5.3 P5; the B'' → Option A migration is ~4-6 weeks per §1.5.7.5(e); neither is catastrophic.

### 1.5.7 Native consolidation path (Option B'') — formalize what ezagent already builds, informed by Commanded

Allen's directive 2026-05-28 09:33 — promoting a new top recommendation. Path B (Sage + ex_audit + Ecto.Multi + Oban outbox) treats event sourcing as **a third-party concern we attach selectively**. But on inventory, ezagent has been DIY-implementing the ES primitives **organically for the last 9 months** — just without ever naming them as such. Option B'' is "name what's there + add the missing 30%", informed by what Commanded learned the hard way.

This subsection corrects a structural mis-framing in §1.3 (acknowledged below in §1.5.7.1), surveys ezagent's existing ES primitives concept-by-concept against Commanded's canonical implementation (§1.5.7.2), sharpens the design with CQRS principles (§1.5.7.3), defines five new internal modules with extension points (§1.5.7.4), maps future growth scenarios (§1.5.7.5), and ends with a four-option comparison table (§1.5.7.6) plus the new recommendation (§1.5.7.7).

**B'' is not anti-Commanded; it is pro-future-Commanded.** Naming the abstractions correctly NOW keeps the migration window open and shrinks the eventual cost to "swap implementations of 3-4 internal modules" instead of "rewrite Kind/Behavior across 5 domains".

#### 1.5.7.1 — Premise: ezagent has been doing ES organically

§1.3 of this SPEC asserts:

> "There is no formal event log... [Behavior.invoke/4's] return is a new slice + optional result; the slice mutation is not named, not durable, not subscribable."

**This claim is partially incorrect.** Inventory of the running codebase (`apps/ezagent_core/` + `apps/ezagent_domain_*/`, paths verified against `/Users/h2oslabs/Workspace/esr-ng` checkout):

| ES concept | ezagent primitive | Source of truth |
|---|---|---|
| Event log (append-only) | `invocations` table — `(id, trace_id, caller, target, action, args, result, duration_us, authz, exception, inserted_at)` | `apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:6` |
| Event writer | `Ezagent.Audit.Writer` — telemetry-handler-fed `GenServer`, 100ms-batched `Repo.insert_all/2` flush | `apps/ezagent_core/lib/ezagent/audit/writer.ex:45` |
| Aggregate snapshot | `kind_snapshots(uri PK, kind_type, state_binary, state, version, workspace_uri, inserted_at, updated_at)` | `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex:25` |
| Snapshot writer (sync) | `Ezagent.Kind.Snapshot.save_now/3` — strict, raises on infra failure | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:319` |
| Snapshot writer (async batched) | `Ezagent.Snapshot.Writer.async_save/3` — 100ms-batched, latest-per-URI wins | `apps/ezagent_core/lib/ezagent/snapshot/writer.ex:45` |
| Snapshot policy | `:on_change` (sync, post-dispatch) / `:on_terminate` / `{:periodic, ms}` / `:ephemeral` / `:external` | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:51` |
| Aggregate process | `Kind.Server` GenServer, one per URI, serialized `handle_call` | `apps/ezagent_core/lib/ezagent/kind/server.ex` |
| Aggregate identity routing | `Ezagent.KindRegistry` + `Ezagent.SpawnRegistry` (URI → pid) | `apps/ezagent_core/lib/ezagent/kind_registry.ex` |
| Aggregate command-execution | `Behavior.invoke(action, slice, args, ctx) :: {:ok, new_slice, result} \| {:error, _}` | `apps/ezagent_core/lib/ezagent/behavior.ex:106` |
| State recovery from snapshot | `Ezagent.Kind.Snapshot.load_or_init/3` — pulls snapshot, canonicalizes URIs, prunes orphan slices, runs `reconcile_after_load/2` per Behavior | `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:51` |
| Boot reconciliation | `Ezagent.ExternalMirror.BootReconciler` — scans `external_mirror_bindings`, idempotently spawns Sessions; bounded retry loop | `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/boot_reconciler.ex` |
| Slice-change broadcast cursor | `Ezagent.SliceChange.Cursors.next/1` — pre-allocated per dispatch, used as ring-buffer key | `apps/ezagent_core/lib/ezagent/kind/runtime.ex:110` |
| Pre-dispatch pipeline | `Ezagent.Kind.Runtime.handle_dispatch/4` — authz (5.5), workspace isolation (5.6), arg validation, then `invoke/4`, then post-commit slice-change emit | `apps/ezagent_core/lib/ezagent/kind/runtime.ex:70` |
| Idempotency token | `Ezagent.Idempotency` per `Invocation.dispatch/1` step 1 | `apps/ezagent_core/lib/ezagent/idempotency.ex` |

**Correction to §1.3.** The `invocations` table IS an append-only event log; it has **denormalized dispatch columns `(caller, target, action)` that are more SQL-ergonomic than Commanded's `eventstore` schema** (Commanded's `events` table is keyed `(stream_id, stream_version, event_type, data jsonb, metadata jsonb, created_at)`; caller/target/action would have to be extracted from `data` JSON via `jsonb_path` queries). The §1.3 framing ("audit table is a side-channel telemetry recording, NOT the source of truth") is half right (the SLICE is currently the source of truth, not the audit row) and half wrong (the audit row IS the event log in shape; it just isn't replayed).

**Honest acknowledgment (codex r7 LOW-6 closure, 2026-05-28)**: the `args` and `result` columns exist in the schema (`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:11,13`) but the **current `Audit.Writer` does NOT populate them on successful invocations** (`apps/ezagent_core/lib/ezagent/audit.ex:93-116` — only failure / error paths populate these). The table TODAY is "structured tuple of dispatch metadata"; calling it a complete domain-event payload overstates current shape. B'' commits to extending `Audit.Writer` / `EventLog.append/1` to capture full args + result for every dispatch as part of the SnapshotStore/EventLog naming SPECs (companion §1.5.6 list). The "more SQL-queryable than Commanded" comparison applies **after** the args/result are populated; today it's a shape advantage on caller/target/action only.

The honest gap is "ezagent does not REPLAY events to rebuild aggregate state" + "ezagent doesn't persist full command/result payloads in its event log YET"; not "ezagent has no event log".

**Acknowledged asymmetry (codex r7 — slice-per-Behavior vs single-aggregate-state)**: Commanded aggregates are SINGLE-MODULE — one struct + one `execute/2` + one `apply/2`. ezagent Kinds host MULTIPLE Behaviors per Kind (User registers Identity + UserCredentials + UserTokens + IdentityAdmin per `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:226-231` + `application.ex:271-284`). State is a map keyed by `behavior.state_slice()` — each Behavior owns ITS slice; cross-Behavior reads require an explicit `reads_sibling_slices/0` declaration. **The slice-per-Behavior model is a genuinely different aggregation model from Commanded's single-struct aggregate.** B'' does NOT pretend these are 1:1: when a Kind opts into events-as-truth, EVERY Behavior on the Kind must implement the CQRS triplet (§1.5.7.2.b) — i.e. the Kind's aggregate becomes a TUPLE of per-Behavior aggregates, with `apply_event/2` dispatched by event-type to the owning Behavior. A future Commanded migration must fuse these into one aggregate state struct OR split the Kind into multiple Commanded aggregates (one per Behavior); the SPEC does not pre-commit which. The B'' design preserves both options.

What's NOT yet there (the missing 30%):

- **No formal command struct** — `args` is a `map`, not a `%Command{}`. The catalog of valid commands lives implicitly in each Behavior's `interface/0`.
- **No formal event struct** — `Behavior.invoke/4` returns a new slice, not a list of events. The slice diff IS the event, but it isn't named or structured.
- **No replay** — `load_or_init/3` reads the latest snapshot; if you don't have a snapshot you start from `init_slice/1`. The `invocations` history between snapshots is not consulted.
- **No event-driven cross-Kind orchestration** — multi-Kind workflows are imperative caller code with `try/rescue` cleanup (e.g. `EzagentDomainChat.create_session/3`). The destroy cascade is the most acute example.
- **No projection / read-model split** — LV reads slice directly via `Kind.get_slice/2`. There is no eventually-consistent read view that subscribes to events.
- **No idempotency-on-command-id** — dispatch-level `Ezagent.Idempotency` keys on the `%Invocation{}` envelope, not on a `command_uuid` the caller supplies.

#### 1.5.7.2 — Concept-by-concept comparison: ezagent current → Commanded canonical → B'' refined

Each row tracks one ES concept across three columns: what ezagent has today (with file path), how Commanded does it (with code snippet from Commanded docs), and what B'' commits to (the refined design that lands in ezagent informed by Commanded's lesson but using ezagent's existing primitives).

##### a. Event log / EventStore

- **ezagent today** — `invocations` table (`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:6`), SQLite. `Audit.Writer` flushes 100ms-batched via telemetry on `[:ezagent, :invoke, :stop]`. Append-only (no UPDATE/DELETE in current code). Indexed on `(inserted_at)` and `(target, inserted_at)`. Stream-by-aggregate would be `WHERE target = ^uri_str ORDER BY inserted_at, id` (works today; just hasn't been named as such — and `args` + `result` columns exist but are not populated for successful dispatches today; codex r7 LOW-6 correction below).
- **Commanded** — `commanded_eventstore_adapter` writes to PostgreSQL `events` table. Stream identity = `<identity_prefix><aggregate_uuid>`. Append is per-stream with optimistic-concurrency-check (expected_version). Per the docs: "an open-source event store using PostgreSQL for persistence."
- **B'' design** — `Ezagent.EventLog` module wraps the existing `invocations` table. Public API:
  ```
  Ezagent.EventLog.append(envelope :: map) :: :ok | {:error, term}
  Ezagent.EventLog.stream_by_aggregate(uri :: URI.t, opts) :: [event_row]
  Ezagent.EventLog.stream_by_workspace(ws :: URI.t, opts) :: [event_row]
  Ezagent.EventLog.stream_since(cursor :: DateTime, opts) :: [event_row]
  ```
  No schema change; the existing telemetry-handler path becomes the `append/1` implementation. **Extension point** `Ezagent.EventLog.replay_aggregate/2` is documented in §1.5.7.4 but NOT included in v1 (no Kind yet declares events-as-truth). Optimistic-concurrency check is also Phase 2 — v1 leans on `Kind.Server` GenServer serialization for the same property.

##### b. Command / Event separation

- **ezagent today** — `Behavior.invoke(action, slice, args, ctx)` is a **combined** primitive: it decides what to do (command), mutates state (apply event), and may return a result. The slice diff is the implicit event payload. Source: `apps/ezagent_core/lib/ezagent/behavior.ex:106`, concrete example `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:297`.
- **Commanded** — separates `execute(state, %Command{}) :: [%Event{}]` (decide + emit) from `apply(state, %Event{}) :: new_state` (pure fold). Per Commanded docs: "multiple events can be generated from a single command... aggregate apply functions are invoked between execution steps to maintain updated state for subsequent operations." Snippet:
  ```elixir
  def execute(%BankAccount{state: :active} = acct, %WithdrawMoney{amount: amt}),
    do: [%MoneyWithdrawn{account: acct.id, amount: amt, new_balance: acct.balance - amt}]

  def apply(%BankAccount{} = acct, %MoneyWithdrawn{new_balance: nb}),
    do: %{acct | balance: nb}
  ```
- **B'' design** — DON'T require this split for every Behavior on day-1; that's a breaking change to 24 modules. Instead, **make the split the future extension shape**, and be **explicit that legacy `invoke/4` Behaviors are excluded from events-as-truth replay**:
  1. v1 keeps `Behavior.invoke/4` as-is. Internally, `Kind.Runtime.handle_dispatch/4` wraps each successful invoke as a **synthetic event** `%SliceMutated{kind_module, action, args, old_slice, new_slice, caller, at}` and appends to `EventLog`. This is what the slice-change cursor (line 110) already half-implements. **`%SliceMutated{}` is audit / notification / cross-Kind-trigger material ONLY — it is NOT a replay-safe event.** The slice diff cannot reconstruct the side effects `invoke/4` performed (PubSub broadcasts, `MessageStore.write`, cross-Kind `Invocation.dispatch/1`, external IO). Codex r7 review HIGH-1 (2026-05-28) made this explicit after concrete trace through `Behavior.Chat.invoke(:send)` (`chat.ex:297-370, 408-414`) showed `MessageStore.write` + PubSub broadcast + recipient dispatch all happen before the slice mutation returns — none of which `apply_event(%SliceMutated{}, slice) -> new_slice` could replay.
  2. New optional Behavior callback `events_for/4` — if a Behavior implements it, the synthetic-event fallback is replaced with the Behavior-emitted list. Signature: `events_for(action, slice, args, ctx) :: [%Event{}]`. The Behavior also gains `apply_event/2 :: new_slice` and `effects/2 :: [side_effect]`. **All three are required together for events-as-truth opt-in.** Default in the `@behaviour` is "events_for unimplemented → synthetic-event path → audit-only, no replay".
  3. Per-Kind opt-in: a Kind that wants events-as-truth declares **every** Behavior on the Kind implements `events_for/4` + `apply_event/2` + `effects/2` (the triplet is atomic per Behavior). The Kind's `persistence/0` returns `:replay_enabled` only when **all** Behaviors are CQRS-split. A `replay_readiness/1` invariant test enumerates every action × every Behavior and fails if any path lacks the triplet. Replay rebuilds slice via `EventLog.stream_by_aggregate + Enum.reduce(events, init_slice, &apply_event/2)`; effects are **NOT** re-executed during replay (they were already executed at original-dispatch time; replay is state reconstruction, not side-effect replay).

  **Why this matters**: ezagent stays shippable today (no Behavior rewrites). The first Kind that needs replay (P5 from §1.5.3) migrates ONE Kind at a time, **but the per-Kind migration cost is the full CQRS-split of every Behavior on that Kind — NOT just adding a callback to one Behavior.** Cross-Kind orchestration (B'' §1.5.7.4 module #4 SagaRunner) doesn't need event-split — synthetic events suffice as triggers because triggering is audit-shaped (read "what happened" + decide what to do next), not replay-shaped (rebuild state).

##### c. Aggregate identity

- **ezagent today** — `entity://kind/workspace/name` URI. Canonical via `Ezagent.URI.parse!/1` (the SPEC #324 / URI-canonical chokepoint). Routing via `Ezagent.KindRegistry` (URI → pid). One process per URI; concurrent dispatch serializes through `Kind.Server.handle_call`.
- **Commanded** — aggregate UUID, optionally with `identity_prefix`. Stream identity = `<prefix><uuid>`. One process per UUID; concurrent dispatch serializes via the aggregate process.
- **B'' design** — keep ezagent URI as Aggregate identity. Document the equivalence: ezagent URI = Commanded `<identity_prefix><uuid>` with `identity_prefix = ""` and `uuid = URI.to_string(uri)`. **No code change** — the property is already there; B'' just names it. If we ever flip to Commanded, the migration is a no-op for the identity layer (per `feedback_uuid_is_canonical_identifier`: the URI IS the identifier; we don't mint a parallel UUID column).

##### d. Snapshot

- **ezagent today** — `kind_snapshots` table; policy via `Ezagent.Kind.Snapshot` (`:on_change` sync, `:on_terminate` sync, `{:periodic, ms}` async via `Snapshot.Writer`, `:ephemeral`, `:external`). Snapshot stored as `:erlang.term_to_binary(state)` (lossless: MapSet, URI, DateTime, atoms).
- **Commanded** — opt-in per aggregate via `snapshot_every: N` (after every N events) + `snapshot_version: V` (bump to invalidate stale snapshots). Storage in the event-store schema's snapshot table. Replay reads latest snapshot first then folds events newer than the snapshot.
- **B'' design** — `Ezagent.SnapshotStore` module wraps `Ezagent.Ecto.KindSnapshot` + `Ezagent.Kind.Snapshot` policy logic. Public API:
  ```
  Ezagent.SnapshotStore.latest(uri :: URI.t) :: {:ok, state, version} | :empty
  Ezagent.SnapshotStore.write(uri, kind_module, state) :: :ok | {:error, term}
  Ezagent.SnapshotStore.delete(uri) :: :ok
  Ezagent.SnapshotStore.policy_for(kind_module) :: persistence_policy
  ```
  Policy stays at `:on_change` / `:on_terminate` / `{:periodic, ms}` (current ezagent shapes). **Extension point**: `every_n_events/1` policy variant (Commanded-shaped) lands WHEN any Kind opts into events-as-truth (because counting events presupposes events being emitted). Documented as Phase 2.

##### e. State recovery / Replay

- **ezagent today** — `Kind.Server.init/1` calls `Snapshot.load_or_init/3` → returns snapshot OR fresh `init_slice/1` output. No event-replay. Boot reconciler exists in **one** domain (`ExternalMirror.BootReconciler`) and rehydrates from a **projection table** (`external_mirror_bindings`), not from events. Allen 2026-05-26 task #34 added `reconcile_after_load/2` per Behavior (Kind.Snapshot:155) — a hook for amending merged state against a DB projection.
- **Commanded** — state = snapshot (if present) THEN fold events newer than the snapshot. Replay is automatic on aggregate process restart; the framework doesn't expose the choice.
- **B'' design** — `Ezagent.Kind.StateRebuilder` behaviour. Required callback `rebuild_from_snapshot(uri, snapshot_state) :: new_state`. Optional callback `rebuild_from_events(uri, snapshot_state, event_stream) :: new_state` — only Kinds that opted into events-as-truth (§1.5.7.2.b) implement this. Default `Kind.Server.init/1` calls `StateRebuilder.rebuild_from_snapshot/2` (current behavior); per-Kind opt-in `:replay_enabled` flag swaps in the events path. **Extension point**: `BootReconciler` becomes a generic `Ezagent.BootReconciler` (move from `apps/ezagent_domain_external_mirror/` to `apps/ezagent_core/`) parameterized by a Kind-supplied "rows-to-rehydrate" query. Today only ExternalMirror needs it; once generic, other Kinds can adopt it without copy-paste.

##### f. Saga / Process Manager

- **ezagent today** — ad-hoc PubSub handlers (e.g. ExternalMirror Worker subscribes to Session's `:slice_change` topic) + ad-hoc cross-Kind imperative code (e.g. `EzagentDomainChat.create_session/3` has 5 dispatches across 4 Kinds with `try/rescue` cleanup at each step). No common abstraction; each saga reinvents the resume + compensate primitives. **This is the strongest motivator for Commanded-shaped thinking** — every multi-Kind workflow is a one-off.
- **Commanded** — `Commanded.ProcessManagers.ProcessManager`: `interested?/1` selects events, `handle/2` returns commands to dispatch, `apply/2` mutates the PM's own state. PM state is event-store-persisted; cross-restart resume is native. Snippet:
  ```elixir
  def interested?(%TransferRequested{id: id}), do: {:start, id}
  def interested?(%TransferCompleted{id: id}), do: {:stop, id}
  def handle(state, %TransferRequested{from: from, to: to, amount: amt}),
    do: [%DebitAccount{account: from, amount: amt}]
  ```
  PMs conflate two distinct concerns: **single-call linear sagas** (destroy cascade — N steps in one caller's lifetime) and **event-driven cross-call workflows** (worker bootstrap on `BindingCreated` — fires asynchronously much later).
- **B'' design** — separate the two:
  1. **`Ezagent.SagaRunner`** — for single-call linear sagas. Take a list of `{forward_fn, compensate_fn}` pairs, execute in order, on failure reverse-compensate. State is in-memory across the call. (This is what Sage would give us; B'' inlines a ~200-LOC implementation instead of vendoring an unmaintained dep — per `feedback_let_it_crash_no_workarounds` we'd rather own the structural primitive than depend on a 2022-stale library that L2 in §1.5.2 already flagged as risk-bearing.)
  2. **`Ezagent.EventSubscriber`** — `@behaviour` for PubSub-driven cross-call workflows. Callbacks: `interested?(event) :: boolean | {:partition, key}` + `handle_event(event, state) :: [%Command{}]`. State persistence is Phase 2 extension (see §1.5.7.5(c)); v1 EventSubscriber state is in-memory.

  **Why split**: Commanded's PM tries to be both, and the data shape (PM-state-per-correlation-id) is overkill for a 7-step destroy cascade where the saga state IS the call stack. Conversely, an event subscriber doesn't need the rollback machinery (it didn't initiate the chain, it just reacted to it). Separating them gives each module the smallest possible contract.

##### g. Projection / Read Model

- **ezagent today** — slice IS the read model AND the write model. LV reads via `Kind.get_slice/2` (sync `GenServer.call`); writes via `Invocation.dispatch/1`. There is no eventually-consistent projection table — admin LV reads the live GenServer state, which is **strongly consistent** but couples LV ergonomics tightly to GenServer liveness.
- **Commanded** — `Commanded.Projections.Ecto` writes to projection tables via `project %Event{}, fn multi -> Ecto.Multi.insert(multi, ...) end`. Read = `Repo.all/get` on the projection table. Consistency mode (strong/eventual) is per-projector; strong-mode dispatch blocks until the projector catches up.
- **B'' design** — explicit read-model concept WITHOUT immediate cutover to projection tables:
  1. v1: `Ezagent.ReadModel` is a `@behaviour` with default impl `slice_via_kind_server(uri, slice_key)` (current behavior). LV uses `ReadModel.read(...)` instead of `Kind.get_slice(...)` — same return, named differently.
  2. Phase 2 extension: a Kind can opt into a backing projection table. The Behavior emits events; a `Commanded.Projections.Ecto`-shaped projector writes the projection; `ReadModel.read/2` flips to `Repo.get/all`. Strong consistency is preserved via Commanded's `consistency: :strong` flag (or B''-equivalent: dispatch blocks until projection catches up).

  **Why deferred**: the cap-vis SPEC (§1.2) is the canonical case for projection tables, and even there the slice-as-read-model has shipped for months without burning the team. B'' commits the contract (`ReadModel` behaviour), not the implementation.

##### h. Event versioning / upcasting

- **ezagent today** — no event versioning (no events as first-class). Snapshot `version` field exists but flips fail-loud on mismatch (`Kind.Snapshot:198`).
- **Commanded** — `commanded_event_handler` supports event upcasters via `Commanded.Event.Upcaster` protocol — read an old-schema event, return the new-schema event.
- **B'' design** — NOT in v1. Documented as Phase 2 extension point: once any Behavior implements `events_for/4` (§1.5.7.2.b), the corresponding `apply_event/2` clauses need versioning. The extension point lives in `Ezagent.EventLog.replay_aggregate/2` — it receives raw rows, calls an optional upcaster module to canonicalize old schemas, then feeds to `apply_event/2`. Until any Kind opts in, this is documentation only.

#### 1.5.7.3 — CQRS principles applied to sharpen B''

This is where B'' goes beyond "name what's there" into "design what's there *properly*." Each principle below cites a canonical source and shows the **concrete module-signature change** that lands in ezagent — not a rename, a structural shape change.

##### Command / Query separation (Greg Young, [cqrs.wordpress.com 2010](https://cqrs.wordpress.com/documents/cqrs-introduction/))

The principle: a function either mutates state OR returns data, never both. The same model should not serve writes and reads.

Where ezagent violates this today: `Behavior.invoke(action, slice, args, ctx)` is allowed to return `{:ok, new_slice, result}` — it mutates AND returns. Concrete example: `Behavior.Chat.invoke(:send, slice, %{message: msg}, ctx)` (`chat.ex:297`) writes to `MessageStore`, broadcasts via PubSub, computes recipients via `Routing.Resolver`, and returns the routing decision. Five side effects + a return value in one call.

**B'' refinement** — `Behavior.invoke/4` keeps its current shape (changing it across 24 modules is gold-plating); ADD two explicit hooks for the disciplined Behaviors that want CQRS:

```elixir
@callback execute_command(action, slice, args, ctx) :: [event] | {:error, term}
@callback apply_event(event, slice) :: new_slice
@callback effects(event, ctx) :: [side_effect]   # PubSub broadcasts, external IO, follow-up dispatches
```

`Kind.Runtime.handle_dispatch/4` gains a branch: if the Behavior implements the new triplet, use it; if it only implements legacy `invoke/4`, fall back to wrap-as-synthetic-event (§1.5.7.2.b). The hot path stays single-allocation; the disciplined path is opt-in.

Crucially: `effects/2` returns DECLARATIONS, not function calls. The Runtime is the only place that converts `%PubSubBroadcast{topic, payload}` into `Phoenix.PubSub.broadcast/3`. Behaviors become **pure** in the CQRS sense; side effects live at the dispatch boundary. This is what makes `apply_event/2` replay-safe (replay must NOT re-broadcast historical messages).

##### Event as the source of truth ([Martin Fowler, "Event Sourcing"](https://martinfowler.com/eaaDev/EventSourcing.html))

The principle: events are the immutable historical record; current state is **derived**; snapshots are a cache. Per Fowler: "Snapshots are purely derivative—the event log remains the system of record."

Where ezagent violates this today: snapshot IS the source of truth (`Kind.Snapshot.load_or_init/3` reads only snapshot; events between snapshots are not consulted). If the snapshot file gets corrupted but the event log is intact, the slice is gone.

**B'' refinement** — even though v1 keeps snapshot-as-truth for hot path performance, design the modules so the inversion is possible later:

1. `apply_event/2` must be **pure + total** for any Behavior that opts in. No DB reads, no time-of-day branches, no random. Replay-safety is a structural property, not a runtime check.
2. `Ezagent.EventLog.append/1` is the **only** write path that publishes a "state changed" signal externally. Today the `SliceChange` emit is gated on `Snapshot.commit/4` returning `:ok`; B'' tightens this to "gated on `EventLog.append/1` returning `:ok`". Snapshot becomes a downstream cache, written AFTER the event lands.
3. `Ezagent.SnapshotStore.write/3` must accept a `:tolerate_failure` flag (default true for `:periodic`, false for `:on_change`). A `:on_change` snapshot failure during the post-event window doesn't roll back the event — it merely retries on the next dispatch.

The cost is one extra write per dispatch for opted-in Kinds (event append + snapshot upsert). Per §7.1 the snapshot write is already there; the event append IS the existing audit-writer cast. **No new I/O.** What changes is the **ordering invariant**: event-append-first, snapshot-after.

##### Aggregate boundary discipline ([Vaughn Vernon, _Implementing DDD_](https://www.informit.com/store/implementing-domain-driven-design-9780321834577); [Commanded docs](https://hexdocs.pm/commanded/aggregates.html))

The principle: one command targets one aggregate. Cross-aggregate orchestration goes through a Process Manager / Saga. Two aggregates never mutate each other directly.

Where ezagent violates this today: `Behavior.invoke/4` can synchronously dispatch into any other Kind via `Ezagent.Invocation.dispatch/1`. Example: `Behavior.Chat.invoke(:send, ...)` dispatches `:receive` into every recipient Kind synchronously inside the sender's call stack. If recipient #3's GenServer is dead, the sender's call partial-fails after #1 and #2 already mutated.

**B'' refinement** — `Behavior.invoke/4` MAY dispatch into OTHER Kinds, but cross-Kind effects MUST be wrapped in:

- **`SagaRunner.run(steps, ctx)`** for synchronous linear cascades (destroy, session-create). Each step is `{forward_fn, compensate_fn}`. On step N failure, steps N-1..1 reverse-compensate. The current `try/rescue` cleanup pattern in `EzagentDomainChat.create_session/3` is a hand-rolled version of this.
- **`EventSubscriber`** for asynchronous cross-call workflows (worker bootstrap on `BindingCreated`).
- **NEVER from inside `Behavior.invoke/4` directly** for orchestration — `invoke/4` may emit ONE command-equivalent effect (the slice mutation), and may emit declarative `effects/2` (PubSub broadcast etc.), but it does NOT chain dispatches itself.

`Kind.Runtime.handle_dispatch/4` gains a structural check: if a Behavior's `invoke/4` calls `Ezagent.Invocation.dispatch/1` directly (detectable via process dictionary), log a warning telemetry `[:ezagent, :anti_pattern, :cross_kind_from_invoke]`. Phase 2 elevates to a hard fail; the warning lets us audit + refactor existing call sites first.

##### Eventual consistency for reads (Greg Young, [_CQRS Documents_](https://cqrs.files.wordpress.com/2010/11/cqrs_documents.pdf))

The principle: in a CQRS system, the read model lags the write model. Reads MAY be stale. Acceptance of staleness is the cost; horizontal scaling of reads is the benefit.

Where ezagent operates today: reads via `Kind.get_slice/2` are **strongly consistent** (sync GenServer.call returns the latest state). This is GREAT for LV ergonomics and for write-then-immediate-read parity (§4.8 of this SPEC). It's BAD for any read that doesn't need real-time freshness (e.g. admin dashboard listing every workspace's session count) — those reads compete for `Kind.Server` mailbox.

**B'' refinement** — keep slice-as-strong-consistent for the hot path (LV chat stream, dispatch-time authz check, write-then-immediate-read sites). EXPLICITLY model the eventual-consistent read path for FUTURE projection tables:

```elixir
Ezagent.ReadModel.read(uri, slice_key, consistency: :strong)   # default — current behavior
Ezagent.ReadModel.read(uri, slice_key, consistency: :eventual) # opts into projection table when one exists
```

v1 ignores the `consistency:` flag (slice is the only read source). Phase 2: per-projection migration flips specific read sites to `:eventual` against a backing projection table. The §4.8 consistency matrix becomes the LV-write-site source of truth for `:strong` requirements.

##### Idempotency (Greg Young, [_Idempotent commands_](https://buildplease.com/pages/idempotent-commands/))

The principle: a command has a stable identity; replaying the same command MUST be a no-op after the first success.

Where ezagent operates today: `Ezagent.Idempotency` keys on the `%Invocation{}` envelope but the key is the trace_id, not a caller-supplied `command_uuid`. The grant_cap retry-on-network-blip case in §3.7 is not idempotent: if the dispatch times out from caller's POV but succeeded server-side, the caller's retry creates a second grant.

**B'' refinement** — extend `Behavior.invoke/4`'s ctx with an OPTIONAL `:command_uuid` key. When present, `Ezagent.Idempotency.check_or_record/2` is called BEFORE `invoke/4` with the `command_uuid` as the dedup key. SagaRunner sets `command_uuid = "saga:<saga_id>:step:<N>"` automatically. Callers may pass their own (`POST /grants` HTTP handler mints a UUID from the request body hash). Without `command_uuid`, behavior is unchanged.

This closes the retry-storm gap without breaking existing call sites: no caller is forced to mint a UUID, but callers that DO get exactly-once semantics across crashes.

#### 1.5.7.4 — Concrete module hierarchy with extension points

Five new internal modules consolidate the existing primitives. Each lives under `Ezagent.*` (no new umbrella app — the goal is "name what's there", not "add another deployable").

##### 1. `Ezagent.EventLog`

**Signature**:
```elixir
@spec append(envelope :: map) :: :ok | {:error, term}
@spec stream_by_aggregate(uri :: URI.t, opts :: [from: DateTime.t, limit: pos_integer]) :: [event_row]
@spec stream_by_workspace(ws :: URI.t, opts) :: [event_row]
@spec stream_since(cursor :: DateTime.t, opts) :: [event_row]
```

**Design rationale**: thin facade over the existing `invocations` table. The envelope shape standardizes what telemetry handlers already write (`%{trace_id, caller, target, action, args, result, ...}`); `Audit.Writer` becomes one implementation of `append/1` (the batched one); a future Postgres-backed implementation drops in by swapping the module without changing callers. Stream-by-aggregate is the new helper that didn't exist before.

**Ordering contract (codex r7 MED-4 closure, 2026-05-28)**: `stream_by_aggregate/2` orders rows by `(inserted_at ASC, id ASC)`. The `id` column is the existing `invocations` primary key (`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:7`, monotonic integer). `inserted_at` alone is NOT stable under same-microsecond collisions (test batched inserts, high-throughput production) — the `id` tie-breaker makes the order total and stable across query reads. Cursor pagination uses the `(inserted_at, id)` pair as the cursor key: `WHERE (inserted_at, id) > (^cursor_at, ^cursor_id)`. This mirrors Commanded's `RecordedEvent`'s `(stream_version, event_number)` pair, just keyed on `(inserted_at, id)` since ezagent's invocations table predates the per-stream-version-counter design. Phase 2 extension point: if `expected_version` is added, the SPEC migrates to a true per-stream version column — but the (inserted_at, id) ordering remains the wire-format cursor for backwards compat.

**Extension points**:
- `replay_aggregate(uri, init_slice, apply_event_fn)` — DISABLED in v1; documented as the Phase 2 entry point when the first Kind opts into events-as-truth.
- Pluggable storage backend: today SQLite via Ecto; Phase 3+ option to swap to Postgres or `commanded_eventstore_adapter` without caller change.
- Optimistic-concurrency `expected_version` arg on `append/1` — Phase 2 (today, `Kind.Server` GenServer serialization gives the same property; the `expected_version` add introduces a `stream_version` column on `invocations`).

**Test strategy**: unit tests for stream-by-aggregate ordering + cursor pagination (with explicit same-microsecond batched-insert test to verify `id` tie-breaker); integration test that simulates 1000 dispatches and asserts the stream is ordered + complete + reproducible across query repeats.

**Estimated LOC**: ~150 (mostly delegations).

##### 2. `Ezagent.SnapshotStore`

**Signature**:
```elixir
@spec latest(uri :: URI.t) :: {:ok, state :: map, version :: non_neg_integer} | :empty
@spec write(uri :: URI.t, kind_module :: module, state :: map, opts :: [tolerate_failure: boolean]) :: :ok | :not_durable | {:error, term}
@spec delete(uri :: URI.t) :: :ok
@spec policy_for(kind_module :: module) :: persistence_policy
```

**Design rationale**: consolidates the three current snapshot entry points (`Snapshot.load_or_init/3`, `Snapshot.save_now/3`, `Snapshot.Writer.async_save/3`) under one named module. `write/4`'s `:tolerate_failure` flag is the explicit knob for "I'm a periodic flush, dropping one snapshot is fine" vs "I'm a post-event commit, snapshot failure must propagate". Current call sites distribute this knowledge across 4 modules; B'' centralizes it.

**Extension points**:
- `every_n_events/1` policy variant — added WHEN any Kind opts into events-as-truth (events-as-truth presupposes events being counted, which presupposes the event-emission path of §1.5.7.2.b).
- Pluggable storage: today SQLite via `Ezagent.Ecto.KindSnapshot`; Phase 3+ Postgres if event log moves.

**Test strategy**: invariant test that EVERY Kind's `persistence/0` value resolves to a valid `policy_for/1` shape; round-trip test for write→latest→decode.

**Estimated LOC**: ~200 (the existing logic in `Kind.Snapshot` migrates here mostly unchanged).

##### 3. `Ezagent.Kind.StateRebuilder` (behaviour)

**Signature**:
```elixir
@callback rebuild_from_snapshot(uri :: URI.t, snapshot_state :: map) :: new_state :: map
@callback rebuild_from_events(uri :: URI.t, snapshot_state :: map, event_stream :: Enumerable.t) :: new_state :: map
```

**Design rationale**: today `Kind.Server.init/1` hardcodes the snapshot-only recovery path. Lifting it to a behaviour gives per-Kind opt-in to events-as-truth without changing the call site. The default implementation (auto-provided by `use Ezagent.Kind`) is `rebuild_from_snapshot/2 = fn _uri, snap -> snap end` and `rebuild_from_events/3 = :not_implemented`. A Kind opting in overrides both.

**Extension points**:
- `BootReconciler` generalization — today `ExternalMirror.BootReconciler` is hand-rolled per domain. A Kind opting into rebuild-from-events gets boot-time replay for free; no per-domain reconciler needed.
- Hybrid mode: a Kind can implement `rebuild_from_events/3` that uses snapshot as the starting state then folds events newer than the snapshot timestamp.

**Test strategy**: each opted-in Kind ships a "rebuild parity" test — take a Kind through 100 dispatches, snapshot, kill, rebuild from snapshot only, rebuild from events only, assert all three slices equal.

**Estimated LOC**: ~80 (behaviour definition + the default macro impl).

##### 4. `Ezagent.SagaRunner`

**Signature** (codex r7 MED-4-co contract closure, 2026-05-28):

```elixir
defstruct steps: [], compensations: [], ctx: %{}, name: nil, command_uuid: nil

@type effect_map :: %{atom() => term()}   # step_name -> forward_fn's :ok value

@spec new(name :: String.t, opts :: [command_uuid: String.t]) :: %SagaRunner{}
@spec run(
  saga,
  step_name :: atom,
  forward :: (effect_map -> {:ok, term} | {:error, term}),
  compensate :: (effect_map, effects_so_far :: effect_map -> :ok | {:error, term})
) :: %SagaRunner{}
@spec execute(saga, initial_ctx :: map) :: {:ok, effect_map} | {:error, step :: atom, reason :: term, compensated_steps :: [atom]}
```

**Ctx-threading contract**:
1. `execute/2` seeds `effect_map = initial_ctx` (the initial_ctx is folded INTO the effect_map; `Map.merge(initial_ctx, %{})`).
2. Each `forward/1` receives the current `effect_map` (which contains the initial ctx PLUS every prior step's `:ok` result keyed by step_name). On `{:ok, value}`, the runner extends `effect_map = Map.put(effect_map, step_name, value)` and proceeds. On `{:error, reason}`, the runner triggers reverse compensation.
3. Each `compensate/2` receives `(this_step's_effect_map_entry, effect_map_built_through_prior_steps)`. The first arg is what THIS step's forward returned (`Map.get(effect_map, step_name)`); the second is the full prior-state map for cross-step compensation (e.g. step 3 compensate needs to read step 1's snapshot).
4. Compensation runs in REVERSE step order (steps N-1 → 1 — the failing step N itself has no `:ok` value to compensate).
5. Return value on success: full `effect_map` so caller sees every step's result.

**Design rationale**: B'' inlines the saga primitive instead of vendoring Sage (§1.5.4 risk: Sage 2022-09, ex_audit 2023-02). Inlining is ~200 LOC; vendoring Sage is the same LOC plus dependency-staleness risk. Per `feedback_let_it_crash_no_workarounds` we own the structural primitive. The contract is intentionally **a subset of Sage's** — we don't need the async/parallel features Sage exposes; ezagent's saga inventory (§4.4) is all linear-step.

Usage example (the destroy cascade):

```elixir
Ezagent.SagaRunner.new("destroy_agent:#{uri}", command_uuid: trace_id)
|> SagaRunner.run(:snapshot,    &capture_pre_destroy/1,    &noop/2)
|> SagaRunner.run(:revoke_caps, &revoke_all_caps/1,        &restore_caps/2)
|> SagaRunner.run(:terminate,   &terminate_agent/1,        &noop/2)
|> SagaRunner.run(:audit,       &write_destroy_audit/1,    &noop/2)
|> SagaRunner.execute(%{agent_uri: uri, workspace_uri: ws_uri})
```

In the cascade above, `capture_pre_destroy/1` receives `%{agent_uri: ..., workspace_uri: ...}` (initial ctx), returns `{:ok, %{caps: caps, sessions: sessions, lineage: parent}}`; that snapshot is then available to `restore_caps/2` as `effects_so_far[:snapshot]` if `terminate` fails after caps were revoked.

**Extension points**:
- `run_async/4` — Phase 2; today SagaRunner is sync only. Async would require state persistence across the call.
- `Ezagent.SagaOutbox` — Phase 2 durable-across-restart saga state (a `saga_executions` table + a poll worker). Closes the Sage in-memory-state gap codex HIGH-2 raised in §1.5.3. Until any saga's mid-execution crash becomes observably common, this stays Phase 2.
- `command_uuid` propagation — each step's invoke is keyed by `"saga:<name>:step:<step_name>"` for natural idempotency on retry.

**Test strategy**: forward-only happy path; forward-fails-at-step-N reverse-compensates 1..N-1 in reverse order; compensate-itself-fails leaves a marker for operator-repair (matches §3.8 r3 saga doctrine).

**Estimated LOC**: ~200.

##### 5. `Ezagent.EventSubscriber` (behaviour)

**Signature** (codex r7 MED-5 closure, 2026-05-28 — partition mode pulled to Phase 2):

```elixir
@callback interested?(event :: map) :: boolean
@callback handle_event(event :: map, state :: map) :: {:ok, new_state} | {:dispatch, [%Command{}], new_state} | {:error, term}
@callback initial_state(opts) :: map  # default %{}
```

The v1 return type of `interested?/1` is `boolean` only. The earlier `{:partition, key}` shape was promoted to a Phase 2 extension point because v1 cannot honestly specify partition lifecycle, per-key ordering, restart behavior, GC policy, or duplicate handling without an outbox (Phase 2 — Ext.c). Subscribers in v1 are single-process, one-at-a-time within a subscriber module; ordering is `EventLog.stream_by_aggregate` order; concurrency is achieved by registering multiple subscriber modules.

A registry mechanism (`use Ezagent.EventSubscriber, application: :ezagent_core`) supervises one process per registered subscriber, subscribed to `EventLog`'s post-append PubSub topic. Worker bootstrap on `BindingCreated` becomes:

```elixir
defmodule Ezagent.ExternalMirror.WorkerBootstrapSubscriber do
  use Ezagent.EventSubscriber, application: :ezagent_domain_external_mirror
  def interested?(%{action: :bind, kind_module: Ezagent.Entity.Session}), do: true
  def interested?(_), do: false
  def handle_event(%{target: session_uri, args: %{adapter: a, params: p}}, state),
    do: {:dispatch, [%SpawnWorker{session_uri: session_uri, adapter: a, params: p}], state}
end
```

**Design rationale**: today the same effect requires writing a custom GenServer that subscribes to PubSub and re-dispatches. EventSubscriber names the pattern + standardizes the contract. Crucially, this is **separate** from SagaRunner — EventSubscriber didn't initiate the chain (no rollback machinery needed); SagaRunner did.

**Extension points**:
- `Ezagent.EventOutbox` — Phase 2 durable retry on subscriber crash mid-handler. Today subscriber crash + supervisor restart re-subscribes but loses the in-flight event. Outbox writes the dispatch intent to a `event_subscriber_outbox` table before subscriber processes the event; poll worker drains.
- **Partition mode (Phase 2 — codex r7 MED-5 closure)** — for high-volume topics, partition by a key (e.g. workspace_uri) to spawn N parallel subscriber processes. Phase 2 contract MUST specify: (i) partition ownership (one process per key, or fixed-N pool keyed by hash), (ii) per-partition ordering guarantee, (iii) crash + restart replay behavior, (iv) GC policy (idle timeout per partition, or persistent), (v) duplicate-handler protection via `command_uuid`. The v1 `interested?/1` callback returns `boolean` only — `{:partition, key}` lands when the Phase 2 SPEC defines (i)-(v).

**Test strategy**: dispatch a triggering event, assert the subscriber's `handle_event/2` ran exactly once; kill subscriber mid-handler, restart, assert handler doesn't double-run (idempotency via `command_uuid` from §1.5.7.3).

**Estimated LOC**: ~250 (behaviour + supervisor + registry).

**Total new code**: ~880 LOC across 5 modules. Compare to Option A's 1500-2000 LOC saga code per §4.4 + the umbrella-app additions.

#### 1.5.7.5 — Future extension points roadmap

Five concrete extension scenarios + the B'' growth path. Each names the trigger + the structural shift, sized in LOC and weeks.

##### a. If `invocations` table grows too large

**Trigger**: SQLite file > 5 GB; full-table scans exceed 1 second.

**B'' growth path**: cold-archive to `invocations_archive` (separate table) with a cutoff date. `EventLog.stream_by_aggregate/2` UNION-queries both tables. Schema mostly identical; the active table stays small + indexed for hot writes. Existing `MessageStore.older_than/3` already uses this pattern (per `feedback_register_lookup_key_parity` precedent in §6.0 r4). **Cost**: ~3-4 days for migration + UNION query + cutover.

**No code change in callers** — `EventLog.stream_by_aggregate/2` is opaque about whether it UNIONs.

##### b. If the first Kind needs replay (P5 enters the roadmap)

**Trigger**: regulatory compliance demands historical-state reconstruction (e.g. SOC 2 audit for "what caps did user X hold at 2025-09-12 14:00 UTC"); OR a specific Kind benefits from event-driven post-incident reproduction.

**B'' growth path**: that Kind opts every Behavior on it into the CQRS triplet (`events_for/4` + `apply_event/2` + `effects/2`). `EventLog.replay_aggregate/2` lights up (gets implemented). The Kind's `persistence/0` returns `:replay_enabled`. `StateRebuilder.rebuild_from_events/3` is wired up. Other Kinds unaffected. Per `feedback_let_it_crash_no_workarounds`, no shim or dual-mode — once a Kind opts in, it goes through the events path on every restart.

**Concrete walk-through — User Kind (codex r7 HIGH-2 closure, 2026-05-28)**. Actual Behaviors registered on `Ezagent.Entity.User` per `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex:226-231` plus the `IdentityAdmin` extension at `application.ex:271-284`: **`Identity`, `UserCredentials`, `UserTokens`, `IdentityAdmin`**. Per-Behavior replay-readiness assessment:

- **`Identity`** — caps slice is `MapSet` in-memory; cap grants/revokes are slice mutations; `reconcile_after_load/2` rehydrates from `users.caps_json` (`identity.ex:156-206, 228-245`). Replay path: `events_for(:grant_cap, ...)` emits `%CapGranted{cap}`, `apply_event(%CapGranted{cap}, slice) = MapSet.put(slice.caps, cap)`. **Replay-eligible** IF the `users.caps_json` projection writer becomes an `effects/2` declaration instead of an inline DB write.
- **`UserCredentials`** — `invoke(:set_password, ...)` bcrypt-hashes + writes `users.password_hash` via `Ezagent.Entity.User.update_password/2` (`user_credentials.ex:112-122`, `users.ex:100-112`). The DB write is the canonical source — slice carries no password. Replay path: `events_for(:set_password, ...)` emits `%PasswordChanged{hash}`; `apply_event` is a no-op on slice (no in-memory representation); `effects/2` declares `%DbWrite{table: users, set: %{password_hash: hash}}` which the Runtime executes. **Replay-eligible** ONLY IF `effects/2` is NOT re-executed during replay (otherwise replay would mass-rewrite history). The B'' contract per §1.5.7.2.b is that replay re-folds events but does NOT re-execute effects — verified.
- **`UserTokens`** — `invoke(:mint_token, ...)` generates a token, bcrypt-hashes, inserts into `entity_tokens` (`user_tokens.ex:120-146`, `token.ex:75-91`); `invoke(:revoke_token, ...)` pre-reads + deletes (`user_tokens.ex:173-191, 260-272`). The token table is the source of truth — slice mirrors it for hot-path reads. Replay path: `events_for(:mint_token, ...)` emits `%TokenMinted{token_id, label, hash}`; `apply_event` updates slice MapSet; `effects/2` declares the `entity_tokens` insert. Revoke is symmetric. **Replay-eligible** with the same effects-not-replayed property as `UserCredentials`. The `mix ezagent.user.replay` task would NOT re-mint tokens; it would only rebuild the slice's in-memory token-MapSet from the existing events.
- **`IdentityAdmin`** — admin-scope grants. Same shape as `Identity`. **Replay-eligible**.

**Total per-Kind cost for User**: ~3-4 weeks (not the original 2-3 estimate — r7 correction). Breakdown: ~1 week each for `UserCredentials` + `UserTokens` (the DB-write Behaviors need careful `effects/2` extraction); ~3 days each for `Identity` + `IdentityAdmin` (slice-only); ~1 week for the `replay_readiness/1` invariant test + integration test that rebuilds a User from 100 events and asserts parity with a snapshot-based User. **First Kind opt-in is the expensive one** because the test scaffolding is greenfield; subsequent Kinds amortize the test cost down to ~2 weeks total.

**Key property**: per-Kind migration, not big-bang. Compare with Option A which migrates all 5 entity Kinds in one Phase-10 plan (§6 of this SPEC, ~3 months wall-time). BUT: B'' replay opt-in is gated on **every** Behavior on the Kind passing `replay_readiness/1`. A Kind with one unported Behavior cannot opt in. This is the structural cost the §1.5.7.2.b atomic-triplet invariant enforces.

##### c. If saga durability becomes needed (cross-restart resume)

**Trigger**: observability shows >1% of destroy cascades crash mid-execution (e.g. operator kills the BEAM node during a long-running cascade); operator-repair is too frequent.

**B'' growth path**: add `Ezagent.SagaOutbox` — a `saga_executions` table + a poll worker. SagaRunner's `execute/2` gains a `:durable` opt; when set, each step's start/end writes to the outbox; on BEAM restart, the poll worker resumes incomplete sagas from the last completed step. **Cost**: ~2 weeks (schema + worker + tests). Closes the codex HIGH-2 gap raised in §1.5.3 for Sage.

**Key property**: opt-in per-saga, not blanket. Most sagas (the 5 single-call cascades from §4.4) don't need durability because they complete in <100ms.

##### d. If projection tables become needed (eventual-consistent reads)

**Trigger**: a read site (admin dashboard, CLI listing, HTTP endpoint) suffers measurable contention against `Kind.Server` GenServer mailbox; OR an analytics use case requires reading historical state without restarting the Kind.

**B'' growth path**: `Ezagent.Projection` behaviour + per-projection `init_from_events/1` (initial backfill) + `handle_event/2` (incremental update). The projection table is its own Ecto schema. `ReadModel.read(uri, slice_key, consistency: :eventual)` flips to query the projection table. Slice stays for hot-path strong-consistent reads (LV chat stream, dispatch-time authz check). **Cost**: per-projection ~1-2 weeks.

**Key property**: per-projection migration, not per-Kind. The cap-vis SPEC's `workspace_visibility_per_caller` projection (§1.2 of this SPEC) lands as a standalone projection without touching other reads.

##### e. If we ever DO need Commanded — the migration path is **shortest** of all options

This last point is critical. The four options compared in §1.5.7.6 have different migration costs back to Commanded if Allen later decides ezagent should adopt it:

- **Option A (Commanded directly)** — already there. Cost: 0.
- **Option B (Sage + ex_audit)** — strangle-pattern migration: events have to be inferred from `Ecto.Changeset` history retroactively; saga modules rewritten from Sage to Commanded PM. Cost: ~10-12 weeks.
- **Option B' (DIY Ecto.Multi)** — events have to be modeled from scratch; sagas rewritten. Cost: ~14-16 weeks.
- **Option B'' (native consolidation)** — events already exist (in `EventLog` / `invocations`); aggregates already exist (per Kind); snapshots already exist (`SnapshotStore` / `kind_snapshots`). Sagas exist in a `SagaRunner` shape that is **conceptually adjacent but NOT 1:1 with** Commanded PM (codex r7 HIGH-3 closure, 2026-05-28): `SagaRunner` is a stateless in-call closure list (`run/4` + `execute/2`); Commanded PM is stateful with `interested?/1` + `handle/2` + `apply/2` + correlation-id PM-state-per-instance. The migration is NOT a wrapping swap for sagas — it requires translating each `SagaRunner.execute` call site into a PM with `interested?` clauses + correlation ID + persisted PM state + stop conditions.

  Per-component migration cost breakdown:
  - `EventLog` → `commanded_eventstore_adapter`: ~1 week (mostly schema migration + dual-write cutover; the public API IS already a 1:1 wrap of stream-by-aggregate semantics).
  - `SnapshotStore` → Commanded snapshots: ~3-4 days (policies differ — `:on_change` / `:on_terminate` are ezagent-shapes vs Commanded's `snapshot_every: N`; the migration converts policy declarations).
  - `EventSubscriber` → `Commanded.Event.Handler`: ~1 week (subscriber registration semantics match; partition mode (B'' Ext.) maps to Commanded's `subscribe_to: :all` + handler concurrency).
  - **`SagaRunner` → `Commanded.ProcessManagers.ProcessManager`: ~3-4 weeks per non-trivial saga**, because each step's forward/compensate closure becomes a PM event-handler clause, with correlation id derivation + interested? selectors + apply/2 fold + stop condition. The 5 single-call cascades in §4.4 each cost ~3-5 days; cross-call workflows like the `EzagentDomainChat.create_session/3` flow (lock + spawn + bind + cast `chat.join` async + grant owner cap + `ensure_orchestrator_with_meta` with `:partial` bounded retry — `ezagent_domain_chat.ex:143-200, 540-615, 619-648`; `session.ex:850-889, 984-1003`) cost ~1-2 weeks each because the async legs and the `:partial`-result branch need persisted PM correlation state.
  - Per-Kind `events_for/4` + `apply_event/2` + `effects/2` triplet → Commanded `execute/2` + `apply/2`: per opted-in Kind ~1-2 weeks (the slice-per-Behavior model has to fuse into a single aggregate state struct — see also the codex r7 HIGH-acknowledgment in §1.5.7.1 below).

  **Honest revised total**: ~6-10 weeks for the simplest mix (1-2 small sagas, no cross-call workflows, no Kinds opted into events-as-truth), ~10-14 weeks if 2+ cross-call workflows + multi-Behavior Kinds need migration. The earlier "~4-6 weeks" figure was the optimistic floor; codex r7 HIGH-3 review correctly flagged it as understated. **Even at the revised range, B'' → Commanded is cheaper than Option B → Commanded (~10-12 weeks for sagas alone, plus events have to be inferred from scratch) and dramatically cheaper than Option B' → Commanded (~14-16 weeks).**

**What "pro-future-Commanded" means after the correction.** By having `EventLog`, `SnapshotStore`, `EventSubscriber` at near-1:1 with Commanded equivalents, and `SagaRunner` providing the saga shape ezagent needs today (linear, sync) PLUS a clear migration path to PM for the harder cases, we keep the option open AND shrink the future cost (at minimum we save the ~6 weeks of "events have to be inferred" that Option B suffers). B'' is not a 1:1 wrapper for Commanded; it is a **convergent design** — most concepts align tightly; sagas require translation but not reinvention.

#### 1.5.7.6 — Comparison summary table

| Dimension | Option A (Commanded) | Option B (Sage + ex_audit + Oban) | Option B' (DIY Ecto.Multi + event log) | Option B'' (Native consolidation) |
|---|---|---|---|---|
| **Day-1 LOC delta** | +5000-7000 (3 new umbrella apps + 9 sagas + 5 aggregates + 8 projectors) | +1500-2000 (Sage modules + ex_audit wiring + Oban outbox) | +1200-1800 (DIY orchestration + DIY audit + DIY constraints) | **+880 (5 internal modules)** |
| **Day-1 wall-time** | ~3 months | ~3-4 weeks | ~4-5 weeks | **~2-3 weeks** |
| **Day-1 infra change** | Postgres in dev loop; new umbrella apps | Postgres for Oban; no umbrella change | None | **None** |
| **Day-1 retired modules** | 7 internal (Kind.Server, KindRegistry, Audit.Writer, Persistence, Snapshot.Writer, etc.) | 0 | 0 | **0** |
| **Long-term replay** | Native | Hand-rolled per-Kind | Hand-rolled per-Kind | **Native per-Kind opt-in (Ext.b)** |
| **Long-term distributed scaling** | Native (multi-node aggregates) | Possible via Oban distribution | Possible via Postgres | **Possible via SagaOutbox / EventOutbox (Ext.c/Ext.d)** |
| **Long-term multi-tenant** | Per-aggregate strong isolation | Workspace via DB scoping | Workspace via DB scoping | **Workspace via `Persistence.scope_by_workspace` (already there)** |
| **Migration cost to Commanded if needed later** | 0 | ~10-12 weeks | ~14-16 weeks | **~6-14 weeks (per §1.5.7.5(e) r7 honest range; floor depends on saga inventory + Kinds opted in)** |
| **Dependency risk** | Commanded itself (active, well-maintained); EventStore lib | Sage 2022-stale; ex_audit 2023-stale; Oban Pro paid | None (stdlib + Ecto) | **None (uses existing ezagent primitives)** |
| **Dispatch latency hit** | +5x per §7.1 | 0 | 0 | **0** |
| **Dev-loop friction** | Postgres required | Postgres required (Oban) | None | **None** |
| **Alignment with `feedback_let_it_crash_no_workarounds`** | High (CQRS is structural) | Medium (Sage adds workaround for missing structural primitive) | Medium-High (DIY is structural but ad-hoc) | **High (names structural primitives we already have)** |
| **Alignment with `feedback_north_star_plugin_isolation`** | High (plugin authors stay in `execute/2` / `apply/2`) | Medium (plugin authors learn Sage + ex_audit + Oban) | Low (plugin authors learn N ad-hoc patterns) | **High (plugin authors keep writing `invoke/4`; opt-in to `execute_command/apply_event` per CQRS principle)** |
| **Per `feedback_completion_requires_invariant_test`** | New invariants per aggregate | New invariants per saga | New invariants per Ecto.Multi | **Existing invariants stay; new invariants only for opted-in Kinds** |
| **Risk of architectural drift** | Low — Commanded enforces shape | Medium — Sage + ex_audit + Oban interact in subtle ways | High — DIY drifts over time | **Low — abstractions are named + tested** |

##### Honest acknowledgments

- B'' does NOT solve P5 (replay) **today** — it provides the extension point (Ext.b) at no day-1 cost. If replay is needed in <6 months, Option A is still the right call.
- B'' does NOT solve mid-cascade saga durability **today** — same shape as Option B's gap. SagaOutbox (Ext.c) is the closer when needed.
- B'' is a refactor on the same architecture, not a replacement. Allen could argue this is the wrong abstraction layer. The counter-argument: every other option ALSO leaves the current architecture in place AND adds new layers; B'' is the only option that adds **less than 1000 LOC of new code** and the only one that names what's already there.

#### 1.5.7.7 — Recommendation

**B'' is the recommended path.** Reasons:

1. **Smallest day-1 footprint** — ~880 LOC, no new umbrella apps, no Postgres in dev loop, no retired modules. Ships in ~2-3 weeks. Option B's ~3-4 weeks + outbox dependency, B''s footprint is lower AND structurally cleaner because it eliminates the Sage/ex_audit/Oban dependency triangle.

2. **No dependency risk** — Option B inherits Sage's 2022-09 + ex_audit's 2023-02 staleness (§1.5.4). B'' uses ezagent's own primitives + standard Ecto + Phoenix.PubSub. The only "library" added is the names of modules already in `ezagent_core`.

3. **Best-positioned for future Commanded migration** — §1.5.7.5(e). The migration from B'' to Commanded is ~6-14 weeks (codex r7 HIGH-3-honest range; floor depends on saga inventory + Kinds opted into events-as-truth). The cheap part (`EventLog`, `SnapshotStore`, `EventSubscriber`) is near-1:1 wrap; the expensive part (sagas → Commanded PM) requires translation, not just renaming. Even at the upper bound this is cheaper than Option B's ~10-12 weeks (events have to be inferred AND sagas rewritten) and dramatically cheaper than Option B's ~14-16 weeks. B'' makes the eventual Commanded migration the cheapest non-trivial path.

4. **Aligns with `feedback_let_it_crash_no_workarounds`** — every other option adds shims (Sage's saga state, Oban's outbox, ex_audit's changeset interceptor). B'' adds none — every primitive it names is structural truth already in the code. The "missing 30%" is module-naming, not new behavior.

5. **Aligns with `feedback_north_star_plugin_isolation`** — plugin authors keep writing `Behavior.invoke/4`. The CQRS upgrade path (`execute_command/2` + `apply_event/2`) is OPT-IN per Behavior. No plugin author is forced to learn Sage or ex_audit or Oban; the core stays the same.

**Fallback ordering** if B'' design fails codex review or impl-PR drafting:

1. First fallback: **Option B** (Sage + ex_audit + Ecto.Multi + Oban outbox per §1.5.5). This was the prior verdict; still viable if (a)(b)(c) hold and dependency risk is acceptable.
2. Second fallback: **Option A** (Commanded full migration per §2-§12 of this SPEC). Justified only if replay (P5) becomes a roadmap item OR if both B'' and B prove infeasible.

**Path forward**:

1. This SPEC (#442) updates §1.5.5 verdict and §1.5.6 downstream impacts to reflect B'' as primary.
2. Five companion SPECs (one per B'' module from §1.5.7.4) get drafted; these are small + independent + landable in 2-3 weeks each:
   - `2026-05-28-ezagent-eventlog-naming.md` — name the existing audit-writer pipeline as EventLog
   - `2026-05-28-ezagent-snapshotstore-naming.md` — consolidate Snapshot.Writer + Kind.Snapshot under SnapshotStore
   - `2026-05-28-ezagent-saga-runner.md` — inline ~200 LOC SagaRunner; rewrite §4.4's saga inventory against it
   - `2026-05-28-ezagent-event-subscriber.md` — name the EventSubscriber behaviour; refactor the 2 existing PubSub-driven subscribers
   - `2026-05-28-ezagent-state-rebuilder.md` — lift `Kind.Server.init/1` recovery into the StateRebuilder behaviour
3. Each companion SPEC gets codex adversarial-review per `feedback_codex_review_every_pr`.
4. If any companion SPEC fails its review badly enough that the abstraction shape changes, this §1.5.7 gets revisited.

---

## 2. Decision — adopt Commanded + EventStore as primary state model

> ⚠️ **Pre-§2 note (r7)**: §1.5 verdict is **Option B'' (native consolidation)** (r7 update — supersedes r6's "CONDITIONAL Option B"). §1.5.7 details: ezagent has been DIY-implementing ES primitives organically for 9 months; B'' names them + adds the missing 30% via 5 small internal modules (~880 LOC, ~2-3 weeks). §2-§12 below reflects the Commanded full-migration path (Option A), retained as the **second fallback** behind Option B (first fallback per §1.5.5). Option A is the primary path only if BOTH B'' and Option B prove infeasible OR if replay (P5) becomes a roadmap item within 6 months. See §1.5.6 for the 5 B'' companion SPECs that supersede this SPEC. Do not merge §2-§12 as-is.

### 2.1 What we adopt

| Component | Lib | Role |
|---|---|---|
| `Commanded.Application` | `commanded` | Per-deployment dispatch + aggregate hosting boundary |
| `Commanded.Commands.Router` | `commanded` | Command → Aggregate routing via `:identify` |
| `Commanded.Aggregates.Aggregate` | `commanded` | The behaviour replacing `Ezagent.Kind`'s GenServer pattern |
| `Commanded.ProcessManagers.ProcessManager` | `commanded` | Multi-aggregate workflows (the new home for destroy cascade etc.) |
| `Commanded.Event.Handler` | `commanded` | Non-projection event subscribers (e.g. mirror events to external systems, dispatch follow-up commands without state — the `:eventually consistent` variant of a process manager when state machine is overkill) |
| `Commanded.Projections.Ecto` | `commanded_ecto_projections` | Read-model projectors that Ecto.Multi-update tables on events |
| `EventStore` | `eventstore` | Postgres-backed event persistence |
| `Commanded.EventStore.Adapters.EventStore` | `commanded_eventstore_adapter` | Adapter wiring `commanded` to `eventstore` |
| `Commanded.EventStore.Adapters.InMemory` | bundled | Test / dev-loop event store |

### 2.2 What we do NOT adopt yet

- **EventStoreDB** (the standalone Erlang/Scala event store via `commanded_extreme_adapter`) — operationally heavier than Postgres + `eventstore` lib, and we have no clustering need at current scale. Postgres ops is widespread; EventStoreDB is niche. (Discussion in §7.4 + §10 OQ-1.)
- **Snapshot store on EventStoreDB** — we use Commanded's built-in snapshot-every-N-events stored in the same Postgres `eventstore` schema. The existing `kind_snapshots` SQLite table is retired per Kind on migration.
- **Multi-app Commanded topology** (one `Commanded.Application` per bounded context with cross-app event bridges) — overkill for our 5-Kind model; we run ONE `Ezagent.CommandedApp` with all aggregates + all process managers + all projectors. Splitting is a Phase N+1 question if scale demands it.

### 2.3 What stays unchanged (the external API surface)

- Phoenix.Channel `handle_in/3` callbacks. Today they construct `%Invocation{}` and call `Invocation.dispatch/1`; post-migration they construct `%Cmd{}` and call `Ezagent.CommandedApp.dispatch/2`. The channel topic, message shape, response shape are unchanged from the JS client's perspective.
- LiveView `mount/3` + `handle_event/3`. Same change: dispatch a Command instead of an Invocation. Reads come from projection queries instead of `Kind.get_slice/2` (§5).
- CLI `mix ezagent.*` tasks. Same dispatch change. Reads from projection tables.
- HTTP plug controllers (e.g. `EzagentWeb.SessionController.create`). Same.
- The `URI`-based addressing model. Aggregate UUIDs ARE the canonical URI strings; no new addressing scheme.
- Capability semantics. The cap struct + matcher are unchanged. The check moves from `Kind.Runtime` step 5.5 to a pre-dispatch pipeline (§4.5).
- The Behavior contract surface visible to plugin authors stays *substantively* the same — they declare a Kind (now an Aggregate), state (now event-derived), actions (now commands), invoke logic (now `execute/2` returning events + `apply/2` returning new state). The interface(s) differ syntactically but the mental model is preserved (§4.2 maps each callback).

### 2.4 What MUST change (the internals)

- `Ezagent.Kind.Server` is retired per-Kind on migration. The shared GenServer is replaced by `Commanded.Aggregates.Aggregate` processes managed by Commanded's `AggregateRegistry`.
- `Ezagent.Kind.Snapshot` is retired per-Kind on migration. Commanded's snapshot store (Postgres-backed, configured via `snapshot_every:`) replaces it.
- `Ezagent.Audit.Writer` (the `invocations` SQLite table) is retired for domain events; the event stream IS the audit log. Non-domain telemetry (denied authz, persistence-failure, cross-cutting boot/teardown) stays in the SQLite audit table (§4.7).
- `Ezagent.Invocation.dispatch/1` is retired as the public dispatch entry. Replaced by `Ezagent.CommandedApp.dispatch/2`. The 12-step flow becomes a 5-step pre-dispatch pipeline + Commanded's aggregate hosting (§4.5).
- `Ezagent.KindRegistry` is retired per-Kind on migration. Aggregate lookup is handled by Commanded internally; cross-Kind references go through events + sagas, not registry lookups.
- `Ezagent.SpawnRegistry` is retired per-Kind on migration. "Spawn" becomes "first command at aggregate ID creates it" — the aggregate doesn't exist until the create command applies; subsequent create commands fail deterministically.
- `Ezagent.PendingDelivery` is retired post-Phase-10-A (the not-yet-ready buffer pattern). Aggregates don't have a `:not_ready` state in the same sense — they're either created (history non-empty) or not (history empty); a dispatch against a non-created aggregate either creates it (per the `execute/2` clause for empty state) or fails with the aggregate's "not created" error.
- `Ezagent.Persistence.scope_by_workspace/2` and `workspace_uri_for/1` stay — they apply to PROJECTION tables now, not slice writes. The workspace isolation invariant is enforced in projectors + read queries.

### 2.5 Decision boundary — what this SPEC does and does not commit to

This SPEC commits to:
- Adopting Commanded + EventStore as the future state model.
- The 4-phase migration plan in §6 (Phase 10-A through 10-D), with explicit unwind at each phase boundary.
- The mapping table in §4.4 from current Kinds to Aggregates + the cross-Kind workflow inventory in §4.4.2 that defines which Process Managers exist post-migration.
- The dev-loop story (in-memory adapter for fast tests; Postgres for dev + prod). See §7.3.
- The audit decomposition in §4.7 — domain events go to event store, telemetry-only events stay in SQLite.

This SPEC explicitly does NOT commit to:
- The exact event schema for each Aggregate (per-Aggregate impl SPECs in Phase 10-B through 10-D).
- The exact projection table shape for each read-model (impl-time decisions per phase).
- Whether process managers run in-process with the Commanded Application or in a sibling supervisor (§10 OQ-5).
- Snapshot-every-N tuning per Aggregate (default = 50, override per-Aggregate where benchmarks justify it).
- The exact CLI / LV form changes for any command (per existing CLI ↔ LV isomorphism invariant in `IMPLEMENTATION_ROADMAP.md` §1.4; preserved post-migration but the specific binding details land in impl PRs).

---

## 3. Phoenix + Commanded hybrid integration — the critical research question

This is the section Allen specifically flagged for depth. The integration is **not novel** (production references in §3.6) but the patterns are subtle. The whole point of CQRS is the asymmetry between write-path (commands dispatched to aggregates, events persisted) and read-path (projections queried). LiveView and Phoenix.Channel sit on BOTH paths. This section enumerates each interaction.

### 3.1 The "Phoenix at the edges, Commanded at the core" pattern

The canonical pattern across Conduit, gift-card-demo, segment-challenge, and Honeydew is:

```
                       ┌─────────────────────────────┐
                       │  EXTERNAL TRANSPORT          │
                       │  (HTTP / WS / LV / CLI / MCP)│
                       └──────────────┬──────────────┘
                                      │
                                      ▼  (constructs %Cmd{})
                       ┌─────────────────────────────┐
                       │  PRE-DISPATCH PIPELINE       │
                       │  - authn (already happens)   │
                       │  - authz (CapBAC step 5.5)   │
                       │  - workspace isolation 5.6   │
                       │  - idempotency check         │
                       │  - URI canonicalization      │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  Ezagent.CommandedApp.dispatch(cmd, opts)
                       ┌─────────────────────────────┐
                       │  COMMANDED.APPLICATION       │
                       │  Router → :identify by id    │
                       └──────────────┬──────────────┘
                                      │
                                      ▼
                       ┌─────────────────────────────┐
                       │  AGGREGATE                   │
                       │  execute(state, cmd)         │
                       │   → [event(s)] | error       │
                       │  apply(state, event)         │
                       │   → new_state                │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  events appended to event store
                       ┌─────────────────────────────┐
                       │  EVENT STORE (Postgres)      │
                       └──────────────┬──────────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
                ▼                     ▼                     ▼
        ┌──────────────┐    ┌──────────────┐      ┌──────────────┐
        │ PROJECTOR    │    │ PROCESS MGR  │      │ HANDLER      │
        │ Ecto.Multi   │    │ saga state + │      │ side effects │
        │ updates      │    │ emits cmds   │      │ (notifs, fan │
        │ read tables  │    │              │      │  out, etc.)  │
        └──────┬───────┘    └──────┬───────┘      └──────────────┘
               │                   │
               ▼                   ▼
       ┌─────────────┐     ┌─────────────┐
       │  LV / API   │     │  AGGREGATE  │
       │  reads from │     │  (follow-up │
       │  read table │     │   command)  │
       └─────────────┘     └─────────────┘
```

Phoenix.Channel and LiveView sit at the top (write-side, constructing commands) and the bottom (read-side, querying projections). Commanded owns the middle. Plugin authors write commands, events, aggregates, projectors, and process managers — they never touch the event store directly.

### 3.2 LiveView write-path — handle_event/3 → dispatch

The reference pattern from `gift-card-demo/lib/gift_card_demo/gift_cards.ex`:

```elixir
defmodule GiftCardDemo.GiftCards do
  alias GiftCardDemo.AppRouter
  alias GiftCardDemo.GiftCard.Commands.{IssueGiftCard, RedeemGiftCard}

  def issue_gift_card(amount) do
    command = %IssueGiftCard{id: UUID.uuid4(), amount: amount}
    AppRouter.dispatch(command)
  end

  def redeem_gift_card(id, amount) do
    command = %RedeemGiftCard{id: id, amount: amount}
    AppRouter.dispatch(command)
  end
end
```

LiveView's `handle_event/3` calls `GiftCards.issue_gift_card(amount)`. The function constructs a Command struct and dispatches. No direct EventStore access; no manual event emission; the aggregate's `execute/2` decides what events fire.

**For ezagent**, the equivalent context module is per-Domain (one per `apps/ezagent_domain_*`) — `Ezagent.Domain.Chat.create_session(...)`, `Ezagent.Domain.Identity.grant_cap(...)`, etc. Each context function:
1. Builds a `%Cmd{}` struct with the canonical aggregate URI as `:id`.
2. Calls `Ezagent.CommandedApp.dispatch(cmd, opts)` with opts derived from the caller's intent (`consistency: :strong` for read-after-write paths; `:eventual` otherwise — see §3.3).
3. Returns `:ok` / `{:error, reason}`.

The pre-dispatch pipeline (§4.5) wraps `Ezagent.CommandedApp.dispatch/2` so authz, workspace isolation, idempotency, and URI canonicalization happen ONCE at the boundary, not in every domain context function.

### 3.3 Read-after-write consistency — THE critical question

When LiveView `handle_event` dispatches a command and then re-renders, will the re-render see the new state?

**Three modes Commanded supports:**

**(a) `consistency: :eventual` (default).** Dispatch returns `:ok` as soon as the event is persisted. Projectors run asynchronously. LiveView's re-render fires immediately on dispatch return — but the projection table may not yet reflect the change. The next push from PubSub or projector `after_update/3` triggers a follow-up render with the new state. UX: a momentary stale read; users see the change within a typical 1-10ms projector latency.

**(b) `consistency: :strong`.** Dispatch blocks until ALL projectors flagged `consistency: :strong` have committed. LiveView's re-render after dispatch sees the new state synchronously. Cost: dispatch latency = event-append (5-50ms) + slowest strong projector commit (typically another 5-20ms). For dispatches that fan out to multiple strong projectors, the bound is max of them. ([hexdocs Commands.md](https://hexdocs.pm/commanded/Commanded.Commands.Router.html))

**(c) `consistency: [ProjectorA, ProjectorB]`.** Block until specific named projectors catch up. The middle ground: synchronous wait for only the projectors that feed THIS LiveView, async for everything else.

**ezagent's choice — per dispatch site, default `:eventual`, opt-in `:strong`:**

The default for `Ezagent.CommandedApp.dispatch/2` is `consistency: :eventual` because the majority of dispatches (chat send, audit-only writes, fanout-style mutations) do not require read-after-write at the dispatch site. The dispatch site opts into `:strong` (or named-projector-list) when:

- The same LiveView render reads back the projection it just updated (e.g. create_session → wizard redirects to /sessions/X and renders the session detail — the detail projection must be present).
- A CLI command prints the resulting state to stdout (deterministic CLI return).
- A controller responds 201 with the created resource's projection state.

The opt-in mechanism is explicit at the dispatch site: `Ezagent.CommandedApp.dispatch(cmd, consistency: :strong)`. Defaulting to `:eventual` keeps the hot path fast; the LV/PubSub pattern (3.4) makes the eventual case nearly invisible to users.

**Process-manager-emitted commands always use `:eventual`** — the saga is itself an event subscriber, so by the time it dispatches a follow-up command, the originating event has already persisted; blocking on strong consistency between saga-internal steps would deadlock with the saga's own event subscription.

### 3.4 LiveView read-path — subscribe to projections, not events

The reference pattern from gift-card-demo:

```elixir
defmodule GiftCardDemoWeb.GiftCardSummaryLive do
  use Phoenix.LiveView
  alias GiftCardDemo.GiftCards

  def mount(_session, socket) do
    if connected?(socket), do: GiftCards.subscribe()
    {:ok, fetch(socket)}
  end

  def handle_info({:gift_card_summary, %GiftCardSummary{}}, socket) do
    {:noreply, fetch(socket)}
  end

  defp fetch(socket) do
    assign(socket, gift_cards: GiftCards.list_gift_cards())
  end
end
```

And in the projector:

```elixir
project %GiftCardIssued{...} = event, fn multi -> ... end

def after_update(_event, _metadata, %{gift_card_summary: summary}) do
  Registry.dispatch(Registry.GiftCardSummary, :gift_card_summary, fn entries ->
    for {pid, _} <- entries, do: send(pid, {:gift_card_summary, summary})
  end)
end
```

**The flow:**
1. LV `mount/3` subscribes to a per-projection Registry topic.
2. LV initial render reads the projection table directly (sync DB query).
3. Projector's `after_update/3` callback (a `commanded_ecto_projections` hook) fans out the updated row to all subscribers.
4. LV `handle_info` re-fetches + re-renders.

**For ezagent**, we replace `Registry` with `Phoenix.PubSub` (already used elsewhere in the codebase; uniform topic naming). Per-Aggregate-class projector defines a topic like `"ezagent:projections:user:#{user_uri}"` and broadcasts on `after_update/3`. LV subscribes during mount.

The pattern is symmetric across all 5 Kinds — User, Session, Agent, Workspace, Worker — each gets a projector + a PubSub topic; LV subscribes per the URIs it's rendering.

**The cold-load problem.** When LV mounts and the projection has not yet caught up to the LATEST events (a race window because the LV mount runs in parallel with the projector subscription), the initial render shows stale state. Two solutions:

- **`Commanded.Subscriptions.wait_for/3`** — the LV mount blocks on a specific aggregate UUID + version until the projector catches up. Slightly more synchronous than the standard pattern but eliminates the stale-mount window when the LV is mounted RIGHT AFTER a dispatch (e.g. wizard redirect-then-mount).
- **Dispatch-then-mount-with-aggregate-version** — the dispatching code passes the `:aggregate_version` from the dispatch result through the redirect URL or session; the LV mount waits for THAT specific version before rendering. This is the gift-card-demo pattern, scaled up.

For ezagent, the standard LV pattern uses `consistency: :strong` on the dispatch that precedes the redirect; the destination LV mounts AFTER the dispatch returns, so the projection is guaranteed to be caught up at mount time. The wait_for/3 helper exists as a fallback for cross-tab races (user opens detail page in tab 2 while tab 1 is dispatching).

### 3.5 Phoenix.Channel write-path (CLI, agent_bridge, feishu)

Phoenix.Channel `handle_in/3` is structurally identical to LV `handle_event/3` — it constructs a command and dispatches. The only difference is the reply mechanism:

- **LV** — re-render is triggered automatically by `assign/2`; the user sees the result in HTML.
- **Channel** — `handle_in/3` returns `{:reply, {:ok, payload}, socket}` and the JS client (cli, agent_bridge) receives the reply. The dispatch result (typically `:ok` or `{:ok, %ExecutionResult{}}`) is serialized into the channel payload.

For commands whose dispatch site needs to return data to the caller (e.g. CLI `mix ezagent.user.token --mint` prints the minted token):
- The dispatch uses `consistency: :strong` (so the token is in the read model).
- The dispatch site queries the read model immediately after dispatch returns.
- The dispatch result + read-model row are returned together to the channel.

There is no `Behavior.invoke/4`-style return-value-in-the-event-itself pattern in Commanded — events are facts about the past, not return values. If the caller needs a return value, the return is derived from the read model AFTER dispatch.

### 3.6 Production references

| Project | Stack | Notes | URL |
|---|---|---|---|
| **Conduit** | Phoenix + Commanded | RealWorld example app (Medium clone); mature; demonstrates router, aggregates, projectors, process managers, Phoenix views | https://github.com/slashdotdash/conduit |
| **Gift-card-demo** | Phoenix LiveView + Commanded | Smaller, LV-focused; shows projection-via-Registry pattern + `after_update/3` hook | https://github.com/slashdotdash/gift-card-demo |
| **Segment Challenge** | Phoenix + Commanded | Production app for Strava competitions; larger-scale aggregate inventory | https://github.com/slashdotdash/segment-challenge |
| **Honeydew** | Phoenix LiveView + Commanded + Postgres ("CELP stack") | Starter template; demonstrates standard wiring | https://github.com/quarterpi/honeydew |
| **Casavo (medium post)** | Production company | Uses Commanded + LiveView for monitoring/debug tools sitting on top of event store; demonstrates "LiveView as event-store observer" pattern (we will use the same for `/admin/events` page) | https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99 |
| **ElixirMerge guide** | Walkthrough | EventStoreDB + Phoenix + LiveView CQRS/ES guide | https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview |
| **Cantido blog post** | Phoenix LV event-sourced | LV subscribes to `$all` event stream + push_event to JS hook for high-frequency render | https://dev.to/cantido/phoenix-liveview-but-event-sourced |
| **Christian Alexander blog post** | Phoenix API + Commanded | Read-after-write strong-consistency pattern walkthrough | https://christianalexander.com/2022/05/09/elixir-commanded/ |

**Verdict on maturity:** the integration is established; reference apps exist; community has Q&A on ElixirForum dating back to 2018. Not pioneering. The "Phoenix at the edges, Commanded at the core" pattern is the de-facto standard. ezagent is well within the precedented use-cases.

### 3.7 Failure modes — what can go wrong

| Failure | Cause | Recovery | SPEC §reference |
|---|---|---|---|
| **Aggregate process crashes mid-replay** | A corrupted event in the stream OR a bug in `apply/2` raises during state reconstruction | Commanded's `AggregateRegistry` restarts the aggregate; replay resumes from the last snapshot. If the bug is in `apply/2`, the crash loops until the code is fixed. Pin: snapshot every N events bounds the replay scope so a code fix immediately recovers (replay starts from the snapshot, not from event 0). | §4.4 + §6 Phase 10-A |
| **EventStore Postgres outage** | DB down | `dispatch/2` returns `{:error, _}`. Caller treats this as transient failure (retry policy). Aggregates in-memory state survives; on Postgres recovery, dispatch resumes. Sagas pause (their subscription stops receiving events); on recovery they resume from the last processed event. | §7.4 + §8 |
| **Saga partial failure** | Process Manager's `handle/2` returns a command that the target aggregate rejects | Saga's `error/3` callback decides: retry-with-backoff, compensate (dispatch reverse command), skip-and-continue, or stop. The compensation logic is explicit code in the saga; no framework auto-rollback. | §3.8 destroy cascade specifically |
| **New event type added to existing aggregate** | Code adds a new event variant the aggregate now emits | `apply/2` MUST have a clause for the new event. The aggregate's `behaviors/0`-equivalent list (the aggregate module itself) is the source of truth; the new event is also added to the projector's `project` clauses. | §10 OQ-3 + §11 q#6 — event schema evolution |
| **Old event type removed** | Code stops emitting a type that's in historical streams | `apply/2` MUST still have a clause for the historical event (replay needs it). The clause can be a no-op if the field is no longer relevant; the event itself is not deleted from history. | §10 OQ-3 |
| **Field added to existing event** | Need to add `caller_metadata` to `MessagesPosted` events | `Commanded.Event.Upcaster` impl runs at event-read time, transforming old events into the new shape before they reach `apply/2`. Historical events stay byte-identical on disk; in-memory shape is upgraded. | §10 OQ-3 |
| **Projection drift from aggregate** | Projector has a bug, write the wrong column | Rebuild from event stream: stop projector → truncate projection table → restart projector with `start_from: :origin`. Cost: O(events) replay; bounded by `snapshot_every` for aggregate snapshots but not for projections (projection replay reads the full stream). For our scale, projection replay is minutes not hours. | §7.4 + §8 |
| **Hot aggregate with 10K+ events** | A heavily-used Session aggregates 10K MessagesPosted over its lifetime | Snapshot every 50 events bounds replay to ≤50 events on cold start; warm aggregates stay in memory. Worst-case replay = ~50 events × `apply/2` latency (μs each) ≈ 1ms. | §7.2 |
| **Two writers race on same aggregate** | Concurrent LV + CLI both dispatch a command for the same aggregate UUID | Commanded serializes per aggregate (one process per UUID); the second command queues behind the first. Optimistic concurrency error only if explicit `expected_version` is set (which we don't for ezagent — we accept implicit serialization). | §4.5 |
| **Event store schema breaking change** | Commanded major version upgrade introduces event store table changes | Upgrade migration runs against Postgres; events are NOT rewritten (the event payload is JSON, schema-flexible); only the surrounding metadata columns change. Read [commanded changelog](https://hexdocs.pm/commanded/changelog.html) before each upgrade. | §7.4 |

### 3.8 Saga compensation pattern for the destroy cascade (the original trigger)

The destroy cascade from SPEC #440, expressed as a Process Manager:

```elixir
defmodule Ezagent.Saga.DestroyAgentSaga do
  use Commanded.ProcessManagers.ProcessManager,
    application: Ezagent.CommandedApp,
    name: "DestroyAgentSaga"

  # r3 fix (HIGH-7): defstruct includes the pre-destroy snapshot fields.
  defstruct [
    :agent_uri, :workspace_uri, :step,
    :pre_destroy_caps,         # captured at step 0 from agent_caps_projection
    :pre_destroy_sessions,     # captured at step 0 from session_members_projection
    :pre_destroy_lineage_parent, # captured at step 0 from agent_lineage_projection
    :caps_revoked,
    :children_destroyed
  ]

  # Starts on AgentDestroyRequested event (emitted by Agent aggregate
  # when it accepts a Destroy command).
  def interested?(%AgentDestroyRequested{agent_uri: uri}), do: {:start, uri}

  # Continues for each follow-up event the saga emits commands for.
  # r3 — added DestroyPreSnapshotCaptured as the step 0 follow-up.
  def interested?(%DestroyPreSnapshotCaptured{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentCapsRevoked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentChildrenDestroyed{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentMembershipsDropped{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentLineageUnlinked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentTerminated{agent_uri: uri}), do: {:stop, uri}

  # Step 0 (r4 — HIGH-8 fix): capture the pre-destroy state from the
  # AUTHORITATIVE aggregate state, NOT from projections (which are
  # eventually consistent — stale-by-design baseline). The aggregate's
  # `execute/2` for %CaptureDestroyPreSnapshot{} reads from the aggregate's
  # OWN state struct (the aggregate's `caps: MapSet.t()`,
  # `lineage_parent_uri`, `sessions: MapSet.t()` fields — all hydrated from
  # the aggregate's own event history at aggregate-load time; no projection
  # lag concern).
  #
  # The emitted %DestroyPreSnapshotCaptured{} event payload carries the
  # snapshot. The aggregate's apply/2 writes them into the aggregate's
  # state (so future compensation reads see them); the saga also captures
  # them into PM state for fast lookup at error/3 compensation time.
  def handle(%__MODULE__{step: nil}, %AgentDestroyRequested{} = ev) do
    %CaptureDestroyPreSnapshot{agent_uri: ev.agent_uri}
  end

  # Aggregate-side execute/2 clause (in Ezagent.Aggregate.Agent):
  #
  #   def execute(%__MODULE__{} = aggregate, %CaptureDestroyPreSnapshot{} = _cmd) do
  #     %DestroyPreSnapshotCaptured{
  #       agent_uri:        aggregate.uri,
  #       caps:             aggregate.caps,                  # authoritative — from aggregate own state
  #       sessions:         aggregate.sessions,              # authoritative
  #       lineage_parent:   aggregate.lineage_parent_uri     # authoritative
  #     }
  #   end

  # Step 1: Revoke all caps held by this agent. Now driven by the
  # DestroyPreSnapshotCaptured event (step 0's emission) — saga state
  # captures the snapshot into its own fields for fast compensation lookup.
  def handle(%__MODULE__{step: :pre_snapshotted}, %DestroyPreSnapshotCaptured{} = ev) do
    %RevokeAllCapsHeldBy{agent_uri: ev.agent_uri}
  end

  # Step 2: After caps revoked, destroy child agents (lineage cascade).
  def handle(%__MODULE__{step: :caps_revoked} = pm, %AgentCapsRevoked{}) do
    case Ezagent.Projection.AgentLineage.children_of(pm.agent_uri) do
      [] -> %SkipChildrenDestruction{agent_uri: pm.agent_uri}
      children -> %DestroyChildAgents{agent_uri: pm.agent_uri, children: children}
    end
  end

  # Step 3: Drop session memberships.
  def handle(%__MODULE__{step: :children_destroyed} = pm, %AgentChildrenDestroyed{}) do
    %DropAllSessionMembershipsFor{agent_uri: pm.agent_uri}
  end

  # Step 4: Unlink lineage.
  def handle(%__MODULE__{step: :memberships_dropped} = pm, %AgentMembershipsDropped{}) do
    %UnlinkLineage{agent_uri: pm.agent_uri}
  end

  # Step 5: Terminate the aggregate (final).
  def handle(%__MODULE__{step: :lineage_unlinked} = pm, %AgentLineageUnlinked{}) do
    %TerminateAgent{agent_uri: pm.agent_uri}
  end

  # State machine — track step progression.
  def apply(%__MODULE__{} = pm, %AgentDestroyRequested{} = ev),
    do: %{pm | agent_uri: ev.agent_uri, workspace_uri: ev.workspace_uri, step: :requested}

  # r3: step 0 snapshot writes into saga PM state for fast compensation read.
  def apply(%__MODULE__{} = pm, %DestroyPreSnapshotCaptured{} = ev),
    do: %{pm |
      step: :pre_snapshotted,
      pre_destroy_caps: ev.caps,
      pre_destroy_sessions: ev.sessions,
      pre_destroy_lineage_parent: ev.lineage_parent
    }

  def apply(pm, %AgentCapsRevoked{}), do: %{pm | step: :caps_revoked, caps_revoked: true}
  def apply(pm, %AgentChildrenDestroyed{}), do: %{pm | step: :children_destroyed, children_destroyed: true}
  def apply(pm, %AgentMembershipsDropped{}), do: %{pm | step: :memberships_dropped}
  def apply(pm, %AgentLineageUnlinked{}), do: %{pm | step: :lineage_unlinked}

  # Error / compensation (r2 — explicit reverse-commands per step,
  # mirroring `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:189`
  # session-create rollback and `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:240`
  # sandbox-destroy cleanup patterns).
  #
  # Per-step compensation contract (r2 — every step documents):
  #   (a) idempotency: command's `execute/2` returns `{:error, :no_op}` if already done
  #   (b) residue on failure: what partial state would persist if the step half-applied
  #   (c) reverse command: the explicit undo command for compensation
  #   (d) resume behavior: whether the saga resumes from this step or compensates back
  #
  # Step contracts:
  #   Step 1 RevokeAllCapsHeldBy — idempotent (revoke of absent cap is no-op);
  #     residue: partially-revoked caps; reverse: %RestoreCapsHeldBy{caps_snapshot}.
  #   Step 2 DestroyChildAgents — idempotent (each child destroy is itself a saga);
  #     residue: some children destroyed, some not; reverse: NO inverse possible
  #     (child destruction emits events that cannot be unwound) — failure here is
  #     non-compensable; transitions to :stop_with_residue.
  #   Step 3 DropAllSessionMembershipsFor — idempotent;
  #     residue: partial leaves; reverse: %RejoinSessionsAs{sessions_snapshot}.
  #   Step 4 UnlinkLineage — idempotent;
  #     residue: orphan child URIs (no parent ref); reverse: %RelinkLineage{parent_uri}.
  #   Step 5 TerminateAgent — idempotent (already-destroyed → :no_op);
  #     residue: aggregate marked destroyed?; reverse: NO inverse (destroyed? is sticky).
  #
  # The pre-step snapshot is captured at saga start in the PM state as
  # `pre_destroy_caps`, `pre_destroy_sessions`, `pre_destroy_lineage_parent`
  # — populated by reading projections in step 0 BEFORE step 1's command dispatches.

  def error({:error, :no_op}, _cmd, _ctx) do
    # Idempotent re-run — command already done. Continue.
    {:skip, :continue_pending}
  end

  def error({:error, :agent_not_found}, _cmd, _ctx) do
    # Aggregate never existed (or already fully destroyed via another path).
    {:skip, :discard_pending}
  end

  # Step-specific compensation. Each `error/3` clause matches `failed_message`
  # to dispatch the explicit reverse command + continue with a tombstone marker.
  def error({:error, reason}, %RevokeAllCapsHeldBy{} = _cmd, %{context: %{retries: n}} = ctx)
      when n >= 2 do
    # Step 1 failed twice — compensate by restoring snapshot caps then stop.
    {:continue, [%RestoreCapsHeldBy{
       agent_uri: ctx.pm.agent_uri,
       caps_snapshot: ctx.pm.pre_destroy_caps,
       reason: reason
     }],
     %{ctx | context: Map.put(ctx.context, :compensated, true)}}
  end

  def error({:error, _reason}, %DestroyChildAgents{} = _cmd, %{context: %{retries: n}})
      when n >= 2 do
    # Step 2 is non-compensable (per contract above) — stop with residue,
    # operator inspects via /admin/sagas and resolves manually.
    {:stop, :step2_non_compensable_residue}
  end

  def error({:error, reason}, %DropAllSessionMembershipsFor{} = _cmd, %{context: %{retries: n}} = ctx)
      when n >= 2 do
    {:continue, [%RejoinSessionsAs{
       agent_uri: ctx.pm.agent_uri,
       sessions_snapshot: ctx.pm.pre_destroy_sessions,
       reason: reason
     }],
     %{ctx | context: Map.put(ctx.context, :compensated, true)}}
  end

  def error({:error, reason}, %UnlinkLineage{} = _cmd, %{context: %{retries: n}} = ctx)
      when n >= 2 do
    {:continue, [%RelinkLineage{
       agent_uri: ctx.pm.agent_uri,
       parent_uri: ctx.pm.pre_destroy_lineage_parent,
       reason: reason
     }],
     %{ctx | context: Map.put(ctx.context, :compensated, true)}}
  end

  def error({:error, _failure}, _cmd, %{context: ctx}) do
    # Generic retry with backoff for the first 2 attempts.
    {:retry, 1_000, Map.update(ctx, :retries, 1, &(&1 + 1))}
  end
end
```

**Step-failure invariant tests (r2 — Phase 10-C gates):**
- Inject step-1 failure → assert `RestoreCapsHeldBy` event lands + aggregate cap set == pre-destroy snapshot.
- Inject step-2 failure → assert saga halts in `:stop_with_residue` + operator-visible audit row exists.
- Inject step-3 failure → assert `RejoinSessionsAs` events land for every session in snapshot.
- Inject step-4 failure → assert lineage parent ref is restored.
- Replay test: full happy-path destroy → step-5 success → aggregate `destroyed?: true`.

**What this resolves vs the SPEC #440 destroy_log table approach:**

| SPEC #440 r4 (destroy_log table) | This SPEC (DestroyAgentSaga) |
|---|---|
| Hand-rolled append-only side-table | Event stream (already append-only by definition) |
| Hand-rolled reconciler that resumes on boot | Saga subscription resumes from last-processed event automatically |
| Hand-rolled "is this step idempotent" discipline per behavior | Each step is a command to a specific aggregate; aggregate handles its own idempotency (`{:error, :already_destroyed}` on repeated destroy) |
| Hand-rolled partial-failure compensation | `error/3` callback + `{:retry, ...}` / `{:stop, ...}` framework primitives |
| Hand-rolled audit row for "destroy cascade progressed to step N" | Each step emits a domain event; the saga state IS the cascade audit |

The destroy cascade becomes ~100 lines of saga code + per-aggregate command/event variants. The framework owns the "atomic" property (atomic w.r.t. each step boundary, with explicit compensation between steps).

### 3.9 Open questions specific to Phoenix integration

These bubble up to §11 codex review:

- Does our LV codebase use enough `assign_new/3` and per-tab session state that we can safely make the read-path projection-driven? (Yes — current LVs already wrap `Kind.get_slice/2` in `assign/2`; the substitution is mechanical.)
- Do we have any code paths that READ FROM the slice DURING a Behavior.invoke/4 of a DIFFERENT Kind (cross-Kind read inside dispatch)? (Yes — `Behavior.Identity.check_grant_authorized` reads the owner URI's slice. Post-migration, this must read from a projection or query the target aggregate via a fresh dispatch — see §11 q#5.)
- Are there places where the audit table's `invocations` rows are queried by SQL with predicates (workspace_uri, time range)? (Yes — `/admin/audit` LV. Post-migration, audit queries against domain events become event-stream filter operations OR queries against an `audit_events` projection table. §4.7 + §11 q#8.)

---

## 4. Mapping current ezagent architecture → CQRS

### 4.1 Concept-by-concept mapping

| Current | New | Migration notes |
|---|---|---|
| `Ezagent.Kind` behaviour module | `Commanded.Aggregates.Aggregate` behaviour-implementing module | Kind module's `type_name/0` / `behaviors/0` / `persistence/0` callbacks → aggregate's `execute/2` / `apply/2` callbacks. `behaviors/0` (the list of Behaviors a Kind composes) is encoded by aggregate's per-event `apply/2` clauses — one clause per event emitted by any of the former behaviors. |
| `Ezagent.Behavior.X` modules with `actions/0` + `invoke/4` | Per-Behavior namespace of Command modules + Event modules + a per-Aggregate `execute/2` clause | E.g. `Behavior.Chat.actions == [:send, :join, :leave]` becomes `Behavior.Chat.Commands.SendMessage`, `JoinSession`, `LeaveSession` + matching `MessagesPosted`, `MemberJoined`, `MemberLeft` events. The dispatch routes the command to the Session aggregate, which has `execute/2` clauses for each command. |
| Per-Kind slice state (`state.state[behavior.state_slice()]`) | Aggregate state struct | The Kind GenServer's `state.state` map of slices becomes the Aggregate's `defstruct` fields. No more "slice key" — every field is just a struct field on the aggregate. |
| `Ezagent.Kind.Snapshot.save_now/3` (sync `:on_change`) | Commanded snapshot-every-N (Postgres-backed) | Default `snapshot_every: 50` events. Per-Aggregate override where benchmarks justify it. Replaces both `:on_change` and `:periodic` strategies. `:ephemeral` becomes "no snapshot config" (replay-from-events always). `:on_terminate` becomes irrelevant (aggregates have no terminate hook in Commanded). |
| `Ezagent.Persistence` per-workspace scoping (`scope_by_workspace/2`) | Same module + same scoping, applied to projection tables | Workspace isolation invariant moves from slice writes to projection writes + read queries. The function survives unchanged; it just operates on `projections.*` tables now. |
| `Ezagent.Invocation.dispatch/1` | `Ezagent.CommandedApp.dispatch/2` (wrapped by pre-dispatch pipeline) | The 12-step flow collapses (steps 5-10 become Commanded internals); steps 1-4 + 5.5-5.6 + 11-12 stay (now in pre-dispatch pipeline + `after_dispatch` projection-trigger). |
| `Ezagent.KindRegistry` (URI → pid) | Commanded's internal aggregate registry | Direct lookups (e.g. for `Kind.get_slice/2`) are replaced by projection reads. No external callers of `KindRegistry.lookup/1` survive post-migration. |
| `Ezagent.SpawnRegistry` + `Kind.spawn/2` | Implicit (first command at aggregate ID creates it) | The "spawn" verb disappears; aggregates are created by their first creation command (`%RegisterUser{}`, `%CreateSession{}`, etc.). `{:error, {:already_started, pid}}` race becomes `{:error, :already_created}` returned deterministically by the aggregate's `execute/2`. |
| Cross-Kind cascade in imperative caller code (e.g. `EzagentDomainChat.create_session/3`'s 5-dispatch orchestration) | Process Manager (Saga) subscribing to the originating event | E.g. `SessionCreated` event triggers `GrantOwnerCapsSaga` which dispatches `GrantCap` commands; saga's error/3 handles compensation. |
| `Ezagent.Audit.Writer` writing to `invocations` SQLite table | Event stream IS the audit log (for domain events) + audit-events projection for queryable subset | Cross-cutting telemetry (denied authz, persistence failure, cc_bridge events) stays in SQLite audit; domain events move to event stream + queryable projection. See §4.7. |
| `kind_snapshots` SQLite table | Commanded snapshot store (in `eventstore` Postgres schema) | **r4 corrected:** For migrated Kinds, existing snapshot data is forward-migrated via §6.0 snapshot-import as Step 0 of each Phase. The `kind_snapshots` table becomes read-only post-import (no new writes from migrated Kinds); deletion of the table itself is gated by §6.4 preflight (drill receipt + cooldown). Snapshot data for un-migrated Kinds continues to be written during the hybrid window. |
| `Ezagent.ReadyGate` (status: `:ready` / `:not_ready` / `:unknown`) | Implicit (aggregate exists ⇔ command can be dispatched) | The `:not_ready` post-init buffering pattern becomes "first creation command must precede any other command"; subsequent commands fail until the aggregate is created. Buffering (the old `Ezagent.PendingDelivery`) is retired for migrated Kinds. |
| `Ezagent.PendingDelivery` (cast buffer for not-yet-ready Kinds) | Retired for migrated Kinds | Cast commands to non-existent aggregates fail at dispatch (`{:error, :aggregate_not_found}` or whatever Commanded returns for a uncreated-aggregate cast — see §11 q#8). |
| `Ezagent.Behavior.X.post_init/2` + `handle_continue/3` (deferred work after Kind register) | Process Manager subscribed to `AggregateCreated`-style event | The split-init pattern from `external-mirror-domain` SPEC §6.1 becomes: aggregate's creation command emits `WorkerCreated`; a `WorkerBootstrapSaga` subscribes to this event and dispatches the follow-up commands (subscribe-to-publisher etc.). |
| `Ezagent.Kind.Server.handle_call({:ezagent_get_slice, slice_key}, ...)` | Projection table query | Cross-process slice read becomes `Ezagent.Projection.X.get(uri)`. The query routes through the read-model module; no aggregate process is touched on read. |
| `Ezagent.CapabilityRegistry` + `Ezagent.BehaviorRegistry` | Stay unchanged | Cap subjects are still registered at compile/boot time; the registry is consulted in the pre-dispatch pipeline. No event-sourcing concern. |
| `@behaviour Ezagent.Behavior` + cap_subjects/0 + data_owner/1 | Stay (with semantic shift) — cap_subjects represents what commands gate via CapBAC; data_owner represents which aggregate owns the underlying data | The CapBAC chokepoint at pre-dispatch is unchanged; the cap_subject IS the command's behavior + action axis. data_owner now points to an aggregate URI rather than a Kind's owning principal. |

### 4.1.5 Complete Kind / Behavior inventory (r2 — statically generated)

r1 said "5 entity Kinds + 11 Behavior modules" — actual checkout enumeration:

**All Kind modules + their statically-verified persistence (r3 — verified per file:line):**

| Kind module | App | Persistence (actual @file:line) | Durable source | Migration target |
|---|---|---|---|---|
| `Ezagent.Entity.User` | ezagent_domain_identity | `{:snapshot, :on_change}` @ `user.ex:234` | `kind_snapshots` + `users` + `entity_profiles` + `entity_tokens` | `Ezagent.Aggregate.User` (§4.2.1) |
| `Ezagent.Entity.Session` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `session.ex:48` | `kind_snapshots` + `messages`+ `message_routings` + `external_mirror_bindings` | `Ezagent.Aggregate.Session` (§4.2.3) |
| `Ezagent.Entity.Agent` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `agent.ex` | `kind_snapshots` + `agent_api_keys` + `agent_lineage` (registry, not DB) | `Ezagent.Aggregate.Agent` (§4.2.2) |
| `Ezagent.Workspace` | ezagent_domain_workspace | **`:ephemeral`** @ `workspace.ex:61` (r3 corrected) | `workspaces` SQLite table via `Workspace.Store` — durable EXTERNALLY | `Ezagent.Aggregate.Workspace` (§4.2.4) reading from `Workspace.Store` at import |
| `Ezagent.Entity.AgentTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `agent_template.ex:118` | `kind_snapshots` | `Ezagent.Aggregate.AgentTemplate` (§4.2.6) |
| `Ezagent.Entity.SessionTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `session_template.ex:61` | `kind_snapshots` | `Ezagent.Aggregate.SessionTemplate` (§4.2.7) |
| `Ezagent.Entity.ExternalMirrorWorker` | ezagent_domain_external_mirror | **`:ephemeral`** @ `external_mirror_worker.ex:71` (r3 corrected) | NOT durable per-Kind — bindings durable on Session in `external_mirror_bindings` | `Ezagent.Aggregate.ExternalMirrorWorker` (§4.2.5) reconstructed from binding events |
| `Ezagent.Entity.System` (r1+r2 missed) | ezagent_core | **`:ephemeral`** @ `system.ex:32` (r3 added) | NOT durable — config-derived bootstrap singleton | NOT migrated as Aggregate; stays as runtime `Ezagent.Entity.System` GenServer (singleton; analogous to Pty — documented exception) |
| `Ezagent.Entity.CurlAgent` | ezagent_plugin_curl_agent | `{:snapshot, :on_change}` @ `curl_agent.ex` | `kind_snapshots` + `agent_api_keys` | flavor variant of `Aggregate.Agent` |
| `Ezagent.Entity.Echo` (r4 corrected) | ezagent_plugin_echo | **`:ephemeral`** @ `echo.ex:21` | NONE — Echo is stateless responder; no aggregate state | flavor variant of `Aggregate.Agent` with NO durable state (commands accepted but emit no state-mutating events; emits message-reply events only) |
| `Ezagent.Entity.NpAgent` (r4 corrected) | ezagent_plugin_np | **`:ephemeral`** @ `np_agent.ex:65` | NONE — NpAgent is also stateless | flavor variant of `Aggregate.Agent` with NO durable state |

**r3 clarification — `:ephemeral` Kinds with external durability:** Three Kinds declare `:ephemeral` yet have durable state — durability lives in *external* tables/registries, not `kind_snapshots`. The §6.0 import task adapts per source:
- `Workspace`: read `workspaces` rows via `Workspace.Store.list/0`; emit `%WorkspaceSnapshotImported{}` per row.
- `ExternalMirrorWorker`: read `external_mirror_bindings` rows; emit `%WorkerSnapshotImported{}` reconstructed from each binding (cursor `:earliest`; the saga reconciles forward).
- `System`: NOT migrated. Stays singleton GenServer; cross-aggregate code references it via existing facade.

**Behavior modules (24 total — statically enumerated from `find apps -path "*/behavior/*.ex"`):**

| Behavior | App | Disposition r2 |
|---|---|---|
| `Ezagent.Behavior.Identity` | ezagent_domain_identity | decomposed into per-aggregate cap commands |
| `Ezagent.Behavior.IdentityAdmin` (r3 added — `identity.ex:328`) | ezagent_domain_identity | Workspace aggregate commands + admin-shortcut helper in pre-dispatch pipeline (separate behaviour module in same file as Identity) |
| `Ezagent.Behavior.UserCredentials` | ezagent_domain_identity | User aggregate commands |
| `Ezagent.Behavior.UserTokens` | ezagent_domain_identity | User aggregate commands |
| `Ezagent.Behavior.ApiKeys` (r1 missed) | ezagent_domain_identity | Agent aggregate commands |
| `Ezagent.Behavior.WorkspaceUserAdmin` | ezagent_domain_identity | Workspace aggregate commands |
| `Ezagent.Behavior.Chat` | ezagent_domain_chat | Session aggregate commands |
| `Ezagent.Behavior.Template` (r1 missed) | ezagent_domain_chat | AgentTemplate + SessionTemplate aggregate commands |
| `Ezagent.Behavior.OrchestratorAdmin` (r1 missed) | ezagent_domain_chat | Session aggregate commands (orchestrator-scoped) |
| `Ezagent.Behavior.Publisher.SessionImpl` | ezagent_domain_chat | Session aggregate + subscriber tracking moved to projection-side runtime |
| `Ezagent.Behavior.Publisher` (interface) | ezagent_domain_external_mirror | namespace; no slice |
| `Ezagent.Behavior.ExternalMirror` | ezagent_domain_external_mirror | Session aggregate commands |
| `Ezagent.Behavior.ExternalMirrorWorker` | ezagent_domain_external_mirror | Worker aggregate commands |
| `Ezagent.Behavior.Pty` (r1 missed) | ezagent_domain_pty | stays as runtime Behavior (not durable; PTY is ephemeral per-session); decision per §4.3 |
| `Ezagent.Behavior.Workspace` | ezagent_domain_workspace | Workspace aggregate commands |
| `Ezagent.Behavior.Presence` | ezagent_core | stays slice-based (transient runtime; OQ-7) |
| `Ezagent.Behavior.Sandbox` (r4 corrected) | ezagent_core | **PRODUCTION** — `Ezagent.Entity.Agent` declares it at `agent.ex:75`. Migrate to Agent aggregate commands `%SandboxRead{}` / `%SandboxWritePath{}` / `%SandboxDestroy{}` per `sandbox.ex:86` action list. r3 incorrectly classified as test-fixture-only. |
| `Ezagent.Behavior.Lifecycle` | ezagent_core | subsumed by aggregate create/destroy commands |
| `Ezagent.Behavior.Routing` | ezagent_core | Workspace aggregate commands (routing rules durable) |
| `Ezagent.Behavior.Notifications` | ezagent_core | `Commanded.Event.Handler` (side-effect emitter) |
| `Ezagent.Behavior.CurlAgent` | ezagent_plugin_curl_agent | per-flavor Agent aggregate commands |
| `Ezagent.Behavior.Echo` | ezagent_plugin_echo | per-flavor Agent aggregate commands |
| `Ezagent.Behavior.NpAgent` | ezagent_plugin_np | per-flavor Agent aggregate commands |
| `EzagentPluginFeishu.Behavior.UserBinding` (r1 missed) | ezagent_plugin_feishu | User aggregate commands (Feishu binding state) |
| `EzagentPluginFeishu.Behavior.FeishuAllow` (r1 missed) | ezagent_plugin_feishu | Workspace aggregate commands (allow-list state) |

**Phase gate (per `feedback_completion_requires_invariant_test`):** Each phase's invariant test enumerates EVERY Behavior in its scope and asserts each has a corresponding migration target (or an explicit "stays runtime" decision). A new `Ezagent.Invariants.NoBehaviorLeftBehindTest` walks the BehaviorRegistry at Phase 10-D pre-merge and fails if any dispatchable Behavior lacks an Aggregate command mapping.

### 4.2 The 5 entity Kinds — migration target per Kind

#### 4.2.1 `Ezagent.Entity.User` → `Ezagent.Aggregate.User`

**Current state shape (slice):**
```elixir
%{
  identity: %{caps: MapSet.t(Capability.t())},
  user_credentials: %{...counter state...},
  user_tokens: %{...counter state...}
}
```

**New aggregate state (r2 — expanded to cover profile + token-hash + Feishu binding):**
```elixir
defmodule Ezagent.Aggregate.User do
  defstruct [
    :uri,             # canonical URI string — also the aggregate ID
    :workspace_uri,
    :registered_at,
    :password_hash,   # mirrors users.password_hash column

    # Profile fields (r2 fix — `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:21`)
    :display_name,    # required per current Profile changeset
    :email,           # optional; unique-constrained

    caps: MapSet.new(),

    # Tokens — r2 expansion. Each token is the full Entity.Token schema
    # shape per `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:43`.
    # `token_hash` is the bcrypt hash; `label` is operator-visible;
    # `last_used_at` is updated by an event-handler on each auth use.
    tokens: %{}, # token_id => %{token_hash, label, expires_at, last_used_at, minted_at}

    # Feishu binding (r2 fix — UserBinding behavior).
    feishu_binding: nil, # %{open_id, allow_status, paired_at} or nil

    destroyed?: false
  ]
  ...
end
```

**Commands (r2 — expanded):**
- `%RegisterUser{uri, workspace_uri, password_hash, display_name, initial_caps}` → emits `%UserRegistered{}`
- `%UpsertProfile{uri, display_name, email}` → emits `%ProfileUpserted{}`
- `%GrantCapToUser{uri, cap, granted_by}` → emits `%CapGrantedToUser{}` (or `{:error, :grant_not_owner}` if granter lacks data-owner cap)
- `%RevokeCapFromUser{uri, cap, revoked_by}` → emits `%CapRevokedFromUser{}`
- `%MintTokenForUser{uri, token_id, token_hash, label, expires_at}` → emits `%TokenMintedForUser{}`
- `%MarkTokenUsed{uri, token_id, used_at}` → emits `%TokenUsedByUser{}` (issued by the auth handler; updates `last_used_at`)
- `%RevokeTokenForUser{uri, token_id}` → emits `%TokenRevokedForUser{}`
- `%RotatePasswordForUser{uri, new_password_hash}` → emits `%PasswordRotatedForUser{}`
- `%BindFeishuOpenId{uri, open_id}` → emits `%FeishuOpenIdBound{}` (UserBinding behavior)
- `%UnbindFeishuOpenId{uri}` → emits `%FeishuOpenIdUnbound{}`
- `%ImportUserSnapshot{uri, snapshot_payload}` (r2 forward-migration command — see §6.0) → emits `%UserSnapshotImported{}`
- `%DestroyUser{uri}` → emits `%UserDestroyRequested{}` (which triggers `DestroyUserSaga` for cascade)

**Events** — one per command above; payload is the command minus the routing UUID.

**Projections:**
- `user_caps_projection` — Ecto table `projections.user_caps(uri, cap_json, granted_by, granted_at)`. Read by `Behavior.Identity` queries and `/admin/users` LV. `consistency: :strong` for cap-grant dispatches that need read-after-write at the LV.
- `user_profile_projection` — Ecto table `projections.user_profile(uri, workspace_uri, display_name, email, registered_at, destroyed?)`. r3 fix (HIGH-5): added `display_name` (NOT NULL — required per `entity_profiles` changeset at `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:41`) + `email` (optional, unique). Read by the user listing LV + login flow + workspace-scoped user filters.
- `user_tokens_projection` — Ecto table `projections.user_tokens(uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, revoked_at, workspace_uri)`. r3 fix (HIGH-5): added `token_hash` (bcrypt hash — required for auth verification), `label` (operator-visible name), `last_used_at` (updated on each auth-handler dispatch), `workspace_uri` (per-tenant scope). Read by bearer auth + token-list admin LV.

**Field-level parity gates (r3 — HIGH-5):** §6.0 `mix ezagent.aggregate.verify --kind user` reads every row in `entity_profiles` + `entity_tokens` and asserts a matching `user_profile_projection` + `user_tokens_projection` row exists post-replay with every column equal. Any divergence blocks cutover.

**Persistence:** snapshot every 50 events. User aggregate event volume is low (one event per cap grant + one per token mint); 50 events is ~weeks of activity per active user.

#### 4.2.2 `Ezagent.Entity.Agent` → `Ezagent.Aggregate.Agent`

**Current state (slice):** complex — flavor-specific state + lineage parent_uri + api_keys + workspace_uri + per-template fork state.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.Agent do
  defstruct [
    :uri,
    :workspace_uri,
    :flavor,           # :cc | :codex | :curl | :np | :echo | ...
    :parent_template_uri,
    :lineage_parent_uri,
    :config_dir,
    :api_keys,         # encrypted map; api_keys behavior's slice
    caps: MapSet.new(),
    flavor_state: %{},  # per-flavor sub-state, opaque to non-flavor code
    sessions: MapSet.new(),  # session URIs this agent is a member of
    destroyed?: false
  ]
end
```

**Commands** — split into flavor-agnostic core + per-flavor extensions:

Core:
- `%CreateAgent{uri, workspace_uri, flavor, parent_template_uri, lineage_parent_uri, initial_caps, config_dir}` → emits `%AgentCreated{}`
- `%GrantCapToAgent{uri, cap, granted_by}` → emits `%CapGrantedToAgent{}`
- `%RevokeCapFromAgent{uri, cap, revoked_by}` → emits `%CapRevokedFromAgent{}`
- `%PutApiKeyForAgent{uri, key_name, encrypted_key}` → emits `%ApiKeyPutForAgent{}`
- `%JoinSessionAsAgent{uri, session_uri}` → emits `%AgentJoinedSession{}`
- `%LeaveSessionAsAgent{uri, session_uri}` → emits `%AgentLeftSession{}`
- `%DestroyAgent{uri}` → emits `%AgentDestroyRequested{}` (triggers `DestroyAgentSaga`)

Per-flavor (cc, codex, ...):
- Each flavor exposes a `%FlavorSpecific{...}` command variant; the aggregate's `execute/2` dispatches to the flavor's logic + emits a flavor-specific event. The flavor's `apply/2` clause mutates `flavor_state` opaquely.

**Projections:**
- `agent_profile_projection` — Ecto table for the listing LV.
- `agent_caps_projection` — for cap queries.
- `agent_lineage_projection` — replaces `Ezagent.AgentLineage` registry (parent/child relationships).

#### 4.2.3 `Ezagent.Entity.Session` → `Ezagent.Aggregate.Session`

**Current state:** highest complexity in the codebase — Chat slice + Publisher slice + ExternalMirror slice; members; rules; routing.

**New aggregate state (r2 — every durable Chat/Publisher slice field enumerated):**

Sourced statically from `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:144-:242` (Chat slice) + `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:150-:165` (Publisher slice) + `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` (ExternalMirror slice).

```elixir
defmodule Ezagent.Aggregate.Session do
  defstruct [
    :uri,
    :workspace_uri,
    :template_uri,
    :owner_uri,              # PR-OWN-2 caps-data-ownership SPEC §7 — durable

    # Chat slice — durable members & message-cursor state.
    members: %{},            # %{URI => %{online: bool}} — durable (rejoin replay)
    last_seen: %{},          # %{URI => DateTime} — when each offline member last seen
    last_message_id: nil,    # stable cross-ref to MessageStore row
    last_message: nil,       # full %Ezagent.Message{} for ExternalMirror adapter purity
    send_cursor: 0,          # monotonic; bumps on every successful send (idempotent retry safety)
    recent_messages: [],     # [{slice_change_cursor, msg_id}] — PR-N3 r4 bounded ring (durable)

    # NON-durable runtime — explicitly excluded from aggregate state.
    # (Per Chat slice: `monitors: %{}` — Process.monitor refs cannot survive
    # restart and have no event-sourced equivalent. The post-Phase-10 design
    # rebuilds monitor refs by walking aggregate-`members` and re-monitoring
    # in a runtime sidecar at aggregate-load time.)

    # Publisher slice — durable ring + cursor for SliceChange replay.
    publisher_ring: [],      # bounded ring of last N events for cursor catchup
    publisher_cursor: 0,     # monotonic event cursor
    publisher_retention: 100,# per-session override (default 100; from `init_slice` arg)
    # Publisher.subscribers / monitors — NON-durable; subscriber tracking moves
    # to a sibling `Ezagent.Publisher.SubscriberRegistry` GenServer that
    # rebuilds on aggregate load by re-subscribing each `Phoenix.PubSub` topic
    # the projection broadcasts on. Per §3.4 read-path pattern.

    # ExternalMirror slice — durable binding descriptors.
    external_mirror_bindings: [], # list of %{binding_id, descriptor, adapter} maps

    # SessionTemplate working copy — durable structured map staged before
    # instantiate. r3 fix (MED-6): actual default per
    # `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:255`
    # `default_template_working_copy/0` has these 5 sub-fields:
    # r4 (MED-7): nested field names verbatim from `default_template_working_copy/0`
    # at `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:255`-`:285`.
    template_working_copy: %{
      # [{slot_name :: String.t(),
      #   source_agent_template_uri :: URI.t(),   # NOT source_template_uri (r3 was wrong)
      #   live_worker_uri :: URI.t(),
      #   generation :: non_neg_integer()}]
      agent_slots: [],
      # [{matcher_ast :: term(), [slot_name :: String.t()]}]
      routing_rules: [],
      orchestrator_template_uri: nil, # URI.t() | nil
      default_workspace_uri: nil,     # URI.t() | nil
      description: ""                  # String.t()
    },

    destroyed?: false
  ]
end
```

**Replay tests (r2 — Phase 10-B invariant tests):**
- **Rejoin replay** — a member who left at `last_seen[uri]=T1` rejoins at T2; aggregate replay reconstructs `recent_messages` ring; the JoinSession command's `execute/2` reads the ring + emits `MissedMessagesReplayed` events sized to the gap.
- **External mirror dedupe** — `send_cursor` monotonically bumps even on idempotent message_id resends so ExternalMirror's adapter sees the retry as a fresh slice_change event.
- **Publisher cursor catchup** — a cold-spawning Worker subscribes from `cursor: -100`; aggregate replay reconstructs `publisher_ring` of last 100; Worker receives them in order.

These three tests directly exercise the durable fields r1 missed; failure of any constitutes a Phase 10-B blocker.

**Commands** — many; the largest aggregate by command count.

Core lifecycle:
- `%CreateSession{uri, template_uri, owner_uri, workspace_uri}` → emits `%SessionCreated{}`
- `%DestroySession{uri}` → emits `%SessionDestroyRequested{}` (triggers `DestroySessionSaga`)

Membership (`Behavior.Chat` actions):
- `%JoinSession{uri, joiner_uri}` → emits `%MemberJoinedSession{}`
- `%LeaveSession{uri, leaver_uri}` → emits `%MemberLeftSession{}`
- `%TransferSessionOwnership{uri, new_owner_uri}` → emits `%SessionOwnershipTransferred{}`

Messaging:
- `%PostMessageToSession{uri, message}` → emits `%MessagePosted{}` (also triggers fanout-via-projection)

Publisher (`Behavior.Publisher.SessionImpl`):
- `%SubscribeToSessionPublisher{uri, subscriber_pid, cursor}` → emits `%PublisherSubscriberAdded{}`
- `%UnsubscribeFromSessionPublisher{uri, subscriber_pid}` → emits `%PublisherSubscriberRemoved{}`
- (Note: PIDs in events is a smell — see §11 q#5. Maybe subscribers are tracked outside the aggregate.)

External mirror (`Behavior.ExternalMirror`):
- `%BindExternalMirror{uri, binding_descriptor}` → emits `%ExternalMirrorBound{}`
- `%UnbindExternalMirror{uri, binding_id}` → emits `%ExternalMirrorUnbound{}`

**Projections** — many:
- `session_profile_projection` — basic session state for LV listing.
- `session_messages_projection` — replaces the current `messages` SQLite table. Each `MessagePosted` event → insert row.
- `session_members_projection` — `(session_uri, member_uri, joined_at, left_at)` for membership queries.
- `external_mirror_bindings_projection` — replaces the current `external_mirror_bindings` SQLite table.

#### 4.2.4 `Ezagent.Workspace` → `Ezagent.Aggregate.Workspace`

**Current state:** tiny — workspace metadata + ownership.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.Workspace do
  defstruct [
    :uri,
    :name,
    :created_by,
    :created_at,
    members: MapSet.new(),
    destroyed?: false
  ]
end
```

**Commands:**
- `%CreateWorkspace{uri, name, created_by}` → emits `%WorkspaceCreated{}`
- `%AddMemberToWorkspace{uri, member_uri}` → emits `%MemberAddedToWorkspace{}`
- `%RemoveMemberFromWorkspace{uri, member_uri}` → emits `%MemberRemovedFromWorkspace{}`
- `%DestroyWorkspace{uri}` → emits `%WorkspaceDestroyRequested{}` (triggers `DestroyWorkspaceSaga` — cascades destroy on all sessions/agents/users in workspace; expensive)

**Projections:**
- `workspaces_projection` — for the picker LV. Replaces current `workspaces` SQLite table.
- `workspace_members_projection` — for the cap-vis SPEC's `list_workspaces_for/2`. Cap-based visibility becomes a JOIN against this + the cap projection.

#### 4.2.5 `Ezagent.ExternalMirror.Worker` → `Ezagent.Aggregate.ExternalMirrorWorker`

**Current state:** binding-specific worker state.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.ExternalMirrorWorker do
  defstruct [
    :uri,
    :session_uri,
    :workspace_uri,
    :binding_descriptor,
    :cursor,                # publisher cursor
    :adapter_state,         # per-adapter internal state
    destroyed?: false
  ]
end
```

**Commands:**
- `%SpawnWorker{uri, session_uri, binding_descriptor}` → emits `%WorkerSpawned{}` (triggers `BootstrapWorkerSaga`)
- `%AdvanceWorkerCursor{uri, new_cursor}` → emits `%WorkerCursorAdvanced{}`
- `%TerminateWorker{uri}` → emits `%WorkerTerminated{}`

**Projection:**
- `external_mirror_workers_projection` — live worker status + last-cursor.

#### 4.2.6 `Ezagent.Entity.AgentTemplate` → `Ezagent.Aggregate.AgentTemplate` (r2 — HIGH-4 fix)

r1 missed this. AgentTemplate is `{:snapshot, :on_change}` (durable; `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex:118`), carries 2 slices (Identity + Template), and serves dispatchable `:read` / `:write` / `:instantiate` actions.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.AgentTemplate do
  defstruct [
    :uri, :workspace_uri, :parent_template_uri,
    :template_content,  # the Template behavior's durable content
    caps: MapSet.new(),  # Identity slice
    versions: [],        # version history (template_hash, content_at_version)
    destroyed?: false
  ]
end
```

**Commands:** `%CreateAgentTemplate{}`, `%WriteAgentTemplate{}`, `%ForkAgentTemplate{new_uri, parent_uri}`, `%GrantCapToAgentTemplate{}`, `%InstantiateAgentTemplateAsAgent{}` (triggers `InstantiateAgentSaga`).

**Projection:** `agent_template_profile_projection` for `/admin/templates` LV.

#### 4.2.7 `Ezagent.Entity.SessionTemplate` → `Ezagent.Aggregate.SessionTemplate` (r2 — HIGH-4 fix)

Same shape as AgentTemplate; persistence `{:snapshot, :on_change}` (`apps/ezagent_domain_chat/lib/ezagent/entity/session_template.ex:61`). Carries `update_template` / `save_template_as` / `fork` action vocabulary on top of standard Template commands.

**Distinguishing commands:** `%UpdateSessionTemplate{}` (new version of current parent), `%SaveSessionTemplateAs{new_name}` (first version of new template — parent_template_uri set), `%ForkSessionTemplate{}`.

### 4.3 The 24 Behavior modules — disposition (r2 — HIGH-4 fix)

| Behavior | Disposition | Notes |
|---|---|---|
| `Behavior.Identity` | Decomposed into per-aggregate cap-handling commands | Cap grant/revoke commands land on the relevant aggregate (User/Agent); the Behavior module becomes a namespace for the commands + the cap_subjects/0 callback for CapBAC registration. data_owner/1 callback stays (drives saga compensation paths). |
| `Behavior.Chat` | Session aggregate commands + projector | All actions become Session commands; the Behavior module becomes a namespace + cap_subjects + the message projection's update logic. |
| `Behavior.Publisher` + `Behavior.Publisher.SessionImpl` | Session aggregate commands; subscriber tracking moved to projection-side | See §11 q#5 — PID-in-event smell; subscriber tracking is a runtime concern, not an event-sourced one. |
| `Behavior.ExternalMirror` | Session aggregate commands + Worker aggregate commands | Bindings are persisted as Session events; worker spawn is a saga (BootstrapWorkerSaga subscribes to BindingCreated, dispatches SpawnWorker). |
| `Behavior.IdentityAdmin` | Workspace aggregate commands + admin-shortcut helper module | The admin-cap-bypass logic lives in the pre-dispatch authz pipeline; the commands themselves land on the Workspace aggregate. |
| `Behavior.UserCredentials` | User aggregate commands | Password rotation is a User command. The `users.password_hash` column becomes a projection. |
| `Behavior.UserTokens` | User aggregate commands | Token mint/revoke is a User command. The `entity_tokens` table becomes a projection. |
| `Behavior.WorkspaceUserAdmin` | Workspace aggregate commands | User creation as a workspace admin → `AddUserToWorkspace` command on Workspace + `RegisterUser` command on User. The two-command sequence is bundled in a saga (`CreateUserInWorkspaceSaga`). |
| `Behavior.Presence` | Stays slice-based (NOT migrated) | Presence is real-time runtime state, not durable history. Kept as-is on a non-Aggregate `Ezagent.Presence` GenServer (or moved to `Phoenix.Presence` natively). §11 q#7. |
| `Behavior.Sandbox` | Stays runtime-only | Test-fixture-only Behavior; not part of production state model. |
| `Behavior.Routing` | Routes are workspace-scoped rules, stored as Workspace aggregate state | Workspace command `AddRoutingRule` / `RemoveRoutingRule` + matching events. |
| `Behavior.Notifications` | Event handler subscribing to relevant events + emitting notifications | See §11 q#5 — notification emission is a side-effect handler, not state-mutating. `Commanded.Event.Handler` impl. |
| `Behavior.Lifecycle` | Subsumed by aggregate creation/destruction commands | Lifecycle as a Behavior disappears post-migration; each Kind's create/destroy commands replace it. |
| `Behavior.ApiKeys` (r1 missed) | Agent aggregate commands | `Behavior.ApiKeys` lives on Agent (post 2026-05-26 flip per `apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex:53`); becomes `%PutApiKeyForAgent{}` + matching event. The `agent_api_keys` SQLite table becomes a projection (encrypted column preserved). |
| `Behavior.Template` (r1 missed) | AgentTemplate + SessionTemplate aggregate commands | Template `:read` / `:write` / `:instantiate` actions migrate to AgentTemplate/SessionTemplate aggregates (§4.2.6 + §4.2.7). |
| `Behavior.OrchestratorAdmin` (r1 missed) | Session aggregate commands | Orchestrator admin actions on a Session (e.g. `force_join`, `eject_member`) become Session aggregate commands gated by an orchestrator-admin cap. |
| `Behavior.Pty` (r1 missed) | Stays runtime Behavior (PTY is ephemeral per-session) | Pty state is transient (PID + buffer); no event-sourced equivalent makes sense. Pty Behavior stays as a runtime sidecar; dispatches go through legacy `Invocation.dispatch/1` permanently. Documented exception to the "all Behaviors migrate" pattern. |
| `Behavior.CurlAgent` | Agent aggregate per-flavor commands | curl_agent-specific actions become per-flavor Agent commands (§4.2.2). |
| `Behavior.Echo` | Agent aggregate per-flavor commands | echo-flavor actions become per-flavor Agent commands. |
| `Behavior.NpAgent` | Agent aggregate per-flavor commands | np-flavor actions become per-flavor Agent commands. |
| `EzagentPluginFeishu.Behavior.UserBinding` (r1 missed) | User aggregate commands | Feishu binding state is durable per-user; becomes `%BindFeishuOpenId{}` / `%UnbindFeishuOpenId{}` on User aggregate (§4.2.1). |
| `EzagentPluginFeishu.Behavior.FeishuAllow` (r1 missed) | Workspace aggregate commands | Feishu allow-list is workspace-scoped durable state; becomes Workspace aggregate commands. |

### 4.4 Cross-Kind workflows — the saga inventory

Post-migration sagas that replace ad-hoc cross-Kind orchestration:

| Saga | Triggered by | Cascade |
|---|---|---|
| `DestroyAgentSaga` | `AgentDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents → DropAllSessionMembershipsFor → UnlinkLineage → TerminateAgent |
| `DestroyUserSaga` | `UserDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents (where user is parent) → DropAllSessionMembershipsFor → TerminateUser |
| `DestroySessionSaga` | `SessionDestroyRequested` | EvictAllMembers → UnbindAllExternalMirrors → DestroyAllChildAgents → TerminateSession |
| `DestroyWorkspaceSaga` | `WorkspaceDestroyRequested` | DestroyAllSessions → DestroyAllAgents → DestroyAllUsers → TerminateWorkspace (expensive — requires explicit confirm + admin caps; reuses each child's destroy saga) |
| `CreateSessionSaga` | `SessionCreated` | GrantOwnerOrchestratorAdminCap (the bug 2 path from URI canonicalization SPEC) → InvokeTemplateClassInitHooks → AnnounceSessionReady |
| `CreateUserInWorkspaceSaga` | `WorkspaceAdminRequestedUserCreate` | RegisterUser → GrantDefaultCaps → AddUserToWorkspaceMembers → MintInitialToken (optional) |
| `BootstrapWorkerSaga` | `BindingCreated` | SpawnWorker → SubscribeToSessionPublisher → AnnounceWorkerReady |
| `RevokeCapCascadeSaga` | `WorkspaceMembershipRevoked` | RevokeAllWorkspaceScopedCapsFor (the principal whose membership was revoked loses all caps scoped to that workspace) |
| `CapGrantOwnershipVerifySaga` | `CapGrantRequested` | VerifyGranterHasDataOwnerCap (via reading granter's cap projection at command-time) → either dispatch the actual grant or reject with `:grant_not_owner` |

Each saga is ~50-150 lines + the per-step command/event variants. Total saga LOC across the inventory ≈ 1500-2000 LOC. Replaces the current ~3000 LOC of ad-hoc cross-Kind orchestration in domain modules.

### 4.5 The pre-dispatch pipeline — where step 5.5 + 5.6 + idempotency move to

Current dispatch routes steps 5.5 (CapBAC) + 5.6 (workspace isolation) through `Kind.Runtime.handle_dispatch/4`, inside the Kind GenServer's `handle_call`. Post-migration, these checks happen BEFORE `Commanded.Application.dispatch/2` — in a pre-dispatch pipeline module.

```elixir
defmodule Ezagent.CommandedApp.Dispatch do
  alias Ezagent.CommandedApp

  @spec dispatch(cmd :: struct(), opts :: keyword()) ::
    :ok | {:error, term()}
  def dispatch(cmd, opts \\ []) do
    with :ok <- Ezagent.URI.canonicalize_cmd(cmd),         # step 1 — canonicalize URIs in cmd
         :ok <- check_idempotency(cmd, opts),              # step 1.5 — idempotency key check
         :ok <- check_capbac(cmd, opts),                   # step 5.5 — CapBAC chokepoint
         :ok <- check_workspace_isolation(cmd, opts),      # step 5.6 — cross-workspace deny
         :ok <- CommandedApp.dispatch(cmd, opts) do        # step 6+ — Commanded internals
      :ok
    end
  end

  defp check_capbac(cmd, opts) do
    caller = Keyword.fetch!(opts, :caller)
    caps = Keyword.fetch!(opts, :caps)
    needed = Ezagent.CapabilityRegistry.cap_for_command(cmd.__struct__)
    if Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp check_workspace_isolation(cmd, opts) do
    caller_workspace = Keyword.fetch!(opts, :caller_workspace)
    target_workspace = cmd.workspace_uri  # every cmd carries workspace_uri
    if caller_workspace == target_workspace or admin?(opts),
      do: :ok,
      else: {:error, :cross_workspace_denied}
  end

  ...
end
```

Every external entry (LV, Channel, CLI, MCP) calls `Ezagent.CommandedApp.Dispatch.dispatch(cmd, opts)`. The pre-dispatch pipeline is the new chokepoint — equivalent to step 5.5 + 5.6 today.

The `Ezagent.CommandedApp.dispatch/2` (the bare Commanded application) is private to this module; nothing outside the pipeline calls it directly. Invariant test: grep for `Ezagent.CommandedApp.dispatch` outside `Ezagent.CommandedApp.Dispatch` is empty (mirror of current `single_dispatch_entry_test.exs`).

### 4.6 Aggregate ID derivation — URI canonicalization parity

Per `feedback_register_lookup_key_parity` + `feedback_uuid_is_canonical_identifier`:

- Every command MUST carry a canonical URI string in a field named `:uri` (or the relevant variant, e.g. `:agent_uri`, `:session_uri`).
- The router's `identify` clause uses this field:
  ```elixir
  identify(Ezagent.Aggregate.User, by: :uri, prefix: "")
  ```
- The canonical form is `Ezagent.URI.parse!(...) |> URI.to_string()` — same as the URI-canonicalization SPEC.
- The pre-dispatch pipeline canonicalizes the URI fields before dispatch.
- Cross-aggregate references (e.g. a Session command that references an Agent URI) carry both URIs as canonical strings.

The aggregate ID is opaque to the aggregate (it's the routing key, not state); the URI inside the aggregate state is the same canonical string. Single source of truth; no divergence between routing and state.

### 4.7 The audit log — what's a domain event vs telemetry

Two distinct concepts collapse into one `invocations` table today; they DIVERGE post-migration:

**Domain events (in event stream):**
- `UserRegistered`, `CapGrantedToUser`, `MessagePosted`, `SessionCreated`, `MemberJoinedSession`, `WorkerSpawned`, ... — every state-mutating event.
- Persisted in event store with full payload; queryable via projection (`audit_events_projection`).
- The event stream is the audit log; no separate audit writer.

**Telemetry-only events (stay in SQLite `audit` table):**
- `[:ezagent, :authz, :denied]` — the dispatch was rejected; nothing was state-mutated; not a domain event.
- `[:ezagent, :persistence, :failed]` — infra-level failure; not part of aggregate history.
- `[:ezagent, :cc_bridge, :event]` — bridge sidechannel; not state-mutating.
- `[:ezagent, :chat, :receive, :dropped]` — runtime drop; not state-mutating.
- `[:ezagent, :notification, :emit]` — side-effect emission record; not state-mutating in the source aggregate.

**Audit query patterns:**
- "What did user X do between time A and B" → query event stream for events with `metadata.caller == "X"` AND `created_at BETWEEN A AND B`. Either via Postgres event store SQL OR via `audit_events_projection` (a denormalized read model for fast querying).
- "Why was this dispatch denied" → query the SQLite `audit` table for the `[:ezagent, :authz, :denied]` row (this is NOT in the event stream because nothing happened in the domain).
- "What's the current cap set for user X" → query `user_caps_projection`.
- "What's the cap-grant history for user X" → query event stream for `CapGrantedToUser` / `CapRevokedFromUser` events filtered by `metadata.target == "X"`.

This split keeps domain events pure (only state-mutating facts; no telemetry noise in the stream) while preserving telemetry for ops + debugging.

---

### 4.8 LV / Channel / CLI write-then-immediate-read consistency matrix (r2 — HIGH-3 fix)

Codex r1 HIGH-3: r1 said "opt to :strong per dispatch site" without enumerating sites. Default `:eventual` is unsafe at any callsite that immediately re-reads state.

**Statically-enumerated write→read sites that MUST use `consistency: :strong`** (or named-projector consistency list) — file:line verified at r3:

| Callsite | File:line | Write | Immediate re-read | Required mode |
|---|---|---|---|---|
| Create user | `users_live.ex:137` | RegisterUser | `list_users()` @ `:143` | `:strong` |
| Profile upsert | `users_live.ex:177` | UpsertProfile | `list_users()` @ `:181` | `:strong` |
| Set password (r3 added) | `users_live.ex:202` | RotatePasswordForUser | `list_users()` @ `:206` | `:strong` |
| Promote to system (r3 added) | `users_live.ex:230` | AddMemberToWorkspace(system) | `list_users()` @ `:235` | `:strong` |
| Revoke from system (r3 added) | `users_live.ex:250` | RemoveMemberFromWorkspace(system) | `list_users()` @ `:253` | `:strong` |
| Add workspace member | `workspace_detail_live.ex:165` | AddMemberToWorkspace | `Workspace.Store.get_by_name/1` | `:strong` |
| Remove workspace member (r3 added) | `workspace_detail_live.ex:255`/`:273` | RemoveMemberFromWorkspace | reload members | `:strong` |
| Grant cap | `entity_caps_live.ex:142` | GrantCapToUser / GrantCapToAgent | reload caps | `:strong` |
| Add routing rule | `routing_live.ex:235` | AddRoutingRule | reload rules | `:strong` |
| Delete routing rule (r3 added) | `routing_live.ex:307` | DeleteRoutingRule | reload rules | `:strong` |
| Enable/disable routing rule (r3 added) | `routing_live.ex:308`-region | ToggleRoutingRule | reload rules | `:strong` |
| Create agent — **r3 file corrected** | `agent_new_live.ex:120` | CreateAgent | redirect→agent detail | `:strong` |
| Set api_key — **r3 confirmed exists** | `agent_api_keys_live.ex` (put handler) | PutApiKeyForAgent | reload keys list | `:strong` |
| Delete api_key (r3 added) | `agent_api_keys_live.ex:159` | DeleteApiKeyForAgent | reload keys list | `:strong` |
| Create session (wizard) | `apps/ezagent_web/lib/ezagent_web/live/home_live.ex` wizard submit | CreateSession | redirect→/sessions/X mount | `:strong` |
| Mint user token (CLI) | `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.token.ex:75` | MintTokenForUser | print token row | `:strong` |
| Bind external mirror | feishu bind LV/CLI | BindExternalMirror | reload bindings | `:strong` |
| Workspace create | `workspaces_live.ex` | CreateWorkspace | redirect→detail | `:strong` |
| Send chat message | LV / Channel chat send | PostMessageToSession | (NO re-read; fanout via PubSub) | `:eventual` (acceptable) |

**Additional callsites (r4 — facades + admin_live + feishu sites HIGH-3 added):**

| Callsite | File:line | Facade | Required mode |
|---|---|---|---|
| Workspace add_template | `workspace_detail_live.ex:307` (facade `Ezagent.Workspace.add_template/3`) | facade-declared `@consistency :strong` | `:strong` |
| Admin create session | `admin_live.ex:804` (facade `EzagentDomainChat.create_session/3`) | facade-declared `@consistency :strong` | `:strong` |
| Admin invite session member | `admin_live.ex:1019` (facade chat join via `Behavior.Chat`) | facade-declared `@consistency :strong` | `:strong` |
| Admin session routing CRUD | `admin_live.ex:1381` | facade-declared `@consistency :strong` | `:strong` |
| Feishu user bind | `feishu_bindings_live.ex:88` (facade `EzagentPluginFeishu.bind/2`) | facade-declared `@consistency :strong` | `:strong` |
| Feishu user unbind | `feishu_bindings_live.ex:88`-region | facade-declared `@consistency :strong` | `:strong` |
| Session ExternalMirror bind | `admin/session_external_mirror_live.ex:221` (facade `ExternalMirror.bind/4`) | facade-declared `@consistency :strong` | `:strong` |
| Session ExternalMirror unbind | `admin/session_external_mirror_live.ex:221`-region | facade-declared `@consistency :strong` | `:strong` |

**The matrix is the source of truth.** Every dispatch path is assigned a consistency mode here at SPEC-time; the impl PR cannot deviate.

**Phase 10-B/10-C invariant test (r4 — dual-gate, facade-aware):**

The r3 single-AST-rule "find dispatch in handle_event" was insufficient because LV writes go through facade modules (`Ezagent.Workspace.add_template/3`, `EzagentDomainChat.create_session/3`, etc) — the LV doesn't see `Commanded.App.dispatch/2` directly. r4 splits the gate in two:

**Gate 1 — Facade declaration (write side):** Every domain-context write facade (the modules under `apps/ezagent_domain_*/` that LVs/CLI/Channel call) declares a `@consistency :strong | :eventual | {:named, [projector]}` module attribute on each public function that ends in a `Ezagent.CommandedApp.dispatch/2` call. The attribute is the API contract. Example:

```elixir
defmodule EzagentDomainChat do
  @consistency :strong
  @doc "Create a new session — uses strong consistency because callers redirect to the detail page."
  def create_session(name, owner_uri, opts) do
    cmd = %CreateSession{...}
    Ezagent.CommandedApp.Dispatch.dispatch(cmd, opts ++ [consistency: :strong])
  end

  @consistency :eventual
  @doc "Post a chat message — fanout via PubSub is acceptable async."
  def post_message(session_uri, message) do
    ...
  end
end
```

A new invariant `Ezagent.Invariants.FacadeConsistencyDeclaredTest` walks every `apps/ezagent_domain_*/lib/**/*.ex` module + every `apps/ezagent_plugin_*/lib/**/*.ex` module, finds every public `def` that calls `Ezagent.CommandedApp.Dispatch.dispatch/2` (transitive — also matches `Ezagent.CommandedApp.dispatch/2` directly), and asserts the function has a `@consistency` attribute on its docstring/spec. Missing attribute → CI fail.

**Gate 2 — LV write→read coverage (read side):** `Ezagent.Invariants.LVConsistencyTest` walks every `apps/ezagent_plugin_liveview/lib/**/*.ex` LV module. For each `handle_event/3` clause, it finds:
1. The first facade call (a call to any module declared in Gate 1's set).
2. Any subsequent `assign(socket, ...)` that re-reads a projection table.
3. Looks up the facade's `@consistency` declaration. If the LV re-reads a projection updated by the facade's events, the facade must be `:strong` OR a named-projector list including that projection.
4. Asserts the projection coverage map (Appendix D) lists this facade as a source for the projection being re-read.

This catches facade-mediated writes that the r3 direct-AST rule missed.

**Projection→facade coverage map (new Appendix D):** an explicit mapping `%{<projection_module> => [<facades that emit events updating it>]}`. Updated at impl-time per phase. The Gate 2 lookup uses this map.

**Future callsites:** any new write→immediate-read pattern MUST be added to this matrix at SPEC-time + the invariant updated. The matrix is the discipline; the invariant is the gate.

---

## 5. Read Model strategy

### 5.1 One projection per logical read view

Each LiveView page / API endpoint has a corresponding projection table:

| Projection | Source events | Read by |
|---|---|---|
| `user_profile` | UserRegistered, PasswordRotatedForUser, UserDestroyRequested | `/admin/users`, login flow |
| `user_caps` | CapGrantedToUser, CapRevokedFromUser | `/admin/caps`, dispatch authz |
| `user_tokens` | TokenMintedForUser, TokenRevokedForUser | `entity_tokens` reads, bearer auth |
| `agent_profile` | AgentCreated, AgentDestroyRequested | `/admin/agents`, agent picker |
| `agent_caps` | CapGrantedToAgent, CapRevokedFromAgent | `/admin/caps`, dispatch authz |
| `agent_lineage` | AgentCreated (with parent_uri), AgentDestroyRequested | lineage queries |
| `agent_api_keys` | ApiKeyPutForAgent | runtime credential fetch (NOTE: encrypted in projection too; same encryption as current `agent_api_keys` table) |
| `session_profile` | SessionCreated, SessionDestroyRequested, SessionOwnershipTransferred | `/sessions`, session picker |
| `session_messages` | MessagePosted | `/sessions/X`, chat history (replaces `messages` SQLite table) |
| `session_members` | MemberJoinedSession, MemberLeftSession | membership queries, `/sessions/X` |
| `external_mirror_bindings` | ExternalMirrorBound, ExternalMirrorUnbound | bindings reconciler, `/admin/mirrors` |
| `external_mirror_workers` | WorkerSpawned, WorkerCursorAdvanced, WorkerTerminated | worker status |
| `workspaces` | WorkspaceCreated, WorkspaceDestroyRequested | workspace picker, `Workspace.list_*` |
| `workspace_members` | MemberAddedToWorkspace, MemberRemovedFromWorkspace | `list_workspaces_for/2` cap-vis query |
| `audit_events` | (all domain events filtered through audit projector) | `/admin/audit` queryable history |

Each projection is a module:

```elixir
defmodule Ezagent.Projection.UserCaps do
  use Commanded.Projections.Ecto,
    application: Ezagent.CommandedApp,
    name: "UserCapsProjection",
    consistency: :eventual  # opt to :strong for read-after-write LVs

  project %CapGrantedToUser{} = event, fn multi ->
    Ecto.Multi.insert(multi, :cap, %Ezagent.Projection.UserCap{
      user_uri: event.user_uri,
      cap_json: Jason.encode!(event.cap),
      granted_by: event.granted_by,
      granted_at: event.granted_at
    })
  end

  project %CapRevokedFromUser{} = event, fn multi ->
    Ecto.Multi.delete_all(multi,
      :cap,
      from(c in Ezagent.Projection.UserCap,
        where: c.user_uri == ^event.user_uri and c.cap_json == ^Jason.encode!(event.cap))
    )
  end

  def after_update(_event, _metadata, _changes) do
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, "ezagent:projections:user_caps", :updated)
    :ok
  end
end
```

### 5.2 Workspace scoping on projections

Every projection row that's workspace-scoped carries a `workspace_uri` column (same convention as current SQLite tables). `Ezagent.Persistence.scope_by_workspace/2` works against projections unchanged; the existing workspace-isolation invariant test is repointed at projection tables.

### 5.3 Cold-load handling

When LV mounts, it reads the projection (sync DB query). If the LV was just redirected-to from a dispatch site, the dispatch used `consistency: :strong` so the projection is caught up.

For cross-tab races (tab 1 dispatches, tab 2 mounts a stale LV before the projector catches up):
- The LV mount uses `Commanded.Subscriptions.wait_for/3` with the latest known aggregate version for that URI. If known, wait. If not known, accept eventual.
- The LV subscribes to the PubSub topic for the projection; the projector's `after_update/3` fires the subscriber; the LV re-renders.

The cold-load defense is the SAME as gift-card-demo: subscribe + re-fetch on update + initial render is best-effort. Worst case: ≤10ms stale window.

### 5.4 Strong vs eventual per projector

Default: `consistency: :eventual` for all projectors. Opt to `:strong` only for projectors that gate a dispatch site's immediate redirect (e.g. `user_profile` for `/admin/users/create` → redirect to `/admin/users/X` flow needs the new user in the profile projection).

Tradeoff: each `:strong` projector adds latency to every dispatch that flags `:strong` consistency. Default `:eventual` keeps the hot path fast.

---

## 6. Migration plan — phased

The migration runs as **Phase 10** in the IMPLEMENTATION_ROADMAP. Four sub-phases (10-A through 10-D), each gated by a /goal + per-phase invariant test.

### 6.0 Forward data migration — snapshot import (r2 — CRIT-1 fix)

**Codex r1 CRIT-1:** r1 said migrated Kinds "do NOT migrate existing snapshots; first command creates fresh event-sourced state." That drops live User/Session/Agent/Workspace state at cutover. UNACCEPTABLE per `feedback_destructive_migration_anti_pattern`.

**r2 fix — every Phase 10-A through 10-C runs Step 0 (snapshot import) BEFORE production dispatch is routed to the aggregate:**

Each Aggregate class defines a dedicated `%XSnapshotImported{}` event variant. The aggregate's `apply/2` has a clause for this event that hydrates the aggregate state from the snapshot payload. The event is emitted ONCE per existing URI by a `mix ezagent.aggregate.import --kind <kind>` task BEFORE the per-Phase cutover.

**Per-Kind import event:**

| Kind | Import event | Payload |
|---|---|---|
| User | `%UserSnapshotImported{}` | the full pre-existing slice (identity caps, user_credentials counter, user_tokens counter), plus the `users.password_hash`, `entity_profiles.*`, `entity_tokens.*` joined columns |
| Session | `%SessionSnapshotImported{}` | the full Chat slice + Publisher slice + ExternalMirror slice + members + ring state |
| Agent | `%AgentSnapshotImported{}` | the full per-flavor slice + lineage + api_keys |
| Workspace | `%WorkspaceSnapshotImported{}` | name, members, routing rules |
| ExternalMirrorWorker | `%WorkerSnapshotImported{}` | binding descriptor + cursor state |
| AgentTemplate | `%AgentTemplateSnapshotImported{}` | identity caps + template content |
| SessionTemplate | `%SessionTemplateSnapshotImported{}` | identity caps + template content |

**The import task:**

```
mix ezagent.aggregate.import \
  --kind user \
  --batch-size 100 \
  --dry-run    # default — print what would be imported, exit
```

When `--dry-run` is dropped:
1. For each row in `kind_snapshots` matching the Kind type, read the `state_binary`.
2. JOIN supplemental tables (`users.password_hash`, `entity_profiles.*`, `entity_tokens.*` for User; `messages` for Session-not-included — see below).
3. Build the `%XSnapshotImported{}` event payload.
4. Dispatch as the first event on the aggregate's stream (via `EventStore.append_to_stream/4`, NOT through the aggregate's `execute/2` — these are not commands, they are direct events the aggregate accepts at construction time).
5. Replay the aggregate; the `apply/2` clause hydrates state.

**`messages` table treatment for Session (r3 — schema-correct):** the existing `messages` SQLite table contains all historical messages. Importing every historical message as a `%MessagePosted{}` event would balloon the event store. **Decision:** the `%SessionSnapshotImported{}` event payload carries a `last_message_id` + `recent_messages` ring only (the durable Chat slice fields); the FULL message history stays in the SQLite `messages` table (which becomes a read-only archive). The projection table `session_messages_projection` holds new post-cutover messages.

**Permanent history query (r3 — actual schema column + join shape from `apps/ezagent_core/priv/repo/migrations/20260516070500_phase2_messages.exs:23` + `apps/ezagent_core/lib/ezagent/message_store.ex:174`):**

The schema column is `inserted_at` (NOT `created_at`); per-session history is a JOIN over `message_routings ⋈ messages` filtered by routing's `session_uri` + the message's `inserted_at` window. The post-migration query becomes an ordered UNION:

**r4 — workspace-scoped UNION SQL with DateTime cursor (HIGH-5 fix):**

Real per-session history join also requires `m.workspace_uri = $workspace_str` filter (per `message_store.ex:174`/`:201`/`:149`); ordering + cursor use `r.inserted_at`; pagination cursor is `DateTime`, not message id (per `message_store.ex:195`). Three parity-preserving SQL templates per existing `MessageStore.recent_in_session/3`, `older_than/3`, `in_session_since/3` signatures:

**recent_in_session(session_uri, workspace_str, n):**
```sql
SELECT * FROM (
  -- pre-cutover archive
  SELECT m.*, r.inserted_at AS routing_inserted_at FROM messages m
  JOIN message_routings r ON r.message_id = m.id
  WHERE r.session_uri = $session_uri AND m.workspace_uri = $workspace_str
    AND r.inserted_at < $cutover_at

  UNION ALL

  -- post-cutover projection (already includes workspace_uri column)
  SELECT *, inserted_at AS routing_inserted_at FROM session_messages_projection
  WHERE session_uri = $session_uri AND workspace_uri = $workspace_str
    AND inserted_at >= $cutover_at
) merged
ORDER BY routing_inserted_at DESC
LIMIT $n;
```

**older_than(session_uri, workspace_str, before_dt :: DateTime, limit):**
```sql
SELECT * FROM (
  SELECT m.*, r.inserted_at AS routing_inserted_at FROM messages m
  JOIN message_routings r ON r.message_id = m.id
  WHERE r.session_uri = $session_uri AND m.workspace_uri = $workspace_str
    AND r.inserted_at < $before_dt
  UNION ALL
  SELECT *, inserted_at AS routing_inserted_at FROM session_messages_projection
  WHERE session_uri = $session_uri AND workspace_uri = $workspace_str
    AND inserted_at < $before_dt
) merged
ORDER BY routing_inserted_at DESC
LIMIT $limit;
```

**in_session_since(session_uri, workspace_str, since_dt :: DateTime):**
```sql
SELECT * FROM (
  SELECT m.*, r.inserted_at AS routing_inserted_at FROM messages m
  JOIN message_routings r ON r.message_id = m.id
  WHERE r.session_uri = $session_uri AND m.workspace_uri = $workspace_str
    AND r.inserted_at >= $since_dt
  UNION ALL
  SELECT *, inserted_at AS routing_inserted_at FROM session_messages_projection
  WHERE session_uri = $session_uri AND workspace_uri = $workspace_str
    AND inserted_at >= $since_dt
) merged
ORDER BY routing_inserted_at ASC;
```

`Ezagent.MessageStore.list_for_session/1` (the current entry point) is rewritten to issue the appropriate UNION at post-migration. The `inserted_at` schema column naming is preserved; no rename. Workspace scoping is enforced in both halves of the UNION; `Ezagent.Persistence.scope_by_workspace/2` invariants extend to session_messages_projection naturally.

**Parity gates added in §6.0 import (r4 — corrected signatures):**
- `recent_in_session(session_uri, workspace_str, n)` — returns the same `n` rows pre/post (DateTime ordering preserved).
- `older_than(session_uri, workspace_str, before_dt)` — `DateTime` cursor, NOT msg_id. Identical pages.
- `in_session_since(session_uri, workspace_str, since_dt)` — DateTime window. Both halves.

Phase 10-D documents this UNION shape as the permanent shape; the `messages` table is NOT dropped.

**Parity gate (the cutover criterion, per `feedback_completion_requires_invariant_test`):**

```
mix ezagent.aggregate.verify --kind <kind>
```

Reads every URI's event-replayed aggregate state + compares field-by-field against the original `kind_snapshots.state_binary`. Asserts equality on every durable field enumerated in §4.2.*.

**r4 — per-Kind additional explicit-table parity asserts (HIGH-6):**

For Kinds whose durable state spans multiple SQLite tables (User), `verify --kind user` runs additional explicit per-table SELECTs:

```
# After kind_snapshots parity:
For every row in entity_profiles where workspace_uri = w:
  Assert exists in user_profile_projection with
    (uri, workspace_uri, display_name, email, registered_at) equal

For every row in entity_tokens where workspace_uri = w:
  Assert exists in user_tokens_projection with
    (uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, workspace_uri) equal

For Session: For every row in messages joined message_routings where workspace_uri = w:
  Assert UNION query in §6.0 returns the same row at the same position
```

Each per-Kind verify is documented in §6.2/6.3 deliverables. Any mismatch → import is incomplete; cutover is blocked.

**Cutover is the moment** the pre-dispatch pipeline routes Aggregate-targeted commands to `Commanded.Application.dispatch/2` instead of the legacy `Invocation.dispatch/1`. The cutover commits when the parity gate is green for all migrated URIs.

**Rollback BEFORE cutover:** trivial — drop the events from the aggregate's stream; the aggregate is fresh again. The original `kind_snapshots` data is untouched.

**Rollback AFTER cutover:** harder — events written post-cutover by production dispatches need to be replayed back into slice/snapshot via the §12 unwind path.

### 6.1 Phase 10-A — dependencies + skeleton + ExternalMirror slice + Worker (r3 — bind-spawn coupling boundary)

**Goal (r3 — HIGH-3 fix):** prove the integration. The ExternalMirror slice + Worker Kind migrate together because the bind→spawn coupling at `external_mirror.ex:394`/`:677` cannot be broken by migrating Worker alone. If 10-A fails, the whole migration aborts.

**Phase 10-A scope (r4 — HIGH-4 fix; split-brain protocol REMOVED):**

The r3 slice-split protocol was unsafe because bind→spawn→subscribe is one atomic-from-the-user's-perspective workflow that touches both the `:external_mirror` slice (binding row) and the `:publisher` subscription (worker's reverse-callback). Splitting the slices placed the binding row in an event stream while the publisher subscription still went through the legacy Session GenServer — the worker's subscribe call at `external_mirror_worker.ex:639` could race the binding event.

**r4 Phase 10-A scope (Option a — saga bridges via PubSub, Session stays fully legacy):**

- Session aggregate is NOT created in 10-A. Session stays fully a GenServer Kind (Chat + Publisher + ExternalMirror + OrchestratorAdmin slices).
- Worker IS migrated to `Ezagent.Aggregate.ExternalMirrorWorker` in 10-A.
- The bind → spawn → subscribe coupling is replaced by a `BootstrapWorkerSaga` that subscribes to the LEGACY Session's existing `:slice_change` PubSub topic (NOT to an event stream).
- When a legacy bind dispatches `Behavior.ExternalMirror.bind/4`, the Session GenServer writes the binding row + emits a `:slice_change` PubSub event (existing behavior). The saga listens to PubSub, observes the binding addition, and dispatches `%SpawnWorker{}` on the new Worker aggregate.
- The Worker aggregate's `BootstrapWorkerSaga` (saga internal) then dispatches `%SubscribeToSessionPublisher{}` — but this command, since Session is legacy, routes back through the bridge to call `Ezagent.Invocation.dispatch/1` against the legacy Session's `Behavior.Publisher.SessionImpl.subscribe_from/4`. No race; the legacy Session and the new Worker aggregate are coordinated through PubSub events (push) + the bridge (pull).
- Cutover for Worker is per §6.0: the import task replays `external_mirror_bindings` rows as `%WorkerSnapshotImported{}` events on the Worker aggregate's stream BEFORE turning on production dispatch.

**SessionRouter (r3) is REMOVED.** No per-Behavior routing within Session. Phase 10-A is exclusively Worker migration + bridge module.

**Bridge module (r4):** `Ezagent.MigrationBridge` in `apps/ezagent_commanded_app/`. Two directions:
- **Aggregate → Legacy:** when an aggregate-side command needs to dispatch to a legacy GenServer Kind (e.g. Worker saga calls Session's `subscribe_from`), the bridge translates the call into `Ezagent.Invocation.dispatch/1`. The bridge is deleted in Phase 10-D.
- **Legacy → Aggregate:** when legacy code emits a `:slice_change` PubSub event that the saga listens to, the saga internally converts to an aggregate command. No bridge code needed — saga IS the bridge for the read direction.

**Phase 10-A is NOT a "small" phase under this revision.** It bundles dependency/skeleton work, Worker migration, and the saga bridge. The "smallest Kind" framing is dropped. Estimated calendar time revised in §6.5.

**r2 CRIT-2 fix — Worker cannot migrate in isolation:** r1 had Phase 10-A migrate Worker only, but `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:394` + `:677` shows the legacy Session-side bind calls `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params)` DIRECTLY. No `BindingCreated` event is emitted while Session remains a GenServer Kind, so the `BootstrapWorkerSaga` would never fire. Two options:

**Option (a) — DEFAULT for r2: migrate Session ExternalMirror behavior + Worker together in Phase 10-A.** Worker is still the gating Kind (smallest, most isolated state); the Session `Behavior.ExternalMirror` actions (bind / unbind / list_bindings) become Session aggregate commands that emit `BindingCreated` / `BindingRemoved` events. This expands Phase 10-A scope but eliminates the heterogeneity gap. Session core (Chat / Publisher) stays GenServer-backed until Phase 10-B; only the ExternalMirror slice migrates in 10-A.

**Option (b) — fallback if (a) proves too entangled: ship `Ezagent.MigrationBridge.LegacyBind`** — a translation shim that wraps the legacy `Kind.spawn(Worker, params)` call and (i) constructs a `%SpawnWorker{}` command on the new aggregate AND (ii) synthesizes a `%BindingCreated{}` event into the new event stream so saga triggers fire. The bridge is deleted in Phase 10-D.

r2 commits to (a) unless impl PR-A1 codex review identifies a blocker.

**Deliverables (r2 — expanded):**
1. Add deps to root mix: `commanded ~> 1.4`, `eventstore ~> 1.4`, `commanded_eventstore_adapter ~> 1.4`, `commanded_ecto_projections ~> 1.3`, `postgrex ~> 0.19`.
2. Create new umbrella app `apps/ezagent_event_store` — config for `eventstore` lib (Postgres backend; dev uses local Postgres on port 5432, test uses in-memory adapter via Commanded's built-in test adapter).
3. Create new umbrella app `apps/ezagent_commanded_app` — `Ezagent.CommandedApp` module + the router + the pre-dispatch pipeline (§4.5).
4. Create new umbrella app `apps/ezagent_projections` — projection tables (Ecto repo against the existing SQLite for projection storage; events live in Postgres; the asymmetry is intentional — see §7.3).
5. **Step 0 — forward-migration import** (per §6.0) for Worker bindings + ExternalMirror slice on existing Sessions. Read `external_mirror_bindings` SQLite table; emit `%BindingSnapshotImported{}` events on Session aggregate stream; emit `%WorkerSnapshotImported{}` events on Worker aggregate stream. Parity gate green before cutover.
6. Migrate `Ezagent.ExternalMirror.Worker` to `Ezagent.Aggregate.ExternalMirrorWorker`.
   - Worker is the smallest Kind (117 LOC), the most isolated (its own domain app), and its in-process subscribers are bounded.
   - Existing `Ezagent.Entity.ExternalMirrorWorker` Kind module is REPLACED — not deprecated. Same URI shape; same callers (the BindingCreated saga that boot-spawns Workers is also added in this phase).
7. **Migrate `Behavior.ExternalMirror` actions on Session aggregate** (r2 CRIT-2 fix) — Session-aggregate-side commands `%BindExternalMirror{}` / `%UnbindExternalMirror{}` / `%ListBindings{}` (the last as a projection query, not a command). The Session aggregate gains an `external_mirror_bindings: []` field. The Session GenServer Kind is REMOVED from the ExternalMirror dispatch path for these 3 actions only; the rest of Session (Chat / Publisher / OrchestratorAdmin) stays GenServer-backed until Phase 10-B.
8. `BootstrapWorkerSaga` is implemented (replaces the boot reconciler scan).
9. `external_mirror_workers_projection` + `external_mirror_bindings_projection` are implemented.
10. Phoenix.Channel + LV that talk to Workers / ExternalMirror bind route through `Ezagent.CommandedApp.Dispatch`.

**Phase 10-A invariant test (the gate, per `feedback_completion_requires_invariant_test`):**
- `Worker aggregate state reconstructs deterministically from event stream alone` — test spins up an aggregate, dispatches N commands, stops the aggregate, restarts, asserts state equality.
- `BootstrapWorkerSaga resumes after BindingCreated event without rerunning the binding` — test plays a BindingCreated event, kills the saga process, replays, asserts no duplicate SpawnWorker dispatch.
- `Cross-Kind invocation from Worker → Session uses an event subscription, not direct GenServer.call` — grep test on the Worker code; no `Kind.get_slice/2` or `KindRegistry.lookup/1` for cross-Kind reads.

**Phase 10-A unwind (if failure):**
- Revert all deps in mix.exs.
- Delete the three new umbrella apps.
- Restore `Ezagent.Entity.ExternalMirrorWorker` from git.
- No data migration; the worker state was always derived from `external_mirror_bindings` rows (which never moved).

### 6.2 Phase 10-B — User + Session

**Pre-condition:** Phase 10-A merged + 1 week of soak in dev/staging.

**Goal:** the two most-used Kinds migrated. User: medium (240 LOC); Session: large (2272 LOC); both critical to every user-facing flow.

**Deliverables:**
- `Ezagent.Aggregate.User` + commands/events/projections (§4.2.1).
- `Ezagent.Aggregate.Session` + commands/events/projections (§4.2.3).
- Sagas: `CreateSessionSaga`, `DestroySessionSaga`, `DestroyUserSaga`, `CapGrantOwnershipVerifySaga`.
- All User + Session callsites migrated to the new Command-based API. Existing `EzagentDomainChat.create_session/3` becomes `EzagentDomainChat.create_session_command/3` returning `{:ok, cmd}` + a dispatch site OR is rewritten to dispatch directly.

**Phase 10-B invariant tests:**
- User caps reconstruct from event stream.
- Session messages reconstruct from event stream.
- `CreateSessionSaga` completes deterministically (no missing GrantOwnerOrchestratorAdminCap step).
- `DestroyUserSaga` compensates correctly on simulated step failure (the destroy_lifecycle 4-round failure resolved).

**Phase 10-B unwind:**
- More complex. User + Session aggregates have written events to the production event store. Unwind requires:
  1. Stop dispatch (new commands go to the GenServer-Kind code).
  2. Replay event stream → write back to slice/snapshot tables via a one-time `mix ezagent.unwind.user_session` task.
  3. Verify slice/snapshot state matches projection.
  4. Restore the GenServer Kind modules from git.
- Documented + reversible; the cost is the manual replay step.

### 6.3 Phase 10-C — Agent + Workspace

**Pre-condition:** Phase 10-B merged + 2 weeks soak.

**Goal:** the remaining Kinds. Agent: large (798 LOC) + per-flavor variants; Workspace: small but cross-cutting.

**Deliverables:**
- `Ezagent.Aggregate.Agent` + commands/events/projections (§4.2.2).
- `Ezagent.Aggregate.Workspace` + commands/events/projections (§4.2.4).
- Sagas: `DestroyAgentSaga` (the trigger SPEC #440), `DestroyWorkspaceSaga`, `CreateUserInWorkspaceSaga`, `BootstrapWorkerSaga` (refactored — was Phase 10-A but enriched here with Workspace context).
- All per-flavor agent code migrated. Flavor Behaviors (cc, codex, curl, np, echo) gain a Command + Event vocabulary.

**Phase 10-C invariant tests:**
- Agent lineage queries match aggregate state (no projection drift).
- `DestroyAgentSaga` completes the full 7-step cascade or compensates cleanly.
- `DestroyWorkspaceSaga` cascades through all child sessions/agents/users.

### 6.4 Phase 10-D — deprecate + cleanup

**Pre-condition:** Phases 10-A through 10-C merged + 1 month soak.

**Goal:** delete the old code.

**Deliverables:**
- Delete `Ezagent.Kind.Server`, `Ezagent.Kind.Snapshot`, `Ezagent.KindRegistry`, `Ezagent.SpawnRegistry`, `Ezagent.PendingDelivery`, `Ezagent.ReadyGate`.
- Delete `Ezagent.Invocation` (and all its callers).
- Delete the `kind_snapshots` SQLite table — **GATED**: see "Cleanup preflight gate" below.
- Delete `Ezagent.Audit.Writer` for domain-event paths; KEEP for telemetry paths.
- Delete `Ezagent.Behavior` (and all Behavior modules) — replaced by Command modules + per-Aggregate execute clauses.
- Update `IMPLEMENTATION_ROADMAP.md` §1.1 to mark Phase 10 complete + the new architectural baseline.
- Update `CLAUDE.md` skill `ezagent-developer` to point at the new dispatch / aggregate patterns.

**Cleanup preflight gate (r3 — MED-8 fix, hardened against flag spoofing):**

`DROP TABLE kind_snapshots` is destructive. The gate requires a *drill receipt* artifact, not just a flag.

**`mix ezagent.cleanup.drill`** (the only writer of receipts):
1. Operator runs `mix ezagent.cleanup.drill --backup-path /path/to/backup.sqlite --operator-email <ops@example>`.
2. Task computes `backup_sha256 = sha256(file)`, restores backup to a temp DB, counts rows in `kind_snapshots`, compares to live DB row count.
3. Task runs §6.0 parity gate (`mix ezagent.aggregate.verify`) against the *restored* temp DB; captures the parity report's SHA256.
4. Writes a signed JSON receipt at `priv/cleanup_receipts/<timestamp>.json` (r4 — MED-9: explicit `earliest_execute_at` cooldown + separate `expires_at` + execution_nonce):
   ```json
   {
     "backup_path": "...",
     "backup_sha256": "...",
     "live_row_count": 1234,
     "live_db_content_hash": "...",   // r4: SHA256 of the live DB's kind_snapshots table contents at drill time
     "restored_row_count": 1234,
     "parity_report_sha256": "...",
     "operator_email": "...",
     "drill_completed_at": "2026-05-28T14:00:00Z",
     "earliest_execute_at": "2026-05-29T14:00:00Z",  // r4: drill_completed_at + 24h cooldown (the real cooldown gate)
     "expires_at": "2026-06-04T14:00:00Z",            // r4: drill_completed_at + 7d (the receipt validity window)
     "execution_nonce": "<random uuid v4>",           // r4: written to audit_events row on execute
     "signature": "..."                               // HMAC over the above with deployment secret
   }
   ```
5. Receipt is committed to git for audit trail (the file path is in `.gitignore` exclusions for cleanup_receipts/).

**`mix ezagent.cleanup.execute --receipt <path-to-receipt-json>`** (the actual DROP, r4 — MED-9 hardened):
1. Checks `priv/cleanup_receipts/<timestamp>.consumed` does NOT exist. If it does → "receipt already consumed" → exit 1.
2. Reads receipt, verifies HMAC signature against deployment secret. Mismatch → exit 1.
3. Recomputes `backup_sha256` from `backup_path` in receipt → must equal stored SHA. Mismatch → exit 1.
4. Reads live DB `kind_snapshots` row count → must equal `live_row_count` AND content-hash must equal `live_db_content_hash`. Drift → exit 1 (live DB changed since drill, even if row count happens to coincide).
5. Reruns parity check on live DB → SHA must equal `parity_report_sha256`. Mismatch → exit 1.
6. Verifies `operator_email` is on `priv/cleanup_operators.allowlist` (committed file). Not on list → exit 1.
7. **r4 — real cooldown:** verifies `now >= earliest_execute_at` (cooldown elapsed) AND `now < expires_at` (receipt not stale). Either condition false → exit 1.
8. Only when ALL pass: prints "DROP TABLE kind_snapshots — final confirmation?" + reads operator interactive `y/N`; defaults `N`. Operator's `y` triggers the DROP.
9. **r4 — one-time consumption:** writes `priv/cleanup_receipts/<timestamp>.consumed` marker after a successful DROP. Replays see the marker (step 1) and fail.
10. **r4 — execution nonce audit:** writes an `audit_events` row with `event_type: "kind_snapshots_dropped"`, payload: `{execution_nonce, receipt_path, operator_email, executed_at}`. Forensic trail.

**The receipt cannot be forged.** Spoofing requires breaking the HMAC. Replaying an old receipt requires the live DB row count + parity SHA to still match (they won't, since events accumulate post-drill). Bypassing the allowlist requires git commit access (which the CI gate logs).

**Invariant test (r3 — MED-8):** CI runs `mix ezagent.cleanup.execute --receipt nonexistent.json` and asserts exit non-zero with "receipt not found". Also runs a synthesized invalid-signature receipt and asserts exit non-zero with "signature mismatch". The gate's resistance is itself tested.

**Phase 10-D invariant tests:**
- grep for `Ezagent.Kind.Server`, `Ezagent.Invocation`, `KindRegistry.lookup`, etc. across `apps/` is empty.
- All LVs read from projections; no `Kind.get_slice/2` calls anywhere.
- `mix ezagent.cleanup.preflight --table kind_snapshots` returns non-zero in CI (because no operator-approval flag is supplied) — this asserts the gate exists and refuses unconditional execution.
- The `NoBehaviorLeftBehindTest` from §4.1.5 returns green (every dispatchable Behavior has a Command mapping).

### 6.5 Estimated phase durations

| Phase | Estimated calendar time (1 developer + codex review) |
|---|---|
| 10-A | 2-3 weeks |
| 10-B | 4-5 weeks |
| 10-C | 4-5 weeks |
| 10-D | 1-2 weeks |
| **Total** | **~3 months** |

These are rough — they assume no major blockers and the patterns established in 10-A generalize. Allen's input needed on whether this aligns with current priorities (see §10 OQ-2).

---

## 7. Performance + ops cost analysis

### 7.1 Hot-path dispatch latency

| Operation | Current latency | New latency | Notes |
|---|---|---|---|
| Dispatch `:cast` to existing Kind | ~1ms (`GenServer.cast` + slice update + `:on_change` SQLite write) | ~5-50ms (event append to Postgres) | Postgres event append dominates; same order as SQLite `:on_change` today but slower per-op due to fsync semantics |
| Dispatch `:call` to existing Kind | ~5ms (`GenServer.call` + slice + write + reply) | ~10-60ms (event append + aggregate apply + reply) | Similar shape |
| Dispatch `:call` w/ `consistency: :strong` | n/a — current model is implicitly strong via GenServer serialization | ~15-80ms (event append + strong projector commit + reply) | The new "strong" mode is similar to current effective behavior |
| Cold aggregate replay (after restart) | n/a — Kind GenServer starts from latest snapshot | ~5-50ms (load snapshot + replay events since snapshot) | `snapshot_every: 50` bounds replay to ≤50 events |
| LV mount + initial read | ~1ms (Kind.get_slice sync call) | ~1-5ms (Postgres SELECT) | Roughly equivalent; SQLite local-disk is faster than Postgres networked but the gap is ~ms |
| LV update (projection-driven) | n/a (currently push-via-PubSub from Behavior) | ~10-20ms (projector commit + PubSub broadcast + LV re-render) | Similar to current — current also has the broadcast hop |

**Conclusion:** event-store-driven dispatch is **5-10x slower than current per-dispatch in the worst case** (50ms vs 5ms), but still well within human-perception bounds (<100ms). For batch workflows (CLI), this is acceptable; for real-time UI, it's seamless.

### 7.2 Aggregate snapshot frequency tuning

`snapshot_every: 50` events is the recommended default. Per-Aggregate override:

- **Session** — high event volume (1 event per message). `snapshot_every: 100` to amortize snapshot cost. Worst-case cold replay = 100 events × 50μs each = 5ms.
- **User** — low event volume. `snapshot_every: 20` is fine; replay cost is negligible.
- **Workspace** — very low volume. `snapshot_every: 10`.
- **Agent** — medium volume; `snapshot_every: 50` default.
- **Worker** — medium volume (per-cursor-advance event); `snapshot_every: 100`.

These are starting values; tune based on production telemetry post-launch.

### 7.3 Dev burden — Postgres in dev loop

The current dev loop uses SQLite (zero-config). Postgres requires:
- Running `postgres` locally (Docker: `docker run -p 5432:5432 postgres:16`, or homebrew: `brew install postgresql@16 && brew services start postgresql@16`).
- `mix event_store.create` + `mix event_store.init` at first-time setup.
- An additional repo for the event store schema (separate from the existing SQLite projections repo).

**Mitigations:**
- **Test mode uses in-memory adapter** — `Commanded.EventStore.Adapters.InMemory` runs in-process; no Postgres required for `mix test`. The test environment is unchanged from the dev's perspective.
- **`docker-compose.dev.yml`** ships a Postgres + adminer container; `mix ezagent.dev.up` brings it up. Onboarding cost: one Docker command at clone time.
- **Snapshot store also in Postgres** (Commanded's built-in `snapshotting` config) — no separate snapshot infra in dev.
- **Migration path documented in CONTRIBUTING.md** — first-PR-after-Phase-10-A devs read the new setup instructions; existing devs need to pull the docker-compose change.

**Trade-off acknowledged:** the zero-config dev experience is lost. Allen's input needed (§10 OQ-2).

### 7.4 Ops burden — Postgres backup, replication, PITR

Postgres ops is widespread; tooling is mature:
- **Backup**: `pg_dump` for full; WAL archiving for PITR.
- **Replication**: streaming replication; standby for failover.
- **PITR**: WAL-based; standard `recovery.conf`.

For ezagent's scale (single-tenant deployment per Allen's current ops model), a single Postgres node + nightly `pg_dump` + WAL archive is sufficient. Cloud-managed (RDS, Cloud SQL, Supabase) all work. No new ops skill required beyond "we now run Postgres in addition to SQLite for projections + telemetry".

**SQLite stays for:**
- Projections (the projection schema lives in SQLite for compatibility with all existing read paths).
- Telemetry audit (the `audit` table for non-domain events).
- Application config / templates / fixtures.

**Postgres handles only:**
- Event store (`eventstore` lib schema).
- Aggregate snapshots (Commanded's snapshot store, sharing the `eventstore` schema).

**Why split:** SQLite is unbeatable for low-latency local reads; Postgres's event-store schema is the only place a Postgres-only library is required. Splitting lets us keep SQLite for everything that doesn't NEED Postgres while paying the Postgres cost only for what does. Asymmetric, but pragmatic.

### 7.5 Disk footprint

Event store grows monotonically (events are append-only, never deleted). Estimate:
- Per event: ~200-1000 bytes JSON payload + ~100 bytes metadata.
- ezagent activity rate: very rough estimate ~1000-10,000 events/day in steady state.
- Daily disk growth: ~1MB-10MB/day; ~1GB/year worst case.

Event archival policy: snapshots make REPLAY fast regardless of stream length, so events don't need to be deleted for performance. They can be archived (move to cold storage) for cost; not required for years. §11 q#8 addresses query patterns over archived events.

---

## 8. Migration risks + rollback plan

### 8.1 Per-phase rollback

Each phase has explicit unwind documented in §6. Summary:

| Phase | Rollback complexity | Data risk |
|---|---|---|
| 10-A (Worker only) | Trivial — revert code; no data migration | None — Worker state always derived from `external_mirror_bindings`, which never moved |
| 10-B (User + Session) | Medium — manual event-replay → slice/snapshot via a `mix` task | Low — events exist in event store, can be replayed back to slice |
| 10-C (Agent + Workspace) | Medium — same as 10-B | Low — same |
| 10-D (cleanup) | Hard — old code is deleted; rollback means restoring from git + re-running 10-B/10-C unwind | Medium — but only triggered if every prior phase failed |

### 8.2 Hybrid-period heterogeneity risk

During Phases 10-A through 10-C, some Kinds are Aggregates and others are GenServers. How they interact:

- **Aggregate → GenServer Kind cross-Kind call:** A saga emits a Command that targets a GenServer Kind. The Command's "dispatch" routes through the OLD `Ezagent.Invocation.dispatch/1` path for that Kind. Bridge: in the pre-dispatch pipeline, if the command's target URI maps to a non-yet-migrated Kind, route through `Invocation.dispatch/1`. The bridge module is `Ezagent.MigrationBridge.dispatch_to_legacy/2`.
- **GenServer Kind → Aggregate cross-Kind call:** A `Behavior.invoke/4` calls into a migrated Kind. Bridge: the call constructs a Command and dispatches via the new pipeline. Equally explicit in the bridge module.

The bridge module is the SHIM that allows hybrid operation. It's intentionally narrow — exactly the two directions above. The bridge is deleted in Phase 10-D.

§11 q#5 enumerates this concern for codex review.

### 8.3 Event schema breakage during impl

If a Phase 10-B impl PR adds an event type and Phase 10-B v2 needs to rename a field, every historical event still has the old shape on disk. `Commanded.Event.Upcaster` handles this:

```elixir
defimpl Commanded.Event.Upcaster, for: MessagePosted do
  def upcast(%MessagePosted{content: c} = ev, _meta) when not is_nil(c) do
    %MessagePosted{ev | body: c, content: nil}
  end
  def upcast(%MessagePosted{} = ev, _meta), do: ev
end
```

The pattern is well-supported by Commanded ([hexdocs](https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html)). Each event schema change adds an upcaster impl; the historical event is read-only.

### 8.4 Production data loss risk

Per `feedback_destructive_migration_anti_pattern`:
- **No DROP / TRUNCATE on existing SQLite tables during migration.** New code reads from event-derived projections; old code reads from slice tables (during hybrid window). Both coexist.
- **Final cleanup (Phase 10-D) drops `kind_snapshots` only AFTER 1 month of clean operation post-10-C.**
- **Event store is append-only by construction** — events cannot be deleted accidentally without explicit operator action.

The risk is bounded: in the worst case (every phase fails), data is recoverable from the never-truncated SQLite tables. Phase 10-D is the only point of no return, and it gates on a 1-month soak.

---

## 9. Backwards compat / external API

### 9.1 What surface stays the same

- Phoenix.Channel topic names + message shapes — unchanged.
- HTTP endpoint paths + JSON shapes — unchanged.
- LiveView URLs + Assigns — unchanged from the user's perspective.
- CLI command names + flag shapes — unchanged.
- MCP tool schemas — unchanged.
- The `URI` addressing scheme — unchanged.
- Capability struct shape — unchanged.

### 9.2 What surface changes

- Plugin authors: instead of `@behaviour Ezagent.Kind` + `Ezagent.Behavior` modules, they write `@behaviour Commanded.Aggregates.Aggregate` + Command modules + Event modules + a per-Aggregate execute clause. The `ezagent-developer` skill is rewritten Phase 10-D.
- Domain context modules: `EzagentDomainChat.create_session/3` either becomes a thin wrapper that constructs `%CreateSession{}` and dispatches, OR is deleted and replaced by direct dispatch from the LV / channel. Decision per impl PR.
- Audit consumers: queries against the SQLite `invocations` table for domain events fail post-10-D — those queries must move to `audit_events_projection` OR to event-stream filters via `EventStore.read_stream_forward/4`. Migrated piecewise during 10-B / 10-C.

### 9.3 Plugin compatibility

Plugins outside the umbrella (if any future plugins existed at a separate git remote) would need to migrate their Kind definitions to Aggregates. Per `feedback_north_star_plugin_isolation`, the migration cost is bounded — plugins write commands + events + an aggregate; they do NOT touch the event store, the router, or the saga infrastructure (those live in `ezagent_commanded_app`).

The 3-tier rule from existing SPECs holds:
- **Tier 1 — core:** `apps/ezagent_core/`, `apps/ezagent_commanded_app/`, `apps/ezagent_event_store/`, `apps/ezagent_projections/`. Owns Commanded wiring.
- **Tier 2 — domain:** `apps/ezagent_domain_*/`. Owns aggregates + commands + events + projectors + sagas for their domain Kinds.
- **Tier 3 — plugin:** `apps/ezagent_plugin_*/`. Owns flavor-specific aggregate extensions (per-flavor commands + events + per-flavor execute clauses on the Agent aggregate).

Plugins cannot reach across to other plugins' aggregates; they go through events + sagas.

---

## 10. Open questions for Allen

### OQ-1. DB choice — Postgres for event store, SQLite for projections — accept?

Decision: yes (recommended). Alternatives:
- (a) **Migrate everything to Postgres** — drop SQLite entirely. Cleaner; one DB to manage. Cost: existing SQLite-based code (audit, fixtures, templates) must move; bigger disruption.
- (b) **Keep SQLite for everything except event store** — current recommendation (§7.4). Asymmetric but pragmatic.
- (c) **Find a SQLite event-store adapter** — no maintained one exists; would require building + maintaining a custom `Commanded.EventStore.Adapter` impl. High risk; not recommended.

### OQ-2. Migration calendar — 3 months acceptable, or do we phase it differently?

Allen's input needed. The phased plan is conservative (one Kind class per phase + 1-2 week soak). Acceleration options:
- (a) Phase 10-B and 10-C in parallel (riskier; two teams; we don't have two teams).
- (b) Run 10-A then jump directly to 10-D-equivalent for all Kinds (big bang; rejected per `feedback_destructive_migration_anti_pattern`).
- (c) Pause non-migration feature work during Phase 10-A through 10-C (Allen's call).

### OQ-3. Dev experience — Postgres in dev loop, acceptable burden?

Mitigations in §7.3. Allen's call on whether the docker-compose hop is acceptable for daily dev.

### OQ-4. Multi-tenant — does event sourcing change tenant-isolation concerns?

The current per-workspace isolation invariant (Phase 9 / SPEC v3 §7) ports forward: each domain event carries `workspace_uri`; projections enforce isolation in queries. The event stream itself is NOT workspace-partitioned by default — all events for all workspaces live in the same stream. This may be a concern for ops (a workspace cannot be "deleted from the event log" without a full dump-filter-restore cycle).

Alternative: one event stream per workspace. Commanded supports per-stream subscriptions naturally; multi-stream aggregates require care. §11 q#6.

### OQ-5. Mid-migration interop — bridge module placement

Phase 10-A through 10-C has the bridge module `Ezagent.MigrationBridge`. Should it live in `apps/ezagent_core/` (Tier 1) or `apps/ezagent_commanded_app/` (also Tier 1)? Probably the latter — the bridge is migration-specific scaffolding, not a permanent feature. Allen agrees?

### OQ-6. Sagas — should they be supervised inside `Ezagent.CommandedApp` or in a sibling supervisor?

Commanded supports both. In-app is simpler (single supervisor tree); sibling is more isolated. Default recommendation: in-app for Phase 10-A; reconsider if saga count grows past ~20.

### OQ-7. Presence — keep slice-based or move to `Phoenix.Presence`?

Per §4.3, Presence is not migrated to event sourcing (it's transient runtime state). Two options:
- (a) Keep as a `Ezagent.Presence` GenServer + slice (current).
- (b) Migrate to `Phoenix.Presence` natively (better-tested; CRDT-backed; clustering-ready).

Independent decision from this SPEC; flag here.

### OQ-8. Audit retention — when do we archive old events?

EventStore grows monotonically (§7.5). At ~1GB/year, archival is not pressing for years. When do we want a policy?

---

## 11. Codex adv-review questions

Pre-loaded attack vectors for codex round 1:

1. **Phoenix + Commanded integration maturity — is there a production reference at comparable scale, or are we pioneering?** §3.6 enumerates Conduit, Gift-card-demo, Segment Challenge, Honeydew, Casavo. None is at "thousands of aggregate types"-scale. Verdict: the pattern is established; ezagent's scale is well within precedent.

2. **Read-after-write consistency for LV — when user dispatches a command and LV re-renders, will it see the updated state? Is `:strong` mode the right answer or does it block command return until projection catches up?** §3.3 explains the three modes; the recommendation is default `:eventual` with opt-in `:strong` per dispatch site. The blocking is exactly what we want for the "wizard → redirect → detail page" pattern. Codex: validate that our specific LV → dispatch → re-render flows all have an opt-in path documented.

3. **Saga partial-failure: destroy cascade has 7 steps; if step 4 fails, how does the Saga compensate? Are there published compensation patterns?** §3.8 shows the destroy saga with `error/3` callback. Compensation in Commanded sagas is explicit (no auto-rollback); the saga code MUST encode compensation. Codex: validate the destroy saga's compensation logic is complete (does step 4 failure require undoing steps 1-3 or just retrying step 4? — depends on idempotency of each).

4. **Postgres vs SQLite — ezagent uses SQLite; can we feasibly support both, or must we migrate fully?** §7.4 + OQ-1: the recommendation is split (Postgres for event store + snapshots; SQLite for projections + audit + everything else). Asymmetric but works. Codex: validate that the asymmetry doesn't create cross-DB query problems (it shouldn't — projections + event store don't share queries; they share only the projection update operation, which is an Ecto.Multi within the projection's own SQLite repo).

5. **Heterogeneous migration — Phase 10-A through 10-C has some Kinds as Aggregates and some as GenServers. How do cross-Kind workflows work in this mixed mode?** §8.2 + the `Ezagent.MigrationBridge` module. Codex: validate that the bridge module handles both directions (Aggregate → GenServer + GenServer → Aggregate) AND that the bridge deletion in Phase 10-D doesn't strand any callers.

6. **Event schema evolution — adding new fields to existing event types, handling old events on replay.** §8.3 + Commanded's `Event.Upcaster` pattern. Codex: validate the Upcaster impl path for each anticipated schema change in Phase 10-B/10-C (we have at least 5 known evolutions queued from the destroy SPEC).

7. **Performance: worst-case event-stream replay time for an aggregate with N events. Hot Aggregates may have 10K+ events.** §7.2 + snapshot_every: 50-100. Codex: validate that 50 events × 50μs = 2.5ms cold-start is acceptable for our LV mount budget (it is).

8. **Audit query: today's `invocations` table is queryable via SQL. With EventStore, ad-hoc audit queries require event-stream scan or projection. Define audit query patterns.** §4.7. Codex: validate that the `audit_events_projection` schema can satisfy the existing `/admin/audit` LV's filter predicates (workspace_uri, caller, time range, action type). If a query exists today that the projection can't satisfy, document it as a Phase 10-B impl-blocker.

---

## 12. Rollback plan — overall abort path

If, after Phase 10-A merges + 10-B / 10-C in progress, Allen decides the migration is not working:

1. **Stop new dispatch.** Set a feature flag in the pre-dispatch pipeline that routes all commands through the legacy `Ezagent.Invocation.dispatch/1` path. New dispatches stop emitting events; Aggregates stop receiving commands.
2. **Replay events back to slice/snapshot.** For each migrated Aggregate, a `mix ezagent.aggregate.unwind --uri <uri>` task reads the event stream + writes equivalent slice state into `kind_snapshots`. The replay is deterministic (Aggregate's `apply/2` IS the projection from event to state).
3. **Verify parity.** A `mix ezagent.aggregate.verify` task asserts that for every migrated URI, the slice-snapshot state equals the event-replayed Aggregate state. If parity fails, the unwind aborts at this point (data is preserved in the event store + the SQLite snapshot — operator inspects).
4. **Restore GenServer Kind code.** From git: revert the per-Phase code that replaced `Ezagent.Entity.X` with `Ezagent.Aggregate.X`. The legacy `Kind.Server` boots from the (now-replayed) snapshot.
5. **Keep the event store data.** Even on abort, the events are preserved. A future re-attempt at migration starts from the same event store.

The unwind is documented + automated per Aggregate. Cost: an operator-driven session (estimated 1-2 hours for the full unwind across all 5 Aggregate classes given the projections are already shaped for the inverse direction).

---

## Appendix A — Event-store schema (Postgres)

Standard `eventstore` library schema; documented at https://hexdocs.pm/eventstore/EventStore.html. Tables:

- `event_store.events` — append-only event log.
- `event_store.streams` — per-stream metadata (one stream per Aggregate UUID = canonical URI string).
- `event_store.subscriptions` — projector + saga subscription state (replayed events position).
- `event_store.snapshots` — aggregate snapshots (Commanded-managed).

No custom schema required for Phase 10-A; per-projection tables live in the SQLite projections repo (§4 + §5).

## Appendix B — Sample command + event + aggregate execute clause

```elixir
# Command
defmodule Ezagent.Aggregate.User.Commands.GrantCapToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :idempotency_key]
end

# Event
defmodule Ezagent.Aggregate.User.Events.CapGrantedToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :granted_at]
end

# Aggregate execute clause
defmodule Ezagent.Aggregate.User do
  alias Ezagent.Aggregate.User.Commands.{GrantCapToUser, ...}
  alias Ezagent.Aggregate.User.Events.{CapGrantedToUser, ...}

  @behaviour Commanded.Aggregates.Aggregate

  defstruct [:uri, :workspace_uri, :registered_at, caps: MapSet.new(), destroyed?: false]

  # GrantCapToUser → CapGrantedToUser
  def execute(%__MODULE__{destroyed?: true}, %GrantCapToUser{}),
    do: {:error, :user_destroyed}

  def execute(%__MODULE__{uri: nil}, %GrantCapToUser{}),
    do: {:error, :user_not_registered}

  def execute(%__MODULE__{} = state, %GrantCapToUser{} = cmd) do
    %CapGrantedToUser{
      user_uri: cmd.user_uri,
      workspace_uri: cmd.workspace_uri,
      cap: cmd.cap,
      granted_by: cmd.granted_by,
      granted_at: DateTime.utc_now()
    }
  end

  # apply — state mutation
  def apply(%__MODULE__{} = state, %CapGrantedToUser{} = ev),
    do: %{state | caps: MapSet.put(state.caps, ev.cap)}

  # ... other commands/events/apply clauses ...
end

# Router clause
defmodule Ezagent.CommandedApp.Router do
  use Commanded.Commands.Router

  identify(Ezagent.Aggregate.User, by: :user_uri)
  dispatch([
    Ezagent.Aggregate.User.Commands.GrantCapToUser,
    Ezagent.Aggregate.User.Commands.RevokeCapFromUser,
    ...
  ], to: Ezagent.Aggregate.User)
end

# Dispatch site (e.g. in EzagentDomainIdentity.Users)
def grant_cap(user_uri, cap, granted_by, caller_caps) do
  cmd = %GrantCapToUser{
    user_uri: URI.to_string(Ezagent.URI.parse!(user_uri)),
    workspace_uri: Ezagent.URI.entity_workspace_uri_string(user_uri),
    cap: cap,
    granted_by: granted_by,
    idempotency_key: UUID.uuid4()
  }
  Ezagent.CommandedApp.Dispatch.dispatch(cmd,
    caller: granted_by,
    caps: caller_caps,
    consistency: :strong
  )
end
```

## Appendix D — Projection→Facade coverage map (r4 — HIGH-3)

Used by `Ezagent.Invariants.LVConsistencyTest` to verify that LV write→read combinations have a facade declaring `@consistency :strong` covering the projection.

| Projection module | Source facades (emit events updating this projection) |
|---|---|
| `Ezagent.Projection.UserProfile` | `Ezagent.Users.create/3`, `Ezagent.Users.set_password/2`, `EzagentDomainIdentity.UserCredentials.rotate/2`, `Ezagent.Entity.Profile.upsert/1` |
| `Ezagent.Projection.UserCaps` | `EzagentDomainIdentity.grant_cap/3`, `EzagentDomainIdentity.revoke_cap/3`, `Ezagent.Workspace.add_member/2` (default-grant), `Ezagent.Workspace.remove_member/2` (cascade revoke) |
| `Ezagent.Projection.UserTokens` | `Ezagent.Users.Token.mint/2`, `Ezagent.Users.Token.revoke/2`, `EzagentDomainIdentity.UserTokens.mark_used/2` |
| `Ezagent.Projection.AgentProfile` | `EzagentDomainChat.create_agent/4`, `EzagentDomainChat.destroy_agent/2`, plugin-flavor facade `Ezagent.PluginCc.spawn_agent/3` |
| `Ezagent.Projection.AgentCaps` | `EzagentDomainIdentity.grant_cap/3` (agent target), `EzagentDomainIdentity.revoke_cap/3` (agent target) |
| `Ezagent.Projection.AgentLineage` | `EzagentDomainChat.create_agent/4` (parent_uri set), `EzagentDomainChat.destroy_agent/2` |
| `Ezagent.Projection.AgentApiKeys` | `EzagentDomainIdentity.ApiKeys.put/3`, `EzagentDomainIdentity.ApiKeys.delete/2` |
| `Ezagent.Projection.SessionProfile` | `EzagentDomainChat.create_session/3`, `EzagentDomainChat.destroy_session/2`, `EzagentDomainChat.transfer_ownership/3` |
| `Ezagent.Projection.SessionMembers` | `Behavior.Chat.invoke(:join, ...)`, `Behavior.Chat.invoke(:leave, ...)` |
| `Ezagent.Projection.SessionMessages` | `Behavior.Chat.invoke(:send, ...)` (after Phase 10-B); pre-cutover messages remain in `messages` table (archive) |
| `Ezagent.Projection.ExternalMirrorBindings` | `Behavior.ExternalMirror.invoke(:bind, ...)`, `:unbind`, `EzagentPluginFeishu.bind/2`, `EzagentPluginFeishu.unbind/2` |
| `Ezagent.Projection.ExternalMirrorWorkers` | saga-emitted `%SpawnWorker{}`, `%TerminateWorker{}`, `%AdvanceWorkerCursor{}` |
| `Ezagent.Projection.Workspaces` | `Ezagent.Workspace.create/2`, `Ezagent.Workspace.destroy/1` |
| `Ezagent.Projection.WorkspaceMembers` | `Ezagent.Workspace.add_member/2`, `Ezagent.Workspace.remove_member/2` |
| `Ezagent.Projection.AgentTemplateProfile` | `EzagentDomainChat.create_agent_template/3`, `Behavior.Template.invoke(:write, ...)`, `:instantiate` |
| `Ezagent.Projection.SessionTemplateProfile` | `EzagentDomainChat.save_template_as/3`, `EzagentDomainChat.update_template/3`, `:fork` |
| `Ezagent.Projection.AuditEvents` | (all domain events; updated by AuditProjector subscribing to `$all` stream) |

Each facade in this table MUST carry an `@consistency` module attribute (Gate 1 §4.8). The LV invariant uses this map to validate that LV re-reads after facade calls have the right consistency mode.

## Appendix C — Reference URLs

- Commanded: https://github.com/commanded/commanded · https://hexdocs.pm/commanded
- EventStore (lib): https://github.com/commanded/eventstore · https://hexdocs.pm/eventstore
- commanded_eventstore_adapter: https://hex.pm/packages/commanded_eventstore_adapter
- commanded_ecto_projections: https://hex.pm/packages/commanded_ecto_projections · https://hexdocs.pm/commanded_ecto_projections
- Awesome-Elixir-CQRS (project list): https://github.com/slashdotdash/awesome-elixir-cqrs
- Conduit reference app: https://github.com/slashdotdash/conduit
- Gift-card-demo: https://github.com/slashdotdash/gift-card-demo
- Segment Challenge: https://github.com/slashdotdash/segment-challenge
- Honeydew CELP starter: https://github.com/quarterpi/honeydew
- Casavo Phoenix LiveView + ES tools: https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99
- "Phoenix LiveView but event-sourced" (cantido): https://dev.to/cantido/phoenix-liveview-but-event-sourced-7pe
- Christian Alexander Phoenix API + Commanded: https://christianalexander.com/2022/05/09/elixir-commanded/
- ElixirMerge ES/CQRS guide: https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview
- Commanded process managers / sagas: https://hexdocs.pm/commanded/process-managers.html
- Commanded read-model projections: https://hexdocs.pm/commanded/Read%20Model%20Projections.md
- Commanded event upcasting: https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html
- Saga pattern in Elixir (Peter Ullrich): https://peterullrich.com/saga-pattern-in-elixir
