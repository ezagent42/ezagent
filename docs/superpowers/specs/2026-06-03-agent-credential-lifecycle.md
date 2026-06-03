# SPEC: domain.agent credential lifecycle (#17) — flavor-generic

> **Status:** DRAFT for Allen review + codex adversarial-review BEFORE implementation.
> Builds on domain.agent (`2026-06-02-domain-agent-design.md`) + PR-3 (per-agent
> `Ezagent.Sandbox.ConfigDir`, `CLAUDE_CONFIG_DIR` → sandbox). Terms: domain.agent spec.
> Allen decisions (2026-06-03, Feishu): users log in interactively (PTY + `claude /login`);
> our job is PERSIST + REUSE; auto-refresh is a TEST-SUITE capability (E2E must not need a
> human re-login); **the mechanism must apply to codex too, not just cc** → flavor-generic.

## 1. Problem

A cc agent's claude login is a file `<config_dir>/.credentials.json`
(`claudeAiOauth.{accessToken, refreshToken, expiresAt, scopes, subscriptionType,
rateLimitTier}`). access tokens expire ~daily; refresh tokens are longer-lived but
**single-use (rotated on use)**. Today:

- **No persistence guarantee surfaced as a contract** — creds happen to land in the
  sandbox because PR-3 sets `CLAUDE_CONFIG_DIR` there; nothing tests/owns "user-login
  creds survive respawn."
- **Silent mute on expiry** — claude prints `API Error: 403` / `Please run /login`; the
  PTY scanner (`Ezagent.Domain.Pty.Server.default_auto_prompts/0`) has NO auth-failure
  rule, so an expired agent receives mentions but never replies (the 传话游戏 symptom).
  NOTE: this is partly claude-code's own headless/copied-creds auto-refresh bug
  (anthropics/claude-code #21765, #50743, #34306 — it 401s instead of using a valid
  refreshToken when creds are copied to a headless node).
- **No inheritance** — `mix ezagent.agent.create --from <uri>` clones a source agent's
  config_dir manually; nothing wires lineage/ownership → a child's cred source.
- **No test/E2E provisioning** — only `Mix.Tasks.Ezagent.Demo.SeedCcSandbox` (copy host
  `~/.claude/.credentials.json`) + a manual `cp`; E2E needs a human `/login` per run.
- **Codex** has NO credential code at all (relies on node `~/.codex` / env).

## 2. Scope (Allen-confirmed)

**Production runtime (flavor-generic):**
- ① **Persistence** — creds the user writes via interactive `/login` (into the per-agent
  `config_dir` = `CLAUDE_CONFIG_DIR`) survive agent restart / re-instantiate, never
  clobbered.
- ② **Clear error on expiry** — detect the flavor's auth-failure signature in PTY output
  → notify the owner (channel) "re-login in agent X's terminal"; no silent mute.
- ③ **Inheritance** — user logs in once in one agent (e.g. `<username>-default`); its
  owned/forked agents inherit its creds at spawn via lineage.

**Test / E2E only:**
- ④ **Credential auto-provision** — the test harness makes valid creds available to E2E
  agents WITHOUT a human `/login`, so 传话游戏 E2E is self-sufficient (aligns with
  `feedback_self_generate_test_credentials`).

**NON-goals (explicitly dropped):** production auto-refresh runtime code; a custom login
flow (use the existing PTY terminal + `/login`); explicit `HTTPS_PROXY` threading (the
PTY child already inherits node OS env via erlexec — ops/deploy concern, #21).

## 3. Design — the flavor-generic credential contract

The DOMAIN owns the lifecycle; each flavor PLUGIN provides a thin **credential adapter**.
The adapter lives on `Ezagent.Kind.Template` as new OPTIONAL callbacks (a flavor with no
creds — curl/echo — omits them):

```
@callback credential_relpaths() :: [String.t()]
  # files within config_dir that ARE the login state (cc: [".credentials.json"];
  # codex: ["auth.json"]). Used by ③ inheritance (which files to carry) + ① (what to
  # assert persists).

@callback auth_failure_patterns() :: [Regex.t() | String.t()]
  # PTY output signatures meaning "expired/missing auth, needs re-login"
  # (cc: ~r/Please run \/login/, "API Error: 403"; codex: its equivalent).
  # Fed into the Pty scanner for ②.

@callback provision_test_credentials(config_dir :: String.t()) :: :ok | {:error, term}
  # TEST/DEV ONLY (④): write valid creds into config_dir so an E2E agent works without a
  # human /login. Guarded to non-:prod Mix.env (or an explicit allow flag).
```

The domain owns: where creds live (the PR-3 `config_dir`), persistence (marker
idempotence + restart-reuse), the owner-notification surface, and the lineage→source
wiring. The plugin owns ONLY the flavor specifics above. (North-Star: plugin authors add
a flavor without touching domain credential code.)

### ① Persistence (mostly already true — make it a contract + test)
- `/login` writes into `CLAUDE_CONFIG_DIR` = the per-agent `config_dir` (PR-3). Restart
  (`ensure_subprocess_alive`) reuses the dir untouched; re-instantiate hits the
  `.ezagent-config-complete` marker → idempotent, no re-copy (PR-3). So user creds
  persist by construction.
- **Hazard to close:** the production reference/seed dir must NOT ship a stale
  `.credentials.json` that the FIRST materialize copies over a real one. Fresh-create
  copies the reference BEFORE the user logs in, so the reference should be
  credential-less in prod (the user supplies creds via `/login`). Assert: a reference
  with no creds → empty cred slot → `/login` populates → survives respawn.
- **Deliverable:** a regression test "a credential file written into a materialized
  config_dir survives a re-instantiate (marker present → no re-copy)" — extends the
  existing PR-3 idempotence test, framed for creds.

### ② Clear error on expiry
- Add a domain-driven auth-failure rule to the Pty scanner: when PTY output matches the
  flavor's `auth_failure_patterns/0`, emit a structured signal (phase/telemetry) AND
  notify the agent's owner via the channel: "Agent <uri> needs re-login — open its
  terminal and run `/login`." (Owner resolved via lineage/`created_by`.)
- Must NOT auto-`/login` or swallow; it's an explicit, actionable notification (no silent
  mute, no degrade — `feedback_let_it_crash_no_workarounds`).

