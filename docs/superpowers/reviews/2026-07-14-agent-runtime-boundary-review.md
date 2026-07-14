# AgentRuntime Boundary Adversarial Review

**Date:** 2026-07-14

**Reviewed scope:** approved boundary design, ARB-0 inventory, ARB-1 scanner and
architecture gate

**Verdict:** **NOT SOUND**

The ownership design is coherent, and the exact debt allowlist has the intended
stale-entry and replacement resistance. The ARB-1 scanner nevertheless has two
high-severity alias/import bypasses. Both can express calls that the design marks
forbidden while producing no offender. The boundary therefore cannot receive a
`SOUND` verdict until those call forms are either detected or structurally forbidden
by another gate.

## Findings

| Severity | Finding | Evidence | Resolution |
|---|---|---|---|
| High | A grouped alias bypasses the classifier. `alias Ezagent.Entity.{Agent, User}` followed by `Agent.spawn_from_manifest/1` returns `[]`. The walker only accepts an `alias` whose first argument is a plain `__aliases__` node, so the grouped-alias AST is not registered. | Reproduction: `Scanner.scan_source/2` returned `[]` for the grouped-alias fixture. Scanner alias pattern: `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex:100`; the design requires aliased forbidden calls to be detected: `docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md:181-186,350-352`. | **Unresolved.** Extend lexical alias handling to grouped aliases and add a positive regression fixture. Until then the gate is bypassable. |
| High | An imported forbidden function bypasses the classifier. `import Ezagent.Entity.Agent, only: [spawn_from_manifest: 1]` followed by local `spawn_from_manifest/1` returns `[]`. The classifier recognizes only remote-call AST (`Module.function(...)`) and has no lexical import table. | Reproduction: `Scanner.scan_source/2` returned `[]` for the import fixture. Remote-only call pattern: `apps/ezagent_core/test/support/agent_runtime_boundary_scanner.ex:158-181`; direct Agent spawn is forbidden regardless of call spelling: `docs/superpowers/specs/2026-07-14-agent-runtime-boundary-design.md:148-156`. | **Unresolved.** Either resolve lexical imports and local calls, or add a separate fail-closed rule forbidding imports of the closed lifecycle modules in Session production code. Add positive and lexical-scope regression fixtures. |
| Info | A Session wrapper does not conceal a forbidden remote seam when the wrapper body retains an explicit Agent target. | A fixture whose `run/1` calls a local helper and whose helper calls `Ezagent.SpawnRegistry.ensure_live(agent_uri)` produced one `agent_ensure_live` offender anchored to `defp:helper/1`. This follows the wrapper prohibition at design lines 148-156. | Resolved by the existing recursive AST walk for the tested v1 wrapper form. General interprocedural dataflow is explicitly out of scope. |
| Info | Dynamic file discovery and exact allowlist identity resist two common count-gate attacks. A new file containing a qualified Agent spawn is detected; deleting one old offender and adding the same call in a new path yields both a stale allowance and an unallowlisted offender. | Repository discovery uses `Path.wildcard` over `apps/ezagent_domain_session/lib/**/*.ex` at `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs:4-12,188-195`. The replacement fixture returned one `unmatched_allowance` and one `unallowlisted_offender`; exact matching includes path, class and source anchor at scanner lines 265-271. | Resolved for recognized call forms. The alias/import bypasses remain independent of allowlist exactness. |
| Info | Comments and moduledocs containing forbidden names do not produce false positives. | A fixture containing the forbidden call spelling only in a comment and `@moduledoc` returned `[]`; parsing plus call-node classification ignores strings and comments. | Resolved. |
| Info | Legal Session/SessionTemplate lifecycle, membership reads and member dispatch stay green in the tested syntax-only policy. | Fixtures for `Lifecycle.destroy(session_uri, ...)`, `SpawnRegistry.ensure_live(session_template_uri)`, `Invocation.dispatch(member_invocation)` and `KindRegistry.lookup(member_uri)` all returned `[]`; permanent negatives are present at `apps/ezagent_core/test/architecture/agent_runtime_boundary_test.exs:334-375`. | Resolved. Keep these negative fixtures when closing the two high findings. |

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

## Required closure before `SOUND`

1. Make grouped aliases non-bypassable and add a positive test.
2. Make imported closed-family calls non-bypassable, or fail closed on imports of
   those modules, with lexical-scope tests.
3. Re-run the focused architecture test and this attack set.
4. Preserve the current legal-call negative fixtures and exact allowlist checks.

No scanner or gate source was modified by this review, so the two findings remain
open for the implementation owner.
