# Handoff: World Hello Convergence

> **Date:** 2026-06-23 · **From:** Allen/Codex lead · **To:** an independent developer (human + cc/codex)
> **Tracking:** `world-hello-convergence` · **Base:** `origin/main` @ `99f9eddb`
> **Status:** confirmed — complete the world hello化 path needed by today's E2E.

## 0. Mission

Complete the world/hello path needed for launch: world can create or open a hello
app, show the generated `@json-render` page in the operator experience, expose
the public customer link, and keep session/chat/customer state coherent enough to
pass the shared E2E.

## 1. Required reading (before writing code)

1. Skill `ezagent-developer`.
2. `docs/guide/world-coordination.md`.
3. The `dev-together` skill and handoff standard.
4. `docs/superpowers/handoffs/2026-06-22-hello-phase0-status.md`.
5. `docs/together/2026-06-22/returns/hello.md`.
6. `docs/together/2026-06-23/handoffs/world-deploy-e2e-pg.md`.

## 2. Locked decisions (settled — do not re-litigate)

| # | Decision | Value |
|---|---|---|
| 1 | Public page surface | `/socialware/customer` is the external generated-page surface for `public_view` hello sessions. |
| 2 | Operator experience | The operator must see the generated page from world. Prefer the registered `EzagentPluginHello.PageView`/`HelloRenderer` path over the temporary iframe if feasible today. |
| 3 | Scope | Implement only the product fixes needed by the full E2E. Avoid broad world navigation or styling changes. |
| 4 | Deadline | 2026-06-23 20:00 +08:00. At 18:00, split and return the smallest working hello/world artifact if full E2E cannot finish. |

## 3. Architecture primer

Hello already has:
- `EzagentPluginHello.Template.HelloSession` (`session.hello`) as the factory seam.
- `EzagentPluginHello.App.ensure_app/2` to create a `public_view` hello app.
- `EzagentPluginHello.PageView` and `HelloRenderer` for operator rendering.
- `/socialware/customer` tokenless public rendering for `public_view` sessions.

World currently has:
- session create/open surfaces in `SessionsTable.tsx` / `WorldLive`;
- conversation/chat/routing UI in `Conversation.tsx`;
- a temporary `HelloPagePreview` iframe in `Conversation.tsx`.

Relevant files:
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/template/hello_session.ex`
- `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex`
- `apps/ezagent_plugin_hello/assets/js/hello_renderer.js`
- `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`

## 4. Design (+ review status) & phased plan

Phase 0: Verify current support.
- Use the support matrix from `world-deploy-e2e-pg` if available.
- Confirm whether world can already create `session.hello` through the generic create path.
- Confirm whether the operator page view uses the native `HelloRenderer` or only the temporary iframe.

Phase 1: Close the smallest product gaps.
- If hello app creation is hidden or awkward, expose a clear world path to create/open it.
- If the operator page is only temporary, either replace it with the registered PageView or document why the temporary path is acceptable for launch.
- Ensure the external customer link is visible/copyable from world.

Phase 2: Verify the E2E hello slice.
- Create a hello app/page.
- Open it as an external customer.
- Return to world and verify session/page/conversation state.
- Verify messages across the session/external surface where currently supported; if two-way interaction needs a deeper socialware change, return the smallest working artifact and exact blocker by 18:00.

## 5. Definition of Done (demonstrable artifact)

- [ ] Screenshot/transcript showing a hello app created/opened from world.
- [ ] Screenshot showing the generated `@json-render` page in world operator context.
- [ ] Public `/socialware/customer?...` link opens without login for a public hello session.
- [ ] Evidence for the shared E2E steps 5-8, or a precise unsupported-step matrix by 18:00.
- [ ] Relevant focused tests/gates for touched files, plus `world` mount/slot checks if a world route or renderer changes.

## 6. Discuss-first vs Deferred

**Discuss-first:** replacing major world navigation; changing public-view auth; adding new CapBAC authority; making a broad renderer rewrite.

**Deferred:** a full socialware creator UX, advanced page editing, real member-worker orchestration, and any Manage-gate live mutation.

**Never deferred here:** a working launch path for hello pages and clear evidence for what part of E2E passes.

## 7. Conflict-avoidance

This task owns hello/world page rendering and hello entrypoints. Follow
`docs/guide/world-coordination.md`; if adding a route-level world surface, update
`SlotRegistry` and the manifest. Avoid editing creator-specific surfaces; the
creator branch should consume this task's links/seams.

## 8. Merge model

PRs merge into `world-hello-convergence` first. Keep rebased on `main`. The lead
merges the task branch to `main` only after the DoD is met.

## 9. Gates, file/LOC estimate, open questions

Expected files: `Conversation.tsx`, hello PageView/renderer glue, maybe
WorldLive route/action glue. Keep under 300 LOC unless the support matrix proves
larger work is required.

Open question for the return: is the temporary iframe still present, replaced,
or explicitly accepted for launch with evidence?
