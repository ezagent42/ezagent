# Hello live E2E completion and Kanban fusion deepening implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the real DeepSeek-backed Hello live E2E proof and harden the existing Hello-to-Kanban delegation contract without implementing cross-session sharing or #1360 Layer B.

**Architecture:** Keep the existing Hello dispatcher as the only task-creation path and Kanban as the sole board data owner. Exercise the real curl-agent/DeepSeek route through the sanctioned session flow, add only the observability and regression seams required to prove generation, validation, render, PATCH, concierge read-only behavior, anonymous visibility, and the 36-component catalog. Defer cross-session sharing and bidirectional binding until the colleague-owned Kanban contract lands.

**Tech Stack:** Elixir 1.19, OTP 28, Phoenix 1.8, LiveView, Ezagent Invocation/CapBAC, React `@json-render`, Playwright/agent-browser, DeepSeek OpenAI-compatible API.

## Global Constraints

- Continue on `feat/hello-recording-ready`; do not create another branch.
- Preserve unstaged `config/dev.exs`, `apps/ezagent_plugin_world/assets/package-lock.json`, and the recording artifact unless explicitly committing the artifact.
- Use the real DeepSeek provider and model; no stub may be presented as live proof.
- Kanban owns board data and permissions; Hello must not read state slices directly or duplicate a permission model.
- Cross-session sharing, bidirectional binding, and #1360 Layer B are deferred.
- Do not edit `apps/ezagent_plugin_world/assets/src/styles.css`.
- Any World touch must remain additive and pass typed-slot/layout gates.
- Use `Req` for any Elixir HTTP work.
- Finish with `mix precommit`, relevant regression tests, current-main rebase, PR-head CI green, screenshots, transcript, and recording companion.

---

### Task 1: Establish a truthful live-DeepSeek baseline

**Files:**
- Modify if evidence requires clarification: `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/transcript.txt`
- Modify if setup instructions drifted: `docs/e2e/2026-07-14/hello-live-e2e-kanban-fusion/README.md`
- Test: `apps/ezagent_plugin_curl_agent/test/e2e/scenario_07_curl_agent_roundtrip_test.exs`

**Interfaces:**
- Consumes: the existing `hello.llm` curl recipe and credential cascade.
- Produces: verified provider reachability and a secret-free record of the actual failure boundary or successful reply.

- [ ] **Step 1: Verify the host route without printing credentials**

Load `.env` only into the command environment. Check that the key variable is non-empty by printing `SET`/`UNSET`, inspect proxy variables, and send a minimal `Req`/curl request that records only HTTP status and response error category.

- [ ] **Step 2: Run the sanctioned curl-agent live scenario**

Run:

```bash
mix test apps/ezagent_plugin_curl_agent/test/e2e/scenario_07_curl_agent_roundtrip_test.exs --include live
```

Expected: a real DeepSeek response lands through the curl-agent bridge. If it fails, capture whether the boundary is credential, proxy/TCP, provider response, or Ezagent dispatch before changing code.

- [ ] **Step 3: Compare the live path with the working direct request**

Trace environment propagation and request options through:

```text
hello Generator -> Entity.Agent.complete/3 -> curl BridgeAdapter -> ApiClient -> Req
```

Form one root-cause hypothesis and test one variable at a time. Do not add a bypass around dispatch or CapBAC.

- [ ] **Step 4: Add the smallest regression test for any discovered defect**

The failing test must exercise the broken production boundary, such as proxy option propagation or provider error decoding. Verify it fails before implementing a fix.

- [ ] **Step 5: Implement and verify the minimal fix**

Use existing configuration and `Req`; do not introduce a second HTTP client or an environment-only demo path. Re-run the focused regression and live scenario.

- [ ] **Step 6: Commit the isolated fix if code changed**

```bash
git add <focused-production-files> <focused-test-files>
git diff --cached --check
git commit -m "fix(hello): restore live DeepSeek generation path"
```

### Task 2: Lock the six-point Hello product flow in automated tests

**Files:**
- Modify: `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/spec_test.exs`
- Modify only if a production gap is proven: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex`
- Modify only if a production gap is proven: `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_concierge.ex`

**Interfaces:**
- Consumes: `Generator.generate/2`, PATCH/edit handling, `Spec.validate/1`, public Hello route, concierge dispatch.
- Produces: deterministic tests that separately prove generation validation, incremental edit, read-only concierge, anonymous visibility, and exact catalog parity.

- [ ] **Step 1: Add a failing integration assertion for revision-preserving PATCH**

Drive the first prompt to a valid Surface, record its revision/spec, drive the second edit prompt, and assert the second revision changes only through the edit path while the resulting spec still passes `Spec.validate/1`.

- [ ] **Step 2: Add a failing concierge read-only assertion**

Record Surface revision and Kanban tree, send a concierge question about current page content, assert an answer lands, then assert both revision and tree are unchanged.

- [ ] **Step 3: Assert the public short route renders anonymously**

Use `Phoenix.LiveViewTest`/controller helpers and stable DOM IDs; do not assert raw HTML strings. Confirm the anonymous caller sees the Hello renderer but cannot invoke delegation without login.

- [ ] **Step 4: Keep the 36-component contract exact**

Run and extend the existing parity test so backend `Spec.catalog/0` and frontend definitions remain the same 36-name set, and validate both generated and patched specs.

- [ ] **Step 5: Run the focused suite RED, implement only proven gaps, then GREEN**

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs \
  apps/ezagent_plugin_hello/test/ezagent_plugin_hello/spec_test.exs \
  apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs
```

