# Handoff: Git Provider V1 continuation — Plan C design first

> **Date:** 2026-07-17 · **From:** gaga current Codex session · **To:** gaga next Codex session
> **Tracking:** W29 demo P0 / Draft PR #1445 · **Base:** `origin/main` @ `be9a4d9ea2af8ef2e8c0845fc9a3108b75309bcb`
> **Status:** confirmed continuation — Plan A and Plan B complete; downstream roadmap corrected; Plan C design is next

## 0. Mission

Continue the W29 dev-loop work without re-deriving or renaming the completed
phases. First finish and review the real Plan C design: public anonymous
checkout, per-task worktree, and `project_cwd` readiness before cc-headless
sidecar start. Do not begin implementation until the design is approved. Plan D
remains OAuth-first and begins later with the bounded OneAuth/OneSystem D0 reuse
gate.

## 1. Current repository state

- Worktree: `/home/huangjiajia/ezagent/.worktrees/git-domain-spine`
- Branch: `feat/git-domain-spine`
- Local HEAD: `6ec926db8378af7f7bfab012a3507c1c6184c55f`
- Remote branch HEAD: `df34dfa7d3d100d561bdf83e96d84e532ec145a1`
- Current `origin/main`: `be9a4d9ea2af8ef2e8c0845fc9a3108b75309bcb`
- Divergence from current main: main has 4 commits not in the branch; the local
  branch has 56 commits not in main.
- Working tree: clean at handoff creation.
- PR: `https://github.com/ezagent42/ezagent/pull/1445`; last confirmed state was
  Draft. A 2026-07-17 `gh pr view` refresh failed because the GitHub GraphQL
  connection reset, so re-query before reporting current PR checks/state.
- Commit `6ec926db8` is local only at handoff time. Neither it nor this handoff is
  pushed unless a later command explicitly does so.

Before Plan C implementation, update the branch onto current main and inspect
conflicts. Do not silently discard the Plan A/Plan B stack. Re-run the Plan B
focused gates after integration.

## 2. Required reading before any action

1. Root `AGENTS.md`.
2. Skills: `using-superpowers`, `dev-together`, `brainstorming`,
   `ezagent-developer`, `project-discussion-ezagent`, `ezagent-socialware`,
   `elixir-phoenix-helper`, `systematic-debugging`,
   `verification-before-completion`, and `using-git-worktrees` when changing
   worktree/branch state.
3. `docs/superpowers/specs/2026-07-15-git-provider-v1-design.md`.
4. `docs/superpowers/specs/2026-07-16-git-provider-v1-a-decisions.md`.
5. `docs/superpowers/specs/2026-07-16-git-provider-v1-b-domain-spine.md`.
6. `docs/superpowers/specs/2026-07-17-git-provider-v1-downstream-roadmap-amendment.md`.
7. `docs/together/2026-07-16/returns/gaga-git-provider-plan-b.md`.
8. `docs/superpowers/notes/2026-07-15-demo-provisioning-constraints.md`.
9. `docs/together/2026-W29/weekly-goals.md` and
   `docs/together/2026-07-15/plan.md` §1/§7.
10. `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` from current
    `origin/main` for the separate cc-headless MCP/credential readiness gates.

If Plan C writes Lifecycle/CapBAC code, additionally read the exact referenced
`ezagent-developer` lifecycle and capbac guides before coding.

## 3. Locked decisions — do not re-litigate silently

