# Post-Phase-5 meta-report (2026-05-17)

**Context:** After Phase 5 closed (PRs #27–#43), Allen drove four follow-up rounds the same day: Feishu Receiver Kind refactor (Plan B), CLI HTTP shell, CLI RPC repivot, PTY agent_uri fix. This doc captures what changed, current LOC, dead-code scan results, and what the canonical docs (ARCHITECTURE / GLOSSARY / ROADMAP) need to absorb.

## 1. Dead-code scan result

After today's commits, only one **real bug** surfaced:

- `EzagentPluginFeishu.WebhookPlug.lookup_session_for_chat/1` was scanning the deleted `EzagentPluginFeishu.SubscriberSupervisor` (gone in Plan B PR #45). Rewrote to reverse-lookup via routing_rules table — matches the new source of truth. **Inbound Feishu webhook hasn't been tested with real Feishu inbound yet**, so this was silent until the audit.

Cleaned-up dead helpers:
- `Ezagent.Entity.User.admin_caps?/1` — added for HTTP-CLI JSON encode (PR #48), orphaned by RPC pivot (PR #50). Removed.
- `EzagentCli.Formatter.render_to_string/2` — back-compat alias for the IO-side-effect render. The pure-data `render/2` is the one path; alias removed, callers inlined.

Stale comments updated in: PtyServer moduledoc, PtyServer in-code "PR A.2" annotations, EzagentCli.Exec moduledoc, Ezagent.Entity.Agent moduledoc, CcBridgeAnnounceController moduledoc, cc-pty mix.exs comment, dev_channels_confirm_test comment.

No remaining orphan modules. `grep -rn 'CliController\|InvokeController\|OutboundSubscriber\|Ezagent.Invocation.JSON' apps/` returns zero hits in code (only historical mentions in design docs, which is correct).

## 2. Current LOC

```
apps/ezagent_core/lib                          6918
apps/ezagent_cli/lib                            938
apps/esr_plugin_chat                       1186
apps/ezagent_plugin_cc                      753
apps/ezagent_plugin_cc                  277
apps/ezagent_plugin_cc_bridge_v1_prototype      462
apps/ezagent_plugin_echo                        144
apps/ezagent_plugin_feishu                      773
apps/ezagent_web/lib                           1553
apps/ezagent_web_liveview/lib                  2849
                                          -----
  umbrella lib total                      15853

apps/*/test                                7555
docs + phase-specs (md)                    5671
```

ARCHITECTURE.md §14 LOC budget references `ezagent_core target ~870 LOC` for "core only" (Phase 2 v0.4 budget). Today's `ezagent_core` is 6918 — but that includes a lot of impl that's not "core abstraction layer" (Audit / KindSnapshot / RoutingRegistry tables / Identity / Capability / Workspace.Store / Loader / Snapshot.Writer / Pty.Input synthetic Kind / RoutingAdmin synthetic Kind / etc). The §14.y note already acknowledged "ARCH 920 is design SLOC, not file LOC ceiling". Today's number is consistent with that framing.

**Plugin LOC totals** show the plugin north-star working: external integrations (cc-channel 277, cc-bridge-v1 462, feishu 773, echo 144) all small and self-contained.

## 3. ARCHITECTURE.md updates needed

### 3.1 New Decision Log entries (#127–#131)

- **#127** Receiver Kind contract for external integrations. (Memory `feedback_plugin_external_integration_is_receiver_kind`; docs/notes/plugin-receiver-kind-contract.md; CI invariant `receiver_kind_pattern_test.exs`.) Per Allen 2026-05-17 incident: PR 6 first impl used PubSub-subscriber side-channel; refactored to FeishuChat Kind + chat/receive Behavior bound by routing rule.

- **#128** `in_session(session_uri)` matcher — scopes routing rules per-session. Plan B addition because Feishu binding needs per-session granularity (otherwise rules fire globally).

- **#129** Chat.invoke(:send) uses stored_msg (with session_uri stamped) for Resolver — bug surfaced by in_session matcher introduction; fixed in PR #46.

- **#130** CLI is distributed-Erlang RPC client to the running runtime, NOT HTTP. Single-machine assumption. (Allen 2026-05-17 second pivot.) Future remote = runtime↔runtime federation. `Ezagent.Runtime` module + `~/.ezagent/<profile>/runtime/cookie`.

- **#131** PtyServer passes agent_uri through mcp.json (not env-var passthrough through erlexec → claude → bridge). Deterministic. `McpConfigWriter.write!/1` takes `:agent_uri` opt.

### 3.2 §5.4.4 reinforcement
"Adapter is the receiver Kind" gains a concrete reference impl pointer: `apps/ezagent_plugin_feishu` + `docs/notes/plugin-receiver-kind-contract.md`. The forbidden side-channel pattern is now caught by CI (`apps/ezagent_core/test/invariants/receiver_kind_pattern_test.exs`).

### 3.3 §14 LOC budget note
Add: post-Phase-5 LOC table (above) plus the framing "ezagent_core total grew well past 920-design-SLOC because synthetic-Kind helpers (RoutingAdmin, PtyInput) + reliability primitives + UI.Form behaviour + Audit/Snapshot/Loader infrastructure all live there; ARCH §14.y "design SLOC ≠ file LOC" still holds."

## 4. GLOSSARY.md updates needed

New term entries:

- **Receiver Kind** — plugin pattern for any Kind that consumes session messages and writes externally (Feishu, future Slack/Discord/email). Implements `Ezagent.Behavior.Chat` `:receive` action; bound to sessions via routing rules. Contrast with the **forbidden** side-channel pattern (subscriber). Ref: `docs/notes/plugin-receiver-kind-contract.md`, memory `feedback_plugin_external_integration_is_receiver_kind`, CI gate `receiver_kind_pattern_test.exs`.
- **in_session(session_uri)** — Matcher constructor that gates a routing rule to messages originating in a specific session. Required for per-session bindings (Plan B).
- **EZAGENT_HOME** — runtime persistence root (`~/.ezagent/<profile>/`) containing credentials, db, snapshots, logs, plugins. See `docs/phase-specs/phase5/EZAGENT_HOME.md`.
- **Ezagent.Runtime** — distributed Erlang node + cookie management. CLI connects to `ezagent_runtime@127.0.0.1` via RPC.

Update existing entries where they reference deleted paths:
- **CC Bridge** entry should mention "PtyServer spawns claude directly; mcp.json carries agent_uri" instead of "operator runs bash cc-bridge-attach.sh".

## 5. IMPLEMENTATION_ROADMAP.md updates needed

### 5.1 §1.3 (8 hard invariants)
Add invariant #9: **CLI ↔ LV reach the same runtime BEAM**. The CLI never spawns its own VM for dispatch; it RPCs into the running runtime. Caught by `apps/ezagent_cli/test/integration/cli_lv_same_server_invariant_test.exs`.

Add invariant #10: **External-integration plugins go through Receiver Kind + routing rule**. No PubSub-subscriber + external write. Caught by `apps/ezagent_core/test/invariants/receiver_kind_pattern_test.exs`.

### 5.2 §1.4 (CLI ↔ LV isomorphism)
Strengthen the equivalence definition: it now means **same BEAM** (not just same Invocation shape). Reference: post-Phase-5 PR #48 then PR #50.

### 5.3 §8 Phase 5
Already has the "naming note" addendum. Add a second addendum referencing the four follow-up pivots:
- Plan B (Feishu Receiver Kind, PR #45)
- CLI HTTP shell (PR #48; superseded)
- CLI RPC pivot (PR #50)
- PTY agent_uri via mcp.json (PR #49)

Note that the **original** Roadmap §8 Phase 5 (Feishu adapter + CC channel production rewrite + Pty-Web) is **largely done** by the combined phase4.5 + post-Phase-5 work:
- Feishu adapter ✅ (Receiver Kind + WebhookPlug, end-to-end verified with Allen)
- CC channel production rewrite ⚠️ partial (Phase 1 v1_prototype HTTP/SSE still in use; production WS rewrite is the remaining gap)
- Pty-Web ✅ (xterm.js + dispatch path invariant test, PR #40)

So Roadmap should mark Phase 5 **complete-with-known-gap** (the v1→v2 channel wire swap) rather than open.

### 5.4 New entries
- Phase 6 should include: **Workspace.config.routing_rules** persistence (per-Workspace rule storage so dev/prod environments can diverge); **Multi-user-routing** (mention rules per workspace); **Federation (Decision #48)**.
- CLI roadmap: distributed-Erlang RPC is v1; v2 should add token-based auth so non-admin CLI users still go through CapBAC at the runtime.

## 6. Suggested doc-update PR shape

Single PR titled `docs: post-Phase-5 absorption (Decision Log + GLOSSARY + Roadmap)`:
- ARCHITECTURE.md: 5 new Decision Log entries (#127–#131) + §5.4.4 ref-impl pointer + §14 LOC note
- GLOSSARY.md: 4 new terms + 1 updated entry
- IMPLEMENTATION_ROADMAP.md: 2 new invariants + §1.4 strengthening + §8 Phase 5 status update + Phase 6 sketch entries

Estimated diff: ~150 lines of doc additions, 0 code changes. Should be reviewed by Allen before merge to confirm the framing of "complete-with-known-gap" for Phase 5.
