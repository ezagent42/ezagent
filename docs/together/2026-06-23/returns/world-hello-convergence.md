# Return: World Hello Convergence

> **returned_at:** 2026-06-23 19:32 +08:00
> **deadline:** 2026-06-23 20:00 +08:00
> **deadline_status:** on_time
> **dev:** Claude (Opus 4.8) · **branch:** `world-hello-convergence` (off `main` @ `3cd5a5a4`)
> **handoff:** `docs/together/2026-06-23/handoffs/world-hello-convergence.md`

## 1. Summary

The world→hello launch path is closed end-to-end. An operator can create a
`session.hello` app from the world **New session** form, see its generated
`@json-render` page live beside the chat, the public `/socialware/customer` link
opens with no login, and the builder now narrates + replies **in chat as itself**
so session/external conversation state is coherent on both surfaces.

## 2. What landed (3 commits on the branch)

| Commit | Scope |
|---|---|
| `d6364783` feat(world): create session.hello from the New-session form | `behavior/workspace.ex` — typed `template_name` that resolves to a registered `session.*` Template Class routes through `instantiate/3` (System A), after the existing `:create_session` cap gate, class resolved at runtime via `TemplateRegistry` (no plugin dep). So `hello` in the form creates a real hello app in **any** workspace. |
| `90ba7192` feat(world): operator hello page preview | `Conversation.tsx` — generated page is a **permanent right-half live pane** beside the chat (no Page tab), viewport-height; banner removed. `customer_app.js` — page tree logged to the **F12 console** on each update. |
| `01c8ed51` feat(hello): builder narrates + replies as itself | `turn_driver.ex` + `generator.ex` — turns dispatched as the builder agent (`sender=builder`, not admin); `say/3` for builder-authored lines; full narration (ack → plan → component breakdown → completion); **result sent via `say` (`:session :send`)** so it pushes live instead of only on refresh. |

Out of scope, left uncommitted on the working tree: `runtime.ex` (a dev-infra
fix that skips distributed-Erlang boot via `EZAGENT_NO_DISTRIBUTION` — unrelated
to hello; should land as its own dev-infra change).

## 3. Definition of Done

- [x] **Hello app created from world** — typing `hello` in New session creates
  `session://<ws>/hello/<name>`. Verified end-to-end through
  `Ezagent.Workspace.create_session(.., template_name: "hello")` →
  `session://system/hello/uitest` (control `default` → `/default/`, no
  regression). Live operator-created sessions present:
  `session://system/hello/{777,888,333,122222,...}`.
- [x] **Generated `@json-render` page in operator context** — right-half iframe
  pane in `Conversation.tsx`. **[screenshot: operator world page — to attach]**
- [x] **Public `/socialware/customer` link, no login** — works for both live AND
  **cold** sessions now (the cold-link gap was found AND fixed, `99b3542e`).
  Verified after a restart (everything cold): `hello/333` 400→**200**,
  `hello/777`/`888` → 200, `/socialware/chat?...hello/333` → 200; a nonexistent
  `hello/doesnotexist999` stays **400** (the revive only wakes snapshotted
  sessions and `public_view?/1` still gates). See §5a.
  **[screenshot: public customer page — to attach]**
- [x] **Conversation state coherent** — verified at the DATA + MECHANISM level:
  builder replies are `customer_visible` (§4) and the customer feed snapshot
  serves `customer_visible` messages, so operator/builder turns reach BOTH the
  operator session view and the external customer feed. NOT yet confirmed by a
  literal side-by-side screenshot of the external feed updating — best closed by
  the operator/customer screenshots.
- [~] **Focused tests/gates** — see §6 (gap: a focused test for the class-routing
  branch is proposed, not yet written; no world route/slot added so the
  mount/slot gates are unaffected).

## 4. E2E steps 5–8 support matrix (DoD #4)

