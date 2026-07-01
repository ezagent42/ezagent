# 2026-06-30 Dev-Together Review

Reviewed at: 2026-07-01
Lead: linyilun / Codex
Source: `docs/together/2026-06-30/stack.md`, GitHub PR state, Feishu returns

## What Landed

| PR | Owner | Merge SHA | Result |
|---|---|---|---|
| #1106 AutoService answer-soul E2E | gaga | `b73cb247165d6841e9d61df084ffc377728481a4` | Current architecture E2E validated; AutoService Tier-1 landed as seed/harness content, not core/domain business logic. |
| #1105 Admin user management UI | zyli | `8a8e0b688ca68b8f56bef11a77e2f95c2565364d` | Production bootstrap user management landed. |
| #1103 Website demo/design archive | ruihua | `0d20fa191f9135420e6b9b2187aacde1250d55dd` | Website design/demo memory preserved before implementation branches. |
| #1107 Website hello support | zhaomato | `602d7c7e154c93a7f7b1576ad9f0d0af43ec6549` | Hello/world website support assets and refresh script landed after rebase. |
| #1104 World UI redesign prototype/refactor | zyli | `5eb82d4280645353d5899bc67ed40c2fc9d2a93e` | IM-like World shell refactor landed after rebase. |
| #1109 / #1111 / #1113 close docs | lead | `e51fb36778a7e41c0fee57defeb465512da00127`, `36b4c4b9f7e00707cf92fa97eb12abbceb8bbef7`, `ed0f08dcf8f3eead53bd6cc605d9145f6ae7a6dd` | 0630 stack, kanban rebase analysis, and FatNine late return were recorded. |

## Accounting

| Item | Count | Notes |
|---|---:|---|
| Planned tasks in a complete `plan.md` | 0 | 0630 had an incomplete/late plan ledger. Work happened through Feishu returns and PRs. |
| Returns/PRs reconciled in stack | 7 | #1106, #1105, #1103, #1107, #1104, #1020/#1110, #1112. |
| Late returns | 1 | #1112 Agent Console completeness / IA arrived after the initial close stack and was recorded by #1113. |
| Merged to `main` | 6 work PRs + 3 docs PRs | #1106/#1105/#1103/#1107/#1104 plus #1109/#1111/#1113. |
| Intentionally left open | 2 | #1110 and #1112. |
| Superseded | 1 | #1020 is superseded for merge mechanics by #1110. |

## Gaps

1. The daily ledger lagged the actual work. Returns were in Feishu and PR bodies,
   not consistently in `docs/together/2026-06-30/returns/`.
2. #1110 exposed the same large-PR failure mode: one branch mixed core/domain
   substrate, plugin business logic, World UI, CLI, persona, and E2E docs.
3. UI work is converging, but not yet under one design source of truth. Website,
   Hello, World UI, Agent Console, and Socialware all have adjacent design needs.
4. #1112 clarified that Agent Console is no longer mostly "small completeness
   bugs"; the remaining work is IA and destructive-action semantics.
5. CI green was necessary but not sufficient for UI PRs. #1104 needed product
   acceptance, not only tests.
6. #1106 did not leak AutoService business logic into core/domain, but it did
   put AutoService persona, KB corpus, and session/orchestrator wiring into a
   seed script. That is acceptable as an E2E proof, not as the long-term product
   carrier.

## Open PR State

| PR | State | Review Position |
|---|---|---|
| #1110 | mergeable, CI red | Keep as 2026-07-01 source branch for jjkysy to split. Do not merge whole. |
| #1112 | CI green, open | FatNine should converge on one Agent Console prototype path; do not expand multiple prototypes. |
| #1020 | conflicting | Superseded by #1110 for merge mechanics. |

## Method Deltas

1. **Return artifacts are mandatory.** Feishu-only returns are useful for speed but
   not enough for close. Every return must land a `returns/*.md` file or be
   explicitly marked as late/out-of-scope in `stack.md`.
2. **Prototype work must converge.** For UI/IA work, "many prototypes" is not
   progress unless one path becomes usable and verifiable. The lead comment on
   #1112 captures the rule: make one prototype real.
3. **Large integration branches are not merge units.** #1110 is an integration
   proof and salvage branch. It must be split by ownership boundary before merge.
4. **Design source of truth must be declared before parallel UI implementation.**
   For 0701, ruihua is the design anchor across UI/hello/console/socialware.
5. **Seed is not the product.** #1106 should be recorded as a successful
   AutoService Tier-1 harness, but AutoService product content must move to
   definition data: AgentTemplate/soul markdown, resource fixtures,
   SessionTemplate/socialware definition, and supported product/API install
   paths. The rule is now captured in
   `docs/together/contributing/seed-vs-product-boundary.md`.

## Next-Day Suggestions

1. Make 0701 a convergence day, not another exploration day.
2. Center the day on ruihua's design/IA direction, but keep engineering tracks
   separated by surface.
3. Assign one owner per surface:
   - zhaomato: website/hello
   - zyli: World UI shell
   - fatnine: Agent Console one complete prototype
   - gaga: AutoService/socialware flow validation and gaps
   - jjkysy: split #1110
4. Add a gaga-owned, jjkysy-reviewed task to move AutoService Tier-1 out of
   seed-as-product: seed remains installer/verifier; persona/corpus/routing
   become data/package artifacts.
5. Keep ruihua in the review gate: each surface should show how it follows the
   shared IA/visual direction before merging more UI code.
