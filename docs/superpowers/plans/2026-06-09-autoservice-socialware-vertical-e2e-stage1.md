# AutoService → socialware Vertical E2E (Stage 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Any subagent touching `.ex` MUST load `ezagent-developer` + `elixir-phoenix-helper` skills first.
>
> **rev2 (2026-06-09)** — incorporates @gagameow's review of #690: ① DD3 `render_soul` change lands as an **independent PR to `main` first**, then rebases in; ② **DD1 turn-end policy** added (per-turn idle-window + conversation-end "anything else?"); ③ **reject** the "keep raw subscription as fallback" suggestion (it leaks `:operator_only` — see Task 7); ④ DD5-b/DD6/DD4 **cleared** by the corrected review (no 🔶 / no Allen decision); ⑤ fast+slow stays deferred — **measure latency first, then pick the lightest mitigation** (not a presumed problem).

**Goal:** Stand up the thinnest provable slice of the AutoService CS vertical on the socialware base (`SocialwareSession`) — one cinnox-soul-driven cc bot answering a customer through the visibility-gated `CustomerFeed`, with an operator takeover that flips visibility — recordable E2E on an isolated stack.

**Architecture:** Reuse `SocialwareSession` (Chat+Turn+Surface+ConfigUpdate) as the session Kind. Seed the cinnox **customer soul** as an immutable `ConfigObject` projected to the bot's `CLAUDE.md` via the existing `ConfigProjection` + #17 cascade. The customer message opens a degenerate **Turn** (zero subtasks); the bot's chat reply is composed `:customer_visible` and settled, landing in `CustomerFeed` → the existing **`customer_live` LiveView** (its message source repointed from raw PubSub to `CustomerFeed`). Operator takeover = `turn.claim` → `:operator_only` → edit → `turn.settle`.

**Tech Stack:** Elixir/OTP umbrella, Phoenix LiveView (operator + customer), Ecto/SQLite, cc (Claude) agent flavor, #17 credential cascade, erlexec PTY. (The socialware React/json-render SPA is NOT used in Stage 1 — see DD5-b.)

**Lands on:** the `autoservice` branch (after it is rebased onto `main` — see §5). The one socialware-domain change (DD3) lands on `main` first as its own PR.

---

## 0. Scope (read this first)

**Stage 1 = thinnest E2E that proves "AutoService CS runs on the socialware base, recordable."**

