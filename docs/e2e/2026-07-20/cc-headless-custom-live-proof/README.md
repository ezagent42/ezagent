# cc-headless-custom live proof — 2026-07-20 (issue #1460 closure run)

**Scope:** the live-spawn acceptance of #1460 — prove a `cc_headless_custom.agent`
can be spawned **live, end-to-end** on the lanes that F2/F3/F4 blocked, on BOTH
catalog backends (deepseek + kimi-coding), from a locally booted dev node on
branch `fix/1460-cc-headless-custom-live` (main `fe2906431` + the three fix
commits).

**Secret hygiene:** keys were sourced only via
`set -a; . ~/.ezagent/default/credentials/cc-custom.env; set +a` (CR-stripped).
No key value was ever printed, logged into this directory, or committed. The
full server log was scanned for `AUTH_TOKEN` / `sk-` before excerpting (0 hits —
see the cleanliness proof at the bottom of this file). The ambient custom-backend
env of this host was scrubbed before boot (same recipe as the 2026-07-17 PTY
proof), so the agents' only auth material is each profile's.

## Environment

| Item | Value |
|---|---|
| Branch | `fix/1460-cc-headless-custom-live` (F2 + F4 + F3 commits on `fe2906431`) |
| Server | `MIX_ENV=dev mix phx.server`, `PORT=10101`, `EZAGENT_HOME=/tmp/ez-hc-proof/home`, disposable `POSTGRES_DB=ezagent_hc_proof` |
| Node env | throwaway `EZAGENT_SIGNING_SEED_V1` / `EZAGENT_PAT_PEPPER_V1`; `EZAGENT_ADMIN_PASSWORD` set (boot's `repair_admin_user` wires the admin login — NO seed scripts needed) |
| CLI auth | `EZAGENT_USER_TOKEN` minted via a `--no-start` minimal node (the stock `mix ezagent.user.token --mint` boots the full app and crashes on a populated DB — see #1482) |
| Browser | headless Chromium via Playwright (`tools/*.cjs`, run from `apps/ezagent_plugin_world/assets`) |
| Known blocker | server RESTART against a populated DB crashes on this main — **filed as issue #1482** (cold-restart boot race; NOT caused by these fixes — reproduced on a tree where the fixes are the only delta over `fe2906431`, none of which touch boot/Loader paths). The cold-check below therefore uses an in-node sidecar kill instead of a server restart. |

## Verdicts at a glance

| Proof | Result |
|---|---|
| **F2 lane** — `agent_template instantiate` WITH `config_dir` in content (`hc-ds-f2`, deepseek) | **PASS** — pre-fix this died `{:cascade_layer_dir_failed, …, {:get_slice_exit, {:calling_self, …}}}`; now spawns, SDK sidecar up, curated layer materialized (`curated-marker.txt` copied into the per-agent home) |
| **F4 lane** — `agent_template instantiate` WITHOUT `config_dir` (`hc-kc-f4`, kimi-coding) | **PASS** — pre-fix the SDK sidecar crashed `String.to_charlist(nil)`; now `ensure_config_home/2` allocates the canonical per-agent home, sidecar up |
| **F3 lane** — ad-hoc create via world "New Agent" form (`hc-ds-f3`, deepseek) | **PASS** — the form's flavor select now exposes a required **Backend profile** select (`deepseek`/`kimi`/`kimi-coding`, straight from `ProviderCatalog.names()`); create → sidecar up. (Pre-F3 the ad-hoc lane direct-spawned a zombie Kind with NO sidecar — see `agent_create.ex` change.) |
| Chat round-trip, deepseek (`hc-ds-f2`) | **PASS** — `@hc-ds-f2 … ds-pong` → agent bubble `ds-pong` (twice, two independent runs) |
| Chat round-trip, kimi-coding (`hc-kc-f4`) | **PASS** — `@hc-kc-f4 … kc-pong` → agent bubble `kc-pong`; the killed sidecar's buffered output shows the raw SDK rows `{"id":"cc-sdk-1","ok":true,"content":"kc-pong", …usage…}` |
| Chat round-trip, F3-created agent (`hc-ds-f3`) | **PASS** — `f3-pong` |
| Cold-respawn — kill the sidecar OS process, re-chat (`hc-kc-f4`) | **PASS** — `ensure_subprocess_alive` respawns the sidecar; `kc-pong-2` round-trip |
| Kind-level cold restart (server reboot re-resolves flavor+profile) | **SUBSTITUTED** — server restart is blocked by #1482 (unrelated boot race). Kind/sidecar-level respawn proven above; flavor+profile cold re-resolution remains covered by the #1449 unit suite (`cc_custom_backend_test.exs`, unchanged code path). |
| Negative: bogus / missing `provider` on the ad-hoc lane | **PASS** (integration) — `create_agent_dispatch_test.exs`: `{:invalid_template_data, {:unknown_backend_profile, "bogus"}}` both flavors; `:missing_backend_profile` when absent |

## Files

- `server-excerpts.txt` — spawn lines, `chat.send` dispatches, the sidecar-exit
  line (sanitized).
- `sidecar-sdk-responses.txt` — the raw SDK response rows recovered from the
  killed kimi-coding sidecar's output buffer (`content: "kc-pong"` with token
  usage) — direct vendor round-trip evidence.
- `shots/` —
  `00-login.png` / `02-session.png` (session list with the proof session),
  `10-ds-reply.png` (deepseek `ds-pong` agent bubble ×2 + kimi `kc-pong`),
  `11-kc-reply.png` (same feed scrolled, both replies),
  `12-respawn-reply.png` (`kc-pong-2` after the sidecar kill),
  `21-form-custom-flavor.png` (New Agent form on `cc-headless-custom` — the
  **Backend profile** select rendered from the new `config_schema` field),
  `22-form-filled.png` / `23-form-submitted.png` (F3 create → agent page).
- `tools/` — the three Playwright drivers (`hc-proof-chat.cjs` both-backend
  chat, `hc-proof-respawn.cjs` single-agent chat, `hc-proof-f3create.cjs` the
  form create). Run from `apps/ezagent_plugin_world/assets`.

## Spawn-lane transcripts (CLI)

### F2 — template.instantiate WITH config_dir (deepseek)

```bash
mix ezagent agent_template fork --agent-template template://system/agent/cc-orchestrator \
    --new-name hc-ds-f2 --owner entity://system/user/admin
# => template_uri: template://system/agent/hc-ds-f2

mix ezagent agent_template write --agent-template template://system/agent/hc-ds-f2 \
    --content '{"name":"hc-ds-f2","flavor":"cc-headless-custom","provider":"deepseek",
                "project_cwd":"/tmp/ez-hc-proof/cwd-ds",
                "config_dir":"/tmp/ez-hc-proof/curated-ds/.claude"}'
# => content stored (provider: "deepseek", config_dir present)

mix ezagent agent_template instantiate --agent-template template://system/agent/hc-ds-f2 \
    --instance-name hc-ds-f2 --workspace-uri workspace://system \
    --spawned-by entity://system/user/admin --deadline-ms 180000
# => workers: [entity://system/agent/hc-ds-f2]   fresh?: true
```

Server: `cc-headless: agent entity://system/agent/hc-ds-f2 spawned with SDK sidecar`.
Cascade layer materialized:
`/tmp/ez-hc-proof/home/default/cc-headless-agents/system/hc-ds-f2/curated-marker.txt`
(the curated template home copied into the agent's per-agent home — the very
layer whose resolution self-called the template Kind pre-fix).

### F4 — template.instantiate WITHOUT config_dir (kimi-coding)

```bash
mix ezagent agent_template fork --agent-template template://system/agent/cc-orchestrator \
    --new-name hc-kc-f4 --owner entity://system/user/admin
mix ezagent agent_template write --agent-template template://system/agent/hc-kc-f4 \
    --content '{"name":"hc-kc-f4","flavor":"cc-headless-custom","provider":"kimi-coding",
                "project_cwd":"/tmp/ez-hc-proof/cwd-kc"}'      # NOTE: no config_dir
mix ezagent agent_template instantiate --agent-template template://system/agent/hc-kc-f4 \
    --instance-name hc-kc-f4 --workspace-uri workspace://system \
    --spawned-by entity://system/user/admin --deadline-ms 180000
# => workers: [entity://system/agent/hc-kc-f4]   fresh?: true
```

`ensure_config_home/2` allocated the canonical per-agent home
(`/tmp/ez-hc-proof/home/default/cc-headless-agents/system/hc-kc-f4`) and the
sidecar started — pre-fix this content crashed the sidecar
`String.to_charlist(nil)`.

### F3 — ad-hoc create (world form)

`Agents → New agent → Flavor=cc-headless-custom` renders the new required
**Backend profile** select (options `deepseek`/`kimi`/`kimi-coding`, driven by
`Provider.provider_config_field/0` in the classes' `config_schema/0`) →
`Name=hc-ds-f3`, `Backend profile=deepseek` → Create → redirected to
`/identities/agents/entity://system/agent/hc-ds-f3`; server:
`cc-headless: agent entity://system/agent/hc-ds-f3 spawned with SDK sidecar`.

(The generic `mix ezagent workspace create_agent` CLI cannot express the
required boolean `--with-pty` flag — an Optimus/coercion parity gap separate
 from F3; the GUI form and the dispatch facade work. Recorded as a finding in
 the day-return.)

## Chat round-trips

Drove the world UI (login `admin@ezagent.chat` → `/Default/Hc-Proof` →
打开对话 → mention → 发送):

- `@hc-ds-f2 please reply with exactly: ds-pong` → agent bubble **`ds-pong`**
  (two independent runs, 22:13:03 + 22:15:12) — deepseek.
- `@hc-kc-f4 please reply with exactly: kc-pong` → agent bubble **`kc-pong`**
  (22:13:20) — kimi-coding. The sidecar-kill forensics later recovered the raw
  SDK rows from its output buffer (`sidecar-sdk-responses.txt`).
- Cold-respawn: killed the kimi sidecar OS processes, sent
  `@hc-kc-f4 … kc-pong-2` → **`kc-pong-2`** — `ensure_subprocess_alive`
  respawned the sidecar on the receive path.
- `@hc-ds-f3 … f3-pong` → **`f3-pong`** — the F3 (ad-hoc form) lane's agent
  chats too.

Waiter correctness: the first script run matched the token inside MY OWN
bubble (false positive risk); the final waiter requires a leaf element whose
text is EXACTLY the token (own bubble contains a longer string) — screenshots
confirm agent-authored bubbles (智能体 hc-ds-f2 / hc-kc-f4 / hc-ds-f3).

## Follow-ups surfaced by this run (all filed / recorded)

1. **#1482 (CRITICAL, pre-existing)** — cold-restart boot race:
   world-plugin `after_boot` `spawn_workspace("system")` collides
   `{:already_registered, "workspace://system"}` on ANY populated DB. Every
   dev/e2e restart is broken on current main; also blocks the stock
   `mix ezagent.user.token --mint` (it boots the full app). This proof used
   fresh-DB boots + a `--no-start` mint instead.
2. **CLI boolean parity gap (pre-existing)** — the auto-derived
   `mix ezagent workspace create_agent` cannot express the required
   `--with-pty` boolean (switch consumes the next token; `--with-pty=false`
   reaches the action as the STRING "false" and fails `is_boolean/1`). Same
   F5-class CLI/GUI parity family. The GUI form works.
3. The 2026-07-17 PTY proof's F1 (PtyServer crash-dump leaks `cmd_env`
   incl. `ANTHROPIC_AUTH_TOKEN`) did NOT trigger here (headless sidecars, no
   PTY crash dumps; log scan = 0 hits) — but F1's fix (#1455) is still open.

## Cleanliness proof (run before commit)

```
$ grep -rInE 'sk-[A-Za-z0-9]|esr_pat_v1_[A-Za-z0-9]|tok_[A-Za-z0-9]|ANTHROPIC_AUTH_TOKEN' docs/e2e/2026-07-20/cc-headless-custom-live-proof/
(no matches)
```
