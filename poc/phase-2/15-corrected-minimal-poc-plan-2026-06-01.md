# Corrected minimal PoC plan — validate AutoService→ezagent migration, minimally

> 2026-06-01. **Course-correction.** Earlier this session I recommended making the
> `autoservice` (B) plugin canonical and *merging* the colleague's fast-agent +
> `configure` machinery with our `customer_chat` (A) work. That optimized for
> "best production architecture" — the wrong goal. **The PoC's job is to validate
> migration feasibility with minimal code and minimal core changes, and to *learn*
> cleverer native expressions from the colleague's work — not to absorb their
> plugin.** This doc re-anchors on that. Supersedes the B-canonical framing in
> `13-pr-split-plan` for the *plugin* decision (the generic primitives — Mode,
> bridge fix — and the takeover/orchestrator learnings still stand).

## 1. PoC principles (the red lines we drifted from)
1. **Minimal code.** Smallest slice that proves the capability migrates.
2. **Minimal core/domain change.** Prefer composing existing ezagent primitives.
   When a core/domain change is genuinely needed, make it on our branch and
   **flag it in the PR comment for Allen to approve or send back** — don't merge
   core changes silently.
3. **Borrow, don't absorb.** The colleague's `feat/autoservice-cinnox` (hjj) is a
   **reference** for native patterns; we cite/learn from it, we do not merge it.
4. **Surface decisions for the core team.** Every "native primitive vs custom
   workaround" fork is a documented question for Allen — that *is* the PoC's
   highest-value output.
5. **Lose no one's work.** Verified: all our open PRs (#511/#512/#515/#525/#526)
   are 100% our commits; hjj's work lives only in `feat/autoservice-cinnox` + #510.
   Nothing of anyone else's is embedded in our branches.

