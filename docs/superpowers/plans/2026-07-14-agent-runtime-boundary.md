# AgentRuntime Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define and enforce the boundary that Session may request Agent control operations but may not own Agent materialization, liveness, executor, credential/config or destruction mechanics.

**Architecture:** Keep `Ezagent.LocalRuntime` as the generic core primitive and place Agent control ownership in `ezagent_domain_agent`. First land an exact inventory and AST architecture gate with a stale-checked debt allowlist; later slices move the existing Session-owned Agent facade and lifecycle call sites behind a narrow command-shaped domain-agent API.

**Tech Stack:** Elixir 1.19, ExUnit, Elixir AST (`Code.string_to_quoted!/2`, `Macro.prewalk/3`), Mix architecture gates, ezagent core/domain umbrella conventions.

## Global Constraints

- Do not add a generic `Ezagent.AgentRuntime` module to core.
- Do not add a Command Bus, Port behaviour or adapter registry.
- Do not weaken Invocation/Lifecycle, CapBAC, workspace-owner or audit semantics.
- Scan every `apps/ezagent_domain_session/lib/**/*.ex` production source dynamically.
- Gate Agent lifecycle ownership, not every Session→Agent reference.
- Allowlist entries are exact, justified, stale-checked and target empty.
- No compatibility shim may leave two permanent Agent facade homes.
- Live credential provisioning is a separate operational track and never enters this branch.
- PR #1375/#1379 semantics are absorbed, but their unreviewed heads are never merged or cherry-picked into this branch.
- Final source anchors and live credential acceptance wait for #1375; capability-issuing facade work waits for #1379.
- Run `mix precommit` after all repository changes.

---

### Task 1: Freeze the current lifecycle-crossing inventory

**Files:**
- Modify: `docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md`
- Create: `docs/superpowers/notes/2026-07-14-agent-runtime-boundary-inventory.md`

**Interfaces:**
- Consumes: approved ownership vocabulary and allow/deny semantics from the design.
- Produces: a closed table of `%{path, line, resolved_call, class, disposition, migration_slice}` entries used by Task 2's allowlist.

- [ ] **Step 1: Enumerate candidate production calls**

Run:

```bash
rg -n "spawn_from_|SpawnRegistry\.(spawn|spawn_detailed|ensure_live)|Lifecycle\.destroy|SessionManager\.(ensure_started|stop)|Sandbox\.(destroy|read_persisted_state)|Domain\.Pty" \
  apps/ezagent_domain_session/lib
```

Expected: candidates from SessionCreator, TemplateTeam, delivery, teardown,
orchestrator tools/participants and the current `Ezagent.Domain.Agent` facade.

- [ ] **Step 2: Classify every candidate**

Write a row for every hit using exactly these dispositions:

```markdown
| Path:line | Resolved call | Class | Agent target proof | Disposition | Slice |
|---|---|---|---|---|---|
| `...` | `Ezagent.Entity.Agent.spawn_from_template_content/2` | `agent_materialization` | explicit Agent module | allowlisted debt | ARB-3 |
```

Allowed classes are:

```elixir
[
  :agent_materialization,
  :agent_ensure_live,
  :agent_executor_control,
  :agent_destroy,
  :agent_config_or_credential_control,
  :legal_session_lifecycle,
  :legal_conversation_or_read
]
```

- [ ] **Step 3: Prove the inventory is closed**

Repeat the search with `KindRegistry`, `LocalRuntime`, `Invocation.dispatch` and
wrapper function definitions. Add every new hit or explicitly state why it is outside
the closed lifecycle API family.

Run:

```bash
rg -n "KindRegistry|LocalRuntime|Invocation\.dispatch|def .*spawn|def .*destroy|def .*ensure" \
  apps/ezagent_domain_session/lib
```

Expected: no unexplained lifecycle candidate remains.

- [ ] **Step 4: Self-review the inventory**

Check that Session destroy, SessionTemplate rehydration, membership reads and member
business dispatch are classified as legal rather than accidentally allowlisted debt.

- [ ] **Step 5: Commit the inventory**

```bash
git add docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md \
  docs/superpowers/notes/2026-07-14-agent-runtime-boundary-inventory.md
git commit -m "docs(agent): classify session runtime boundary crossings"
```

