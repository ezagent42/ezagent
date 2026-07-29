# Git Provider V1 Plan E — Slice P4b: Authorization Surface (real ExecutionSeam backend) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fail-closed `Unavailable` seam backend with a real one that
obtains authorization through main's canonical pattern, and — the load-bearing
half — ship the tests that prove Git Provider's **policy layer** actually denies.
Design §3.4 (decision), §3.4.1 (the two-layer split), §3.4.2 (constraints).

**Depends on:** P4a (`%AuthorizedTask{}`, `ExecutionSeam.invoke/3`).

**Owner app:** `apps/ezagent_plugin_git_workflow`, plus new tests only.

---

## Read this before anything else — the finding this slice exists for

`Ezagent.ActionSet.GitTaskAccess` has the check that IS Git Provider's business
authorization:

```elixir
# apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex:337-356
defp authorize_receiver(policy, action, ctx) do
  caller = Map.get(ctx, :caller)
  if authorized_receiver?(action, caller, policy), do: :ok, else: {:error, :unauthorized}
end

defp authorized_receiver?(_action, caller, policy), do: caller == policy.grantee_uri
```

**It is currently untested. This was verified empirically, not inferred:**
replacing the whole function with `defp authorize_receiver(_, _, _), do: :ok`
and running `mix test apps/ezagent_domain_git/test` gives **170 tests, 0
failures**. (`apps/ezagent_domain_workspace/test` gained only two
`assert_receive`-after-100ms mailbox flakes under concurrent load — no
authorization denial anywhere.)

The reason no existing test catches it: every cap in every existing test is
issued **to `fixture.grantee_uri`**, so `caller == policy.grantee_uri` is always
true. The one test that dispatches as an attacker
(`git_task_dispatch_test.exs:106`) is denied by the **cap** gate (`:missing_cap`)
before `authorize_receiver` is ever reached, so it would pass unchanged with the
check deleted.

**Why this matters far more after design §3.4's decision.** Before it, the cap
was minted by a test fixture for one specific grantee, so the cap gate did real
work. After it, **this slice's backend mints the cap on demand for whoever it
computes the principal to be**. If that computation is wrong — reads the wrong
binding field, falls back to the credential owner, reuses a stale run — the
backend mints a cap that *matches*, the cap gate waves it through, and the only
thing standing between a mis-computed principal and a real Git mutation is
`authorize_receiver`. Which is untested.

**So the tests in Task 4 are not coverage-padding. They are the reason this slice
is reviewed separately (design §10).**

---

## Architecture

One new production module. `Unavailable` is **not deleted** — it stays as the
fallback and keeps its tests.

```
authorize(run, binding)  →  PURE. Build + validate the GitTaskAccess policy from
                            the two durable records, return {:ok, %AuthorizedTask{}}.
                            Starts nothing, dispatches nothing, writes nothing.

invoke(task, action, args) → TaskAccessSupervisor.ensure_started(policy)
                           → Cap.issue_for_action({:admin, User.admin_uri()},
                                                  grantee_uri, action_target)
                           → Invocation.dispatch(%Invocation{...})
```

Splitting it this way is deliberate: a denied `authorize/2` must spawn no Kind
(design §3.1 — "任何 backend 在返回 `{:error, _}` 时都必须零副作用").

---

## Global Constraints

- **`Cap.issue_for_action/3` ONLY. Never hand-build a `%Capability{}`.**
  `cap.ex:83-99` derives the requested shape from
  `Cap.Verifier.required_cap(kind_module, behavior_module, action, target)` — i.e.
  from the Kind's own declaration. That makes design §3.4.2's "no `:any`
  dimension" **structural**: there is no argument through which a wildcard could
  be introduced. `Capability.cap/5` + `Cap.issue/3` would reintroduce exactly
  that freedom — do not use them.
- **The principal is read, never derived.** `grantee_uri` comes from
  `binding.task_receiver_uri` and nothing else. `{:admin, User.admin_uri()}` is
  the **issuance anchor**, never the caller, never the principal, never written
  into `ctx.caller` or `ctx.authenticated_principal`.
