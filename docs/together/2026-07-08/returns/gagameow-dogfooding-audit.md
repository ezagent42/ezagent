# gagameow dogfooding audit return

returned_at: 2026-07-08 17:05 Asia/Taipei
deadline: 2026-07-08 EOD
deadline_status: on_time
branch: gagameow-dogfooding-audit-2026-07-08
worktree: /home/huangjiajia/ezagent/.worktrees/gagameow-dogfooding-audit-2026-07-08
base: main @ 9d61ece1f4f32bc3361b7da97bcf922e45388672
pr: https://github.com/ezagent42/ezagent/pull/1247
contributing_read_through: yes

## Scope

Audit whether "develop ezagent inside ezagent" is workable today. This is an
audit task, not a repair task. A failure with a reproducible breakpoint counts
as a valid result if the breakpoint and structural gap are recorded.

## Implementation Plan

### Track A: code change + real PR

Goal: verify an ezagent-hosted agent can modify the repository and submit a real
GitHub PR.

Planned method:

1. Start a local ezagent runtime from an isolated worktree.
2. Use the product surface to create/open a session with an orchestrator agent.
3. Ask the agent to make a deliberately tiny repository change.
4. Inspect the produced git diff from outside the product.
5. If the diff is valid, push the branch and create a PR.
6. Record PR URL, command transcript, and UI/session evidence.

Success evidence:

- PR URL.
- The branch name and commit SHA.
- Screenshot showing the work was initiated inside ezagent.
- Independent diff inspection from the worktree.

Failure evidence:

- Last successful product step.
- Exact command/UI action that failed.
- Error text or screenshot.
- Structural gap: missing runtime, missing agent capability, missing sanctioned
  CLI, missing credential, missing repository mount, or unclear product path.

### Track B: create a plugin from inside ezagent

Goal: verify ezagent can guide or execute creation of a new plugin-shaped
artifact using the repo's plugin contract.

Planned method:

1. Identify the current plugin authoring contract and minimal plugin shape.
2. In an ezagent session, ask an agent to produce a minimal audit plugin
   scaffold.
3. Validate the result against the project rules without silently wiring it into
   runtime.
4. Run narrow verification.
5. Record whether product flow can get from request to plugin-shaped output
   without manual codebase intervention.

Success evidence:

- Generated plugin files.
- `mix compile` output for the generated scaffold.
- Session screenshot showing the plugin was produced from inside ezagent.

Failure evidence:

- The blocking step and exact error.
- Whether the blocker is product UX, agent runtime, plugin contract discovery,
  or verification/tooling.

### Track C: create, publish, and install socialware from inside ezagent

Goal: verify ezagent can author a new socialware definition and install it into
a session.

Planned method:

1. Use the current socialware author flow, preferring world UI if usable.
2. Ask the orchestrator to create minimal socialware through the supported
   product path only.
3. Publish or save it using the supported product path.
4. Create/install it into a session.
5. Verify installed members/views or record where the flow stops.

Success evidence:

- Screenshot or transcript of the authored socialware.
- Screenshot or transcript of install into a session.
- Evidence that members/views materialized.

Failure evidence:

- Last successful authoring/install step.
- Exact failure text or screenshot.
- Structural gap: boot/reflow issue, world UI path gap, current-tag ambiguity,
  missing view cap, missing assets, dispatch authorization, or runtime readiness.

## Actual Execution Log

### Setup

- Created isolated worktree:
  `/home/huangjiajia/ezagent/.worktrees/gagameow-dogfooding-audit-2026-07-08`.
- Created branch: `gagameow-dogfooding-audit-2026-07-08`.
- Confirmed original branch base:
  `main @ b260b09aa66ef7a89be1481933b9cae182d88b6a`.
- Found `mise` is not available in this shell.
- Confirmed asdf toolchain is available:
  Elixir 1.18.4, Erlang/OTP 27, Mix 1.18.4.
- Ran `mix deps.get`.
- Ran `mix compile`; compile completed with exit code 0.
- Ran pre-rebase `SHELL=/bin/bash mix precommit`; precommit completed with exit
  code 0.
- Confirmed `gh` is authenticated as GitHub user `gagameow` with `repo` scope.
- Found `docker` is not available in this shell.
- Confirmed Postgres was already reachable at `127.0.0.1:55432`.
- Ran `mix ecto.create && mix ecto.migrate`; database already existed and
  pending migrations through `20260707000200` ran successfully.