**Upstream checkpoint:** Before calling this inventory frozen, fetch `main` and check
PR #1375. While it is pending, mark its changed `session_creator/materializer.ex`
entries as `anchor_pending_1375`; do not encode their current line numbers in the gate.

### Task 2: Add an AST scanner with teeth fixtures

**Files:**
- Create: `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex`
- Create: `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs`

**Interfaces:**
- Consumes: Task 1's closed lifecycle classes and resolved calls.
- Produces: `EzagentCore.AgentRuntimeBoundaryScanner.scan_source/2` and
  `scan_paths/1`, returning structured offender maps.

- [ ] **Step 1: Write failing fixture tests for qualified and aliased calls**

Add tests with these planted sources:

```elixir
test "scanner catches qualified Agent materialization" do
  source = """
  defmodule BadSession do
    def run(content), do: Ezagent.Entity.Agent.spawn_from_template_content(content)
  end
  """

  assert [%{class: :agent_materialization}] = Scanner.scan_source("bad.ex", source)
end

test "scanner catches aliased Agent materialization" do
  source = """
  defmodule BadSession do
    alias Ezagent.Entity.Agent
    def run(content), do: Agent.spawn_from_template_content(content)
  end
  """

  assert [%{class: :agent_materialization}] = Scanner.scan_source("bad.ex", source)
end
```

- [ ] **Step 2: Write negative precision tests**

Plant legal sources for:

```elixir
Ezagent.Lifecycle.destroy(session_uri, :session_delete)
Ezagent.SpawnRegistry.ensure_live(session_template_uri)
Ezagent.Invocation.dispatch(member_invocation)
Ezagent.KindRegistry.lookup(member_uri)
```

Expected: `Scanner.scan_source/2 == []` for each fixture unless the source explicitly
uses an Agent-specific forbidden seam.

- [ ] **Step 3: Run the focused tests and verify failure**

Run:

```bash
mix test apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs
```

Expected: compilation failure because the scanner module does not exist.

- [ ] **Step 4: Implement the minimal AST scanner**

Implement:

```elixir
defmodule EzagentCore.AgentRuntimeBoundaryScanner do
  @spec scan_source(Path.t(), String.t()) :: [map()]
  def scan_source(path, source) do
    ast = Code.string_to_quoted!(source, warn_on_unnecessary_quotes: false, emit_warnings: false)
    aliases = collect_aliases(ast)

    {_ast, offenders} =
      Macro.prewalk(ast, [], fn node, acc ->
        case classify_call(node, aliases, path) do
          nil -> {node, acc}
          offender -> {node, [offender | acc]}
        end
      end)

    Enum.reverse(offenders)
  end

  @spec scan_paths([Path.t()]) :: [map()]
  def scan_paths(paths) do
    Enum.flat_map(paths, fn path -> scan_source(path, File.read!(path)) end)
  end
end
```

Keep the forbidden table closed and explicit. Do not implement speculative dataflow
or classify every `Lifecycle.destroy/2` as agent destruction.

- [ ] **Step 5: Run fixtures and verify pass**

Run:

```bash
mix test apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs
```

Expected: qualified/alias positive fixtures are detected and legal negative fixtures
produce no offenders.

- [ ] **Step 6: Commit the scanner and fixture tests**

```bash
git add apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex \
  apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs
git commit -m "test(arch): detect session-owned agent lifecycle calls"
```

### Task 3: Enforce the repository gate with an exact debt allowlist

**Files:**
- Modify: `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs`
- Modify: `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex`

**Interfaces:**
- Consumes: Task 1 inventory and Task 2 structured offenders.
- Produces: a repository-wide gate over all Session production sources and a
  stale-allowance invariant.

**Upstream prerequisite:** PR #1375 must be merged and this branch rebased before
final repository source anchors are committed. Tasks 1–2 may proceed while it is
pending.

- [ ] **Step 1: Write the failing repository scan assertion**

Discover files dynamically:

```elixir
@session_glob Path.join([
  @repo_root,
  "apps",
  "ezagent_domain_session",
  "lib",
  "**",
  "*.ex"
])

paths = Path.wildcard(@session_glob)
assert paths != []
offenders = Scanner.scan_paths(paths)
```

Assert that every non-legal offender is either absent or matched by one exact
allowlist entry.