## 2. Base decision
**Base = our own `customer_chat` (A), cc/claude-based**, on the
`poc/phase-2-customer-service` branch (the old #446 source). Rationale: it's ours,
we fully understand it, the cc bridge-JOIN blocker is now **fixed** (#524 cherry-
picked into the branch), and its soul model is already designed
(`11-admin-edit-soul-design.md`). We do **not** introduce the colleague's curl
fast-agent + `configure` (that complexity — live-agent enumeration, privileged
push, partial-failure — was all downstream of a hot-update goal the PoC doesn't
need).

The `autoservice` (B) split PRs I made this session (#525/#526) are **superseded**
by this re-anchor; close them (all our own commits — nothing lost). #511 (Mode)
stays — it's the generic takeover primitive, used by A too.

## 3. Capabilities × native mapping (what the PoC demonstrates)

| Capability | A's implementation | Native ezagent primitive used | Verdict |
|---|---|---|---|
| **Customer web chat** | `ChatLive`/SSE/widget; synthetic anonymous customer; per-conv `session://` | `Session` + `Chat` Behavior + **native mention-routing** (`$session_users`/`$mentions` default rule) | ✅ native; keep |
| **Customer→agent delivery** | synthesize `mentions:[cc_uri]` so the default rule fans out to the agent | rides the native `Routing.Resolver` default rule | ✅ minimal/native (a synthesized @, not a custom router) |
| **Soul edit** | `SoulStore` file (edited→fixture→prev, undo/reset) + `ConfigAuth` cap gate; cc reads it at spawn via `--append-system-prompt-file` | cc template's existing `soul_path` → `--append-system-prompt-file`; the **capability model** for the gate | ✅ native; keep (`11-admin-edit-soul-design`) |
| **Operator takeover** | `Behavior.Mode` (#511) `:set :takeover`; `Chat.handle_send` suppresses agent-sender msgs | a native **Behavior + slice** primitive **+ 1 small core hook** | ⚠️ native primitive, but the Chat hook is a **core change → Allen** (§5) |
| **Agent lifecycle** | per-conv **ephemeral** cc (`create_agent` + `remove_template` + GC) to dodge boot-restore | fights the framework's boot-restore | ⚠️ the one real **reinvent-the-wheel** spot (§4) |

## 4. The one reinvent-the-wheel spot: ephemeral cc lifecycle
A spawns a fresh cc per conversation, then `remove_template`s to suppress
boot-restore and GCs the leftovers — a whole custom subsystem
(`2026-05-30-ephemeral-cc-agents-design.md`). The colleague's autoservice solved
this natively: a **long-lived agent provisioned as a workspace template that
rehydrates at boot** — no ephemeral spawn, no GC.

**Decision for the PoC: KEEP A's ephemeral lifecycle as-is (it works post-bridge-
fix), and DOCUMENT the native long-lived/template pattern as the recommended
productization improvement + an Allen decision-point.** Reason: a direct port of
the long-lived pattern collides with A's *anonymous-per-chat-open* customer model
(no persistent customer URI to anchor a long-lived agent), so adopting it is a
non-trivial redesign — out of scope for a *minimal* feasibility PoC. We surface it
as a finding, not a refactor. (This is exactly the "borrow as learning, not as
merge" principle.)

## 5. Core / domain changes requiring Allen's review
Flag each in its PR comment; Allen approves or sends back:

1. **`Behavior.Mode` + `Chat.handle_send` takeover gate** (#511). The Mode Behavior
   is a clean native primitive; the suppression hook in core `Chat` is the change
   to vet. **Attach the zero-core alternative** (§6) so Allen chooses the
   direction.
2. *(none others required for the minimal slice)* — soul-edit, customer chat, and
   the cap gate all compose existing primitives with no core change.

## 6. Takeover: the design decision to hand Allen
Two native ways; the PoC demonstrates #1 (already built) and documents #2:

| | core change | plugin complexity | agent wastes a turn? |
|---|---|---|---|
| **#1 Mode behavior (#511)** — slice + `Chat` suppression | 1 (Chat hook) | low (flip a slice) | yes (reply dropped at fan-out) |
| **#2 Pure routing (doc 14)** — disable the customer→agent rule, route customer→operator | **0** | medium (rule mgmt, reversibility, mid-turn race) | no (agent never receives) |

Full analysis: `14-takeover-routing-evolution`. Routing is the **only abstraction
that also expresses Copilot**. We don't build both — we ship #1 and ask Allen
which direction ezagent should standardize on (and whether the Chat hook is
acceptable or should be replaced by #2).

## 7. Borrow-as-reference (cite, don't merge)
From `feat/autoservice-cinnox` / #510, documented as learnings:
- **Long-lived template agent** (vs A's ephemeral) — §4.
- **Explicit routing rule** for customer→agent (vs A's mention-synthesis) — enables
  the routing-takeover path.
- **URI-as-SoT + reconciler facade** (`Uris`, `customer_session.provision`) — cleaner
  composition; cite as the idiomatic shape.

## 8. PR split (small, human-reviewable)
Re-using what already stands; closing the autoservice ones:
- **Keep**: #511 `feat/takeover-mode` (generic Mode primitive — Allen-flagged).
- **cc-agent bring-up block**: consolidate theme-picker PTY + OAuth + EagerBridge
  (currently #512 partial + the #524 fix now in the branch) into **one** PR
  (coordinate with hjj per #524's close note / the #510 4-track plan).
- **Close**: #525 / #526 (autoservice split — superseded by this re-anchor; our
  commits only).
- **New, small, on A**: (a) customer chat + cc lifecycle (as-is) + native mention
  routing; (b) soul-edit (`SoulStore`/`ConfigLive`/`ConfigAuth`, file model);
  (c) operator takeover (wire A's Take-over button to the real Mode #511).
- **#515** formatter: keep (trivial).
- Coordinate granularity with hjj (his #510 4-track plan targets the same
  convergence) — avoid duplicate plugin PRs.

## 9. Testing + demos
- Unit: `SoulStore` resolution/undo/reset; `ConfigAuth` cap matrix; Mode takeover
  scenarios (already in #511).
- e2e (post bridge-fix): browser — open `/chat/acme`, send, get a cc reply; edit
  soul → new conversation reflects it; operator Take-over → customer sees operator,
  AI suppressed.
- **Demos** (3, on `acme`, after the slice lands): customer chat / operator
  takeover / soul edit. Re-record via `scripts/demo/record-clean.sh`.
  Recording prereq: cc template must use `~/.claude` or an `api_key_helper`
  (fresh per-agent `CLAUDE_CONFIG_DIR` hits the 2.1.92 OAuth screen — see #524).

## 10. Out of scope (explicitly NOT doing)
- Curl fast-agent + `configure` hot-update (the absorbed-complexity we backed out).
- Live-session hot-update of souls (new-conversation propagation is enough).
- Copilot mode (routing groundwork documented only).
- cc "slow"-agent-only-vs-fast unified soul mechanism.
- Long-lived/template lifecycle refactor (documented for Allen, not built).
- Merging `feat/autoservice-cinnox` code.

## 11. Open sub-decisions (confirm before plan)
- **Demos blocked on which slice?** The soul demo needs the soul-edit slice; OK to
  record after (b) lands.
- **cc-bring-up PR ownership** — ours or hjj's (per #510). Coordinate.
