# Hello Live E2E and Kanban Fusion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove hello's real DeepSeek-backed live page loop and add a conversational, authenticated, idempotent hello-to-Kanban delegation path with an anonymous login continuation.

**Architecture:** Extend hello routing with a dedicated dispatcher role so concierge stays read-only. The dispatcher calls a hello-owned Kanban delegation service that resolves or creates one canonical workspace board and dispatches `kanban.add_node`; a signed, single-use Web continuation carries anonymous delegation across login without granting anonymous write authority.

**Tech Stack:** Elixir 1.19 / OTP 28, Phoenix 1.8, LiveView 1.1, Ecto/PostgreSQL, Ezagent Lifecycle/Invocation/CapBAC, React/TypeScript hello island, ExUnit/LazyHTML, agent-browser.

## Global Constraints

- Work only on `feat/hello-live-e2e-kanban-fusion`, based on current `origin/main`.
- Use `Ezagent.Invocation.dispatch/1` for cross-Kind operations; no direct Kanban slice writes.
- The new worker is a role on unified `Entity.Agent`, never a new Kind.
- Preserve #1134: concierge/public-read remains structurally read-only.
- This is loose coupling, not #1360 Layer B cross-session live mounting.
- Anonymous public view gains no Kanban write capability.
- Do not edit `apps/ezagent_plugin_world/assets/src/styles.css`.
- World changes must be additive and use existing plugin-page/typed-slot contracts.
- Use existing dependencies only; HTTP remains Req-based.
- Write every behavior change test-first and observe the intended RED before implementation.
- Preserve the user's unrelated local modifications to `config/dev.exs` and `apps/ezagent_plugin_world/assets/package-lock.json`; never stage them.

---

### Task 1: Lock the conversational intent and dispatcher role contract

**Files:**
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/prompts.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex`
- Create: `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_dispatcher.ex`
- Create: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/hello_dispatcher_dispatch_test.exs`

**Interfaces:**
- Produces: `Generator.interpret_intent/1 :: :builder | :concierge | :sharer | :publisher | :dispatcher`
- Produces: recipe `hello.dispatcher` with `Ezagent.ActionSet.HelloDispatcher`
- Produces: action `agent.delegate_to_kanban` with `%{session_uri: String.t(), text: String.t(), sender_uri: String.t()}`

- [ ] **Step 1: Add failing pure routing tests**

Add assertions that `KANBAN` maps to `:dispatcher`, non-owners remain `:concierge`, and dispatcher is part of the loop guard:

```elixir
test "KANBAN routes an owner to the dispatcher" do
  assert Generator.interpret_intent("KANBAN") == :dispatcher
end

test "a non-owner cannot reach dispatcher" do
  session = Ezagent.URI.session("system", :hello, "nonowner-kanban")
  assert Router.classify("KANBAN", false, session) == :concierge
end
```

- [ ] **Step 2: Run the focused tests and observe RED**

Run:

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs
```

Expected: failure because `KANBAN` currently falls through to `:builder` and no dispatcher role exists.

- [ ] **Step 3: Add the dispatcher recipe/action registration tests**

Assert `Application.roles/0` contains exactly one `hello.dispatcher` recipe and its requested cap names `HelloDispatcher.delegate_to_kanban`.

- [ ] **Step 4: Implement the minimal routing and role registration**

Extend the route prompt with the exact result word `KANBAN`, parse it before the builder fallback, add `dispatcher` to `@worker_roles`, map it to `:delegate_to_kanban`, and register:

```elixir
%{
  name: "hello.dispatcher",
  behaviors: [Ezagent.ActionSet.HelloDispatcher],
  requested_caps: [
    %{behavior: Ezagent.ActionSet.HelloDispatcher, action: :delegate_to_kanban}
  ]
}
```

The Lifecycle handler must delegate to `EzagentPluginHello.KanbanDelegation.start/3` and return immediately; Task 2 supplies that service.

- [ ] **Step 5: Run the focused tests GREEN**

Run the router, registration, and dispatcher tests. Expected: all pass with no new warnings.

- [ ] **Step 6: Commit Task 1**

```bash
git add apps/ezagent_plugin_hello/lib apps/ezagent_plugin_hello/test
git commit -m "feat(hello): route Kanban delegation to dispatcher role"
```

### Task 2: Implement the canonical default-Kanban delegation service

**Files:**
- Create: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_delegation.ex`
- Create: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_delegation_test.exs`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_dispatcher.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/turn_driver.ex`

