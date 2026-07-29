# Git Provider V1 Plan E — Slice P1: Workflow Legal State + Authorization Seam — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `ezagent_plugin_git_workflow` a fail-closed authorization seam, a
deterministic head ref, a closed legal-transition graph, and a typed
provider-neutral facts store — the four Slice-P1 deliverables from
`docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md`
§9, without adding any public ingress, Cap, or provider/secret dependency.

**Architecture:** `ezagent_plugin_git_workflow` stays a dormant plugin (zero
`behaviors/0`/`roles/0`/`children/0`/`kinds/0`, no `Plugin.boot`). This slice
adds four small, independently-testable modules on top of the existing
`Store`/`WorkflowRun`/`TaskBinding` persistence layer: a pure ref-derivation
function, a closed status/edge graph, a behaviour-based execution seam whose
production default is permanently fail-closed, and a typed facts schema. No
module in this slice calls GitHub, a Kind, or `Ezagent.Cap`.

**Tech Stack:** Elixir/OTP, Ecto migrations against `EzagentCore.Repo`
(`repo_pg`), raw-SQL single-statement CAS (existing `Store` pattern, no
`Ecto.Changeset`), ExUnit + `Ecto.Adapters.SQL.Sandbox`.

## Global Constraints

- No new `Cap.issue`/`Cap.store`, no derived caller/authenticated principal,
  no `%Invocation{}` or `ctx.caps` anywhere in this app (design §3.2).
- No public ingress: no ActionSet, route, CLI, Mix task, or agent tool in
  `ezagent_plugin_git_workflow` (design §9; enforced today by
  `test/ezagent_plugin_git_workflow/architecture_test.exs`, which this plan
  extends rather than replaces).
- Stays dormant end to end: this slice must not be wired into any boot or
  callable path in production — matches `Application.ex`'s existing
  zero-surface stance. When a PR is opened for this work, tag it
  `blocked: auth-convergence` (see "Relationship to main's
  cap-authorization convergence" below) and do not merge it onto main's
  callable surface until a real `ExecutionSeam` backend exists.
- No token, authorization header, private key, or raw provider response body
  in any struct, error, log, or migration column (design §3.2/§7.1).
- No back-compat shims (`feedback_let_it_crash_no_workarounds`): the status
  vocabulary in `workflow_run.ex` is **replaced outright**, not dual-run
  alongside the old one — see "Relationship to prior plans" below.
- Formatter noise policy: run `mix format` only on files this plan touches,
  not the whole project.
- Run `MIX_ENV=test mix ci.fast` (must finish, not time out — use an explicit
  `timeout: 300000` if run via a tool that defaults to 120s) before every
  commit that closes a task, and the full `mix precommit` before considering
  the slice done.

## Relationship to prior plans (read before touching `workflow_run.ex`)

`apps/ezagent_plugin_git_workflow` is not a green field. It was built by
`docs/superpowers/plans/2026-07-24-git-provider-v1-plan-e-simplified-implementation.md`
Slice **E2** ("durable workflow intent 与原子 CAS") as the first wave of a much
larger **E0–E9** plan (E3 = isolated worker + `GitTaskAccess` authority
issuance to a managed Agent; E4 = the Agent itself calls
`create_change_request` from inside a sidecar; E5 = required-checks +
independent-review gating; E6 = human merge + fresh-read confirmation; E7 =
Kanban projection; E9 = canary). `workflow_run.ex`'s current closed status set
—

```text
accepted → workspace_ready → worker_ready → authority_ready
→ pr_open → checks_passed → awaiting_external_merge
→ merged_confirmed → projected → completed
```

— is that E0–E9 plan's wave boundaries encoded as states (E3 = the middle
three, E4 = `pr_open`, E5 = `checks_passed`, E6 = the next two, E7 =
`projected`, E9 = `completed`). `Application.ex` still says "Authorization
ingress is deferred to E2-B" using that plan's own vocabulary.

The 2026-07-25 design this plan implements (`…p1-workflow-legal-state`'s
parent spec) is a **deliberate narrower V1**: no managed-Agent-in-sidecar step
(the workflow itself collects workspace changes and drives
`create_change_request` — there is no `worker_ready`/`authority_ready`
concept in the new model), no required-check gating, no human-merge
confirmation, no Kanban projection, no canary (spec §1, §11). Its own state
machine (§5.4) is `accepted → authorized → workspace_ready → changes_ready →
pr_open → observations_current`.

**This plan treats the 2026-07-25 design as superseding the E0–E9 wave plan's
state machine and E3 worker/authority stage for V1.** It does not touch
`Application.ex`'s "E2-A"/"E2-B" language beyond what Task 3 requires. If Allen
or the lead intends E0–E9 (particularly E7 Kanban projection and E9 canary)
to still happen after V1 ships, that is a follow-up planning decision, not
part of this slice — flag it back to the design owner rather than assuming
either answer.

### Relationship to main's cap-authorization convergence

`ExecutionSeam`'s production default (Task 3) is permanently
`{:error, :authorization_unavailable}` because main's real cap-resolution
chokepoint isn't ready to be called into yet, not as a shortcut. Per
`docs/superpowers/specs/2026-07-24-ezagent-actor-convergence-design.md` v3
(read at `origin/main@846265571`):

- The target shape for a real seam is that spec's §3 "V2 — caps-resolution
  convergence": `EzAgentActor.call(uri, cmd, args, CALLER_IDENTITY)`, where
  the 4th argument is an authenticated principal `%URI{}` — never a caps
  list, never an opaque task object.
