# Return: cc-headless real implementation

> **Task:** cc-headless real implementation (gaga's 2026-06-24 AM track)
> **Dev:** gagameow (@黄佳佳)
> **PR:** [#931](https://github.com/ezagent42/ezagent/pull/931) · **Branch:** `agent-flavor-headless-cc-headless-impl`
> **returned_at:** 2026-06-24 (AM) · **deadline_status:** on_time
> **Status:** ✅ DONE — pending lead verify (precommit both-signal + codex core-review) before close/merge.

## Summary

Completes `cc-headless` from the prior placeholder/fake-SDK stub into a **real Claude Code Python SDK sidecar** implementation. The flavor is now a session-capable, no-PTY Claude agent (the 3A route from `docs/together/2026-06-23/handoffs/cc-headless-real-implementation.md`; 3B `server:esr-bridge`-no-PTY was verified not viable).

## What landed

- **SDK sidecar process** — the real no-PTY Claude Code Python SDK backend.
- **cc-headless Agent behavior** (`apps/ezagent_domain_agent/lib/ezagent/behavior/cc_headless_agent.ex`) — cc-headless joins the Agent Kind as an explicit flavor behavior.
- **Session-reply writeback chain** — replies route back to the session.
- **fake SDK** (test double) + **real E2E seed + screenshot evidence**.

## Core/domain changes (why a flavor needed them)

cc-headless must be an explicit flavor behavior on the Agent Kind, so the PR includes minimal core/domain edits:
- register the new slice owner;
- extend the Agent behavior **superset** to include cc-headless;
- make `receive`/`delivery` dispatch the synchronous result to cc-headless's **own** behavior, instead of reusing the curl-specific path.

Files: `entity/agent.ex`, `behavior/agent/{receive,delivery}.ex`, `behavior/cc_headless_agent.ex`, `ezagent_core/.../kind/behavior_set.ex`, arch-baseline manifest + `arch.scan` + `single_spawn_entry_test`.

## Verification (dev-reported)

- `ezagent_plugin_cc` tests pass.
- Full `mix precommit` run: cc side passes; two pre-existing `ezagent_web` full-load-flaky cases passed on an isolated `--failed` rerun.

## Lead close gate (this session)

Independent re-verification before merge: `mix precommit` EXIT=0 **AND** grep-confirmed every suite 0 failures; `mix ezagent.check_invariants` EXIT=0; **codex adversarial-review of the core/domain diff** (routing-correctness for cc/codex/curl/echo + the arch-baseline bumps must be real debt, not a masked regression). Then `--admin --squash` merge.
