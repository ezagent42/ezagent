# T7 Step 2 — product-path proof (local, lead-authorized)

Worktree `.worktrees/cc-custom-backends` @ `d9e429b9e` (`feat/cc-custom-backends`). All commands run against a locally booted dev node from THIS worktree. Keys sourced via `set -a; . ~/.ezagent/default/credentials/cc-custom.env; set +a` — values never printed; transcripts grep-proven (see README).

## Environment

| Item | Value |
|---|---|
| DB | fresh dev DB (`mix ecto.drop/create/migrate`, disposable per repo norm) |
| Server | `PORT=10042 MIX_ENV=dev mix phx.server`, `EZAGENT_SIGNING_SEED_V1=$(openssl rand -hex 32)` (throwaway per-run), `EZAGENT_PAT_PEPPER_V1` (throwaway, needed for CLI token verify) |
| Ambient env | run 2 (the proof run) booted with `env -u ANTHROPIC_API_KEY -u ANTHROPIC_BASE_URL -u ANTHROPIC_MODEL -u ANTHROPIC_DEFAULT_* -u CLAUDE_CODE_SUBAGENT_MODEL -u CLAUDE_CODE_EFFORT_LEVEL ...` — the ONLY auth material the agents see is the profile's (this shell session itself runs on a custom backend; run 1 without the scrub showed claude's "Both ANTHROPIC_AUTH_TOKEN and ANTHROPIC_API_KEY set" warning, so the definitive evidence is run 2's) |
| epmd | `epmd -daemon` (required for the `ezagent_runtime` distribution claim; first boot failed `econnrefused` without it) |
| CLI auth | `mix ezagent.user.token entity://system/user/admin --mint` (bootstrap carve-out), `EZAGENT_USER_TOKEN` for every `mix ezagent` RPC call |
| Browser | headless Chromium via Playwright (world UI at `http://127.0.0.1:10042`) — vite + esbuild + tailwind assets built in-worktree (`pnpm install` + `pnpm build` + `mix tailwind ezagent_web`) |

## Boot proof — the seeded cc-orchestrator is cc-custom + deepseek

`mix ezagent agent_template read --agent-template template://system/agent/cc-orchestrator` (product CLI, in the running node):

```json
"content": {
  "name": "cc-orchestrator",
  "role": "orchestrator",
  "provider": "deepseek",
  "flavor": "cc-custom",
  ...
}
```

The T5 seed flip is live in the booted node: the orchestrator AgentTemplate boots on flavor `cc-custom` with provider profile `deepseek`.

## Agent 1 — cc-custom PTY on `deepseek` (create + cold restart + chat round-trip)

### Create (product dispatch surface: agent_template fork → write → instantiate)

```bash
mix ezagent agent_template fork --agent-template template://system/agent/cc-orchestrator \
    --new-name t7-ds-pty --owner entity://system/user/admin
# => {"template_uri": "template://system/agent/t7-ds-pty"}

mix ezagent agent_template write --agent-template template://system/agent/t7-ds-pty \
    --content '{"name":"t7-ds-pty","flavor":"cc-custom","provider":"deepseek","project_cwd":"/tmp/t7-ds-cwd",...}'
# => content stored (provider: "deepseek")

mix ezagent agent_template instantiate --agent-template template://system/agent/t7-ds-pty \
    --instance-name t7-ds-1 --workspace-uri workspace://system \
    --spawned-by entity://system/user/admin --deadline-ms 120000
# => {"workers": ["entity://system/agent/t7-ds-1"], "fresh?": true}   (2.3 s)
```

`provider` rides the AgentTemplate content seam (spec §4.5 link 1) — it is a
catalog profile NAME; no env var, URL, or model appears in template data.
NOTE: the ad-hoc `workspace create_agent --flavor cc-custom --flavor-config
'{"provider":...}'` surface rejects `provider` as an unknown flavor-config key
(see `04-findings.md` F3) — the template content path is the sanctioned create
lane for custom flavors.

### Spawn / transport (server log, `server-run2-excerpts.txt`)