- [ ] **Step 2: Run and capture the unallowlisted failure**

Run:

```bash
mix test apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs
```

Expected: failure listing every current Session-owned Agent lifecycle crossing.

- [ ] **Step 3: Add only inventory-backed allowances**

Use this exact shape:

```elixir
@allowlist [
  %{
    path: "apps/ezagent_domain_session/lib/...ex",
    class: :agent_materialization,
    source_anchor: "Ezagent.Entity.Agent.spawn_from_template_content(",
    reason: "ARB-3 materialization cutover"
  }
]
```

Do not add a path-only or class-only allowance. Every entry must correspond to one
Task 1 row and one future migration slice.

- [ ] **Step 4: Add stale-entry and one-to-one-match tests**

Assert:

```elixir
assert unmatched_allowances == []
assert multiply_matched_allowances == []
assert unallowlisted_offenders == []
```

Plant a fake stale allowance in an isolated unit fixture and verify the validator
reports it.

- [ ] **Step 5: Run the focused architecture gate**

Run:

```bash
mix test apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs
```

Expected: PASS with all current debt explicit and no stale allowance.

- [ ] **Step 6: Run architecture and invariant suites**

Run:

```bash
mix test apps/ezagent_core/test/architecture apps/ezagent_core/test/invariants
```

Expected: PASS.

- [ ] **Step 7: Commit the repository gate**

```bash
git add apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs \
  apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex
git commit -m "test(arch): enforce agent runtime ownership boundary"
```

### Task 4: Perform the adversarial design and gate review

**Files:**
- Create: `docs/superpowers/reviews/2026-07-14-agent-runtime-boundary-review.md`
- Modify: `docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md`
- Modify if required: `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs`
- Modify if required: `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex`

**Interfaces:**
- Consumes: approved design, complete inventory and passing gate.
- Produces: a `SOUND` or `NOT SOUND` verdict with every finding resolved or explicitly
  lead-adjudicated.

- [ ] **Step 1: Review architecture ownership**

Check:

- no Agent vocabulary moved into core runtime code;
- no domain-agent→domain-session or domain-agent→plugin compile edge is proposed;
- the existing Invocation/Lifecycle grammar remains authoritative;
- the facade does not hide caller/workspace/CapBAC context.

- [ ] **Step 2: Attack gate bypasses**

Try fixtures for:

- alias calls;
- multi-alias calls;
- imported/wrapped calls included in the v1 policy;
- a new Session file outside today's inventory;
- one-old-offender-deleted plus one-new-offender-added;
- comments and moduledocs containing forbidden names.

- [ ] **Step 3: Attack false positives**

Try legal Session/SessionTemplate lifecycle operations, membership reads and member
Invocation dispatch. Record whether each stays green.

- [ ] **Step 4: Record and resolve findings**

The review document must use:

```markdown
| Severity | Finding | Evidence | Resolution |
|---|---|---|---|
```

Do not issue `SOUND` while a critical/high boundary bypass or ownership contradiction
remains.

- [ ] **Step 5: Commit review-driven revisions**

```bash
git add docs/superpowers/reviews/2026-07-14-agent-runtime-boundary-review.md \
  docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md \
  apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs \
  apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex
git commit -m "docs(agent): close runtime boundary adversarial review"
```

### Task 5: Run final gates and prepare the code-track return

**Files:**
- Create: `docs/together/2026-07-14/returns/gagameow-agent-runtime-boundary.md`

**Interfaces:**
- Consumes: Tasks 1–4 and the dev-together return standard.
- Produces: a return with per-line DoD reconciliation, gate evidence and lead merge
  request.

- [ ] **Step 1: Format only touched Elixir files**

Run:

```bash
mix format \
  apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex \
  apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs
```

- [ ] **Step 2: Run focused and architecture tests**

Run:

```bash
mix test apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs
mix test apps/ezagent_core/test/architecture apps/ezagent_core/test/invariants
```

Expected: PASS.

- [ ] **Step 3: Run complete repository gates**

Run:

```bash
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.uri_query.scan
mix ezagent.check_invariants
mix precommit
```

Expected: every command exits 0.

- [ ] **Step 4: Rebase and verify the PR head**

```bash
git fetch origin main
git rebase origin/main
mix precommit
```

