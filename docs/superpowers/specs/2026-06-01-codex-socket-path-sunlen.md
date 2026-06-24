# Fix: codex app-server socket path exceeds unix SUN_LEN

**Date**: 2026-06-01
**Status**: spec (bug fix — root cause confirmed)
**Unblocks**: scenario 33 live tier — orchestrator-spawned codex workers.

## Root cause (confirmed by live reproduction)

`EzagentPluginCodex.Template.CodexAgent.default_app_server_socket_path/1`
builds the codex app-server unix-socket path by embedding the FULL
sanitized agent URI:

```
~/.ezagent/default/codex/<sanitized-full-uri>/app-server.sock
```

For an orchestrator-spawned worker the URI is long —
`entity://agent/system/codex_worker-cx-<32-hex>--e2e-orch15` → sanitized
slug ~80 chars → full socket path = **135 bytes**, exceeding the macOS
unix-domain socket limit (`SUN_LEN` ≈ 104).

Reproduced directly: `codex app-server --listen unix://<135-byte-path>`
→ `Error: path must be shorter than SUN_LEN`, process exits status 1.
Consequence chain: app-server can't bind → no socket → the bridge
sidecar's `ensure_thread` can't `unix_connect` → it never writes the
thread-id file → `ensure_bridge_thread_id` hits
`{:codex_thread_id_file_timeout, ...}` (15 s) → the worker spawn rolls
back. The codex bridge thread-bootstrap itself is FINE (the
`codex_bridge_thread_smoke.py` smoke test passes — it uses a short tmp
path). Short-named codex agents (scenario 06, `codex_test_alpha`) stayed
under the limit, which is why only orchestrator workers failed.

## Fix

Shorten the socket directory: use a SHORT, DETERMINISTIC hash of the
agent URI instead of the full sanitized URI.

```elixir
defp default_app_server_socket_path(agent_uri) do
  slug = agent_uri |> URI.to_string() |> short_hash()
  Path.join([Ezagent.Home.path("codex"), slug, "app-server.sock"])
end

defp short_hash(s) do
  :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
```

Resulting path: `~/.ezagent/default/codex/<16-hex>/app-server.sock` ≈ 72
bytes — comfortably under SUN_LEN, even for long worker URIs.

### Why this is complete + consistent

- `ensure_sidecars/2` computes `socket_path` + `thread_id_path` ONCE and
  threads them to AppServer (binds), BridgeSidecar (`EZAGENT_CODEX_APP_SERVER_SOCK`),
  the PTY (`codex resume --remote unix://socket`), and `wait_for_thread_id`.
  All four derive from `app_server_socket_path/2` →
  `default_app_server_socket_path/1`, so fixing that one function fixes
  every consumer consistently. No other module constructs the path
  (AppServer/BridgeSidecar receive it as a param).
- `thread_id_path/2` = `dirname(socket_path)/bridge-thread-id` — follows
  the new short dir automatically (a regular file, no length limit).
- DETERMINISTIC: same URI → same hash → same path, so respawn/adopt and
  the 4 consumers always agree.
- An operator `tmpl["app_server_socket"]` / `tmpl["thread_id_file"]`
  override still wins (unchanged) — they're responsible for their own
  length.
- Collision: 16 hex = 64 bits of SHA-256 → negligible.

## Out of scope

- The cc-orchestrator/curl legs (already live). The
  flavor-generic `to_template_data` fix (#508, merged) already threads
  codex's model/approval/sandbox — this socket-path fix is the remaining
  blocker for codex's LIVE round-trip.
- The non-fatal codex skill-load warning (`~/.agents/skills/agent-browser/SKILL.md`
  missing frontmatter) — cosmetic, codex still runs.

## Testing

- **Unit**: `default_app_server_socket_path/1` for a long worker URI
  yields a path < 104 bytes; deterministic (same URI → same path); two
  different URIs → different dirs.
- **Live (the gate)**: orchestrator `add_agent_slot` a codex worker →
  app-server binds + stays alive → bridge writes thread-id → no
  `codex_thread_id_file_timeout` → the codex worker round-trips a reply,
  mirrored to the bound Ezagent Feishu group (`FeishuClient code=0`).