- `ezagent_actor` extraction C0–C3 are merged (#1546/#1548/#1550+#1562/#1561);
  **C4–C7 are still pending.** V2 explicitly depends on C5's port contract
  and explicitly requires "coordinate w/ #195 owner." There is no callable
  real-authorization surface to integrate against until V2 lands, and V2
  cannot start before C4/C5 do.
- `ezagent_plugin_git_workflow` is in the same position as the Feishu binding
  slices (B1 `#1568` / B2 `#1547`, `docs/together/2026-07-24/board.yaml`):
  code/tests/CI can and should go green independently, but the PR stays
  tagged `blocked: auth-convergence` and out of main's callable surface
  until mainline permissions stabilize.
- **Unverified assumption, to check when V2 lands:** the real
  `ExecutionSeam.authorize/2` will most likely use
  `TaskBinding.credential_owner_uri` or `Entity.GitTaskAccess.grantee_uri`
  as V2's `CALLER_IDENTITY`, dispatching through the `EzAgentActor`/
  `GitTaskAccess` action surface. Verify this before writing the real
  backend — if it doesn't hold, that's a separate identity-design task, and
  it only touches the seam module, not anything P1–P4 build here.

Do not attempt to build the real `ExecutionSeam` backend as part of this
slice or any slice before P4. Watch `docs/together/` board updates for V2
landing rather than polling main for it speculatively.

---

### Task 1: Deterministic head ref + exact-match validation

**Files:**
- Create: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/deterministic_ref.ex`
- Create: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/deterministic_ref_test.exs`
- Modify: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex:95-141,241-267` (`accept/1`, `validate_source_workspace/3`, `validate_requested_head_ref/2`)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs:125-133` (extend, don't remove)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/concurrency_test.exs:22` (fixture no longer needs a head ref)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs:94-99,245-253` (extend the hardcoded source-file scan lists)

**Interfaces:**
- Produces: `EzagentPluginGitWorkflow.DeterministicRef.derive(allowed_head_namespace :: String.t(), run_id :: String.t()) :: String.t()` — pure function, no DB. `run_id` must be a `WorkflowRun.generate_id/3` output (`"run_" <> 64-hex-char sha256`); the ref is `allowed_head_namespace <> "run-" <> first 24 hex chars of that digest`.
- Consumed by: Task 3's `Authorization` module indirectly (via `WorkflowRun`/`TaskBinding` structs only — Task 3 does not call `DeterministicRef` directly in this slice).

- [ ] **Step 1: Write the failing unit tests for `DeterministicRef`**

```elixir
# apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/deterministic_ref_test.exs
defmodule EzagentPluginGitWorkflow.DeterministicRefTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :deterministic_ref

  describe "derive/2" do
    test "same run id always yields the same ref" do
      run_id = WorkflowRun.generate_id("bnd_1", 1, "task-1")

      assert DeterministicRef.derive("feature/", run_id) ==
               DeterministicRef.derive("feature/", run_id)
    end

    test "ref is namespace <> run- <> first 24 hex chars of the run id digest" do
      run_id = WorkflowRun.generate_id("bnd_1", 1, "task-1")
      "run_" <> digest = run_id

      assert DeterministicRef.derive("feature/", run_id) ==
               "feature/run-" <> String.slice(digest, 0, 24)
    end

    test "different runs yield different refs" do
      run_id_a = WorkflowRun.generate_id("bnd_1", 1, "task-1")
      run_id_b = WorkflowRun.generate_id("bnd_1", 1, "task-2")

      refute DeterministicRef.derive("feature/", run_id_a) ==
               DeterministicRef.derive("feature/", run_id_b)
    end

    test "different namespaces yield different refs for the same run" do
      run_id = WorkflowRun.generate_id("bnd_1", 1, "task-1")

      refute DeterministicRef.derive("feature/", run_id) ==
               DeterministicRef.derive("hotfix/", run_id)
    end
  end
end
```

- [ ] **Step 2: Run it to confirm it fails on undefined module**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/deterministic_ref_test.exs`
Expected: FAIL — `module EzagentPluginGitWorkflow.DeterministicRef is not available`

- [ ] **Step 3: Implement `DeterministicRef`**

```elixir
# apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/deterministic_ref.ex
defmodule EzagentPluginGitWorkflow.DeterministicRef do
  @moduledoc """
  Server-derived deterministic head ref for a workflow run (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.2).

  The same run always yields the same ref: `allowed_head_namespace <>
  "run-" <>` the first 24 hex characters of the run id's digest. The run id
  is already `"run_" <> sha256_hex(unique_key)` (`WorkflowRun.generate_id/3`)
  — this module does not compute or store anything new, only slices it.
  """

  @digest_prefix_length 24

  @doc "Derives the deterministic head ref for a run under its binding's allowed namespace."
  @spec derive(String.t(), String.t()) :: String.t()
  def derive(allowed_head_namespace, "run_" <> digest = _run_id)
      when is_binary(allowed_head_namespace) do
    allowed_head_namespace <> "run-" <> String.slice(digest, 0, @digest_prefix_length)
  end
end
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/deterministic_ref_test.exs`
Expected: PASS (4 tests, 0 failures)

- [ ] **Step 5: Write the failing test proving `Store.accept/1` now requires an exact match**

Add to `store_test.exs` right after the existing `"requested_head_ref outside allowed namespace returns error"` test (around line 133):

```elixir
    test "requested_head_ref inside namespace but not the deterministic value returns error" do
      # Regression for the pre-P1 gap: the old check only verified
      # String.starts_with?/2 against the namespace, so any suffix under
      # "feature/" was accepted. It must now match derive/2 exactly.
      intent =
        build_intent(%{
          external_task_id: "task-non-deterministic-head",
          requested_head_ref: "feature/whatever-i-want"
        })

      assert {:error, :head_ref_not_allowed} = Store.accept(intent)
    end

    test "requested_head_ref matching the deterministic value is accepted" do
      external_task_id = "task-deterministic-head"

      run_id =
        WorkflowRun.generate_id("bnd_store_test", 1, external_task_id)

      expected_ref = EzagentPluginGitWorkflow.DeterministicRef.derive("feature/", run_id)

      intent =
        build_intent(%{
          external_task_id: external_task_id,
          requested_head_ref: expected_ref
        })

      assert {:ok, %WorkflowRun{requested_head_ref: ^expected_ref}} = Store.accept(intent)
    end
```

- [ ] **Step 6: Run the new tests to confirm they fail against the current `starts_with?` check**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/store_test.exs -v`
Expected: the new "not the deterministic value" test FAILS (current code accepts any ref under the namespace); the "matching" test passes already (deterministic value does start with the namespace) — that first failure is the one this task closes.

- [ ] **Step 7: Reorder `Store.accept/1` and tighten `validate_requested_head_ref/2`**

In `store.ex`, add the alias near the top:

```elixir
  alias EzagentPluginGitWorkflow.DeterministicRef
```

Replace the `accept/1` head (lines 95-106) so `run_id` is computed before
validation runs — it is a pure function of already-available intent fields,
so moving it earlier has no side effects:

```elixir
  @spec accept(AcceptIntent.t()) :: {:ok, WorkflowRun.t()} | {:error, term()}
  def accept(%AcceptIntent{
        binding_id: binding_id,
        binding_generation: binding_generation,
        external_task_id: external_task_id,
        source_task_uri: source_task_uri,
        source_revision: source_revision,
        requested_head_ref: requested_head_ref
      }) do
    run_id = WorkflowRun.generate_id(binding_id, binding_generation, external_task_id)

    with {:ok, binding} <- check_binding_active(binding_id),
         :ok <- validate_binding_generation(binding_generation, binding),
         :ok <- validate_source_workspace(source_task_uri, binding, requested_head_ref, run_id),
         digest =
           compute_accept_digest(
             binding_id,
             binding_generation,
             external_task_id,
             source_task_uri,
             source_revision,
             requested_head_ref
           ) do
```

(The rest of the `with` body — building `run_attrs` and calling
`insert_or_load/2` — is unchanged; only remove the now-duplicate `run_id =`
line that used to appear inside the `with` chain.)

Replace `validate_source_workspace/3` and `validate_requested_head_ref/2`
(lines 241-267) with:

```elixir
  defp validate_source_workspace(
         source_task_uri,
         %TaskBinding{workspace_uri: workspace_uri} = binding,
         requested_head_ref,
         run_id
       ) do
    source_ws = Ezagent.URI.workspace_name(source_task_uri)
    binding_ws = Ezagent.URI.workspace_name(workspace_uri)

    case {source_ws, binding_ws} do
      {{:ok, ws}, {:ok, ws}} ->
        validate_requested_head_ref(requested_head_ref, binding, run_id)

      {{:ok, _}, {:ok, _}} ->
        {:error, :source_workspace_mismatch}

      _ ->
        {:error, :invalid_source_task_uri}
    end
  end

  defp validate_requested_head_ref(nil, _binding, _run_id), do: :ok

  defp validate_requested_head_ref(
         ref,
         %TaskBinding{allowed_head_namespace: ns},
         run_id
       ) do
    if ref == DeterministicRef.derive(ns, run_id),
      do: :ok,
      else: {:error, :head_ref_not_allowed}
  end
```

- [ ] **Step 8: Fix the now-broken concurrency fixture**

`concurrency_test.exs`'s `build_intent/2` default `requested_head_ref:
"feature/conc"` (line 22) is not the deterministic value and that test isn't
about head-ref validation — the exact-match check would now reject it before
the concurrency race it's testing ever runs. Change the default to `nil`
(§5.2: caller-supplied ref may be empty):

```elixir
      requested_head_ref: nil
```

- [ ] **Step 9: Run the full app test suite**

Run: `cd apps/ezagent_plugin_git_workflow && mix test`
Expected: PASS, 0 failures — including the two new Step-5 tests, the
existing "outside allowed namespace" test (still fails the same way, just
now for the same reason as any other non-matching ref), and
`concurrency_test.exs`'s `#{@n} concurrent identical accepts` test.

- [ ] **Step 10: Extend the architecture gate's hardcoded source-file lists**

In `architecture_test.exs`, add `deterministic_ref.ex` to both hardcoded
`sources`/scan lists so the new file is covered by the existing no-Kind/no-Cap
and no-CapBAC gates instead of silently falling outside them:

Line ~94, `"claim path rejects forbidden modules"`:
```elixir
      sources = ~w(store.ex accept_intent.ex task_binding.ex workflow_run.ex deterministic_ref.ex)
```

Line ~245, `"no reference to Ezagent.Cap in lib modules"`:
```elixir
      for source <- ~w(store.ex accept_intent.ex task_binding.ex workflow_run.ex deterministic_ref.ex) do
```

- [ ] **Step 11: Run the full app suite once more, then format and commit**

Run: `cd apps/ezagent_plugin_git_workflow && mix test && cd ../.. && mix format apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/deterministic_ref.ex apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/deterministic_ref_test.exs apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/concurrency_test.exs apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs`
Expected: PASS

```bash
git add apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/deterministic_ref.ex \
        apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/deterministic_ref_test.exs \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/concurrency_test.exs \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs
git commit -m "feat(git-workflow): deterministic head ref, exact-match accept validation"
```

---

### Task 1 — post-review corrections (2026-07-26)

Codex reviewed Task 1's implementation and found three defects that trace
back to gaps in this plan, not to the implementer. Apply these on top of
Task 1's commit; all three must be verified by an actual test run (they were
not, originally — see the note below).

**Correction 1 — `store_test.exs`'s own fixture breaks the suite (plan bug).**
Task 1 Step 8 fixed `concurrency_test.exs`'s fixture but missed that
`store_test.exs:36-48`'s `build_intent/1` defaults to
`requested_head_ref: "feature/test"`. Under the new exact-match rule that
value can never equal `"feature/run-" <> <24 hex>`, so
`Store.accept(build_intent())` now returns
`{:error, :head_ref_not_allowed}` — breaking every test in that file that
pattern-matches `{:ok, run} = Store.accept(intent)` (~10 sites out of 21
`Store.accept` calls) before it reaches the behavior it means to test.
Change that default to `nil`, exactly as Step 8 did for
`concurrency_test.exs`. Do not change the two tests added in Step 5 — they
supply their refs explicitly and are correct as written.

**Correction 2 — derived refs are never validated against Git ref rules
(design §5.2 requirement this plan dropped).** §5.2 requires the derived ref
to "满足 Git ref validation 和 255-byte 上限", but `derive/2` concatenates
without checking, and `TaskBinding` validates `allowed_head_namespace` only
as `is_binary/1` (`task_binding.ex:113`). A namespace containing `//`, `..`,
`@{`, or one long enough to push the result past 255 bytes silently yields
an illegal server-derived ref. The repo already has the exact predicate:
`Ezagent.DomainGit.RepositoryRef.valid_ref?/1`
(`apps/ezagent_domain_git/lib/ezagent/domain_git/repository_ref.ex:38-45`),
which enforces the 1..255 byte range, the character class, and rejects
`//`, `..`, `@{`, leading `refs/`, and trailing `/` or `.`.

Validate the *completed* ref, and validate the binding's namespace at
construction so a bad namespace fails early rather than at accept time. Add
tests for: a namespace producing an over-255-byte ref, and a namespace
containing `..` / `//` / `@{`. `RepositoryRef` is already a dependency of
this app (`task_binding.ex` uses it), so this adds no new dependency.

**Correction 3 (Minor) — third scan list missed.** `architecture_test.exs`
has a *third* hardcoded source-file list, in the `String.to_atom/1` safety
test (~line 142-150), which Task 1 Step 10 did not update. Add
`deterministic_ref.ex` there too. Consider replacing the three duplicated
lists with one module attribute — three copies is why one was missed.

**Decisions recorded (Allen, 2026-07-26):**

- **Empty-string `requested_head_ref` stays rejected.** §5.2's "只能为空"
  means `nil`; `AcceptIntent` rejecting `""` as a malformed value
  (`accept_intent.ex:100-102`) is correct and is pre-existing behavior Task 1
  never touched. Do **not** canonicalize `""` to `nil`.
- **Ref validation lands in Task 1**, not a later slice — it belongs with the
  derivation logic it constrains.

**Verification note:** Task 1's original commit was made with **zero test
runs** — the local PostgreSQL at 127.0.0.1:55432 was down, and `ezagent_core`
cannot boot without it (`Ezagent.TemplateTags.load_into_registry/0` queries
the DB during `Application.start/2`), which kills even DB-free unit tests in
this umbrella. That is exactly how Correction 1 reached a commit unnoticed.
Do not mark these corrections complete on inspection alone: start the
cluster (`sudo systemctl enable --now postgresql@16-main`) and run the tests.

---

### Task 2: Legal transition graph (supersedes the E2-A status vocabulary)

**Files:**
- Modify: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_run.ex:1-56` (moduledoc + status vocabulary)
- Modify: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex:160-193` (`transition/4`)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs:175-234` (rewrite the `describe "transition/4"` block)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/schema_test.exs:64-71` (rewrite terminal-status assertions)

**Interfaces:**
- Produces: `WorkflowRun.legal_transition?(current :: String.t(), next :: String.t()) :: boolean()`. `WorkflowRun.statuses/0` now returns `~w(accepted authorized workspace_ready changes_ready pr_open observations_current blocked failed cancelled)`. `WorkflowRun.terminal?/1` now recognizes only `failed`/`cancelled`.
- Consumes: none new.
- Consumed by: `Store.transition/4` (this task); Task 3's `Authorization.authorize_run/2`, which transitions `"accepted" -> "authorized"`.

- [ ] **Step 1: Write the failing tests for the new vocabulary and edge graph**

Replace `schema_test.exs`'s `"terminal statuses are correctly identified"` test (lines 64-71):

```elixir
    test "terminal statuses are correctly identified" do
      assert WorkflowRun.terminal?("failed")
      assert WorkflowRun.terminal?("cancelled")

      refute WorkflowRun.terminal?("accepted")
      refute WorkflowRun.terminal?("authorized")
      refute WorkflowRun.terminal?("blocked")
    end

    test "legal_transition?/2 allows only the design's §5.4 success-path edges plus control states" do
      assert WorkflowRun.legal_transition?("accepted", "authorized")
      assert WorkflowRun.legal_transition?("authorized", "workspace_ready")
      assert WorkflowRun.legal_transition?("workspace_ready", "changes_ready")
      assert WorkflowRun.legal_transition?("changes_ready", "pr_open")
      assert WorkflowRun.legal_transition?("pr_open", "observations_current")
      assert WorkflowRun.legal_transition?("observations_current", "observations_current")

      refute WorkflowRun.legal_transition?("accepted", "pr_open")
      refute WorkflowRun.legal_transition?("accepted", "changes_ready")
      refute WorkflowRun.legal_transition?("observations_current", "accepted")
    end

    test "legal_transition?/2 allows any non-terminal state into blocked/failed/cancelled" do
      for state <- ~w(accepted authorized workspace_ready changes_ready pr_open observations_current) do
        assert WorkflowRun.legal_transition?(state, "blocked"), "#{state} -> blocked"
        assert WorkflowRun.legal_transition?(state, "failed"), "#{state} -> failed"
        assert WorkflowRun.legal_transition?(state, "cancelled"), "#{state} -> cancelled"
      end
    end

    test "blocked has no defined resume edge in this slice" do
      # P1 scope only: resuming a blocked run onto the success path is
      # Slice P4's retry-classification concern (design §4.1/§9). Blocked
      # can still reach failed/cancelled.
      assert WorkflowRun.legal_transition?("blocked", "failed")
      assert WorkflowRun.legal_transition?("blocked", "cancelled")
      refute WorkflowRun.legal_transition?("blocked", "accepted")
      refute WorkflowRun.legal_transition?("blocked", "authorized")
    end
```

Rewrite `store_test.exs`'s `describe "transition/4"` block (lines 175-234) —
keep the existing `setup` above it (`{:ok, run: run}`) unchanged, replace the
tests below it:

```elixir
    test "transitions from accepted to authorized", %{run: run} do
      assert {:ok, %WorkflowRun{status: "authorized", state_version: 2}} =
               Store.transition(run.id, 1, "accepted", "authorized")
    end

    test "exact retry is idempotent", %{run: run} do
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "authorized")
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "authorized")
      assert r1.state_version == r2.state_version
    end

    test "stale state_version returns error", %{run: run} do
      {:ok, _} = Store.transition(run.id, 1, "accepted", "authorized")

      assert {:error, :stale_state_version} =
               Store.transition(run.id, 1, "accepted", "workspace_ready")
    end

    test "wrong expected_status returns conflict", %{run: run} do
      assert {:error, :workflow_state_conflict} =
               Store.transition(run.id, 1, "workspace_ready", "changes_ready")
    end

    test "non-existent run returns not_found" do
      assert {:error, :not_found} =
               Store.transition("nonexistent", 1, "accepted", "authorized")
    end

    test "rejects unknown status at gate" do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)

      assert {:error, {:invalid_status, "invalid_status"}} =
               Store.transition(run.id, 1, "accepted", "invalid_status")
    end

    test "rejects a known status that is not a legal edge from the current one", %{run: run} do
      assert {:error, {:illegal_transition, "accepted", "pr_open"}} =
               Store.transition(run.id, 1, "accepted", "pr_open")
    end

    test "terminal runs: exact retry returns same run, different transition rejected", %{
      run: run
    } do
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "blocked")
      assert r1.status == "blocked"
      assert r1.state_version == 2

      # Exact retry with same params: returns same run (idempotent).
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "blocked")
      assert r2.id == r1.id
      assert r2.status == "blocked"
      assert r2.state_version == 2

      {:ok, r3} = Store.transition(run.id, 2, "blocked", "failed")
      assert r3.status == "failed"
      assert r3.state_version == 3

      # Different transition attempt on terminal run: rejected.
      assert {:error, :workflow_terminal} =
               Store.transition(run.id, 3, "failed", "cancelled")

      {:ok, final} = Store.read_run(run.id)
      assert final.state_version == 3
      assert final.status == "failed"
    end
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/schema_test.exs test/ezagent_plugin_git_workflow/store_test.exs`
Expected: FAIL — `legal_transition?/2` undefined; old-vocabulary assertions
(`worker_ready` etc.) already gone so those specific failures won't
reproduce, but the new edge-rejection test fails because today's
`Store.transition/4` has no edge check (`accepted -> pr_open` currently
succeeds).

- [ ] **Step 3: Replace the status vocabulary and add the edge graph**

In `workflow_run.ex`, replace the moduledoc's status-set paragraph (lines
18-26) with:

