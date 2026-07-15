# Website Kanban Permission-Aware Published Read Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an author publish a Hello website that references a real Kanban board, then let a separate reception session consume that board read-only and converge repeated publications by board entity URI.

**Architecture:** Hello owns a small publication port and a content-free `PublishedBoardRef`; Kanban/Mount remains the sole source of board data, share authorization, capability minting, and durable mounts. Before #1374/#1376 land, the default adapter fails honestly with `:dependency_not_landed`; after they land, a sanctioned adapter delegates to their share/mount/read contracts and the customer surface renders only bounded authorized data.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix 1.8, Ezagent Invocation/CapBAC, socialware Manifest/Mount, React customer viewer, Phoenix.LiveViewTest, Node test runner, Playwright.

## Global Constraints

- Continue on `feat/hello-recording-ready` / PR #1425; do not create another branch.
- Preserve unstaged `config/dev.exs`, `apps/ezagent_plugin_world/assets/package-lock.json`, and the older 2026-07-14 recording.
- Kanban remains the sole owner of board state, sharing policy, and authorization.
- Hello stores only `board_uri`, source `session_uri`, a Kanban-produced receive reference, and publication metadata; never a copied tree.
- Do not read Kanban state slices directly, call `Cap.issue`, or write capability storage.
- Anonymous visitors never claim a Kanban token or receive mutation authority.
- Operation and publication remain separate explicit actions.
- Do not copy production code from unmerged #1374/#1376.
- Do not edit World `styles.css`.
- Never commit the DeepSeek key or a one-time login token.
- Finish with focused regressions, frontend checks, `mix precommit`, current-main rebase, PR-head CI green, screenshots, transcript, and a new recording.

---

### Task 1: Define the content-free Hello publication contract

**Files:**
- Create: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/published_board_ref.ex`
- Create: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_published_read.ex`
- Create: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_published_read/dependency_pending.ex`
- Create: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_published_read_test.exs`

**Interfaces:**
- Produces: `PublishedBoardRef.new/1` and `identity_key/1`.
- Produces: `KanbanPublishedRead.publish_board_read/3` and `refresh_published_board/2`.
- Default implementation returns `{:error, :dependency_not_landed}`.

- [ ] **Step 1: Write the failing value-contract test**

```elixir
attrs = %{
  board_uri: "entity://system/agent/hello-kanban",
  source_session_uri: "session://system/default/author",
  receive_ref: "/socialware/kanban/receive?token=redacted",
  revision: 2
}

assert {:ok, ref} = PublishedBoardRef.new(attrs)
assert PublishedBoardRef.identity_key(ref) ==
         {"session://system/default/author", "entity://system/agent/hello-kanban"}

assert {:error, {:forbidden_board_payload, :tree}} =
         PublishedBoardRef.new(Map.put(attrs, :tree, %{nodes: %{}}))
```

- [ ] **Step 2: Run RED**

Run:

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_published_read_test.exs
```

Expected: compilation failure because `PublishedBoardRef` does not exist.

- [ ] **Step 3: Implement the minimal immutable reference**

Create a struct with enforced `board_uri`, `source_session_uri`, `receive_ref`, and positive integer `revision`. Normalize both URIs through `Ezagent.URI.parse/1`; reject `:tree`, `:nodes`, `:tasks`, and `:statuses` keys with `{:error, {:forbidden_board_payload, key}}`.

- [ ] **Step 4: Write the failing dependency-port test**

```elixir
assert {:error, :dependency_not_landed} =
         KanbanPublishedRead.publish_board_read(author_ctx(), source_session(), board_uri())
```

- [ ] **Step 5: Implement the port and pending adapter**

```elixir
def publish_board_read(ctx, session_uri, board_uri) do
  adapter().publish_board_read(ctx, session_uri, board_uri)
end

defp adapter do
  Application.get_env(
    :ezagent_plugin_hello,
    :kanban_published_read_adapter,
    EzagentPluginHello.KanbanPublishedRead.DependencyPending
  )
end
```

The pending adapter implements both callbacks and returns `{:error, :dependency_not_landed}` without reading Kanban state.

- [ ] **Step 6: Run GREEN and commit**

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_published_read_test.exs
git add apps/ezagent_plugin_hello/lib/ezagent_plugin_hello apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_published_read_test.exs
git diff --cached --check
git commit -m "feat(hello): define published Kanban read contract"
```

### Task 2: Declare composition without copying Kanban policy

**Files:**
- Modify: `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/app_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs`
- Create: `apps/ezagent_plugin_hello/test/architecture/kanban_published_read_boundary_test.exs`

**Interfaces:**
- Produces: shipped Hello manifest `uses: ["hello", "kanban"]` with no copied Kanban roles.
- Produces: a source gate preventing direct tree reads, capability minting, and copied Kanban policy.

- [ ] **Step 1: Write the failing manifest assertion**

```elixir
assert definition.uses == ["hello", "kanban"]
refute Enum.any?(definition.roles, &(&1.role_name == "board"))
```

- [ ] **Step 2: Run RED**

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/app_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs
```

Expected: the current manifest resolves only `uses: ["hello"]`.

- [ ] **Step 3: Change the shipped manifest**

```yaml
uses:
  - hello
  - kanban