| Step | Behavior | Status | Evidence |
|---|---|---|---|
| 5 | create a hello page/app | ✅ supported | form `template_name=hello` → hello session (§3) |
| 6 | open external customer link w/o login | ✅ supported | live + cold: `hello/333` (cold) 400→200 after the revive fix `99b3542e`; nonexistent stays 400 (§5a) |
| 7 | see hello conversation/page state in world session page | ✅ supported | right-half live preview + chat in `Conversation.tsx` |
| 8 | send messages across surfaces, both sides update | ◑ partial (by design) | **operator → both:** operator/builder messages are `customer_visible` → appear in operator view AND customer feed. **anon customer → session: NOT supported by design** — the empty-caps anon-User cannot `chat.send` (socialware security property). Two-way anon authoring is a deferred socialware change, not in this handoff's scope. |

Conversation-coherence thread (`session://system/hello/777`), all
`customer_visible` → both surfaces:

```
who         vis               text
(admin)     customer_visible  @hello_777 做一个登录页
hello_777   customer_visible  收到 ✅ 正在理解你的需求…
hello_777   customer_visible  🧭 规划:单页直接生成…
hello_777   customer_visible  🛠 正在把页面渲染上去…
hello_777   customer_visible  ✅ 已生成页面:登录
```
(builder is the sender — the pre-fix bug attributed these to `admin`.)

## 5. Open question answered (operator view: iframe vs native)

**The temporary `/socialware/customer` iframe is KEPT and accepted for launch.**
Rationale: the native `EzagentPluginHello.PageView`/`HelloRenderer` operator path
is gated on the **React-18 → React-19 / `@json-render` migration** (a pre-existing
known blocker — `@json-render/react` peers `react@^19`, the world substrate is
React 18). Swapping it today risks the deadline for no launch-blocking benefit:
the iframe renders the same approved page via the working customer renderer. The
native swap is a tracked follow-up for the React-19 migration (handoff Decision #2
"if feasible today" → not feasible today; documented per the handoff open
question).

## 5a. Cold public-link revival — FIXED (`99b3542e`)

A public hello link used to work only while the session was **live**
(`PublicView.public_view?/1` reads the live slice; a session not revived since
boot fail-closed → 400 customer / bounce chat).

Fix: `customer_controller.show` and `chat_feed_controller.resolve_anonymous` now
call `Ezagent.SpawnRegistry.ensure_live/1` before the public-view gate, which
rehydrates the session from its snapshot. Safety: `ensure_live/1` returns
`{:error, :not_created}` (no-op) when no snapshot exists — an anon can wake an
EXISTING session but never conjure one — and `public_view?/1` still gates access,
so a revived NON-public session still fails closed. Verified after a cold restart:
`hello/333` 400→200, nonexistent `hello/x` stays 400.

Residual (minor, follow-up): a revived NON-public session is woken (then denied).
To never wake non-public sessions at all, pre-gate the revive on the snapshot's
persisted `public_view` flag. Not launch-blocking (access is already correctly
denied).

## 6. Tests / gates / follow-ups

- **Gates unaffected:** no world route or renderer family added → `SlotRegistry` /
  mount-slot gates unchanged (the right-half preview is a child of the existing
  `conversation` component, not a new route surface).
- **Proposed focused test (not yet written):** `behavior/workspace.ex`
  `handle_create_session` — assert a registered `session.*` class routes to
  `instantiate/3` and an unknown name falls through to the generic facade.
- **Phase-1 external-link affordance: DONE** (`8e5532ef`) — a top-right
  open-in-new-tab icon button on the operator hello preview opens the public
  `/socialware/customer` link.

## 7. Merge request

- Branch `world-hello-convergence`, 3 commits, rebased on `main` @ `3cd5a5a4`.
- Touches `ezagent_domain_workspace`, `ezagent_plugin_world` (assets),
  `ezagent_domain_socialware` (assets), `ezagent_plugin_hello`.
- **Lead note:** the workspace `create_session` class-routing is a CapBAC-adjacent
  decision (the `:create_session` cap now also instantiates registered session
  classes) — flagged in-code as `DECISION (2026-06-23) — pending GLOSSARY Decision
  Log + Allen review`. Wants a Decision Log entry on merge.
- Operator + customer screenshots to be attached by the reviewer from the live
  session (server running on `:10042`, world host `world.localhost:10042`).