```
  Closed status set (Plan E V1 — design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.4, which supersedes the wider E0-E9 wave-plan vocabulary this app
  shipped with under Slice E2):
    accepted → authorized → workspace_ready → changes_ready
    → pr_open → observations_current (self-loop on repeated ticks)

  Control states: blocked | failed | cancelled — any non-terminal status may
  transition to any of the three.

  Terminal states (reject further transitions): failed, cancelled.
  `blocked` is deliberately NOT terminal-in-the-CAS-sense (matching the
  prior model); its legal edges in this slice are blocked (self-transition
  — re-blocking an already-blocked run is harmless and idempotent),
  failed, and cancelled. Resuming a blocked run onto the success path is
  Slice P4's retry-classification concern, not defined here.
```

> **Amended (Allen, 2026-07-26):** the moduledoc paragraph above and the
> `@legal_edges` map below originally omitted the `blocked → blocked`
> self-edge, even though design §5.4 states any non-terminal state
> (`blocked` included) may transition to `blocked`/`failed`/`cancelled`.
> The whole-branch final review caught the gap — the exhaustive
> 81-pair test in `schema_test.exs` had frozen the omission, so it
> confidently enforced a graph that didn't match the design. Owner
> decision: add the self-transition, aligning the implementation to the
> design, rather than carving out a design exception for no benefit. The
> text below already reflects that decision.