Expected final result: `0 failures`.

- [ ] **Step 6: Commit the testable product-flow increment**

```bash
git add apps/ezagent_plugin_hello
git diff --cached --check
git commit -m "test(hello): lock the live generation product loop"
```

### Task 3: Harden the Hello-side Kanban delegation contract

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/kanban_delegation.ex`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_delegation_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/hello_dispatcher_dispatch_test.exs`
- Modify: `apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs`
- Modify only if contract output changes: `apps/ezagent_domain_socialware/assets/js/viewer_app.js`

**Interfaces:**
- Consumes: authenticated `delegate/3`, canonical board resolution, `kanban.add_node`, `kanban.attach_artifact`, and `kanban.get_tree` through Invocation.
- Produces: a bounded `%{kanban_uri, node_id, title, status, path}` result and explicit errors without depending on Kanban sharing work.

- [ ] **Step 1: Add failing contract-shape and authorization tests**

Assert success returns exactly the stable reference fields, source artifact points to the Hello session, ambiguous boards fail loud, unauthorized callers create no node, and UI code contains no direct Kanban mutation.

- [ ] **Step 2: Add a failing node-existence consistency test**

After delegation, dispatch `get_tree` under the authenticated caller and assert the returned `node_id`, title, status, and source artifact correspond to one real node. Repeating the login continuation must not add another node.

- [ ] **Step 3: Implement only missing contract validation**

Keep all board access through `Invocation.dispatch/1`. Normalize the returned status without inventing workflow states. Do not add sharing, polling, mirrored storage, or direct slice reads.

- [ ] **Step 4: Run Hello/Kanban focused tests and JS contract test**

```bash
mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/kanban_delegation_test.exs \
  apps/ezagent_plugin_hello/test/ezagent_plugin_hello/hello_dispatcher_dispatch_test.exs
node --test apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs
```

Expected final result: all tests pass and the JS process exits `0`.

- [ ] **Step 5: Commit the stable Hello-side contract**

```bash
git add apps/ezagent_plugin_hello apps/ezagent_domain_socialware/assets/js/viewer_app.js
git diff --cached --check
git commit -m "test(hello): pin the Kanban delegation contract"
```

### Task 4: Capture real browser evidence and pass the return gate

**Files:**
- Replace/add: `docs/e2e/2026-07-15/hello-kanban-fusion-deepen/*.png`
- Create: `docs/e2e/2026-07-15/hello-kanban-fusion-deepen/transcript.txt`
- Create: `docs/e2e/2026-07-15/hello-kanban-fusion-deepen/README.md`
- Add final recording: `docs/e2e/2026-07-15/hello-kanban-fusion-deepen/hello-live-e2e.webm`
- Create: `docs/together/2026-07-15/returns/hello-kanban-fusion-deepen.md`

**Interfaces:**
- Consumes: the live product routes, real DeepSeek result, validated Surface revisions, concierge answer, anonymous route, and Kanban delegation receipt.
- Produces: auditable screenshots, transcript, recording, and return ledger.

- [ ] **Step 1: Start the seeded app with explicit environment**

Source `.env` without echoing it, enable the Fusion demo seed, and wait for the actual health endpoint and `/hello/fusion` to return `200`.

- [ ] **Step 2: Drive the complete real browser journey**

Use agent-browser/Playwright to capture: entry, first prompt, DeepSeek-rendered page, second-prompt PATCH result, concierge answer with unchanged revision, anonymous view, delegation receipt, and matching World Kanban node.

- [ ] **Step 3: Write the secret-free transcript**

Record provider/model, timestamps, prompt texts, response identifiers safe to disclose, validation result, before/after revisions, concierge read-only checks, anonymous result, catalog count, board URI/node id, and each screenshot filename. Never record the key or one-time login token.

- [ ] **Step 4: Run focused regressions and frontend checks**

```bash
mix test apps/ezagent_plugin_hello/test \
  apps/ezagent_web/test/ezagent_web/controllers/hello_delegation_controller_test.exs \
  apps/ezagent_web/test/ezagent_web/hello_delegation_continuation_test.exs
node --test apps/ezagent_plugin_hello/assets/test/hello_delegation_surface_test.mjs
pnpm --dir apps/ezagent_plugin_hello/assets build
```

Expected: `0 failures`, Node exit `0`, and production asset build exit `0`.

- [ ] **Step 5: Run the complete project gate**

```bash
mix precommit
```

Expected: exit `0`. Fix branch-owned failures only.

- [ ] **Step 6: Commit evidence and return**

```bash
git add docs/e2e/2026-07-15/hello-kanban-fusion-deepen \
  docs/together/2026-07-15/returns/hello-kanban-fusion-deepen.md
git diff --cached --check
git commit -m "docs(hello): capture live DeepSeek Kanban proof"
```

- [ ] **Step 7: Rebase, verify, push, open the replacement PR, and monitor CI**

Protect unstaged user files, fetch and rebase on current `origin/main`, rerun the focused suite and `mix precommit`, push with `--force-with-lease` if the rebase rewrites commits, open a new PR to `main`, and wait until required PR-head checks are green.
