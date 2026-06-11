# Socialware Substrate — E2E Acceptance Gate (the FINAL gate for 基座化)

> **STATUS: the pinned acceptance gate.** Approved by Allen 2026-06-10 as the single end-to-end gate that declares the socialware-substrate reconstruction (P0–P5) DONE. This is the TDD acceptance test for the whole phase: it is RED until P3 (ExternalAdapter) + P4 (chat external SPA) land and the customer-delivery path is wired end-to-end on a live disposable stack; the substrate is "done" when it is GREEN.

This gate is **a superset of what a human reviewer would check**, and **ergonomic** (paste-able commands, no manual UUID/long-string typing) — per the project's goal-verification standard. It runs on an **isolated, fresh-seeded disposable stack** (never shared dev/prod), reachable over Tailscale `100.64.0.27`, and uses **agent-browser screenshots** as the load-bearing visual proof (the project's §36 E2E standard).

---

## Why THIS scenario is the gate

The substrate's headline claim is: *"any session becomes an external SPA via composable behaviors + a durable customer-delivery channel, with verticals as Templates."* The SW-USE customer-delivery flow is the single path that exercises EVERY load-bearing layer at once:

| Layer | Phase | Exercised by the gate |
|---|---|---|
| Publisher-as-base behavior | P0 | the socialware session records a trunk event |
| per-instance behavior-set enforcement | P1 | the socialware-template instance allows `surface.*`/`turn.*`; a chat instance denies them |
| unified view contract | P2 | the customer projection + the operator projection are two Views on one session |
| transactional customer-delivery outbox | P2.5a/b/c | the customer-visible surface delta is delivered ONLY after the parent turn AND the settlement durably commit, in commit order, replayable by cursor |
| ExternalAdapter (push/pull) | P3 | the customer SPA is served by a `:pull` adapter over the committed-delivery cursor |
| chat external SPA view | P4 | the same `:pull` SPA machinery renders a chat session (generalization proof) |
| collapse to one Kind | P5 (if shipped) | the P1 denial invariant holds on the unified Kind |

If this scenario is green, all of the above are working together. That is the definition of "基座化 done."

---

## Disposable stack recipe (the harness — never touch dev:10042 / prod:10043)

Stand up a fresh, isolated stack from the host repo (per the proven recipe):

```bash
# 1. Fresh isolated EZAGENT_HOME + a free port, dev mode, Tailscale-reachable.
export EZAGENT_HOME="$(mktemp -d /tmp/sw-e2e-home.XXXXXX)"
export PORT=10044
export PHX_HOST=100.64.0.27
# dev mode so the stack is reachable at http://100.64.0.27:10044 over Tailscale
# (NOT localhost — the operator is remote).

# 2. Init + migrate the disposable DB, then SEED the substrate scenario fresh.
mix ezagent.home.init
MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
mix ezagent.demo.seed_socialware_substrate   # see "Seed" below — fresh each run

# 3. Boot with the proxy env on the node (agents inherit HTTPS_PROXY;
#    NO_PROXY covers feishu/localhost) so in-session cc/codex agents can reach
#    their APIs (missing proxy => 403, NOT a cred bug).
HTTPS_PROXY=$HTTPS_PROXY NO_PROXY=$NO_PROXY PORT=$PORT PHX_HOST=$PHX_HOST mix phx.server
```

> **Two-BEAM trap:** create the scenario via the LiveView UI or a single seed task, NOT a standalone CLI run against a separate BEAM — two BEAMs sharing one Feishu app round-robin WS events and silently drop ~50%. The disposable stack owns its own (dev) app_id.

**Seed (`mix ezagent.demo.seed_socialware_substrate`, fresh each run) — flag every human-assist step:**
1. a non-admin author user (`e2e-author`) — bootstrap a temp token + `set_password` (NEVER ask Allen for a password).
2. a socialware session created via the **blessed** unified-Template create chokepoint (the SW-USE template), owned by `e2e-author`.
3. a customer principal (`e2e-customer`) able to open the customer SPA via `CustomerAuth` (the customer token / magic link — paste-able URL emitted by the seed).
4. **[HUMAN-ASSIST, if any]** the seed prints the customer SPA URL + the operator LiveView URL + the author/customer login URLs. No manual UUID typing — all URLs are paste-able.

---

## The scenario (steps)

1. **Author drives an SW-USE turn.** As `e2e-author`, open the session's operator view (`http://100.64.0.27:10044/...`) and run an auto-or-copilot turn that produces BOTH:
   - a `customer_visible` surface delta (e.g. an updated customer-facing config/answer), AND
   - an `operator_only` artifact in the same turn (e.g. an internal note / reasoning the customer must never see).
