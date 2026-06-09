# AutoService → socialware Vertical E2E (Stage 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Any subagent touching `.ex` MUST load `ezagent-developer` + `elixir-phoenix-helper` skills first.

**Goal:** Stand up the thinnest provable slice of the AutoService CS vertical on the socialware base (`SocialwareSession`) — one cinnox-soul-driven cc bot answering a customer through the visibility-gated `CustomerFeed`, with an operator takeover that flips visibility — recordable E2E on an isolated stack.

**Architecture:** Reuse `SocialwareSession` (Chat+Turn+Surface+ConfigUpdate) as the session Kind. Seed the cinnox **customer soul** as an immutable `ConfigObject` projected to the bot's `CLAUDE.md` via the existing `ConfigProjection` + #17 cascade. The customer message opens a degenerate **Turn** (zero subtasks); the bot's chat reply is composed `:customer_visible` and settled, landing in `CustomerFeed` → the existing **`customer_live` LiveView** (its message source repointed from raw PubSub to `CustomerFeed`). Operator takeover = `turn.claim` → `:operator_only` → edit → `turn.settle`.

**Tech Stack:** Elixir/OTP umbrella, Phoenix LiveView (operator + customer), Ecto/SQLite, cc (Claude) agent flavor, #17 credential cascade, erlexec PTY. (The socialware React/json-render SPA is NOT used in Stage 1 — see DD5-b.)

**Lands on:** the `autoservice` branch (after it is rebased onto `main` — see Stage 0). NOT `main`.

---

## 0. Scope (read this first)

**Stage 1 = thinnest E2E that proves "AutoService CS runs on the socialware base, recordable."**