Replace the vocabulary block (lines 29-39):

```elixir
  # ── status vocabulary ────────────────────────────────────────

  @success_path ~w(
    accepted authorized workspace_ready changes_ready
    pr_open observations_current
  )

  @control_states ~w(blocked failed cancelled)

  @all_statuses @success_path ++ @control_states

  @terminal_statuses ~w(failed cancelled)

  @legal_edges %{
    "accepted" => ~w(authorized blocked failed cancelled),
    "authorized" => ~w(workspace_ready blocked failed cancelled),
    "workspace_ready" => ~w(changes_ready blocked failed cancelled),
    "changes_ready" => ~w(pr_open blocked failed cancelled),
    "pr_open" => ~w(observations_current blocked failed cancelled),
    "observations_current" => ~w(observations_current blocked failed cancelled),
    "blocked" => ~w(blocked failed cancelled)
  }
```

Add the new public function next to `terminal?/1` (after line 52):

```elixir
  @doc "Whether `next` is a legal CAS transition target from `current`."
  @spec legal_transition?(String.t(), String.t()) :: boolean()
  def legal_transition?(current, next), do: next in Map.get(@legal_edges, current, [])
```

- [ ] **Step 4: Wire edge validation into `Store.transition/4`**

In `store.ex`, change the `with` chain (lines 170-171) to add the edge check
before the CAS UPDATE:

```elixir
    with :ok <- check_valid_status(expected_status),
         :ok <- check_valid_status(next_status),
         :ok <- check_legal_edge(expected_status, next_status) do
```

Add the private helper next to `check_valid_status/1`:

```elixir
  defp check_legal_edge(expected_status, next_status) do
    if WorkflowRun.legal_transition?(expected_status, next_status),
      do: :ok,
      else: {:error, {:illegal_transition, expected_status, next_status}}
  end
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `cd apps/ezagent_plugin_git_workflow && mix test`
Expected: PASS, 0 failures.

- [ ] **Step 6: Format and commit**

```bash
cd /home/huangjiajia/ezagent
mix format apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_run.ex \
            apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/schema_test.exs \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs
