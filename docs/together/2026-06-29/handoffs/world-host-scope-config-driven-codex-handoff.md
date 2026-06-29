# Handoff — world host-scope config-driven (dev `world.` / deploy apex) + no-hardcoded-domain gate (codex)

**To:** codex  ·  **From:** coordinator (Claude)  ·  **Date:** 2026-06-29
**Repo:** `/Users/h2oslabs/Workspace/esr-ng` (ezagent42/ezagent)

## The bug (verified during #110 internal testing)
On the public deploy (`app.ezagent.chat`), the operator console is **unreachable** — `app.ezagent.chat/admin` → 404, and the only reachable surface is the socialware customer landing page. Root cause: **all operator routes are scoped under a hardcoded `host: "world."`** so they only match a `world.` subdomain, and `world.app.ezagent.chat` has no DNS/tunnel in deploy.

`apps/ezagent_web/lib/ezagent_web/router.ex:32`:
```elixir
scope "/", EzagentPluginWorld, host: "world." do
  ...
  live "/admin", WorldLive
  live "/sessions", WorldLive
  live "/identities", WorldLive
  live "/identities/agents/new", WorldLive
  ...
end
```
This works in local dev (`world.localhost:4000`) but breaks deploy (public domain is the apex `app.ezagent.chat`).

## Lead decision (the fix shape)
**Do NOT add a `world.*` subdomain to deploy.** Make the host-scope **config-driven**: keep `world.` in local dev, but in deployment serve the world (operator) routes on the **apex** domain (`app.ezagent.chat`). The apex then serves BOTH the socialware customer routes (`/socialware/*`) AND the operator routes (`/admin`, `/sessions`, `/identities`, …) — they path-disambiguate, no collision. Plus add a gate forbidding hardcoded deploy domains in prod code.

## Handoff contract
- Target branch `fix/world-host-scope-config-driven` off `origin/main` (fresh `git fetch origin`; main tip `04b2340c`). Worktree under `.worktrees/`.
- **Self-merge all commits onto the target branch (commit per step, push incrementally). Do NOT merge to main, do NOT open a PR.** Return the target branch to the coordinator for accept+merge (coordinator then redeploys via deploy-flow + verifies `app.ezagent.chat/admin` serves WorldLive).
- `Skill: ezagent-developer` + `elixir-phoenix-helper`.
- **Goal: full gates green incl the socialware P10 E2E + the new no-hardcoded-domain gate.** Self-drive to green.

## The work

### 1. Config-driven host scope (the core fix)
- In `apps/ezagent_web/lib/ezagent_web/router.ex:32`, replace the literal `host: "world."` with a value read from config — e.g. a module attr `@world_host_scope Application.compile_env(:ezagent_web, :world_host_scope, "world.")` (or a runtime read if a compile-time read can't express it; a Phoenix `scope` `host:` opt can take `nil` = no host restriction → serves on every host incl apex).
- **dev/test:** `world_host_scope = "world."` (keep `world.localhost` — set in `config/dev.exs` + `config/test.exs`).
- **prod (deploy):** `world_host_scope = nil` (no host restriction → operator routes serve on the apex `app.ezagent.chat`). Set in `config/runtime.exs` (prod branch) or `config/prod.exs`, overridable by an env var (e.g. `WORLD_HOST_SCOPE`) so the deploy can tune it without a rebuild.
- **Verify no path collision** between the apex's existing customer routes and the operator routes once both serve on apex. The customer scope (router.ex:71/128/168/195/248 `EzagentWeb`) + the world operator scope must not have overlapping paths. (`/socialware/*`, `/api/*`, `/plugin-assets/*` are EzagentWeb; `/admin`,`/sessions`,`/identities`,`/workspaces`,`/plugins`,`/profile` are world — verify disjoint; the catch-all `/` LiveView mount is the one to check carefully — there may be an apex `/` route AND a world `/` route → when world scope becomes host-nil, decide precedence. The apex `/` today is login/customer; world `/` is WorldLive dashboard. You must keep login reachable on apex `/` for unauthenticated users AND WorldLive for authenticated operators — check how the existing scopes order/guard this; likely the RequireEntity plug on the world scope already gates it, but confirm the route-match order doesn't shadow login.)

