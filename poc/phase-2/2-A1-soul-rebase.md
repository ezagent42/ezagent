# Phase 2.2 — EXP-A1 soul-injection rebased onto Phase 2 (agent_bridge) + tenant-parameterized

## Goal

Bring the EXP-A1 mechanism (cc.agent Template `soul_path` arg → `--append-system-prompt`) onto Phase 2's branch (which now sits on top of the agent_bridge refactor series), and **remove all tenant-specific literals** so the same code serves any tenant via configuration.

## Result

**Soul injection works on Phase 2.** A live claude process spawned via `Workspace.create_agent(... soul_path: "<path>")` carries the soul as a single `--append-system-prompt <contents>` argv element. Red-line greps for tenant-hardcoded values come back empty for my diff.

## Files changed (production code under `apps/*/lib/`)

| File | Δ | What |
|---|---|---|
| `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` | +52/-2 | Add `soul_path` to `@optional_sandbox_keys`; new `build_soul_args/2` reads `tmpl["soul_path"]` at spawn and emits `["--append-system-prompt", <file-contents>]`. Missing/unreadable file → no flag (warning log). |
| `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex` | +43/-2 | Thread `soul_path: {:option, :string}` through `interface/0`, `coerce_create_args/1` (now 7-tuple), `do_create_agent("cc", _)`, and into the cc template via `maybe_put_soul_path/2`. |

Tenant-agnostic: no new literal `"acme"`, no new `"workspace://X"` URI, no new `"entity://agent/X/Y"` URI in lib/. Verified by red-line greps below.

## Files changed (test fixtures + setup scripts, NOT lib/)

| File | What |
|---|---|
| `poc/fixtures/plugins/acme/souls/customer.md` | Soul fixture for the `acme` tenant test sandbox. Path mirrors AutoService's `plugins/<tenant>/souls/<role>.md` convention. |
| `poc/phase-2/setup.exs` | Parameterized via env: `TENANT` (default `acme`), `ROLE` (default `customer`), `AGENT_NAME` (default `cs_main`), `AGENT_CWD`, `SOUL_PATH`. Tenant-specific defaults exist only as fall-throughs for local dev. |
| `poc/phase-2/probe_trigger.exs` | Same env parameterization (`TENANT`, `AGENT_NAME`). |

## Cherry-pick: conflicts encountered + resolution

`git cherry-pick origin/poc/exp-A1-soul-as-template-arg` produced 2 conflicts:

