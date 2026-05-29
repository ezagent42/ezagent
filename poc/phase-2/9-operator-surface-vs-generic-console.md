# Operator surface vs. the generic `/sessions` console — design discussion

> Decision record (2026-05-29). Triggered by a sharp user observation:
> the admin, logged in, can already see ALL customer conversations and
> their transcripts via the generic `/sessions` console (session picker
> top-left → transcript). So what does our custom operator dashboard
> (`/admin/customer_sessions`) actually add? **Outcome: record the
> analysis; defer implementation.** PR #446 unaffected.

## Verified facts (grounded in code)

- **`/sessions` = `AdminLive`** (router L141) — ezagent's *pre-existing,
  generic platform console*. Operates ANY session of ANY kind as a
  **member**, and exposes 路由 / Bindings / 终端 / Members tabs. Built for
  the *platform-admin* persona.
- **Our dashboard** = `CustomerSessionsDashboardLive` (`/admin/customer_sessions`)
  + `CustomerSessionViewLive` (`/admin/customer_sessions/:id`), router L270–271.
- **`Ezagent.Behavior.Mode`** implements only `:auto` / `:takeover`
  (`:copilot` reserved; enum intentionally open). There is **no
  AI-initiated "request human" state**.
- **The dashboard renders no escalation / priority / alert** signal
  (grep clean). Only a mode badge (Auto/Takeover) + last-message preview
  + timestamp.

## What genuinely overlaps (user is right)

The **read/browse half** of our dashboard — "list all customer sessions +
read a transcript" — is largely redundant with the generic `/sessions`
console, which already does exactly that for any session.

## What does NOT overlap (the dashboard's real, narrow value)

1. **Take over ≠ send a message.** The "Take over" button dispatches
   `mode.set {mode: :takeover}`, which:
   - (a) **gates AI fan-out** — `Chat.send` suppresses the cc agent's
     replies while mode is `:takeover` (the AI goes silent), and
   - (b) **posts the `(客服已接管对话)` notice** to the customer.

   If an operator instead just *types into the customer session via the
   generic `/sessions` console*: the message DOES reach the customer
   (same session-topic broadcast the customer LiveView subscribes to),
   **but the AI is NOT silenced and no handoff notice fires** — you'd get
   the human and the AI both replying, and the customer never sees a
   "human took over" cue. So the generic console *cannot* perform a
   takeover; it can only inject a message. **This mode mechanism is the
   dashboard's core, non-redundant value.**

2. **Support-queue shape.** A CS operator wants a triage queue (who's
   waiting, last message, recency, mode, eventually a "needs human"
   priority), not a URI dropdown. `/sessions`' picker is a flat list of
   session URIs with no preview/recency/mode — fine for a developer
   inspecting one session, poor for an operator scanning many waiting
   customers.

3. **Escalation signal — NOT built.** The highest-value missing piece the
   user identified: when the AI can't handle something, it should flag
   the operator (tag / colour change) that a human is needed. Today Mode
   is operator-initiated only; there is no AI→human request path and no
   dashboard highlight.

## Folding recommendation — layered, not binary

The genericity concern is real but cuts differently per piece:

| Piece | Fold into generic `/sessions`? | Why |
|---|---|---|
| **Mode badge + Take-over toggle** | **Yes — but conditionally** | Render the badge + toggle *iff the session carries a `:mode` slice* (i.e. the Mode behavior is installed). The console then reflects *whatever Behaviors a session has*, never hardcoding "customer service." A peer-agent or system session has no `:mode` slice → no toggle. This is generic-preserving and matches ezagent's "console renders capabilities, not business types" philosophy. |
| **Support-queue / triage view + escalation-priority sort** | **No** | This is customer-service-SHAPED product UI (assumes the customer↔AI+human-fallback shape). Folding it into the platform console would teach core about "customers" and "support queues" → reduces genericity. Belongs in the future `ezagent_plugin_customer_chat` as its **operator surface**. |
| **Escalation primitive (AI requests human)** | **New primitive first** | The *capability* — a session can carry "human requested" — is generic to any human-fallback business → belongs in `ezagent_domain_chat` / Mode (e.g. a new `:escalation_requested` mode, or a separate slice flag the AI can set via a directive). The *highlight UI* then lives in whichever operator surface (queue or console). |

## Persona distinction (independent of genericity)

Even setting genericity aside, `/sessions` and a CS dashboard serve **two
different personas**:
- **Platform admin** (`/sessions`) — full power: routing, bindings,
  terminal, membership. Footguns a CS operator shouldn't have.
- **CS operator** (dashboard) — a narrow, safe, queue-shaped surface.

So there is a product argument for a separate, narrower CS operator
surface regardless of the generic-vs-specific code argument. For this PoC
(one person doing both) the overlap is tolerable; at template-extraction
time the two personas diverge.

## Decision (this round)

**Record only; do not implement now.** PR #446 stands as-is. When the
operator surface is next picked up, the target end-state is:

1. **Build the escalation primitive** in `ezagent_domain_chat` (Mode gains
   an AI-settable "human requested" state/flag + a cc-emittable directive).
   — highest value, genuinely missing.
2. **Fold the Mode badge + take-over toggle conditionally into the generic
   `/sessions` console** (render iff `:mode` slice present). — generic-
   preserving; lets the redundant read/browse half of our dashboard slim
   down or retire.
3. **Keep the queue/triage + escalation-priority view as the operator
   surface of `ezagent_plugin_customer_chat`** — NOT in core.

This keeps ezagent's platform console domain-agnostic while giving the
customer-service template a purpose-built operator surface, and closes the
one real capability gap (escalation) the current dashboard lacks.