### ③ Inheritance (the one piece with real design weight)
- At fresh spawn of an owned/forked agent, the domain sets the new agent's `config_dir`
  REFERENCE to the OWNER's realized config_dir (so materialize cp_r's the owner's creds).
- "Owner" = the lineage parent (`record_lineage` / `created_by`) — typically the user's
  `<username>-default` agent the user logged into. Carry ONLY `credential_relpaths/0`
  files (+ existing settings/skills) — not transient state.
- Open: copy-at-spawn (snapshot; child diverges) vs re-sync on owner re-login. Recommend
  copy-at-spawn for V1 (simple, matches existing cp_r); re-sync is a later enhancement.

### ④ Test/E2E auto-provision — DECISION POINT (see §4)
- The harness calls `provision_test_credentials/1` for each E2E agent before launch.
- Two candidate mechanisms (flavor adapter implements one) — Allen to pick (§4 D1).

## 4. DECISION POINTS (Allen)

**D1 — ④ provisioning mechanism (the main fork):**
- **(i) OAuth refresh** — adapter POSTs the stored `refreshToken` to
  `https://console.anthropic.com/api/oauth/token` (`grant_type=refresh_token`,
  `client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e`), writes back the rotated
  access+refresh tokens. PRO: exercises the real OAuth cred path (high E2E fidelity);
  uses the subscription. CON: reverse-engineers claude internals (endpoint/client_id
  may change); single-use rotation means we MUST persist the new refreshToken or break
  the source; per-flavor (codex needs its own OpenAI refresh endpoint).
- **(ii) API key** — adapter writes `ANTHROPIC_API_KEY` (cc) / `OPENAI_API_KEY` (codex)
  into the agent env from the host's key. PRO: Anthropic's OWN recommendation for
  headless/CI; dead simple; never expires; generalizes across flavors uniformly; no
  reverse-engineering. CON: tests the API-key path, not the OAuth file path (lower
  fidelity to the production `/login` cred flow); uses API billing not the subscription.
- **Recommendation:** **(ii) API key for the E2E happy-path** (robust, flavor-generic,
  no brittle reverse-engineering) PLUS a SEPARATE small test that exercises the OAuth
  file path with a (i)-style refresh so ①③ are covered for the real cred shape. i.e.
  default E2E uses API-key; one focused test covers OAuth-refresh fidelity. ← challenge.

**D2 — ② owner-notification surface:** notify via the channel (Feishu) the owner reads,
keyed on `created_by`? Or also a LV badge on the agent? Recommend channel notify
(primary) + the existing PTY phase badge.

**D3 — ③ inheritance trigger:** copy-at-spawn only (V1), or also re-sync owned agents
when the owner re-logs in? Recommend copy-at-spawn V1.

## 5. Open items / investigation
- **Codex credential adapter:** confirm codex's cred file (`~/.codex/auth.json`?) +
  schema + its auth-failure PTY signature + whether `OPENAI_API_KEY` env suffices for
  headless. (Implement the cc adapter first; codex adapter follows, same contract.)
- **macOS Keychain:** on macOS `claude /login` stores creds in Keychain, not the file —
  so ①③ file-based persistence/inheritance only hold on the Linux prod node (acceptable;
  flag in the runbook).
- Verify the refresh endpoint path (`/api/oauth/token` vs `/v1/oauth/token`) against a
  live host cred before relying on (i).

## 6. Process
Allen picks D1–D3 → finalize SPEC → codex adversarial-review → writing-plans → TDD.
Implement cc adapter + the generic domain lifecycle first; codex adapter as a follow-up
PR on the same contract.