- Installed asset dependencies with `pnpm install` in:
  - `apps/ezagent_plugin_world/assets`
  - `apps/ezagent_web/assets`

### Runtime and UI

- Started Phoenix runtime from this worktree with:
  `PORT=10042 WORLD_VITE_PORT=5173 mix phx.server`.
- Runtime served HTTP on port 10042 and Vite on port 5173.
- Erlang distribution failed during boot:
  `Ezagent.Runtime: net_kernel start failed ... :nodistribution`.
- `mix ezagent --help` also failed with `:cli_node_start_failed`, and
  `epmd -names` could not connect. Result: CLI/RPC path was not usable in this
  environment.
- `agent-browser` was not installed, so Playwright was used for UI operation.
- Login succeeded at `http://world.localhost:10042/login` with the local dev
  admin account.
- The world UI initially emitted Vite 504 "Outdated Optimize Dep" errors, then
  rendered after waiting.
- Browser repeatedly refused `/assets/css/local_fonts.css` because it returned
  `text/html` / 404 instead of CSS.

### Track A Result: Partial Success, Worktree Binding Gap Found

- Created plain session `dogfood-plain-1783497857566`.
- Session URI:
  `session://system/default/dogfood-plain-1783497857566`.
- Session had 2 members: `Admin` and one orchestrator agent.
- Pinged `@orchestrator`; it replied successfully.
- Asked orchestrator to create:
  `docs/together/2026-07-08/evidence/gagameow-dogfooding-audit/agent-produced-marker.md`.
- First attempt succeeded but wrote to the original main checkout:
  `/home/huangjiajia/ezagent/...`, not the active audit worktree. The agent
  reported `branch main`.
- Sent a corrective instruction with the absolute worktree path.
- Second attempt succeeded and created:
  `/home/huangjiajia/ezagent/.worktrees/gagameow-dogfooding-audit-2026-07-08/docs/together/2026-07-08/evidence/gagameow-dogfooding-audit/agent-produced-marker.md`.
- File content:
  `created from inside ezagent session dogfood-plain-1783497857566 in audit worktree`.

Conclusion:

- Product-hosted agent can make a real repository file change.
- Default repository/worktree context is unsafe for this workflow: without an
  absolute path, the agent wrote into the main checkout rather than the task
  worktree.
- PR creation was deferred until this return was completed; the final PR should
  be treated as an audit artifact, not a merge-ready product feature branch.
- Draft PR created: https://github.com/ezagent42/ezagent/pull/1247.

Evidence:

- `10-message-composed.png`
- `11-after-orchestrator-ping.png`
- `12-track-a-code-change-request.png`
- `13-track-a-corrected-worktree-request.png`
- `agent-produced-marker.md`

### Track B Result: Plugin Scaffold Produced, Runtime Wiring Gap Recorded

- Asked orchestrator to create minimal plugin app:
  `apps/ezagent_plugin_dogfood_audit`.
- It created exactly two files during the product dogfood run:
  - `apps/ezagent_plugin_dogfood_audit/mix.exs`
  - `apps/ezagent_plugin_dogfood_audit/lib/ezagent_plugin_dogfood_audit/application.ex`
- The scaffold implements `Ezagent.Plugin` with `plugin_info/0` only.
- No kinds, behaviors, children, root release changes, or existing app edits were
  made.
- Added `plugin-wire-exempt` to the scaffold `mix.exs` because this is an audit
  scratch plugin, not a runtime plugin intended to boot with `ezagent_web`.
- Pre-rebase verification:
  - `mix compile` exited 0.
  - `mix app.tree --exclude elixir --exclude logger | rg -n "dogfood|ezagent_plugin_dogfood"`
    showed `ezagent_plugin_dogfood_audit`.
  - `SHELL=/bin/bash mix test apps/ezagent_core/test/invariants/all_plugin_apps_wired_to_web_test.exs`
    exited 0 after the scratch-plugin exemption was added.
  - Pre-rebase `SHELL=/bin/bash mix precommit` exited 0.
- After rebasing onto updated main, the scratch plugin app was removed from the
  final branch. Reason: this audit branch should preserve dogfooding evidence,
  not add an inert runtime app. The generated scaffold remains documented as
  execution evidence in this return and screenshots.

Conclusion:

- Product-hosted agent can produce a minimal plugin-shaped artifact.
- Because the task explicitly said not to modify root release list or existing
  app wiring, and because this PR is an audit artifact rather than a product
  plugin PR, the scaffold is not retained as code in the final branch.

