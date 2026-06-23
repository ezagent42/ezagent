# dev-together plan — 2026-06-24

```yaml
planned_at: 2026-06-24
lead: Allen (林懿伦)
timezone: GMT+9 (lead) / authored CST
day_deadline: end of 2026-06-24 working day
theme: human/manual full-flow run-through of ezagent (end-to-end product validation)
base_main: c14b5df5  # post arch-debt close (oversized 3→0)
```

## Theme & why

Allen's call: **tomorrow's focus is "人肉跑通 ezagent 的全流程"** — a human-driven,
end-to-end manual run of the whole product, on a fresh disposable stack, capturing
evidence at every leg. This is **validation, not feature work**: the goal is to find
where the real production flow breaks for a new operator, not to ship new code. Any
code task this day is a *fix surfaced by the run*, branched off the leg that found it
(per `feedback_e2e_faces_production` + `feedback_e2e_failure_earns_unit_test`).

The day is structured as **ordered validation legs** (L0→L7). Legs run **serially**
(each depends on the previous leg's durable state); the only parallelizable work is
agent-side prep (L0) and per-leg evidence capture.

## Standing rules for the run (from memory)

- **Disposable stack only** — fresh `EZAGENT_HOME`, `PORT=10044`, dev mode,
  Tailscale-reachable (`100.64.0.27`). Never the shared dev/prod node.
  (`feedback_e2e_in_docker_fresh_seed`, `project_disposable_stack_e2e`.)
- **agent-browser first** — every UI leg opens a headless Chrome + screenshot
  BEFORE asking Allen to look; log forensics is step 2.
  (`feedback_agent_browser_debug`, `feedback_open_terminal_first_when_debugging`.)
- **Self-generate test creds** — bootstrap admin token + mint test users; never ask
  Allen for passwords. (`feedback_self_generate_test_credentials`.)
- **Fix the production flow, not the harness**, when a leg fails; each distinct bug
  earns a fast regression test before the fix lands. (`feedback_e2e_failure_earns_unit_test`.)
- **Node needs proxy env** (`HTTPS_PROXY`, `NO_PROXY=feishu/localhost`) so agent
  claude/codex inherit it. (`feedback_agents_need_proxy_env`.)

## Validation legs

| Leg | Scope (the flow leg being proven) | Driver | Owned surface | Evidence (DoD) | Required reading |
|---|---|---|---|---|---|
| **L0** | Bring up a fresh disposable stack: host repo + fresh `EZAGENT_HOME` + `PORT=10044` + dev mode, Feishu WS connected, `claude`/`codex`/`uv` resolvable, proxy env set | agent (Claude) | infra only (no app code) | `mix ezagent.health` green + `docker`/host up screenshot + WS-connected log line | `docs/guide/*e2e*`, `project_disposable_stack_e2e` |
| **L1** | New-user **registration → email+password login** → lands on world UI | human + agent-browser | — | agent-browser screenshot of post-login world UI; minted test user documented in `returns/` | `#87` login flow |
| **L2** | Create **workspace + agent** via the world agent-create/config UI (the #905 agent-contract MVP path) | human + agent-browser | — | screenshot of created agent detail page; agent URI captured | #905 return |
| **L3** | **Bind a Feishu chat** to the session (one binding) + verify inbound reaches the session | human (Feishu) + agent | — | inbound message → session log line; Feishu ack screenshot | `project_docker_dev_dedicated_feishu_app` |
| **L4** | **cc agent round-trip**: `@`-mention → orchestrator/session → cc PTY reply back to Feishu | human (Feishu) + agent-browser | — | agent-browser PTY screenshot + cc reply visible in Feishu (the ESR e2e standard sign-off) | `feedback_esr_e2e_standards` |
| **L5** | **codex + curl flavor** round-trips (the #907 headless/remote flavors + protocol-api path) | human + agent | — | per-flavor reply screenshots; protocol-api `/v1` call returns | #907 return, `e2e_init_protocol_api.sh` |
| **L6** | **Multi-agent relay** (sender-locked relay / scenario-34) end-to-end through bound Feishu group | human + agent | — | relay chain replies in order; no baton tokens | `project_relay_routing_via_sender_rules`, scenario-34 |
| **L7** | **world page-render** (hello @json-render) + customer public view | human + agent-browser | — | rendered page screenshot (operator + customer SPA) | #910 world↔hello, hello i18n (#91) |

> All legs are **DoD = a captured artifact** (screenshot/log line), saved under
> `docs/together/2026-06-24/evidence/L<n>/`. A leg is "green" only with its artifact.

## Conflict map

This is a **single serial validation run on one disposable stack** — there is no
parallel multi-file editing, so the usual cross-task file-conflict map is N/A.
The only shared resource is **the disposable stack itself** (one stack, one runner).
If a leg surfaces a code fix, it gets its own per-task branch off `main` named
`fix/<leg>-<symptom>` and goes through the normal precommit + `--admin` merge; only
then does the run resume from that leg (re-seed the stack to avoid polluted state).

## Human-assist steps (flagged per `feedback_flag_user_assist_steps`)

- **L1/L2/L7** — Allen drives the browser interactions (or confirms the agent-browser
  screenshots). Agent pre-captures every screenshot first.
- **L3/L4/L6** — Allen sends the real Feishu messages from the bound group (inbound
  can only originate from a human in Feishu). Agent seeds + verifies the routing.
- Everything else (stack bring-up, cred minting, evidence capture, log forensics,
  any code fix) is agent-doable.

## Parallel / background tracks (NOT the day's focus — pick up only if the run blocks)

These are the deferred items from the 2026-06-23 close review; they are **separate
deliberate tracks**, explicitly NOT folded into the manual-run day:

1. **#55 undocumented_public_defs 392 burn-down** — deliberate, codex-reviewed,
   batched @doc campaign (docs must be code-verified — no mass sweep).
2. **Plugin-owned resource-type registration** on `Resource.FsResolver` → then migrate
   world `layout_dir` off raw `Home.path` (unblocks `raw_home_path_outside_core` 2→1).
   Spec-worthy; see close review §5.
3. **i18n umbrella-wide anti-CJK gate widening** (`CjkLiteralGateTest.@scanned_globs`).
4. **cross_file_duplicate_fn_groups 32 audit** — enumerate sanctioned-vs-dedupable
   before any dedup (not yet audited).

## Intended handoff order

L0 (agent prep) → then serial L1…L7 driven with Allen. No handoffs are generated up
front — this is a co-driven run, not a fan-out of independent dev tasks. If a leg
spawns a code fix, *that* becomes a normal handoff/branch at that point.