| # | Decision | Value |
|---|---|---|
| 1 | Formal phase order | A security → B Git domain → C workspace transport → D provider connection/GitHub → E product/canary |
| 2 | Plan A transport | Public anonymous checkout + GitHub Git Data API; SSH and private checkout remain NO-GO |
| 3 | Plan B baseline | Consume existing `DomainGit` values, `GitTaskAccess`, adapter registry/contract, signed receiver-bound Cap dispatch, and closed errors |
| 4 | Product connection | OAuth-first; PAT-first is withdrawn |
| 5 | Multi-provider boundary | Thin provider-neutral connection lifecycle; provider OAuth/scopes/refresh/webhooks remain plugin-owned |
| 6 | OneAuth/OneSystem | Scheme C: freeze replaceable ports in D0; do not depend now on an incomplete remote broker |
| 7 | OneAuth safety | Social-login token is not repository-operation consent |
| 8 | OneSystem safety | Current generic plaintext decrypt API is not an acceptable credential-use boundary |
| 9 | Agent secret boundary | Git provider token and SSH private key never enter agent, config_dir, workspace, prompt, transcript, snapshot, audit, or task card |
| 10 | W29 scope | First closed loop only; no stabilization expansion |
| 11 | Merge/deploy | Lead-controlled; keep PR Draft and stop at reviewable state |
| 12 | #1360 | No Git Provider dependency; continue honest loose-coupled label |

## 4. Completed work — do not rebuild

### Plan A

- Inventory of secret storage and SSH parsing.
- Same-UID secret exposure reproduction.
- SSH broker NO-GO decision.
- GitHub Git Data API pure request-plan prototype and security tests.

### Plan B

- Independent `apps/ezagent_domain_git` app.
- Closed provider-neutral values and validations.
- `Ezagent.DomainGit.Adapter` and `AdapterRegistry`.
- `GitTaskAccess` Resource/Lifecycle and five actions.
- Exact signed, receiver-bound task capabilities.
- Sole authorized adapter lookup/invocation inside `GitTaskAccess`.
- Atomic boot registration/reconciliation.
- Fake-provider in-process integration proof and structural gates.
- Plan B return and Draft PR #1445.

Never introduce a second adapter contract/registry, GitHub-specific domain
values, token/client fields in `OperationContext`, a Kanban-to-provider shortcut,
or a new provider URI scheme.

## 5. Next task: Plan C clarify-first design

This task hits discuss-first triggers: cross-domain lifecycle, CapBAC, filesystem
effects, sidecar ordering, idempotency, and an MVP/reliability scope decision.
The next session must use brainstorming and produce the design before invoking
writing-plans or implementation skills.

Plan C consumes the authoritative Plan B task policy and validated public
`RepositoryRef`. It must settle:

1. exact owner/app placement for the provider-neutral pre-start provision port;
2. durable provision record schema and task URI + generation identity;
3. anonymous public repository cache/clone versus per-task worktree ownership;
4. state transitions and CAS/idempotency boundaries;
5. how `project_cwd` readiness gates sidecar start without putting provisioning
   inside `plugin_cc`;
6. cleanup ownership and the minimum orphan recovery required for first loop;
7. the sanctioned dispatch/cap path and unauthorized-no-filesystem-effect gate;
8. how the provisioner receives repository intent without calling a provider
   adapter directly or duplicating Plan B validation;
9. structured blockers projected later by Kanban;
10. focused and full verification commands.

### Plan C scope minimum

- public repositories only;
- per-task-generation isolated worktree;
- no shared mutable cwd or `git stash`;
- provision-before-sidecar hard gate;
- deterministic identity and duplicate-provision protection;
- explicit terminal/cancel cleanup;
- fail-closed private/authenticated checkout;
- no agent credential or Git provider API.

### Explicit Plan C deferrals

- private repositories and authenticated checkout;
- SSH transport and Entity SSH key UI;
- long-term workspace pooling;
- cross-node leases;
- comprehensive periodic reaper/stabilization;
- GitHub OAuth/API implementation (Plan D);
- Kanban product projection and canary acceptance (Plan E).

## 6. Provisional Plan C research DoD

This is a research/design handoff, not a build completion claim.

- [ ] Existing agent materialization, sidecar start, `project_cwd`, repository,
      workspace, and cleanup seams are inventoried with file:line evidence.
- [ ] Two or three ownership/ordering approaches are compared against the
      project tiering and dispatch invariants.
- [ ] The recommended design lists every consumed Plan B API and every frozen
      component it cannot recreate.
- [ ] State machine, persistence identity, filesystem ownership, failure paths,
      cleanup, and first-loop deferrals are explicit and internally consistent.