**Interfaces:**
- Produces: `KanbanDelegation.start(session_uri, instruction, sender_uri) :: {:ok, pid()} | {:error, term()}`
- Produces: `KanbanDelegation.delegate(session_uri, instruction, sender_uri) :: {:ok, %{kanban_uri: URI.t(), node_id: String.t(), path: String.t()}} | {:error, term()}`
- Produces: `KanbanDelegation.resolve_default(workspace_uri, ctx) :: {:ok, URI.t()} | {:error, term()}`

- [ ] **Step 1: Write failing integration tests for resolve/create/add-node**

Cover three independent outcomes:

```elixir
test "creates a kanban-manager when the workspace has none" do
  assert {:ok, result} = KanbanDelegation.delegate(session, "Ship the homepage", admin)
  assert %URI{} = result.kanban_uri
  assert is_binary(result.node_id)
end

test "reuses the canonical board and creates exactly one node" do
  assert {:ok, first} = KanbanDelegation.delegate(session, "Task A", admin)
  assert {:ok, second} = KanbanDelegation.delegate(session, "Task B", admin)
  assert first.kanban_uri == second.kanban_uri
end

test "surfaces add_node denial and posts no success line" do
  assert {:error, :unauthorized} = KanbanDelegation.delegate(session, "Denied", outsider)
end
```

Assert the persisted node carries a source artifact/map with the hello session URI, page URL, page summary, and original instruction.

- [ ] **Step 2: Run the new test and observe RED**

Run the new file. Expected: undefined module/function.

- [ ] **Step 3: Implement workspace and page context extraction**

Use `Ezagent.URI.session_workspace_uri/1` (or the current canonical URI helper proven by source), read the current approved Surface tree, and build a bounded summary without serializing secrets or full chat history.

- [ ] **Step 4: Implement canonical board resolution**

Use `Ezagent.Agent.RecipeResolver.list_by_recipe("kanban-manager", workspace_uri)` as the durable live+dormant source. Resolution rules:

```elixir
[] -> create_default_board(...)
[board] -> {:ok, board}
many -> select the explicit canonical default name; otherwise {:error, :ambiguous_default_kanban}
```

Create through `Ezagent.Workspace.create_agent/3` with `%{flavor: "native", role: "kanban-manager", name: canonical_name, cwd: "", with_pty: false}` and the authenticated caller context.

- [ ] **Step 5: Dispatch `kanban.add_node` and attach source context**

Dispatch a root node first. After receiving `%{id: node_id}`, dispatch `kanban.attach_artifact` with a stable hello-source artifact. Return the existing World path shape:

```elixir
"/plugins/kanban/" <> URI.encode_www_form(URI.to_string(kanban_uri))
```

- [ ] **Step 6: Post explicit success/failure chat lines**

Use `TurnDriver.say_nav/4` as the dispatcher actor. Success carries `open_url`; failures name the failure without claiming a node exists.

- [ ] **Step 7: Run Task 2 tests GREEN and existing Kanban dispatch regressions**

Run the new test plus `role_native_create_test.exs`, `role_native_dispatch_test.exs`, and hello router tests.

- [ ] **Step 8: Commit Task 2**

```bash
git add apps/ezagent_plugin_hello/lib apps/ezagent_plugin_hello/test
git commit -m "feat(hello): delegate conversation work to default Kanban"
```

### Task 3: Add single-use anonymous login continuation

**Files:**
- Create: `apps/ezagent_web/lib/ezagent_web/hello_delegation_continuation.ex`
- Create: `apps/ezagent_web/lib/ezagent_web/controllers/hello_delegation_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/session_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/pat_delivery.ex`
- Create: `apps/ezagent_web/test/ezagent_web/hello_delegation_continuation_test.exs`
- Create: `apps/ezagent_web/test/ezagent_web/controllers/hello_delegation_controller_test.exs`

**Interfaces:**
- Produces: `HelloDelegationContinuation.sign(session_uri, instruction) :: String.t()`
- Produces: `HelloDelegationContinuation.verify(token) :: {:ok, %{session_uri: URI.t(), instruction: String.t(), nonce: String.t()}} | {:error, term()}`
- Produces: POST `/hello/delegate` and POST `/hello/delegate/resume`

- [ ] **Step 1: Write failing signing, tamper, expiry, and replay tests**

Use Phoenix.Token with a dedicated salt and a maximum age. Store only a digest/nonce consumption record in the session so the instruction remains signed and replay is rejected.

- [ ] **Step 2: Run continuation tests RED**

Expected: module/routes absent.

- [ ] **Step 3: Implement fail-closed token validation**