1. **`apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` (content conflict)** — Phase 2 base and EXP-A1 both edited the argv-build site at `build_claude_cmd/3`. Trivial: kept the EXP-A1 form (`... ++ soul_args ++ settings_mcp_args`). The surrounding hardening (claude_path absolute resolution, env handling) had already landed upstream — EXP-A1's hunks slotted in cleanly above/below.
2. **`poc/phase-0/setup.exs` (modify/delete)** — EXP-A1 modified the file; Phase 2 base had renamed/relocated to `poc/phase-2/setup.exs`. Resolved by deleting the EXP-A1 modification (the phase-0 setup is obsolete on Phase 2's branch). Manually ported EXP-A1's intent (`soul_path: <path>` in the create_agent kwarg) into `poc/phase-2/setup.exs` with tenant-parameterization.
3. **`poc/exp-A1/FINDINGS.md`** — discarded (this doc supersedes it; previous findings preserved at the original branch).
4. **`poc/fixtures/acme-soul.md`** — moved to `poc/fixtures/plugins/acme/souls/customer.md` to match AutoService convention. The location is a TEST fixture (allowed per design constraint §1); production deployments set `SOUL_PATH` to their own path.

The lib/ diff produced by my cherry-pick is functionally identical to EXP-A1's original lib/ diff. No semantic carry-over from the agent_bridge refactor was needed.

## De-hardcoding (Phase 2.2's main contribution beyond raw cherry-pick)

EXP-A1 itself was already free of tenant-hardcoded lib/ code (the magic Acme string lived in the Phase 0 hack site which EXP-A1 deleted). Phase 2.2's additional work was at the **call-site / fixture layer**:

| Before | After | Why |
|---|---|---|
| `agent_cwd = Path.expand("~/poc-sandbox-phase2/acme")` (literal) | `agent_cwd = System.get_env("AGENT_CWD") \|\| Path.expand("~/poc-sandbox-phase2/#{tenant}")` | Tenant is now the parameter; the path is derived from it. |
| `URI.parse("entity://agent/acme/cc_cs_main")` in probe_trigger | `URI.parse("entity://agent/#{tenant}/cc_#{agent_name}")` | Same. |
| Soul fixture path baked into setup as `../fixtures/acme-soul.md` | `Path.expand("../fixtures/plugins/#{tenant}/souls/#{role}.md", __DIR__)` (overridable via `SOUL_PATH` env) | Layout mirrors AutoService `plugins/<tenant>/souls/<role>.md`; future tenants drop files into the same shape, no script edit. |
| `Ezagent.Workspace.create("acme", %{})` in setup | `Ezagent.Workspace.create("#{tenant}", %{})` (`tenant` is `System.get_env("TENANT") \|\| "acme"`) | Defaults make local dev a one-liner; the `acme` default is a fixture-only sandbox per `/poc/fixtures/plugins/acme/`. |

## Design choice: where does the soul file live in production?

EXP-A1's spec left the production location as an open question. Phase 2.2 picks **per-tenant directory under `plugins/<tenant>/souls/<role>.md`** (mirroring AutoService) for the fixture/example, and exposes `SOUL_PATH` as an env override so operators can point elsewhere (e.g. `~/.ezagent/<profile>/souls/<tenant>/<role>.md` for operator-config layouts).

Reasoning:
- **AutoService convention reuse** — Phase 2's eventual goal is hosting the AutoService customer-service flow. Mirroring `plugins/<tenant>/souls/<role>.md` means migration from AutoService just copies files into the same relative layout.
- **Filesystem stays out of `apps/*/lib/`** — the soul file is purely a `Workspace.create_agent` argument; lib/ never has to know where it came from. This keeps the production code soul-location-agnostic, matching constraint §1's "tenant-specific data lives in config, not code."
- **`SOUL_PATH` env escape hatch** — operators who want their own filesystem layout (e.g. `/etc/ezagent/souls/`) override the default per `make`/systemd unit. The setup script is just a dev convenience.

Not chosen: cramming the soul content into the call site (would need re-baking on every text edit) or storing in ezagent's DB (adds a soul-store concern that EXP-A1 explicitly avoided).

## Static-inspect + dynamic-inspect proof

**Static (from server log when spawn failed transiently due to host-env quirk — see "Surprise" below):**

```
State: %Ezagent.Domain.Pty.Server{
  agent_uri: %URI{... path: "/acme/cc_cs_main"},
  cmd_override: [
    "/opt/homebrew/bin/claude",
    "--permission-mode", "bypassPermissions",
    "--dangerously-load-development-channels", "server:esr-bridge",
    "--append-system-prompt",
    "You are Acme Corp's customer support agent.\n\n## Facts\n- Laptops: 12-month warranty, 24-month for Pro line\n- Phones: 6-month warranty, no extension\n- Repair turnaround: 3 business days standard\n\n## Tone\n- Friendly but precise. Don't promise what isn't above.\n- If user asks about products not listed, say \"I'll need to check with my team.\"\n",
    "--settings", "/Users/daiming/workspace/ezagent42/ezagent-poc-phase-2-A1/_build/dev/lib/ezagent_plugin_cc/priv/claude-pty-settings.json",
    "--mcp-config", "/Users/daiming/poc-sandbox-phase2/acme/.mcp.json"
  ],
  ...
}
```

The `cmd_override` list is exactly what the PTY runner hands to erlexec/execve — proof that soul-injection reached the claude argv. The `_build/dev/lib/ezagent_plugin_cc/...` path confirms it came from THIS worktree's compile, not a stale sibling worktree.

**Dynamic (live claude PID 34930 after server restart with cleaned env):**

```
$ ps -p 34930 -o command=
/opt/homebrew/bin/claude
  --permission-mode bypassPermissions
  --dangerously-load-development-channels server:esr-bridge
  --append-system-prompt
  You are Acme Corp's customer support agent.\012\012## Facts\012
    - Laptops: 12-month warranty, 24-month for Pro line\012
    - Phones: 6-month warranty, no extension\012
    - Repair turnaround: 3 business days standard\012\012## Tone\012
    - Friendly but precise. Don't promise what isn't above.\012
    - If user asks about products not listed, say "I'll need to check with my team."\012
  --settings /Users/daiming/workspace/ezagent42/ezagent-poc-phase-2-A1/_build/dev/lib/ezagent_plugin_cc/priv/claude-pty-settings.json
  --mcp-config /Users/daiming/poc-sandbox-phase2/acme/.mcp.json
```

`\012` is `ps`'s representation of a newline preserved INSIDE one argv element (argv-form execve, no shell). The `## Facts` / `## Tone` markdown headers are unique to the fixture file — Phase 0's hardcoded one-paragraph soul had no headers — so this is decisively the file's contents, not stale state.

## Red-line greps (constraint §1 verification)

Ran on the worktree at HEAD = `poc/phase-2-A1-soul-rebased`:

```
$ git diff main -- 'apps/*/lib/' | grep -E '^\+.*"(acme|cinnox)"'
(empty — no tenant literals introduced by my diff)

$ git diff main -- 'apps/*/lib/' | grep -E '^\+.*"workspace://[a-z_-]+"'
(empty)

$ git diff main -- 'apps/*/lib/' | grep -E '^\+.*"entity://agent/[a-z_-]+/'
(empty)
```

Full-scan red-line 1 across all apps/*/lib/ found two pre-existing hits in `apps/ezagent_web/lib/ezagent_web/controllers/onboarding_controller.ex` (HTML `placeholder="acme"` form hints — UI affordance, not data). Not introduced by this PR; not in scope to fix.

## Subtle differences from original EXP-A1

| | Original EXP-A1 | Phase 2.2 |
|---|---|---|
| Setup script location | `poc/phase-0/setup.exs` (modified existing) | `poc/phase-2/setup.exs` (already separate per Phase 2 base) |
| Fixture path | `poc/fixtures/acme-soul.md` (flat, named for tenant) | `poc/fixtures/plugins/acme/souls/customer.md` (tenant-tree, role-named) |
| `EZAGENT_RUNTIME_NODE` plumbing | EXP-A1 added this kwarg-style to setup | Phase 2 setup got the same shape independently; my edit kept it |
| Tenant parameterization in setup | Hardcoded `acme` | `TENANT` / `ROLE` / `AGENT_NAME` / `AGENT_CWD` / `SOUL_PATH` env, defaults to `acme`/`customer`/`cs_main` |

The lib/ diff itself is byte-equivalent to EXP-A1's lib/ diff modulo the conflict resolution at `build_claude_cmd/3` (which collapsed cleanly).

## Verification env (what I ran)

```
EZAGENT_PROFILE=poc-phase2-a1
PORT=10122
EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2_a1@127.0.0.1
EZAGENT_BRIDGE_WS_URL=ws://127.0.0.1:10122/agent_bridge/websocket  # Phase 2.0 finding workaround
MIX_DEPS_PATH=/Users/daiming/workspace/ezagent42/.poc-shared-deps   # no deps.get
```

Setup invocation:

```
TENANT=acme ROLE=customer AGENT_NAME=cs_main \
  EZAGENT_RUNTIME_NODE=ezagent_runtime_phase2_a1@127.0.0.1 \
  elixir --name "phase2_a1_setup@127.0.0.1" \
    --cookie "$(cat ~/.ezagent/poc-phase2-a1/runtime/cookie)" \
    poc/phase-2/setup.exs
```

(Tenant defaults are all `acme`/`customer`/`cs_main` so a bare invocation reproduces the verification scenario.)

## Surprise / blocker found en route

**Empty-value env vars in the host shell crash erlexec spawn.** First setup run failed with `{:spawn_failed, ~c"env - invalid env argument #7"}`. The 7th entry passed to `:exec.run/2 {:env, _}` is the 7th `:os.getenv()`-derived var; on my Mac running inside Claude Code, three host env vars (`USE_LOCAL_OAUTH`, `USE_STAGING_OAUTH`, `ANTHROPIC_API_KEY`, `CLAUDE_CODE_DISABLE_CRON`) had empty string values, which erlexec refuses. Workaround: `unset` those vars before `mix phx.server`. **This is pre-existing PTY/erlexec behavior unrelated to my soul-injection change** — it would fail the same on the parent phase-2 branch with this host env. Worth filing against ezagent as a defensive PTY-layer filter (skip `{k, ""}` entries before handing to erlexec).

**Cookie collision noise.** Initial `&`-backgrounded `mix phx.server` started before `ezagent.home.init` had finished writing the cookie file, so the BEAM generated a random cookie and the CLI couldn't connect. Restart-in-order resolved it. Adding a small `sleep` between `home.init` and `phx.server` in any setup recipe would prevent this.

**Branch noise from `--cookie "$(cat ...)"`.** Two cases where the shell substitution silently produced an empty string (whitespace, missing file) sent the wrong cookie to elixir CLI. Once the file was reliably present, both literal-cookie and `--cookie "$(cat ...)"` worked. Not a code bug, but a recipe footgun.

## What's NOT in scope (deferred)

- `coerce_create_args/1` is now a 7-tuple — EXP-A1's "code smell" callout. Phase B (Soul Editor / 4-layer composition) should refactor before adding any more knobs. Not done here.
- Soul hot-reload (file edit → live agent picks up). Not in scope — EXP-A1's static-soul model is the contract; mutability is Phase E territory.
- `EZAGENT_BRIDGE_WS_URL` defaulting to port 10042 — recorded in Phase 2.0 as a separate ezagent issue, not touched here.
