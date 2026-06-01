# Flavor-generic `AgentTemplate.to_template_data/2`

**Date**: 2026-06-01
**Status**: spec (brainstorm approach B approved by Allen)
**Scenario it unblocks**: 33 (full-star) live tier — orchestrator-spawned
curl/codex workers.

## Problem

`Ezagent.Entity.AgentTemplate.to_template_data/2` converts an AgentTemplate's
`:template` slice `content` into the flavor Template Class's `instantiate/3`
data map. It is **cc-centric**: beyond the universal `class` / `agent_uri` /
`cwd`, it only threads a hardcoded cc-specific optional set —
`claude_config_dir`, `operator_settings_path`, `operator_mcp_config_path`,
`api_key_helper`, `role` (agent_template.ex ~169-175).

It does NOT carry:
- **curl**: `provider`, `api_url`, `model`, `system_prompt`, `max_history`
- **codex**: `model`, `approval_policy`, `sandbox` (+ optional `bridge_ws_url`,
  `codex_path`)

So when the orchestrator's `add_agent_slot` spawns a curl/codex worker, the
worker's flavor slice gets those fields as `nil`. **Verified live (2026-06-01)**:
an orchestrator-spawned curl worker had `provider`/`api_url`/`model` all nil and
could not call DeepSeek even though its `:api_keys` slice held a valid key. cc
workers work only because their needed field (`claude_config_dir`) is in the cc
allowlist.

This blocks live multi-flavor full-star (scenario 33 live tier). The
deterministic `scenario_33_full_star_test` uses synthetic no-PTY flavors, so it
does not exercise this mapping.

## Approach (B — flavor declares its own fields; approved)

The flavor's Template Class — which already owns `template_name/0` /
`validate/1` / `instantiate/3` — declares which of its content fields to thread.
Core stays flavor-agnostic (north-star: plugin isolation; keep curl/codex field
knowledge OUT of `ezagent_domain_chat`).

### New optional callback on `Ezagent.Kind.Template`

```elixir
@doc """
Flavor-specific template_data the flavor's instantiate/3 expects, derived
from the AgentTemplate `content`. Merged by AgentTemplate.to_template_data/2
onto the universal base (class/agent_uri/cwd). Keys MUST be STRINGS (the
instantiate/3 contract reads string keys). nil values are dropped by the
caller. Reading from `content` should tolerate atom OR string keys.
"""
@callback template_data_extra(content :: map()) :: %{optional(String.t()) => term()}
```

Added to `@optional_callbacks` (flavors without it contribute no extras → base
only). Reserved keys (`class`, `agent_uri`, `cwd`) are owned by core and MUST
NOT be returned by the callback (core ignores/overrides them if present).

### `to_template_data/2` change

```
base = %{"class" => class, "agent_uri" => ..., "cwd" => cwd}
extra =
  case flavor_template_class(content) do
    {:ok, tc} -> if function_exported?(tc, :template_data_extra, 1), do: tc.template_data_extra(content), else: %{}
    _ -> %{}
  end
{:ok, merge_drop_nil_and_reserved(base, extra)}
```

The hardcoded cc optional set is **removed from core** and moved into the cc
Template Class's `template_data_extra/1`. The merge drops nil values (as today)
and ignores any reserved key the callback returns (defensive).

### Per-flavor `template_data_extra/1`

A shared key-tolerant getter (mirror of the existing `content_get/2`) reads
atom-or-string content keys. Each flavor returns ONLY non-nil extras:

- **cc** (`apps/ezagent_plugin_cc/.../cc_agent.ex`):
  `"claude_config_dir"`, `"operator_settings_path"` (from `settings_path`),
  `"operator_mcp_config_path"` (from `mcp_config_path`), `"api_key_helper"`,
  `"role"`. Identical output to today's hardcoded set → orchestrators + existing
  cc agents are byte-for-byte unaffected.
- **curl** (`apps/ezagent_plugin_curl_agent/.../curl_agent.ex`):
  `"provider"`, `"api_url"`, `"model"`, `"system_prompt"`, `"max_history"`.
- **codex** (`apps/ezagent_plugin_codex/.../codex_agent.ex`):
  `"model"`, `"approval_policy"`, `"sandbox"`, and optional `"bridge_ws_url"`,
  `"codex_path"` when present.

## Out of scope (separate todo items)

- **codex worker bridge connection failure** (`codex_bridge` thread_id timeout)
  — a codex-plugin runtime bug, orthogonal to this mapping.
- **`add_agent_slot` sync 5s `GenServer.call` timeout** for slow-spawning
  flavors — separate robustness fix.
- The DeepSeek key itself: already set on the worker's `:api_keys` slice via
  `put_api_key`; this spec only makes the worker LEARN its provider/url/model.

## Testing

- **Unit (`agent_template` test)**: `to_template_data/2` for a cc-flavored
  content still yields `claude_config_dir`/`role` (regression); for a
  curl-flavored content yields `provider`/`api_url`/`model`; for a codex-flavored
  content yields `model`/`approval_policy`/`sandbox`. A flavor whose Class lacks
  the callback yields base-only.
- **Invariant**: the callback output never contains reserved keys
  (`class`/`agent_uri`/`cwd`); nil extras are dropped.
- **Live (the gate, after merge)**: orchestrator `add_agent_slot` a curl worker
  + `put_api_key` + `write_matcher` → the worker calls DeepSeek and replies,
  mirrored to the bound ESR Feishu group (`FeishuClient send_text code=0`). Same
  for codex once its bridge bug is fixed.

## Risk / back-compat

Lowest-risk: cc's callback reproduces the exact current cc set, so the
cc-orchestrator seed (atom-keyed content) and all existing cc agents are
unchanged. Non-cc flavors that previously relied on the cc set being threaded:
none (only cc reads `claude_config_dir` et al.). Flavors without the callback
(echo/np/…) get base-only, which is what they effectively used before (they do
not read cc keys).
