# Git Provider V1 Plan E — Slice P4a: Authorized Task / Seam Invoke / Incremental Facts / Blocker Vocabulary — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four load-bearing gaps that Slices P1–P3 explicitly deferred
to P4, as a self-contained foundation with **no orchestration**: a closed
credential-free `%AuthorizedTask{}`, the missing `ExecutionSeam.invoke/3`
dispatcher with tightened types, a `Store.update_facts/2` that writes facts
incrementally without nulling earlier stages, and a total blocker vocabulary
with retry classification and leak-free presentation
(`docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md`
§3.1, §3.2, §5.3, §7.1, §7.2).

**Non-goal:** This slice runs nothing. No stage runner, no workspace call, no
provider call, no observation tick, no state transition beyond what P1 already
ships. Those are P4b/P4c/P4d.

**Architecture:** All production changes stay inside
`apps/ezagent_plugin_git_workflow`. Two new modules
(`AuthorizedTask`, `Blocker`), two modified (`ExecutionSeam`, `Store`). No new
umbrella dependency — the app already declares `:ezagent_actor`,
`:ezagent_core`, `:ezagent_domain_git`, and every downstream capability P4b
needs is reached through `Ezagent.ActionSet.GitTaskAccess` actions rather than
a direct app dep.

**Execution routing (decision A, 2026-07-28):** the seam's real backend
dispatches through the genuine `Ezagent.Invocation.dispatch/1` → Kind runtime →
`Ezagent.ActionSet.GitTaskAccess` → adapter path, so §8's "主场景" is a true
end-to-end run rather than a direct module call. **This slice does not build
that backend** — it only defines the value (`%AuthorizedTask{}`) and the
entrypoint (`invoke/3`) the backend will satisfy. The backend itself is P4d's
test-support module.

**Tech Stack:** Elixir/OTP, Postgrex (raw SQL, matching `Store`'s existing
style — this app uses `Repo.query!/2` throughout, not Ecto changesets), ExUnit.

---

## Global Constraints

- **Owner app is `apps/ezagent_plugin_git_workflow` only.** No file outside it
  changes. In particular `Ezagent.DomainGit.Error` is NOT extended — §4.4
  assigns that type to the GitHub owner, and this slice consumes it read-only.
- **The workflow never mints, derives, reads, or holds a cap.** No
  `Ezagent.Cap.issue/3`, no `Ezagent.Capability.cap/5`, no `ctx.caps` read, no
  principal derivation anywhere in this slice's production code (design §3.2,
  §10 stop-condition). Cap minting belongs to the seam *backend*, which is
  test-only and out of this slice.
- **No token, credential, raw response body, header, or file content** may
  enter `%AuthorizedTask{}`, a `Blocker` presentation map, a log line, or a
  persisted facts column (§3.1, §5.3, §7.1).
- **`ExecutionSeam`'s compile-time backend selection is untouched.** Do not
  convert `@backend` to a runtime lookup, do not add a runtime override, do not
  add a second resolution path. `implementation/0` and the `Application.compile_env/3`
  attribute stay exactly as they are.
- **Production/dev config still never sets `:execution_seam`.** `architecture_test.exs`
  enforces this; it must keep passing unchanged.
- No new process, GenServer, supervision-tree child, or application callback.
- No migration. The `git_workflow_facts` table already has every column this
  slice writes.

---

## Reference: the four deferred gaps this slice closes

Each is a comment or contract already committed on this branch. Read them
before starting; they are the acceptance criteria in the authors' own words.

| # | Where it is written | What P4a owes |
|---|---|---|
| ① | `execution_seam.ex:69` declares `@callback invoke/3`, but the module has no `invoke/3` function — only `authorize/2` is wired | Add the `invoke/3` dispatcher, keeping dynamic dispatch concentrated in this one module |
| ② | `execution_seam.ex` moduledoc §"Provisional `term()` typing (deferred to Slice P4)" | Replace `@type authorized_task :: term()` with a closed struct so the contract cannot silently widen to permit a cap / `%Invocation{}` / token leak |
| ③ | `store.ex:609` `facts_to_row/2` emits **every** field including `nil`, and `upsert_facts/1`'s `ON CONFLICT` sets every column to `EXCLUDED` | Add an incremental writer so a later stage cannot null out an earlier stage's facts |
| ④ | `github_adapter.ex:184-194` KNOWN LIMITATION — the adapter cannot tell its own retry's ref from a foreign ref sitting at base, and names "the workflow's own durable facts (design §5.3)" as the fix | ③'s writer is the mechanism; **P4b** does the actual write-before-call ordering. P4a only guarantees the write is non-destructive. |