Validate that the decoded URI is a hello session, instruction is non-empty and bounded, and nonce has not been consumed. Never accept caller/workspace/caps from form parameters.

- [ ] **Step 4: Implement anonymous start endpoint**

For anonymous callers, store the signed token in session and redirect to `/login?return_to=/hello/delegate/resume`. For authenticated callers, call the same resume function immediately. This endpoint performs no Kanban write before authentication.

- [ ] **Step 5: Resume after PAT/session establishment exactly once**

After login has established `current_entity_uri`, resume validates/consumes the token, invokes `KanbanDelegation.start/3` under that principal, clears pending state, and redirects back to the hello session. Repeated resume returns an already-consumed result without creating a node.

- [ ] **Step 6: Run controller tests GREEN**

Assert anonymous POST redirects to login, signed-in POST delegates, tampered tokens fail, and two resume requests create one node.

- [ ] **Step 7: Commit Task 3**

```bash
git add apps/ezagent_web/lib apps/ezagent_web/test
git commit -m "feat(web): resume hello delegation after login"
```

### Task 4: Wire the real hello product surface without World CSS collisions

**Files:**
- Modify: `apps/ezagent_plugin_hello/assets/src/main.tsx`
- Modify: `apps/ezagent_plugin_hello/assets/src/island.css`
- Modify: `apps/ezagent_plugin_hello/assets/js/hello_renderer.js`
- Create: `apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs`
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/socialware/external_feed_controller.ex`
- Modify: `apps/ezagent_web/test/ezagent_web/socialware/external_feed_controller_test.exs`

**Interfaces:**
- Consumes: POST `/hello/delegate` from Task 3
- Produces: stable DOM IDs `#hello-prompt-form`, `#hello-delegate-login`, and `#hello-kanban-result`

- [ ] **Step 1: Write a failing frontend structure test**

Assert the hello island renders the delegation/login affordance, posts only session URI + instruction + CSRF, and contains no direct Kanban API call or World bundle import.

- [ ] **Step 2: Run the JS test RED**

Run with Node from the hello asset package. Expected: missing form/IDs.

- [ ] **Step 3: Add the minimal hello-owned UI**

Use existing hello component styling and `island.css`; do not touch World `styles.css`. Authenticated conversation remains normal chat-driven routing. Anonymous public view exposes a login-gated delegation form that preserves the typed instruction for Task 3.

- [ ] **Step 4: Add server state needed by the island**

Expose only authenticated/anonymous status, session URI, and the delegation endpoint. Keep authorization server-side.

- [ ] **Step 5: Run frontend tests, TypeScript check, and hello production build GREEN**

Run the hello JS test, `pnpm exec tsc --noEmit`, and the hello Vite build.

- [ ] **Step 6: Commit Task 4**

```bash
git add apps/ezagent_plugin_hello/assets apps/ezagent_web/lib apps/ezagent_web/test
git commit -m "feat(hello): expose login-gated Kanban delegation surface"
```

### Task 5: Build the automated product-level regression suite

**Files:**
- Create: `apps/ezagent_plugin_hello/test/integration/hello_live_e2e_kanban_fusion_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs`
- Modify: `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`
- Modify: `apps/ezagent_plugin_world/test/ezagent/world/kanban_data_test.exs`

**Interfaces:**
- Proves all non-network deterministic properties from the design DoD.

- [ ] **Step 1: Write failing route/product tests through stable DOM IDs**

Mount the real hello and World routes. Assert the hello form exists, login continuation returns to hello, and the World Kanban detail route shows the delegated node.

- [ ] **Step 2: Add deterministic generation/PATCH/concierge assertions**

Exercise the real `Spec.validate -> TurnDriver -> Surface -> ExternalFeed` path, then an edit patch, and snapshot before/after concierge to prove no Surface or Kanban mutation.

- [ ] **Step 3: Assert anonymous public visibility and the 36-component contract**

Enumerate from `Spec.catalog/0`; do not hard-code a convenient subset. Assert the live renderer registry and backend catalog have an empty parity diff and exactly the shipped contract size.

- [ ] **Step 4: Run the new suite RED, implement only missing test seams, then GREEN**

No network stub may be presented as the real DeepSeek proof; deterministic tests may inject a fake LLM only for error/shape branches and must say so in test names.

- [ ] **Step 5: Commit Task 5**

```bash
git add apps/ezagent_plugin_hello/test apps/ezagent_web/test apps/ezagent_plugin_world/test
git commit -m "test(hello): lock live Kanban fusion product path"
```

