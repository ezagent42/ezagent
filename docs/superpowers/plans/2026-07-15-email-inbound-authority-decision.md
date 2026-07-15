# Email Inbound Authority Decision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make verified durable email binding evidence the single decision boundary for issuing one ephemeral, receiver-bound `session.send` capability.

**Architecture:** Add an email-owned `Ezagent.Email.Inbound.Authority` module that resolves the inbox address with one fresh durable projection/BindingRow join, authenticates the message, issues the narrow artifact, and returns explicit `ok/reject/retry` outcomes. `Inbound` retains polling, deletion, retry, threading, and dispatch responsibilities; the public arbitrary `Principal.mint/2` seam is removed.

**Tech Stack:** Elixir 1.19, Ecto 3.12/PostgreSQL, ExUnit, Ezagent CapBAC and Invocation dispatch.

## Global Constraints

- Loaded domain/plugin code is trusted; this change does not add an untrusted-plugin signer boundary.
- Signed/provenance-bearing artifacts are created only by `Ezagent.Cap.issue/3`.
- The synthetic receiver remains ephemeral and creates no Entity or capability store.
- A successful fresh durable join is the authorization linearization point; an in-flight dispatch may finish after concurrent unbind.
- Deterministic authorization denial deletes the inbox item; infrastructure inability to decide retains it.
- Do not add a rule registry, signer service, binding epoch, no-tail migration, signature-enforcement flip, or AgentRuntime work.

---

### Task 1: Pin the authority API and decision outcomes

**Files:**
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/inbound/authority.ex`
- Create: `apps/ezagent_plugin_email/lib/ezagent/email/inbound/authority/reader.ex`
- Modify: `apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs`
- Create: `apps/ezagent_plugin_email/test/inbound_authority_test.exs`
- Modify: `apps/ezagent_plugin_email/test/inbound_principal_test.exs`

**Interfaces:**
- Consumes: an inbox record map. Authority owns address resolution and the fresh durable join.
- Produces: `Authority.issue(record)` returning `{:ok, decision} | {:reject, reason} | {:retry, reason}`, where decision has `binding_row_id`, `session_uri`, `principal_uri`, and `caps`.

- [ ] **Step 1: Write failing API-surface and missing-evidence tests**

Add tests that assert `function_exported?(Ezagent.Email.Inbound.Principal, :mint, 2)` is false, that the email plugin source has exactly one production `Cap.issue` call in `inbound/authority.ex`, and that `Authority.issue/1` rejects an address with no durable projection/BindingRow pair. In the same RED change, replace every direct `Principal.mint/2` call in `inbound_principal_test.exs` with a wished-for `Authority.issue/1` fixture backed by a real verified BindingRow + InboundBinding pair. Preserve the one-cap, concrete-scope, cross-session denial, provenance, receiver-binding, and real `require_signature: true` assertions.

- [ ] **Step 2: Run the tests and confirm RED**

Run:

```bash
SHELL=/bin/bash mix test \
  apps/ezagent_plugin_email/test/inbound_authority_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_test.exs
```

Expected: compilation failure because `Authority` does not exist and assertion failure because `Principal.mint/2` is exported.

- [ ] **Step 3: Implement the minimal Authority shell**

Define:

```elixir
@type decision :: %{
        binding_row_id: String.t(),
        session_uri: URI.t(),
        principal_uri: URI.t(),
        caps: MapSet.t(Ezagent.Capability.t())
      }

@spec issue(map()) ::
        {:ok, decision()} | {:reject, atom()} | {:retry, term()}
```

Move synthetic principal creation, concrete `session.send` cap construction, behavior lookup, and `Cap.issue/3` into private functions in Authority. Remove `Principal.mint/2`; retain no public authority-bearing helper in Principal.

- [ ] **Step 4: Implement a fresh durable evidence read**

Use one Ecto query rooted at the normalized inbox `To:` address that left-joins `InboundBinding` to `BindingRow` and returns the fresh pair. A missing projection is `{:reject, :no_binding}`; a present projection with no parent is `{:reject, :binding_removed}`. Put the query in a narrow `Ezagent.Email.Inbound.Authority.Reader` module selected from application config, with that real module as the production default. Wrap only the reader call so reader exceptions become `{:retry, {:binding_reader_failed, exception}}`. Unit tests may replace the configured reader with a raising stub, while separate tests exercise the real Reader against Repo.

- [ ] **Step 5: Run focused tests and confirm GREEN**

Run the Task 1 command. Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_email/lib/ezagent/email/inbound/authority.ex \
  apps/ezagent_plugin_email/lib/ezagent/email/inbound/authority/reader.ex \
  apps/ezagent_plugin_email/lib/ezagent/email/inbound/principal.ex \
  apps/ezagent_plugin_email/test/inbound_authority_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_invariant_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_test.exs
git commit -m "fix(email): centralize inbound authority decisions"
```

### Task 2: Complete durable validation and pipeline result handling

**Files:**
- Modify: `apps/ezagent_plugin_email/lib/ezagent/email/inbound/authority.ex`
- Modify: `apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex`
- Modify: `apps/ezagent_plugin_email/test/inbound_authority_test.exs`
- Modify: `apps/ezagent_plugin_email/test/inbound_test.exs`
- Modify: `apps/ezagent_plugin_email/test/inbound_principal_test.exs`

**Interfaces:**
- Consumes: Task 1 `Authority.issue/1`.
- Produces: deterministic denials as `{:reject, reason}` and infrastructure/signing failures as `{:retry, reason}`; `Inbound.process_record/2` deletes rejects and retains retries.