---

## Task 1 — `AuthorizedTask`: a closed, credential-free authorization value

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/authorized_task.ex` (new)

The seam moduledoc specifies the contents exactly: "a validated exact
`GitTaskAccess` policy, task URI, and generation". Nothing else.

- [ ] Define the struct with `@enforce_keys` over exactly four fields:
      `:policy` (`%Ezagent.Entity.GitTaskAccess{}`), `:task_access_uri`
      (`URI.t()`), `:task_uri` (`URI.t()`), `:generation` (`pos_integer()`).
      No `caps`, no `ctx`, no `token`, no `invocation`, no free-form `metadata`
      map — a struct with no place to put a credential cannot carry one.
- [ ] `new/1` follows the shape already used by `Ezagent.DomainGit.OperationContext.new/1`
      and `CreateChangeRequest.new/1`: reject non-atom keys, reject any key
      outside the four, reject a missing key, then validate values. Return
      `{:ok, t()}` | `{:error, :unknown_fields}` | `{:error, {:missing_field, atom}}`
      | `{:error, {:invalid_field, atom}}`.
- [ ] Value validation must prove the four fields are mutually consistent, not
      merely well-typed:
      - `policy` round-trips through `Ezagent.Entity.GitTaskAccess.revalidate/1`
        (the same chokepoint `ActionSet.GitTaskAccess.dispatch_operation/3`
        uses) — a policy that would be rejected downstream must be rejected here.
      - `task_uri` equals `policy.task_uri` exactly.
      - `generation` equals `policy.generation` exactly.
      - `task_access_uri` equals `Ezagent.Entity.GitTaskAccess.uri_from_args(policy)`
        exactly.
      A caller cannot assemble an authorized task for one policy while naming a
      different task, generation, or task-access instance.
- [ ] Do **not** add an `Inspect` implementation that redacts. There is nothing
      secret in the struct, and a redacting `Inspect` would make a future leak
      harder to notice in test output rather than easier.

**Tests** — `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/authorized_task_test.exs` (new)

- [ ] The struct's field set is exactly the four keys. Write this as
      `assert Map.keys(Map.from_struct(task)) |> Enum.sort() == [...]` so that
      **adding a field to the struct fails this test** — that is the whole
      point of ②, and a test that only checks the four are present would pass
      after someone adds `:caps`.
- [ ] `new/1` rejects each of `:caps`, `:cap`, `:token`, `:invocation`, `:ctx`
      as `{:error, :unknown_fields}`. These are the specific leak vectors §3.1
      names; assert them by name rather than testing "some unknown key".
- [ ] `new/1` rejects a `task_uri` that does not match `policy.task_uri`, a
      mismatched `generation`, and a mismatched `task_access_uri` — one test
      each, each asserting the specific `{:invalid_field, _}`.
- [ ] `new/1` rejects a policy that fails `revalidate/1`.
- [ ] Happy path returns `{:ok, %AuthorizedTask{}}` for a consistent set.

> **Fixture note.** Build the policy with the post-#1588 shape — `task_uri:`,
> and `idempotency_inputs: %{task_uri: ..., generation: ...}`. The canonical
> example is `apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs:324`.
> A fixture written from memory against the old `task_id:` contract fails with
> `{:error, :unknown_fields}` inside the fixture itself and tests nothing —
> that exact mistake cost `change_collector_test.exs` 26 red tests.

---

## Task 2 — `ExecutionSeam.invoke/3` and tightened types

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/execution_seam.ex` (modify)

- [ ] Replace `@type authorized_task :: term()` with
      `@type authorized_task :: AuthorizedTask.t()`.
- [ ] Replace `@type action :: atom()` with the closed union of the eight
      actions `Ezagent.ActionSet.GitTaskAccess` declares in its `@actions`:
      `:resolve_repository | :create_change_request | :read_change_request |
      :list_checks | :list_reviews | :provision_workspace | :cleanup_workspace |
      :collect_workspace_changes`.
