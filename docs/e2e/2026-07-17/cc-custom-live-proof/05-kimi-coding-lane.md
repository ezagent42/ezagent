# T7 completion — the kimi-coding lane (2026-07-18, post-controller unblock)

**Unblock context:** the placed `MOONSHOT_API_KEY` is a Kimi for Coding
SUBSCRIPTION key (kimi.com), not an open-platform key — the open platform
correctly 401s it (Step 1 forensics in `01-cli-probes.md` were right; the
diagnosis was incomplete: the key is VALID, just for a different first-party
surface). The controller proved `https://api.kimi.com/coding` (POST
`/v1/messages` → 200, real claude turn) and landed catalog profile
`"kimi-coding"` (base_url `https://api.kimi.com/coding`, api_key_env
`KIMI_CODING_API_KEY`, model block `kimi-k3[1m]`, commit `11770568c`). The
operator env file gained `KIMI_CODING_API_KEY` (LF + 0600).

Same hygiene as the deepseek lane: sourced via `set -a; . …; set +a`, values
never printed; scrubbed ambient `ANTHROPIC_*`/`CLAUDE_*` for the server boot;
evidence grep-proven (see README).

## 1. CLI probes (both kimi surfaces, spec §2.4 shape)

| Probe | Command (env NAMES only) | Exit | Output | Duration |
|---|---|---|---|---|
| kimi-coding | `env ANTHROPIC_BASE_URL=https://api.kimi.com/coding ANTHROPIC_AUTH_TOKEN="$KIMI_CODING_API_KEY" ANTHROPIC_MODEL='kimi-k3[1m]' ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL='kimi-k3[1m]' CLAUDE_CODE_SUBAGENT_MODEL='kimi-k3[1m]' ENABLE_TOOL_SEARCH=false CLAUDE_CODE_AUTO_COMPACT_WINDOW=1048576 claude -p "Reply with exactly: ok" --dangerously-skip-permissions` | **0** | `ok` | 6 331 ms |
| platform kimi (negative sanity) | same block but `ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic ANTHROPIC_AUTH_TOKEN="$MOONSHOT_API_KEY" ANTHROPIC_MODEL=kimi-k3 …` | **1** | `Failed to authenticate. API Error: 401 Invalid Authentication` | 192 751 ms |

The negative sanity distinguishes vendor-reject from our fail-closed gates:
with `MOONSHOT_API_KEY` PRESENT in the env, the platform profile's launch
env builds fine (presence check passes) and the 401 comes back from the
VENDOR — it is not `{:backend_api_key_missing, "kimi"}` (which only fires
when the profile's own env var is unset) and not
`{:unknown_backend_profile, _}` (the profile name is valid).

## 2. Product-path proof — cc-custom PTY on `kimi-coding`

Same create lane as the deepseek agent (template content seam; headless
ad-hoc lanes remain blocked by F2/F4 — see `04-findings.md`):

```bash
mix ezagent agent_template fork --agent-template template://system/agent/cc-orchestrator \
    --new-name t7-kc-pty --owner entity://system/user/admin
mix ezagent agent_template write --agent-template template://system/agent/t7-kc-pty \
    --content '{"name":"t7-kc-pty","flavor":"cc-custom","provider":"kimi-coding","project_cwd":"/tmp/t7-kc-cwd",...}'
mix ezagent agent_template instantiate --agent-template template://system/agent/t7-kc-pty \
    --instance-name t7-kc-1 --workspace-uri workspace://system \
    --spawned-by entity://system/user/admin --deadline-ms 120000
# => {"workers": ["entity://system/agent/t7-kc-1"], "fresh?": true}   (2.3 s)
```

- **Spawn/transport:** PTY (`erlexec`) + dev-channels esr-bridge; trust/dev-channels
  dialogs auto-answered; the routine exit-256 → DEGRADED-respawn fallback
  fired (same as every flavor on this host) →
  **`JOINED agent_bridge:cc-custom:entity://system/agent/t7-kc-1`**.
- **Model identity (live):** claude TUI banner **`kimi-k3[1m] · API Usage
  Billing`** — the catalog's `[1m]` tag confirmed against the subscription
  endpoint (server-run4-5 excerpts).
- **Chat round-trip (world UI, same session as the deepseek proof):**
  `@t7-kc-1 please reply with exactly: kc-pong` (01:46:29) →
  **`kc-pong`** from `t7-kc-1` (01:46:33, ~4 s). Screenshot
  `shots/chat-roundtrip-both-vendors.png` — one session, both vendors
  (`ds-pong` + `kc-pong` bubbles), the §11 "one facility, both vendors" row.

## 3. Cold-restart spot check

Full server stop + reboot, then `mix ezagent agent read --agent
entity://system/agent/t7-kc-1`:

```json
"respawn_template_data": {
  "agent_uri": "entity://system/agent/t7-kc-1",
  "class": "cc_custom.agent",
  "cwd": "/tmp/t7-kc-cwd",
  "flavor": "cc-custom",
  "provider": "kimi-coding"
},
"pty_phase": "running"
```

Flavor + profile re-resolve from `respawn_template_data`; the PTY respawned
(os_pid 228193) and re-joined `agent_bridge:cc-custom:` (run5 excerpt). The
persisted artifact carries the profile NAME only — zero secret (grep-proven:
no `KIMI_CODING_API_KEY`/`MOONSHOT_API_KEY`/`DEEPSEEK_API_KEY` value anywhere
in this directory or in the agent dirs `/tmp/t7-kc-cwd`,
`~/.ezagent/default/cc-agents`).

## 4. Notes

- F1 (the PtyServer crash-dump env leak, `04-findings.md`) reproduces on this
  lane: the kimi-coding profile's `ANTHROPIC_AUTH_TOKEN` also lands in the
  exit-256 GenServer terminate dump. **Every custom-profile agent leaks its
  profile key on that path** — the fix is load-bearing for the whole
  facility, and the kimi-coding key should also be treated as exposed on this
  host (local logs sanitized).
- The platform `kimi` profile stays in the catalog (closed set of 3); an
  operator with an open-platform key can use it — its fail-closed behavior is
  unchanged (proven in `03-negative-proofs.md`).