2. **Settlement commits.** The turn settles → the surface version is approved + committed → the customer-delivery outbox row is committed (committed_seq assigned). (P2.5c ordering: the delivery cannot precede the parent-turn commit.)
3. **Customer opens the external SPA.** As `e2e-customer`, open the customer SPA URL (the `:pull` `customer_feed` adapter, served over its Phoenix channel) at `http://100.64.0.27:10044/...`.
4. **(P4 generalization)** Open a CHAT session's external SPA via the SAME `:pull` machinery (`chat_feed` adapter) as a member; confirm a non-member is denied.

---

## Acceptance criteria (ALL must hold — agent-browser is the load-bearing proof)

The agent launches headless Chrome from the agent side FIRST (never "try it and tell me what you see"), against `http://100.64.0.27:10044`:

1. **[VISUAL] Customer SPA renders the committed delta.** agent-browser screenshot of the customer SPA showing the `customer_visible` surface delta from step 1 (json-render). The page is the external SPA, NOT the operator LiveView.
2. **[VISUAL] operator_only does NOT leak.** The SAME screenshot (or a content assertion on the same page) shows the `operator_only` artifact is ABSENT from the customer view. A grep/DOM assertion for the operator-only marker text returns nothing.
3. **[VISUAL] Operator view DOES show both.** agent-browser screenshot of the operator LiveView showing BOTH the customer_visible delta AND the operator_only artifact (the operator sees everything; the customer sees only the gated subset) — proving the two-View projection.
4. **[ORDERING] No pre-commit leak.** Re-run with the delivery injected BEFORE the settlement commit (or inspect the outbox): the customer SPA shows NOTHING customer-visible until the commit lands (the P2.5 leak test, live).
5. **[DURABILITY] Wake-up-loss safe.** Drop the advisory `{:customer_delivery}` PubSub event for one delivery; the customer SPA STILL renders it (the adapter replays from the committed cursor on the next event / on reconnect) — the P2.5b/P3 wake-up-loss guarantee, live.
6. **[AUTHZ] External read is membership-gated + revocation is live + client-visible.** A cross-scope / non-member principal opening the customer SPA URL (or the chat_feed SPA) is DENIED (the P3-3 live in-handler owner/member predicate). For the chat_feed SPA specifically: an ex-member's **rendered view CLEARS immediately on `chat.leave`** — agent-browser screenshot BEFORE (member sees the chat) and AFTER the leave (view cleared / shows "Unauthorized"), WITHOUT a subsequent chat message. This is the load-bearing client-level proof that the server's `unauthorized` push + channel close (codex P4) actually fails closed in the browser (there is no JS unit-test harness — the agent-browser screenshot IS the client-level regression; the server side is unit-tested via the channel `assert_push "unauthorized"` + close).
7. **[P4] Chat external SPA works on the same machinery.** agent-browser screenshot of a chat session rendered via the `chat_feed` `:pull` adapter by a member; a non-member denied. Proves "any session → external SPA" with no chat-specific surface code.
8. **[REGRESSION] All existing scenarios still green** on the disposable stack: chat send/receive/join/leave/owner-first-join/cap grants; socialware SW-DEV/SW-USE/SW-UPD; Feishu mirror (slice-change → adapter → Lark). Full umbrella `mix test` + arch fitness + lifecycle invariants green.
9. **[P5, only if P5 ships]** The P1 denial invariant holds on the collapsed Kind: a chat-template instance denies socialware actions; a socialware-template instance allows them. If P5 stays deferred, this criterion is N/A and the gate is still satisfied by 1–8.

**The gate is GREEN iff criteria 1–8 hold (9 only if P5 ships).** Screenshots for 1, 2, 3, 7 are attached to the Feishu thread as the human-reviewable proof.

---

## Mapping to the carried-forward deterministic tests (fast pre-gate)

Before the live run, these ExUnit gates must be green (they are the cheap, deterministic half — the live agent-browser run is the expensive confirmation):
- P2.5 **leak test** (no customer_visible page/messages before commit) — `apps/ezagent_domain_socialware/test/...`.
- P2.5b/P3 **wake-up-loss test** (drop PubSub → cursor replay still delivers).
- P3 **join-race test** (commit between snapshot-content read and first replay → still rendered via the lower-bound cursor).
- P3-3 **authz-boundary test** (chat `kind: :session` cap cannot read SocialwareSession internal slices; nil/ownerless/ex-member denied).
- The P1 **instance-set denial test** (and, if P5 ships, on the collapsed Kind).