### Task 6: Run the real DeepSeek and agent-browser evidence flow

**Files:**
- Create: `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/README.md`
- Create: `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/transcript.txt`
- Create screenshots under the same directory.

**Interfaces:**
- Produces the human-readable companion and real-channel proof required by DoD.

- [ ] **Step 1: Prepare an isolated real E2E workspace/session**

Use sanctioned UI/CLI paths only. Confirm the hello curl agent has a DeepSeek credential source without printing the secret.

- [ ] **Step 2: Drive the eight hello proof points with agent-browser**

Capture greeter, real first generation, validated/rendered page, second-prompt PATCH, concierge answer, unchanged page after concierge, anonymous public view, and catalog parity evidence.

- [ ] **Step 3: Drive hello-to-Kanban**

From hello chat, delegate an instruction; capture the confirmation link and the node visible in World Kanban. Repeat through anonymous login continuation and prove one node only.

- [ ] **Step 4: Record transcript and honest boundary**

Record timestamps, session/board URIs, model/backend identity, node ID, commands/checks, and explicitly state “loose-coupled copy; #1360 Layer B not implemented.” Redact PATs, peppers, API keys, cookies, and CSRF tokens.

- [ ] **Step 5: Commit Task 6 evidence**

```bash
git add docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion
git commit -m "test(e2e): prove hello live Kanban delegation"
```

### Task 7: Full gates, review, rebase, PR, and CI closure

**Files:**
- Create: `docs/together/2026-07-14/returns/hello-live-e2e-kanban-fusion.md`

Any gate failure must first be traced to an already-listed branch-owned file.
Do not change unrelated baseline files to make a gate green.

- [ ] **Step 1: Run targeted verification**

Run all touched ExUnit files, hello frontend tests/typecheck/build, and `git diff --check`.

- [ ] **Step 2: Run complete static gates**

Run `mix ezagent.arch.scan`, `mix ezagent.doc.scan`, `mix ezagent.uri_query.scan`, `mix ezagent.check_invariants`, formatting checks, socialware conformance, and plugin checks.

- [ ] **Step 3: Run `mix precommit`**

PostgreSQL must be healthy. Fix branch-caused failures and repeat until exit 0.

- [ ] **Step 4: Perform code review without subagent delegation**

Review `git diff origin/main...HEAD` against the spec line-by-line, inspect CapBAC/data-owner boundaries, scan for secrets/debug code, and rerun any affected test after fixes.

- [ ] **Step 5: Rebase latest main and rerun verification**

Fetch `origin/main`, rebase the task branch, resolve only branch-owned conflicts, and rerun targeted tests plus `mix precommit`.

- [ ] **Step 6: Write the dev-together return**

Include returned_at/deadline status, every DoD line with proof path, world surface ownership, styles.css non-touch statement, Layer B boundary, gate outputs, and PR merge request.

- [ ] **Step 7: Push and create PR to main**

Push `feat/hello-live-e2e-kanban-fusion`, create a PR targeting `main`, and include the spec, plan, screenshots, transcript, test commands, and risk/rollback notes.

- [ ] **Step 8: Monitor PR-head CI to green**

Poll checks. For any red check, inspect logs, reproduce locally, fix with TDD, push, and repeat. Completion requires every required PR-head check green; do not report completion on pending/skipped-required checks.

### Task 8: Replace the sparse seed with a recording-ready Hello product entry

**Files:**
- Modify: `apps/ezagent_plugin_hello/priv/seed_page/body.json`
- Modify: `apps/ezagent_plugin_hello/priv/seed_page/shell.css`
- Modify: `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs`
- Modify: `apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs`

**Interfaces:**
- Produces stable product affordances `#hello-product-entry`,
  `#hello-task-cta`, and `#hello-coupling-boundary` through the existing
  catalog/render path.
- Consumes the existing `#hello-prompt-form`; no new route or mutation endpoint.

- [ ] **Step 1: Add failing product-structure assertions**

Assert the approved seed spec contains the Hello name, product description,
three capability explanations, `派个任务`, and `松耦合，非最终挂载`. Assert the
browser bundle wires the CTA to focus the existing instruction input and contains
no direct Kanban mutation.

- [ ] **Step 2: Run the focused ExUnit and JS tests RED**

Run:

```bash
mix test apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs
node --test apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs
```

Expected: missing product-entry copy/IDs and missing CTA focus behavior.

- [ ] **Step 3: Implement the catalog-valid entry spec and scoped styling**

