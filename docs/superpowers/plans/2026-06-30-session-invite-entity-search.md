# Session Invite Entity Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the conversation invite raw URI input with a searchable, caller-scoped entity picker while preserving `session.invite` as the only mutation path.

**Architecture:** Add a world-local read helper that searches registered users and live agents within the current workspace, expose it through a LiveView `{:reply, ...}` event, and keep final invite submission on the existing `ConversationActions.invite_member/3` path. Add server-side `Ezagent.UI.UriOptions.valid_for?/4` revalidation before dispatching `Session :join`.

**Tech Stack:** Elixir/Phoenix LiveView, React/TypeScript world island, ExUnit, existing world asset tests.

## Global Constraints

- Branch: `feat/session-invite-entity-search-0630` from `origin/main`.
- Read and obey `AGENTS.md`, `CLAUDE.md`, `ezagent-developer`, `elixir-phoenix-helper`, and `docs/guide/world-coordination.md`.
- No production code before a failing test.
- Do not touch the Identities user-onboarding UI in this task.
- Do not add a public HTTP search endpoint; use the world LiveView bridge.
- Final invite still uses `session.invite`; no direct session membership mutation from the frontend.
- Server-side revalidation must use `Ezagent.UI.UriOptions.valid_for?/4`.

---

### Task 1: Server Search Helper

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`
- Test: `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs` or an existing focused world data test if present.

**Interfaces:**
- Produces: `Ezagent.World.ConversationData.search_invitable_entities(caller_uri, workspace_uri, query, session_uri) :: [map()]`
- Result map keys: `"uri"`, `"label"`, `"kind"`, `"already_member"`

- [ ] Write a failing test proving search includes a registered user in the current workspace even if the user Kind is not live.
- [ ] Run the focused test and confirm it fails because `search_invitable_entities/4` is missing.
- [ ] Implement the helper using `Ezagent.Users.list_all/0`, `Ezagent.KindRegistry.list_all/0`, `Ezagent.EntityPresenter.display_many/1`, and workspace filtering.
- [ ] Run the focused test and confirm it passes.
- [ ] Add a failing test proving cross-workspace users/agents do not appear.
- [ ] Implement the minimal filter and confirm both tests pass.
- [ ] Add a failing test proving existing session members are marked or excluded. Choose marking with `"already_member" => true` for explicit UI disabling.
- [ ] Implement the membership marking and confirm the focused tests pass.

### Task 2: LiveView Reply Event and Submit Revalidation

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`
- Test: `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`

**Interfaces:**
- Produces event: `world:entity_search` with args `%{"session_uri" => sid, "q" => query}` and reply `%{"options" => rows}`.
- Produces validation: `ConversationActions.invite_member/3` rejects malformed, non-entity, or cross-workspace submitted members before `Session :join`.

- [ ] Write a failing LiveView test or action-level test proving `world:entity_search` returns current-workspace entity options.
- [ ] Run it and confirm the failure.
- [ ] Add `handle_event("world:entity_search", ...)` returning `{:reply, payload, socket}`.
- [ ] Run the focused test and confirm it passes.
- [ ] Write a failing test proving a cross-workspace member submit is rejected with a visible `last_dispatch_status` error.
- [ ] Add `UriOptions.valid_for?(caller, workspace, member_uri, [:entity])` revalidation inside `invite_member/3`.
- [ ] Run the focused test and confirm it passes.

### Task 3: React Typeahead UI

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx`
- Test: existing asset test under `apps/ezagent_plugin_world/assets/test/` if suitable; otherwise add a focused lightweight test next to existing world asset tests.

**Interfaces:**
- Consumes: `onSearchEntities?: (sessionUri: string, q: string, callback: (reply) => void) => void`
- Keeps: `onInvite(sessionUri, selectedUri)`

- [ ] Write or extend an asset test proving the invite panel exposes a search field and renders returned entity options.
- [ ] Run the asset test and confirm it fails against the raw input implementation.
- [ ] Add `onSearchEntities` plumbing in `main.tsx` using `pushEvent("world:entity_search", ..., callback)`.
- [ ] Replace the raw invite field in `Conversation.tsx` with search state, option list, selected option state, and disabled duplicate rows.
- [ ] Keep exact URI paste as fallback only when no option is selected.
- [ ] Run the asset test and confirm it passes.

### Task 4: Verification and Return Prep

**Files:**
- Modify: `docs/together/2026-06-30/returns/session-invite-entity-search.md`

- [ ] Run focused Elixir tests.
- [ ] Run focused asset tests.
- [ ] Run `mix format --check-formatted` or format touched Elixir files and check.
- [ ] Run `mix ezagent.check_invariants`.
- [ ] Run `mix precommit` if local dependencies allow it; otherwise record the exact blocker.
- [ ] Write the dev-together return with DoD reconciliation and gate evidence.