git add apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_run.ex \
        apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/schema_test.exs \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs
git commit -m "feat(git-workflow): replace E2-A status vocabulary with design §5.4 legal transition graph"
```

---

### Task 3: Fail-closed execution seam + `Authorization.authorize_run/2`

**Files:**
- Create: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam.ex`
- Create: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam/unavailable.ex`
- Create: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/authorization.ex`
- Create: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/execution_seam_test.exs`
- Create: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/authorization_test.exs`
- Create: `apps/ezagent_plugin_git_workflow/test/support/fake_execution_seam.ex`
- Modify: `apps/ezagent_plugin_git_workflow/mix.exs:36` (`elixirc_paths(:test)` already includes `test/support` — no change needed, verify only)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs` (extend gate lists + new fail-closed/no-runtime-override gate)

**Interfaces:**
- Produces: `EzagentPluginGitWorkflow.ExecutionSeam` behaviour with
  `@callback authorize(WorkflowRun.t(), TaskBinding.t()) :: {:ok, term()} |
  {:error, :authorization_unavailable} | {:error, :not_authorized}` and
  `@callback invoke(authorized_task :: term(), action :: atom(), typed_args ::
  term()) :: {:ok, term()} | {:error, term()}`; `implementation/0 :: module()`.
  `EzagentPluginGitWorkflow.ExecutionSeam.Unavailable` — the always-fail-closed
  default. `EzagentPluginGitWorkflow.Authorization.authorize_run/2 ::
  (WorkflowRun.t(), TaskBinding.t()) -> {:ok, WorkflowRun.t()} | {:error,
  term()}`.
- Consumes: `WorkflowRun.t()`, `TaskBinding.t()` (existing structs, unchanged
  shape), `Store.transition/4` (Task 2), status literal `"accepted"`/`"authorized"` (Task 2's vocabulary).

- [ ] **Step 1: Write the failing behaviour + default-backend tests**

```elixir
# apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/execution_seam_test.exs
defmodule EzagentPluginGitWorkflow.ExecutionSeamTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.ExecutionSeam.Unavailable

  @moduletag :execution_seam

  test "implementation/0 defaults to Unavailable when unconfigured" do
    assert ExecutionSeam.implementation() == Unavailable
  end

  test "Unavailable.authorize/2 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} = Unavailable.authorize(:anything, :anything)
    assert {:error, :authorization_unavailable} = Unavailable.authorize(nil, nil)
  end

  test "Unavailable.invoke/3 always fails closed regardless of input" do
    assert {:error, :authorization_unavailable} =
             Unavailable.invoke(:anything, :any_action, %{})
  end
end
```

- [ ] **Step 2: Run to confirm it fails**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/execution_seam_test.exs`
Expected: FAIL — modules not available.

- [ ] **Step 3: Implement the behaviour and its fail-closed default**

```elixir
# apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam.ex
defmodule EzagentPluginGitWorkflow.ExecutionSeam do
  @moduledoc """
  Fail-closed authorization/execution seam — the ONLY internal chokepoint
  the workflow depends on to obtain an authorized task and invoke a
  provider-neutral action against it (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §3.1).

  `authorized_task` must encapsulate only a validated exact `GitTaskAccess`
  policy, task URI, and generation. It must NEVER carry a raw cap, an
  `%Invocation{}`, `ctx.caps`, a GitHub token, or any caller-supplied
  credential (§3.2).

  The production default (`EzagentPluginGitWorkflow.ExecutionSeam.Unavailable`)
  always returns `{:error, :authorization_unavailable}` and performs zero
  workspace/filesystem/provider/Agent side effects. Only test code may
  configure a different implementation, and only via
  `Application.put_env/3` in `config/test.exs` or a test's own setup —
  never via runtime env, a route, an ActionSet, a CLI, or an agent tool
  parameter. `architecture_test.exs` enforces this.
  """

  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @type authorized_task :: term()
  @type action :: atom()
  @type typed_args :: term()
  @type typed_result :: term()

  @callback authorize(WorkflowRun.t(), TaskBinding.t()) ::
              {:ok, authorized_task()}
              | {:error, :authorization_unavailable}
              | {:error, :not_authorized}

  @callback invoke(authorized_task(), action(), typed_args()) ::
              {:ok, typed_result()} | {:error, term()}

  @doc "Resolves the configured seam implementation. Defaults to the fail-closed backend."
  @spec implementation() :: module()
  def implementation do
    Application.get_env(:ezagent_plugin_git_workflow, :execution_seam, __MODULE__.Unavailable)
  end
end
```

```elixir
# apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam/unavailable.ex
defmodule EzagentPluginGitWorkflow.ExecutionSeam.Unavailable do
  @moduledoc """
  Production default execution seam. Permanently fail-closed, zero side
  effects. See `EzagentPluginGitWorkflow.ExecutionSeam` for the contract
  this satisfies.
  """

  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  @impl true
  def authorize(_run, _binding), do: {:error, :authorization_unavailable}

  @impl true
  def invoke(_authorized_task, _action, _typed_args), do: {:error, :authorization_unavailable}
end
```

- [ ] **Step 4: Run to confirm it passes**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/execution_seam_test.exs`
Expected: PASS (3 tests, 0 failures)

- [ ] **Step 5: Write the failing tests for `Authorization.authorize_run/2`**

First, the injectable test fake other tests will reuse:

```elixir
# apps/ezagent_plugin_git_workflow/test/support/fake_execution_seam.ex
defmodule EzagentPluginGitWorkflow.FakeExecutionSeam do
  @moduledoc false
  @behaviour EzagentPluginGitWorkflow.ExecutionSeam

  @impl true
  def authorize(%{binding_id: "bnd_denied"}, _binding), do: {:error, :not_authorized}
  def authorize(_run, _binding), do: {:ok, %{authorized: true}}

  @impl true
  def invoke(_authorized_task, _action, _typed_args), do: {:ok, %{}}
