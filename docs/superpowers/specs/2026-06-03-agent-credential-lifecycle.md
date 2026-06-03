# SPEC: domain.agent credential lifecycle (#17) — flavor-generic (rev 3)

> **Status:** rev 3 — Allen D1–D4 LOCKED + codex experiment (codex per-agent isolation
> CONFIRMED) + codex adversarial-review rev-1/rev-2 findings folded. For re-review or
> direct PR-A entry (Allen's call). Builds on `2026-06-02-domain-agent-design.md` + PR-3
> (`Ezagent.Sandbox.ConfigDir`).

## Locked decisions

- **D1 — test mechanism = OAuth FILE path** (refreshToken refresh), NOT API-key.
  **API-key auth is its own future FLAVOR** (API ⇒ third-party models) — out of scope.
- **D2 — ② expiry notification** carries a clickable terminal URL built from the Phoenix
  route `/identities/agents/:uri/terminal` (URL-encoded URI) on the **deployment-configured
  ezagent base URL** (dev `100.64.0.27` / prod `app.ezagent.chat`) — not a hardcoded IP.
- **D3 — ③ inheritance** = copy-at-spawn + owner-re-login resync; credential SOURCE
  resolved + **cap-checked at agent-CREATION time** (human caller present), not spawn.
- **D4 — codex in scope.** **Experiment (2026-06-03) CONFIRMED:** codex creds copy into a
  per-agent sandbox + work via `CODEX_HOME` (relocates config AND auth — `codex --help`:
  `--ignore-user-config: auth still uses CODEX_HOME`; `codex doctor` with a copied
  `auth.json` → `✓ auth is configured`). So **codex is a first-class per-agent-file flavor
  symmetric to cc**, NOT node-shared. See [[reference_codex_codex_home_per_agent_auth]].

## Design — ONE parameterized per-agent-file model

Both flavors isolate credentials per-agent in a domain-allocated dir; they differ only in
parameters. The credential contract is a facet **implemented by the flavor's Template
Class** (the same module that materializes/wipes files — no parallel adapter that can
drift; codex rev-2 HIGH). It is a `@behaviour Ezagent.Agent.CredentialAdapter` that
`CcAgent` / `CodexAgent` implement, resolved via the existing flavor registry. All-or-none
opt-in, gated by an invariant test (like the extension-callback contract).

```
@callback credential_env_var()      :: String.t()      # "CLAUDE_CONFIG_DIR" | "CODEX_HOME"
@callback credential_relpaths()     :: [String.t()]     # [".credentials.json"] | ["auth.json","config.toml"]
@callback auth_failure_signals()    :: [Regex.t()|String.t()]   # PTY expiry signatures
@callback refresh_test_credentials(source, home) :: :ok | {:error, term}  # ④, non-prod only
```

| param | cc | codex |
|---|---|---|
| namespace (ConfigDir) | `cc` → `cc-agents` | `codex` → `codex-agents` |
| isolation env | `CLAUDE_CONFIG_DIR` | `CODEX_HOME` |
| cred file(s) | `.credentials.json` | `auth.json` (+ `config.toml`) |
| OAuth refresh endpoint | `console.anthropic.com/api/oauth/token` (client_id `9d1c250a-…`) | OpenAI/ChatGPT token endpoint (confirm) |

Domain owns the lifecycle (allocate home, persist, detect+notify, inherit, test-orchestrate);
the Template Class supplies only the params above + the actual file materialization.

### ① Persistence — atomic staging (codex rev-2 HIGH)
- The user's `/login` writes creds into the per-agent home (`CLAUDE_CONFIG_DIR`/`CODEX_HOME`
  → the PR-3-allocated dir). Restart reuses untouched; re-instantiate hits the marker → no
  re-copy.
- **Materialize via atomic staging:** cp the reference into a temp staging dir, then
  `File.rename` into the target. A target therefore NEVER contains a partial copy → a
  marker-absent target ALWAYS means "a real (possibly user-login) dir," which is NEVER
  `rm_rf`'d. Eliminates both the stale-partial-copy hazard (PR-3) AND the
  credential-clobber hazard in one mechanism (supersedes the rev-2 "credential guard").
- Test: a credential written into a materialized home survives re-instantiate + restart.