**IN:**
- `SocialwareSession` provisioned per customer (replaces autoservice's bare `Session`).
- Cinnox **customer soul** seeded as `ConfigObject` → projected to the bot's `CLAUDE.md`.
- **One** cc bot agent (soul-driven), joined to the session. **No fast/slow biphasic in Stage 1** (single cc bot).
- **One flow**: `customer-type-clarifier` (no KB dependency — pure soul/skill driven).
- Customer message → **Turn** (open → compose `:customer_visible` → settle) → `CustomerFeed` → **`customer_live` LiveView** (message source repointed to `CustomerFeed`).
- **Operator takeover**: `turn.claim` → bot drafts go `:operator_only` → operator edits → `turn.settle` flips visibility.
- E2E recorded on an isolated fresh-seeded stack.

**OUT (deferred, with the phase that owns them):**
- fast+slow biphasic (DeepSeek ack + cc) → **Stage 2**.
- KB / `general-inquiry-flow` (needs `kb_search` MCP sidecar; E1-proven) → **Stage 2**.
- Full cinnox content (all souls/skills/flow_chunks) → **Stage 2+**.
- Admin LiveViews (bot_creator / soul_slot_editor / template_editor / template_diff / kb_curator) → **Admin phase**.
- Multi-tenant management surface (persistence already on main) → **Admin phase**.
- Rich operator console (port of `operator_live.ex`, 249 LOC) → **Admin phase**; Stage 1 uses a minimal takeover path on the core `SessionView` + socialware `PageView`.

---

## 1. Design Decisions (answers to the review's framework — REVIEW THESE FIRST)

These answer gagameow's per-面 + soul/skill/kb questions. **DD1 and DD4 are load-bearing — flagged 🔶 for Allen/colleague sign-off before the contingent tasks (Task 5–7) are built.**

### DD1 🔶 — Who drives the Turn for a single-bot CS reply?
**Decision (recommended):** A thin **CS turn adapter** in the autoservice vertical, NOT an orchestrator agent and NOT teaching the bot turn semantics.
- On a customer message (routing `{:from customer} → session`), the adapter calls `turn.open` (degenerate turn, `expected = []`).
- The bot replies via **normal `chat.send`** (it stays a plain cc chat agent — no new MCP turn tools).
- The adapter maps the bot's chat reply into `turn.compose(result_refs: [%{message: <reply>}])` with `mode: :auto` (→ `:customer_visible`) then `turn.settle`.

**Why:** Minimal change to the bot (reuses autoservice's "bot replies in chat" model, `customer_session.ex:51-67` pattern); gains socialware's value (visibility-gated `CustomerFeed` + atomic settlement) without an orchestrator. **Rejected:** (a) bot self-drives turns via MCP tools — forces turn semantics into every CS bot; (b) dedicated orchestrator agent — heavy for single-bot CS, reintroduces the cc-worker relay chain Stage 1 wants to avoid.

**Open sub-question for review:** does `turn.compose` accept a chat-message card_ref shape directly, or does the adapter need a `card_ref` wrapper? (`turn.ex:235-256` `dispatch_subtask` builds `Message.new(...)`; `compose_result_and_effects` at `turn.ex:258+` calls `write_chat_messages` — confirm the result_ref shape in Task 5 Step 1 by reading `write_chat_messages/3`.)

### DD2 — Session Kind
**Decision:** Replace autoservice's bare `Session` with **`SocialwareSession`** (`socialware_session.ex:1-30` — Chat+Turn+Surface+ConfigUpdate). The autoservice `customer_session.ex` provisioner is rewritten to seed a `SocialwareSession` instead of a chat `Session`.

### DD3 — soul → config
**Decision:** cinnox `customer_soul.md` (555 LOC) → one **`ConfigObject`** whose `body` carries the soul markdown under a `"soul_md"` key, pointed at `layer: "session"`, `subject_uri: <bot agent uri>`, `key: "soul"`. Projected to the bot's `CLAUDE.md` via `ConfigProjection`. **Requires enhancing `render_soul/1`** (`config_projection.ex:217-229`) — today it emits a trivial `- key: value` dump; Stage 1 adds a branch: if `body` has `"soul_md"`, emit that verbatim as `CLAUDE.md`. (Small, contained change in the socialware domain — the one core-ish touch, like the rev8 §11 note.)

### DD4 🔶 — skill + kb mapping
**Decision (Stage 1):**
- **skill** (`customer-type-clarifier/SKILL.md`) → materialized into the bot's **AgentTemplate working_directory** (reuse autoservice's `cinnox_assets.ex` materialization pattern), referenced by the soul's skill-index. NOT a ConfigObject in Stage 1.
- **kb** → **deferred to Stage 2** (customer-type-clarifier needs no KB). When added: external `kb_search` MCP sidecar via `operator_mcp_config_path` through the #17 cascade (E1-proven; `agent-data-access-exploration.md`).

**Why flagged:** the soul/skill split (soul=ConfigObject vs skill=working-dir-file) is a real architecture choice gagameow asked about; confirm before Task 6.

### DD5-b 🔶 — Customer UI (revised 2026-06-09)
**Decision:** **Keep autoservice's `customer_live.ex` LiveView**; only repoint its **message source** from raw `Chat.session_events_topic` PubSub to **`CustomerFeed`** — subscribe `CustomerFeed.topic(session_uri)` (the `:customer_delivery` broadcast on settlement) and call `CustomerFeed.snapshot/2` with a `CustomerAuth.issue_token/3` token. Send path unchanged (`chat.send` dispatch, `customer_live.ex:51-67`).

**Why (supersedes the earlier "use React SPA / drop customer_live"):** the customer-safe gating is a property of **`CustomerFeed` (visibility filter + settlement gate)**, which is orthogonal to whether the frontend is LiveView or SPA. For a **page-less, conversational CS** the SPA's only added value — json-render of a live **Surface** page — is not exercised. So the minimal change is to swap the message source on the working `customer_live`, not to discard it. The React SPA + `customer_socket`/`customer_channel` are the right move **only when a real "live page" (Surface) product line exists**.

**Flagged for Allen 🔶:** this deviates from rev8's "customer = React SPA". The SPA decision is deferred to the Surface/live-page line and is an explicit Allen call (open question §4.5).

### DD6 — Operator surface
**Decision:** Stage 1 = **minimal takeover** on the core `SessionView` (operator sees the session) + a single "claim/settle" control wired to `turn.claim`/`turn.settle`. **No** port of `operator_live.ex` (249 LOC) in Stage 1. Draft invisibility uses `Message.visibility` (`:operator_only`) + `CustomerFeed` filtering — the capability autoservice lacks today.

---

## 2. File Structure

**New (autoservice vertical, on `autoservice` branch):**
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/socialware_cs.ex` — Stage-1 provisioner + CS turn adapter (DD1, DD2). Replaces the `SocialwareSession`-seeding parts of `customer_session.ex`.
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/cinnox_soul_seed.ex` — seed cinnox soul → `ConfigObject` (DD3).
- `apps/ezagent_plugin_autoservice/test/socialware_cs_test.exs`
- `apps/ezagent_plugin_autoservice/test/cinnox_soul_seed_test.exs`
- `apps/ezagent_plugin_autoservice/test/e2e/cs_socialware_stage1_live_test.exs` — runbook-style live E2E (tagged `:live`/`:skip`, mirrors `scenario_34_sender_locked_relay_live_test.exs`).

**Modified (autoservice vertical, on `autoservice` branch):**
- `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_live.ex:13-71` — repoint message source from `Chat.session_events_topic` to `CustomerFeed` (DD5-b). Send path unchanged.

**Modified (socialware domain, on `main` → comes in via rebase):**
- `apps/ezagent_domain_socialware/lib/ezagent/socialware/config_projection.ex:217-229` — `render_soul/1` soul_md branch (DD3).
- `apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs` — add soul_md projection test.

**Reused as-is (no change):** `SocialwareSession`, `Behavior.Turn/Surface/ConfigUpdate`, `ConfigStore`, `CustomerFeed/CustomerAuth`, #17 cascade, cc agent flavor, `cinnox_assets.ex` materialization.
**NOT used in Stage 1 (deferred to the Surface/live-page line, DD5-b):** `customer_app.js`, `customer_socket.ex`/`customer_channel.ex` (the React SPA path).

---

## 3. Tasks

### Task 0: Live G1 confirmation (de-risk before building)
**Goal:** Confirm on an isolated stack that a cc member spawned via `add_managed_member` actually joins chat and replies on current `main` (G1 / the #539 fix). This is the first integration milestone — if it fails, escalate before building Stage 1.

**Files:** none (runbook). Uses `apps/ezagent_domain_instance_message/test/e2e/scenario_34_sender_locked_relay_live_test.exs` as the harness.

- [ ] **Step 1:** Bring up an isolated fresh-seeded stack (per `docs/superpowers/specs/2026-06-04-dockerized-e2e-harness-design.md`; NOT the shared dev/prod node — socialware #595). Export `CLAUDE_CODE_OAUTH_TOKEN` (memory `project-headless-cc-agent-auth-token` — Keychain login does NOT cross to PtyServer-spawned claude).
- [ ] **Step 2:** Run the gated live relay test:
  `SCENARIO_34_LIVE=1 mix test apps/ezagent_domain_instance_message/test/e2e/scenario_34_sender_locked_relay_live_test.exs`
  Expected: the relay member (built via `add_managed_member`) actually delivers a `chat.receive` and replies (assert reads `Ezagent.MessageStore` for the wrapper text — see the test's moduledoc §"What the relay executed means").
- [ ] **Step 3:** Record the result in `docs/notes/2026-06-09-g1-live-confirmation.md` (PASS → G1 retired; FAIL → STOP, file the gap, escalate to Allen — do not build Stage 1 on a broken relay).

### Task 1: `render_soul/1` projects raw soul markdown (DD3)
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
  Run: `mix test apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs -v`
  Expected: FAIL (first test — current `render_soul` wraps everything in the `# Agent soul (...)` header).
- [ ] **Step 3: Implement the soul_md branch**
```elixir
def render_soul(%{"soul_md" => soul_md}) when is_binary(soul_md), do: soul_md
def render_soul(body) when is_map(body) do
  lines = body |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
              |> Enum.map(fn {k, v} -> "- #{k}: #{render_value(v)}" end)
  "# Agent soul (socialware self-evolve config)\n\n#{Enum.join(lines, "\n")}\n"
end
```
- [ ] **Step 4: Run to verify pass**
  Run: `mix test apps/ezagent_domain_socialware/test/ezagent/socialware/config_projection_test.exs -v` → PASS.
- [ ] **Step 5: Commit**
  `git add apps/ezagent_domain_socialware/... && git commit -m "feat(socialware): render_soul projects raw soul_md as CLAUDE.md (autoservice migration DD3)"`

### Task 2: Seed cinnox soul → ConfigObject (`cinnox_soul_seed.ex`)
**Files:**
- Create: `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/cinnox_soul_seed.ex`
- Test: `apps/ezagent_plugin_autoservice/test/cinnox_soul_seed_test.exs`

- [ ] **Step 1: Write the failing test** — `seed_soul/2` writes a ConfigObject + session-layer pointer for the bot, body carries the cinnox soul markdown under `"soul_md"`.
```elixir
test "seed_soul/2 writes a ConfigObject pointed at the bot's session-layer soul key" do
  {:ok, %{config_id: id}} = CinnoxSoulSeed.seed_soul(bot_uri, workspace_uri)
  {:ok, obj} = ConfigStore.resolve("session", workspace_uri, bot_uri, "soul")
  assert obj.id == id
  assert obj.body["soul_md"] =~ "IDENTITY"
end
```
- [ ] **Step 2: Run to verify fail** (`CinnoxSoulSeed` undefined).
- [ ] **Step 3: Implement** — read `priv/cinnox/souls/customer_soul.md`, `ConfigStore.write_and_point/1` with `%{layer: "session", workspace_uri, subject_uri: bot_uri, key: "soul", body: %{"soul_md" => contents}, created_by: ..., source_turn_id: "seed"}`.
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit.**

### Task 3: Provision a SocialwareSession + soul-driven bot (`socialware_cs.ex` part 1 — provisioning, DD2)
**Files:**
- Create: `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/socialware_cs.ex`
- Test: `apps/ezagent_plugin_autoservice/test/socialware_cs_test.exs`

- [ ] **Step 1: Write the failing test** — `provision/2` is an idempotent reconciler (mirror `customer_session.ex:58-90`) that: creates a `SocialwareSession`, seeds the soul (Task 2), provisions a cc bot whose #17 user-cascade layer points at the soul ConfigObject (so `ConfigProjection` renders its `CLAUDE.md`), joins customer + bot, installs routing `{:from customer, :in_session} → session`. Assert session is a `SocialwareSession` with `:turns` + `:surface` slices and the bot joined.
- [ ] **Step 2–5:** fail → implement (reuse `Workspace.create_agent/3`, `CascadeRepoint.repoint_user_layer/3` to point the bot at the soul object, `RuleStore.add` for routing, `chat.join`) → pass → commit. **No fast/slow.**

### Task 4: Seed the chosen flow's skill into the bot working dir (DD4)
**Files:** Modify `socialware_cs.ex`; Test in `socialware_cs_test.exs`.
- [ ] **Step 1: Write failing test** — provisioning materializes `customer-type-clarifier/SKILL.md` into the bot's working directory (reuse `cinnox_assets.ex` helpers) and the soul's skill-index references it.
- [ ] **Step 2–5:** fail → implement → pass → commit.

### Task 5 🔶 (contingent on DD1): CS turn adapter — customer msg opens+composes+settles a turn
**Files:** Modify `socialware_cs.ex` (the adapter); Test in `socialware_cs_test.exs`.
- [ ] **Step 1: Read `write_chat_messages/3` + `compose_result_and_effects/4`** (`turn.ex:258+`, `turn.ex:419-430`) to confirm the `result_refs` card shape the adapter must produce. Write the failing test against that shape: a customer message triggers `turn.open`; a simulated bot reply drives `turn.compose(mode: :auto)` → message written `:customer_visible`; `turn.settle` → `Settlement` reaches `:committed` and `CustomerFeed.snapshot/2` returns the reply.
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement the adapter** — subscribe to the session's chat events (`Chat.session_events_topic`), on a `{:from customer}` message dispatch `turn.open`; on the bot's reply dispatch `turn.compose` then `turn.settle` (all via `Ezagent.Invocation.dispatch/1`, cap-checked). Degenerate turn: `expected = []`.
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit.**

### Task 6 🔶 (contingent on DD1/DD6): Operator takeover — claim → operator_only → edit → settle
**Files:** Modify `socialware_cs.ex` + a minimal operator control (core `SessionView` action); Test in `socialware_cs_test.exs`.
- [ ] **Step 1: Write failing test** — operator `turn.claim(by: operator_uri)` flips in-flight bot messages to `:operator_only` (assert `CustomerFeed.snapshot` does NOT show them); operator sends an edited reply; `turn.settle` flips to `:customer_visible` and `CustomerFeed` now shows the operator's version. (Exercises `turn.ex:164-177` claim + `turn.ex:179-197` settle + `Settlement.flip_visibility`.)
- [ ] **Step 2–5:** fail → implement → pass → commit.

### Task 7: Repoint `customer_live` message source to `CustomerFeed` (DD5-b)
**Files:**
- Modify: `apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/customer_live.ex:13-71`
- Test: `apps/ezagent_plugin_autoservice/test/customer_live_feed_test.exs` (new)
- [ ] **Step 1: Write the failing test** — mount for a CS `SocialwareSession`: the LiveView issues a `CustomerAuth.issue_token/3` token, subscribes `CustomerFeed.topic(session_uri)`, and `load_messages` comes from `CustomerFeed.snapshot/2`. Assert: an `:operator_only` message is NOT in the rendered list; after settle (`:customer_delivery` broadcast), the `:customer_visible` message appears. (Today it subscribes `Chat.session_events_topic` and shows all messages — that assertion fails.)
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement** — in `mount/3` replace `Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))` with `Phoenix.PubSub.subscribe(EzagentCore.PubSub, CustomerFeed.topic(session_uri))`; store a `CustomerAuth.issue_token/3` token in assigns; `load_messages` → `CustomerFeed.snapshot(session_uri, token)`; handle `{:customer_delivery, _}` by re-snapshotting. **Send path (`handle_event("send", ...)`) unchanged.**
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit.**

### Task 8: `customer_live` + `CustomerFeed` integration check (gap G3, revised for DD5-b)
**Files:** none (verification) → `docs/notes/2026-06-09-customer-live-feed-gaps.md`.
- [ ] **Step 1:** Drive `customer_live` against a seeded CS session with `agent-browser` (headless Chrome, remote IP `100.64.0.27` per project convention). Confirm: customer sees only `:customer_visible` settled messages; operator drafts (`:operator_only`) stay hidden until settle; the feed updates on `:customer_delivery`.
- [ ] **Step 2:** File concrete gaps; fix only blockers for the Stage-1 recordable flow (defer the rest).

### Task 9: E2E live runbook + recording
**Files:** Create `apps/ezagent_plugin_autoservice/test/e2e/cs_socialware_stage1_live_test.exs` (tagged `@moduletag :live` + `:skip`, mirror `scenario_34_sender_locked_relay_live_test.exs`).
- [ ] **Step 1:** Write the runbook assertion: on an isolated seeded stack, customer asks a weak-signal question → bot (cinnox soul) replies via the clarifier flow (`customer-type-clarifier`) → message visible in `CustomerFeed`; operator claims, edits, settles → customer sees operator's version. Assertion reads `MessageStore.committed_customer_visible/2` + `CustomerFeed.snapshot/2` (the production path, no stub).
- [ ] **Step 2:** Run gated (`AUTOSERVICE_CS_LIVE=1 mix test ...`), capture the terminal/UI replay (E1-style `term-replay.js`, or agent-browser screencap) → `docs/notes/evidence/autoservice-cs-stage1/`.
- [ ] **Step 3:** Commit evidence; this is the recordable Stage-1 demo.

---

## 4. Open questions for Allen / colleague review

1. **DD1** — CS turn adapter vs orchestrator agent for single-bot CS. (Recommended: adapter.)
2. **DD4** — soul=ConfigObject vs skill=working-dir-file split; is that the intended soul/skill boundary on socialware?
3. **Stage-1 flow choice** — `customer-type-clarifier` (no KB) as the first flow; `general-inquiry-flow` (KB) deferred to Stage 2. OK?
4. **fast+slow deferral** — Stage 1 drops the DeepSeek-ack biphasic for a single cc bot. Acceptable for the first E2E, or is the biphasic latency UX a must-have in Stage 1?
5. **DD5-b deviates from rev8 "customer = React SPA"** — Stage 1 keeps `customer_live` (LiveView) and only repoints its source to `CustomerFeed`; the React SPA is deferred to a real Surface/live-page product line. **Allen call:** OK to defer the SPA, or is customer=SPA a hard requirement now?

---

## 5. Dependencies / sequencing

- **Stage 0 (prerequisite, separate):** rebase `origin/autoservice` onto `main` (gets socialware base; 68 behind). We do it, colleague reviews. This plan's "modified socialware" files assume that rebase.
- **Task 0 gates everything** — if G1 live confirmation fails, stop and escalate.
- Tasks 1–4 are non-contingent foundation (parallelizable after Task 0).
- Tasks 5–6 are contingent on DD1 sign-off.
- Tasks 7–9 close the E2E.