end
```

```elixir
# apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/authorization_test.exs
defmodule EzagentPluginGitWorkflow.AuthorizationTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Authorization
  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.ExecutionSeam.Unavailable
  alias EzagentPluginGitWorkflow.FakeExecutionSeam
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :authorization

  @valid_binding_attrs %{
    id: "bnd_auth_test",
    generation: 1,
    workspace_uri: Ezagent.URI.workspace("test-ws"),
    task_receiver_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-recv"),
    credential_owner_uri: Ezagent.URI.entity("test-ws", "user", "credential-owner"),
    repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "my-repo"),
    provider_adapter: :github,
    provider_host: "github.com",
    external_id: "owner/repo",
    owner_path: "owner",
    base_ref: "main",
    visibility: :public,
    allowed_head_namespace: "feature/",
    enabled: true
  }

  setup do
    {:ok, binding} = TaskBinding.new(@valid_binding_attrs)
    {:ok, _} = Store.register_binding(binding)

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: "bnd_auth_test",
        binding_generation: 1,
        external_task_id: "task-auth-1",
        source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
        source_revision: "abc123",
        requested_head_ref: nil
      })

    {:ok, run} = Store.accept(intent)

    on_exit(fn -> Application.delete_env(:ezagent_plugin_git_workflow, :execution_seam) end)

    {:ok, binding: binding, run: run}
  end

  test "production default: seam unavailable leaves the run at accepted", %{
    run: run,
    binding: binding
  } do
    assert ExecutionSeam.implementation() == Unavailable

    assert {:error, :authorization_unavailable} = Authorization.authorize_run(run, binding)

    {:ok, unchanged} = Store.read_run(run.id)
    assert unchanged.status == "accepted"
    assert unchanged.state_version == 1
  end

  test "injected fake seam: authorize success transitions accepted -> authorized", %{
    run: run,
    binding: binding
  } do
    Application.put_env(:ezagent_plugin_git_workflow, :execution_seam, FakeExecutionSeam)

    assert {:ok, %WorkflowRun{status: "authorized", state_version: 2}} =
             Authorization.authorize_run(run, binding)
  end

  test "injected fake seam: not_authorized leaves the run at accepted", %{binding: binding} do
    Application.put_env(:ezagent_plugin_git_workflow, :execution_seam, FakeExecutionSeam)

    # FakeExecutionSeam denies on binding_id "bnd_denied" — build that run
    # struct directly (mirrors Store's own struct!(WorkflowRun, %{...})
    # idiom); Authorization.authorize_run/2 never reads the DB for `run`
    # itself, so no matching binding row needs to exist for this case.
    denied_run =
      struct!(WorkflowRun, %{
        id: "run_denied",
        binding_id: "bnd_denied",
        binding_generation: 1,
        external_task_id: "task-denied-1",
        workspace_uri: binding.workspace_uri,
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:test",
        source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
        source_revision: "abc123",
        requested_head_ref: nil,
        last_error_code: nil
      })

    assert {:error, :not_authorized} = Authorization.authorize_run(denied_run, binding)
  end

  test "refuses to authorize a run that is not accepted", %{run: run, binding: binding} do
    {:ok, authorized} = Store.transition(run.id, 1, "accepted", "authorized")

    assert {:error, {:invalid_run_status, "authorized"}} =
             Authorization.authorize_run(authorized, binding)
  end
end
```

- [ ] **Step 6: Run to confirm it fails**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/authorization_test.exs`
Expected: FAIL — `EzagentPluginGitWorkflow.Authorization` not available.

- [ ] **Step 7: Implement `Authorization`**

```elixir
# apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/authorization.ex
defmodule EzagentPluginGitWorkflow.Authorization do
  @moduledoc """
  Drives a run's `accepted -> authorized` transition through the
  fail-closed `ExecutionSeam` (design §3.1/§5.4). Zero provider/workspace
  side effects — those belong to later slices.
  """

  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @doc """
  Attempts to authorize `run` against `binding` via the configured seam.

  On `{:ok, _authorized_task}`: CAS-transitions the run to "authorized" and
  returns the updated run. The authorized_task itself is not persisted —
  later slices re-derive it from the same seam call.

  On `{:error, :authorization_unavailable}` or `{:error, :not_authorized}`:
  performs no transition; the run stays "accepted" for a later retry
  (design §5.4).
  """
  @spec authorize_run(WorkflowRun.t(), TaskBinding.t()) ::
          {:ok, WorkflowRun.t()}
          | {:error, :authorization_unavailable}
          | {:error, :not_authorized}
          | {:error, term()}
  def authorize_run(%WorkflowRun{status: "accepted"} = run, %TaskBinding{} = binding) do
    seam = ExecutionSeam.implementation()

    case seam.authorize(run, binding) do
      {:ok, _authorized_task} ->
        Store.transition(run.id, run.state_version, "accepted", "authorized")

      {:error, _reason} = error ->
        error
    end
  end

  def authorize_run(%WorkflowRun{status: status}, %TaskBinding{}),
    do: {:error, {:invalid_run_status, status}}
end
```

- [ ] **Step 8: Run to confirm it passes**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/authorization_test.exs`
Expected: PASS (4 tests, 0 failures)

- [ ] **Step 9: Add the fail-closed / no-runtime-override gate + extend hardcoded scan lists**

In `architecture_test.exs`, add `execution_seam.ex`, `execution_seam/unavailable.ex`,
and `authorization.ex` to both hardcoded lists from Task 1 Step 10 (now
`~w(store.ex accept_intent.ex task_binding.ex workflow_run.ex
deterministic_ref.ex execution_seam.ex execution_seam/unavailable.ex
authorization.ex)` in both places), then add a new describe block:

```elixir
  describe "execution seam is fail-closed and test-only-injectable" do
    test "no non-test config sets :execution_seam" do
      for file <- ~w(config/config.exs config/dev.exs config/prod.exs config/runtime.exs) do
        path = Path.join(@app_dir, "../../#{file}") |> Path.expand()

        if File.exists?(path) do
          content = File.read!(path)

          refute content =~ ":execution_seam",
                 "#{file} must not set :execution_seam — only test config/setup may (design §3.1)"
        end
      end
    end

    test "no lib module calls Application.put_env for :execution_seam" do
      lib_files = Path.join(@lib_dir, "**/*.ex") |> Path.wildcard()

      for file <- lib_files do
        content = File.read!(file)
        base = Path.basename(file)

        refute content =~
                 ~r/Application\.put_env\(:ezagent_plugin_git_workflow,\s*:execution_seam/,
               "#{base}: only test code may override :execution_seam"
      end
    end

    test "ExecutionSeam.implementation/0 defaults to the Unavailable backend" do
      content =
        Path.join(@lib_dir, "ezagent_plugin_git_workflow/execution_seam.ex") |> File.read!()

      assert content =~ "__MODULE__.Unavailable"
    end
  end
```

- [ ] **Step 10: Run the full app suite**

Run: `cd apps/ezagent_plugin_git_workflow && mix test`
Expected: PASS, 0 failures.

- [ ] **Step 11: Format and commit**

```bash
cd /home/huangjiajia/ezagent
mix format apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam.ex \
            apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam/unavailable.ex \
            apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/authorization.ex \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/execution_seam_test.exs \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/authorization_test.exs \
            apps/ezagent_plugin_git_workflow/test/support/fake_execution_seam.ex \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs
git add apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam.ex \
        apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam/unavailable.ex \
        apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/authorization.ex \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/execution_seam_test.exs \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/authorization_test.exs \
        apps/ezagent_plugin_git_workflow/test/support/fake_execution_seam.ex \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs
git commit -m "feat(git-workflow): fail-closed execution seam + Authorization.authorize_run/2"
```

---

### Task 4: Typed workflow facts schema + store

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/20260725120000_create_git_workflow_facts.exs`
- Create: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_facts.ex`
- Create: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/workflow_facts_test.exs`
- Modify: `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex` (add `upsert_facts/1`, `read_facts/1`)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs` (new `describe "facts"` block)
- Modify: `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs` (extend gate lists + new migration secret-scan test)

**Interfaces:**
- Produces: `EzagentPluginGitWorkflow.WorkflowFacts.new(map()) :: {:ok, t()} |
  {:error, term()}` (closed field set below); `Store.upsert_facts(WorkflowFacts.t())
  :: {:ok, WorkflowFacts.t()}`; `Store.read_facts(run_id :: String.t()) ::
  {:ok, WorkflowFacts.t()} | {:error, :not_found}`.
- Consumes: `run_id` (a `WorkflowRun.id`, foreign-key-by-convention — no DB
  FK constraint added, matching this app's existing style of app-level
  validation over DB constraints).

Design §5.3 lists the fields this record must be able to hold: workspace
provision id, deterministic head ref, collected change digest, expected
base SHA, created/reconciled head SHA, normalized change request
id/URL/state/head-ref/base-ref, and checks/reviews observation
revision+summary+observed_at. Every field except `id`/`run_id` is optional
at creation. No field may hold a raw response body, header, token, or
credential (design §5.3, §3.2).

> **Amended (Allen, 2026-07-26):** this paragraph originally continued
> "...later slices (P2/P3/P4) populate them incrementally as the run
> progresses," which contradicts `Store.upsert_facts/1`'s actual
> semantics — a single-statement `INSERT ... ON CONFLICT (run_id) DO
> UPDATE` that replaces every non-key column on every call. A later
> partial write under that model would NULL out an earlier stage's
> facts, not merge with them. The whole-branch final review caught the
> contradiction. Owner decision: keep full-replace semantics as built
> (P1 has no second writer at all — P2/P3/P4 don't exist yet, so
> designing a merge protocol now would be guessing at a write pattern
> nobody has); fix the documentation instead. A caller of
> `upsert_facts/1` must always pass a **complete** snapshot of the facts
> it wants persisted, never a delta. If a later slice needs incremental
> accumulation from multiple writers, it must introduce explicit merge
> or revision-CAS semantics at that point — see the current moduledoc in
> `workflow_facts.ex` for the authoritative wording.

- [ ] **Step 1: Write the failing migration/schema test**

```elixir
# apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/workflow_facts_test.exs
defmodule EzagentPluginGitWorkflow.WorkflowFactsTest do
  use ExUnit.Case, async: true

  alias EzagentPluginGitWorkflow.WorkflowFacts

  @moduletag :workflow_facts

  @minimal %{id: "wf_test", run_id: "run_test"}

  describe "new/1" do
    test "accepts the minimal required fields, defaults the rest to nil" do
      assert {:ok, %WorkflowFacts{id: "wf_test", run_id: "run_test", head_sha: nil}} =
               WorkflowFacts.new(@minimal)
    end

    test "rejects missing id" do
      assert {:error, {:missing_field, :id}} = WorkflowFacts.new(%{run_id: "run_test"})
    end

    test "rejects missing run_id" do
      assert {:error, {:missing_field, :run_id}} = WorkflowFacts.new(%{id: "wf_test"})
    end

    test "rejects unknown fields" do
      assert {:error, {:unknown_fields, [:token]}} =
               WorkflowFacts.new(Map.put(@minimal, :token, "secret"))
    end

    test "accepts every design §5.3 fact field" do
      attrs =
        Map.merge(@minimal, %{
          workspace_provision_id: "prov_1",
          deterministic_head_ref: "feature/run-abc123",
          change_digest: "sha256:deadbeef",
          expected_base_sha: "abc123",
          head_sha: "def456",
          change_request_id: "cr_1",
          change_request_url: "https://github.com/o/r/pull/1",
          change_request_state: "open",
          change_request_head_ref: "feature/run-abc123",
          change_request_base_ref: "main",
          checks_revision: 1,
          checks_summary: "all passing",
          checks_observed_at: DateTime.utc_now(),
          reviews_revision: 1,
          reviews_summary: "1 approval",
          reviews_observed_at: DateTime.utc_now()
        })

      assert {:ok, %WorkflowFacts{}} = WorkflowFacts.new(attrs)
    end
  end

  describe "struct field contract" do
    test "no secret-shaped keys" do
      keys =
        WorkflowFacts.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 == :__struct__))

      forbidden = ~w(token credential secret password authorization private_key installation_id raw_response header)a

      for key <- keys do
        ks = Atom.to_string(key)

        refute Enum.any?(forbidden, &String.contains?(ks, Atom.to_string(&1))),
               "WorkflowFacts key #{key} forbidden"
      end
    end
  end
