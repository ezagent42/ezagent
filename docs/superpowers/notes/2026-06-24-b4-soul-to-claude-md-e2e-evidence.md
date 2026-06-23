# B4: E2E evidence — cc agent with `soul:` writes soul to CLAUDE.md on disk

**Date:** 2026-06-24
**Branch:** `agent-contract-echo-soul`
**Task:** B4 (soul → CLAUDE.md E2E proof)

## Evidence

Run: `POSTGRES_PORT=5432 mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_soul_to_claude_md_e2e_test.exs --seed 0`

```
2 tests, 0 failures
```

### Live evidence from standalone evidence capture (same test code path)

```
=== B4 EVIDENCE ===
agent_uri:   entity://b4-evidence-1602/agent/b4-evidence-25987
config_dir:  /Users/daiming/.ezagent/default/cc-agents/b4-evidence-1602/b4-evidence-25987
CLAUDE.md path: /Users/daiming/.ezagent/default/cc-agents/b4-evidence-1602/b4-evidence-25987/CLAUDE.md
CLAUDE.md content:
SOUL_MARKER_B4 — 你是前台导购助手，简短友好地回答顾客问题。
Contains SOUL_MARKER_B4: true
=== END B4 EVIDENCE ===
```

**Soul reached CLAUDE.md on disk: YES.**

## Chain verified

```
Workspace.create_agent(..., %{flavor: "cc", with_pty: false, soul: "SOUL_MARKER_B4 — ..."})
  → Behavior.Workspace.AgentCreate.do_create_agent/4
  → manifest_cc_tmpl/3
    → %AgentManifest{soul: ...}
    → AgentManifest.to_template_content/4
    → content[:agent_manifest_resolved].instructions = soul_text
  → to_cascade_content/1 passes :agent_manifest_resolved through
  → Entity.Agent.spawn_from_template_content/5
  → AgentTemplate.to_template_data/2
    → template_extra(CcAgent, content)
    → CcAgent.compile(resolved, params)
    → compile_cc_agent_data → data["claude_md"] = soul_text
  → CcAgent.instantiate/3
    → spawn_for_local_pty/3
    → create_agent_config_dir_with_grant/2
    → HomeRuntime.stage_and_swap/6
    → HomeRuntime.apply_derived_config/2
    → File.write(Path.join(staging, "CLAUDE.md"), data["claude_md"])
    → atomic_replace(staging, target)
  → CLAUDE.md on disk at per-agent config dir
```

## Test file

`apps/ezagent_plugin_cc/test/ezagent/template/cc_soul_to_claude_md_e2e_test.exs`

Two tests:

1. **soul-present**: cc create with `soul: "SOUL_MARKER_B4 ..."` → asserts `File.exists?(CLAUDE.md)` and `String.contains?(content, @soul_marker)`.
2. **soul-absent regression**: cc create without soul → asserts config_dir still created; asserts SOUL_MARKER_B4 is NOT in CLAUDE.md.

## Note on PTY

`with_pty: false` is set in the args but the cc instantiate always attempts PTY spawn. In `:test` env, `SpawnPlan.build_pty_params/4` short-circuits to `{:ok, %{cwd: cwd, test_mode: true}}` — no real `claude` process. CLAUDE.md is written in `create_agent_config_dir_with_grant` BEFORE PTY launch, so it exists regardless of PTY outcome.
