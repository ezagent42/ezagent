# AgentRuntime Boundary Adversarial Review

**Date:** 2026-07-14

**Reviewed scope:** approved boundary design, ARB-0 inventory, ARB-1 scanner and
architecture gate

**Verdict:** **SOUND**

The ownership design is coherent, and the exact debt allowlist has the intended
stale-entry and replacement resistance. Commit `f44638811` closes the original
plain grouped-alias and imported-local-call reproductions. Commit `ff62aa368` closes
the remaining option-bearing grouped-alias bypass. Independent replay now detects
both attack forms, and no Critical/High finding remains open.

## Findings

| Severity | Finding | Evidence | Resolution |
|---|---|---|---|
| High | Grouped aliases with options bypassed the classifier. The plain `alias Ezagent.Entity.{Agent, User}` form was fixed first, but `alias Ezagent.Entity.{Agent, User}, warn: false` followed by `Agent.spawn_from_manifest/1` still returned `[]` because the walker matched only a one-element alias argument list. | Independent replay against `ff62aa368` now returns one `agent_materialization` offender for the option-bearing form. The permanent exact fixture is at `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs:346-357`; the walker accepts the optional alias argument tail at `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex:101-119`. | **Resolved by `ff62aa368`.** Grouped aliases with and without keyword options are registered lexically and the forbidden call is detected. |
| High | An imported forbidden function bypassed the classifier. `import Ezagent.Entity.Agent, only: [spawn_from_manifest: 1]` followed by local `spawn_from_manifest/1` previously returned `[]`. | Reproduction against `f44638811` now returns one `agent_materialization` offender. An aliased import (`alias ... as: A; import A`) also returns one offender, while imports remain lexical: calls before the import and outside a nested/sibling scope remain unclassified. The permanent positive fixture is at `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs:358-368`. | **Resolved by `f44638811`.** The scanner records imported modules lexically and classifies matching local calls. |
| Info | A Session wrapper does not conceal a forbidden remote seam when the wrapper body retains an explicit Agent target. | A fixture whose `run/1` calls a local helper and whose helper calls `Ezagent.SpawnRegistry.ensure_live(agent_uri)` produced one `agent_ensure_live` offender anchored to `defp:helper/1`. This follows the wrapper prohibition at design lines 148-156. | Resolved by the existing recursive AST walk for the tested v1 wrapper form. General interprocedural dataflow is explicitly out of scope. |
| Info | Dynamic file discovery and exact allowlist identity resist two common count-gate attacks. A new file containing a qualified Agent spawn is detected; deleting one old offender and adding the same call in a new path yields both a stale allowance and an unallowlisted offender. | Repository discovery uses `Path.wildcard` over `apps/ezagent_domain_session/lib/**/*.ex` at `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs:4-12,188-195`. The replacement fixture returned one `unmatched_allowance` and one `unallowlisted_offender`; exact matching includes path, class and source anchor at `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex:368-374`. | Resolved for recognized call forms. The alias/import bypasses remain independent of allowlist exactness. |
| Info | Comments and moduledocs containing forbidden names do not produce false positives. | A fixture containing the forbidden call spelling only in a comment and `@moduledoc` returned `[]`; parsing plus call-node classification ignores strings and comments. | Resolved. |
| Info | Legal Session/SessionTemplate lifecycle, membership reads and member dispatch stay green in the tested syntax-only policy. | Fixtures for `Lifecycle.destroy(session_uri, ...)`, `SpawnRegistry.ensure_live(session_template_uri)`, `Invocation.dispatch(member_invocation)` and `KindRegistry.lookup(member_uri)` all returned `[]`; permanent negatives begin at `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs:370`. | Resolved. Keep these negative fixtures when closing the two high findings. |

## Architecture ownership assessment

The proposed owner split is sound independently of the scanner defects:

- Core retains only URI/Kind locality primitives; the design explicitly rejects a
  core `Ezagent.AgentRuntime` and keeps `Ezagent.LocalRuntime` generic
  (`design.md:28-35,328-336`).
- The dependency direction is Session → domain-agent, never domain-agent → Session
  or domain-agent → flavor plugin (`design.md:122-135`). The current
  `ezagent_domain_agent` dependency list contains core, identity and agent-bridge,
  but no Session or plugin OTP dependency
  (`apps/ezagent_domain_agent/mix.exs:38-51`).
- Invocation/Lifecycle remains authoritative; the facade is command-shaped without
  adding a command bus or port registry (`design.md:86-99`).
- Caller, workspace and authority context must remain explicit and authorization is
  delegated to existing CapBAC chokepoints (`design.md:88-94,280-290`). PTY policy
  stays with `Ezagent.Domain.Pty.Access` and capability issuance stays with
  `Ezagent.Cap.issue/3` (`design.md:41-46,101-104`).

These are design obligations for ARB-2 through ARB-4; this review does not claim
that the not-yet-implemented facade already satisfies them.

## Closure verification

The final review replay verified:

- `alias Ezagent.Entity.{Agent, User}, warn: false` followed by the forbidden Agent
  call returns one `agent_materialization` offender;
- `import Ezagent.Entity.Agent, only: [spawn_from_manifest: 1]` followed by the local
  forbidden call returns one `agent_materialization` offender;
- the focused architecture suite passes with 23 tests and 0 failures;
- legal Session/SessionTemplate lifecycle, membership reads, member dispatch, exact
  allowances and stale-entry checks remain covered by the same suite.

No scanner or gate source was modified by this review. All Critical/High findings
are closed, so the ARB-0/ARB-1 design and gate are `SOUND` for their documented
syntax-only scope.
