# Git Provider V1 Plan C Task Workspace Hardening Design

## Status and scope

This design closes the findings from the independent post-implementation Plan C
review. It amends the start, Git checkout, cache refresh, recovery, and
structural-test sections of
`2026-07-17-git-provider-v1-c-task-workspace-design.md`. Where the two documents
conflict on those subjects, this document wins.

The change does not broaden Plan C into private checkout, credentials, provider
write operations, change-request creation, UI, deployment, or cross-node cache
locking. Existing receiver-bound CapBAC, `GitTaskAccess`, Workspace ownership,
and provider-adapter boundaries remain unchanged.

## Findings being closed

1. Template pre-start completion currently runs immediately after Template
   Class `instantiate/3`, before the shared spawn helper records lineage,
   workspace binding, creation inventory, and later post-spawn obligations.
2. A process or node crash after consuming the start token but before completion
   leaves a consumed `:ready` row that boot recovery never selects.
3. Checkout readiness proves only that a path is a Git worktree, not that it is
   on the governed branch and resolved commit.
4. An existing bare cache verifies `origin` but does not fetch, so later
   generations can use stale refs or fail to see new refs.
5. The pre-start proof-runner override is runtime-configurable in production,
   and structural tests do not fully freeze the trusted start call sites or
   secret-like schema fields.

These are product correctness defects, not the known SkillRegistry or
`skill_reconcile` branch baseline.

## Decisions

### 1. Durable start state

Add `:starting` to the provision state machine. Starting is a durable external
effect claim, not an in-memory core concern.

The row gains:

- `start_claim_token`
- `start_lease_until`
- `resolved_base_commit`
- `local_branch_ref`

`AgentStart.start/5` first binds deterministic Agent retirement intent as it
does today. `PreStart.prepare/1` then performs one locked transition:

```text
ready + unconsumed start token
  -> starting + consumed token + start claim token + finite lease
```

It returns the canonical `cwd` and an opaque completion claim containing only
the row id and start claim token. A second claimant fails closed.

Completion transitions are token- and lease-fenced:

```text
starting --successful final spawn obligations--> sidecar_started
starting --spawn error/raise/exit--------------> cleanup_pending
starting --expired lease------------------------> cleanup_pending
```

An expired `:starting` row is classified as `:ambiguous_or_live`, because the
sidecar may exist even when no completion was recorded. Recovery must perform
sanctioned Agent retirement before Git cleanup. It must never reset the row to
`:ready` or retry instantiate with the consumed generation.

The boot effect-recovery lane includes expired `:starting` rows ahead of
proof-only ready checks. The same bounded/deferred boot policy used for active
provision and cleanup leases applies to active start leases.

Core `Template.PreStart` remains a generic transient coordinator. It monitors
the caller that registered a pending completion token and removes that token on
`DOWN`; it does not attempt durable recovery or name Workspace concepts.

### 2. Completion after final spawn obligations

The single Template instantiate seam remains in `TemplateSpawn`, but successful
completion moves to the end of the shared spawn workflow.

Required ordering:

```text
pre-start prepare
-> Template Class instantiate
-> shared lineage recording
-> workspace binding
-> creation inventory
-> remaining post-spawn obligations
-> pre-start complete(success, workers)
```

Any error, raise, exit, or failed post-spawn obligation after prepare calls
pre-start completion exactly once with an error outcome. Completion failure
after a sidecar exists is returned as a start failure and leaves the durable row
cleanup-recoverable; it is not converted into apparent success.

The generic completion outcome may carry worker URIs, but it cannot carry Git,
task, provider, flavor, recipe, or plugin-specific data. `pre_start_ref` remains
a trusted spawn option and is never persisted in template/recipe/plugin data.

Workspace success completion verifies:

- returned workers contain exactly the pre-bound Agent URI;
- the creation attempt exists for the row workspace;
- lineage equals the pre-bound provenance root;
- the matching start claim token and lease are current.

The regression test must use a genuine fresh Template Class that does not write
lineage, workspace binding, or creation inventory itself.

### 3. Deterministic local task branch

Plan C uses a real local branch, not detached HEAD.

The branch is derived exclusively from `provision_id` and `generation`; callers
cannot supply it. The exact encoding must be stable, ref-safe, bounded in
length, and collision-resistant. A recommended shape is:

```text
refs/heads/ezagent/task/<short-provision-hash>/g<generation>
```

`allowed_head_ref` remains the governed future remote destination. It is not
used as an unchecked local ref name and is not pushed by Plan C.

Within one cache lock, preparation performs:

```text
verify or clone governed origin
-> bounded anonymous fetch with fixed refspec
-> resolve base_ref^{commit}
-> create/reset deterministic local branch at the resolved commit
-> add worktree on that branch
-> verify branch, commit, cache ownership, and path
```

The resolved full commit SHA and local branch ref are persisted atomically with
the ready transition. A retry may converge only when the existing branch points
at the same resolved commit and belongs to the same provision identity.
Conflicting branch state fails closed and enters cleanup; it is never silently
reset if an active recorded worktree owns it.

### 4. Readiness and start proof

`GitRunner.verify/1` becomes an exact proof. It must establish all of:

- the canonical worktree is registered by the expected bare cache;
- `origin` equals the governed anonymous remote;
- `git rev-parse HEAD` equals `resolved_base_commit`;
- `git symbolic-ref -q HEAD` equals `local_branch_ref`;
- the worktree has no staged, unstaged, or untracked changes before Agent start;
- canonical cache/worktree identities and paths equal the durable row.