**IN:**
- `SocialwareSession` provisioned per customer (replaces autoservice's bare `Session`).
- Cinnox **customer soul** seeded as `ConfigObject` → projected to the bot's `CLAUDE.md`.
- **One** cc bot agent (soul-driven), joined to the session. **Single bot — no fast/slow biphasic** (see the defer note below).
- **One flow**: `customer-type-clarifier` (no KB dependency — pure soul/skill driven; also the *least* latency-prone flow).
- Customer message → **Turn** (open → compose `:customer_visible` → settle) → `CustomerFeed` → **`customer_live` LiveView** (message source repointed to `CustomerFeed`).
- **Operator takeover**: `turn.claim` → bot drafts go `:operator_only` → operator edits → `turn.settle` flips visibility.
- E2E recorded on an isolated fresh-seeded stack, **measuring real cc reply latency** (Task 9).

**OUT (deferred, with the phase that owns them):**
- **fast+slow biphasic (DeepSeek ack + cc) → deferred, decided by measurement, attached to Stage 2.** Rationale: fast+slow was a fix for a *measured* latency problem in the prior project; carrying it into the new stack pre-supposes an unmeasured problem (premature optimization). The Stage-1 flow (`customer-type-clarifier`, no KB, short classification reply) is the least latency-prone, so it is the wrong place to test the mitigation anyway. **Decision: build single-bot, measure cc latency in Task 9, and only if it's bad pick the lightest effective mitigation in this order — (a) a client-side "typing…" indicator (zero backend, settlement-safe); (b) a lighter/non-reasoning model or trimmed prompt; (c) streaming (note: conflicts with the "customer only sees committed" settlement invariant — handle with care); (d) fast+slow biphasic, last.** This decision belongs with Stage 2 (the KB-heavy `general-inquiry-flow`, where latency actually lives). Deferring is cheaply reversible; building now then finding it unneeded is wasted, coupled work.
- KB / `general-inquiry-flow` (needs `kb_search` MCP sidecar; E1-proven) → **Stage 2**.
- Full cinnox content (all souls/skills/flow_chunks) → **Stage 2+**.
- Admin LiveViews (bot_creator / soul_slot_editor / template_editor / template_diff / kb_curator) → **Admin phase**.
- Multi-tenant management surface (persistence already on main) → **Admin phase**.
- Rich operator console (port of `operator_live.ex`, 249 LOC) → its own **operator-frontend product line** (review-confirmed: operator is a business frontend, not admin); Stage 1 uses a minimal takeover path on the core `SessionView`.

---

## 1. Design Decisions (answers to the review's framework)

DD1 is the design centerpiece (review approved the direction; turn-end policy is specified below). DD2–DD6 are settled — DD4/DD5-b/DD6 were explicitly **cleared in @gagameow's corrected review** (no Allen decision needed).

### DD1 — Who drives the Turn for a single-bot CS reply? (+ turn-end policy)
**Decision (review-approved direction):** A thin **CS turn adapter** in the autoservice vertical, NOT an orchestrator agent and NOT teaching the bot turn semantics.
- On a customer message (routing `{:from customer} → session`), the adapter calls `turn.open` (degenerate turn, `expected = []`).
- The bot replies via **normal `chat.send`** (it stays a plain cc chat agent — no new MCP turn tools).
- The adapter maps the bot's chat reply into `turn.compose(result_refs: [%{message: <reply>}])` with `mode: :auto` (→ `:customer_visible`) then `turn.settle`.

**Turn-end policy (two layers — the review's open question):**
1. **Per-turn completion** (when does the adapter `compose`+`settle` a turn?): the bot's reply for one customer message may be one or more chat messages, so use an **idle-window coalesce** — collect the bot's reply messages until a short silence (no new bot message within window W, default ~2s), then `compose`(all collected) + `settle`. (Single bot → no multi-worker `deliver`; W is the only knob.)
2. **Conversation end** (when to close the session): the bot, per the cinnox soul, asks "**还有其他可以帮您的吗?**"; on an **end-type customer reply** (soul-classified) **or a timeout**, the session is closed. (Mainstream CS pattern.) This is soul/flow behavior, not adapter plumbing — encoded in the soul, observed by the adapter for the close.

**Why the adapter:** Minimal change to the bot (reuses autoservice's "bot replies in chat" model, `customer_session.ex:51-67`); gains socialware's value (visibility-gated `CustomerFeed` + atomic settlement) without an orchestrator. **Rejected:** (a) bot self-drives turns via MCP tools — forces turn semantics into every CS bot; (b) dedicated orchestrator agent — heavy for single-bot CS.

**Open sub-question (resolved in Task 5 Step 1):** the exact `result_refs` card shape `turn.compose` expects — confirm by reading `write_chat_messages/3` (`turn.ex:258+`).

### DD2 — Session Kind
**Decision:** Replace autoservice's bare `Session` with **`SocialwareSession`** (`socialware_session.ex:1-30` — Chat+Turn+Surface+ConfigUpdate).

### DD3 — soul → config (lands on `main` first)
**Decision:** cinnox `customer_soul.md` (555 LOC) → one **`ConfigObject`** whose `body` carries the soul markdown under a `"soul_md"` key, pointed at `layer: "session"`, `subject_uri: <bot agent uri>`, `key: "soul"`. Projected to the bot's `CLAUDE.md` via `ConfigProjection`.
**Requires enhancing `render_soul/1`** (`config_projection.ex:217-229`): today it emits a trivial `- key: value` dump; add a branch — if `body` has `"soul_md"`, emit it verbatim as `CLAUDE.md`.
**Merge path (review point, "先合 main"):** this is a **`ezagent_domain_socialware` (main) change**, not an autoservice change. It ships as an **independent PR → `main` (Task 1)**, then flows into `autoservice` via the rebase (§5). We do NOT edit socialware-domain code directly on the `autoservice` branch.

### DD4 — skill + kb mapping (review-cleared)
**Decision (Stage 1):**
- **skill** (`customer-type-clarifier/SKILL.md`) → materialized into the bot's **AgentTemplate working_directory** (reuse `cinnox_assets.ex`), referenced by the soul's skill-index. NOT a ConfigObject.
- **kb** → **deferred to Stage 2** (clarifier needs no KB). When added: external `kb_search` MCP sidecar via `operator_mcp_config_path` through the #17 cascade (E1-proven).
**Review note:** the soul=ConfigObject vs skill=working-dir boundary is confirmed reasonable — **soul needs versioned self-evolve history (ConfigObject + pointer); a skill is a static template-time file that doesn't.**

### DD5-b — Customer UI (review-cleared, NOT a rev8 deviation)
**Decision:** **Keep autoservice's `customer_live.ex` LiveView**; only repoint its **message source** from raw `Chat.session_events_topic` PubSub to **`CustomerFeed`** — subscribe `CustomerFeed.topic(session_uri)` (the `:customer_delivery` broadcast on settlement) and call `CustomerFeed.snapshot/2` with a `CustomerAuth.issue_token/3` token. Send path unchanged (`customer_live.ex:51-67`).

**Why:** customer-safe gating is a property of **`CustomerFeed` (visibility filter + settlement gate)**, orthogonal to LiveView-vs-SPA. A page-less conversational CS does not exercise the SPA's only added value (json-render of a live **Surface** page). Minimal change = swap the source on the working `customer_live`. The React SPA + `customer_socket`/`customer_channel` are for a real "live page" (Surface) product line later.

**rev8 alignment (review-verified):** this is NOT a deviation. rev8 §4.4 (line 249-250) explicitly allows *"Backend E2E can run against a thin LiveView render before the SPA lands"*; the formal customer SPA (loom) is a later phase. **No 🔶, no Allen decision.**

**Behavior change to note (review point):** today `customer_live` streams every chat message in real time; via `CustomerFeed` the customer sees a reply **only after settle** (batch, not live token stream — correct socialware "customer sees only committed" behavior). For the Stage-1 clarifier flow the reply is short/fast, so this is acceptable; perceived latency is **measured in Task 9** and, if poor, mitigated per the §0 ladder.

### DD6 — Operator surface (review-cleared)
**Decision:** Stage 1 = **minimal takeover** on the core `SessionView` + a "claim/settle" control wired to `turn.claim`/`turn.settle`. **No** port of `operator_live.ex` (249 LOC). Draft invisibility uses `Message.visibility` (`:operator_only`) + `CustomerFeed` filtering — the capability autoservice lacks today.
**Review note:** confirmed appropriately scoped — operator is a **business-frontend prototype**, and the formal operator workbench is its own product line (not admin).

---

## 2. File Structure

**New (autoservice vertical, on `autoservice` branch):**
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/socialware_cs.ex` — Stage-1 provisioner + CS turn adapter (DD1, DD2).
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/cinnox_soul_seed.ex` — seed cinnox soul → `ConfigObject` (DD3).
- `apps/ezagent_plugin_autoservice/test/socialware_cs_test.exs`, `.../test/cinnox_soul_seed_test.exs`, `.../test/customer_live_feed_test.exs`
- `apps/ezagent_plugin_autoservice/test/e2e/cs_socialware_stage1_live_test.exs` — runbook live E2E (tagged `:live`/`:skip`).

**`socialware_cs.ex` vs `customer_session.ex` (review point #5):** `socialware_cs.ex` is the **new** `SocialwareSession`-based provisioner. `customer_session.ex` (bare `Session` + fast/slow provisioning) is **superseded for Stage 1's flow** — kept (not deleted) only because its fast/slow provisioning is the reference for the Stage-2 measure-then-decide call. It is **legacy-being-replaced**, not a permanent parallel path (per the no-back-compat-shim convention); delete once Stage 2 settles fast/slow.

**Modified (autoservice vertical):**
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_live.ex:13-71` — repoint message source to `CustomerFeed` (DD5-b). Send path unchanged. **Single source — no dual-subscription fallback (see Task 7).**

**Modified (socialware domain — ships as an independent PR to `main`, NOT on `autoservice`; DD3 / Task 1):**
- `apps/ezagent_domain_socialware/lib/ezagent/socialware/config_projection.ex:217-229` — `render_soul/1` soul_md branch.
- `apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs` — soul_md projection test.

**Reused as-is:** `SocialwareSession`, `Behavior.Turn/Surface/ConfigUpdate`, `ConfigStore`, `CustomerFeed/CustomerAuth`, #17 cascade, cc agent flavor, `cinnox_assets.ex`.
**NOT used in Stage 1 (deferred to the Surface/live-page line):** `customer_app.js`, `customer_socket.ex`/`customer_channel.ex`.

---

## 3. Tasks

### Task 0: Live G1 confirmation (de-risk before building)
**Goal:** Confirm on an isolated stack that a cc member spawned via `add_managed_member` actually joins chat and replies on current `main` (G1 / the #539 fix). First integration milestone — if it fails, escalate before building Stage 1.
**Files:** none (runbook). Harness: `apps/ezagent_domain_instance_message/test/e2e/scenario_34_sender_locked_relay_live_test.exs`.
- [ ] **Step 1:** Bring up an isolated fresh-seeded stack (per `docs/superpowers/specs/2026-06-04-dockerized-e2e-harness-design.md`; NOT the shared dev/prod node — socialware #595). Export `CLAUDE_CODE_OAUTH_TOKEN` (memory `project-headless-cc-agent-auth-token`).
- [ ] **Step 2:** Run `SCENARIO_34_LIVE=1 mix test apps/ezagent_domain_instance_message/test/e2e/scenario_34_sender_locked_relay_live_test.exs`. Expected: the `add_managed_member`-built relay member delivers `chat.receive` and replies (assert reads `Ezagent.MessageStore`).
- [ ] **Step 3:** Record in `docs/notes/2026-06-09-g1-live-confirmation.md` (PASS → G1 retired; FAIL → STOP, file the gap, escalate to Allen).

### Task 1: `render_soul/1` projects raw soul markdown (DD3) — **independent PR → `main`**
> This task ships as its own PR onto `main`, then reaches `autoservice` via the §5 rebase. Do NOT commit it on the `autoservice` branch.

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/config_projection.ex:217-229`
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs`
- [ ] **Step 1: Write the failing test**
```elixir
test "render_soul/1 emits soul_md verbatim as CLAUDE.md when body has soul_md" do
  body = %{"soul_md" => "# CINNOX Customer Soul\n\n1. IDENTITY ...\n"}
  assert ConfigProjection.render_soul(body) == "# CINNOX Customer Soul\n\n1. IDENTITY ...\n"
end

test "render_soul/1 falls back to key:value dump when no soul_md" do
  assert ConfigProjection.render_soul(%{"a" => 1}) =~ "- a: 1"
end
```
- [ ] **Step 2: Run to verify it fails**
  `mix test apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs -v` → FAIL (current `render_soul` wraps everything in the `# Agent soul (...)` header).
- [ ] **Step 3: Implement the soul_md branch**
```elixir
def render_soul(%{"soul_md" => soul_md}) when is_binary(soul_md), do: soul_md
def render_soul(body) when is_map(body) do
  lines = body |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
              |> Enum.map(fn {k, v} -> "- #{k}: #{render_value(v)}" end)
  "# Agent soul (socialware self-evolve config)\n\n#{Enum.join(lines, "\n")}\n"
end
```
- [ ] **Step 4: Run to verify pass** → PASS.
- [ ] **Step 5: Commit + open PR to `main`** `feat(socialware): render_soul projects raw soul_md as CLAUDE.md (autoservice DD3)`

### Task 2: Seed cinnox soul → ConfigObject (`cinnox_soul_seed.ex`)
**Files:** Create `.../cinnox_soul_seed.ex`; Test `.../test/cinnox_soul_seed_test.exs`.
- [ ] **Step 1: Write the failing test** — `seed_soul/2` writes a ConfigObject + session-layer pointer for the bot, body carries the soul markdown under `"soul_md"`.
```elixir
test "seed_soul/2 writes a ConfigObject pointed at the bot's session-layer soul key" do
  {:ok, %{config_id: id}} = CinnoxSoulSeed.seed_soul(bot_uri, workspace_uri)
  {:ok, obj} = ConfigStore.resolve("session", workspace_uri, bot_uri, "soul")
  assert obj.id == id
  assert obj.body["soul_md"] =~ "IDENTITY"
end
```
- [ ] **Step 2: Run to verify fail** (`CinnoxSoulSeed` undefined).
- [ ] **Step 3: Implement** — read `priv/cinnox/souls/customer_soul.md`; `ConfigStore.write_and_point/1` with `%{layer: "session", workspace_uri, subject_uri: bot_uri, key: "soul", body: %{"soul_md" => contents}, created_by: ..., source_turn_id: "seed"}`.
- [ ] **Step 4: Run to verify pass. Step 5: Commit.**

### Task 3: Provision a SocialwareSession + soul-driven bot (`socialware_cs.ex` part 1, DD2)
**Files:** Create `.../socialware_cs.ex`; Test `.../test/socialware_cs_test.exs`.
- [ ] **Step 1: Write the failing test** — `provision/2` is an idempotent reconciler (mirror `customer_session.ex:58-90`): creates a `SocialwareSession`, seeds the soul (Task 2), provisions a cc bot whose #17 user-cascade layer points at the soul ConfigObject (so `ConfigProjection` renders its `CLAUDE.md`), joins customer + bot, installs routing `{:from customer, :in_session} → session`. Assert: session is a `SocialwareSession` with `:turns` + `:surface` slices and the bot joined.
- [ ] **Step 2–5:** fail → implement (`Workspace.create_agent/3`, `CascadeRepoint.repoint_user_layer/3`, `RuleStore.add`, `chat.join`) → pass → commit. **Single bot — no fast/slow.**

### Task 4: Seed the chosen flow's skill into the bot working dir (DD4)
**Files:** Modify `socialware_cs.ex`; Test in `socialware_cs_test.exs`.
- [ ] **Step 1: Write failing test** — provisioning materializes `customer-type-clarifier/SKILL.md` into the bot's working directory (reuse `cinnox_assets.ex`) and the soul's skill-index references it.
- [ ] **Step 2–5:** fail → implement → pass → commit.

### Task 5: CS turn adapter — customer msg opens → coalesce reply → compose → settle (DD1)
**Files:** Modify `socialware_cs.ex` (the adapter); Test in `socialware_cs_test.exs`.
- [ ] **Step 1: Read `write_chat_messages/3` + `compose_result_and_effects/4`** (`turn.ex:258+`) to confirm the `result_refs` card shape. Write the failing test: a customer message triggers `turn.open`; the bot's reply (one or more messages) is **coalesced over the idle window W** then drives `turn.compose(mode: :auto)` → message(s) `:customer_visible`; `turn.settle` → `Settlement` `:committed` and `CustomerFeed.snapshot/2` returns the reply.
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement the adapter** — subscribe to `Chat.session_events_topic`; on a `{:from customer}` message `turn.open`; collect the bot's reply messages, and on idle-window W expiry (default ~2s, no new bot message) `turn.compose` then `turn.settle` (all via `Ezagent.Invocation.dispatch/1`, cap-checked). Degenerate turn: `expected = []`. The conversation-end ("还有其他可以帮您的吗?" → end-reply/timeout → close) is soul-driven; the adapter observes the close.
- [ ] **Step 4: Run to verify pass. Step 5: Commit.**

### Task 6: Operator takeover — claim → operator_only → edit → settle (DD6)
**Files:** Modify `socialware_cs.ex` + a minimal operator control (core `SessionView` action); Test in `socialware_cs_test.exs`.
- [ ] **Step 1: Write failing test** — operator `turn.claim(by: operator_uri)` flips in-flight bot messages to `:operator_only` (assert `CustomerFeed.snapshot` does NOT show them); operator sends an edited reply; `turn.settle` flips to `:customer_visible` and `CustomerFeed` now shows the operator's version. (Exercises `turn.ex:164-177` claim + `turn.ex:179-197` settle + `Settlement.flip_visibility`.)
- [ ] **Step 2–5:** fail → implement → pass → commit.

### Task 7: Repoint `customer_live` message source to `CustomerFeed` (DD5-b)
**Files:** Modify `customer_live.ex:13-71`; Test `.../test/customer_live_feed_test.exs` (new).
> **Reject the "keep raw subscription as a fallback config switch" suggestion.** Keeping `Chat.session_events_topic` alongside `CustomerFeed` is not a safe fallback: that broadcast carries **every** message unfiltered (`chat.ex:587` emits `{:chat_message, _, msg}`; visibility filtering lives ONLY in `MessageStore.committed_customer_visible`, `message_store.ex:235`). A dual subscription would deliver `:operator_only` drafts to the customer — the exact leak `CustomerFeed` prevents. **Single source: `CustomerFeed`. Delete the old subscription, no toggle** (no-back-compat-shim convention).
- [ ] **Step 1: Write the failing test** — mount for a CS `SocialwareSession`: the LiveView issues a `CustomerAuth.issue_token/3` token, subscribes `CustomerFeed.topic(session_uri)`, `load_messages` from `CustomerFeed.snapshot/2`. Assert: an `:operator_only` message is NOT rendered; after settle (`:customer_delivery` broadcast) the `:customer_visible` message appears. (Today it subscribes `Chat.session_events_topic` and shows all → fails.)
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement** — in `mount/3` replace `Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))` with `CustomerFeed.topic(session_uri)`; store a `CustomerAuth.issue_token/3` token; `load_messages` → `CustomerFeed.snapshot(session_uri, token)`; handle `{:customer_delivery, _}` by re-snapshotting. **Send path unchanged. Remove the old subscription entirely.**
- [ ] **Step 4: Run to verify pass. Step 5: Commit.**

### Task 8: `customer_live` + `CustomerFeed` integration check (gap G3)
**Files:** none (verification) → `docs/notes/2026-06-09-customer-live-feed-gaps.md`.
- [ ] **Step 1:** Drive `customer_live` against a seeded CS session with `agent-browser` (headless Chrome, remote IP `100.64.0.27`). Confirm: customer sees only `:customer_visible` settled messages; `:operator_only` drafts stay hidden until settle; feed updates on `:customer_delivery`.
- [ ] **Step 2:** File concrete gaps; fix only Stage-1 blockers (defer the rest).

### Task 9: E2E live runbook + recording + **latency measurement**
**Files:** Create `apps/ezagent_plugin_autoservice/test/e2e/cs_socialware_stage1_live_test.exs` (tagged `@moduletag :live` + `:skip`).
- [ ] **Step 1:** Runbook assertion: on an isolated seeded stack, customer asks a weak-signal question → bot (cinnox soul) replies via `customer-type-clarifier` → message visible in `CustomerFeed`; operator claims, edits, settles → customer sees operator's version. Assertion reads `MessageStore.committed_customer_visible/2` + `CustomerFeed.snapshot/2` (production path, no stub).
- [ ] **Step 2:** Run gated (`AUTOSERVICE_CS_LIVE=1 mix test ...`); **record the wall-clock from customer message → settled `:customer_visible` reply** (this is the latency datum that decides whether any §0 mitigation is needed). Capture the terminal/UI replay → `docs/notes/evidence/autoservice-cs-stage1/`.
- [ ] **Step 3:** Commit evidence + the measured latency; this is the recordable Stage-1 demo.

---

## 4. Review status / remaining open items

**Resolved in @gagameow's review (#690):** DD2 ✅; DD4 ✅ (soul/skill boundary reasonable); DD5-b ✅ (rev8-sanctioned transition, not a deviation — no Allen call); DD6 ✅ (operator scope appropriate); DD1 direction ✅ (adapter) — turn-end policy now specified (§DD1).

**Decided in planning:** fast+slow deferred → measure-first + mitigation ladder (§0); reject the raw-subscription fallback (Task 7); DD3 ships as an independent PR to `main` first (Task 1, §5).

**Still open (low-stakes):**
1. **Idle-window W default** (~2s) for per-turn coalesce — tune against the live runbook (Task 5/9).
2. **Stage-1 flow** — `customer-type-clarifier` (no KB) confirmed reasonable; `general-inquiry-flow` (KB) → Stage 2.

---

## 5. Dependencies / sequencing

- **Prereq A — DD3 to `main`:** Task 1 (`render_soul` soul_md branch) merges to `main` as its own PR.
- **Prereq B — autoservice rebases `main`:** rebase `origin/autoservice` onto `main` (gets socialware base **and** Prereq A; currently 68 behind). We do it, colleague reviews. The autoservice-vertical tasks assume this.
- **Task 0 gates everything** — if G1 live confirmation fails, stop and escalate.
- Tasks 2–4 are foundation (parallelizable after Task 0 + the rebase).
- Tasks 5–6 build the turn adapter + takeover; Task 7 the customer feed; Tasks 8–9 close + record the E2E.