- **Change the `Application.compile_env/3` DEFAULT**, not prod config.
  `architecture_test.exs:313` ("no non-test config file sets `:execution_seam`,
  in any spelling") must keep passing **unchanged**. If you find yourself editing
  that test, you have taken the wrong approach — stop and report.
- `ctx.caps` never leaves this backend. It is built inside `invoke/3`, travels
  with one `%Invocation{}`, and dies with the dispatch. It must not reach a
  workflow row, event, log line, error, or any other module.
- No new `system://` principal (design §3.2; `capbac.md` §10.5 — Decision-#154
  review surface).
- No token, credential, raw provider body, or file content anywhere.
- The `Ezagent.DomainGit` action vocabulary is FROZEN. This slice adds no
  callback and changes no signature.

---

## Task 1 — Derive the `GitTaskAccess` policy from the two durable records

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/policy_derivation.ex` (new)

Everything the policy needs is already durable. Nothing is invented at execution
time.

| `GitTaskAccess` field | Source | Note |
|---|---|---|
| `id` | derived from `run.id` | **must be deterministic** — see below |
| `task_uri` | `run.source_task_uri` | post-#1588 contract: a URI, not an id |
| `generation` | `run.binding_generation` | |
| `workspace_uri` | `binding.workspace_uri` | |
| `credential_owner_uri` | `binding.credential_owner_uri` | who lends the credential |
| `grantee_uri` | `binding.task_receiver_uri` | **the acting principal** |
| `repository` | `RepositoryRef.new/1` from `binding`'s `repository_uri` / `provider_adapter` / `provider_host` / `external_id` / `owner_path` / `base_ref` / `visibility` | |
| `provider_adapter` | `binding.provider_adapter` | |
| `allowed_head_ref` | `DeterministicRef.derive(binding.allowed_head_namespace, run.id)` | design §5.2 |
| `allowed_actions` | closed list, see below | |
| `idempotency_inputs` | `%{task_uri: run.source_task_uri, generation: run.binding_generation}` | |

- [ ] **`id` must be deterministic.** `Entity.GitTaskAccess.build_uri/1`
      (`entity/git_task_access.ex:324-333`) hashes the **entire policy struct**
      via `:erlang.term_to_binary([:deterministic])`, so `id` is part of the
      task-access URI's digest. A random `id` gives a *different* task-access URI
      on every retry — the Kind would be re-spawned, the cap re-targeted, and
      §8's "one PR / one ref" idempotency assertions would fail in a way that
      looks like a provider bug. Derive `id` from `run.id` (itself already
      `"run_" <> sha256_hex(...)`).
- [ ] `allowed_actions` is a closed list containing exactly the actions the
      workflow invokes. Start from the eight in `ActionSet.GitTaskAccess`'s
      `@actions` and **remove any the workflow never calls** — least privilege is
      the point, and an unused action in the list is authority nobody needs.
      Document the choice in the moduledoc.
- [ ] Return `{:ok, policy}` | `{:error, reason}` with reasons drawn from P4a's
      `Blocker` vocabulary. A binding whose `enabled` is false, or whose
      generation disagrees with the run's, is a denial — not a crash.
- [ ] The module must not read `ctx`, mint a cap, touch a supervisor, or dispatch.
      It is a pure function of two structs.

**Tests** — `test/ezagent_plugin_git_workflow/policy_derivation_test.exs` (new)

- [ ] Same `(binding, run)` twice → byte-identical policy AND identical
      `GitTaskAccess.uri_from_args/1`. This is the test that catches a
      non-deterministic `id`; assert the **URI**, not just the struct.
- [ ] `grantee_uri == binding.task_receiver_uri` — asserted by *changing*
      `task_receiver_uri` and observing the derived `grantee_uri` change, not by
      comparing two things that were both read from the same field.
- [ ] `credential_owner_uri` and `grantee_uri` are **distinct fields** and do not
      collapse: a binding whose two URIs differ produces a policy whose two
      fields differ.
- [ ] The derived policy passes `Entity.GitTaskAccess.revalidate/1`.
- [ ] `allowed_head_ref` equals `DeterministicRef.derive/2`'s output for that run.
- [ ] Disabled binding, generation mismatch → the documented denial, no raise.

---

## Task 2 — The real backend: `authorize/2`

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam/cap_backed.ex` (new)

- [ ] `@behaviour EzagentPluginGitWorkflow.ExecutionSeam`.
- [ ] `authorize(run, binding)`: derive the policy (Task 1), then build the
      `%AuthorizedTask{}` through P4a's validating constructor. Return
      `{:ok, task}` | `{:error, :not_authorized}` | `{:error, :authorization_unavailable}`.
- [ ] **Zero side effects on every path, including the success path.** No
      `ensure_started`, no cap issuance, no dispatch, no DB write. `authorize/2`
      answers a question; it does not begin work.

**Tests** — `test/ezagent_plugin_git_workflow/execution_seam/cap_backed_test.exs` (new)

- [ ] Happy path returns `{:ok, %AuthorizedTask{}}` whose four fields match the
      derived policy.
- [ ] **No Kind is started by `authorize/2`** — on both the success and the
      denial path. Assert with `Ezagent.Kind.alive?/1` (or the registry) against
      the task-access URI *before and after* the call. Without this assertion the
      "zero side effects" contract is a comment, not a property.
- [ ] Denial paths return the documented atoms, never raise, never leak the
      binding or policy into the error term.

---

## Task 3 — The real backend: `invoke/3`

- [ ] `invoke(%AuthorizedTask{} = task, action, args)`:
      1. `TaskAccessSupervisor.ensure_started(task.policy)` — idempotent;
      2. `action_target = Ezagent.URI.with_action(task.task_access_uri, :git_task_access, action)`;
      3. `{:ok, cap} = Cap.issue_for_action({:admin, Ezagent.Entity.User.admin_uri()}, task.policy.grantee_uri, action_target)`;
      4. `Invocation.dispatch(%Invocation{target: action_target, mode: :call, args: args, ctx: %{caller: task.policy.grantee_uri, authenticated_principal: task.policy.grantee_uri, caps: MapSet.new([cap]), reply: {:caller_inbox, self()}}, origin: :trusted_internal})`.
- [ ] Normalize every failure through P4a's `Blocker.from_error/1`. A raw
      dispatch error term must not escape this function.
- [ ] One cap per invocation, minted for exactly one action target. Do not cache
      caps across invocations — a cached cap is the stale-artifact class design
      §3.4.1 warns about.

**Tests** (same file)

- [ ] Happy path reaches the adapter through the real Kind runtime — assert via
      the existing `GitEffectProbe`-style sentinel, not by mocking the ActionSet.
      **Routing through `Ezagent.Invocation.dispatch/1` is the whole point of
      decision A**; a test that calls the ActionSet directly proves nothing about
      it.
- [ ] `ctx.caller` and `ctx.authenticated_principal` both equal
      `policy.grantee_uri`, and neither is `User.admin_uri()`. Assert by
      inspecting the dispatched invocation (probe/telemetry), not by reading the
      backend's source.
- [ ] Two invocations mint two caps (no caching), each targeting only its own action.

---

## Task 4 — The authorization tests this slice exists for

**File:** `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/authorization_surface_test.exs` (new)

### 4a. Policy layer — the untested guard

- [ ] **`caller` holds a genuinely valid cap but is NOT `policy.grantee_uri` →
      `{:error, :unauthorized}`.** Construct it the way that actually exercises
      the gap: mint the cap for an *attacker* principal via
      `Cap.issue_for_action({:admin, admin}, attacker_uri, action_target)` — a
      real, signed, current cap — then dispatch with
      `caller: attacker_uri, authenticated_principal: attacker_uri`. The cap gate
      passes (the cap genuinely belongs to the attacker and targets the right
      action); `authorize_receiver` must be what denies.
      **This is the single most important test in the slice.** The existing
      `git_task_dispatch_test.exs:106` case does NOT cover it — there the
      attacker carries the *grantee's* cap, so the cap gate denies first and
      `authorize_receiver` is never reached.
- [ ] The denial happens **before any port/adapter effect** — `refute_receive`
      on the effect sentinel, matching the pattern at
      `git_task_dispatch_test.exs:107`.
- [ ] **An action outside `policy.allowed_actions`, denied through real
      dispatch** → `{:error, :action_not_allowed}`, with the same
      no-side-effect assertion. Today this is only covered as an Entity unit test
      (`entity/git_task_access_test.exs:79-82`) — never through the dispatch path.

### 4b. Prove these tests have teeth — run the experiment, don't assume

- [ ] Temporarily replace `authorize_receiver/3` in
      `apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex` with
      `defp authorize_receiver(_, _, _), do: :ok`, run this file, and **confirm
      4a's first test goes RED**. Then restore the file and confirm
      `git diff` is empty.
      Record the observed result in your completion report. If the test stays
      green with the guard disabled, it does not test what its name claims —
      rewrite it before proceeding. (Reference: the same experiment on the
      current tree gives 170 tests / 0 failures, which is why this slice exists.)
- [ ] Do the same for `action_allowed/2`.
- [ ] Do **not** commit either temporary edit. `apps/ezagent_domain_git` is not
      this slice's owner app.

### 4c. Cap layer — port the existing negatives to the workflow's own dispatch

- [ ] Port all five negatives from `git_task_dispatch_test.exs:106-160` —
      wrong receiver, wrong workspace, wrong instance, wrong action, unsigned —
      each asserting `{:error, :missing_cap}` **and** `refute_receive` on the
      effect sentinel. The value here is not re-testing the framework; it is
      proving the invocation **this backend builds** is subject to those gates.

---

## Task 5 — Flip the default, keeping the config gate intact

- [ ] In `execution_seam.ex`, change the `Application.compile_env/3` default from
      `__MODULE__.Unavailable` to the new backend. **Do not** add
      `config :ezagent_plugin_git_workflow, :execution_seam, ...` to
      `config/config.exs`, `dev.exs`, `prod.exs`, or `runtime.exs`.
- [ ] Rewrite the moduledoc's "Backend selection is compile-time" section: the
      compile-time hardwiring is retained (it still blocks every runtime flip
      vector), but its purpose is no longer "production is a dead end". State the
      new purpose — the backend is fixed at build time and cannot be swapped by
      release config, `sys.config`, `Application.put_env/3`, or a remote IEx
      session.
- [ ] `Unavailable` stays, with its tests, as the documented fallback.
- [ ] `config/test.exs` still names the test delegator — unchanged.

**Tests**

- [ ] `architecture_test.exs` passes **unmodified**, including
      `"no non-test config file sets :execution_seam, in any spelling"`.
- [ ] `ExecutionSeam.implementation/0` returns the new backend in a normal build.
- [ ] The existing `ExecutionSeamTest` proofs that runtime mutation cannot change
      `@backend` still pass.

---

## Gates

```
mix format --check-formatted
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_git_workflow/test
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_domain_git/test
MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast
MIX_ENV=test mix ezagent.arch.scan                        # dup groups stay at 42
MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

- Run mix from the **umbrella root**; `cd apps/<app> && mix test` loads only that
  app's deps and produces bogus `UndefinedFunctionError`s.
- Postgres is on **15432** on this machine.
- Capture **exit codes**. A green tail is not a green run.
- Locality ledger is exact-match, entry shape `{path, {fun, arity}, kind,
  accessor, sha}` — **no line number**. Regenerate from the scanner's own output
  and review every added fingerprint; never paste blind.
- Grep your own diff: zero `Capability.cap(`, zero `Cap.issue(` (only
  `issue_for_action`), zero `system://`.

---

## Stop and report instead of proceeding

- You need to edit `architecture_test.exs`, or add `:execution_seam` to a
  non-test config file.
- You need `Capability.cap/5` because `issue_for_action/3` will not produce the
  shape you need — that is a real finding about the Kind's cap declaration, not a
  reason to hand-build.
- The policy cannot be derived from `TaskBinding` + `WorkflowRun` without
  inventing a value.
- A Task 4b experiment shows a test staying green with its guard disabled and you
  cannot make it red.
- You need a change in `apps/ezagent_domain_git` beyond the temporary,
  reverted 4b experiments.

## Handoff to P4c

- The seam is live: `authorize/2` returns a real `%AuthorizedTask{}` and
  `invoke/3` reaches the adapter through the real Kind runtime.
- P4c owns the **write ordering** the GitHub adapter's KNOWN LIMITATION
  (`github_adapter.ex:184-194`) depends on: `deterministic_head_ref` must be in
  `git_workflow_facts` **before** the first provider mutation call, so a resumed
  run can prove a ref sitting at base is its own.
- Report whether `allowed_actions` ended up narrower than the eight, and which
  actions the workflow actually invokes — P4c needs that list.