- [ ] Add the dispatcher, mirroring `authorize/2`'s existing shape and its
      "single call site" rationale:

      ```elixir
      def invoke(%AuthorizedTask{} = task, action, args) when action in @actions,
        do: @backend.invoke(task, action, args)
      ```

      The `%AuthorizedTask{}` pattern and the `action in @actions` guard are
      both load-bearing: a raw map, a bare policy, or an action outside the
      closed vocabulary must never reach a backend. A non-matching call raises
      `FunctionClauseError` — fail closed and loud, not a silent `{:error, _}`
      the caller might log and continue past.
- [ ] Leave `typed_args`/`typed_result` as `term()`, and **document why** in the
      moduledoc, replacing the "deferred to Slice P4" section: their per-action
      shape is already gated structurally by `ActionSet.GitTaskAccess`'s
      `@allowed_keys` whitelist, which rejects any arg key outside the
      per-action list. Combined with `%AuthorizedTask{}` having no credential
      field, there is no place in this contract for a cap or token to ride.
      State that as the reason the two remaining `term()`s are acceptable — do
      not leave them silently unexplained, and do not invent a seam-level
      key-blacklist (a blacklist of spellings is exactly the kind of
      unenforceable guard this project has repeatedly found does not hold).
- [ ] `alias EzagentPluginGitWorkflow.AuthorizedTask`.

**Tests** — `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/execution_seam_test.exs` (extend; keep it non-async as it already is)

- [ ] `invoke/3` with the fail-closed default backend returns
      `{:error, :authorization_unavailable}` — i.e. `Unavailable` gains an
      `invoke/3` that is as dead an end as its `authorize/2`. Add that clause
      to `execution_seam/unavailable.ex`.
- [ ] `invoke/3` raises `FunctionClauseError` for a plain map in place of an
      `%AuthorizedTask{}`.
- [ ] `invoke/3` raises `FunctionClauseError` for an action outside the eight.
- [ ] The eight actions are each accepted (reaching the backend) — assert via
      the process-local fake, not by asserting the guard list literally.
- [ ] **Ask of every new test: if I deleted the thing this test is named for,
      would it fail?** A test that asserts `invoke/3` "exists" by calling it
      and matching `{:error, _}` would still pass with the guard removed. The
      guard tests above must assert the raise.

---