Compose only existing catalog components. Keep cobalt + zinc tokens, responsive
spacing, high-contrast CTA, and a neutral boundary panel. Do not add catalog
components, a route, a World bundle import, or a World `styles.css` edit.

- [ ] **Step 4: Wire CTA focus without creating a second submission path**

Use one document event/data action owned by the viewer bundle to focus
`input[name="instruction"]`. Submission remains the existing `/hello/delegate`
form and authenticated dispatcher service.

- [ ] **Step 5: Run focused tests GREEN and commit**

```bash
git add apps/ezagent_plugin_hello/priv/seed_page \
  apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs \
  apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs \
  apps/ezagent_domain_socialware/assets/js/viewer_app.js
git commit -m "feat(hello): present recording-ready product entry"
```

### Task 9: Return a real delegation receipt and truthful Kanban status badge

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_delegation.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/hello_delegation_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/hello_delegation_continuation.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/socialware/chat_feed_controller.ex`
- Modify: `apps/ezagent_web/lib/ezagent_web/controllers/socialware/external_feed_controller.ex`
- Modify: `apps/ezagent_domain_socialware/assets/js/viewer_app.js`
- Modify: `apps/ezagent_web/test/ezagent_web/controllers/hello_delegation_controller_test.exs`
- Modify: `apps/ezagent_web/test/ezagent_web/hello_delegation_continuation_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_delegation_test.exs`
- Modify: `apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs`

**Interfaces:**
- Extends `KanbanDelegation.delegate/3` success with the real task title and
  Kanban status.
- Produces a bounded signed receipt containing only session URI, Kanban URI,
  node id, task title, raw status, and World path.
- Renders `#hello-kanban-result` from verified server data.

- [ ] **Step 1: Add failing status and receipt tests**

Assert a newly created node reports `unassigned`, maps to `待派`, and survives
the login return as a signed receipt. Assert tampering, expiry, and refresh do
not create a node or fabricate success.

- [ ] **Step 2: Run focused tests RED**

Expected: delegation result lacks title/status, continuation has no receipt API,
and the browser result container stays empty.

- [ ] **Step 3: Read the created node through sanctioned Kanban dispatch**

After `add_node` and artifact attachment, dispatch `get_tree`, select the returned
node id, and return its real `status`. Never read the Kanban state slice directly.

- [ ] **Step 4: Sign and expose a bounded success receipt**

Store the receipt token in the authenticated session after the asynchronous
delegation settles, or make the controller's authenticated path synchronous
within the existing dispatch budget. The returned Hello page receives only a
verified escaped payload. Receipt rendering is idempotent and performs no write.

- [ ] **Step 5: Render the closed truthful status mapping**

Map `unassigned -> 待派`, `claimed -> 已认领`, `doing -> 进行中`, and
`done -> 已完成`. Preserve unknown raw values under neutral `处理中`; do not
invent `PR 已开` or `已合并` without corresponding real model data.

- [ ] **Step 6: Run focused tests GREEN and commit**

```bash
git add apps/ezagent_plugin_hello apps/ezagent_web apps/ezagent_domain_socialware/assets/js/viewer_app.js
git commit -m "feat(hello): show real Kanban delegation receipt"
```

### Task 10: Rebuild the recording proof and close PR #1383 again

**Files:**
- Replace screenshots in `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/`
- Modify: `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/README.md`
- Modify: `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/transcript.txt`
- Modify: `docs/together/2026-07-14/returns/hello-live-e2e-kanban-fusion.md`

- [ ] **Step 1: Run targeted tests, asset build, and full `mix precommit`**

Fix only branch-owned failures. Preserve the user's dirty `config/dev.exs` and
World package lock without staging them.

- [ ] **Step 2: Start the seeded Fusion demo through the sanctioned boot path**

Use `HELLO_DEMO_SEED=1`, workspace `demo`, name `fusion`, and the current backend.
Wait for `/_health` and `/hello/fusion` to return 200.

- [ ] **Step 3: Capture recording-ready browser evidence**

Capture the product entry, filled task, login continuation, real receipt with
`待派`, and the existing World Kanban page containing the real node. Ensure CJK
text renders legibly in the evidence browser.

- [ ] **Step 4: Update evidence and return documents honestly**

State that status badges project Kanban's real four-state model and that PR/merge
event ingestion is not fabricated. Keep the Layer B boundary explicit.

- [ ] **Step 5: Commit, rebase, push, and monitor PR-head CI**

Rebase on latest `origin/main`, rerun targeted verification and `mix precommit`,
push the branch, update PR #1383, and continue until every required check is green.
