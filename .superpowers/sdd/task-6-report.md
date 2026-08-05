# Task 6 report — receipt-backed TemplateSpawn completion

## Status

Implemented from approved HEAD `e3b5efcbe`.

## RED evidence

The exact Task 6 command initially failed because the production path invoked
`instantiate/3`: the workspace test received no launch context, and a Template
without `instantiate/4` executed its `/3` effect instead of failing closed.

## Implementation

- Added the option-aware `provision_and_instantiate/5` contract boundary. It
  validates `instantiate/4` before config allocation, flavor hooks, or Template
  effects, and invokes it with exactly `[launch_context: launch_context]`.
  The existing `/4` wrapper preserves the legacy `instantiate/3` path.
- Threaded `prepared.launch_context` separately through `TemplateSpawn`; it is
  never inserted into Template data.
- Plan C fresh completion now verifies `CreationInventory.exact/4` before
  sandbox, overlay, flavor, or completion work. It does not rewrite lineage,
  workspace ownership, or creation inventory already committed by Agent init.
- Non-Plan-C fresh completion retains its legacy lineage, workspace, inventory,
  sandbox, overlay, flavor, rollback, and grant behavior.
- Adopted Plan C completion finalizes PreStart first, returns
  `:sidecar_start_not_fresh`, and preserves the existing worker's lineage,
  workspace, sandbox, flavor, overlay, and creation inventory.
- PreStart fresh completion verifies the exact persisted receipt and maps a
  missing/conflicting receipt to `:ownership_receipt_missing`; it never marks the
  provision started.
- `reserve_creation_identity/1` was already absent at the approved Task 5 HEAD;
  no PreStart inventory prewrite remains.

## Verification

- Exact Task 6 command: 32 tests, 0 failures.
- Core Template boundary plus Task 5 flavor transport regressions: 93 tests,
  0 failures.
- Touched files formatted; `git diff --check` clean.

## Scope

No launch context is serialized, logged, persisted, or inserted into Template
data. The pre-existing untracked handoff file was preserved and excluded.

## Important review correction after `56da93593`

- The option-aware core wrapper no longer invokes the persistent flavor store
  or delete hooks before/after `instantiate/4`. Legacy `/3` and option-free
  behavior retain their existing hook lifecycle unchanged.
- TemplateSpawn no longer restores an adopted Plan C flavor after the fact or
  deletes pre-existing flavor state on a Plan C instantiate failure. The only
  Plan C flavor write remains the fresh final obligation, after exact receipt
  acceptance, sandbox state, and behavior overlay completion.
- The adopted regression now probes `AgentFlavorAttributes` from inside the
  deterministic instantiate barrier. RED observed the requested flavor there;
  GREEN observes the original `"preexisting-flavor"`, proving no transient
  losing-attempt write occurred.
- Plan C test Template Classes start the declared Agent Kind directly because
  first-start resolution may no longer rely on a prematurely persisted flavor
  attribute. No implicit process-local resolver channel was added.

Fresh verification: exact Task 6 command `32 tests, 0 failures`; core Template
plus Task 5 transport regressions `86 tests, 0 failures`; touched files formatted
and `git diff --check` clean.

---

# Hello reusable-agent UI and relay cleanup — Task 6 (2026-08-05)

## Status

Implemented on top of `c51864933` without modifying the unrelated Task 1 and
Task 2 report changes already present in the worktree.

## Implementation

- Renamed the AgentBridge correlation metadata to the generic
  `completion_request_id` and locked out the retired Hello-specific key.
- Removed SessionFeedChannel's Hello `front-desk` mention injection. Generic
  external posts now enter through `Session.send` without web-layer product
  routing knowledge.
- Removed World's server and React `:hello_page`/`:page` id fallbacks.
  Non-native views render externally only when the session-view registry
  declares `external_render?`, and the client hosts any resulting generic
  `mode: "external"` without inspecting the view id or session URI.
- Added optional generic `template_options` to Workspace `create_session` for
  registered Template Classes. Workspace strips caller-provided `class` and
  `session_name` overrides and supplies the canonical values itself.
- Reworked authenticated `HomeLive` first-session creation into a Hello flow:
  flavor selection drives `ReusableLlmAgent.list/3`, the agent selector shows
  only eligible caller-managed `hello.llm` agents in the selected workspace,
  empty results explain the prerequisite, and submit remains disabled until an
  explicit candidate is selected.
- Submit revalidates the selection, creates `session.hello` in the selected
  workspace, and passes the exact flavor/agent pair through generic Template
  data. The integration test verifies the working-copy role declaration uses
  `install_mode: :reuse` and that no replacement agent is created.
- The Hello sync-result mapping was already absent at the approved Task 5 HEAD;
  the existing retired-relay architecture test continues to guard its absence.

## Verification

- Fresh focused command including the URI scanner: 83 tests, 0 failures
  (`ezagent_core` 19, AgentBridge 6, Workspace 14, World 27, web 17).
- World client suite: 48 tests, 0 failures. TypeScript typecheck and focused
  ESLint for the changed Conversation files also pass.
- `git diff --check`: clean.
- `mix ci.fast`: blocked before its test phase by an unchanged malformed entry
  in `apps/ezagent_core/lib/ezagent/actor_boundary_ledger.exs` for
  `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/migrate.ex`; the invariant
  task raises because that existing entry has no `:line` key.
- `mix precommit`: compiled the umbrella and began the full suite. It exposed
  existing architecture debt (oversized-module cap, HelloSessionActions
  owner-bypass/dynamic-receiver baseline, ReusableLlmAgent sensitive-read
  ledger, and stale migrate ledger). A Task 6 URI scanner finding was also
  identified during that run, fixed, and then verified green by the fresh
  19-test scanner suite above. The long runner was stopped after the accumulated
  architecture failures; no broad-green claim is made.

## Scope

No broad invariant-ledger or architecture-baseline updates were folded into
this feature commit. The unrelated dirty Task 1 and Task 2 reports remain
unstaged and preserved.
