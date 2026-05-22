# cc-agent configuration — operator runbook

How an operator configures a CC (Claude Code) agent in ezagent. The
**authoritative design** lives in `Ezagent.Entity.AgentTemplate`
(Phase 7) — read the moduledoc at
`apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex` first.
This page covers the operator-facing knobs, the macOS Keychain
caveat, and the credential-seeding question.

> **History.** A standalone `cc-agent-config` SPEC was drafted on
> branch `docs/cc-agent-config-spec` (2026-05-22, rev 2) but RETIRED
> 2026-05-23: the Phase-7 AgentTemplate slice already carries the
> exact same keys (`claude_config_dir` / `settings_path` /
> `mcp_config_path` / `api_key_helper`) and the cc Template Class
> already consumes them via
> `Ezagent.Entity.AgentTemplate.to_template_data/2`. AgentTemplate
> is the single source of truth; this runbook is the operational
> companion.

## The shape — what an AgentTemplate carries

Per `AgentTemplate` `:template` slice (Phase 7 completion PR-1,
SPEC §1.0):

| Field | Meaning | Default |
|---|---|---|
| `name` / `description` | display metadata | required |
| `flavor` | `"cc"` for Claude Code agents — resolves the Template Class via `AgentFlavorRegistry` | required |
| `working_directory` | the agent's `cwd` — where `claude` is launched | required |
| `claude_config_dir` | path → `CLAUDE_CONFIG_DIR` env var; relocates the entire `.claude/` state directory (credentials, OAuth, MCP cache, plugins, skills, session history) per-agent | optional (omit ⇒ inherits host `~/.claude/`) |
| `settings_path` | extra `--settings <file>` passed to `claude` — operator-supplied overlay | optional |
| `mcp_config_path` | extra `--mcp-config <file>` passed to `claude` — operator-supplied additional servers (the esr-bridge MCP server is always present, never replaced) | optional |
| `api_key_helper` | helper script that prints an API key on stdout — used to rotate keys per-template on macOS where Keychain is shared (§"macOS Keychain caveat") | optional |
| `default_caps` | cap policy the spawned worker inherits | required |
| `created_by` / `created_at` | audit fields | auto |

What is **not** in the slice (by design): prompt, model, effort, tools
whitelist, MCP servers. Those live inside the pointed-at
`claude_config_dir` (or the explicit `settings_path` overlay). ESR
does not re-model what CC already encodes — the AgentTemplate is a
*sandbox pointer + cap policy*, not a full agent spec.

## How the slice reaches `claude`

`Ezagent.Entity.AgentTemplate.to_template_data/2(content, agent_uri)`
returns a string-keyed map the cc Template Class
(`Ezagent.PluginCc.Template.CcAgent`) consumes. The four sandbox
keys flow into:

- `claude_config_dir` → `CLAUDE_CONFIG_DIR` env var on the spawned
  `claude` process (via the `:cmd_env` param to
  `Ezagent.Domain.Pty.start/2` — never a `VAR=val` shell prefix).
- `settings_path` → an `operator_settings_path` key →
  `build_claude_cmd/3` emits it as an additional `--settings`.
- `mcp_config_path` → an `operator_mcp_config_path` key →
  `build_claude_cmd/3` emits it as an additional `--mcp-config`.
- `api_key_helper` → preserved on the template-data map (mac
  multi-agent mitigation below).

## PTY safety override is non-bypassable

The plugin ships `priv/claude-pty-settings.json` which sets
`remoteControlAtStartup: false` — a PTY-correctness invariant, NOT a
preference. `build_claude_cmd/3` emits the plugin file **LAST** in
the `--settings` chain. Claude's `--settings` is last-wins, so an
operator `settings_path` that tries to set
`remoteControlAtStartup: true` is silently overridden by the safety
file. The operator overlay can still layer non-conflicting keys
(themes, ignore globs, etc.) — it just cannot re-enable remote
control.

A regression test in the cc plugin's test suite locks this in: a
hostile operator settings file with `remoteControlAtStartup: true`
MUST still yield `false` at runtime.

Equivalently, `mcp_config_path` adds servers but cannot delete the
trusted esr-bridge server (claude merges MCP configs additively).

## macOS Keychain caveat

On macOS, CC credentials live in Keychain regardless of
`CLAUDE_CONFIG_DIR`. Multiple agents running on the same OS user
therefore share Keychain credential access — `CLAUDE_CONFIG_DIR`
isolates everything else (settings, MCP cache, skills, session
history) but **not credentials**.

Mitigations, in order of operator preference:

1. **Populate `api_key_helper`** with a per-template helper script
   that returns a distinct API key. The cc Template Class threads
   it as the `api_key_helper` key; `claude` calls the helper to
   obtain the key, bypassing Keychain.
2. **Run each agent under a separate OS user.** Keychain is
   per-user, so this fully isolates.
3. **Accept the shared credential on dev macOS.** Production runs
   on Linux, where `CLAUDE_CONFIG_DIR` is the only credential
   store and isolation is complete.

The retired cc-config rev 2 SPEC ran a capability spike that
confirmed file-based credentials DO isolate via
`CLAUDE_CONFIG_DIR`; only the macOS Keychain path is shared.

## Credential seeding — the "fresh sandbox can't log in" problem

A sandbox with a brand-new empty `CLAUDE_CONFIG_DIR` cannot
authenticate `claude` on first launch — no credentials, no OAuth
state, no Keychain (Linux) / no Keychain entries the agent owns
(macOS).

**Operator responsibility (not automated by ezagent V1):** when
creating a new sandboxed AgentTemplate, the operator either:

- Pre-seeds the target `claude_config_dir` by copying the necessary
  credential files from a known-good source dir (typically the
  operator's `~/.claude/.credentials.json` and any
  `~/.claude/oauth*`), OR
- Configures `api_key_helper` to provide a key directly, sidestepping
  interactive login.

Automating this safely is deferred — the question is *which*
credentials are safe to copy and from *where*, and the answer is
deployment-specific. Document the seed path you used in the
AgentTemplate's `description`.

## Where this design lives in code

- `Ezagent.Entity.AgentTemplate` — the slice schema +
  `to_template_data/2` adapter. Read its moduledoc.
- `Ezagent.PluginCc.Template.CcAgent` — consumes the adapter output;
  `build_claude_cmd/3` is the precedence-correct argv builder. The
  argv-safe invocation (no shell, `execve` directly via erlexec)
  prevents operator string values from creating extra `--settings`
  flags.
- `Ezagent.AgentFlavorRegistry` — `flavor: "cc"` → the Template
  Class module (declarative, per the plugin-authoring contract).

## Pointers

- Phase 7 completion SPEC: `docs/superpowers/specs/2026-05-22-phase-7-completion.md` §1.0–§1.5 (slice + adapter)
  and §3 "cc-agent-config reconciliation" (why this runbook exists).
- Plugin authoring contract:
  `docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md` (the
  `:form` config surface is V2 — a plugin-settings store has not
  shipped).
- GLOSSARY: "AgentTemplate" + "`CLAUDE_CONFIG_DIR` per-agent
  isolation".
- ARCHITECTURE.md Decision #136 (AgentTemplate design rationale).
