# Agent Console CRUD — Update editor + Delete helper-swap + live-status fix (on #938)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Pass `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` to every Elixir subagent. Steps use `- [ ]`.

**Goal:** Complete the Agent Console CRUD by adding the **Update** verb (a config editor at a new sub-route, on 黄佳佳's `Ezagent.AgentConfig` facade from #938), finish **Delete** by swapping the bound-gate to #938's canonical session-domain helper, and fix the **live-status** display bug found in the live E2E.

**Architecture:** **#938 is now MERGED to main** (the `Ezagent.AgentConfig` facade + session helpers are on `origin/main`), so this branch rebases onto **latest `origin/main`** (no longer a stack). Main also moved past #938 — notably **#943 cap-gated config READS symmetric with writes**: `read_cascade/read_key` now take `(agent_uri, caller, caps, opts)` and require the operator's manage-cap. Update wires a new world sub-route whose **read happens in the route's state builder** (C2, `read_cascade/4`) + **3 `world:dispatch` MUTATION actions** (`agents.config.update`/`delete_path`/`repoint`, C3) to the `Ezagent.AgentConfig` facade. (The contract doc's `agents.config.read` action = our route-state read; mutations refresh by re-building that state, not a separate read action.) The editor is a key/value form over the **user layer** (workspace/session shown read-only — the VS Code Default-vs-User pattern). Every mutation AND read goes through the facade (which dispatches manage-cap-gated `ConfigEvolve` actions); the world layer never touches `ConfigStore` directly.

**Tech Stack:** Elixir/OTP (ezagent umbrella), Phoenix LiveView (`world_live.ex`), React/TSX island (`Identities.tsx` + `main.tsx`), shadcn-shaped components, ExUnit. Tests run `POSTGRES_PORT=5432`.

## Global Constraints

- **#938 merged; base = `origin/main` (rebase onto latest).** Do NOT re-implement the facade; call `Ezagent.AgentConfig.{read_cascade/4, apply_delta/4, delete_path/4, repoint/4}` and `EzagentDomainInstanceMessage.{agent_live_sessions/1, agent_in_live_session?/1}`.
- **Reads AND mutations through the facade only, cap-gated (P14 / no-unowned-caps).** Update/delete-path/repoint AND read dispatch via the facade under the operator's `current_caps`. Per **#943**, `read_cascade(agent_uri, caller, caps, opts)` requires the operator's manage-cap — a caller without it gets `{:error, :unauthorized}`, which the config page must render as a **"no permission" state, never a crash**. The world layer NEVER calls `ConfigStore`/`ConfigEvolve` directly and NEVER writes config rows.
- **No silent drops (Invariant #9).** Every config mutation failure surfaces an operator-facing message (reason code → Chinese, mirroring `create_error_message/1`), with a **fallback clause** for unmapped reasons. Map at least these (confirm the full set against `agent_config.ex` + the dispatch layer, do NOT assume the contract doc is exhaustive): `unauthorized`, `agent_not_found`, `invalid_agent_uri`, `invalid_uri`, `invalid_layer`, `invalid_key`, `invalid_patch`, `invalid_replace_body`, `invalid_path`, `path_not_found`, `config_not_found`, `cross_tenant_target`, `cross_workspace_denied`, `subject_not_self`. Tests must cover at least `unauthorized`, `invalid_patch`, and one of `path_not_found`/`cross_workspace_denied`.
- **`delete_path` auth ordering caveat (review finding — backend follow-up).** The facade's `delete_path/4` reads `ConfigStore.layer_objects_for_key/2` (a body read) BEFORE the auth-gated dispatch, so a caller WITHOUT the manage-cap hitting a nonexistent key/path may get `:config_not_found`/`:path_not_found` *instead of* `:unauthorized` (an existence info-leak + breaks the "cap-denial → unauthorized" expectation). Do NOT assume `delete_path` always returns `:unauthorized` for no-cap callers; test the cap-denial path against an EXISTING field. Flag a backend follow-up to @黄佳佳 to front/symmetrize `delete_path`'s auth gate (this is a real merged-facade defect, not a confirmation).
- **V1 scope:** **all keys editable via the user-layer override**; inherited **workspace/session layer bodies shown read-only** (not "only show the user layer"). Render every key `read_cascade` returns (Allen's "start full" = all keys). Field-path delete via `delete_path`; whole-key clear deferred. Repoint: backend exists; frontend UI deferred (omit or leave a disabled stub — do not fake it).
- **After mutation → re-read** `read_cascade` (our contract answer #4); do not trust an in-form echo.
- **Additive only** to the world surface + the one route. shadcn tokens already in `Identities.tsx`.
- **`turn_id`:** frontend omits it; the facade auto-generates `console:<uuid>`.

---

## Phase A — Delete: swap bound-gate to #938's helper (also clears the uri_query.scan violation)

### Task A1: Replace interim `agent_bound_to_live_session?` with `agent_live_sessions/1`

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` (`dispatch_agent_delete/2` gate + `action_error_message/1`)
- **Modify** (NOT delete the file): `apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator.ex` — remove ONLY the interim `agent_bound_to_live_session?/1` helper (~line 518-545; its raw `String.starts_with?(uri_str, "session://")` is the `uri_query.scan` violation) and its `@doc`/`@spec`. The module has other session/orchestrator responsibilities — leave them intact.
- Delete (whole file): `apps/ezagent_domain_session/test/ezagent/entity/session/orchestrator_bound_test.exs` (it only tested the removed helper)
- Modify: `apps/ezagent_plugin_world/test/ezagent/world/agent_delete_dispatch_test.exs` (bound case → new helper/shape)

**Interfaces:**
- Consumes: `EzagentDomainInstanceMessage.agent_live_sessions(agent_uri) :: {:ok, [URI.t()]} | {:error, term()}`.

- [ ] **Step 1:** In `dispatch_agent_delete/2`, replace the gate line `false <- Ezagent.Entity.Session.Orchestrator.agent_bound_to_live_session?(agent_uri)` with a call to `EzagentDomainInstanceMessage.agent_live_sessions(agent_uri)` that blocks when the list is non-empty:

```elixir
with {:ok, agent_uri} <- parse_agent_uri(agent_uri_str),
     {:ok, []} <- EzagentDomainInstanceMessage.agent_live_sessions(agent_uri),
     target = Ezagent.URI.with_action(agent_uri, :manage, :delete),
     {:ok, {:ok, :deleted}} <- Invocation.dispatch(%Invocation{...}) do
  # success → push_navigate to /identities/agents
else
  {:ok, sessions} when is_list(sessions) ->
    {:noreply, push_agent_action_error(socket, {:agent_bound_to_live_session, sessions})}
  :error -> {:noreply, push_agent_action_error(socket, :invalid_agent_uri)}
  {:error, reason} -> {:noreply, push_agent_action_error(socket, reason)}
end
```

- [ ] **Step 2:** Update `action_error_message/1` for the bound case to list the sessions: `defp action_error_message({:agent_bound_to_live_session, sessions}), do: "该 agent 正在 #{length(sessions)} 个对话中（#{Enum.map_join(sessions, "、", &short_session_name/1)}），先从这些对话移出再删除"` (add a small `short_session_name/1` that takes the session URI's last path segment; keep the plain `:agent_bound_to_live_session` clause too for safety).
- [ ] **Step 3:** Remove the `agent_bound_to_live_session?/1` helper (+ its `@doc`/`@spec`) from `orchestrator.ex` (keep the rest of the module) and delete `orchestrator_bound_test.exs`. Then sweep for stragglers: `rg "agent_bound_to_live_session"` must return **zero** hits (code, tests, docs, ledger references) — clean any remaining reference.
- [ ] **Step 4:** Update `agent_delete_dispatch_test.exs` bound case to drive the same delete path while the agent is bound (mirror the existing fixture that joins the agent to a live session) and assert the surfaced error is the bound error AND `KindRegistry.lookup` still finds the agent. (The fixture that created a live session + joined the agent stays; only the gate call changes.)
- [ ] **Step 5:** Run: `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/agent_delete_dispatch_test.exs` + `POSTGRES_PORT=5432 mix ezagent.uri_query.scan` (must now report 0 violations — the orchestrator line is gone).
- [ ] **Step 6: Commit.** `refactor(world): delete bound-gate via EzagentDomainInstanceMessage.agent_live_sessions (drop interim helper; clears uri_query.scan)`

---

## Phase B — Fix the live-status display bug (R-hardening)

Observed in the live E2E: an agent present in `KindRegistry` shows `Status: live` in the agents **list** but `Phase: unknown` on the **detail** page — the two read live status from different sources that disagree.

### Task B1: Detail Phase reflects live status (matches the list)

**Files:**
- Likely modify: `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex` (`agent_status/1` / `agent_detail` builder) and/or `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex` (`lifecycle_status/1`) — **diagnose first**, fix the actual mismatch.
- Test: `apps/ezagent_plugin_world/test/ezagent/world/agent_detail_live_status_test.exs` (create)

**Interfaces:**
- `Ezagent.World.IdentityData` builds `agent_detail` state with `"agent_status"`; the list's `"alive"` is set in `list_entities/2`. Find why list-alive ≠ detail-phase.

- [ ] **Step 1: Diagnose.** Spawn/locate a live agent (in `KindRegistry`); compare what `list_entities/2` uses to set `alive` vs what `agent_status/1` (→ `Domain.Agent.lifecycle_status/1`) returns for the same URI. Identify the mismatch (e.g. one reads `KindRegistry`, the other reads a snapshot; or `lifecycle_status` returns a phase the React maps to "unknown"). Record the root cause in the report.
- [ ] **Step 2: Write the failing test.** For an agent that IS live (present in `KindRegistry`), assert the `agent_detail` state's phase is a live value (e.g. `"alive"`/`"registered"`), NOT `"unknown"`/`nil`, and that it agrees with the list's `alive`. Run — confirm it fails (reproduces the bug).
- [ ] **Step 3: Fix** the source so detail phase reflects live status consistently with the list. (No placeholder: implement the actual fix found in Step 1.)
- [ ] **Step 4: Run** — test passes; also confirm the list still shows correct status. `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/agent_detail_live_status_test.exs`
- [ ] **Step 5: Commit.** `fix(world): agent detail Phase reflects live KindRegistry status (was unknown for live agents)`

---

## Phase C — Update: config editor sub-route on the AgentConfig facade

### Task C1: Route + entry points for the config sub-page

**Files:**
- **Modify (CRITICAL — typed-slot registration): `apps/ezagent_plugin_world/lib/ezagent/world/slot_registry.ex`** — register `"agent_config"` as a `:layout_slot` in the agent group (next to `{"agent_detail", "Agent Detail"}`, `{"agent_api_keys", ...}` ~line 75-79). Every `WorldLive.route_for/2` route component MUST be a registered `:layout_slot` or it **hard-fails** the layout gate (`slot_registry_test.exs` / mount gate). I missed this in v1 — it is required.
- Modify (GENERATED): `apps/ezagent_plugin_world/assets/src/slots.manifest.json` — regenerate via `mix world.slots.manifest` (the JS mount gate + `slot_manifest_test.exs` consume it; drift fails CI).
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex` (add `/identities/agents/:uri/config` → `%{component: "agent_config", title: "Agent Config", path: path}`, mirroring the `…/caps` clause)
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex` (add `"config"` to the agent row's action paths in `list_entities/2`; add a `config_path` to `agent_detail` state)
- Modify: `apps/ezagent_plugin_world/assets/src/components/Identities.tsx` (add "Config" to the `AgentsTable` Actions `InlineLinks` and the `AgentDetail`)

**Interfaces:**
- Produces: registered `:layout_slot` `"agent_config"`; route component `"agent_config"` with `entity_uri`; a `config_path` per agent row.

- [ ] **Step 1 (slot registry FIRST):** Add `{"agent_config", "Agent Config"}` to the agent `:layout_slot` group in `slot_registry.ex` (match the existing entry shape). Run `mix world.slots.manifest` to regenerate `slots.manifest.json`. Run `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/slot_registry_test.exs` (and the manifest sync test) — must pass.
- [ ] **Step 2:** Add the route clause (copy the `…/caps` clause shape; confirm how `:uri` is parsed into `entity_uri` — mirror `agent_detail`/`entity_caps`). Add `config_path` (`detail_path`-style helper) for the row + detail.
- [ ] **Step 3:** Add "Config" link to `AgentsTable` Actions and `AgentDetail` (use the existing `InlineLinks`/`actionLinkClass`). **Keep the link visible for everyone — do NOT hand-roll `Capability.matches?` in TSX/LV to hide it.** Permission is enforced server-side: entering the page, `read_cascade/4` returns `{:error, :unauthorized}` → the page renders the no-permission state (Task C2).
- [ ] **Step 4: Test** the route resolves + is a registered slot: `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/ezagent/world/` (extend a routes test asserting `/identities/agents/<enc>/config` → `component: "agent_config"`; the slot gate from Step 1 covers registration).
- [ ] **Step 5: Commit.** `feat(world): agent config sub-route + typed-slot registration + entry links`

### Task C2: `agent_config` state builder (read_cascade)

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex` (add `component_state` clause for `"agent_config"`)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/agent_config_state_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.AgentConfig.read_cascade(agent_uri, caller, caps, opts) :: {:ok, %{agent_uri, workspace_uri, default_key, layer_order, keys: [%{key, effective_body, editable, editable_layer, layers}]}} | {:error, term()}`. **Per #943 the read is cap-gated** — pass the authenticated `caller` + `caps` (the `component_state/5` clause already receives `caller` and `caps`).

- [ ] **Step 1: Write the failing test.** For an agent whose creator (the test caller) holds the manage-cap, assert the `agent_config` component state contains a `"cascade"` map with `"keys"` including the default `"advisor.behavior"` (stable empty shape ok), built from `read_cascade`. (Drive an `apply_delta` first via the facade to get a non-empty body, then assert the state reflects it — proves it reads real cascade state, not a stub.) Add a case: a caller WITHOUT the manage-cap → state carries `"config_error"` (the unauthorized message), not a crash.
- [ ] **Step 2: Run** — fails (no clause). 
- [ ] **Step 3: Implement** the `component_state(%{component: "agent_config", entity_uri: agent_uri}, base, _workspace_uri, caller, caps)` clause: call `Ezagent.AgentConfig.read_cascade(agent_uri, caller, caps)`, `jsonable/1` the `{:ok, cascade}` into `base |> Map.put("agent_uri", ...) |> Map.put("cascade", cascade)`; on `{:error, :unauthorized}` put `"config_error" => "没有查看权限（需要 manage 权限）"`; on other `{:error, reason}` put the mapped message. Reuse the `jsonable/1` already in this module.
- [ ] **Step 4: Run** — passes. **Commit.** `feat(world): agent_config state via AgentConfig.read_cascade`

### Task C3: world_live config mutation dispatch (update / delete_path / repoint)

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` (3 `handle_event` clauses + `dispatch_config_*` helpers; extend `action_error_message/1` for the facade reason codes)
- Test: `apps/ezagent_plugin_world/test/ezagent/world/agent_config_dispatch_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.AgentConfig.apply_delta(agent_uri, caller, caps, %{layer: "user", key: key, patch: patch})`, `.delete_path(agent_uri, caller, caps, %{layer: "user", key: key, path: path})`, `.repoint(agent_uri, caller, caps, %{layer, key, config_id})`. (Confirm whether the facade's `attrs` wants string or atom keys by reading `agent_config.ex` `apply_args`/`layer`/`key`/`field` helpers; pass whatever it accepts.)

- [ ] **Step 1: Write the failing test (anti-stub, backend-pinned).** Dispatch `agents.config.update` (key `advisor.behavior`, patch `%{"tone" => "decisive"}`) with the operator's manage-cap; assert `{:ok, ...}` AND that a fresh **`Ezagent.AgentConfig.read_cascade(agent_uri, caller, caps)`** (per #943 — read is cap-gated, /4) shows `tone == "decisive"` in the user layer (durable, read back from the facade — not an in-form echo). **Cap-denial case:** dispatch update with empty caps → assert `:unauthorized` surfaced + value unchanged. **delete_path case:** first `apply_delta` a field so it EXISTS, then `delete_path` it → re-read shows it gone (test the cap-denial of delete_path against an EXISTING field — per the auth-ordering caveat, a nonexistent path may return `:path_not_found` before `:unauthorized`). **Reason-code coverage:** include an `invalid_patch` case and one of `path_not_found`/`cross_workspace_denied`.
- [ ] **Step 2: Run** — fails (no clauses).
- [ ] **Step 3: Add** `handle_event("world:dispatch", %{"action" => "agents.config.update", "args" => %{...}}, socket)` → `dispatch_config_update/2` (parse agent_uri + key + patch; call `AgentConfig.apply_delta(agent_uri, caller, caps, attrs)`; on success re-build the `agent_config` state and `push_event("world:state", state)`; on `{:error, reason}` → a `push_config_error/2` mirroring `push_agent_action_error/2`). Same shape for `agents.config.delete_path` and `agents.config.repoint`. Map the facade reason codes in `action_error_message/1` (unauthorized→"没有修改权限（需要 manage 权限）", subject_not_self→…, invalid_patch→…, etc.).
- [ ] **Step 4: Run** — passes. **Commit.** `feat(world): agents.config update/delete_path/repoint dispatch via AgentConfig facade`

### Task C4: React config editor + main.tsx wiring

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Identities.tsx` (add `AgentConfigEditor`; route it in `IdentitiesSurface` for `component === "agent_config"`; extend `IdentitiesState` with `cascade?` + `config_error?`)
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx` (add `onConfigUpdate`/`onConfigDeletePath` to the context interface + wiring object + the `IdentitiesSurface` render, mirroring `onCreateAgent`/`onDeleteAgent`)

**Interfaces:**
- `onConfigUpdate(agentUri, key, patch)` → `pushEvent("world:dispatch", {action: "agents.config.update", args: {agent_uri, layer: "user", key, patch}})`. `onConfigDeletePath(agentUri, key, path)` → `agents.config.delete_path` with `{agent_uri, layer: "user", key, path}`.

- [ ] **Step 1:** Add `cascade?: {...}` + `config_error?: string` to `IdentitiesState`; route `agent_config` to `<AgentConfigEditor state onConfigUpdate onConfigDeletePath />` in `IdentitiesSurface`.
- [ ] **Step 2:** Build `AgentConfigEditor`: for each `cascade.keys[]`, render the key with its `effective_body` as editable rows (each field → label + input; a field named `soul_md` → `<textarea>`); user layer editable, show workspace/session layer values read-only if present; a "Save" button per key calls `onConfigUpdate(agent_uri, key, editedBody)` (send the full edited body as the patch — shallow merge); an "×" per field calls `onConfigDeletePath(agent_uri, key, [field])`; an "add field" row. Render `config_error` as a `role="alert"` banner (mirror `create_error`). Use existing `Button`/`Input`/shadcn tokens.
- [ ] **Step 3:** Wire `onConfigUpdate`/`onConfigDeletePath` in `main.tsx` (mirror the `onDeleteAgent` block + interface + render prop).
- [ ] **Step 4: Build/typecheck** the assets the project way (`pnpm` — check `apps/ezagent_plugin_world/assets/package.json`); zero new TS errors. **Commit.** `feat(world): agent config key/value editor (user layer) + wiring`

### Task C5: E2E demonstrable evidence (full console CRUD)

**Files:** none (evidence → `docs/superpowers/notes/2026-06-24-agent-console-crud-e2e-evidence.md`).

- [ ] Run the live app (`world` launch config + `POSTGRES_PORT=5432`); capture, with agent-browser/preview + backend reads: (a) **Create** echo agent → appears in list; (b) **Read config** → editor shows `advisor.behavior`; (c) **Update** a field → reload → value persists (backend `read_cascade` confirms); (d) **delete_path** a field → gone on reload; (e) **Delete agent** → gone from list + `KindRegistry.lookup` not-found; (f) **bound-block** → delete refused with the session list; (g) **cap-denial** → error surfaced. Write the evidence note. Commit.

---

## Self-Review

- **Spec coverage:** Update (C1-C4: route, read, mutations, editor), Delete finish (A1: canonical helper + richer block + clears uri_query.scan), live-status fix (B1), demonstrable E2E (C5). Repoint backend-only (UI deferred, flagged — not faked). Compliance: edits user layer (VS Code Default/User pattern; Allen's "full" = all keys, all shown).
- **No-placeholder:** facade call shapes + reason codes + dispatch/error patterns are concrete; B1's fix is "diagnose-then-implement the real fix" (a bug task, acceptance pinned), not a placeholder value.
- **Type consistency:** `cascade`/`config_error` keys consistent server↔client; `agents.config.*` action strings + `agent_uri`/`layer`/`key`/`patch`/`path` arg keys consistent between `main.tsx` and `world_live.ex`; facade signatures match `agent_config.ex`.
- **Anti-demo / backend-pinned:** C3 asserts the patched value is read back from `read_cascade` (durable); A1 asserts `KindRegistry.lookup` still finds a bound agent (block real); C5 captures live backend reads.
- **Stacked-on-#938** noted; PR merges after #938; rebase onto main when #938 lands.