### ② Clear error on expiry + notify (D2)
- Add a **separate output-observer list** to `Ezagent.Domain.Pty.Server` (distinct from
  `default_auto_prompts`, which sends stdin bytes — codex rev-2 HIGH): observers match
  stripped output and EMIT an event only (no `send`). Refactor: `handle output → broadcast
  → run observers (emit) → run auto_prompts (may send)`.
- On a flavor `auth_failure_signals/0` match: emit `[:ezagent, :agent, :auth_failed]`
  telemetry + notify the owner's channel: "Agent <uri> needs re-login" + the D2 terminal
  URL. No auto-login, no swallow, no degrade.

### ③ Inheritance (D3) — authorize at CREATE, execute at SPAWN
- **At agent CREATE/fork (human caller w/ caps):** resolve the credential SOURCE — either
  an explicitly chosen source agent OR the caller's owner default (reuse the existing
  `creator_uri`-then-lineage owner model, `api_keys.ex`-style; NOT a new root/default
  invention — codex rev-2 HIGH). Authorize the read with the existing `sandbox.read` cap
  seam (`workspace.ex` `--from` path), THEN persist the approved source into the new
  agent's template. **No source read under `system://agent-internal` caps** (codex rev-2
  BLOCKER — privilege-escalation credential leak).
- **At SPAWN:** execute a FILTERED copy of ONLY `credential_relpaths/0` (+ explicitly
  allowed settings) from the approved source's home into the child's home — never point the
  child `config_dir` at the source's realized dir (codex rev-2 HIGH; that drags
  session/bridge/runtime artifacts).
- Resync owned agents on owner re-login (fresh cred-file mtime), V1 = copy-at-spawn first.

### ④ Test/E2E auto-provision (D1 = OAuth refresh)
- Harness calls `refresh_test_credentials(source, home)` per E2E agent before launch.
- cc: POST the source `refreshToken` to `console.anthropic.com/api/oauth/token`
  (`grant_type=refresh_token`, client_id), write the rotated tokens into the agent's
  `.credentials.json`. codex: the analogous OpenAI/ChatGPT refresh into `auth.json`
  (endpoint confirm).
- **Rotation safety (codex rev-2 HIGH/MEDIUM):** the source is a per-test
  disposable copy of a DEDICATED test credential (NOT the host's live cred), guarded by an
  **OS-level file lock** (flock on a lockfile path) spanning read→refresh→atomic-write-back
  so concurrent E2E BEAMs/processes can't invalidate each other's source.
- Guarded to non-`:prod` Mix.env / explicit allow-flag.

### Out of scope / non-goals
- API-key auth = separate future flavor (D1); cc's existing `api_key_helper` template field
  is **legacy**, explicitly excluded from this credential adapter (codex rev-2 MEDIUM).
- Production runtime auto-refresh (users re-login); explicit HTTPS_PROXY threading
  (node OS-env inheritance, → #21).

## Decomposition (small PRs, each → codex code-review)
- **PR-A:** `CredentialAdapter` behavior + cc & codex impls (params) + all-or-none invariant
  test; codex per-agent `CODEX_HOME` allocation (ConfigDir namespace `codex`) + `auth.json`
  copy + `CODEX_HOME` env at launch (mirrors cc's PR-3 wiring).
- **PR-B:** ① atomic-staging materialize (supersedes blind stale-wipe) + persistence test.
- **PR-C:** ② PTY observer list + auth-failure detector + owner notify w/ D2 terminal URL.
- **PR-D:** ③ create-time cap-checked source resolution + persisted approval + spawn-time
  filtered copy + owner-resync.
- **PR-E:** ④ OAuth-refresh test provisioner (flock'd disposable source, atomic write-back)
  + wire 传话游戏 E2E (cc + codex) to it (no human /login).

## Open items
- Confirm codex's OAuth refresh endpoint/params (for PR-E codex) + codex expiry PTY
  signature (PR-C `auth_failure_signals` for codex).
- Verify claude refresh endpoint path (`/api/oauth/token` vs `/v1`) against a live cred
  before PR-E.
- macOS Keychain: file-based ①③ hold on the Linux prod node (runbook note).

## Process
Allen: OK to enter PR-A (or one more codex review of rev 3)? Then writing-plans per PR → TDD.