### 2. Fix all hardcoded `world.` deploy-domain refs
- `config/runtime.exs:72` `check_origin` lists `"https://world.ezagent.chat"` — this becomes wrong if operator serves on apex. Update check_origin to the apex (`https://app.ezagent.chat`) + keep tailnet/localhost origins; make the domain list env-driven where it bakes a deploy domain.
- `config/config.exs:39-45` `session_cookie_domain: ".ezagent.chat"` + `url: [host: "localhost"]` — the cookie domain `.ezagent.chat` is fine (shared across subdomains), but verify the operator-on-apex serves with a cookie valid for `app.ezagent.chat` (it is, `.ezagent.chat` covers apex). 
- grep `world\.` across `apps/ezagent_web/lib`, `apps/ezagent_plugin_world/lib`, `apps/ezagent_plugin_world/assets/src`, `config/` for any other baked `world.<domain>` host/url/link assumption (canonical URLs, redirects, WS origins). **Keep** `world.localhost` in dev config + tests; **keep** non-host `World.`/`world_`/`world/`/`world.css` (those are module/path names, not hosts).

### 3. Add the no-hardcoded-deploy-domain gate (lead's ask)
- Add an arch-gate / invariant (in `mix ezagent.arch.scan` — see `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex`, the `grep(~r/.../)` counter pattern at ~line 284) that **forbids a hardcoded deploy domain / host literal in non-test, non-dev-config prod code**. Concretely: forbid a literal `"world."` host-scope in `router.ex` (must be config-driven), and forbid literal deploy-domain strings (`ezagent.chat` host literals) in `lib/` (config files + tests + `check_origin` allowlist exempt; `world.localhost` exempt). Use the established `# arch-allow:` suppression + a baseline count so existing legitimate refs (config) don't trip it. The gate FAILS if someone re-bakes a literal deploy host in prod lib code.

## Verify (the goal)
- `mix compile --warnings-as-errors`, `mix ezagent.arch.scan` (incl the new gate), `mix ezagent.check_invariants`(+`.lifecycle`), `mix ezagent.uri_query.scan`, `mix ezagent.doc.scan` — all green.
- **socialware P10 E2E gate** (`apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs`) still green — the operator/world routes must still resolve in the TEST env. If the test or any world test relies on `host: "world."`, ensure `world_host_scope = "world."` in `config/test.exs` so the scope still matches `world.localhost` in tests.
- `apps/ezagent_plugin_world/test` green (esp any `WorldHostRouting` test — note: there's a known-flake by that name; distinguish a real failure from the flake by running it in isolation).
- Known flakes (PluginIsolation/AnonUserGC/PresenceReadReceipts/WorldHostRouting/AgentReadTest/DefaultSessionTemplateSeed) — note-only; any OTHER failure = real = fix.

## Hand-back
Push `fix/world-host-scope-config-driven`; report:
1. The config mechanism (how dev=`"world."` / prod=apex-nil is selected; the env var name).
2. Every hardcoded-world/deploy-domain ref found + fixed (file:line).
3. The new gate (file + what it forbids + the allowlist/baseline).
4. Gate results (incl P10 E2E + world tests; note any known-flake-only reds).
5. **How the coordinator verifies after redeploy**: post-merge, coordinator rebuilds nightly→beta→stable; `app.ezagent.chat/admin` should serve WorldLive (operator console), `app.ezagent.chat/` keeps login/customer, `app.ezagent.chat/identities/agents/new` reachable for create-agent.
6. Any OQ.
**STOP — do not merge, do not open a PR. Coordinator accepts + merges + redeploys.**

## If you stall (usage cap / transient)
Commit-before-every-step + push incrementally so the coordinator can pick up partial work. The previous attempt produced zero output (hit a usage cap before writing code) — commit early.
