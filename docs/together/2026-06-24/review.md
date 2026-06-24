# dev-together close review — 2026-06-24 cycle (lead: Claude)

_What landed, what came back incomplete/divergent, and the process loop. The
per-task findings are split into independent files under `review/` so each can be
forwarded to its owner. The **process** retrospective (how we change dev-together
so this stops recurring) is its own grill artifact:
[`dev-together-process-improvement.md`](dev-together-process-improvement.md)._

## 1. Landed on `main` this cycle

| PR | Task | Dev | merge SHA | note |
|---|---|---|---|---|
| #961 (supersedes #956) | hello AI page generation — integrated + greened | zhaomato (greened by lead) | `6cfabacd` | see `review/956-hello-never-green.md` |
| #962 | **CI gate + branch protection** | lead (Claude) | `a56ca149` | the structural fix (see §3) |
| #959 | F14 routing self-loop (#98) | lead | `b847512b` | |
| #960 | #95 PR-final skill docs | lead | `e2807c0c` | |
| #954/#955/#957 | #95 LocalRuntime PRs | lead/cc | — | |
| #948 #951 #943 #952 + zyli 944/953/949/950 | (earlier in cycle) | various | — | |

## 2. Came back incomplete / divergent — per-task findings (independent files)

- [`review/956-hello-never-green.md`](review/956-hello-never-green.md) — **#956 was never green on its own tip** (compile-WAE + 6 tests/gates). Lead fixed to land. Owner: **zhaomato**.
- [`review/958-agent-console-completeness.md`](review/958-agent-console-completeness.md) — **#958 backend solid, console UI under-delivered/under-tested** (0 UI/route tests; repoint UI deferred; echo blocked on #918; subset DoD). Owner: **fatnine**. Status: OPEN, lead disposition pending Allen.
- [`review/official-site-json-render-desync.md`](review/official-site-json-render-desync.md) — **official site renders broken**: #956 migrated the backend catalog to shadcn but never migrated the frontend renderer. Now a planned task for **zhaomato** (in `plan.md`).

## 3. Structural fix shipped this cycle

CI (`#962`) now runs `mix precommit` + `mix ezagent.check_invariants` on every PR
and push to `main`; **branch protection** requires the `precommit +
check_invariants` check (force-push/deletion blocked, `enforce_admins=false`).
This directly closes the **#956 class** (a never-green/stale branch can no longer
be merged by a non-admin). CI immediately earned its keep by catching a
pre-existing `zod` lockfile drift on `main`.

## 4. Owner reminders (carry-forward)

- **zhaomato:** a PR must be **green on its own tip** (`mix precommit` EXIT=0) **and
  rebased onto current `main`** *before* you return it. Both are now CI-enforced.
  When you migrate a contract (e.g. the shadcn catalog), migrate **all consumers**
  (frontend renderer, tests), not just the backend.
- **fatnine:** "Agent Console" DoD = the operator can configure **every** field
  **and it's verified through the console UI** (a LiveViewTest mounting the route,
  not only backend-seam tests). Defer = mark the return `deferred` + list the open
  decisions; "READY TO MERGE" is the lead's call.

## 5. Process loop

Each finding above maps to a proposed dev-together rule (P1–P6) in the grill
artifact. That doc is the **process** change we grill before editing the skill —
per Allen, the analysis there is about the workflow, not the code.
