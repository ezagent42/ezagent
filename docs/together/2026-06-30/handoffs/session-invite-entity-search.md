# Handoff: Session Invite Entity Search

> **Date:** 2026-06-30 · **From:** codex · **To:** zyli or an independent developer
> **Tracking:** AM-2 · **Base:** `origin/main` @ `72ae93a3`
> **Status:** build-ready - verified raw input gap and existing URI authority helpers.

## 0. Mission

Replace the conversation members panel's raw "Invite by entity URI" text field
with a searchable entity picker. Operators should search visible users/agents,
select an entity, and invite it into the session. The server must still reject a
tampered, malformed, or cross-workspace submitted URI.

## 1. Required Reading

1. Skill `ezagent-developer`.
2. Skill `elixir-phoenix-helper`.
3. `docs/guide/world-coordination.md`.
4. `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`.
5. `apps/ezagent_plugin_world/assets/src/main.tsx`.
6. `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`.
7. `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`.
8. `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`.
9. `apps/ezagent_domain_ui/lib/ezagent_domain_ui/uri_options.ex`.
10. Existing tests under `apps/ezagent_web/test/ezagent_web/world_conversation_test.exs`
    and `apps/ezagent_plugin_world/test/assets/`.

## 2. Locked Decisions

| # | Decision | Value |
|---|---|---|
| 1 | Search surface | Add a world LiveView search/reply surface for entities, not a new HTTP controller. |
| 2 | Authority | Search results and submit revalidation are caller/workspace scoped. Use `Ezagent.UI.UriOptions.valid_for?/4` for the final submitted URI. |
| 3 | Search corpus | Include registered users from `Ezagent.Users.list_all()` for the current workspace and live entity agents from the registry. Cold registered users must be selectable. |
| 4 | Submit path | Keep final invite as `session.invite`; do not bypass `ConversationActions.invite_member/3` or `Session :join`. |
| 5 | UX fallback | Exact URI paste may be kept only if it still passes server revalidation. The primary path is typeahead selection. |

## 3. Architecture Primer

The current UI gap is in `Conversation.tsx`: the invite form renders a plain
`<input id="world-invite-input">` and submits `member` to `onInvite`, which
`main.tsx` sends as `world:dispatch` action `session.invite`.

The backend invite path is already correct in shape: `ConversationActions` parses
the member URI, demand-spawns cold members, dispatches `:session :join` in
`:call` mode, then refreshes the members panel. What is missing is a scoped
search/read API and server-side revalidation before the submit reaches that
path.

`Ezagent.UI.UriOptions` is the existing caller-authorized URI option and
validator module. Its `entities/2` options are registry-backed; this task needs
registered users too, so either add a world-specific search helper or carefully
extend `UriOptions` with tests.

## 4. Design and Phased Plan

Phase 1 - Server search:
- Add a read helper, preferably in `Ezagent.World.ConversationData`, for
  `search_invitable_entities(caller_uri, workspace_uri, query, session_uri)`.
- Results shape:
  `%{"uri" => string, "label" => string, "kind" => "user" | "agent", "already_member" => boolean}`.
- Filter to `current_workspace_uri`.
- Use `Ezagent.EntityPresenter.display_many/1` for labels.
- Include registered users from `Ezagent.Users.list_all()`.
- Include live agents from `Ezagent.KindRegistry.list_all()` or existing
  identity data helpers.
- Exclude or mark current session members via
  `ConversationData.member_options(session_uri)`.

Phase 2 - LiveView event API:
- Add a dedicated event, for example `handle_event("world:entity_search", args, socket)`.
- Return `{:reply, %{"options" => rows}, socket}` so React can call it with the
  existing `pushEvent` callback support.
- Required args: `session_uri`, `q`.
- Derive caller/workspace from socket assigns, not client payload.
- Reject malformed session URI with an empty result plus `"error" => "bad_session_uri"`.

Phase 3 - Submit revalidation:
- Before `invite_member/3` dispatches join, validate:
  `Ezagent.UI.UriOptions.valid_for?(caller, workspace, member_uri, [:entity])`.
- Return `error:invalid_member_uri` or `error:bad_member_uri` consistently.
- Keep the existing `demand_spawn_member` and `session.join` flow.

