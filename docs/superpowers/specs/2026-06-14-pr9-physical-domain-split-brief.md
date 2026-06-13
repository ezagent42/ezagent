# PR-9 — Physical domain split (im / session / agent): design + decision brief

> **Status: DESIGN BRIEF for Allen's 拍板.** PR-9 is the LAST piece of the #53
> transport line; the logical decomposition (PR-6/7/8a/8) is merged (#748/#749/
> #750). This brief does NOT execute — it surfaces the decisions PR-9 needs and a
> recommended approach, per the design-then-review preference. Parent spec:
> `2026-06-12-im-session-agent-decomposition-design.md` (§2 module map, §6 migration,
> §7 O-1..O-4). Risk class: broad umbrella surgery; snapshot-key-sensitive ONLY if
> module names change (see "Key de-risking insight").

## 1. What PR-9 is (and is not)

PR-9 physically relocates modules into the 3 target domains and enforces the
acyclic `im → session → agent` dependency graph with an arch-fitness test
(parent spec §6.3). It is the realignment LAST step — every module's target is
already decided in parent §2; PR-0..8 already did the logical seams (the
`session.send` entry, the `OrchestratorReadinessPort`, the cc transport
relocation, curl-as-flavor). PR-9 moves files + names apps + adds the acyclic gate.

PR-9 is NOT a behavior change and NOT a Kind/snapshot change. The P5 collapse
(PR-3..5) and curl migration (PR-7) are the snapshot-touching PRs; PR-9 rides on
their completed state.

## 2. Key de-risking insight (verify in review)

**Elixir module names are independent of the OTP app that compiles them.** Moving
`Ezagent.Entity.Session` from `ezagent_domain_instance_message` to a renamed
`ezagent_domain_session` app does NOT change the module atom
`Ezagent.Entity.Session`. `kind_snapshots` resolve by `kind_type` STRING via the
cold-load resolver (`agent_module_resolver.ex`) and by module atoms inside
`state_binary` — both are app-independent. **Therefore the OTP-app rename does not
touch snapshot keys, as long as PR-9 keeps module namespaces stable.**

The "renames are expensive per snapshot-key + call-site coupling" warning in the
parent spec (§5/line 418, `chat.ex:101-110`) is about MODULE/ACTION renames
(`chat.send → session.send`) — which already happened in the transport line — NOT
the app-dir rename. **Recommendation: PR-9 keeps every `Ezagent.*` module name
unchanged; it only moves files between apps + renames apps + fixes deps.** Any
module-namespace rename is explicitly OUT of PR-9 scope (separate, snapshot-aware
PR if ever wanted).

## 3. Target app structure

| Target app | Holds (parent §2) | Source today |
|---|---|---|
| `ezagent_domain_session` (rename of `ezagent_domain_instance_message`) | unified Session Kind, Chat/Surface/Turn/routing fan-out, SessionCreator, Orchestrator.Tools + OrchestratorAdmin, OrchestratorReadinessPort, socialware schemas | `ezagent_domain_instance_message` (minus agent + im bits moved out) |
| `ezagent_domain_agent` (NEW) | `Entity.Agent` / `AgentTemplate` / `Behavior.Agent.Receive` / reparented curl-state Behavior | currently in `ezagent_domain_instance_message` |
| `ezagent_domain_agent_bridge` (EXISTS — fold under agent domain) | AgentBridge + adapters/registry/tokenstore (already a clean leaf, core-only dep) | unchanged location; becomes the agent domain's transport |
| `ezagent_domain_im` (NEW or label) | Feishu ingestion (WebhookPlug/WsClient/InboundDispatcher) + outbound transport | `ezagent_plugin_feishu` + channel-server/gateway |

Acyclic target: `im → session → agent` (+ `agent → agent_bridge → core`). The
arch-fitness test asserts: im has no agent-Kind/`agent.receive` symbol; session
has no `McpChannel`/`orchestrator_bridge` symbol; the compile dep graph is acyclic.

## 4. Decisions needed (Allen 拍板)

- **D1 — Rename the OTP app `ezagent_domain_instance_message → ezagent_domain_session`?**
  Recommended YES (matches the decided domain name O-1; honest). Cost is mechanical
  + broad: the `app:` atom in its `mix.exs`, ~12 `{:ezagent_domain_instance_message,
  in_umbrella: true}` refs across sibling `mix.exs`, `config/*.exs` references, any
  `Application.get_env(:ezagent_domain_instance_message, …)` + priv paths, and the
  release app list. Snapshot-safe per §2 (module names unchanged). Alternative: keep
  the app dir name to avoid churn (rejected — leaves the headline domain misnamed
  forever; the churn is one-time + mechanical).

- **D2 — Is `domain.im` a NEW umbrella app, or just the existing `ezagent_plugin_feishu`
  relabeled?** Recommended: KEEP `ezagent_plugin_feishu` as the im-ingestion plugin
  (no new app) and treat "im" as a DOMAIN LABEL/dep-direction enforced by the
  arch-fitness test, not a physical app rename. Rationale: feishu is one of several
  possible ingestion transports; a generic `domain_im` app with one plugin inside
  adds ceremony without isolation benefit. The acyclic gate (im-layer has no
  agent symbol) is what matters, and it can key on the plugin app(s).

- **D3 — Does `ezagent_domain_agent` swallow `ezagent_domain_agent_bridge`, or stay
  two apps?** Recommended: KEEP TWO (`agent_bridge` is already a clean core-only
  leaf; `domain_agent` depends on it). Merging buys nothing and risks the leaf's
  cleanliness. The agent DOMAIN = {domain_agent, agent_bridge}.

- **D4 — One PR or per-domain split?** Recommended: SPLIT into PR-9a (extract
  `domain.agent` — move Entity.Agent + agent receive out of the im-message app) →
  PR-9b (app rename `instance_message → session`) → PR-9c (the acyclic arch-fitness
  gate + im-label enforcement). Each is independently green-able; 9c is the
  invariant that makes the split "done" (memory `feedback_completion_requires_invariant_test`).
  Blast radius warrants the split (parent §4.1 note "PR-9 can be split per-domain").

## 5. Risks + mitigations

- **Broad mechanical churn (mix.exs/config/release refs).** Mitigate: do the app
  rename (D1/9b) as its own commit; grep every `ezagent_domain_instance_message`
  occurrence first (enumerate-all-gates discipline) — including `config/`,
  release, and CI; `mix compile --force` + full umbrella + the 3 arch gates +
  `check_invariants.lifecycle` after.
- **Accidental module-namespace rename → snapshot break.** Mitigate: hard rule —
  PR-9 does NOT rename modules; an arch test / review check that no `kind_type`
  string and no `Ezagent.*` module atom changed in the diff.
- **Test-DB-only for any migration; never touch dev/prod** (memory
  `feedback_destructive_migration_anti_pattern`). PR-9 should need NO migration if
  module names hold — if a migration appears, that's a signal a module rename crept in.
- **Cross-worktree app moves under a live phx.server** — do PR-9 work in an isolated
  esr-ng worktree off origin/main, never the live main tree (memory
  `feedback_subagent_worktree_wrong_repo`).

## 6. Verification (the gate, not "tests pass")

Parent §6.3: an arch-fitness test that FAILS if the split is unmet — (a) im layer
has no agent-Kind/`agent.receive` reference, (b) session has no `McpChannel`/
`orchestrator_bridge` reference, (c) `im → session → agent` acyclic. Plus full
umbrella regression + `arch.scan` + `check_invariants[.lifecycle]` + the existing
E2E scenarios (chat core, socialware SW-*, cc/codex/curl deliver-and-reply, relay
scenario_34) all green. Cold-restart respawn round-trip byte-identical (proves no
snapshot drift from the move).

## 7. Recommendation summary

Proceed PR-9 as **3 sub-PRs (9a extract agent · 9b rename app · 9c acyclic gate)**,
**module names frozen**, **feishu stays the im plugin (no new im app)**,
**agent_bridge stays a separate leaf**. This keeps PR-9 snapshot-safe and turns the
"scary last piece" into bounded, independently-verifiable umbrella surgery. Awaiting
Allen on D1–D4.
