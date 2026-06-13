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
the app-dir rename. **Recommendation: PR-9 keeps every module NAME unchanged; it
only moves files between apps + renames the app atom + fixes deps.** Any
module-namespace rename is explicitly OUT of PR-9 scope (separate, persisted-state-
aware PR if ever wanted).

> **EXCEPTION — persisted app-namespaced atoms (codex 2026-06-14, HIGH).** The
> "module names are app-independent" safety holds only because module ATOMS don't
> change when files move. But some persisted data stores the module atom as a
> STRING, and some of those modules are named after the app, not `Ezagent.*`:
> `routing_rules.table_name` persists `Atom.to_string(table_name_atom)` where the
> atom is `EzagentDomainInstanceMessage.Routing.MentionRouting`
> (`rule_store.ex:6,18,52-56`; `EzagentDomainInstanceMessage.DefaultRules` too,
> `:287`). If PR-9 renames the `EzagentDomainInstanceMessage.*` MODULE namespace
> (tempting alongside the app rename), existing `routing_rules` rows stop hydrating
> on restart → mention/default routing silently drops, even though `kind_snapshots`
> load fine. So the freeze must cover EVERY persisted atom/string namespace, not
> just `Ezagent.*` — see D1.

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
  **Sub-decision D1a (codex HIGH): if the app is renamed, do the
  `EzagentDomainInstanceMessage.*` MODULE atoms get renamed too?** Recommended NO —
  FREEZE them (and every persisted atom/string namespace). `routing_rules.table_name`
  persists `EzagentDomainInstanceMessage.Routing.MentionRouting` / `.DefaultRules`
  as strings (§2 exception); renaming those modules breaks routing-rule hydration
  on restart. A module-namespace rename, if ever wanted, is a SEPARATE
  persisted-state-aware PR that ALSO migrates `routing_rules.table_name` (rewrite
  old→new + dual-load window) — never folded into PR-9. Verification: dump
  `routing_rules` keys before AND after a cold restart and assert mention/default
  routing still hydrates (not only the kind_snapshots round-trip).

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
  PR-9b (app rename `instance_message → session`) → PR-9c (shrink to zero
  allowlist + im-label enforcement). Blast radius warrants the split (parent §4.1
  note "PR-9 can be split per-domain").
  **REVISED (codex MEDIUM): the acyclic arch-fitness gate ships in PR-9a FIRST, not
  9c.** Land the gate at the start with an explicit allowlist of the cross-domain
  references that exist today; every sub-PR (9a/9b/9c) must keep it GREEN while
  SHRINKING the allowlist, reaching empty at 9c. Deferring the only enforcement
  mechanism to the cleanup PR would let a forbidden dependency survive 9a/9b
  (and the repo already has many hardcoded cross-domain refs + path allowlists,
  so that risk is real). The gate-with-shrinking-allowlist IS the moving
  completion invariant (memory `feedback_completion_requires_invariant_test`),
  enforced continuously rather than asserted once at the end.

## 5. Risks + mitigations

- **Broad mechanical churn (mix.exs/config/release refs).** Mitigate: do the app
  rename (D1/9b) as its own commit; grep every `ezagent_domain_instance_message`
  occurrence first (enumerate-all-gates discipline) — including `config/`,
  release, and CI; `mix compile --force` + full umbrella + the 3 arch gates +
  `check_invariants.lifecycle` after.
- **The arch gates THEMSELVES hardcode the old app path — they WILL go red on
  rename (concrete, verified).** `ezagent.arch.scan.ex` has
  `apps/ezagent_domain_instance_message/...` in its allowlists (e.g. lines ~29/31/44),
  and `ezagent.check_invariants.ex` has several `grep -v
  'apps/ezagent_domain_instance_message/...'` exclusions (lines ~123-125/262).
  Renaming the app without updating these stale path allowlists is the EXACT class
  that reddened main twice (#736/#741, memory `feedback_run_check_invariants_gate`
  + `feedback_enumerate_all_gates_before_deletion`). PR-9b MUST update every
  hardcoded `apps/ezagent_domain_instance_message/` literal in the gate tasks in
  the same commit, then run all gates force-compiled to prove green.
- **Runtime app-name atoms.** At least `Application.ensure_all_started(
  :ezagent_domain_instance_message)` (`ezagent.credential.adopt.ex:52`) and any
  `Application.get_env(:ezagent_domain_instance_message, …)` use the app atom at
  runtime — these must move with the rename (a compile pass won't catch a wrong
  app atom in a string/atom literal). Grep `:ezagent_domain_instance_message`
  (atom form) separately from the dep-tuple form.
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

Proceed PR-9 as **3 sub-PRs (9a extract agent + land the acyclic gate
allowlisted · 9b rename app atom · 9c shrink allowlist to zero)**, **ALL module
names frozen — including the persisted `EzagentDomainInstanceMessage.*` atoms
(routing_rules), not just `Ezagent.*`**, **feishu stays the im plugin (no new im
app)**, **agent_bridge stays a separate leaf**, **arch-fitness gate enforced from
9a with a shrinking allowlist**. This keeps PR-9 persisted-state-safe (kind_snapshots
AND routing_rules) and turns the "scary last piece" into bounded, continuously-gated
umbrella surgery. Awaiting Allen on D1–D4 (+ D1a: freeze the app-namespaced module
atoms vs. a separate routing_rules-migrating rename PR).