end
```

- [ ] **Step 2: Run to confirm it fails**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/workflow_facts_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 3: Implement `WorkflowFacts`**

```elixir
# apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_facts.ex
defmodule EzagentPluginGitWorkflow.WorkflowFacts do
  @moduledoc """
  Typed, provider-neutral facts accumulated for one workflow run (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.3).

  Every field but `id`/`run_id` is optional — nil is a legal "not yet
  known" value, not an error. `Store.upsert_facts/1` fully replaces the
  row on every call, so a caller must always pass a complete snapshot,
  never a delta (amended 2026-07-26 — see the note above this step and
  the current moduledoc in workflow_facts.ex for the authoritative
  full-replace semantics; this is not an incremental-merge store). No
  field may hold a raw response body, header, token, or credential.
  """

  @required_fields [:id, :run_id]
  @optional_fields [
    :workspace_provision_id,
    :deterministic_head_ref,
    :change_digest,
    :expected_base_sha,
    :head_sha,
    :change_request_id,
    :change_request_url,
    :change_request_state,
    :change_request_head_ref,
    :change_request_base_ref,
    :checks_revision,
    :checks_summary,
    :checks_observed_at,
    :reviews_revision,
    :reviews_summary,
    :reviews_observed_at
  ]
  @fields @required_fields ++ @optional_fields

  @enforce_keys @required_fields
  defstruct @fields ++ [:inserted_at, :updated_at]

  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t(),
          workspace_provision_id: String.t() | nil,
          deterministic_head_ref: String.t() | nil,
          change_digest: String.t() | nil,
          expected_base_sha: String.t() | nil,
          head_sha: String.t() | nil,
          change_request_id: String.t() | nil,
          change_request_url: String.t() | nil,
          change_request_state: String.t() | nil,
          change_request_head_ref: String.t() | nil,
          change_request_base_ref: String.t() | nil,
          checks_revision: integer() | nil,
          checks_summary: String.t() | nil,
          checks_observed_at: DateTime.t() | nil,
          reviews_revision: integer() | nil,
          reviews_summary: String.t() | nil,
          reviews_observed_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc "Builds a validated WorkflowFacts record. Unknown fields are rejected."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_required(attrs),
         :ok <- validate_known_fields(attrs) do
      {:ok, struct!(__MODULE__, Map.take(attrs, @fields))}
    end
  end

  def new(_attrs), do: {:error, :invalid_attributes}

  defp validate_required(attrs) do
    missing = Enum.filter(@required_fields, fn f -> not Map.has_key?(attrs, f) end)

    if missing == [],
      do: :ok,
      else: {:error, {:missing_field, hd(missing)}}
  end

  defp validate_known_fields(attrs) do
    extra = Map.keys(attrs) -- @fields

    if extra == [],
      do: :ok,
      else: {:error, {:unknown_fields, extra}}
  end
end
```

- [ ] **Step 4: Run to confirm it passes**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/workflow_facts_test.exs`
Expected: PASS (6 tests, 0 failures)

- [ ] **Step 5: Write the failing migration + Store CRUD test**

Add to `store_test.exs` (new describe block, alongside the existing ones):

```elixir
  describe "facts" do
    test "upsert_facts/1 then read_facts/1 round-trips" do
      {:ok, facts} = WorkflowFacts.new(%{id: "wf_rt_1", run_id: "run_rt_1"})
      assert {:ok, %WorkflowFacts{id: "wf_rt_1"}} = Store.upsert_facts(facts)
      assert {:ok, %WorkflowFacts{id: "wf_rt_1", run_id: "run_rt_1"}} = Store.read_facts("run_rt_1")
    end

    test "upsert_facts/1 updates in place on repeated calls for the same run_id" do
      {:ok, facts} = WorkflowFacts.new(%{id: "wf_rt_2", run_id: "run_rt_2"})
      {:ok, _} = Store.upsert_facts(facts)

      {:ok, updated} =
        WorkflowFacts.new(%{id: "wf_rt_2", run_id: "run_rt_2", head_sha: "abc123"})

      {:ok, _} = Store.upsert_facts(updated)

      assert {:ok, %WorkflowFacts{head_sha: "abc123"}} = Store.read_facts("run_rt_2")
      # still exactly one row for this run_id
      [[count]] =
        Repo.query!("SELECT COUNT(*) FROM git_workflow_facts WHERE run_id = $1", ["run_rt_2"]).rows

      assert count == 1
    end

    test "read_facts/1 returns not_found for an unknown run_id" do
      assert {:error, :not_found} = Store.read_facts("nonexistent")
    end
  end
```