The ready transition verifies before persisting. `PreStart.prepare/1` first
atomically claims `ready -> starting`, then repeats the same proof while holding
that durable start claim and before instantiate. A failed proof moves the
matching claim to cleanup pending. This ordering prevents two verifiers from
starting concurrently without leaving an unfenced proof-to-claim gap.

After the sidecar starts, edits and commits are expected. Cleanup therefore
does not demand that HEAD still equals the base commit; it proves only exact
durable ownership before removal.

### 5. Anonymous cache refresh

Both clone and fetch use the same anonymous execution boundary:

- absolute Git executable and argv-only execution;
- cleared inherited environment;
- credential helper and askpass disabled;
- `GIT_TERMINAL_PROMPT=0` and system config disabled;
- bounded output and a finite deadline;
- no credential, authorization header, provider adapter, or caller-selected
  refspec in the request.

For an existing cache, origin is checked before fetch. Fetch uses a fixed
implementation-owned refspec sufficient to resolve the validated base ref and
prunes stale remote-tracking refs without deleting the deterministic local task
branch. Fetch, branch mutation, worktree add/remove, and Git metadata cleanup
all hold the same cache lock.

Provision lease duration must cover bounded lock wait plus clone/fetch,
resolution, branch/worktree operations, and both exact verifications with a
documented safety margin. The test freezes that arithmetic.

### 6. Test seam and structural gates

The pre-start proof runner uses the same compile-time test-only selection as
Provisioner and Reconciler. Production always resolves to `GitRunner`.

Structural tests enforce:

- `AgentStart.start/5` is the only production constructor/path for the opaque
  Workspace pre-start reference;
- `pre_start_ref:` has only the approved production call site;
- core `Template.PreStart` contains no Workspace, Git, task, provider, flavor,
  recipe, or plugin vocabulary;
- no production runtime proof/executor/retirement implementation is selected
  through Application environment;
- provision schema and all Plan C migrations contain no secret-like fields,
  using token-aware patterns that reject at least `access_token`, `auth_blob`,
  `key_material`, `credential_ref`, `authorization_header`, `private_key`,
  `secret`, `credential`, and environment payloads while allowing lifecycle
  claim tokens;
- only the Workspace reconciler canonical path can invoke destructive worktree
  removal.

Tests may use explicit compile-time seams. They must save and restore singleton
state and cannot make a fake perform helper-owned lineage/inventory duties.

## State-machine invariants

- There is at most one active provision, start, or cleanup claim for one row.
- A token from an expired or replaced claim cannot perform or commit an effect.
- `ready` means exact Git proof passed and the start token is unconsumed.
- `starting` means the token is consumed and the sidecar outcome is ambiguous
  until fenced completion or recovery.
- `sidecar_started` means final shared spawn obligations and Workspace
  completion both succeeded.
- `cleanup_pending` invalidates all unused claims and is the only entry to
  destructive reconciliation.
- No recovery path enumerates filesystem directories to invent durable work.
- A generation is never started twice, including after a crash.

## Error handling

- Missing/invalid Git proof before start: `:workspace_not_ready`, followed by a
  fenced cleanup request.
- Branch or commit mismatch: `:workspace_checkout_mismatch`.
- Dirty pre-start worktree: `:workspace_not_clean`.
- Fetch/transport unavailability: `:checkout_unavailable`; it does not become a
  destructive invalidity proof for an already-ready row.
- Lost start claim: `:sidecar_start_claim_lost`; the stale caller performs no
  durable transition or cleanup effect.
- Expired starting recovery: retire if present or accept sanctioned
  `:no_such_actor`, then remove the exact worktree and mark cleaned.

Closed errors should preserve the existing public error vocabulary where
possible. New detailed reasons remain internal blockers unless a caller needs
to distinguish a safe retry from terminal policy denial.

## Verification requirements

The implementation is not complete until tests prove:

1. a real fresh Template Class completes only after helper-owned lineage,
   workspace binding, inventory, and post-spawn obligations;
2. process death and simulated node restart after `ready -> starting` converge
   through retirement and terminal cleanup;
3. stale start workers cannot mark started or request destructive cleanup after
   lease takeover;
4. ready-to-start mutation to another commit, branch, or dirty tree prevents
   instantiate;
5. reused cache sees a newly created base ref and a moved base ref after fetch;
6. the deterministic branch and resolved commit persist and round-trip across
   recovery;
7. concurrent provision/start/cleanup attempts preserve one Git effect and one
   sidecar start;
8. unauthorized/private requests still produce zero row, path, Git process, and
   sidecar effects;
9. structural gates above fail on representative forbidden fixtures;
10. the signed end-to-end path uses the real fresh spawn lifecycle rather than
    a probe that writes helper-owned stores.

Affected app suites, architecture/document/URI/lifecycle gates, and project
precommit must be rerun. Known unrelated branch-baseline failures must be
reported separately and cannot be attributed to this hardening.

## Migration and compatibility

Use a new forward migration; do not edit the three existing Plan C migrations.
Existing non-terminal Plan C rows lack commit/branch/start-lease proof and
cannot be trusted. The migration or a bounded boot transition must move them to
`cleanup_pending` with an explicit upgrade reason. Existing `cleaned` rows may
remain terminal.

No compatibility path may infer a commit or branch from an existing worktree.
That would make filesystem state a second source of truth and reintroduce the
reviewed defect.

## Explicit non-goals

- private repository checkout or credentials;
- pushing `allowed_head_ref` or creating a change request;
- preserving uncommitted work across cleanup;
- cross-node distributed Git cache locks;
- a periodic unbounded reaper;
- changing CapBAC, repository consent, provider backends, recipes, or
  `plugin_cc`.
