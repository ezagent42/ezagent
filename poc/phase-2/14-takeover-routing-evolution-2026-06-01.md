# Takeover: Mode-suppression now, routing-reconfig later (decision + the insight not to re-derive)

> 2026-06-01 discussion (no code). Decision: **Route 1 — keep the current
> Mode-output-suppression takeover (Block 2 / PR #526); defer routing-based
> takeover + Copilot to a Phase-2 evolution of `Behavior.Mode`.** Near-term there
> is no Copilot requirement. This note records *why* routing is the correct
> long-term primitive so we don't re-derive it when Copilot lands.

## The insight (verified in code)
"Who can answer in a session" is decided by the **routing layer**, and that layer
is a **Session-level primitive — NOT owned by the orchestrator**:
- `Chat.handle_send` computes recipients via `Routing.Resolver.resolve` against a
  rule table (`RuleStore` SQLite → `RoutingRegistry` ETS). Even "broadcast to all"
  is just a rule (`{:always} → [$session_users, $mentions]`). No hardcoded fan-out.
- `routing.add_rule` / `disable_rule` / `enable_rule` are CapBAC actions registered
  on **`Ezagent.Entity.Session`** (`Ezagent.Behavior.Routing`). Anyone holding the
  cap calls them directly.
- The orchestrator's `write_matcher` is just **one caller** of `routing.add_rule`
  (dispatched on its own Session URI). **B's `customer_session.install_routing`
  already writes the customer→agent rule directly via `RuleStore.add`** — no
  orchestrator in the path.
- ⇒ To use this ability we use the **Session routing primitive directly**; we do
  **not** couple to (or need) the orchestrator agent.

## Why routing is the right primitive for the 3 modes
The glossary's three modes are all "who receives what" — i.e. routing:
| Mode | Routing |
|---|---|
| **Auto** | customer→agent, agent→customer (operator observes via `$session_users` once joined) |
| **Takeover** | customer→operator, operator→customer; **agent dropped from receivers** |
| **Copilot** | customer→agent+operator; agent→operator (review) →customer, or reversed |

**Output-suppression cannot express Copilot** (it only binary-mutes the agent's
*outgoing* message). Routing can. So the clean long-term layering is:
**`Mode` slice = intent declaration (auto/takeover/copilot); the *effect* = a
routing reconfiguration** — removing the `Chat.handle_send` special-case suppression.

## Current takeover (what #526 actually does)
- operator joins as its own `entity://user/...` URI (`chat.join`) and replies via
  `chat.send` as that URI → fans out to the customer normally (already a
  first-class participant; "operator joins + frontend filters" is **already real**).
- `mode.set(:takeover)` flips the `:mode` slice; `Chat.handle_send` then drops
  customer-facing recipients **only when the agent is the sender**. So the customer
  message **still routes to the agent, which still runs a full LLM turn** — only its
  reply is dropped at fan-out. Wasteful + a mid-turn race, but simple and trivially
  reversible.

## Gaps to solve when we do the routing version (Phase 2)
1. **Reversibility** — routing is persisted state; resume must restore the exact
   prior receiver set / enabled flag. Use a transient overlay rule (disabled-wins)
   or store-and-restore. (Slice-flip is free today; routing is not.)
2. **No "drop one receiver" helper** — only whole-rule `disable` or whole-list
   `update_receivers`. Minor: B already locates the rule by the agent URI.
3. **Mid-turn in-flight reply** — routing only stops *new* agent turns; a reply
   already dispatched still lands. ⇒ keep a **thin output-suppression backstop**
   for the in-flight window. The Phase-2 shape is therefore *hybrid*: routing
   reconfig (no new agent turns, copilot-capable) + a small suppression net.

## Trigger to revisit
Build the routing version when **Copilot** enters scope (or when the wasted
per-turn agent LLM call on a busy takeover becomes a measured cost). Until then,
#526's Mode-suppression stands.
