# PLAN — comms-unify PR-1 + PR-2 (adapter substrate)

**Status:** PLAN (implementation-ready). Read-only basis; no code changed by this plan.
**Owner-to-execute:** codex (self-drives PR-1 then PR-2 on one branch; lead/Claude verify + merge).
**SPEC (contract):** `docs/together/2026-06-27/specs/unify-comms-on-adapter-substrate.md`
(branch `docs/unify-comms-spec`; codex review verdict SOUND-WITH-FIXES, fixes folded).
**Skills:** `ezagent-developer` + `ezagent-socialware` + `elixir-phoenix-helper`.
**Read against:** `origin/main` (37b71aae) and `origin/refactor/retire-customer` (post-#1037 external surface).
**Base branch for BOTH PRs:** `main`. **VERIFIED:** #1037 is MERGED to main —
`ExternalFeed` EXISTS on main, `CustomerFeed` is GONE, both `chat_feed_channel`
and `external_feed_channel` are present on main. So PR-2's delegation to
`ExternalFeed.snapshot/2|join/3|replay/3` is valid against `main` (the SPEC §2
two-column "main vs retire" framing describes the pre/post-#1037 HISTORY, not
main-vs-branch).

---

## 0. Scope of THIS plan vs the SPEC's §10 numbering — READ FIRST

The SPEC §10 sequences five PRs. **The lead has re-carved the work into a tighter
two-PR unit. The SPEC §10 numbering is SUPERSEDED by this plan's mapping.** Do
not follow §10's PR numbers.

| THIS plan | = SPEC sections | NOT included |
|---|---|---|
| **PR-1** (contract + generic channel/socket, additive) | §3.2 (extend `:pull` Adapter contract + registry enforcement) **and** §5 (collapse → ONE `SessionFeedChannel`/`SessionFeedSocket`) | **NOT** AnonIngress (§7) |
| **PR-2** (adapter revival + boot registration + cutover) | §6 (`ExternalFeedAdapter` + register both adapters at boot; channel resolves adapters from `AdapterRegistry`) | — |

**Explicitly OUT of this handoff (do NOT touch — they are PR-3/PR-4):**
- **AnonIngress** (SPEC §7 / §10 PR-3): the shared anon-lifecycle web helper. PR-1's
  `SessionFeedSocket` resolves the caller by **lifting the EXISTING per-surface
  socket `connect/3` logic inline** (signed-in member OR existing anon mint/cookie),
  accepting temporary duplication across the two old sockets. **Do NOT build
  AnonIngress.** SPEC §5 says the socket resolves caller "via AnonIngress (§7)" —
  that wiring is a LATER PR; here you inline the lift.
- **world / `WorldLive`** convergence (SPEC §9 / §10 PR-4).
- The §9.2 **E3-for-world** and **E4-AnonIngress-dedup** elimination clauses (PR-2's
  gate is scoped to E1 + E2 + E5 + both-disciplines-intact only; see Task 2.6).

**Sprawl boundary:** if any task seems to require AnonIngress, world, a new app
`in_umbrella` dep, or touching hello's write path — **STOP and report**, do not
expand scope.

---

## 1. Load-bearing constraints (encode in every task)

### C1 — The dep-DAG rule (only ABSTRACT signatures go low)
`ezagent_domain_external_mirror` deps ONLY on `{core, identity}`. The concrete
live-delivery helper needs the settlement outbox
(`Ezagent.Socialware.DeliveryOutbox` / `ExternalFeed.committed_deliveries_since/2`)
and the external-delivery topic builder (`Ezagent.Session.ExternalDelivery.topic/1`)
— **both in `ezagent_domain_session`**. `external_mirror` **cannot** dep on
`session` (session deps UP onto external_mirror — the reverse edge is a Mix
deps-cycle, documented verbatim in `external_mirror/mix.exs`). Therefore:

- **In `external_mirror`:** ONLY the abstract callback *signatures* (they reference
  ONLY `URI.t()` / `integer()` / `map()` / atoms — no session/socialware module).
- **In `socialware` (which already deps on session + external_mirror + core):** the
  concrete cursor reads, topic strings, outbox calls — the adapter impls.

A PR-1 unit test (Task 1.5) greps the behaviour module + asserts NO
session/socialware alias appears in it — the legality gate the SPEC §8/§12-MED demands.

### C2 — Both delivery disciplines preserved (zero loss of either)
Two disciplines are correct, each for its surface:
- **chat = `:snapshot_refresh`** — NO cursor in `socket.assigns`; re-read current
  latest-N (`ChatFeed.snapshot/2` → `MessageStore.chat_visible_recent/2`) on ANY
  advisory. Self-healing latest-N (the keyset cursor chat deliberately DELETED stays deleted).
- **external = `:cursor_replay`** — durable settlement outbox, `committed_seq`
  lower-bound cursor captured BEFORE the content read, idempotent replay. ZERO-LOSS guaranteed.

The generic channel branches on `adapter.delivery_discipline/0`. The two branch
bodies are the VERBATIM protocol of the two current channels — a behavioral
superset, not an averaging merge. **No shared field couples the two** (the cursor
assign exists only on the `:cursor_replay` branch).

### C3 — `render_authorized/2` is result-bearing, fail-closed (the codex HIGH fix)
The existing `render/2` returns a bare `map()`. The live re-authorize-on-read path
needs to distinguish a denied/ex-member read. `render_authorized/2` returns
`{:ok, snapshot}` on grant and `{:error, :unauthorized}` on LIVE revocation; the
generic channel pushes `"unauthorized"` + `{:stop, :shutdown}` (fail-closed at the
transport). Bare `render/2` is RETAINED for back-compat callers.

### C4 — Subscribe-FIRST invariant (both disciplines)
On join the channel subscribes to `adapter.live_topics(session_uri)` BEFORE the
first content read. Every PubSub message is treated as an advisory WAKE-UP, never
as payload. The guarantee is no committed-STATE loss (not guaranteed-immediate push).

### C5 — Per-PR green-ness (additive-first; deletion only in PR-2)
**Every PR ends green** (full precommit + arch gates). PR-1 is purely ADDITIVE:
it builds the new channel/socket + contract, tested against TEST `:pull` fixtures,
and **does NOT delete or re-route the two old channels** (deleting them in PR-1
would leave chat+external resolving from an empty registry → red). PR-2 registers
the real adapters at boot, flips the routes, then DELETES the old channels and
runs the scoped elimination gate.

### C6 — Registry back-compat (decided)
`delivery_discipline/0` defaults to `:snapshot_refresh`; `participation_profile/0`
defaults to `:read_only` (resolved via `function_exported?/3`). The new `:pull`
required-callback rule (Task 1.2) makes `render_authorized/2` + `live_topics/1` +
`participation_profile/0` REQUIRED for `:pull`; for `:cursor_replay`,
`join_with_cursor/2` + `replay/3` REQUIRED and ABSENT for `:snapshot_refresh`.
The ONLY existing `:pull` adapter that registers is the TEST fixture
`Ezagent.ExternalMirror.TestSupport.PullAdapter` (chat+external are not registered
on main). **PR-1 migrates that fixture** to the new contract (Task 1.4) so strict
enforcement + migrated-fixture is the clean path; no production `:pull` adapter is
broken because none registers until PR-2 (which adds the real ones already
conforming).

---

## 2. Anchored facts (verified against real source — do not re-derive)

- `external_mirror/.../adapter.ex`: `@callback render(session_uri :: URI.t(), ctx :: map()) :: map()`
  (bare map); `kind_of/1` resolves `adapter_kind/0` defaulting `:push`;
  `@optional_callbacks` already lists `adapter_kind: 0, render: 2, …`.
- `external_mirror/.../adapter_registry.ex`: `assert_required_callbacks!/1` builds
  `required = [adapter_id, display_name, description, cap_subject] ++ kind_specific_required(kind_of(mod))`;
  `kind_specific_required(:pull) -> [render: 2]`. This is the function PR-1 extends.
- `socialware/.../chat_feed_adapter.ex`: `ChatFeedAdapter` (`adapter_id "chat_feed"`)
  + `ChatFeedAdapter.Allow` (cap `allow_chat_feed`, `dispatchable?: false`); `render/2`
  delegates `ChatFeed.snapshot/2`. Declared-but-registered-by-nobody on main.
- `socialware/.../external_feed.ex` (retire branch): `ExternalFeed.snapshot/2`,
  `.history/2`, `.committed_deliveries_since/2`, `.join/3` (lower-bound cursor
  protocol → `{:ok, %{snapshot, deliveries, cursor}}`), `.topic/1` → `ExternalDelivery.topic/1`.
  NO `ExternalFeedAdapter` exists (deleted by #1037).
- `web/.../socialware/chat_feed_channel.ex`: route `socialware:chat_feed:*`, read-only,
  subscribes `Delivery.session_events_topic`, `handle_info` re-reads snapshot.
- `web/.../socialware/external_feed_channel.ex` (retire branch): route `socialware:external:*`,
  subscribes `{:external_delivery}` topic AND session_events_topic; `handle_in "join"/"post"/"history"`;
  `handle_info {:external_delivery,…}` + generic event → replay.
- `web/.../endpoint.ex`: `socket "/socialware_external_socket", …ExternalFeedSocket`
  and `socket "/socialware_chat_socket", …ChatFeedSocket`. Sockets carry
  `channel "socialware:chat_feed:*"` / `"socialware:external:*"` + `connect/3`
  (token + caller resolution).
- `external_mirror/test/support/test_adapters.ex`: `TestSupport.PullAdapter`
  (`adapter_kind :pull`, `render/2 -> %{kind: "pull-render"}`) + `.PullAdapter.Allow`
  — the only registering `:pull` adapter; PR-1 migrates it.

---

## PR-1 — Contract extension + generic channel/socket (ADDITIVE)

**Goal:** extend the `:pull` Adapter behaviour with the live-delivery callbacks
(§3.2) + registry discipline enforcement, and build ONE `SessionFeedChannel` +
`SessionFeedSocket` that branch on the contract — proven against TEST fixtures.
**No old channel deleted or re-routed.** End state: precommit + arch gates green,
old chat/external channels still live and unchanged.

> TDD per task: write the failing test → run it red → implement → run it green →
> commit. Each task is one logical commit.

### Task 1.1 — Add the live-delivery callback signatures to the Adapter behaviour
- **Modify:** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex`
- **Produces:** `@type delivery_discipline :: :snapshot_refresh | :cursor_replay`;
  `@type participation_profile :: :read_only | :participatory`; callbacks
  `delivery_discipline/0`, `render_authorized/2`
  (`{:ok, map()} | {:error, :unauthorized | term()}`), `live_topics/1` (`[String.t()]`),
  `join_with_cursor/2` (`{:ok, %{snapshot: map(), cursor: integer()}} | {:error, term()}`),
  `replay/3` (same ok-shape), `participation_profile/0`. Add all six to
  `@optional_callbacks`. Add resolver helpers mirroring `kind_of/1`:
  `delivery_discipline_of/1` (default `:snapshot_refresh`),
  `participation_profile_of/1` (default `:read_only`) via `function_exported?/3`.
- **Consumes:** only `URI.t()` / `integer()` / `map()` / atoms (C1 legality).
- **Test (`adapter_test.exs`, new cases):** the resolver helpers return the
  declared value when exported, the back-compat default otherwise.
- **Steps:** red (helper undefined) → add types/callbacks/resolvers → green → commit.

### Task 1.2 — Extend registry `:pull` discipline enforcement
- **Modify:** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex`
  (`kind_specific_required/1` for `:pull`; do NOT rewrite `:push`/`:request_scoped`).
- **Produces:** `:pull` required set now = base + `[live_topics: 1, participation_profile: 0]`
  + discipline-conditional via `delivery_discipline_of/1`:
  - `:snapshot_refresh` → `render_authorized: 2` REQUIRED; `join_with_cursor`/`replay` MUST be ABSENT (raise if present).
  - `:cursor_replay` → `join_with_cursor: 2` + `replay: 3` REQUIRED.
  Keep the existing `assert_no_binding_for_pull!` invariant intact.
- **Test (`adapter_registry_test.exs`, new cases):**
  - registry ACCEPTS a `:cursor_replay` `:pull` adapter declaring `join_with_cursor`/`replay`/`live_topics`/`participation_profile`.
  - registry REJECTS a `:snapshot_refresh` `:pull` adapter that declares `join_with_cursor` (mutual-exclusion).
  - registry REJECTS a `:pull` adapter missing `live_topics`/`participation_profile`.
  - existing `:push`/`:request_scoped` accept/reject cases UNCHANGED (regression).
- **Steps:** red → extend `kind_specific_required(:pull)` + conditional raise → green → commit.

### Task 1.3 — New test fixtures for the two disciplines (note the cross-app split)
- **Modify:** `apps/ezagent_domain_external_mirror/test/support/test_adapters.ex`
  for the REGISTRY tests (Task 1.2, same app).
- **CROSS-APP CAVEAT:** in an umbrella each app compiles its OWN `test/support`
  under that app's `elixirc_paths`; `ezagent_web`'s test env does NOT compile
  `Ezagent.ExternalMirror.TestSupport.*`. So the CHANNEL test (Task 1.6, in
  `ezagent_web`) CANNOT see the external_mirror fixtures. **Define the channel-test
  discipline fixtures separately in `apps/ezagent_web/test/support/`** (e.g.
  `EzagentWeb.TestSupport.SnapshotPullAdapter` / `.CursorPullAdapter`).
- **Produces (external_mirror, for 1.2):** `TestSupport.SnapshotPullAdapter` (`:pull`
  + `:snapshot_refresh` + `:read_only`, `render_authorized/2`, `live_topics/1`) and
  `TestSupport.CursorPullAdapter` (`:pull` + `:cursor_replay` + `:participatory`,
  `join_with_cursor/2`, `replay/3`, `live_topics/1`) — pure, no session refs.
  **Produces (ezagent_web, for 1.6):** the analogous two fixtures in
  `ezagent_web/test/support`.
- **Test:** consumed by 1.2 (external_mirror fixtures) + 1.6 (web fixtures).
- **Steps:** add fixtures (external_mirror set alongside the 1.4 migration; web set with 1.6).

### Task 1.4 — Migrate the existing `PullAdapter` fixture to the new contract
- **Modify:** `apps/ezagent_domain_external_mirror/test/support/test_adapters.ex`
  (`TestSupport.PullAdapter`).
- **Produces:** `PullAdapter` gains `delivery_discipline/0` (`:snapshot_refresh`),
  `participation_profile/0` (`:read_only`), `render_authorized/2`, `live_topics/1`
  so it still registers under the strict rule (C6). (Or assert it registers via
  the back-compat defaults if you keep it minimal — but it must satisfy the
  `:snapshot_refresh` → `render_authorized` REQUIRED rule.)
- **Test:** the existing `:pull` registration test stays green.
- **Steps:** red (strict rule breaks old fixture) → migrate fixture → green → commit
  (can fold with 1.3).

### Task 1.5 — Behaviour-legality grep gate (C1 / SPEC §12-MED)
- **Create:** `apps/ezagent_domain_external_mirror/test/ezagent/external_mirror/adapter_behaviour_legality_test.exs`
- **Produces:** a test that reads `adapter.ex` source and asserts it contains NO
  `Ezagent.Session` / `Ezagent.Socialware` alias or reference (the abstract-only
  invariant — prevents a future edit from sneaking a concrete dep low and creating
  the Mix cycle).
- **Steps:** write test (green immediately if Task 1.1 kept signatures pure) → commit.

### Task 1.6 — `SessionFeedChannel` (generic, additive — NOT routed yet)
- **Create:** `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_channel.ex`
- **Consumes:** `ExternalMirror.AdapterRegistry.lookup/1`, `Adapter.delivery_discipline_of/1`,
  `Adapter.participation_profile_of/1`, `render_authorized/2`, `live_topics/1`,
  `join_with_cursor/2`, `replay/3`; `Phoenix.PubSub`.
- **Produces:** ONE channel on topic family `"socialware:feed:<adapter_id>:<session_uri>"`.
  `join/3`: resolve `adapter` via `AdapterRegistry.lookup(adapter_id)`; subscribe
  `adapter.live_topics(session_uri)` FIRST (C4); then branch on
  `delivery_discipline`:
  - `:snapshot_refresh` → `render_authorized/2`; reply snapshot; store NO cursor (C2).
  - `:cursor_replay` → `join_with_cursor/2`; reply snapshot; store cursor in assigns (C2).
  `handle_info/2` (advisory): branch on `socket.assigns.discipline` →
  `render_authorized` (re-read) OR `replay/3` (from stored cursor); push `"snapshot"`,
  or on `{:error, :unauthorized}` push `"unauthorized"` + `{:stop, :shutdown}` (C3).
  `handle_in/3` gated by `participation_profile`: `:read_only` → `"post"` replies
  `{:error, %{reason: "read_only"}}`; `:participatory` → `"join"`/`"post"`/`"history"`
  bodies LIFTED VERBATIM from retire-branch `external_feed_channel.ex`.
- **Test (`session_feed_channel_test.exs`, new):** drive with the `ezagent_web`-local
  `SnapshotPullAdapter` + `CursorPullAdapter` fixtures (Task 1.3 cross-app caveat —
  do NOT reach for the external_mirror fixtures; they don't compile here) via
  `Phoenix.ChannelTest`:
  - snapshot-refresh join stores NO cursor; advisory re-reads (push `"snapshot"`).
  - cursor-replay join stores cursor; advisory replays from cursor (idempotent — re-delivered row not skipped).
  - live revocation (`render_authorized`/`replay` returns `{:error, :unauthorized}`) → push `"unauthorized"` + channel stops (C3).
  - subscribe-first: an advisory fired immediately after join is handled (C4).
  - `:read_only` adapter rejects `"post"`; `:participatory` accepts participation handlers.
- **Steps:** red → implement dispatcher → green → commit.

### Task 1.7 — `SessionFeedSocket` (generic, additive — NOT routed in endpoint yet)
- **Create:** `apps/ezagent_web/lib/ezagent_web/socialware/session_feed_socket.ex`
- **Produces:** `use Phoenix.Socket`; `channel "socialware:feed:*", SessionFeedChannel`;
  `connect/3` resolves `adapter_id` + `session_uri` + `caller` into assigns. **Caller
  resolution = inline LIFT of the existing `ChatFeedSocket`/`ExternalFeedSocket`
  `connect/3` logic** (signed-in member OR existing anon mint/cookie). **Do NOT
  build AnonIngress** (C5 / sprawl boundary) — temporary duplication is accepted;
  PR-3 factors it later.
- **Test (`session_feed_socket_test.exs`, new):** `connect/3` resolves a signed-in
  caller and an anon caller into assigns; bad token → `:error`.
- **NOT done here:** no `socket "/…"` line added to `endpoint.ex` yet (additive;
  in PR-2 Task 2.4 the legacy sockets are repointed at `SessionFeedChannel` and an
  optional generic `/socialware_feed_socket` may be added). The socket is exercised
  only by its unit test in PR-1.
- **Steps:** red → implement → green → commit.

### Task 1.8 — PR-1 gate + open PR (no merge)
- Run scoped: `MIX_TEST_PARTITION=commsplan1 mix precommit` (or the project's
  precommit alias) + `mix arch.scan` + `mix check_invariants`.
- Confirm old chat/external channels untouched + their suites green (additive proof).
- Open PR (base `main`). **Do NOT self-merge.**

---

## PR-2 — Adapter revival + boot registration + cutover (LOAD-BEARING registration)

**Goal:** `ExternalFeedAdapter` (undo #1037 the right way) + register BOTH chat +
external adapters at boot; the generic channel resolves them from `AdapterRegistry`;
flip the routes; DELETE the two old channels; assert the scoped elimination gate.
End state: chat + external both ride the substrate, disciplines intact, precommit +
arch gates + elimination test green.

### Task 2.1 — `ExternalFeedAdapter` + `.Allow` (delegating to existing `ExternalFeed`)
- **Create:** `apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed_adapter.ex`
- **Consumes:** `ExternalFeed.snapshot/2`, `.join/3`, `.replay/3` (the existing
  projection — REUSED unchanged), `ExternalDelivery.topic/1`,
  `Delivery.session_events_topic/1`.
- **Produces:** `ExternalFeedAdapter.Allow` (cap `allow_external_feed`,
  `dispatchable?: false`, mirroring `ChatFeedAdapter.Allow`) + `ExternalFeedAdapter`:
  `adapter_id "external_feed"`, `adapter_kind :pull`, `delivery_discipline :cursor_replay`,
  `participation_profile :participatory`, `cap_subject/0`,
  `live_topics/1 = [ExternalDelivery.topic(uri), Delivery.session_events_topic(uri)]`,
  `render/2` → `ExternalFeed.snapshot/2`, `join_with_cursor/2` → `ExternalFeed.join/3`,
  `replay/3` → `ExternalFeed.replay/3`. (If `ExternalFeed` on main lacks a public
  `replay/3` matching the contract shape, add a thin wrapper in `ExternalFeed` over
  `committed_deliveries_since/2` — same app, no new dep.)
- **Test (`external_feed_adapter_test.exs`, new):** the adapter's callbacks delegate
  correctly; `delivery_discipline == :cursor_replay`; `live_topics/1` returns both
  topics; a non-member → `{:error, :unauthorized}` (fail-closed, C3).
- **Steps:** red → implement adapter wrapper → green → commit.

### Task 2.2 — Migrate `ChatFeedAdapter` to the extended contract
- **Modify:** `apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed_adapter.ex`
- **Produces:** add `delivery_discipline/0 :snapshot_refresh`,
  `participation_profile/0 :read_only`, `render_authorized/2`
  (`{:ok, snapshot}` / `{:error, :unauthorized}` via the chat membership check),
  `live_topics/1 = [Delivery.session_events_topic(uri)]`. Keep bare `render/2`.
- **Test (`chat_feed_adapter_test.exs`):** `render_authorized/2` returns `{:ok,_}`
  for a member, `{:error, :unauthorized}` for a non-member; `delivery_discipline`/`participation_profile` correct.
- **Steps:** red → implement → green → commit.

### Task 2.3 — Register BOTH adapters at boot (registration becomes load-bearing)
- **Create/Modify:** a socialware-owned boot declaration that publishes both
  `ChatFeedAdapter` + `ExternalFeedAdapter` (and their `.Allow` cap subjects) into
  `AdapterRegistry` via the existing bare-module pull-declaration shape. Per SPEC
  §11-OQ1, default to a **socialware-owned `adapters/0`** declarer (lead's
  recommendation); if a dedicated micro-plugin is cleaner, note it but do NOT
  expand scope. Verify cap subjects (`allow_chat_feed`, `allow_external_feed`)
  publish at boot.
- **Test (`adapter_registration_test.exs`, new):** after boot, `AdapterRegistry.lookup("chat_feed")`
  and `lookup("external_feed")` both resolve; both `:pull`; cap subjects present on
  `Ezagent.Entity.Session`.
- **Steps:** red → wire `adapters/0` declaration → green → commit.

### Task 2.4 — Cutover via the LEGACY-ALIAS path (ONE path — no JS change)
**Decision (NOT lead's-call mid-run): take the legacy-topic-alias path** (SPEC
§11-OQ2 recommendation; smallest blast radius, no production-client churn, stays
in PR-1+2 scope, needs NO AnonIngress). Do NOT migrate the JS clients in this unit.
- **Modify:** `apps/ezagent_web/lib/ezagent_web/socialware/chat_feed_socket.ex` and
  `external_feed_socket.ex` — repoint their `channel` macro at `SessionFeedChannel`
  (KEEP each socket's existing `connect/3` caller-resolution + the existing endpoint
  `socket "/socialware_chat_socket"` / `"/socialware_external_socket"` lines, so
  existing JS connects unchanged). Optionally also add
  `socket "/socialware_feed_socket", SessionFeedSocket` for new generic clients,
  but the legacy sockets staying live is what keeps clients churn-free.
- **Modify:** `SessionFeedChannel` to parse BOTH topic shapes →
  `"socialware:feed:<adapter_id>:<uri>"` (generic) AND the legacy
  `"socialware:chat_feed:<uri>"` → fixed `adapter_id "chat_feed"` /
  `"socialware:external:<uri>"` → fixed `adapter_id "external_feed"`. This is real
  parsing code (a join-topic matcher), not a config "alias". E1 bans `*FeedChannel`
  MODULES, not `*FeedSocket` — keeping the sockets satisfies E1.
- **Test:** end-to-end channel test (real adapters via the registry) using BOTH the
  generic topic AND each legacy topic — chat join re-reads on a session event;
  external join replays on `{:external_delivery}`; participation `post`/`join` on
  external works through the generic channel.
- **Steps:** red → repoint sockets + add legacy-topic parsing to `SessionFeedChannel` → green → commit.

### Task 2.5 — DELETE only the two old channel MODULES (sockets stay)
- **Delete:** `apps/ezagent_web/lib/ezagent_web/socialware/chat_feed_channel.ex`
  and `external_feed_channel.ex` (their `handle_in`/`handle_info` bodies already
  lifted into `SessionFeedChannel` in PR-1 Task 1.6). **KEEP**
  `chat_feed_socket.ex` / `external_feed_socket.ex` (now pointing at
  `SessionFeedChannel`, per Task 2.4) — their `connect/3` is PR-3's AnonIngress
  factoring target; do not touch it here (minimize blast radius / sprawl boundary).
- **Test:** old channel test files deleted/replaced; full suite green proves no
  caller references the deleted channel modules.
- **Steps:** delete the two channel modules → run suite → green → commit.

### Task 2.6 — Scoped elimination gate (E1 + E2 + E5 + disciplines) — the completion test
- **Create:** `apps/ezagent_core/test/architecture/comms_substrate_elimination_test.exs`
  (or the project's arch-test location).
- **Produces (assert ALL):**
  - **E1** — NO module/file named `*FeedChannel` exists EXCEPT
    `EzagentWeb.Socialware.SessionFeedChannel` (grep: `chat_feed_channel` +
    `external_feed_channel` are gone).
  - **E2** — every registered `:pull` adapter (`chat_feed`, `external_feed`) is in
    `AdapterRegistry` at boot (registration is load-bearing — no declared-but-unregistered `:pull`).
  - **E5** — the dep DAG is unchanged: no new app `in_umbrella` edge; the existing
    acyclic + undeclared-dep gates stay green (assert via the existing gates, do not
    duplicate them).
  - **Disciplines intact** — assert the `chat_feed` adapter resolves
    `delivery_discipline == :snapshot_refresh` + `participation_profile == :read_only`,
    and `external_feed` resolves `:cursor_replay` + `:participatory`.
  - **SCOPE NOTE in the test:** explicitly document that **E3-for-world** and
    **E4-AnonIngress-dedup** are OUT of this unit (PR-3/PR-4) so the gate does NOT
    trip on `WorldLive`'s surviving session read or the un-factored anon helpers.
- **Steps:** write test → red until 2.1–2.5 land → green → commit.

### Task 2.7 — PR-2 gate + open PR (no merge)
- Run scoped: `MIX_TEST_PARTITION=commsplan2 mix precommit` + `mix arch.scan` +
  `mix check_invariants`.
- Known cross-suite flakes to NOTE (do not chase): `AgentReadTest`,
  `PluginIsolation`, `PresenceReadReceipts` — if ONLY these fail, note + proceed;
  any other failure is yours to root-cause.
- Open PR (base `main`, stacked on PR-1 or same branch). **Do NOT self-merge.**

---

## 3. Per-PR acceptance gates (the verifiable contract)

| Gate | PR-1 | PR-2 |
|---|---|---|
| Full `mix precommit` (scoped `MIX_TEST_PARTITION`) green | ✅ | ✅ |
| `mix arch.scan` green | ✅ | ✅ |
| `mix check_invariants` green | ✅ | ✅ |
| New contract callbacks + registry rule tested (accept/reject both disciplines) | ✅ | — |
| Behaviour-legality grep gate (no session/socialware ref low) green | ✅ | — |
| Generic channel proven on TEST fixtures (both disciplines + fail-closed + subscribe-first) | ✅ | — |
| Old chat/external channels UNTOUCHED + their suites green (additive proof) | ✅ | n/a (deleted) |
| `ExternalFeedAdapter` + `ChatFeedAdapter` register at boot; cap subjects published | — | ✅ |
| Chat + external work THROUGH the generic channel; both disciplines intact | — | ✅ |
| Elimination test (E1 + E2 + E5 + disciplines) green | — | ✅ |
| NOT self-merged (PR open for lead/Claude verify) | ✅ | ✅ |

---

## 4. Provenance / method
- All code reads via `git show origin/main:<path>` and `git show origin/refactor/retire-customer:<path>`.
  No working-tree trust.
- SPEC: `docs/together/2026-06-27/specs/unify-comms-on-adapter-substrate.md` (branch `docs/unify-comms-spec`).
- Anchored facts (§2) verified directly against the cited source files.