## Task 3 — `Store.update_facts/2`: incremental, non-destructive

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/store.ex` (modify)

`upsert_facts/1` stays exactly as it is — P4b uses it once per run to establish
the row with its three `@required_fields`. This task adds the incremental
writer every subsequent stage uses.

- [ ] `@spec update_facts(String.t(), map()) :: {:ok, WorkflowFacts.t()} | {:error, :not_found} | {:error, :unknown_fields} | {:error, :empty_update}`
- [ ] Column whitelist: accept only keys in `WorkflowFacts`'s optional-field
      set (the 16 nullable columns). Reject `:id`, `:run_id`, `:workspace_uri`,
      `:inserted_at`, `:updated_at`, and anything unknown, with
      `{:error, :unknown_fields}`. This is both an identity guard (a fact write
      must never move a row's identity) and the reason the generated SQL cannot
      carry a caller-chosen column name.
      **Derive the whitelist from `WorkflowFacts`** — that module keeps
      `@optional_fields` private today, so add a small public accessor
      (`def optional_fields, do: @optional_fields`) and have `Store` call it,
      rather than re-typing the 16 names in `Store`; two hand-maintained copies
      drift.
- [ ] Reject an empty map with `{:error, :empty_update}` rather than emitting
      `UPDATE ... SET  WHERE ...`.
- [ ] Emit a plain `UPDATE git_workflow_facts SET <given cols>, updated_at = $n
      WHERE run_id = $m RETURNING *`, parameterised, columns interpolated only
      from the whitelist. Build the returned struct from `RETURNING *` via the
      existing `row_to_facts/1` — never from the caller's input, for the same
      reason `upsert_facts/1` already documents.
- [ ] `num_rows == 0` → `{:error, :not_found}`. A stage writing facts for a run
      whose row was never established is a bug in the runner, and must surface
      as one rather than silently inserting a partial row.

**Tests** — `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/store_test.exs` (extend)

- [ ] **The regression this task exists for:** `upsert_facts/1` a row with
      `workspace_provision_id` set, then `update_facts/2` with only
      `deterministic_head_ref`, then read back and assert
      `workspace_provision_id` is **still set**. Assert the same for a third
      write. This test fails today against `upsert_facts/1` — write it first
      and watch it fail before implementing, so it is known to be load-bearing.
- [ ] Each of `:id`, `:run_id`, `:workspace_uri` is rejected with
      `{:error, :unknown_fields}`, asserted per-column.
- [ ] An unknown column (`%{drop_table: "x"}`) is rejected.
- [ ] Empty map → `{:error, :empty_update}`.
- [ ] Unknown `run_id` → `{:error, :not_found}` and writes nothing.
- [ ] `updated_at` advances; `inserted_at` and `id` do not change.
- [ ] Datetime and integer columns (`checks_observed_at`, `checks_revision`)
      round-trip, not only strings.

---

## Task 4 — `Blocker`: total vocabulary, retry classification, leak-free presentation

**File:** `apps/ezagent_plugin_git_workflow/lib/ezagent_plugin_git_workflow/blocker.ex` (new)

Design §7.1 lists 15 stable blockers and says "**至少**包括" — the real
requirement is that the mapping be **total**, because anything unmapped either
crashes the runner or leaks a raw provider reason into presentation.

- [ ] `@stable_codes` — the 15 from §7.1 verbatim:
      `authorization_unavailable`, `not_authorized`, `workspace_not_ready`,
      `workspace_identity_mismatch`, `unsupported_workspace_change`,
      `change_limit_exceeded`, `base_sha_mismatch`, `head_ref_conflict`,
      `change_request_conflict`, `installation_scope_mismatch`,
      `provider_permission_denied`, `provider_rate_limited`,
      `provider_unavailable`, `observation_incomplete`, `no_changes_collected`.
- [ ] Extend that set with the codes the ports actually produce but §7.1 did
      not enumerate — the gap is real and this slice must close it explicitly
      rather than let them fall through:
      - `workspace_read_failed` and `invalid_change_limits_config` from
        `Ezagent.Workspace.TaskWorkspace.ChangeCollector`'s closed vocabulary;
      - `repository_not_found`, `base_ref_not_found`, `invalid_ref`,
        `invalid_file_change`, `checks_unavailable`,
        `provider_account_not_connected`, `credential_backend_unavailable`,
        `private_checkout_not_supported` from `Ezagent.DomainGit.Error.t()`.
      Record in the moduledoc that these extend §7.1's "至少" list, and why.
- [ ] `classify/1 :: :retryable | :terminal_blocker` per §7.2:
      - deterministic validation/conflict → `:terminal_blocker`
        (`not_authorized`, `workspace_identity_mismatch`,
        `unsupported_workspace_change`, `change_limit_exceeded`,
        `base_sha_mismatch`, `head_ref_conflict`, `change_request_conflict`,
        `installation_scope_mismatch`, `invalid_ref`, `invalid_file_change`,
        `private_checkout_not_supported`, `invalid_change_limits_config`,
        and **`no_changes_collected`** — design §7.1's 2026-07-26 amendment
        makes this one explicit: re-running the same generation only ever
        yields the same empty diff);
      - transient/provider → `:retryable` (`provider_rate_limited`,
        `provider_unavailable`, `authorization_unavailable`,
        `workspace_not_ready`, `workspace_read_failed`, `checks_unavailable`,
        `credential_backend_unavailable`, `observation_incomplete`);
      - decide and document each remaining code; no code may be unclassified.
- [ ] `from_error/1` maps a port/adapter error term to a stable code:
      - the seam's two atoms pass through;
      - `ChangeCollector`'s atoms pass through;
      - `Ezagent.DomainGit.Error.t()` members map by name, except
        `repository_read_denied` / `repository_write_denied` /
        `authentication_rejected` → `provider_permission_denied`;
      - `{:provider_request_failed, _operation, status}` maps by status class:
        401/403 → `provider_permission_denied`, 429 → `provider_rate_limited`,
        5xx → `provider_unavailable`, anything else → `provider_unavailable`.
        **The `operation` atom must be dropped**, not carried into
        presentation — it is provider-shaped detail.
      - a final catch-all → `:internal_error` that **drops the term entirely**.
        Not a crash (a crash in a runner is worse than a safe generic), and not
        a passthrough (a passthrough is the leak §7.1 forbids).
- [ ] `present/4 :: (code, stage, attempt, safe_metadata) -> map()` returning
      exactly `%{code:, stage:, retryable:, attempt:, metadata:}` — §7.1's
      permitted fields and nothing else. `retryable` is derived from
      `classify/1`, never passed in. `safe_metadata` accepts only a map of
      atom keys to integers/booleans/atoms — reject binaries outright, since a
      binary is how a response body, header, token, or file path would arrive.

**Tests** — `apps/ezagent_plugin_git_workflow/test/ezagent_plugin_git_workflow/blocker_test.exs` (new)

- [ ] **Totality over `Ezagent.DomainGit.Error.t()`:** enumerate all **18 atom
      members** (`error.ex` lines 5–22) plus the
      `{:provider_request_failed, _, _}` tuple form explicitly in the test and
      assert none maps to `:internal_error`. This is the test that catches a
      future domain_git error addition — name it so that intent is obvious.
- [ ] **Totality over `ChangeCollector`'s vocabulary:** the 7 codes its
      moduledoc documents as the closed returned set, plus
      `:invalid_change_request` from its fallback `collect(_request)` clause.
      **First verify** that the four finer-grained reasons appearing in that
      module (`:binary_content`, `:executable_mode`, `:not_regular_file`,
      `:path_escapes_worktree`) are internal-only — normalized to
      `:unsupported_workspace_change` before they leave `collect/1`. If any
      escapes, it needs a mapping too, and the moduledoc's "closed vocabulary"
      claim is wrong and should be reported rather than worked around.
- [ ] Every code in `@stable_codes` (plus the extensions) has a `classify/1`
      answer — iterate the list, assert each returns one of the two atoms.
      A code added without a classification must fail this test.
- [ ] `no_changes_collected` classifies as `:terminal_blocker` — its own named
      test, since §7.1's amendment calls it out and the intuitive reading
      ("retry and maybe the agent writes something") is wrong.
- [ ] `{:provider_request_failed, :create_ref, 403}` presents without
      `:create_ref` appearing anywhere in the result.
- [ ] `present/4` rejects binary metadata values.
- [ ] `present/4`'s result has exactly the five keys — sorted-keys assertion, so
      adding a sixth fails.

---

## Task 5 — Slice gates

- [ ] `mix format` clean on every touched file.
- [ ] `MIX_ENV=test POSTGRES_PORT=15432 mix test apps/ezagent_plugin_git_workflow/test` — all green.
      (Note the port: this machine's cluster is on 15432, not the default;
      55432 is inside the Windows-reserved range under WSL2 mirrored networking.)
- [ ] `MIX_ENV=test POSTGRES_PORT=15432 mix ci.fast` — green.
- [ ] `MIX_ENV=test mix ezagent.arch.scan` — green, and specifically
      `cross_file_duplicate_fn_groups` still at 42. If a new module duplicates
      an existing function body, **de-duplicate it**; do not add
      `# arch-cap-bump`.