Phase 4 - React typeahead:
- Replace the raw invite input block in `Conversation.tsx` with a combobox:
  search box, result list, selected row state, clear/cancel.
- On open and on query change, call `world:entity_search`.
- Render label + URI; use monospace for URI.
- Disable submit until a valid selection or exact URI paste exists.
- Preserve keyboard basics: Escape closes, Enter selects highlighted result or submits selected value.

Phase 5 - Tests:
- Add/extend backend tests for search scoping and submit revalidation.
- Add/extend asset tests for the React combobox behavior.

## 5. Definition of Done

- [ ] The invite form no longer presents only a raw URI textbox. It offers a
      searchable entity chooser showing entity display label and URI.
- [ ] Searching lists registered users in the current workspace, including users
      that are not currently live, plus live agents in the current workspace.
- [ ] Already-present session members are excluded or visibly disabled so the
      operator does not invite duplicates.
- [ ] Selecting a result and pressing Invite sends the same `session.invite`
      action and refreshes the members panel on success.
- [ ] A tampered submit for another workspace is rejected server-side through
      `UriOptions.valid_for?/4`; the UI does not silently show success.
- [ ] A malformed URI or non-entity URI is rejected server-side.
- [ ] Tests cover search scoping, registered-cold user inclusion, duplicate
      member handling, and tampered submit rejection.
- [ ] Gates for touched work pass: targeted world tests, asset tests, `mix format
      --check-formatted` on touched Elixir files, `mix ezagent.check_invariants`,
      and `mix precommit` before return if the environment supports it.

## 6. Discuss-First vs Deferred

**Clarify-first?** No for the picker itself. The raw-input gap is verified and
the authority model has an existing helper.

**Discuss-first:** changing global `Ezagent.UI.UriOptions.entities/2` semantics
for every picker; adding a public HTTP search endpoint; changing session join
authorization.

**Deferred:** fuzzy ranking beyond case-insensitive substring; pagination for
large workspaces; invite by email; multi-select batch invite.

**Never deferred here:** submit revalidation, cross-workspace rejection, and a
user-facing error/status on failed invite.

## 7. Conflict Avoidance

This task owns:

- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- `apps/ezagent_plugin_world/assets/src/main.tsx`
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`
- `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
- relevant world tests

Do not touch `Identities.tsx` for this task. Avoid `styles.css` unless a typeahead
state cannot be expressed with existing utility classes.

## 8. Merge Model

Work on `feat/session-invite-entity-search-0630` from `origin/main`. Keep the
branch rebased. The lead merges the task branch to `main` after the DoD is met.

## 9. Gates, Estimate, Open Questions

Estimated LOC: 80 to 140 TSX, 80 to 140 Elixir, 80 to 160 tests.

Suggested commands:

```bash
MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_web/test/ezagent_web/world_conversation_test.exs --trace
MIX_ENV=test POSTGRES_PORT=5432 mix test apps/ezagent_plugin_world/test/assets/world_navigation_test.exs --trace
node apps/ezagent_plugin_world/assets/test/world_navigation_test.mjs
mix ezagent.check_invariants
mix precommit
```

Open question for the dev to resolve in implementation: whether to implement the
search helper locally in world or extend `Ezagent.UI.UriOptions`. Prefer local
world helper unless extending `UriOptions` is clearly low-risk and fully covered
by existing tests.

## 10. Paste-Ready Prompt

```text
Use skills: dev-together, ezagent-developer, elixir-phoenix-helper, test-driven-development.

Accept handoff docs/together/2026-06-30/handoffs/session-invite-entity-search.md.
Create branch feat/session-invite-entity-search-0630 from origin/main.

Build the conversation member invite picker:
- add a caller/workspace-scoped entity search reply surface in WorldLive;
- search registered users in the current workspace plus live agents;
- replace Conversation.tsx raw URI input with a typeahead selector;
- keep final submit on session.invite;
- revalidate submitted member URI server-side with Ezagent.UI.UriOptions.valid_for?/4;
- add tests for search scoping, cold registered users, duplicate handling, and tampered submit rejection.

Do not touch the Identities user-onboarding UI in this task. Return with gates and evidence.
```
