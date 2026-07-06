# Lead GO — world 通用消费 SessionViewRegistry (jjkysy #1192)

**For jjkysy.** This is the lead ratification + locked decisions for your `#1192` plan. Your `handoff.md` + `spec.md` + `plan.md` (branch `feat/sw-world-views`) are **approved as the implementation basis** — this doc does not replace them, it locks the open decisions and the process so you can start.

## Verdict
Approved. You correctly identified a real gap: the `SessionView` contract + `Ezagent.UI.SessionViewRegistry` exist and pty/routing/external_mirror/hello-page all register into them, but **world never reads the registry** — it hardcodes Chat/PTY tabs and force-mounts hello's page via an `is_hello` boolean. Your two-plane split (generic tab-enumeration via `applicable_views/2` + mode-dispatched rendering because `SessionView.render/1` returns HEEx that a React SPA can't render) is the right shape, and the honest `unsupported` placeholder (never silently hide) is exactly right.

## Locked decisions (Allen)
1. **`is_hello` / "temp bespoke hack" must be fully REMOVED, not left parallel.** The whole point is that the special-case folds into the generic registry-driven path. Your plan already deletes `is_hello` + `page_session?` dead code (Stage 1) and the `isHelloSession` right pane (Stage 2) — keep that; a green run that still contains a hello special-case is not done.
2. **PTY tab conditional (only when a live PTY member exists) = correct behavior.** Ship it. It's a real fix, flag it in the PR as an intended visible change, not a regression.
3. **hello Page: always-on right pane → a cap-gated switchable tab = fine.** Ship it.
4. **routing / external_mirror React renderers = OUT OF SCOPE for #1192.** See "The routing/external_mirror question" below. For #1192 they render as the honest `unsupported` placeholder. Building their React renderers is a **separate follow-up** (its own handoff), because they are not socialware views and gating this work on them would bloat scope. Land #1192 with placeholders; we spin the renderers separately if we still want them.

## The routing/external_mirror question (why they're here at all)
They are **registered SessionViews that are NOT socialware** — `routing` is the session's routing-rules surface, `external_mirror` is the external-adapter mirror surface; both are session/behavior views that happen to live in the SAME `SessionViewRegistry`. #1192's job is to make world consume that registry *generically*, so it surfaces **every** registered view — chat, pty, hello-page, and also these two. They only appear because the consumption is generic; they have no special relationship to socialware view-rendering. That's exactly why their React renderers are a separate concern: #1192 delivers "world renders any registered view (or an honest placeholder)"; whether routing/external_mirror deserve a real React surface is an independent product call.

## Lead requirements (in addition to your plan's DoD)
- **Rebase onto current `origin/main` before you start.** Your branch is based on `bf5e03e9`, which predates the CI fixes (#1189) and the reputation receipt (#1193). Current main is `95f6b85f9`. Rebase so your CI actually runs the fixed `full-suite`. (No conflicts expected — you only touch `apps/ezagent_plugin_world/`.)
- **CI is now real and required.** Every PR must pass `gate (deterministic)` + `full-suite (self-hosted macOS)`. Your Stage-1..4 ExUnit gates + Stage-5 Playwright e2e are the pre-push evidence; the PR's `full-suite` is the authoritative re-validation. `mix ci.local` runs the exact same flow locally.
- **cap-gate regression lock is mandatory (your Stage 4).** The single biggest risk in "world enumerates views" is world bypassing `authorize_view/3`. Keep the integration test proving a cap-gated view emits NO tab and cannot be switched-to for an unauthorized/anon caller. This is the security property; it does not ship without it.
- **Scope discipline holds:** only `apps/ezagent_plugin_world/` + the one `ezagent_domain_ui` umbrella dep. Do not touch core / session / hello / socialware. `ezagent_domain_ui` (registry owner) needs 0 changes (`applicable_views/2` + `external_render?/1` are sufficient) — if you find you need to change it, STOP and flag me first.
- **Real-browser e2e, no stubs** (your Stage 5): prove ① a fresh TestView auto-appears as a tab with zero world render-logic change, ② hello session shows Chat/PTY/Page with Page rendering real content, ③ anon/non-member without `hello_render` → Page tab absent (cap gate really controls), ④ tab switch changes content. Screenshots per stage.

## Process
Implement on `feat/sw-world-views` (rebased). Commit + push, open a PR against `main`; it runs gate + full-suite. I (lead) review against this doc + your DoD and merge on green — you don't self-merge to main. If you hit a design fork (esp. the cap-gate surface or the HEEx→React mode classification being ambiguous for a view), STOP and flag rather than guess.

## Not in this work (explicitly)
- routing/external_mirror React renderers (separate follow-up).
- Any socialware Definition / recipe / role change — role-slot #1180/#1185/#1194 already landed and is unrelated.
- Registry distribution/install (P1/P2 #1173/#1176) — that's the socialware install side, unrelated to this UI view registry.
