# Close-review addendum — audit of the 2026-06-24 dev cycle (other problems)

> Per @林懿伦 (2026-06-24, after the dev-together skill update landed): "再检查昨天的开发过程还有哪些问题." Four parallel read-only audits applied the **new four-property-DoD lens** (stub remnants / wrong-layer or one-shot verification / deferred-but-claimed-done / goal divergence) to the cycle's agent-authored work. This is the `review` *method-deltas* step closing the loop.

## Audit results

| Task | Dev | Verdict | Summary |
|---|---|---|---|
| **#931 cc-headless real** | gaga | ✅ **complete** | The spawn-STUB ("returns success without starting Claude") was genuinely replaced with a real Python `claude-agent-sdk` subprocess sidecar, wired into the real spawn + receive path; a real Claude turn is demonstrated (unique-ID marker in the reply, not the fake-worker echo). |
| **#938 agent-config backend** | gaga | ⚠️ **has-defects → fixing** | Facade ops are real + cap-gated, BUT `delete_path` had a confirmed existence info-leak (#958); missing delete_path/repoint denial tests; echo-has-no-config (#918) undocumented. |
| **#918 echo→Entity.Agent** | fatnine (OPEN PR) | ⚠️ **stale/conflicting** | Internally goal-complete + well-verified, but 37 commits behind main with a real design conflict vs #957 (LocalRuntime isolation). Needs rebase + a LocalRuntime decision. |
| **zyli 人肉 full-flow** | zyli | ✅ **completed-with-evidence** | 7 legs (L1–L7) all evidenced, the create-session crux confirmed cleared (downstream of #939), proper return + ledger. L3/L4 are 🟡 due to **product UI gaps** (surfaced, not validation failures). |

### #931 — complete (no action)
Real `EzagentPluginCc.SdkSidecar` GenServer `Port.open`s the Python worker (`priv/python/ezagent_cc_sdk_worker.py`, `claude-agent-sdk`); `cc_headless_agent.ex` calls `ensure_sdk_sidecar` on spawn (no success-without-launch path); receive routes `:in_process_sync` → `CcHeadlessBridgeAdapter.deliver` → sidecar → `:cc_headless_sync_result` writeback. Real-SDK E2E is a manual opt-in (`CC_HEADLESS_E2E_REAL_SDK=1`) with a committed proof screenshot; CI tests use the fake worker. **Note (not a gap):** a real-Claude regression isn't caught by `mix test` alone — expected (needs creds), manual evidence exists.

### #938 — defect fixed this session (PR #966)
- **`delete_path` existence info-leak (#958), CONFIRMED real + now fixed:** it read the body (`layer_body` → `:config_not_found`) + computed the delete (`:path_not_found`) **before** the gated `apply_config_delta` dispatch, so an uncapped caller could probe field existence. Latent today (the console→facade `agents.config.*` wiring isn't open — see #93). Fixed by an auth preflight (probe the already-gated `read_cascade`, same manage-cap) before any existence read → uncapped callers fail closed with `:unauthorized`. + delete_path/repoint denial tests (the audit found them missing). **→ PR #966.**
- **Echo has no config backend** (separate Kind, no `ConfigEvolve`) is real and is exactly what #918 fixes — but it was silent (undocumented). Captured here.

### #918 — fatnine's to rebase+reconcile (NOT taken over — per-task ownership)
- 37 commits behind `origin/main`; `git merge-tree` shows conflicts in 5 echo/agent files; **#958 (agent-console) does NOT conflict**.
- **Blocker = design conflict with #957 (LocalRuntime isolation, merged today):** #957 routed echo's spawn through URI-only `LocalRuntime.ensure_started/1`; #918 rewrote the same spawn to `Ezagent.Kind.spawn(Entity.Agent, init_args)` to thread `behaviors: echo_behaviors()`. `LocalRuntime` has **no args/behaviors arity**. Reconciliation needs a decision: **extend `LocalRuntime` with a behaviors-threading spawn**, OR a sanctioned exception for echo's `Kind.spawn`. Then re-ratchet the arch `spawn_registry_call_sites` cap. **This is the same LocalRuntime-args question as #99** (below) — resolve once, apply to both.
- Otherwise #918 is goal-complete (echo gains Identity + ConfigEvolve; echo-on-receive via the `:in_process_sync` adapter; `soul` in cc create with a real CLAUDE.md-on-disk e2e). Documented limitation: echo's `:count`/`:last_msg` slice isn't updated on a bridge `:receive` (reply fires; counter stale) — accepted A7 follow-up.
- **Punch-list for fatnine:** rebase onto current main; resolve the #957 LocalRuntime conflict per the decision above; re-ratchet arch caps; re-run `mix precommit` to EXIT=0 on the rebased tip (now CI-enforced).

### zyli — complete; surfaced real product gaps (route to backlog)
The validation itself is done + recorded. It surfaced product UI gaps that are NOT zyli's bugs but real backlog: **F9** (no UI to bind a Feishu chat → session), **F10** (no UI to add an agent API key), **F12** (Feishu `@` not parsed into an agent mention). L3/L4 only verified segment-by-segment via authorized DB workarounds because of these. → these should become explicit tasks (they block goal ① "team uses ezagent daily").

## Net new actions from this audit
- **#966** (this session): #938 `delete_path` auth fix + tests.
- **fatnine:** rebase + reconcile #918 vs #957 (LocalRuntime args decision).
- **backlog (new):** F9 / F10 / F12 product-UI gaps from zyli's run.
- **#918 ⊗ #99 shared decision:** does `LocalRuntime` get a behaviors-threading spawn arity? (resolve once.)
