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
knowledge OUT of `ezagent_domain_instance_message`).

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
{:ok, tc}  = flavor_template_class(content)         # already resolved for `class`
base       = %{"class" => tc.template_name(), "agent_uri" => ..., "cwd" => cwd}
extra      = if function_exported?(tc, :template_data_extra, 1),
               do: tc.template_data_extra(content), else: %{}
data       = merge_drop_nil_and_reserved(base, extra)  # nil + reserved-key dropped
# HIGH (codex review): fail-fast — a misconfigured flavor template must NOT
# spawn a nil-config worker. Validate the assembled data against the flavor's
# OWN validate/1 (it already encodes required-field rules, e.g. curl requires
# non-empty provider/api_url/model) before returning.
case (if function_exported?(tc, :validate, 1), do: tc.validate(data), else: :ok) do
  :ok          -> {:ok, data}
  {:error, e}  -> {:error, {:invalid_template_data, e}}
end
```

`flavor_template_class/1` resolves the module ONCE (replacing the separate
`resolve_class_name/1` + base `class` string — codex review LOW: avoid the
double registry lookup). The hardcoded cc optional set is **removed from core**
and moved into the cc Template Class's `template_data_extra/1`. The merge drops
nil values (as today) AND ignores any reserved key (`class`/`agent_uri`/`cwd`)
the callback returns (defensive).

**Fail-fast validation (codex review HIGH).** `Agent.spawn_from_template_content/4`
→ `instantiate_workers/3` passes `to_template_data`'s map straight to
`instantiate/3` WITHOUT calling the flavor `validate/1`. So a curl/codex template
missing a required field (e.g. curl `provider`) would today spawn a worker whose
flavor slice is nil — exactly the live failure mode. Running `tc.validate(data)`
inside `to_template_data` (above) makes `add_agent_slot` / the create flow return
`{:error, {:invalid_template_data, _}}` LOUDLY instead. `validate/1` is optional;
flavors without it skip the check.

### Per-flavor `template_data_extra/1`

A shared key-tolerant getter (mirror of the existing `content_get/2`) reads
atom-or-string content keys. Each flavor returns ONLY non-nil extras:

- **cc** (`apps/ezagent_plugin_cc/.../cc_agent.ex`):
  `"claude_config_dir"`, `"operator_settings_path"` (from `settings_path`),
  `"operator_mcp_config_path"` (from `mcp_config_path`), `"api_key_helper"`,
  `"role"`. Identical output to today's hardcoded set → orchestrators + existing
  cc agents are byte-for-byte unaffected.
- **curl** (`apps/ezagent_plugin_curl_agent/.../curl_agent.ex`):
  `"provider"`, `"api_url"`, `"model"` (required — curl `validate/1` rejects
  empty), `"system_prompt"`, `"max_history"`. `max_history` is threaded AS-IS
  (int or string); curl's `instantiate/3` already coerces via `parse_int/2`
  (default 20) — the callback does NOT coerce (codex review LOW).
- **codex** (`apps/ezagent_plugin_codex/.../codex_agent.ex`):
  `"model"`, `"approval_policy"`, `"sandbox"`, and optional `"bridge_ws_url"`,
  `"codex_path"`. **Only include a key when its content value is a NON-EMPTY
  binary** (codex review MED: `bridge_ws_url`/`codex_path` feed sidecar/app-server
  paths and outpace codex `validate/1`; emitting a stray empty/non-binary value
  must not reach the runtime). nil/empty → omitted by the callback (the core
  nil-drop is a backstop, not the only guard).

### AgentTemplate content contract (codex review MED)

The AgentTemplate `:template` slice `content` is redefined as **a universal base
+ flavor-owned extras**: `flavor` + `working_directory` are universal; the rest
of the content is whatever THAT flavor's `template_data_extra/1` reads. Update
the normative docs accordingly:
- `Ezagent.Behavior.Template` moduledoc (currently lists a cc-only field set).
- `Ezagent.Entity.AgentTemplate` moduledoc ("what is NOT in the slice" cc note).
The surfaces that POPULATE content must supply the flavor's required fields:
`Behavior.Template` `:write` (the `template.write` path used by seeds + the
orchestrator's `save_template_as`), the LiveView template form, and any flavor
seed. `handle_write/2` persists arbitrary maps today, so no writer code changes
— but a curl/codex AgentTemplate created WITHOUT its required fields will now
fail fast at `to_template_data` (the validate above), which is the intended
loud behavior.

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
- **Fail-fast (codex review HIGH)**: a curl-flavored content MISSING `provider`
  (or empty) → `to_template_data/2` returns `{:error, {:invalid_template_data,
  _}}` (NOT a base-only map that would spawn a nil-config worker).
- **Invariant**: the callback output never contains reserved keys
  (`class`/`agent_uri`/`cwd`); nil extras are dropped; codex optional
  path-fields are omitted unless non-empty binaries.
- **Live (the gate, after merge)**: orchestrator `add_agent_slot` a curl worker
  + `put_api_key` + `write_matcher` → the worker calls DeepSeek and replies,
  mirrored to the bound Ezagent Feishu group (`FeishuClient send_text code=0`). Same
  for codex once its bridge bug is fixed.

## Risk / back-compat

Lowest-risk: cc's callback reproduces the exact current cc set, so the
cc-orchestrator seed (atom-keyed content) and all existing cc agents are
unchanged. Non-cc flavors that previously relied on the cc set being threaded:
none (only cc reads `claude_config_dir` et al.). Flavors without the callback
(echo/np/…) get base-only, which is what they effectively used before (they do
not read cc keys).
