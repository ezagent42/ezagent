# Git Provider V1 Plan E — Slice P3: GitHub Branch/Commit/PR Idempotent Reconciliation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `EzagentPluginGithub.GitHubAdapter.create_change_request/4`
idempotent under retry — deterministic ref create-or-reconcile, commit/head
reconciliation, and PR exact find-or-create — so that re-invoking it after a
crash at any of the five windows in
`docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md`
§6.2 never duplicates a remote mutation, while keeping the existing
one-token-per-callback / no-leakage guarantees intact.

**Architecture:** All changes stay inside `ezagent_plugin_github` (plus one
narrow, additive extension to the already-shared `Ezagent.DomainGit.Error`
closed type, which design §4.4 explicitly assigns to the GitHub owner: "GitHub
HTTP error 到 closed DomainGit error 的映射"). The adapter's public
`@behaviour Ezagent.DomainGit.Adapter` callback surface is unchanged — same 5
functions, same signatures. `create_change_request/4`'s internals are
restructured from a linear create-only chain into a `with`-based
create-or-reconcile chain: verify base ref → reconcile deterministic head ref
(GET-then-branch: absent → build fresh commit + create ref; present → verify
safe reuse via the commit's parent) → reconcile the PR (GET-then-branch: none
found → create; exactly one → return it; more than one → fail closed). One
operation-scoped token, minted once at the top of the callback, is threaded
as a plain parameter through every new helper — no new mint call sites.

**Tech Stack:** Elixir/OTP, `Req` 0.6.3 + `Req.Test` (no real GitHub calls),
`Plug.Conn` test stubs, ExUnit (`async: false` for the Req.Test-stubbed
files, matching the existing convention in this app).

## Global Constraints

- Owner app is `ezagent_plugin_github` only, plus the additive
  `Ezagent.DomainGit.Error` type extension design §4.4 assigns to this
  slice. No other file outside these two apps changes.
- The provider-neutral adapter action vocabulary is FROZEN: `resolve_repository`,
  `create_change_request`, `read_change_request`, `list_checks`,
  `list_reviews`, plus `provision_workspace`/`cleanup_workspace` on the
  ActionSet (untouched by this slice). No merge action in V1. No new
  `@callback` is added to `Ezagent.DomainGit.Adapter`.
- GitHub concepts (installation ids, branch-lookup queries, PR API shapes,
  raw response bodies) must never reach a `DomainGit` value, a `Error.t()`
  member, a log line, or a caller. All new `Error.t()` atoms are
  provider-neutral names.
- One operation-scoped token per adapter callback, minted once, threaded as a
  plain function parameter through every helper this slice adds, discarded
  when the callback returns. No caching, no ETS, no Agent, no process
  dictionary, no cross-callback reuse, and — the specific new risk this slice
  introduces — no new `installation_token(...)` call site inside any of the
  new reconciliation helpers.
- No token, authorization header, private key, installation id, or raw
  provider response body may reach a result, a mapped error, a log line,
  Application env, or persistent term.
- Never force-push. This slice's design goes further than "PATCH with
  `force: false`": it deletes the PATCH-based ref update entirely.
  `:head_ref_conflict` is returned whenever the deterministic ref exists but
  its sole parent does not equal the verified base sha.
- No real GitHub calls anywhere in this slice — `Req.Test` only, exactly as
  the existing test suite already does.
- `apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs`
  scans every `apps/ezagent_plugin_*` file (this app included) for calls
  through a variable receiver the AST scanner cannot statically resolve to a
  literal module. Every new helper in this plan calls other modules through
  literal aliases only (`GitHubClient`, `Enum`, `Plug.Conn`, …) — never
  through a variable bound to a module value. This app has zero entries in
  that gate's baseline/allowlist today; this plan keeps it at zero.
- Formatter noise policy: run `mix format` only on the files this plan
  touches, not the whole project.
- PostgreSQL for this worktree's test partition is on port **15432**, not the
  project default 55432. Use `MIX_TEST_PARTITION=p3`.
- Every task in this plan ends with **two** verification runs, not one: the
  app-scoped test run (proves the task's own new/changed tests pass) and
  `MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ci.fast` (proves
  no umbrella-wide invariant — especially the workspace-locality gate above —
  regressed). `mix ci.fast`'s `gate.arch` step does **not** run
  `apps/ezagent_plugin_github/test/**`, so it is not a substitute for the
  app-scoped run; both are required. Pass an explicit `timeout: 300000` when
  running `ci.fast` via a tool that defaults to a 120s timeout — a killed run
  is not a pass.

## Survey: what already exists vs. what this slice adds

Read before touching code — this is not a green field.

`apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex`
already implements all 5 `Ezagent.DomainGit.Adapter` callbacks correctly for
the **create-only, single-shot** case:

- `resolve_repository/2`, `read_change_request/3`, `list_checks/3`,
  `list_reviews/3` are pure reads, already correctly idempotent (a GET has no
  mutation to duplicate), and **this plan does not change them**.
- `create_change_request/4` mints one `:change_request_write` token, fetches
  the base ref and verifies `expected_base_sha`, then — for non-empty
  `file_changes` — unconditionally builds blob → tree → commit, `PATCH`es the
  deterministic head ref to that commit with `force: false`, and
  unconditionally `POST`s a new PR. For empty `file_changes` it skips
  straight to the PR `POST`.

Three concrete gaps against design §6.1/§6.2, found by reading the code
against the real GitHub REST API docs (verified via the GitHub API reference,
not assumed):

1. **No ref-existence check.** `update_head_ref/4` always `PATCH`es
   `/git/refs/heads/{head_ref}` — GitHub's "Update a reference" endpoint
   addresses an *existing* ref; on the deterministic branch's first-ever
   creation (the normal case — the branch is brand new every run) this would
   fail against real GitHub, not just "not reconcile." The correct
   first-creation call is `POST /git/refs` (which the current code never
   calls). Retrying today would either keep hitting this failure or (worse,
   if GitHub ever tolerated it) silently move the ref — which is exactly the
   force-push risk design §6.2 forbids.
2. **`base_tree` bug.** `create_tree/5` passes `ref_data["object"]["sha"]` —
   the base ref's **commit** sha (`GET git/ref/heads/{branch}` always returns
   a commit sha) — as `base_tree`, but GitHub's `POST git/trees` `base_tree`
   parameter is documented as "the SHA1 of an existing Git **tree** object."
   Commit and tree objects live in separate sha namespaces; every existing
   test passes only because `Req.Test` mocks don't validate this the way real
   GitHub would. The fix needs one more read: `GET git/commits/{base_sha}` to
   read `tree.sha`.
3. **No PR find-before-create.** `create_pr/3` always `POST`s. Retrying
   `create_change_request/4` after a crash that happened just after a
   successful PR creation would `POST` a second PR for the same head+base
   (or, against real GitHub, hit a 422 "pull request already exists" that the
   current code maps to the generic `:change_request_conflict` without ever
   trying to find and return the PR that already exists).

None of this is a design gap — §6.1's numbered steps already specify
GET-before-decide for both the ref and the PR. It is an implementation gap:
the code was built create-only and this slice completes it to create-or
-reconcile. `EzagentPluginGithub.GitHubInstallation` (operation-scoped token
minting, Slice E1) and `EzagentPluginGithub.GitHubClient` (the Req HTTP
surface) are already correct for this slice's needs and only need one small,
additive change (Task 2, a 429 status mapping) — no restructuring.

`apps/ezagent_domain_git/lib/ezagent/domain_git/error.ex`'s `Error.t()` union
is also already slightly out of sync with runtime behavior:
`GitHubInstallation.token_for_operation/3` can already return
`{:error, :installation_scope_mismatch}`, and every `map_*_error` helper in
the adapter passes unrecognized reasons through unchanged (`other -> other`)
— so this atom already silently escapes `resolve_repository/2`,
`create_change_request/4`, `read_change_request/3`, `list_checks/3`, and
`list_reviews/3` today without being declared in the type. Task 2 fixes the
type to match the real runtime behavior (prose/behavior consistency) and adds
the two genuinely new atoms this slice's reconciliation logic needs.

---

### Task 1: Test partition bootstrap + dependency install + baseline

**Files:**
- Modify: none (environment setup only; no source changes in this task)

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a working `MIX_ENV=test` build against the `p3` Postgres
  partition on port 15432, and a recorded baseline (`234 tests, 0 failures`
  or whatever the actual current count is) that every later task's diff is
  measured against.

- [ ] **Step 1: Install dependencies for this worktree**

This worktree has no `_build`/`deps` yet (fresh linked worktree). Run from
the repo root:

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
mix deps.get
```

Expected: completes with `All dependencies are up to date` or a resolution
report, exit 0.

- [ ] **Step 2: Create and migrate the `p3` test partition**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ecto.create --quiet
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ecto.migrate --quiet
```

Expected: both exit 0. This creates database `ezagent_pg_compat_testp3` on
`localhost:15432` (per `config/test.exs:47-48`,
`database: "ezagent_pg_compat_test#{System.get_env("MIX_TEST_PARTITION")}"`)
and runs every existing migration against it.

- [ ] **Step 3: Record the pre-change baseline for the two apps this plan touches**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix test apps/ezagent_plugin_github apps/ezagent_domain_git
```

Expected: all tests pass (this is the untouched-baseline count; write it down
— every later task's "Expected" step count is baseline + the new/changed
tests that task adds). As of this plan's authoring, `github_adapter_test.exs`
alone has 22 tests; do not hardcode that number into a later task's
verification step, re-derive it from this run's actual output.

- [ ] **Step 4: Run the umbrella-wide fast gate to confirm a clean starting point**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ci.fast
```

Run with an explicit `timeout: 300000` if invoked through a tool defaulting
to 120s. Expected: exits 0 (ecto.create/migrate no-op since Task 1 Step 2
already ran them, `ezagent.check_invariants` clean, `socialware.check` clean,
`gate.arch` — including
`apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs`
— all green). A killed run is not a pass; if it times out, rerun with a
longer explicit timeout rather than reporting success.

- [ ] **Step 5: No commit for this task**

Nothing in the working tree changed (environment-only task) — `git status`
should be clean. Do not commit.

---

### Task 2: Close the `DomainGit.Error` mapping completeness gap

**Files:**
- Modify: `apps/ezagent_domain_git/lib/ezagent/domain_git/error.ex:4-21`
- Modify: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_client.ex:107-115`
- Modify: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs` (add one test after the existing "get maps other 4xx/5xx to provider_unavailable" test)
- Modify: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs` (add one test to the "operation-scoped mint" describe block)

**Interfaces:**
- Consumes: `Ezagent.DomainGit.Error.t()` (existing closed type, being
  extended, not restructured); `EzagentPluginGithub.GitHubClient.get/3,post/4,patch/4`
  (existing, being extended with one new response-status clause).
- Produces: `Ezagent.DomainGit.Error.t()` now includes `:head_ref_conflict`,
  `:installation_scope_mismatch`, and `:provider_rate_limited` — Task 3 and
  Task 4 return the first from the new reconciliation logic, and all three
  are now documented as valid results from every adapter callback.
  `GitHubClient.get/3` (and `post/4`/`patch/4`, sharing `handle_response/1`)
  now maps HTTP 429 to `{:error, :provider_rate_limited}` instead of falling
  into the generic `:provider_unavailable` catch-all.

- [ ] **Step 1: Write the failing test for GitHubClient's 429 mapping**

Add to `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs`,
directly after the existing `"get maps other 4xx/5xx to provider_unavailable"`
test (so 5xx and 429 sit next to each other for contrast):

```elixir
  test "get maps 429 to provider_rate_limited" do
    Req.Test.stub(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 429, ~s({"message": "You have exceeded a secondary rate limit"}))
    end)

    assert {:error, :provider_rate_limited} =
             GitHubClient.get("/repos/owner/repo", "token", plug: {Req.Test, @stub_name})
  end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_client_test.exs`
Expected: FAIL — the 429 currently falls into the `{:ok, _}` catch-all clause
and returns `{:error, :provider_unavailable}`, not `{:error, :provider_rate_limited}`.

- [ ] **Step 3: Add the 429 clause to `GitHubClient.handle_response/1`**

In `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_client.ex`,
insert a new clause before the two catch-alls (currently lines 107-115):

```elixir
  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: 401}}), do: {:error, :authentication_rejected}
  defp handle_response({:ok, %{status: 404}}), do: {:error, :repository_not_found}
  defp handle_response({:ok, %{status: 403}}), do: {:error, :provider_denied}
  defp handle_response({:ok, %{status: 422}}), do: {:error, :change_request_conflict}
  defp handle_response({:ok, %{status: 429}}), do: {:error, :provider_rate_limited}
  defp handle_response({:ok, _}), do: {:error, :provider_unavailable}
  defp handle_response({:error, _}), do: {:error, :provider_unavailable}
