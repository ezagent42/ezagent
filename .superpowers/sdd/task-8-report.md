# Task 8 report

Baseline: `6a3100d7ff574b386d4ffc5294d16ff13295e95b`

## RED evidence

- Focused structural/E2E run: 12 tests, 2 failures.
- Failures were the intended core-template vocabulary violation (`flavor_hook.ex`) and signed fixture returning `fresh?: false`.
- After correcting the exact-file scan helper, the boundary-only run showed both intended structural failures: core vocabulary and the `PreStart` application-env runner seam.

## Structural gates

- Production `pre_start_ref:` callers: exactly 1, allowlisted only as `apps/ezagent_domain_workspace/lib/ezagent/workspace/task_workspace/agent_start.ex`.
- Production `AgentStart.start(` callers: exactly 0.
- Core template forbidden-vocabulary offenders: 0.
- `PreStart` configurable-runner-seam offenders: 0.
- Parsed durable schema fields: 30.
- Parsed task-workspace migration `add` tokens: 5.
- Forbidden secret-field offenders after exact lifecycle-name handling: 0.
- Exact lifecycle names handled: `claim_token`, `start_token`, `start_claim_token`, `start_token_consumed_at`, `cleanup_reason`, `cleaned_at`.

## Signed fresh E2E

- Template Class returns `fresh?: true` and performs no lineage, inventory, workspace, or flavor-helper writes.
- `TemplateSpawn` owns workspace binding, lineage, and creation inventory.
- E2E asserts creation attempt, exact owner lineage, and durable `:sidecar_started` before cleanup.
- Cleanup asserts sanctioned retirement, exact Git/filesystem worktree absence, and terminal `:cleaned`.
- Existing commit, branch, and dirty-tree real-mutation cases remain in the signed E2E.

## GREEN evidence

- Focused structural/E2E/dependency run: 14 tests, 0 failures.
- Exact complete hardening suite from the brief: 106 tests, 0 failures.
- Renamed generic core attribute-hook suite: 7 tests, 0 failures.
- `git diff --check`: clean.

No push, merge, rebase, deploy, or `mix precommit` was run. The unrelated handoff file was preserved and excluded from the commit.

## Secret-scanner follow-up

The original regex scanner under-counted parenthesized migration calls. This follow-up replaces it with `Code.string_to_quoted!/1` plus AST traversal of actual local `field` and `add` call nodes, including nested module/block forms while excluding comments and string contents.

- Explicit schema files scanned: 1 task-workspace provision schema.
- Explicit migration files scanned: 4 (`17001000`, `17002000`, `17003000`, `17004000`).
- Actual schema field calls: 30.
- Actual migration add calls: 30 (correcting the earlier regex-derived count of 5).
- Supported and mutation-tested forms: `field(:name, ...)`, `field :name, ...`, `add(:name, ...)`, and `add :name, ...`.
- Mutation coverage proves `credential_ref` is rejected in all four forms, exact lifecycle names are allowed, `claim_token_credential_ref` is still rejected, and deceptive comment/string contents are not treated as calls.
- RED: boundary test compilation failed because the AST extractor/classifier did not exist.
- GREEN: boundary 11 tests, focused Task 8 16 tests, and complete hardening suite 108 tests; all had 0 failures.

## Atomic ownership receipt follow-up

- Froze the sole TaskWorkspace launch-authority issuance site and `pre_start_ref:` constructor site.
- Added AST-aware gates that keep the opaque context out of authored maps, logging, telemetry, serialization, environment, argv, files/config, and rendered errors, while forbidding Core field reads/destructuring.
- Added receipt schema/migration secret checks, a `20260717005000*` migration ban, and a Core ownership-implementation purity gate.
- Extended the plugin locality gate to reject receipt, lineage, WorkspaceRegistry, TaskWorkspace persistence, and launch-authority access. Four historical WorkspaceRegistry writes are pinned by exact file/line/call entries; no Plan C receipt access is allowlisted.
- Signed winner E2E pauses deterministically after receipt commit, verifies exact attempt/agent/root/workspace facts, then proves cleanup retires the exact attempt.
- Signed adopted E2E proves there is no receipt and cleanup emits no retirement.
- RED: the new plugin gate found four historical WorkspaceRegistry calls; the first leak scanner also rejected legitimate in-memory relay plumbing, motivating the sink-aware AST gate.
- GREEN: focused Task 8 run reported Core 7 tests and Workspace 19 tests, all with zero failures.

## Review closure

- Replaced the Plan C plugin ownership line regex with AST call analysis that resolves ordinary, renamed, and grouped aliases; imported local calls; multiline remote calls; and `apply/3`. Historical WorkspaceRegistry debt is now allowlisted only by exact file, enclosing function, module, and call identity.
- Replaced spelling-only secrecy checks with taint propagation through rebinding plus explicit authored, persistence, restart-retention, process, external, observability, serialization, and rendered-error sinks. Negative mutants cover atom/string keys, Repo aliases, Ecto, snapshots, persistent term, ETS, process dictionary/state/messages, argv/env/config, logs, telemetry, serialization, and errors.
- Froze the branch migration budget to the four existing `20260717001000`–`04000` files; a differently numbered `20260718001000` receipt migration is mutation-tested as forbidden.
- Signed winner cleanup now asserts the actual `retirement_facts` facade payload matches the post-commit facts for attempt, Agent, provenance root, and workspace. The adopted flow asserts neither retirement message form is emitted.
- Review-closure focused run: Core 9 tests and Workspace 19 tests, all with zero failures.

## Lexical-flow review closure

- Plugin ownership analysis now tracks module values assigned to variables per enclosing function and source line, including rebinding, variable remote calls, variable-module `apply/3`, alias chains, and quoted `unquote` generation. A safe module rebind is mutation-tested as a non-violation.
- Launch authority taint now starts from real `:launch_context` map/keyword patterns, `Keyword`/`Map` extraction, and launch authority/relay operations. It propagates in lexical function scope through renamed values and containers, clears on safe shadowing, and resolves aliased or variable sink modules.
- Authored-map exceptions are pinned to exact file, function, kind, and source line rather than whole functions. A second map in the sanctioned `prepare/1` function followed by serialization is mutation-tested as forbidden.
- Final focused verification: Core 9 tests and Workspace 19 tests, all with zero failures.

## Nested-scope and call-flow review closure

- Nested `fn`/branch/quote assignments no longer replace an outer forbidden plugin module binding; same-scope safe rebinding remains supported. Mutants cover nested `fn`, `if`, and quoted shadowing before outer `apply/3`.
- Authority taint treats nested safe assignments conservatively without clearing the outer handle, retains sink-module identity at earlier call sites despite later safe rebinding, and summarizes local helper sinks by exact parameter position through a bounded callgraph fixpoint.
- Reviewer mutants for nested handle shadowing, serializer use before later rebinding, and `sink(handle) -> helper(value) -> Jason.encode!` are all enforced.