- `PtyServer spawned claude os_pid=142203` → trust/dev-channels dialogs auto-answered by the product machinery; first child exits 256 → **DEGRADED respawn** with the `cmd_fallback` argv (standard cc path, same as plain cc on this host) → `os_pid=142280`.
- `JOINED agent_bridge:cc-custom:entity://system/agent/t7-ds-1` — the cc-custom bridge topic (NOT `agent_bridge:cc:`).
- claude TUI banner in the PTY stdout: **`deepseek-v4-pro[1m] · API Usage Billing`** — the catalog's `[1m]` model tag confirmed as the LIVE model identity on the vendor account; no "Both tokens set" warning in the scrubbed run.

### Cold restart (server stopped, rebooted; agent re-resolves flavor + profile)

After a full server restart, `mix ezagent agent read --agent entity://system/agent/t7-ds-1` drove the cold rehydration through dispatch. The agent's persisted respawn data re-resolved with NO secret material:

```json
{
  "agent_uri": "entity://system/agent/t7-ds-1",
  "class": "cc_custom.agent",
  "cwd": "/tmp/t7-ds-cwd",
  "flavor": "cc-custom",
  "provider": "deepseek",
  "pty_phase": "running"
}
```

The PTY respawned on the deepseek profile (second `PtyServer spawned` + `JOINED agent_bridge:cc-custom:` pair in the excerpt) — DoD "cold restart re-resolves flavor + profile from `respawn_template_data`; no secret in any persisted artifact" holds: only the profile NAME persists.

### Chat round-trip through the product chat path (world UI)

Drove the world UI (login `admin@ezagent.chat` → open session `session://system/default/t7-proof` → mention autocomplete → send):

- sent `@t7-ds-1 please reply with exactly: ds-pong` (00:21:23, operator)
- reply bubble from `t7-ds-1`: **`ds-pong`** (00:21:34, ~11 s round-trip)

Screenshot: `shots/chat-roundtrip-deepseek.png`. Server-side the excerpt shows the
full loop: `chat.send` → PTY stdin (`← esr-bridge: @t7-ds-1 please reply with
exactly: ds-pong`) → claude reasons ~9 s → `Replied "ds-pong" to the
esr-bridge channel` → reply posted back to the session.

**Transport**: PTY (`erlexec`) + dev-channels esr-bridge. **Provider profile**:
`deepseek` (catalog) — `ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic`,
`ANTHROPIC_AUTH_TOKEN` from `DEEPSEEK_API_KEY`, model `deepseek-v4-pro[1m]`.

## Agent 2 — cc-headless-custom on `kimi` — NOT live-provable (two independent blockers)

1. **Vendor blocker (primary):** the operator-supplied `MOONSHOT_API_KEY` is
   rejected by the vendor with 401 Invalid Authentication on every probed
   surface (see `01-cli-probes.md` forensics). Even a perfectly spawned kimi
   agent cannot complete a message. → §2.4/§11 blocker path.
2. **Product-surface blockers (secondary, all pre-existing or documented gaps —
   see `04-findings.md` F2/F3/F4):** the three ad-hoc create lanes for
   cc-headless-custom are each independently broken on this branch:
   - `workspace create_agent --flavor cc-headless-custom` → `provider` rejected
     as an unknown flavor-config key (verified empirically);
   - `agent_template instantiate` WITHOUT `config_dir` in content → the
     headless SDK sidecar crashes `String.to_charlist(nil)` (generic
     cc-headless defect — plain cc-headless hits it identically);
   - `agent_template instantiate` WITH `config_dir` → the #17 cascade layer
     resolution self-calls the template Kind (`{:calling_self, ...}`) — generic,
     reproduced identically with plain cc-headless AND with cc-custom PTY.

   What IS proven for cc-headless-custom + kimi: `validate/1` accepts
   `provider: "kimi"` and rejects `bogus`/`anthropic`/non-strings (unit suite,
   T3); the instantiate fail-closed gates run BEFORE any spawn (the bogus
   negative proof below uses the same path); `sdk_sidecar_params/2` threads
   `Provider.provider_env/1` into the sidecar `cmd_env` (unit suite, T3).
