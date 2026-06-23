# Return — Agent Console Phase-0 demo + Manage-gate proposal (#84)

| Field | Value |
|---|---|
| Task | Agent Console Phase-0 demo + Manage-gate proposal |
| Branch | `agent-console` |
| PR | #892 |
| Dev / PR author | `FatNine` |
| returned_at | 2026-06-22 22:37:12 +08:00 (backfilled from PR `updatedAt`; original return file was missing) |
| deadline | 2026-06-22 20:00 +08:00 |
| deadline_status | `late` |
| close_status | Landed via lead squash/subsumed commit `798f46bd`; PR #892 comment+closed on 2026-06-23 |

## Scope

Phase-0 static design-confirmation demo for Agent Console (#84), plus the
Manage-gate authorization protocol proposal:

- self-contained static demo under
  `apps/ezagent_web/priv/static/agent-console-demo/index.html`;
- four-quadrant IA: Template Studio, Session Console, Migrate, Observability;
- authority matrix for the Manage-gate model, including held-vs-needed caps,
  caller/authorizer/granter separation, and dual-principal audit;
- repeated fact-correction passes against the live code model;
- coordination entry in `docs/guide/world-coordination.md`;
- follow-up issue #895 for URI consistency audit.

## DoD artifact

- PR #892 carried the complete Phase-0 demo branch.
- The demo was iterated through multiple static review/fidelity passes.
- Lead close verified `/agent-console-demo` loads and renders.
- Final main close recorded precommit green for the complete 2026-06-22 stack.

## Caveats

- Phase-0 is a design/demo artifact, not a wired production Agent Console.
- Manage-gate remains a protocol proposal; real authorization implementation is
  follow-up work.
- Several skill/doc corrections were out-of-scope but landed with this branch
  because the demo exposed stale URI and CapBAC language.

## Merge / PR closure

The PR was not merged through GitHub. It was integrated by the 2026-06-22
dev-together lead close path as squash/subsumed commit `798f46bd`.

PR #892 was comment+closed on 2026-06-23 so the GitHub state matches `main`.
