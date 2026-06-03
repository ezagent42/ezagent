# SPEC: domain.agent credential lifecycle (#17) — flavor-generic (rev 2)

> **Status:** rev 2 — Allen decisions D1–D4 LOCKED (2026-06-03 Feishu) + codex
> adversarial-review rev-1 findings folded (NO-SHIP → resolved below). For
> re-adversarial-review BEFORE implementation. Builds on `2026-06-02-domain-agent-design.md`
> + PR-3 (`Ezagent.Sandbox.ConfigDir`, `CLAUDE_CONFIG_DIR` → per-agent sandbox).

## Locked decisions (Allen 2026-06-03)

- **D1 — test mechanism = OAuth FILE path (fidelity), via refreshToken refresh.** NOT
  API-key. **Architectural call: API-key auth is its own future FLAVOR** (API access ⇒
  third-party models), not an auth-mode of cc — out of scope here. The cc credential
  lifecycle is anchored on the real OAuth `.credentials.json` users actually produce.
- **D2 — ② expiry notification** carries a **clickable terminal-PTY URL** (Tailscale
  `100.64.0.27`) the user taps to enter the agent's terminal and run `/login`.
- **D3 — ③ inheritance** = copy-at-spawn + owner-re-login resync; the **owner must be
  resolved explicitly** (the user's root/default agent), NOT the lineage parent.
- **D4 — codex is in scope**, reusing the **already-live codex agent config** (node
  `~/.codex`) as the source — no new codex cred model built.

## rev-1 codex findings → rev-2 resolutions

- **BLOCKER (test-provision callback can't express API-key env):** moot — D1 chose the
  OAuth FILE path, so `provision_test_credentials/1` writes a FILE into the cred home;
  the file-writer shape is correct. (API-key/env is a separate flavor, D1.)
- **BLOCKER (owner ≠ lineage parent; session workers' spawned_by = orchestrator):**
  resolved — §3.③ defines an explicit, cap-checked credential SOURCE; lineage is not the
  authority. (D3 "owner 搞准".)
- **BLOCKER (cc-shaped, codex generality overclaimed):** resolved — §3.0 defines TWO
  credential MODELS (per-agent-isolated vs node-shared); codex's adapter is the
  node-shared reuse-live one (D4), concrete not deferred.
- **HIGH (3 callbacks on Kind.Template not "thin"):** resolved — a SEPARATE
  `Ezagent.Agent.CredentialAdapter` behavior, registered per flavor, all-or-none opt-in
  (mirrors the extension-callback all-or-none precedent).
- **HIGH (persistence over-claim; stale-marker rm_rf clobbers user creds):** resolved —
  §3.① adds a credential-aware guard: never `rm_rf` a target whose declared credential
  files exist; the claim is narrowed.
- **HIGH (inheritance copies whole tree; bypasses sandbox.read cap):** resolved — §3.③
  uses a FILTERED copy of only declared credential files + reuses the existing
  `sandbox.read` authorization seam.
- **HIGH (OAuth rotation hazard for shared E2E fixture):** resolved — §3.④ uses a
  per-test disposable/locked credential source + atomic write-back of the rotated token.
- **MEDIUM (auth-detection on the stdin-sending auto-prompt scanner):** resolved — §3.②
  is a SEPARATE PTY event detector that emits an event + notifies; never sends bytes.

## 1. Problem (unchanged from rev 1 — abbreviated)

cc login = `<config_dir>/.credentials.json` (`claudeAiOauth.{accessToken, refreshToken,
expiresAt, scopes, subscriptionType, rateLimitTier}`); access ~daily expiry; refresh
tokens single-use/rotated. Today: no persistence contract, silent mute on expiry (no PTY
auth-failure rule), no inheritance wiring, no test provisioning (manual cp / human
/login), codex has no cred code (uses node `~/.codex`). claude-code itself has a known
headless/copied-creds auto-refresh bug (#21765/#50743) → the 传话游戏 403.

## 2. Scope

Prod: ① persistence, ② clear-error+notify, ③ inheritance. Test/E2E: ④ auto-provision.
**Non-goals:** API-key auth (separate flavor, D1); production runtime auto-refresh
(users re-login); explicit HTTPS_PROXY threading (node OS-env inheritance, → #21);
codex per-agent cred isolation (codex reuses node config, D4).

## 3. Design

### 3.0 Two credential MODELS behind one adapter

`Ezagent.Agent.CredentialAdapter` (new behavior; a flavor implements ALL callbacks or
NONE — enforced by an invariant test like the extension-contract one):

```
@callback credential_model() :: :per_agent_file | :node_shared
@callback credential_home(agent_uri) :: {:ok, path} | :node   # where login state lives
@callback credential_relpaths() :: [String.t()]               # the files that ARE login state
@callback auth_failure_signals() :: [%{match: Regex.t()|String.t()}]  # PTY expiry signatures
@callback provision_test_credentials(home_path) :: :ok | {:error, term}  # ④, test/dev only
```

- **cc** → `:per_agent_file`; home = the PR-3 per-agent `config_dir`; relpaths =
  `[".credentials.json"]`; signals = `["Please run /login", "API Error: 403", ~r/401/]`;
  provision = OAuth refresh (§3.④).
- **codex** → `:node_shared`; home = `:node` (node `~/.codex`, already live, D4);
  relpaths = `["auth.json"]`; signals = codex's expiry text (open: confirm);
  provision = no-op (live node config already valid).

Domain owns the LIFECYCLE (persist/notify/inherit/test-orchestrate); the adapter supplies
only the flavor specifics. North-Star: a new flavor adds an adapter, touches no domain
credential code.

### 3.1 Persistence
- cc: `/login` writes into `CLAUDE_CONFIG_DIR` = per-agent `config_dir` (PR-3). Restart
  reuses the dir untouched; re-instantiate hits the marker → no re-copy.
- **Guard (codex HIGH):** `materialize_config_dir` MUST NOT `rm_rf` a marker-absent target
  when any `credential_relpaths/0` file exists in it — back up + refuse with a structured
  error (a credentialled-but-markerless dir means a real login we must not destroy), not
  a blind wipe. Narrowed claim: "marker-present OR credentialled dirs are never
  auto-wiped."
- Prod reference/seed dir ships NO `.credentials.json` (user supplies via /login).
- Test: re-instantiate after a written credential preserves it (regression test).

### 3.2 Clear error on expiry + notify (D2)
- A SEPARATE PTY event detector (NOT `default_auto_prompts`, which sends stdin bytes):
  scans stripped output for the adapter's `auth_failure_signals/0`; on match emits
  `[:ezagent, :agent, :auth_failed]` telemetry + a phase signal AND notifies the owner.
- **Notification** (D2): to the owner's channel — "Agent <uri> needs re-login" + a
  **clickable terminal URL** `http://100.64.0.27:<port>/.../terminal/<agent_uri>` so the
  user taps in and runs `/login`. Owner resolved per §3.3.
- No auto-`/login`, no swallow, no degrade (`feedback_let_it_crash_no_workarounds`).
- Signal fragility (codex MEDIUM): regex on UI text is best-effort; mark as the V1 signal,
  prefer a stable bridge/exit signal if one surfaces (UNVERIFIED until found).

### 3.3 Inheritance (D3) — explicit, cap-checked, filtered
- **Credential SOURCE resolution (codex BLOCKER fix):** NOT the lineage parent. The
  source is EITHER (a) an explicitly selected source agent (operator/caller chooses), OR
  (b) the **caller's root/default agent** (`<username>-default`, per
  `project_username_default_agent`). Resolved by an explicit function, not `spawned_by`.
- **Authorization (codex HIGH):** reading the source's credential home REUSES the existing
  `sandbox.read` cap seam (as `mix ezagent.agent.create --from` does) — lineage may
  PROPOSE a default source, but the `sandbox.read` check AUTHORIZES the copy. Unauthorized
  → fail before any filesystem work.
- **Filtered copy (codex HIGH):** copy ONLY `credential_relpaths/0` (+ explicitly allowed
  settings/skills) from source home → child home — NEVER point the child's `config_dir`
  reference at the source's realized dir (that would drag session/bridge/runtime
  artifacts).
- Timing (D3): copy-at-spawn (V1) + resync owned agents when the owner re-logs in
  (triggered off the owner's `/login` success / a fresh `.credentials.json` mtime).

### 3.4 Test/E2E auto-provision (④, D1 = OAuth refresh)
- The harness, before launching E2E agents, calls the adapter's
  `provision_test_credentials/1`.
- **cc:** refresh via `POST https://console.anthropic.com/api/oauth/token`
  (`grant_type=refresh_token`, `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e`,
  `refresh_token=<stored>`), write the returned `accessToken`+rotated `refreshToken`+
  `expiresAt` into the agent's `.credentials.json`. **Rotation safety (codex HIGH):** the
  source refresh token is a per-test **disposable/locked copy** (a dedicated test
  credential, NOT Allen's live host cred) with an exclusive lock around
  read→refresh→atomic-write-back, so concurrent E2E tests never invalidate each other's
  source. Endpoint path (`/api/oauth/token` vs `/v1/oauth/token`) VERIFIED against a live
  cred before relying on it.
- **codex:** no-op — relies on the already-live node `~/.codex` (D4). (If E2E needs codex
  and the node lacks codex auth, that's an ops precondition like proxy, → #21.)
- All provisioning guarded to non-`:prod` Mix.env / explicit test allow-flag.

## 4. Decomposition (small PRs)
- **PR-A:** `CredentialAdapter` behavior + cc adapter (model/home/relpaths/signals) +
  all-or-none invariant test. cc wired; codex adapter (node-shared, provision no-op).
- **PR-B:** ① persistence guard (credential-aware stale-wipe refusal) + regression test.
- **PR-C:** ② auth-failure detector + owner notify-with-PTY-URL (D2).
- **PR-D:** ③ explicit cred-source resolver + `sandbox.read` cap + filtered copy
  (copy-at-spawn) + owner-resync.
- **PR-E:** ④ cc OAuth-refresh test provisioner (disposable/locked source, atomic
  write-back) + wire 传话游戏 E2E to it (no human /login).

## 5. Open items
- Confirm codex's `~/.codex/auth.json` schema + expiry PTY signature (for the codex
  adapter's `auth_failure_signals/0`); codex provision stays no-op in V1.
- Verify the refresh endpoint path against a live cred before PR-E.
- macOS Keychain: file-based ①③ hold only on the Linux prod node (runbook note).

## 6. Process
codex adversarial-review rev 2 → writing-plans per PR → TDD. Implement PR-A→E in order;
each PR → codex code-review before merge.