- [ ] `mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs`
      — green. New dynamic-receiver sites in this plugin change the exact-match
      ledger; regenerate it from the scanner's own output and **review the
      diff** (every added fingerprint must be one this slice actually
      introduced) rather than pasting the scanner output blind.
- [ ] `architecture_test.exs` still passes unchanged — in particular the
      assertions that prod/dev config never name `:execution_seam` and that
      `implementation/0` is compile-time.
- [ ] Grep the slice's own diff for `Cap.issue`, `Capability.cap`, `ctx.caps`,
      `caps:`, `token` — expect zero hits in `lib/`.

---

## Handoff to P4b

State explicitly in the completion report:

- `%AuthorizedTask{}` exists and is closed, but **nothing constructs one yet** —
  `Unavailable` still returns `{:error, :authorization_unavailable}` from both
  callbacks, so the seam remains a genuine production dead end. P4d builds the
  test backend that constructs one and dispatches through
  `Ezagent.Invocation.dispatch/1`.
- `Store.update_facts/2` exists but nothing calls it. P4b owns the ordering
  contract the GitHub adapter's KNOWN LIMITATION depends on: **write
  `deterministic_head_ref` to facts before the first provider mutation call**,
  so a resumed run can prove a ref at base is its own.
- `Blocker.classify/1` exists but no state transition consumes it. P4b maps
  `:terminal_blocker` → the `blocked` state and `:retryable` → a bounded retry,
  using P1's `WorkflowRun` legal-edge table (`blocked → blocked` self-loop is
  already legal; `failed`/`cancelled` are the only terminal states).