Evidence:

- `14-track-b-plugin-request.png`
- `15-track-b-stalled-state.png`
- `16-track-b-status-check.png`

### Track C Result: Failed at Agent Dispatch Authorization

- Asked orchestrator to create/install minimal socialware named
  `dogfood-audit-socialware-17834980` using only the supported product path.
- UI showed no orchestrator reply after the request.
- Database polling found no `dogfood-audit-socialware-17834980` socialware
  config pointer or kind snapshot.
- Sent one explicit status check asking the orchestrator to either finish or
  report the missing capability.
- Runtime logged that the status message was written, but dispatch to the agent
  failed:
  `Kind.Server: fire-and-forget cast dispatch FAILED ... reason=:unauthorized`.
- The UI showed the status check message but no agent response.

Conclusion:

- Track C did not reach socialware authoring.
- The blocking point observed today is session-to-agent dispatch authorization,
  not socialware definition validation.
- This also explains why the product path can appear to accept a message while
  silently failing to activate the addressed agent unless runtime logs are
  inspected.

Evidence:

- `17-track-c-socialware-request.png`
- `19-track-c-chat-latest.png`
- `20-track-c-status-check.png`

## Additional Product Findings

- Creating a session with the `orchestrator` socialware returned a 5 second
  `workspace.create_session` timeout in the UI, but database state later showed
  a session/config pointer existed. This is a partial-success/timeout mismatch.
- `local_fonts.css` is requested by the browser but served as a 404 HTML page,
  causing a strict MIME refusal.
- `curl` required `--noproxy '*'` for `world.localhost`; otherwise the local
  host name was sent through the configured proxy and returned 502.
- After successful early agent replies, later mentions failed with
  `:unauthorized` on `agent.receive`, which is a dispatch/CapBAC stability issue
  worth isolating in a follow-up bugfix branch.

## Main Update and Rebase Verification

- Updated local `main` with `git pull --ff-only origin main`.
- `main` fast-forwarded to:
  `9d61ece1f4f32bc3361b7da97bcf922e45388672`.
- Rebased `gagameow-dogfooding-audit-2026-07-08` onto `origin/main`; rebase
  completed without conflicts.
- Post-rebase `mix compile` exited 0.
- Post-rebase `SHELL=/bin/bash mix ezagent.socialware.check` exited 0:
  `autoservice-tier1`, `chat`, `hello`, `orchestrator`, and `socialware` all
  passed 15 assertions each; 5 socialware definitions passed conformance.
- Narrow socialware seed test note:
  running `manifest_seed_test.exs` by itself failed because it references
  `Ezagent.Socialware.ManifestYamlTest.FixturePlugin`, which is defined in
  `manifest_yaml_test.exs`. Running both files together passed:
  `16 tests, 0 failures`. This is a test isolation dependency, not an audit
  branch product failure.
- Post-rebase `SHELL=/bin/bash mix precommit` did not complete green. It failed
  in `ezagent_web` with one flaky/environment-sensitive failure:
  `WorldConversationTest` at
  `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs:1374`, where
  `assert_patch/2` expected navigation after `session.create` but received no
  patch.
- The same single test was observed passing once on updated `main` and failing
  on a subsequent run on updated `main`, then failing in the feature worktree
  after removing all code differences from `apps/`. The failure is therefore
  not attributable to the final audit branch code changes.
- The failing run logged an asynchronous SQL sandbox ownership error in
  `Ezagent.ActionSet.Identity.handle_cascade_notify_managers/2` after the test
  owner exited. Current hypothesis: the test has a race with post-create cascade
  notification or LiveView navigation timing, exposed by test DB/build/runtime
  state.

Current verification status:

- Completed: compile, socialware conformance check, narrow socialware paired
  manifest tests, broad precommit through all earlier umbrella apps.
- Blocked: final all-green `mix precommit` due the existing/flaky
  `WorldConversationTest` failure described above.
- Recommended follow-up: isolate that test in a dedicated bugfix branch by
  making `session.create` wait for deterministic navigation/settlement or by
  allowing the cascade notification process under SQL sandbox before the test
  process exits.

## Post-Return Reassessment

### Test Scope and Completion

- Runtime/UI scope: covered local boot, login, sessions list, new-session dialog,
  plain session creation, member panel, chat send, agent mention/reply, session
  deep-link behavior, and runtime logs.