Expected: clean rebase and exit 0 after the post-rebase gate.

- [ ] **Step 5: Write the return**

Include:

- `returned_at`, deadline and deadline status;
- every code-track DoD line with its evidence;
- the exact current-debt allowlist and ARB-2..ARB-5 owners;
- Codex verdict;
- local commands and PR-head CI link;
- explicit statement that credential provisioning is tracked separately.

- [ ] **Step 6: Commit the return**

```bash
git add docs/together/2026-07-14/returns/gagameow-agent-runtime-boundary.md
git commit -m "docs(together): return agent runtime boundary gate"
```

### Task 6: Execute the separate credential operations track

**Files:**
- Create only if lead requires a repository artifact:
  `docs/together/2026-07-14/returns/gagameow-demo-agent-credentials.md`

**Interfaces:**
- Consumes: authenticated World access, the current deployment inventory and an
  operator-approved credential source.
- Produces: redacted before/after/restart/call evidence; no credential material.

**Upstream prerequisite:** PR #1375 must be merged and deployed. Its Manage-cap PTY
contract is what makes creator-owned Terminal `/login` both reachable and private.
Do not substitute an admin-only path and claim the creator flow passed.

- [ ] **Step 1: Inventory credential-bearing demo agents**

Use World Identities/agent detail. Record only:

```text
agent URI | flavor | normalized credential status | checked_at
```

Expected: `test-zyli-cc-1` is included and the list is based on live deployment,
not repository name search.

- [ ] **Step 2: Capture safe before evidence**

Capture `missing` or `expired` status. Do not capture config path, credential content,
hash, token, environment or shell trace.

- [ ] **Step 3: Provision through the sanctioned path**

Preferred: open the target agent Terminal and run:

```text
claude /login
```

Fallback only with operator approval and the detail-reported directory:

```bash
mix ezagent.demo.seed_cc_sandbox \
  --name <agent-name> \
  --sandbox-dir <detail-reported-config-dir> \
  --credentials-file <operator-owned-source>
```

Do not use `--force` unless the lead explicitly approves replacement.

- [ ] **Step 4: Verify normalized status**

Refresh agent detail.

Expected: status is `authenticated`, not merely “file exists.”

- [ ] **Step 5: Verify the product call**

Invoke the target agent through the normal session/product entry and retain a redacted
success transcript containing the target URI and response but no secrets.

- [ ] **Step 6: Verify restart persistence**

Restart the target through the sanctioned product/operator path, then repeat the
normal product call.

Expected: authenticated status and successful reply survive restart.

- [ ] **Step 7: Return redacted evidence separately**

If a committed return is required, verify before staging:

```bash
rg -n "credentials|token|secret|CLAUDE_CONFIG_DIR|/data/|sha256|Bearer" \
  docs/together/2026-07-14/returns/gagameow-demo-agent-credentials.md
```

Expected: only explanatory prose or redacted field names; no values or sensitive paths.

## Parallel Execution Map

The implementation can use multiple subagents with these boundaries:

| Worker | Work | Parallel? | Write ownership |
|---|---|---|---|
| A | Task 1 inventory | Yes, initially | inventory note only |
| B | Task 2 fixture/scanner prototype | Yes after classifier vocabulary freezes | scanner + gate test exclusively |
| C | Task 4 architecture review | Starts after Tasks 1–3 | review doc; code only through owner handback |
| D | Task 6 live credential inventory/evidence | Yes | deployment state + separate return only |

Tasks 2 and 3 must use the same code owner because scanner, allowlist and gate tests
share tight state. Task 4 is sequential after the gate exists. Credential writes for
one target agent must never be performed concurrently by multiple workers.

## Upstream Dependency Matrix

| Work item | #1375 | #1379 | May start now? |
|---|---|---|---|
| Design/SPEC update | semantic input | semantic input | Yes |
| Lifecycle inventory | final anchor dependency | none | Yes, anchors provisional |
| AST scanner fixtures | none | none | Yes |
| Exact repository allowlist | rebase/final anchors | none | No finalization |
| Creator Terminal `/login` evidence | merged + deployed | none | No |
| Facade capability issuance/store | policy context | merged chokepoint | No |
| Facade lifecycle API without new grants | policy context | review constraint | Design only |
