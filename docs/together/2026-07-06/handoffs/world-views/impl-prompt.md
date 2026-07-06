# Implementation prompt — world generic SessionView consumption (#1192)

**Paste this into your coding agent (opus) to implement #1192.** It is self-contained; it points at the three authoritative docs already on `main`.

---

You are implementing "world generically consumes `Ezagent.UI.SessionViewRegistry`" in the ezagent Elixir umbrella. This is real production frontend+backend code in `apps/ezagent_plugin_world/`. Work carefully and test at each stage.

## First, load context
1. Load skills: `Skill: ezagent-developer`, then `Skill: elixir-phoenix-helper`.
2. Read these three docs (all on `origin/main`) — they ARE your spec, do not re-derive:
   - `docs/together/2026-07-05/handoffs/world-views/spec.md` — the sectioned dev spec (the real design).
   - `docs/together/2026-07-05/handoffs/world-views/plan.md` — the TDD task-by-task plan. Follow it.
   - `docs/together/2026-07-06/handoffs/world-views/lead-go.md` — the lead's locked decisions + requirements. These override any ambiguity in spec/plan.

## The task in one line
world's session panel currently hardcodes Chat/PTY tabs and force-mounts hello's page via an `is_hello` boolean. Make world instead ask `SessionViewRegistry` (via `applicable_views/2`) which views this session+user can see, emit one tab per view, and render each by its declared mode. After this, registering a new SessionView makes a tab appear in world with **zero** world code changes.

## Setup (do this before Stage 1)
- **Rebase the branch onto current `origin/main` first.** `feat/sw-world-views` is based on the old `bf5e03e9`, which predates the CI fixes (#1189) and the reputation receipt (#1193). Rebase onto current main (`e5c39685d` or newer) so CI runs the fixed `full-suite`. No conflicts expected (you only touch `apps/ezagent_plugin_world/`).
- Confirm a dev Postgres is reachable at `127.0.0.1:55432` (role/db `ezagent_pg_compat`); `MIX_ENV=test MIX_TEST_PARTITION=$USER` for tests.

## Locked decisions (from lead-go.md — non-negotiable)
1. **Delete the `is_hello` / bespoke hack entirely** — it must fold into the generic path, not sit alongside it. A green run that still special-cases hello is NOT done. (Delete `is_hello` bool + `page_session?` dead code + the `isHelloSession` right pane.)
2. **PTY tab becomes conditional** (only when a live PTY member exists) — this is correct; flag it in the PR as an intended visible change.
3. **hello Page: always-on right pane → cap-gated switchable tab** — correct; ship it.
4. **routing/external_mirror render as the honest `unsupported` placeholder** (they're HEEx-only, not socialware, out of scope for their own React renderers here). Never silently hide them.

## Build it (follow plan.md's 5 stages)
- **Stage 1 — server reads registry:** add `{:ezagent_domain_ui, in_umbrella: true}` dep; register a world-owned `Ezagent.World.ConversationView` (chat into the registry, visible to all, not cap-gated); `SessionViewRegistry.init()` + register in `Application.start/2`; `ConversationData.session_views/2` + `render_mode/2` reading `applicable_views/2`; emit a `"views"` array in `state_for/2`, delete `is_hello`/`page_session?`.
- **Stage 2 — React render:** `Conversation.tsx` renders dynamic tabs from `state.views` (lucide icon lookup + fallback); content dispatches by the active view's `mode` → `chat`/`pty`/`external`(iframe `/socialware/external`)/`unsupported`(placeholder). Generalize `HelloPagePreview` → `ExternalSurfaceView` (keep open-in-tab + publish controls), delete the `isHelloSession` right pane.
- **Stage 3 — cap gate:** `switch_view/3` whitelist changes from hardcoded `["chat","pty","page"]` to the dynamic `session_view_ids(session, user)` set; an id not in the enumerated set → `error:bad_view`.
- **Stage 4 — regression + cap lock (MANDATORY):** an integration test proving a cap-gated view emits NO tab and cannot be switched-to for an unauthorized/anon caller (proves world does not bypass `authorize_view/3`). This is the security property; it does not ship without it. Plus no regression in existing world visibility tests.
- **Stage 5 — real-browser e2e (no stubs):** register a dev/test-only `Ezagent.World.TestView` (env-guarded); bring up the real stack (Postgres + migrate + assets build + `mix phx.server` @ 10042); Playwright, real login `admin@ezagent.chat`/`worlddev`; prove ① TestView auto-appears as a tab with zero render-logic change, ② hello session shows Chat/PTY/Page with Page rendering real content, ③ anon/non-member without `hello_render` cap → Page tab absent, ④ tab switch changes content. Screenshot each step into `e2e/2026-07-06/world-views/`.

## Scope discipline
- Touch ONLY `apps/ezagent_plugin_world/` + the one `ezagent_domain_ui` umbrella dep. Do NOT touch core / `ezagent_domain_session` / `ezagent_plugin_hello` / `ezagent_domain_socialware` / any other plugin. `ezagent_domain_ui` needs 0 code changes (`applicable_views/2` + `external_render?/1` suffice) — if you think you need to change it, STOP and flag.

## Gates before hand-back
- `mix compile --warnings-as-errors --force`, `mix format --check-formatted`, the world app suites green (`mix test apps/ezagent_plugin_world/test`), the assets build clean (pnpm, no TS errors), plus your Stage-5 e2e + screenshots.
- Then push and open a PR against `main`; it runs `gate` + `full-suite` (the authoritative re-validation). `mix ci.local` runs the same flow locally.

## Hand-back
Commit (trailer: copy the `Co-Authored-By` + `Claude-Session` lines from a recent `git log`), push `feat/sw-world-views`, open the PR, and return: the change inventory, the cap-gate regression test + its result, the e2e results + screenshots, gate results, and any design fork you hit (STOP + report rather than guess — especially if a view's HEEx→React mode is ambiguous, or the cap-gate surface isn't cleanly reusable). Do NOT self-merge to main; the lead reviews + merges on green.