```

Also update the `@moduledoc` table (lines 13-21) to list the new status:

```elixir
  ## Returns

    Success (HTTP 2xx) → `{:ok, decoded_body}` where `decoded_body` is a map
    Error (HTTP 4xx/5xx) → `{:error, reason_atom}` where `reason_atom` is one of:

      | Status | Atom                          |
      |--------|-------------------------------|
      | 401    | `:authentication_rejected`    |
      | 403    | `:provider_denied`            |
      | 404    | `:repository_not_found`       |
      | 422    | `:change_request_conflict`    |
      | 429    | `:provider_rate_limited`      |
      | other  | `:provider_unavailable`       |
  """
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_client_test.exs`
Expected: PASS (all tests in this file, including the new one).

- [ ] **Step 5: Extend `Ezagent.DomainGit.Error.t()` with the three atoms this slice needs**

In `apps/ezagent_domain_git/lib/ezagent/domain_git/error.ex`, replace the
`@type t` block:

```elixir
defmodule Ezagent.DomainGit.Error do
  @moduledoc "Provider and adapter errors for Git operations."

  @type t ::
          :provider_account_not_connected
          | :credential_backend_unavailable
          | :repository_not_found
          | :repository_read_denied
          | :repository_write_denied
          | :private_checkout_not_supported
          | :base_ref_not_found
          | :base_sha_mismatch
          | :invalid_ref
          | :invalid_file_change
          | :change_limit_exceeded
          | :change_request_conflict
          | :checks_unavailable
          | :provider_unavailable
          | :authentication_rejected
          | :installation_scope_mismatch
          | :head_ref_conflict
          | :provider_rate_limited
          | {:provider_request_failed, operation :: atom(), status :: pos_integer()}
end
```

`:installation_scope_mismatch` documents existing runtime behavior (see
Survey section above) — this is a type-completeness fix, not new behavior.
`:head_ref_conflict` and `:provider_rate_limited` are genuinely new: Task 3
returns the former, Task 2 Step 3 above just made the latter reachable
through every callback that mints a token or makes a GitHub HTTP call.

This is a bare `@type` change with no runtime code — it cannot be asserted by
an ExUnit test directly. Step 6 below adds the actual behavioral proof (that
`:installation_scope_mismatch` really does propagate end-to-end through a
real adapter callback, not just through `GitHubInstallation` in isolation
the way `github_installation_test.exs` already covers).

- [ ] **Step 6: Write the failing end-to-end test proving `:installation_scope_mismatch` propagates through the adapter, not just through `GitHubInstallation`**

`apps/ezagent_plugin_github/test/ezagent_plugin_github/github_installation_test.exs`
already proves `GitHubInstallation.token_for_operation/3` itself returns this
error on a malformed mint response. Nothing today proves it survives the
adapter's own error-mapping layer. Add to
`apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs`,
inside the existing `describe "operation-scoped mint — profile selection and mint count"` block (after the three tests already there):

```elixir
    test "a malformed mint response surfaces as installation_scope_mismatch through the adapter, not a generic error" do
      Req.Test.stub(@stub_name, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/repos/owner/repo/installation"} ->
            Req.Test.json(conn, %{"id" => 123})

          {"POST", "/app/installations/123/access_tokens"} ->
            # Wider-than-requested permissions -- GitHubInstallation's strict
            # scope validation must reject this before any repository call.
            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "token" => "ghs-test-token",
              "expires_at" => future_iso(),
              "repository_selection" => "selected",
              "repositories" => [%{"full_name" => "owner/repo"}],
              "permissions" => %{"metadata" => "read", "contents" => "write"}
            })
        end
      end)

      assert {:error, :installation_scope_mismatch} =
               GitHubAdapter.resolve_repository(ctx(), repo())
    end
```

- [ ] **Step 7: Run it to confirm it fails**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_test.exs -k installation_scope_mismatch`

Expected: FAIL before Step 5 lands — actually, since `map_read_error/1`
already passes unknown atoms through unchanged (`other -> other`), this test
will likely PASS even without any adapter code change, because the runtime
behavior described in the Survey section already exists. That is the point:
Step 5 is a type-only documentation fix, and this test's job is to pin the
already-correct runtime behavior against regression, not to drive new
adapter code. If it fails, the atom is being swallowed or remapped somewhere
in `map_read_error/1` and that is a real bug to fix (do not "fix" the test
to match; fix `map_read_error/1` so `:installation_scope_mismatch` passes
through unchanged, matching every other unrecognized-reason clause in that
function).

- [ ] **Step 8: Run it to confirm it passes**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_test.exs`
Expected: PASS (all tests, baseline count + 1).

- [ ] **Step 9: Format and run both verification commands**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
mix format apps/ezagent_domain_git/lib/ezagent/domain_git/error.ex \
  apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_client.ex \
  apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs \
  apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix test apps/ezagent_plugin_github apps/ezagent_domain_git
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ci.fast
```

Expected: both exit 0. Use `timeout: 300000` for the `ci.fast` call.

- [ ] **Step 10: Commit**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
git add apps/ezagent_domain_git/lib/ezagent/domain_git/error.ex \
        apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_client.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_client_test.exs \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs
git commit -m "fix(git-provider): close DomainGit.Error mapping gaps (429, installation_scope_mismatch, head_ref_conflict)"
```

---

### Task 3: Deterministic ref create-or-reconcile + PR exact find-or-create

This is the core of the slice: `create_change_request/4` is rewritten from a
linear create-only chain into the create-or-reconcile algorithm design §6.1
specifies. Ref-reconciliation and PR-reconciliation are done together in one
task because they are one `with` chain in the same callback and every
existing ordered-`Req.Test.expect` test that exercises the full happy path
needs its HTTP sequence rewritten regardless of which half changes first —
writing that sequence once, in its final form, avoids rewriting it a second
time in a follow-up task.

**Files:**
- Modify: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex:42-195`
  (replaces `create_change_request/4`, `verify_base_sha/2`,
  `create_change_request_with_files/5`, `create_blobs/3`, `create_tree/5`,
  `create_commit/4`, `update_head_ref/4`, `create_pr/3` with the
  create-or-reconcile algorithm below; `create_blobs/3`, `create_tree/5`,
  `create_commit/4`, `create_pr/3`, and `build_change_request/1` are reused
  essentially unchanged, only re-wired)
- Modify: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs`
  (rewrite the tests named below; add the new tests named below)
- Modify: `apps/ezagent_plugin_github/test/architecture/operation_scoped_credential_test.exs`
  (add one sentinel test after the existing one)

**Interfaces:**
- Consumes: `Ezagent.DomainGit.Error.t()` now including `:head_ref_conflict`
  (Task 2); `EzagentPluginGithub.GitHubClient.get/3`, `post/4` (unchanged
  signatures); `EzagentPluginGithub.GitHubInstallation.token_for_operation/3`
  (unchanged, still called exactly once per callback).
- Produces: `EzagentPluginGithub.GitHubAdapter.create_change_request/4`'s
  **public signature and `@behaviour` contract are unchanged** — same 4 args,
  same `{:ok, ChangeRequest.t()} | {:error, Error.t()}` return. Task 4's
  crash-window tests call this same public function twice per test; they do
  not reference any of this task's new private helpers by name.

#### Step-by-step

- [ ] **Step 1: Write the failing tests for the full create-or-reconcile happy path**

Two existing tests change shape (they exercise the same "ref absent → full
create" path, just now with the corrected HTTP sequence) and the empty
`file_changes` test is replaced by two tests with corrected semantics (empty
`file_changes` is legal only when a head ref *already exists* to reconcile
against — it is not legal to skip commit creation on a first-ever create,
which the current code silently allows). In
`apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs`:

Replace the `"create_change_request's multi-step HTTP batch mints exactly once"`
test (inside `describe "operation-scoped mint — profile selection and mint count"`) with:

```elixir
    test "create_change_request's multi-step reconciliation batch mints exactly once" do
      sha = String.duplicate("a", 40)

      expect_mint(:change_request_write)

      # 1. GET base ref
      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"object" => %{"sha" => sha}})
      end)

      # 2. GET head ref -> absent
      Req.Test.expect(@stub_name, fn conn ->
        Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
      end)

      # 3. GET base commit -> tree sha
      Req.Test.expect(@stub_name, fn conn ->
        Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
      end)

      # 4. POST blob
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
      end)

      # 5. POST tree
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
      end)

      # 6. POST commit
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
      end)

      # 7. POST create ref (new -- not PATCH)
      Req.Test.expect(@stub_name, fn conn ->
        conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
      end)

      # 8. GET pulls search -> no existing match
      Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

      # 9. POST pulls create
      Req.Test.expect(@stub_name, fn conn ->
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "number" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => sha},
          "base" => %{"ref" => "main"},
          "merged" => false
        })
      end)

      # 2 mint calls + 9 reconciliation calls, in this exact order -- if the
      # implementation re-minted per HTTP request instead of once per
      # callback, this ordered Req.Test.expect queue would desync and fail.
      assert {:ok, %ChangeRequest{external_id: "42"}} =
               GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
    end
```

Replace the standalone `"create_change_request returns ChangeRequest on 201"`
test with a version that also proves the `base_tree` fix and the PR search
query shape (folding what would otherwise be two more near-duplicate
full-sequence tests into this one):

```elixir
  test "create_change_request returns ChangeRequest on 201, using the base commit's tree sha and an exact head+base+open PR search" do
    test_pid = self()
    base_commit_sha = String.duplicate("a", 40)
    base_tree_sha = String.duplicate("t", 40)
    expect_mint(:change_request_write)

    # Step 1: GET base ref
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => base_commit_sha}})
    end)

    # Step 2: GET head ref -> absent
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))
    end)

    # Step 3: GET base commit -> tree sha (proves the base_tree fix: this
    # call must happen, and its tree.sha -- NOT the base ref's commit sha --
    # must be what step 5 sends as base_tree)
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/commits/#{base_commit_sha}"
      Req.Test.json(conn, %{"sha" => base_commit_sha, "tree" => %{"sha" => base_tree_sha}, "parents" => []})
    end)

    # Step 4: POST blob
    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    # Step 5: POST tree -- capture body
    Req.Test.expect(@stub_name, fn conn ->
      {body, conn} = read_json_body(conn)
      send(test_pid, {:tree_request_body, body})
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    # Step 6: POST commit
    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
    end)

    # Step 7: POST create ref
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/refs"
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    # Step 8: GET pulls search -- capture query params, return no matches
    Req.Test.expect(@stub_name, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:pr_search_params, conn.query_params})
      Req.Test.json(conn, [])
    end)

    # Step 9: POST pulls create
    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => "commit_sha_1"},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    assert_received {:tree_request_body, tree_body}
    assert tree_body["base_tree"] == base_tree_sha
    refute tree_body["base_tree"] == base_commit_sha

    assert_received {:pr_search_params, params}
    assert params == %{"head" => "owner:feature-branch", "base" => "main", "state" => "open"}
  end
```

Replace `"create_change_request with empty file_changes skips git data"` with
two tests reflecting the corrected semantics:

```elixir
  test "create_change_request returns invalid_file_change when the head ref is absent and there are no file changes" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"})) end)

    assert {:error, :invalid_file_change} =
             GitHubAdapter.create_change_request(ctx(), repo(), [], create_request())
  end

  test "create_change_request with empty file_changes reconciles an already-existing safe head ref straight to the PR search" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("h", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => head_sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => head_sha, "tree" => %{"sha" => "tree_x"}, "parents" => [%{"sha" => sha}]})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => head_sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42"}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [], create_request())
  end
```

Leave `"create_change_request returns base_sha_mismatch when SHA doesn't match"`
and `"create_change_request maps 404 on ref to base_ref_not_found"` exactly
as they are today — both fail at the base-ref-verification step, before any
of this task's new logic runs, so their sequences are unaffected.

- [ ] **Step 2: Run the new/changed tests to confirm they fail**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_test.exs`

Expected: FAIL — the rewritten tests expect a `GET .../git/ref/heads/feature-branch`
(head-ref check), a `GET .../git/commits/{base_sha}` (tree-sha fetch), and a
`POST .../git/refs` (ref creation) that the current implementation never
calls, and a `GET .../pulls?...` (PR search) before the `POST .../pulls`. The
current code's `Req.Test.expect` queue will desync against these new
sequences (fewer/different actual calls than registered), producing
"unexpected request" or response-shape-mismatch failures. The two `invalid_file_change`/reconcile-empty tests fail because
the current code has no ref-existence branch at all.

- [ ] **Step 3: Replace `create_change_request/4` and its helpers**

In `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex`,
replace the block from `@impl true` above `create_change_request/4` (current
line 42) through the end of `create_pr/3` (current line 195) — i.e. delete
`create_change_request/4`, `verify_base_sha/2`,
`create_change_request_with_files/5`, `create_blobs/3`, `create_tree/5`,
`create_commit/4`, `update_head_ref/4`, `create_pr/3` — with:

```elixir
  @impl true
  def create_change_request(
        _ctx,
        %RepositoryRef{} = repo,
        file_changes,
        %CreateChangeRequest{} = create_req
      ) do
    case installation_token(repo, :change_request_write) do
      {:ok, token} ->
        with {:ok, base_sha} <- verify_base_ref(repo, create_req, token),
             {:ok, _head_sha} <-
               reconcile_head_ref(repo, file_changes, create_req, base_sha, token) do
          reconcile_pull_request(repo, create_req, token)
        end

      {:error, reason} ->
        {:error, map_read_error(reason)}
    end
  end

  # ── Step 1: base ref verification ───────────────────────────────────────

  defp verify_base_ref(repo, create_req, token) do
    base_ref_path = "/repos/#{repo.external_id}/git/ref/heads/#{repo.base_ref}"

    case GitHubClient.get(base_ref_path, token, request_opts()) do
      {:ok, ref_data} -> verify_base_sha(ref_data, create_req.expected_base_sha)
      {:error, :repository_not_found} -> {:error, :base_ref_not_found}
      {:error, reason} -> {:error, map_read_error(reason)}
    end
  end

  defp verify_base_sha(%{"object" => %{"sha" => sha}}, %CommitSha{value: expected}) do
    if sha == expected, do: {:ok, expected}, else: {:error, :base_sha_mismatch}
  end

  defp verify_base_sha(_ref_data, _expected_sha), do: {:error, :base_sha_mismatch}

  # ── Step 2: deterministic head ref create-or-reconcile (design §6.1 steps 3-6) ──
  #
  # The deterministic ref is the remote mutation identity (design §6.2): if it
  # already exists, this V1 either reuses it (parent matches the verified
  # base) or fails closed (:head_ref_conflict) -- it never moves it. There is
  # no PATCH/force-push path anywhere in this module.

  defp reconcile_head_ref(repo, file_changes, create_req, base_sha, token) do
    head_ref_path = "/repos/#{repo.external_id}/git/ref/heads/#{create_req.head_ref}"

    case GitHubClient.get(head_ref_path, token, request_opts()) do
      {:ok, head_ref_data} ->
        verify_existing_head(repo, head_ref_data, base_sha, token)

      {:error, :repository_not_found} ->
        create_head_commit(repo, file_changes, create_req, base_sha, token)

      {:error, reason} ->
        {:error, map_git_data_error(reason)}
    end
  end

  # Existing ref found -- verify it descends directly from expected_base_sha
  # before reusing it. This checks the commit's sole parent only (not its
  # tree): the caller-supplied file_changes for a given deterministic
  # head_ref are assumed content-stable across retries (the workflow layer
  # enforces this via its own input-digest check, design §5.1) -- this
  # adapter has no run/generation identity to independently re-derive that
  # guarantee, so parent-matches-base is the strongest check it can perform
  # without recomputing (and thereby re-uploading) blob/tree content on every
  # retry.
  defp verify_existing_head(repo, %{"object" => %{"sha" => head_sha}}, base_sha, token)
       when is_binary(head_sha) do
    commit_path = "/repos/#{repo.external_id}/git/commits/#{head_sha}"

    case GitHubClient.get(commit_path, token, request_opts()) do
      {:ok, %{"parents" => [%{"sha" => ^base_sha}]}} -> {:ok, head_sha}
      {:ok, _mismatched_or_unexpected_shape} -> {:error, :head_ref_conflict}
      {:error, reason} -> {:error, map_git_data_error(reason)}
    end
  end

  defp verify_existing_head(_repo, _head_ref_data, _base_sha, _token),
    do: {:error, :head_ref_conflict}

  defp create_head_commit(_repo, [], _create_req, _base_sha, _token),
    do: {:error, :invalid_file_change}

  defp create_head_commit(repo, file_changes, create_req, base_sha, token) do
    with {:ok, base_tree_sha} <- fetch_base_tree_sha(repo, base_sha, token),
         {:ok, blob_shas} <- create_blobs(repo, file_changes, token),
         {:ok, tree_sha} <- create_tree(repo, file_changes, blob_shas, base_tree_sha, token),
         {:ok, commit_sha} <- create_commit(repo, tree_sha, create_req, token),
         :ok <- create_head_ref(repo, commit_sha, create_req.head_ref, token) do
      {:ok, commit_sha}
    else
      {:error, reason} -> {:error, map_git_data_error(reason)}
    end
  end

  # Fetches the TREE sha for the verified base commit -- NOT the ref's commit
  # sha itself, which `POST git/trees`'s `base_tree` parameter documents as
  # requiring a tree object's sha, not a commit object's sha.
  defp fetch_base_tree_sha(repo, base_sha, token) do
    commit_path = "/repos/#{repo.external_id}/git/commits/#{base_sha}"

    case GitHubClient.get(commit_path, token, request_opts()) do
      {:ok, %{"tree" => %{"sha" => tree_sha}}} -> {:ok, tree_sha}
      {:ok, _unexpected_shape} -> {:error, :provider_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_blobs(repo, file_changes, token) do
    Enum.reduce_while(file_changes, {:ok, []}, fn %FileChange{content: content}, {:ok, acc} ->
      path = "/repos/#{repo.external_id}/git/blobs"

      case GitHubClient.post(
             path,
             token,
             %{content: content, encoding: "utf-8"},
             request_opts()
           ) do
        {:ok, %{"sha" => sha}} ->
          {:cont, {:ok, acc ++ [sha]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp create_tree(repo, file_changes, blob_shas, base_tree_sha, token) do
    tree_entries =
      Enum.zip(file_changes, blob_shas)
      |> Enum.map(fn {%FileChange{path: path}, sha} ->
        %{path: path, mode: "100644", type: "blob", sha: sha}
      end)

    path = "/repos/#{repo.external_id}/git/trees"

    case GitHubClient.post(
           path,
           token,
           %{base_tree: base_tree_sha, tree: tree_entries},
           request_opts()
         ) do
      {:ok, %{"sha" => sha}} ->
        {:ok, sha}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_commit(repo, tree_sha, create_req, token) do
    path = "/repos/#{repo.external_id}/git/commits"

    body = %{
      message: create_req.title,
      tree: tree_sha,
      parents: [create_req.expected_base_sha.value]
    }

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, %{"sha" => sha}} ->
        {:ok, sha}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Creates the deterministic ref for the FIRST time -- POST (not PATCH):
  # `reconcile_head_ref/5` only reaches this function when the ref is
  # confirmed absent. An already-present ref is either reused as-is
  # (`verify_existing_head/4`) or rejected as `:head_ref_conflict` -- there is
  # no third path that mutates an existing ref.
  defp create_head_ref(repo, commit_sha, head_ref, token) do
    path = "/repos/#{repo.external_id}/git/refs"
    body = %{ref: "refs/heads/#{head_ref}", sha: commit_sha}

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, _data} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Step 3: PR exact find-or-create (design §6.1 steps 7-8, §6.2) ───────
  #
  # Exact head+base is the PR reconciliation identity -- title/body are never
  # used to find a match. `state: "open"` matches design §6.1 step 7's "查询
  # exact head+base 的 open PR" literally: a closed/merged PR with the same
  # head+base does not block creating a new one.

  defp reconcile_pull_request(repo, create_req, token) do
    path = "/repos/#{repo.external_id}/pulls"

    query = [
      head: "#{repo.owner_path}:#{create_req.head_ref}",
      base: repo.base_ref,
      state: "open"
    ]

    case GitHubClient.get(path, token, Keyword.merge(request_opts(), params: query)) do
      {:ok, []} -> create_pr(repo, create_req, token)
      {:ok, [single]} when is_map(single) -> build_change_request(single)
      {:ok, [_, _ | _]} -> {:error, :change_request_conflict}
      {:ok, _unexpected} -> {:error, :provider_unavailable}
      {:error, reason} -> {:error, map_read_error(reason)}
    end
  end

  defp create_pr(repo, create_req, token) do
    path = "/repos/#{repo.external_id}/pulls"

    body = %{
      title: create_req.title,
      head: create_req.head_ref,
      base: repo.base_ref,
      body: create_req.body
    }

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, data} ->
        build_change_request(data)

      {:error, reason} ->
        {:error, map_write_error(reason)}
    end
  end
```

Leave everything else in the file — `resolve_repository/2`,
`read_change_request/3`, `list_checks/3`, `list_reviews/3`, all the
`build_*`/`map_*` value mappers, `installation_token/2`, `request_opts/0` —
unchanged.

- [ ] **Step 4: Run the changed tests to confirm they pass**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_test.exs`
Expected: FAIL still, on `"create_change_request maps 422 to change_request_conflict"`
and `"create_change_request maps 403 to repository_write_denied"` — Step 5
below rewrites those two. Everything else should now pass.

- [ ] **Step 5: Rewrite the two remaining sequence-dependent tests**

Replace `"create_change_request maps 422 to change_request_conflict"`:

```elixir
  test "create_change_request maps 422 to change_request_conflict" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"})) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    # Step 9: POST pulls fails with 422
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 422, ~s({"message": "Validation error"}))
    end)

    assert {:error, :change_request_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end
```

Replace `"create_change_request maps 403 to repository_write_denied"`:

```elixir
  test "create_change_request maps 403 to repository_write_denied" do
    sha = String.duplicate("a", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"})) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commit_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    # Step 9: POST pulls fails with 403
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 403, ~s({"message": "Forbidden"}))
    end)

    assert {:error, :repository_write_denied} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end
```

- [ ] **Step 6: Run all changed tests to confirm they pass**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_test.exs`
Expected: PASS (every test in the file).

- [ ] **Step 7: Write the failing tests for the reconciliation branches that had no prior coverage at all**

Add these after the tests above, before the `# ── read_change_request ──`
section comment in the same file:

```elixir
  # ── create_change_request: ref + PR reconciliation ────────────────────

  test "create_change_request reconciles an existing safely-provenanced head ref without recreating git data" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("h", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)

    # head ref already exists
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"object" => %{"sha" => head_sha}})
    end)

    # existing head commit's sole parent is exactly the verified base sha ->
    # safe to reuse
    Req.Test.expect(@stub_name, fn conn ->
      assert conn.request_path == "/repos/owner/repo/git/commits/#{head_sha}"
      Req.Test.json(conn, %{"sha" => head_sha, "tree" => %{"sha" => "tree_x"}, "parents" => [%{"sha" => sha}]})
    end)

    # no blob/tree/commit/ref-create calls -- straight to the PR search
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => head_sha},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42"}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request reconciles an existing head ref and an existing open PR with zero write calls" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("h", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => head_sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => head_sha, "tree" => %{"sha" => "tree_x"}, "parents" => [%{"sha" => sha}]})
    end)

    # exactly one open PR already matches head+base -- reconcile, do not create
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, [
        %{
          "number" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => head_sha},
          "base" => %{"ref" => "main"},
          "merged" => false
        }
      ])
    end)

    # No further Req.Test.expect entries are registered: any additional HTTP
    # call (a stray POST to blobs/trees/commits/refs/pulls) exhausts the
    # queue and raises, failing this test.
    assert {:ok, %ChangeRequest{external_id: "42", head_sha: ^head_sha, state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request returns head_ref_conflict when the existing head's parent does not match the expected base" do
    sha = String.duplicate("a", 40)
    other_sha = String.duplicate("z", 40)
    head_sha = String.duplicate("h", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => head_sha}}) end)

    # existing head's parent is a DIFFERENT commit than our verified base
    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => head_sha, "tree" => %{"sha" => "tree_x"}, "parents" => [%{"sha" => other_sha}]})
    end)

    assert {:error, :head_ref_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request returns head_ref_conflict when the existing head commit has no parents" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("h", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => head_sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => head_sha, "tree" => %{"sha" => "tree_x"}, "parents" => []})
    end)

    assert {:error, :head_ref_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end

  test "create_change_request returns change_request_conflict when the PR search finds more than one open match" do
    sha = String.duplicate("a", 40)
    head_sha = String.duplicate("h", 40)
    expect_mint(:change_request_write)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => sha}}) end)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => head_sha}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => head_sha, "tree" => %{"sha" => "tree_x"}, "parents" => [%{"sha" => sha}]})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, [
        %{
          "number" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => head_sha},
          "base" => %{"ref" => "main"},
          "merged" => false
        },
        %{
          "number" => 43,
          "html_url" => "https://github.com/owner/repo/pull/43",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => head_sha},
          "base" => %{"ref" => "main"},
          "merged" => false
        }
      ])
    end)

    assert {:error, :change_request_conflict} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end
```

- [ ] **Step 8: Run it to confirm it fails**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_test.exs`
Expected: these 5 new tests FAIL against Step 3's implementation only if
Step 3 has a bug — the implementation written in Step 3 already contains this
logic, so if Step 3 was transcribed correctly these should already PASS at
this point. Run this step anyway as the explicit verification gate; if any
of these 5 fail, the bug is in Step 3's `verify_existing_head/4` or
`reconcile_pull_request/3`, not in the tests.

- [ ] **Step 9: Fix and confirm all pass**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_test.exs`
Expected: PASS (every test in the file — baseline 22 (Task 1) plus 1
(Task 2's `installation_scope_mismatch` test) minus 1 retired ("skips git
data") plus 2 replacements plus 5 new = 29 tests, but re-derive the exact
count from the actual run rather than trusting this arithmetic).

- [ ] **Step 10: Extend the no-token-leakage architecture gate to `create_change_request`**

The existing sentinel test in
`apps/ezagent_plugin_github/test/architecture/operation_scoped_credential_test.exs`
only exercises `resolve_repository/2` — the simplest callback. Add a second
sentinel test covering `create_change_request/4`, now the callback with the
most internal HTTP calls and therefore the highest-risk surface for an
accidental leak. Add after the existing
`"a successful adapter call's result does not contain the minted token"` test:

```elixir
  test "create_change_request's result never contains the minted token, across its full reconciliation chain" do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")

    Application.put_env(
      :ezagent_plugin_github,
      :private_key,
      EzagentPluginGithub.TestHelpers.test_private_key_pem()
    )

    Application.put_env(:ezagent_plugin_github, :adapter_req_opts,
      plug: {Req.Test, :ccr_operation_scoped_credential_sentinel_test}
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
    end)

    sentinel = "ghs_ccr_architecture_sentinel_value"
    sha = String.duplicate("a", 40)

    Req.Test.stub(:ccr_operation_scoped_credential_sentinel_test, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/owner/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 123})

        {"POST", "/app/installations/123/access_tokens"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "token" => sentinel,
            "expires_at" => DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601(),
            "repository_selection" => "selected",
            "repositories" => [%{"full_name" => "owner/repo"}],
            "permissions" => EzagentPluginGithub.InstallationPermissions.for!(:change_request_write)
          })

        {"GET", "/repos/owner/repo/git/ref/heads/main"} ->
          Req.Test.json(conn, %{"object" => %{"sha" => sha}})

        {"GET", "/repos/owner/repo/git/ref/heads/feature-branch"} ->
          Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"}))

        {"GET", "/repos/owner/repo/git/commits/" <> _rest} ->
          Req.Test.json(conn, %{"sha" => sha, "tree" => %{"sha" => "treesha"}, "parents" => []})

        {"POST", "/repos/owner/repo/git/blobs"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blobsha"})

        {"POST", "/repos/owner/repo/git/trees"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "treesha2"})

        {"POST", "/repos/owner/repo/git/commits"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "commitsha"})

        {"POST", "/repos/owner/repo/git/refs"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})

        {"GET", "/repos/owner/repo/pulls"} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/owner/repo/pulls"} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => 42,
            "html_url" => "https://github.com/owner/repo/pull/42",
            "state" => "open",
            "head" => %{"ref" => "feature-branch", "sha" => sha},
            "base" => %{"ref" => "main"},
            "merged" => false
          })
      end
    end)

    {:ok, repo} =
      Ezagent.DomainGit.RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "owner-repo"),
        provider_adapter: GitHubAdapter,
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public
      })

    workspace = "test-ws"
    hash = Base.encode16(:crypto.hash(:sha256, "ccr-arch-sentinel"), case: :lower)

    {:ok, ctx} =
      Ezagent.DomainGit.OperationContext.new(%{
        task_access_uri: Ezagent.URI.worker(workspace, "gta_#{hash}"),
        caller_uri: Ezagent.URI.entity(workspace, "agent", "caller"),
        grantee_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        idempotency_key: "ccr-arch-sentinel-idem-1"
      })

    {:ok, base_sha_struct} = Ezagent.DomainGit.CommitSha.new(%{value: sha})

    {:ok, create_req} =
      Ezagent.DomainGit.CreateChangeRequest.new(%{
        title: "Sentinel PR",
        body: "body",
        head_ref: "feature-branch",
        expected_base_sha: base_sha_struct
      })

    {:ok, file_change} =
      Ezagent.DomainGit.FileChange.new(%{path: "README.md", operation: :upsert, content: "x"})

    result = GitHubAdapter.create_change_request(ctx, repo, [file_change], create_req)

    refute inspect(result) =~ sentinel,
           "the minted token must never appear in create_change_request's result"
  end
```

- [ ] **Step 11: Run it to confirm it fails, then passes**

Run: `cd apps/ezagent_plugin_github && mix test test/architecture/operation_scoped_credential_test.exs`

This test cannot meaningfully "fail then pass" through a TDD red step the
way a behavior test can — a genuine token leak would be a bug in Step 3's
code, which has already been written. Run it to confirm it PASSES as
written; if it fails, the leak is real and must be fixed in
`github_adapter.ex`, not worked around in the test.

Expected: PASS.

- [ ] **Step 12: Confirm the workspace-locality gate is unaffected**

The new helpers all call `GitHubClient`, `Enum`, `Plug.Conn` through literal
module aliases — no variable ever holds a module value that is then called.
Confirm this holds:

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Expected: PASS, including
`"legacy dynamic receiver baseline is exact and changed-line ratcheted"` —
if that test fails, this task's new code introduced a variable-receiver call
site; find it (the assertion failure names the file/line) and rewrite it to
call the target module directly instead of through a variable.

- [ ] **Step 13: Check the file's size is still reasonable**

```bash
wc -l apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex
```

Expected: roughly 460-480 lines (was 395; net addition after removing
`create_change_request_with_files/5` and `update_head_ref/4` and adding 8 new
helper functions plus the wider `create_change_request/4` and doc comments).
`ezagent_plugin_github` has no CLAUDE.md-mandated LOC red line (that budget
is specific to `ezagent_core`, ARCHITECTURE.md §14) — this is a hygiene
check, not a hard gate. If it is dramatically larger than expected, re-check
Step 3 was transcribed without duplication.

- [ ] **Step 14: Format and run both verification commands**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
mix format apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex \
  apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs \
  apps/ezagent_plugin_github/test/architecture/operation_scoped_credential_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix test apps/ezagent_plugin_github apps/ezagent_domain_git
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ci.fast
```

Expected: both exit 0. Use `timeout: 300000` for the `ci.fast` call.

- [ ] **Step 15: Commit**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
git add apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex \
        apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_test.exs \
        apps/ezagent_plugin_github/test/architecture/operation_scoped_credential_test.exs
git commit -m "feat(git-provider): create-or-reconcile for GitHub ref/commit/PR, fix base_tree bug"
```

---

### Task 4: Crash-window `Req.Test` coverage (design §6.2)

The heart of this slice. Design §6.2 lists five crash windows. At the
adapter's observable boundary — a single synchronous callback, invoked again
from scratch after a crash of unknown extent — they collapse to three
distinguishable re-invocation states plus one no-op case:

| §6.2 window | Adapter-observable re-invocation state |
|---|---|
| after commit creation, before head update | ref still absent → call 2 re-derives a (differently-timestamped, harmless-orphan) commit and creates the ref for the first time |
| after head update, before PR creation | ref now exists+safe, PR absent → call 2 skips git data, creates exactly one PR |
| after PR creation succeeds, before the fact is persisted | ref exists+safe, PR exists → call 2 performs only reads |
| after facts persist, before the state CAS | same as above — the adapter cannot distinguish these two; both look like "everything already exists" on re-invocation |
| after an observation HTTP success, before the snapshot persists | `read_change_request`/`list_checks`/`list_reviews` are pure reads — trivially idempotent, but proven explicitly rather than assumed |

This task adds two two-invocation tests (covering the first four windows,
which pair up as shown) plus confirms the fifth is a genuine explicit test
(added in Task 5, since it belongs with observation coverage rather than
crash-retry coverage).

**Files:**
- Create: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`

**Interfaces:**
- Consumes: `EzagentPluginGithub.GitHubAdapter.create_change_request/4`
  (public, unchanged signature, Task 3's implementation).
- Produces: nothing new for later tasks — this is a leaf test file. Task 5
  appends one more test to this same file rather than creating another.

- [ ] **Step 1: Write the failing two-invocation test for windows 1+2**

```elixir
# apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs
defmodule EzagentPluginGithub.GitHubAdapterReconciliationTest do
  @moduledoc """
  Two-invocation crash/retry coverage for `EzagentPluginGithub.GitHubAdapter`
  (design docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §6.2). Each test calls `create_change_request/4` (or an observation
  callback) TWICE against provider state that reflects what GitHub already
  durably holds after a partial completion of call 1 -- simulating a
  workflow-level crash/restart between the two calls -- and asserts call 2
  performs no duplicate remote mutation.

  `github_adapter_test.exs` covers ONE-CALL behavior (a single invocation's
  response to a given provider state); this file covers RE-INVOCATION safety.
  """

  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.{
    ChangeRequest,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef
  }

  alias EzagentPluginGithub.{GitHubAdapter, InstallationPermissions, TestHelpers}

  @stub_name :github_adapter_reconciliation_test

  setup do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
    Application.put_env(:ezagent_plugin_github, :private_key, TestHelpers.test_private_key_pem())
    Application.put_env(:ezagent_plugin_github, :adapter_req_opts, plug: {Req.Test, @stub_name})

    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
    end)

    :ok
  end

  defp future_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp expect_mint(profile) do
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"id" => 123}) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "token" => "ghs-test-token",
        "expires_at" => future_iso(),
        "repository_selection" => "selected",
        "repositories" => [%{"full_name" => "owner/repo"}],
        "permissions" => InstallationPermissions.for!(profile)
      })
    end)
  end

  defp ctx do
    workspace = "test-ws"
    hash = Base.encode16(:crypto.hash(:sha256, "github-adapter-reconciliation"), case: :lower)

    {:ok, ctx} =
      OperationContext.new(%{
        task_access_uri: Ezagent.URI.worker(workspace, "gta_#{hash}"),
        caller_uri: Ezagent.URI.entity(workspace, "agent", "caller"),
        grantee_uri: Ezagent.URI.entity(workspace, "agent", "grantee"),
        idempotency_key: "reconcile-test-idem-1"
      })

    ctx
  end

  defp repo do
    {:ok, repo} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "owner-repo"),
        provider_adapter: EzagentPluginGithub.GitHubAdapter,
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public
      })

    repo
  end

  defp file_change do
    {:ok, fc} =
      FileChange.new(%{path: "README.md", operation: :upsert, content: "updated content"})

    fc
  end

  defp base_sha, do: String.duplicate("a", 40)
  defp head_sha, do: String.duplicate("h", 40)

  defp create_request do
    {:ok, sha} = CommitSha.new(%{value: base_sha()})

    {:ok, cr} =
      CreateChangeRequest.new(%{
        title: "Test PR",
        body: "PR body text",
        head_ref: "feature-branch",
        expected_base_sha: sha
      })

    cr
  end

  # ── Windows 1+2: "after commit creation, before head update" and "after
  #    head update, before PR creation" -- call 1 durably creates the head
  #    ref server-side but fails before/while creating the PR (simulating the
  #    workflow crashing anywhere in that span and retrying from scratch).
  #    Call 2 must reconcile the now-existing head ref without recreating any
  #    git data, then create exactly one PR. ─────────────────────────────

  test "re-invoking create_change_request after the head ref was durably created but the PR was not finds the ref and creates exactly one PR" do
    # Call 1: fresh create through ref-creation, then the PR search fails
    # transiently (simulating a crash/network failure before the PR could be
    # found-or-created). The head ref is now durably present server-side even
    # though call 1 itself returns an error.
    expect_mint(:change_request_write)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}}) end)
    Req.Test.expect(@stub_name, fn conn -> Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"})) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => base_sha(), "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => head_sha()})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    # PR search fails transiently -- call 1 returns an error, but the ref
    # above was already durably created.
    Req.Test.expect(@stub_name, fn conn ->
      Plug.Conn.resp(conn, 503, ~s({"message": "Service Unavailable"}))
    end)

    assert {:error, :provider_unavailable} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # Call 2 (the retry): the head ref now exists server-side with a parent
    # matching the verified base -- reconcile it, skip git data entirely, and
    # create exactly one PR.
    expect_mint(:change_request_write)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}}) end)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => head_sha()}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha(),
        "tree" => %{"sha" => "tree_x"},
        "parents" => [%{"sha" => base_sha()}]
      })
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => head_sha()},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # No further Req.Test.expect entries are registered for either call: had
    # the implementation attempted to recreate the ref (a second POST
    # /git/refs) or blindly re-POST the PR without searching first, the
    # exhausted ordered-expect queue would raise instead of these two calls
    # completing cleanly.
  end
end
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`
Expected: FAIL if this test file did not exist before this step —
`module EzagentPluginGithub.GitHubAdapterReconciliationTest is not available`
before the file exists; once the file above is saved, this test should
already PASS immediately, because Task 3's implementation already contains
the reconciliation logic it exercises. Confirm it fails ONLY if the file
does not yet exist (expected — the point of this red step is to prove the
file/test is wired up before relying on it), not because the underlying
logic is missing (Task 3 already shipped that).

- [ ] **Step 3: Run it to confirm it passes**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`
Expected: PASS. If it fails, the bug is in Task 3's `reconcile_head_ref/5`
or `reconcile_pull_request/3` — do not weaken this test to accommodate
incorrect reconciliation behavior.

- [ ] **Step 4: Write the failing two-invocation test for windows 3+4**

Add to the same file, after the test above:

```elixir
  # ── Windows 3+4: "after PR creation succeeds, before the workflow fact is
  #    persisted" and "after facts persist, before the state CAS" -- call 1
  #    fully succeeds (ref + PR both created). Call 2 (the workflow retrying
  #    because it crashed before durably recording call 1's success) must
  #    fresh-read the existing ref and PR and make ZERO write calls. These
  #    two design windows are indistinguishable at the adapter's observable
  #    boundary -- both present as "everything already exists" on
  #    re-invocation -- so one test covers both. ──────────────────────────

  test "re-invoking create_change_request after both the head ref and the PR already exist performs only reads" do
    # Call 1: full fresh create, succeeds completely.
    expect_mint(:change_request_write)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}}) end)
    Req.Test.expect(@stub_name, fn conn -> Plug.Conn.resp(conn, 404, ~s({"message": "Not Found"})) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{"sha" => base_sha(), "tree" => %{"sha" => "tree_base"}, "parents" => []})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "blob_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => "tree_sha_1"})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"sha" => head_sha()})
    end)

    Req.Test.expect(@stub_name, fn conn ->
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"ref" => "refs/heads/feature-branch"})
    end)

    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, []) end)

    Req.Test.expect(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(201)
      |> Req.Test.json(%{
        "number" => 42,
        "html_url" => "https://github.com/owner/repo/pull/42",
        "state" => "open",
        "head" => %{"ref" => "feature-branch", "sha" => head_sha()},
        "base" => %{"ref" => "main"},
        "merged" => false
      })
    end)

    assert {:ok, %ChangeRequest{external_id: "42"}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())

    # Call 2 (the retry): both the ref and the PR already exist. Only GETs
    # (plus the mandatory mint POST) are registered -- any write call
    # exhausts the queue and raises.
    expect_mint(:change_request_write)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => base_sha()}}) end)
    Req.Test.expect(@stub_name, fn conn -> Req.Test.json(conn, %{"object" => %{"sha" => head_sha()}}) end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, %{
        "sha" => head_sha(),
        "tree" => %{"sha" => "tree_x"},
        "parents" => [%{"sha" => base_sha()}]
      })
    end)

    Req.Test.expect(@stub_name, fn conn ->
      Req.Test.json(conn, [
        %{
          "number" => 42,
          "html_url" => "https://github.com/owner/repo/pull/42",
          "state" => "open",
          "head" => %{"ref" => "feature-branch", "sha" => head_sha()},
          "base" => %{"ref" => "main"},
          "merged" => false
        }
      ])
    end)

    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} =
             GitHubAdapter.create_change_request(ctx(), repo(), [file_change()], create_request())
  end
```

- [ ] **Step 5: Run it to confirm it fails, then passes**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`
Expected: same as Step 2/3 above — PASS once saved, since Task 3's logic
already implements this. If it fails, the bug is in Task 3's code.

- [ ] **Step 6: Format and run both verification commands**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
mix format apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix test apps/ezagent_plugin_github apps/ezagent_domain_git
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ci.fast
```

Expected: both exit 0. Use `timeout: 300000` for the `ci.fast` call.

- [ ] **Step 7: Commit**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
git add apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs
git commit -m "test(git-provider): two-invocation crash-window coverage for GitHub ref/PR reconciliation"
```

---

### Task 5: Observation idempotency (window 5) + moduledoc consistency + closing checks

**Files:**
- Modify: `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`
  (add one test)
- Modify: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex:1-14`
  (moduledoc update)

**Interfaces:**
- Consumes: `EzagentPluginGithub.GitHubAdapter.read_change_request/3,list_checks/3,list_reviews/3`
  (public, unchanged signatures).
- Produces: nothing further — this is the closing task of the slice.

- [ ] **Step 1: Write the failing observation-idempotency test**

Add to `apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`,
after the two tests from Task 4 (add `ChangeRequestId` to the existing
`alias Ezagent.DomainGit.{...}` list at the top of the file — the test below
matches on `{:ok, []}`/`{:ok, %ChangeRequest{...}}` directly, so `Check` and
`Review` are not needed — and add `change_request_id/0` and `commit_sha/0`
fixture helpers alongside the existing `base_sha/0`/`head_sha/0`):

First, update the module's alias line:

```elixir
  alias Ezagent.DomainGit.{
    ChangeRequest,
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef
  }
```

Add these two fixture helpers next to `base_sha/0`/`head_sha/0`:

```elixir
  defp change_request_id do
    {:ok, id} = ChangeRequestId.new(%{external_id: "42"})
    id
  end

  defp commit_sha do
    {:ok, sha} = CommitSha.new(%{value: base_sha()})
    sha
  end
```

Then add the test itself:

```elixir
  # ── Window 5: "after an observation HTTP success, before the snapshot
  #    persists" -- read_change_request/list_checks/list_reviews are pure
  #    reads with nothing to duplicate. Proven explicitly rather than assumed:
  #    the stub below flunks on any non-GET, non-mint request, so an
  #    accidental write anywhere in these three callbacks fails this test. ──

  test "observation callbacks are pure reads -- repeated calls make zero mutating requests and return consistent facts" do
    sha = base_sha()

    Req.Test.stub(@stub_name, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/repos/owner/repo/installation"} ->
          Req.Test.json(conn, %{"id" => 123})

        {"POST", "/app/installations/123/access_tokens"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          {:ok, decoded} = Jason.decode(body)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "token" => "ghs-test-token",
            "expires_at" => future_iso(),
            "repository_selection" => "selected",
            "repositories" => [%{"full_name" => "owner/repo"}],
            "permissions" => decoded["permissions"]
          })

        {"GET", "/repos/owner/repo/pulls/42"} ->
          Req.Test.json(conn, %{
            "number" => 42,
            "html_url" => "https://github.com/owner/repo/pull/42",
            "state" => "open",
            "head" => %{"ref" => "feature-branch", "sha" => sha},
            "base" => %{"ref" => "main"},
            "merged" => false
          })

        {"GET", "/repos/owner/repo/commits/" <> _rest} ->
          Req.Test.json(conn, %{"total_count" => 0, "check_runs" => []})

        {"GET", "/repos/owner/repo/pulls/42/reviews"} ->
          Req.Test.json(conn, [])

        {method, path} ->
          flunk("observation must be read-only; got #{method} #{path}")
      end
    end)

    read_1 = GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
    read_2 = GitHubAdapter.read_change_request(ctx(), repo(), change_request_id())
    assert {:ok, %ChangeRequest{external_id: "42", state: :open}} = read_1
    assert read_1 == read_2

    checks_1 = GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
    checks_2 = GitHubAdapter.list_checks(ctx(), repo(), commit_sha())
    assert {:ok, []} = checks_1
    assert checks_1 == checks_2

    reviews_1 = GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
    reviews_2 = GitHubAdapter.list_reviews(ctx(), repo(), change_request_id())
    assert {:ok, []} = reviews_1
    assert reviews_1 == reviews_2
  end
```

Note the mint stub in this test echoes back whatever `permissions` were
requested (decoding the request body) rather than hard-coding one profile —
`read_change_request`/`list_reviews` request `:change_request_read` while
`list_checks` requests `:checks_read`, and `GitHubInstallation`'s strict
scope validation requires the response's `permissions` to exactly equal what
was requested, so a single fixed value cannot satisfy all three calls in one
stub.

- [ ] **Step 2: Run it to confirm it fails**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`
Expected: FAIL only if `change_request_id/0`/`commit_sha/0` are missing or
misspelled, or if the alias list wasn't updated (compile error citing the
undefined function/module). Once those are in place, this test exercises
only already-correct, unchanged code (`read_change_request/3`,
`list_checks/3`, `list_reviews/3` are untouched by this whole plan) and
should PASS immediately — this red step is about proving the test
compiles and is wired to real fixtures, not about driving new production
code.

- [ ] **Step 3: Run it to confirm it passes**

Run: `cd apps/ezagent_plugin_github && mix test test/ezagent_plugin_github/github_adapter_reconciliation_test.exs`
Expected: PASS (3 tests total in this file now).

- [ ] **Step 4: Update `github_adapter.ex`'s moduledoc for prose/behavior consistency**

The current moduledoc (lines 1-14) only describes token minting; it makes no
mention of create-or-reconcile, which after Task 3 is the module's central
contract. Replace lines 1-14:

```elixir
defmodule EzagentPluginGithub.GitHubAdapter do
  @moduledoc """
  Maps Git domain operations to the GitHub REST API (v3).

  Each callback accepts `Ezagent.DomainGit` value types, calls the GitHub REST
  API via `GitHubClient`, and maps provider responses back to Domain Git structs.

  Repository operations authenticate with a GitHub App **operation-scoped
  installation access token** — minted fresh per callback via
  `EzagentPluginGithub.GitHubInstallation` for exactly that callback's closed
  permission profile (statically selected here, never from `ctx`, action args,
  prompt, or card) and discarded when the callback returns; there is no shared
  cache. Every callback fails closed if the token cannot be minted or scoped.

  ## Reconciliation

  `create_change_request/4` is create-or-reconcile, not create-only (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §6.1-§6.2): re-invoking it with the same repo/head_ref/expected_base_sha
  after any crash never duplicates a remote mutation.

    * The deterministic head ref is the mutation identity. If it does not
      exist, a fresh blob/tree/commit chain is built and the ref is created
      (`POST git/refs`) for the first time. If it already exists, it is
      reused when its sole parent commit is exactly the verified base sha —
      otherwise the callback fails closed with `:head_ref_conflict`. There is
      no PATCH/force-push path: an existing ref is never moved.
    * The PR's head+base pair (never its title or body) is the reconciliation
      identity: an exact, open, head+base search runs before any PR is
      created. Zero matches creates one; exactly one match is normalized and
      returned; more than one match fails closed with
      `:change_request_conflict`.
    * `resolve_repository/2`, `read_change_request/3`, `list_checks/3`, and
      `list_reviews/3` are pure reads and need no reconciliation logic — a
      repeated read cannot duplicate a mutation.
  """
```

- [ ] **Step 5: Run the full app test suite once more**

Run: `cd apps/ezagent_plugin_github && mix test`
Expected: PASS, all tests in the app (moduledoc-only change, no behavior
change possible from this step).

- [ ] **Step 6: Grep-verify no dynamic module dispatch was introduced anywhere in this slice's changes**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
git diff --stat main -- apps/ezagent_plugin_github apps/ezagent_domain_git
grep -n "^\s*[a-z_]* = .*\n.*\1\." apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex || true
```

The `grep` above is a quick human sanity spot-check, not the actual gate —
the actual gate is the `plugin_workspace_locality_contract_test.exs` run in
Step 7 below, which does a real AST scan rather than a line-oriented regex.
Read the `git diff --stat` output and confirm only the files this plan lists
changed.

- [ ] **Step 7: Full closing verification for the slice**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
mix format apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex \
  apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix test apps/ezagent_plugin_github apps/ezagent_domain_git
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ci.fast
```

Expected: both exit 0. Use `timeout: 300000` for `ci.fast`.

- [ ] **Step 8: Commit**

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
git add apps/ezagent_plugin_github/test/ezagent_plugin_github/github_adapter_reconciliation_test.exs \
        apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex
git commit -m "test(git-provider): observation idempotency coverage + reconciliation moduledoc"
```

---

## Closing verification (run once, after Task 5)

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix ci.fast
```

Pass `timeout: 300000` if invoked through a tool defaulting to 120s.

Then the full gate before considering the slice done:

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-provider-v1-plan-e-p3-github-reconcile
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix precommit
```

Pass `timeout: 600000` (this is the slow full-suite gate, 500s+ per the
project's own documentation of it). Both must finish (not be killed by a
timeout) and exit 0. A killed run is not a pass — rerun with a longer
explicit timeout instead of reporting success.

Also re-run, standalone, as an explicit final confirmation of the specific
risk this plan called out repeatedly:

```bash
MIX_ENV=test POSTGRES_PORT=15432 MIX_TEST_PARTITION=p3 mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Expected: PASS, with `ezagent_plugin_github` still contributing zero entries
to that gate's legacy-dynamic-receiver baseline or ownership allowlist.

## What this slice does not do (do not claim these are done)

Per design §10-§11, this slice does not touch: the workflow's durable state
machine or authorization seam (P1, already merged), workspace change
collection (P2), the vertical runner/observation-tick orchestration or local
end-to-end test (P4 — depends on P1+P2+P3 being integrated by the lead
first), production authorization wiring, managed-Agent canary, or the GitHub
merge loop (explicitly out of V1 per design §2.3/§4.4 — "No merge action in
V1"). This plan's Req.Test coverage proves the adapter's own reconciliation
logic is crash-safe; it does not stand in for P4's real local E2E (design
§8), which exercises a real bare repository, a real Postgres-backed workflow
store, and the full accept→authorize→workspace→changes→PR→observe chain.
