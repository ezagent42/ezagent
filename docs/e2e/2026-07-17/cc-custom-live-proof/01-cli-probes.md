# T7 Step 1 — CLI probes (spec §2.4, both vendors)

Date: 2026-07-17 (UTC+8 host). Worktree: `.worktrees/cc-custom-backends` @ `d9e429b9e` (branch `feat/cc-custom-backends`).
Binary: `claude` 2.1.212 (`/home/huangjiajia/.asdf/installs/nodejs/22.22.3/bin/claude`).
Keys: sourced via `set -a; . ~/.ezagent/default/credentials/cc-custom.env; set +a` — values never printed. Env block per the shipped catalog (`provider_catalog.ex`), which matches the vendor guides (spec §2.1/§2.2); the DeepSeek main slots use the catalog's `deepseek-v4-pro[1m]` tag (brief override of §2.4's draft command).

## Probe 1 — DeepSeek (profile `deepseek`)

Command (env var NAMES only; values from the sourced file):

```bash
env ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic \
    ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY" \
    ANTHROPIC_MODEL='deepseek-v4-pro[1m]' \
    ANTHROPIC_DEFAULT_OPUS_MODEL='deepseek-v4-pro[1m]' \
    ANTHROPIC_DEFAULT_SONNET_MODEL='deepseek-v4-pro[1m]' \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash \
    CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash \
    CLAUDE_CODE_EFFORT_LEVEL=max \
    claude -p "Reply with exactly: ok" --dangerously-skip-permissions
```

| Field | Value |
|---|---|
| exit status | **0** |
| stdout | `ok` |
| response shape | plain assistant text (`-p` print mode), exact string requested |
| model identity | `deepseek-v4-pro[1m]` (main slot; haiku/subagent slots `deepseek-v4-flash`) |
| duration | 7 505 ms |
| stderr | benign connector notice only (`claude.ai connectors are disabled because ANTHROPIC_API_KEY or another auth source is set…`) |

**Verdict: PASS** — the documented DeepSeek env block + the catalog's `[1m]` model tags drive the real claude binary end-to-end.

## Probe 2 — Kimi (profile `kimi`)

Command (same seam):

```bash
env ANTHROPIC_BASE_URL=https://api.moonshot.ai/anthropic \
    ANTHROPIC_AUTH_TOKEN="$MOONSHOT_API_KEY" \
    ANTHROPIC_MODEL=kimi-k3 \
    ANTHROPIC_DEFAULT_OPUS_MODEL=kimi-k3 \
    ANTHROPIC_DEFAULT_SONNET_MODEL=kimi-k3 \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=kimi-k3 \
    CLAUDE_CODE_SUBAGENT_MODEL=kimi-k3 \
    ENABLE_TOOL_SEARCH=false \
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=1048576 \
    claude -p "Reply with exactly: ok" --dangerously-skip-permissions
```

| Field | Value |
|---|---|
| exit status | **1** |
| stdout | `Failed to authenticate. API Error: 401 Invalid Authentication` |
| duration | 194 786 ms (client retried before failing) |
| stderr | benign connector notice only |

**Verdict: FAIL — vendor rejects the key (blocked at vendor boundary, not a build defect).**

### Key-rejection forensics (sanitized)

The 401 is the vendor's answer to the key itself, not an endpoint/header
mismatch. Evidence (key value never printed anywhere):

| Check | Result |
|---|---|
| `POST https://api.moonshot.ai/anthropic/v1/messages` (Bearer) | HTTP 401 `{"error":{"message":"Invalid Authentication","type":"invalid_authentication_error"}}` |
| `POST https://api.moonshot.cn/anthropic/v1/messages` (Bearer) | HTTP 401 (same body) |
| both hosts, `x-api-key` header instead of Bearer | HTTP 401 (same body) |
| `GET https://api.moonshot.ai/v1/models` (Bearer, native endpoint) | HTTP 401 (same body) |
| key metadata (length/charset only) | 72 chars, starts `sk-`, charset `[A-Za-z0-9_-]` only, no stray CR/space |

So: well-formed key string, rejected by Moonshot international + China
endpoints, on both the Anthropic-compat and native surfaces, under both auth
header schemes. **Operator action needed: a fresh/valid `MOONSHOT_API_KEY`.**

### Incidental operator-file observations (no values)

1. `~/.ezagent/default/credentials/cc-custom.env` has **CRLF line endings**.
   `DEEPSEEK_API_KEY` picks up a trailing `\r` when sourced (36 chars incl. CR;
   DeepSeek's endpoint evidently tolerates it — probe 1 passed). The Moonshot
   line has no trailing CR, so CRLF is NOT the 401 cause — but the file should
   be normalized to LF to avoid subtle breakage elsewhere.
2. File mode is `0644`; the brief's prereq asks for `0600`.