```

Do not add Kanban roles, recipes, actions, or capabilities to the Hello manifest.

- [ ] **Step 4: Add the source boundary test**

Scan `apps/ezagent_plugin_hello/lib` and reject new occurrences of `Kind.get_slice(`, `Capability.issue(`, `Cap.issue(`, `list_caps_for(`, `{:set, :tree`, and `"tree" =>`. Keep sanctioned `Invocation.dispatch/1` delegation allowed.

- [ ] **Step 5: Run GREEN and commit**

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/app_test.exs apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs apps/ezagent_plugin_hello/test/architecture/kanban_published_read_boundary_test.exs
git add apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml apps/ezagent_plugin_hello/test
git diff --cached --check
git commit -m "feat(hello): compose Kanban published reads"
```

### Task 3: Wire the landed Kanban/Mount dependency

**Precondition:** #1374 and #1376 are merged into `origin/main`, and the branch has been rebased onto that merge. Do not execute this task against their feature branches.

**Files:**
- Create: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_published_read/mount_adapter.ex`
- Modify: `apps/ezagent_domain_socialware/assets/js/viewer_app.js`
- Modify: `apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs`
- Create: `apps/ezagent_plugin_hello/test/integration/kanban_published_read_mount_test.exs`
- Modify: `apps/ezagent_web/test/ezagent_web/controllers/socialware/kanban_share_controller_test.exs`

**Interfaces:**
- Consumes: landed `Ezagent.Socialware.Mount`, `MountRow`, and sanctioned Kanban share/receive contract.
- Produces: real adapter and read-only author/reception product states.

- [ ] **Step 1: Write failing two-session integration tests**

Prove two distinct sessions, same-board repeated publication, one durable read mount, reception `get_tree` success, and reception `add_node` returning `{:error, :unauthorized}`.

- [ ] **Step 2: Run RED**

```bash
mix test apps/ezagent_plugin_hello/test/integration/kanban_published_read_mount_test.exs
```

Expected: the default adapter returns `:dependency_not_landed`.

- [ ] **Step 3: Implement the sanctioned adapter**

The adapter requests the Kanban-produced read receive reference under the author caller, constructs `PublishedBoardRef` without contents, refreshes through authorized `Invocation.dispatch(... :get_tree ...)`, and normalizes errors to the closed vocabulary. It never mints caps or touches `MountRow` outside tests.

- [ ] **Step 4: Add product states with stable IDs**

```text
#hello-publish-kanban
#hello-published-board-status
#hello-published-board-readonly
#hello-published-board-unavailable
```

The visitor renders bounded data with no mutation controls. Anonymous users never receive a direct Kanban receive-token action.

- [ ] **Step 5: Run GREEN and commit**

```bash
mix test apps/ezagent_plugin_hello/test/integration/kanban_published_read_mount_test.exs apps/ezagent_web/test/ezagent_web/controllers/socialware/kanban_share_controller_test.exs
node --test apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs
git add apps/ezagent_plugin_hello apps/ezagent_domain_socialware/assets/js/viewer_app.js apps/ezagent_web/test
git diff --cached --check
git commit -m "feat(hello): publish permission-aware Kanban reads"
```

### Task 4: Capture the real product proof and close PR #1425

**Precondition:** Task 3 is GREEN against dependencies merged into main.

**Files:**
- Create: `docs/e2e/2026-07-15/website-kanban-published-read/README.md`
- Create: `docs/e2e/2026-07-15/website-kanban-published-read/transcript.txt`
- Add: `docs/e2e/2026-07-15/website-kanban-published-read/*.png`
- Add: `docs/e2e/2026-07-15/website-kanban-published-read/website-kanban-published-read.webm`
- Modify: `docs/together/2026-07-15/returns/hello-kanban-fusion-deepen.md`

- [ ] **Step 1: Run focused regressions and frontend checks**

```bash
mix test apps/ezagent_plugin_hello/test apps/ezagent_web/test/ezagent_web/controllers/socialware/kanban_share_controller_test.exs
node --test apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs
pnpm --dir apps/ezagent_plugin_hello/assets lint
pnpm --dir apps/ezagent_plugin_hello/assets typecheck
pnpm --dir apps/ezagent_plugin_hello/assets test
pnpm --dir apps/ezagent_plugin_hello/assets build
```

- [ ] **Step 2: Push code and start PR CI**

Push the current branch. CI waiting time is the recording window requested by the user.

- [ ] **Step 3: Record the real browser journey while CI runs**

Capture Session 1 board edit, explicit website publish, Session 2 read-only receive, updated board rendering, reception write denial, and repeated publish converging on the same board URI/mount. Blur one-time tokens and never show the DeepSeek key.

- [ ] **Step 4: Commit evidence**

```bash
git add docs/e2e/2026-07-15/website-kanban-published-read docs/together/2026-07-15/returns/hello-kanban-fusion-deepen.md
git diff --cached --check
git commit -m "docs(hello): capture published Kanban read proof"
```

- [ ] **Step 5: Full gate, rebase, push, and wait**

```bash
mix precommit
git fetch origin main
git rebase origin/main
mix precommit
git push --force-with-lease origin feat/hello-recording-ready
gh pr checks 1425 --watch --interval 10
```

Expected: 0 commits behind `origin/main`, required CI green, PR mergeable, and all user-owned dirty files untouched.