- Track A scope: covered product-initiated repository write, corrected worktree
  write, external git verification, branch push, and draft PR creation.
  Completion: partial success. Real code write + PR path worked, but default
  agent cwd/repo binding wrote to the main checkout until an absolute worktree
  path was supplied.
- Track B scope: covered product-initiated plugin scaffold, plugin compile,
  app-tree presence, plugin wiring invariant, scratch-plugin exemption, and
  pre-rebase full precommit. Completion: success for "produce a plugin-shaped
  artifact"; the scaffold is not retained as final branch code because this PR
  is an audit return, not a runtime plugin change.
- Track C scope: covered asking orchestrator to author/install socialware,
  status-check retry, UI transcript, runtime log inspection, and DB checks for
  expected socialware rows. Completion: incomplete for the broader product
  capability. It only proves that the orchestrator-mediated route failed after
  `agent.receive` authorization, not that existing socialware author/install
  mechanisms are unusable.

### Are the Blockers Real?

- Real blocker: session-to-agent dispatch can fail with `reason=:unauthorized`
  after the UI accepts a mention. This is a real product/runtime issue because
  the message was persisted and routed, but the agent was not activated and the
  UI did not surface the failure.
- Real blocker: default agent workspace/repo binding is unsafe for dogfooding.
  The agent reported `branch main` and wrote into `/home/huangjiajia/ezagent`
  unless given the absolute audit worktree path.
- Real blocker: orchestrator socialware session creation produced a UI timeout
  while backend state partially existed. This needs transactional/error-surface
  follow-up.
- Not a sufficient blocker claim: "Track C cannot be implemented." The repo has
  existing socialware capabilities that were not fully exercised in this run:
  world `workspace.template.save`, world `session.create`, `DefinitionRegistry`,
  `mix ezagent.socialware.import`, `mix ezagent.socialware.check`, and
  `mix ezagent.workspace.create_session`.

### Missed / Underused Existing Capabilities

- I over-indexed on "inside ezagent = ask the orchestrator" for Track C. That was
  useful for dogfooding the agent path, but it did not exhaust the product's
  socialware authoring surface.
- The current framework expects socialware to be data persisted through
  `Ezagent.Socialware.DefinitionRegistry`, not bespoke code or random files.
  The authoring guide explicitly says the Definition persists through
  `DefinitionRegistry` and not a parallel writer.
- The world operator path already wires template save and socialware definition
  preparation in `Ezagent.World.WorkspacePluginActions.save_session_template/2`.
  It also publishes the current template tag after save.
- The world session path already calls
  `Ezagent.World.SocialwareInstall.prepare_create_template/6` and then
  `Ezagent.Workspace.create_session/3` through `session.create`.
- CLI/operator primitives exist for follow-up verification:
  `mix ezagent.socialware.import`, `mix ezagent.socialware.check`, and
  `mix ezagent.workspace.create_session`.

### Follow-Up Plan

1. Isolate the `agent.receive :unauthorized` regression with a small test or
   reproducible script:
   create a session with orchestrator, send two mentions, assert both mentions
   either deliver or surface an explicit user-visible failure. Inspect why the
   first ping succeeded and later mentions failed.
2. Add a worktree-binding guard for dogfooding agents:
   session/agent creation should carry the intended repo/worktree path, or the UI
   should show the active cwd/branch before an agent can write files. At minimum,
   dogfooding prompts should inject the absolute task worktree.
3. Re-run Track C through the existing non-orchestrator product path:
   use world workspace template save or a manifest imported via
   `mix ezagent.socialware.import`, validate with
   `mix ezagent.socialware.check`, instantiate with
   `mix ezagent.workspace.create_session`, and open
   `/socialware/chat?session_uri=...` after building customer assets.
4. If the world UI template path fails, classify that separately from agent
   dispatch. Expected failure categories: template save auth, Definition
   conformance, create-session timeout/partial success, public-view live-session
   gate, or customer asset rendering.
5. Fix or file the UI timeout/partial-success issue around orchestrator session
   creation so users do not see a failure when backend rows were created.

## Verification Checklist

- [x] Runtime boot attempted and result recorded.
- [x] Track A result recorded with success evidence and worktree caveat.
- [x] Track B result recorded with success evidence and final-branch removal
      rationale.
- [x] Track C result recorded with failure breakpoint.
- [x] Rebase verification run after main update.
- [ ] Final all-green `mix precommit` blocked by the flaky
      `WorldConversationTest` failure recorded above.
- [x] Draft PR created: https://github.com/ezagent42/ezagent/pull/1247.