Add the alias to `store_test.exs`'s top: `alias EzagentPluginGitWorkflow.WorkflowFacts`.

Create the migration (numbered after the existing `20260724010000` one):

```elixir
# apps/ezagent_core/priv/repo_pg/migrations/20260725120000_create_git_workflow_facts.exs
defmodule EzagentCore.Repo.Migrations.CreateGitWorkflowFacts do
  use Ecto.Migration

  def change do
    create table(:git_workflow_facts, primary_key: false) do
      add :id, :string, null: false, primary_key: true
      add :run_id, :string, null: false
      add :workspace_provision_id, :string
      add :deterministic_head_ref, :string
      add :change_digest, :string
      add :expected_base_sha, :string
      add :head_sha, :string
      add :change_request_id, :string
      add :change_request_url, :string
      add :change_request_state, :string
      add :change_request_head_ref, :string
      add :change_request_base_ref, :string
      add :checks_revision, :integer
      add :checks_summary, :string
      add :checks_observed_at, :utc_datetime_usec
      add :reviews_revision, :integer
      add :reviews_summary, :string
      add :reviews_observed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:git_workflow_facts, [:run_id])
  end
end
```

Run the migration: `mix ecto.migrate` (from the repo root, needs the
Postgres partition the app is currently configured against).

- [ ] **Step 6: Run to confirm the Store tests fail**

Run: `cd apps/ezagent_plugin_git_workflow && mix test test/ezagent_plugin_git_workflow/store_test.exs`
Expected: FAIL — `Store.upsert_facts/1` and `Store.read_facts/1` undefined.

- [ ] **Step 7: Implement `Store.upsert_facts/1` and `Store.read_facts/1`**

Add to `store.ex`, aliasing `WorkflowFacts` at the top and adding a new
section (mirrors the existing row↔struct pattern — raw SQL, no
`Ecto.Changeset`, no `Repo.get`):

```elixir
  # ---------------------------------------------------------------------------
  # Facts operations
  # ---------------------------------------------------------------------------

  @doc "Inserts or fully replaces the facts row for `facts.run_id`."
  @spec upsert_facts(WorkflowFacts.t()) :: {:ok, WorkflowFacts.t()}
  def upsert_facts(%WorkflowFacts{} = facts) do
    now = DateTime.utc_now()
    row = facts_to_row(facts, now)

    columns = Map.keys(row)
    values = Map.values(row)
    placeholders = 1..length(columns) |> Enum.map(&"$#{&1}") |> Enum.join(", ")

    update_clause =
      columns
      |> Enum.reject(&(&1 in ["id", "run_id", "inserted_at"]))
      |> Enum.map(&"#{&1} = EXCLUDED.#{&1}")
      |> Enum.join(", ")

    Repo.query!(
      "INSERT INTO git_workflow_facts (" <>
        Enum.join(columns, ", ") <>
        ") VALUES (" <>
        placeholders <>
        ") ON CONFLICT (run_id) DO UPDATE SET " <> update_clause,
      values
    )

    {:ok, facts}
  end

  @doc "Reads the facts row for a run id."
  @spec read_facts(String.t()) :: {:ok, WorkflowFacts.t()} | {:error, :not_found}
  def read_facts(run_id) when is_binary(run_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      Repo.query!("SELECT * FROM git_workflow_facts WHERE run_id = $1", [run_id])

    case rows do
      [] -> {:error, :not_found}
      [row | _] -> {:ok, Enum.zip(columns, row) |> Map.new() |> row_to_facts()}
    end
  end

  defp facts_to_row(%WorkflowFacts{} = facts, now) do
    facts
    |> Map.from_struct()
    |> Map.drop([:inserted_at, :updated_at])
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.put("inserted_at", now)
    |> Map.put("updated_at", now)
  end

  defp row_to_facts(row) when is_map(row) do
    struct!(WorkflowFacts, %{
      id: row["id"],
      run_id: row["run_id"],
      workspace_provision_id: row["workspace_provision_id"],
      deterministic_head_ref: row["deterministic_head_ref"],
      change_digest: row["change_digest"],
      expected_base_sha: row["expected_base_sha"],
      head_sha: row["head_sha"],
      change_request_id: row["change_request_id"],
      change_request_url: row["change_request_url"],
      change_request_state: row["change_request_state"],
      change_request_head_ref: row["change_request_head_ref"],
      change_request_base_ref: row["change_request_base_ref"],
      checks_revision: row["checks_revision"],
      checks_summary: row["checks_summary"],
      checks_observed_at: row["checks_observed_at"],
      reviews_revision: row["reviews_revision"],
      reviews_summary: row["reviews_summary"],
      reviews_observed_at: row["reviews_observed_at"],
      inserted_at: row["inserted_at"],
      updated_at: row["updated_at"]
    })
  end
```

- [ ] **Step 8: Run to confirm it passes**

Run: `cd apps/ezagent_plugin_git_workflow && mix test`
Expected: PASS, 0 failures.

- [ ] **Step 9: Extend the architecture gate**

In `architecture_test.exs`: add `workflow_facts.ex` to both hardcoded scan
lists (now including all six lib files from this slice), and add a migration
secret-scan test mirroring the existing one for the E2 migration:

```elixir
    test "git_workflow_facts migration has no secret/raw-response column" do
      mig =
        Path.join(
          @app_dir,
          "../../ezagent_core/priv/repo_pg/migrations/20260725120000_create_git_workflow_facts.exs"
        )
        |> Path.expand()

      if File.exists?(mig) do
        content = File.read!(mig)

        for forbidden <- ~w(token authorization private_key raw_response header credential) do
          refute content =~ forbidden, "migration must not have a #{forbidden} column"
        end
      end
    end
```

- [ ] **Step 10: Run the full app suite, format, and commit**

Run: `cd apps/ezagent_plugin_git_workflow && mix test`
Expected: PASS, 0 failures.

```bash
cd /home/huangjiajia/ezagent
mix format apps/ezagent_core/priv/repo_pg/migrations/20260725120000_create_git_workflow_facts.exs \
            apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_facts.ex \
            apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/workflow_facts_test.exs \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs \
            apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs
git add apps/ezagent_core/priv/repo_pg/migrations/20260725120000_create_git_workflow_facts.exs \
        apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/workflow_facts.ex \
        apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/workflow_facts_test.exs \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs \
        apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/architecture_test.exs
git commit -m "feat(git-workflow): typed WorkflowFacts schema + Store CRUD"
```

---

## Closing verification (run once, after Task 4)

```bash
cd /home/huangjiajia/ezagent
timeout 300000  # note: pass as tool timeout, not a shell command
MIX_ENV=test mix ci.fast
```

Then the full gate before calling the slice done:

```bash
MIX_ENV=test mix precommit
```

Both must finish (not be killed by a timeout) and exit 0. A killed run is not
a pass — rerun with a longer explicit timeout instead of reporting success.