- [ ] **Step 1: Write one failing test per evidence axis**

Cover unverified projection, session mismatch, adapter not `email`, target mismatch, projection/row workspace mismatch, session-derived workspace mismatch, non-entity `bound_by`, current-message authentication failure, and From mismatch. Each must return `{:reject, reason}` without producing caps.

- [ ] **Step 2: Write failing pipeline deletion/retry tests**

Assert deterministic binding mismatch returns `{:skipped, reason}` and invokes `delete_fun`; an Authority reader configured to raise returns `{:error, reason}` and does not invoke `delete_fun`; dispatch failure remains retained. Also configure an `authority_fun` through the existing per-record opts pattern to isolate Inbound's `reject` versus `retry` finalization without coupling that test to Repo.

- [ ] **Step 3: Run tests and confirm RED**

Run:

```bash
SHELL=/bin/bash mix test \
  apps/ezagent_plugin_email/test/inbound_authority_test.exs \
  apps/ezagent_plugin_email/test/inbound_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_test.exs
```

Expected: failures for unimplemented axis validation and unchanged generic inject-error handling.

- [ ] **Step 4: Implement exact validation**

After the fresh join, require:

```elixir
fresh_meta.verification_status == "verified"
fresh_meta.binding_row_id == row.id
fresh_meta.session_uri == row.session_uri
row.adapter_id == "email"
fresh_meta.target_id == row.target_id
fresh_meta.workspace_uri == row.workspace_uri
row.workspace_uri == URI.to_string(Ezagent.Capability.workspace_of(session_uri))
match?(%URI{scheme: "entity"}, binding_actor)
```

Then call `Guard.authenticated?/2`. Map durable/message failures to distinct `{:reject, reason}` results. Map `Cap.issue/3` errors and signing exceptions to `{:retry, {:cap_issue_failed, reason}}`.

- [ ] **Step 5: Integrate Authority into Inbound**

Remove `resolve_binding/1`, `verified_gate/1`, `binding_actor/2`, `binding_authority_matches?/3`, and direct `Principal.mint/2` use. After the bounce/auto-reply guard, call Authority with the record and pattern match results in the per-record pipeline:

```elixir
{:ok, decision} -> dispatch and existing success finalization
{:reject, reason} -> delete and return {:skipped, reason}
{:retry, reason} -> retain and return {:error, reason}
```

- [ ] **Step 6: Run focused tests and confirm GREEN**

Run the Task 2 command. Expected: all tests pass.

- [ ] **Step 7: Run real signature enforcement tests**

Run:

```bash
SHELL=/bin/bash mix test \
  apps/ezagent_plugin_email/test/inbound_principal_test.exs \
  apps/ezagent_core/test/ezagent/cap_test.exs \
  apps/ezagent_core/test/invariants/cap_issue_chokepoint_test.exs
```

Expected: receiver-bound real dispatch and signing/chokepoint tests pass.

- [ ] **Step 8: Commit**

```bash
git add apps/ezagent_plugin_email/lib/ezagent/email/inbound/authority.ex \
  apps/ezagent_plugin_email/lib/ezagent/email/inbound/authority/reader.ex \
  apps/ezagent_plugin_email/lib/ezagent/email/inbound.ex \
  apps/ezagent_plugin_email/test/inbound_authority_test.exs \
  apps/ezagent_plugin_email/test/inbound_test.exs \
  apps/ezagent_plugin_email/test/inbound_principal_test.exs
git commit -m "fix(email): classify inbound authority outcomes"
```

### Task 3: Evidence, review, and delivery

**Files:**
- Modify: `docs/together/2026-07-15/returns/capability-auth-followups.md`
- Modify if review requires: files changed in Tasks 1-2.

**Interfaces:**
- Consumes: completed authority implementation and test evidence.
- Produces: reviewed, rebased, pushed PR #1412 with accurate immutable evidence and green required checks.

- [ ] **Step 1: Run the full Email and impacted Cap suites**

```bash
SHELL=/bin/bash mix test apps/ezagent_plugin_email/test \
  apps/ezagent_core/test/ezagent/cap_test.exs \
  apps/ezagent_core/test/invariants/cap_issue_chokepoint_test.exs \
  apps/ezagent_core/test/invariants/entity_caps_access_gate_test.exs
```

Expected: zero failures.

- [ ] **Step 2: Run required gates**

```bash
mix ezagent.arch.scan
mix ezagent.doc.scan
mix ezagent.uri_query.scan
mix ezagent.check_invariants
SHELL=/bin/bash mix precommit
git diff --check
```

Record exact exits and distinguish branch regressions from failures reproduced on current `origin/main`; do not claim local green without zero exits.

- [ ] **Step 3: Request independent implementation review**

Review `origin/main..HEAD` against the approved spec. Fix every Critical and Important through a fresh TDD red/green cycle and request re-review until both counts are zero.

- [ ] **Step 4: Rebase and rerun impacted tests**

```bash
git fetch origin main
git rebase origin/main
```

Rerun Steps 1-2 proportionally after any conflict or new base commit.

- [ ] **Step 5: Update and commit the return record**

Record final base, implementation head, test red/green evidence, review result, gate results, PR URL, current-head CI URL/status, trust-model limitation, and remaining risks.

```bash
git add docs/together/2026-07-15/returns/capability-auth-followups.md
git commit -m "docs(together): update capability auth return"
```

- [ ] **Step 6: Push and wait for PR-head checks**

```bash
git push --force-with-lease
gh pr checks 1412 --watch --interval 10
```

Expected: all required checks pass; conditional jobs may skip by workflow policy. Do not merge; lead owns close.