- [ ] The future build DoD is closed, goal-derived, and names user-facing plus
      invariant proofs.
- [ ] Design is written under `docs/superpowers/specs/`, self-reviewed for
      placeholders/contradictions, and reviewed by the user before writing the
      executable plan.

## 7. Later sequence after Plan C

Plan D begins with D0, not with implementation:

```text
ProviderAuthorizationBackend
CredentialBackend
```

D0 proves local and remote-shaped fake backends and decides whether V1 uses
local ezagent implementations or an approved OneAuth/OneSystem integration.
Current evidence supports reusing OneAuth identity/re-auth and provider catalog
concepts, not its social-login token; OneSystem SOPS/Age is relevant, but its
generic decrypt endpoint must not be used.

Then:

- D1: provider connection substrate and OAuth lifecycle primitives;
- D2: GitHub OAuth connection driver + existing `DomainGit.Adapter` production
  implementation + Req/Git Data/attempt reconciliation;
- E: settings, exact Kanban governance/fact projection, and real canary proof.

## 8. Separate readiness dependencies

Current main's `gaga-agent-runtime.md` records two non-Git-provider prerequisites:

- cc-headless MCP assembly must work so the Kanban assistant has tools;
- cc credential supply and rematerialization must work so missing credentials do
  not leave the assistant role permanently skipped.

Track these as Plan E readiness gates. Do not absorb them into Plan C or Plan D,
and do not touch AgentRuntime ARB or the Kanban/world surfaces without a new
authorized scope decision.

## 9. Constraints and red lines

- Use cc-headless / `:in_process_sync`; bridge join/#1405 is not a blocker.
- Reproduce-first for every failure; use `systematic-debugging` before fixing.
- No raw RPC, arbitrary eval, live DB edits, or live node mutation.
- Do not touch AgentRuntime ARB, EntityCaps A/B/D, `caps_json` persistence, or
  no-tail enforcement.
- Dispatch is the only inter-Kind path.
- Use `Ezagent.Lifecycle` for new ActionSet behavior code.
- Capability issuance follows current `Cap.issue`/self-store/verify rules; no
  direct cap slice writes and no wildcard fallback.
- Per-tenant persistence carries non-null workspace identity.
- External integrations remain plugins; no provider-specific code in core or
  domain.
- Use Req for HTTP; do not introduce HTTPoison/Tesla/:httpc.
- Strict TDD for implementation; relevant regression plus all static gates and
  `mix precommit` before completion claims.
- UI verification uses agent-browser and retained screenshots/transcript.
- No deployment or merge without lead authorization.

## 10. Verification evidence already produced

- Plan B focused/full verification and CI evidence are recorded in
  `docs/together/2026-07-16/returns/gaga-git-provider-plan-b.md`.
- Roadmap amendment commit: `6ec926db8 docs(git): restore downstream provider roadmap`.
- Amendment verification: `git diff --cached --check` and
  `mix ezagent.doc.scan`; doc scan passed all three fitness checks.

No Plan C implementation or tests have been run. Do not claim Plan C started or
complete.

## 11. First commands in the next session

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-domain-spine
git status --short
git fetch origin main feat/git-domain-spine
git rev-parse HEAD origin/main origin/feat/git-domain-spine
git rev-list --left-right --count origin/main...HEAD
gh pr view 1445 --json url,state,isDraft,headRefName,baseRefName,mergeable,statusCheckRollup,title,updatedAt
```

Then load the required skills and read the listed facts. Report current
worktree/branch/main/PR state before making changes. Do not push, rebase, deploy,
or merge until the user authorizes that state transition or it is an already
approved implementation step.

## 12. Merge model

All downstream work remains on the task stack rooted at
`feat/git-domain-spine`; PR #1445 remains Draft. Allen/lead owns integration
order, deployment, and merge. If a new branch/worktree is later chosen for Plan
C implementation, it must inherit the complete Plan A/Plan B/design stack and
the final delivery must remain one coherent Draft stack, per Allen's instruction.
