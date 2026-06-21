# `world` plugin — codex handoff

This is the handoff for a **codex self-driven build** of the `world` plugin. Allen drives codex; codex reviews the spec + plan, sets a goal, and self-drives all PRs onto the `world` branch.

## Inputs codex must read first (in order)

1. SPEC — `docs/superpowers/specs/2026-06-21-world-plugin-react-shadcn-spec.md` (decisions D1–D11, the 7-point gate §2, component inventory §7, phasing §9).
2. PLAN — `docs/superpowers/plans/2026-06-21-world-plugin-implementation-plan.md` (PR-by-PR execution).
3. Project skills/context — load the `ezagent-developer` skill (CapBAC, Kind/Behavior/Router, ui-contract, #154). Existing patterns to mirror: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/terminal.ex` + `assets/js/hooks/` (the phx-hook island precedent), `apps/ezagent_web/lib/ezagent_web/live_auth.ex` (caller/`:current_caps`), `apps/ezagent_plugin_liveview/lib/` (the 25 LV screens to reach parity with), `apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex` (cap/action declaration shape to copy).

## Working agreement (Allen's gate #6)

- **Fully self-driven** — do NOT pause for confirmation between steps.
- **PR per step**, each independently shippable, gate-green, with an agent-browser screenshot. **Merge every PR to the `world` branch.**
- Each PR's gate: relevant umbrella tests + `mix ezagent.check_invariants` + `mix ezagent.arch.scan` + `mix ezagent.doc.scan` + the cap-elimination gates (`system_principal_elimination`/`no_unowned`/`no_admin`/`no_wildcard`) + an agent-browser screenshot of the new/changed screen at `world.ezagent.chat`.
- **#154 hard rule**: no `system://` principal; every cap grant `granted_by` a real entity.

## Decisions already made (do NOT re-open) — see SPEC D1–D11

LV = SSR/comms shell (no prod Node tier) · React+shadcn owns rendering · component=code / layout=data · `world` is a new parallel plugin (don't touch `ezagent_plugin_liveview`) · dispatch via `%Invocation{}`/`Invocation.dispatch/1` with caps from `:current_caps` · Vite dev HMR / prod static · subdomain via `host: "world."` scoping.

## Human-assist prerequisites (codex cannot do these; proceed on dev without them)

1. **DNS + Cloudflare tunnel** for `world.ezagent.chat` — DOABLE LOCALLY (creds in `~/.cloudflared/`: cert.pem + tunnel `7339e970...` already routing `app.ezagent.chat → :10042`). Add ingress `world.ezagent.chat → http://localhost:10042` + `cloudflared tunnel route dns 7339e970-1a2b-4f03-84c9-a1ea50965eba world.ezagent.chat` + reload. ⚠ Mutates **prod DNS** → confirm with Allen before running. Dev does NOT need it: use agent-browser `--host-resolver-rules="MAP world.ezagent.chat <tailnet-ip>"` so all dev PRs proceed. **Verify this dev-access reaches the world scope as the FIRST action in PR-0.**
2. **B1 grantee** — default: grant `:manage` to the workspace admin entity (`entity://system/user/admin` for the system workspace). Proceed on this unless Allen overrides.

## The verification gate (set this as codex's /goal) — the 7 criteria, paste-able

> Done = ALL true, each demonstrated by an agent-browser screenshot or a passing gate on the `world` branch:
> 1. A new plugin `world` exists and serves at `world.ezagent.chat` (dev: via Host-resolver override).
> 2. `world` has a complete React+shadcn component set matching every `EzagentPluginLiveview.*` screen (25 modules; cross-check the router, not just the spec table).
> 3. The workspace admin can dynamically arrange the layout; it persists to `$EZAGENT_HOME/<profile>/world/layouts/`; the `:manage` cap (`Ezagent.World.Behavior.Layout`) defaults to the workspace admin entity; a non-authorized caller is denied.
> 4. Adding a new component = a code file under `world`'s component dir + registry entry; dev HMR shows it + the new layout without a full reload.
> 5. agent-browser screenshots confirm the key screens render.
> 6. Every step shipped as its own PR, all merged to `world`.
> 7. (Claude verifies) — after codex finishes, Claude checks out `world` and reviews against 1–6.

## The prompt to give codex (paste this)

```
You are building the `world` plugin for ezagent — the next-gen React/shadcn app over a
LiveView SSR/comms shell. Work fully self-driven on the `world` branch: PR per step, each
gate-green with an agent-browser screenshot, all merged to `world`, no waiting for
confirmation.

FIRST, read and confirm you understand, then critique (flag anything wrong/risky before coding):
  - docs/superpowers/specs/2026-06-21-world-plugin-react-shadcn-spec.md
  - docs/superpowers/plans/2026-06-21-world-plugin-implementation-plan.md
Load the ezagent-developer skill. Mirror existing patterns: pty/terminal.ex + assets hooks
(phx-hook island), live_auth.ex (caller/:current_caps), behavior/surface.ex (cap/action shape).

Honor the locked decisions D1–D11 (esp: NO prod Node tier; dispatch via %Invocation{}/
Invocation.dispatch/1 not %Cmd{}; #154 no system:// principal; don't touch
ezagent_plugin_liveview). Dev subdomain access = agent-browser
--host-resolver-rules="MAP world.ezagent.chat <tailnet-ip>"; verify it reaches the world
scope FIRST in PR-0.

Execute the plan PR-by-PR (PR-0 scaffold+subdomain+Vite/React/shadcn+phx-hook bridge → PR-1
comms contract on sessions_table → PR-2 layout cap+LayoutManager+editor → PR-3..N component
parity → PR-final polish+verify). Each PR: implement → tests + check_invariants + arch.scan +
doc.scan + cap-elimination gates green → agent-browser screenshot → commit → merge to `world`.

Your goal is done when the 7 verification criteria (spec §2 / handoff) are all met on `world`.
If you hit a human-assist prerequisite (DNS/tunnel for prod, or a B1 owner-model override),
note it and continue on the dev path / the documented default — do not block.
```

## After codex finishes

Claude switches to `world`, runs the full gate suite + agent-browser screenshots, and reviews against the 7 criteria; reports parity gaps / #154 violations / any deviation from the spec.
