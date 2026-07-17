# cc-custom configurable completion backends — design

> **Date:** 2026-07-17 · **Author:** gaga Codex session (clarify-first handoff `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md`)
> **Status:** DRAFT — awaiting lead approval before any implementation
> **Base:** `origin/main` @ `66734aae52ce5f39c54ad5f4d34569cf929a6015` · **Branch:** `feat/cc-custom-backends` (worktree `.worktrees/cc-custom-backends`)

## 1. Goals / non-goals

### Goals

1. Replace the DeepSeek-specific cc backend (`cc-deepseek` / `cc-headless-deepseek`
   flavors) with **one provider-configurable backend facility per transport**
   (`cc-custom` / `cc-headless-custom`), driven by a **closed, server-owned
   provider-profile catalog**.
2. Prove **both DeepSeek and Kimi** through the real Claude Code/SDK seam with
   the same facility — no per-vendor runtime forks, no new Kind, no new Behavior.
3. Keep the credential contract of the deepseek line: deploy-provided API key,
   zero OAuth, zero `.credentials.json`, fail-fast launchability, and the
   automatic-lane "skip, don't halt" semantics — generalized over profiles.
4. Full migration parity with the existing deepseek surface (tests, seeds,
   config, CI) — the old source catalog is accounted for line by line
   (Appendix A).

### Non-goals (deferred, lead-approved phases only)

- Arbitrary third-party OpenAI/Anthropic-compatible providers beyond the two
  catalog profiles; a user-managed credential store or acquisition UI; provider
  health monitoring / quotas / failover / model discovery; Git Provider
  OAuth/token-broker integration; any UI beyond the existing flavor surfaces.
- The **curl agent's** own `provider: "deepseek"` concept
  (`apps/ezagent_domain_agent/lib/ezagent/behavior/curl_agent.ex:166-192`) is an
  OpenAI-shaped HTTP subsystem that merely shares the vendor name. It is
  **out of scope**; this design concerns only the cc flavor's
  Anthropic-compatible completion backend.

## 2. Verified vendor facts (R2 — primary sources, accessed 2026-07-17)

### 2.1 DeepSeek

Sources:
- `https://api-docs.deepseek.com/guides/coding_agents` (Claude Code guide)
- `https://api-docs.deepseek.com/guides/anthropic_api` (Anthropic-compat reference)

Documented Claude Code env block:

| Var | Documented value |
|---|---|
| `ANTHROPIC_BASE_URL` | `https://api.deepseek.com/anthropic` |
| `ANTHROPIC_AUTH_TOKEN` | `<DeepSeek API key>` (NOT `ANTHROPIC_API_KEY`) |
| `ANTHROPIC_MODEL` | `deepseek-v4-pro[1m]` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `deepseek-v4-pro[1m]` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `deepseek-v4-pro[1m]` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `deepseek-v4-flash` |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `deepseek-v4-flash` |
| `CLAUDE_CODE_EFFORT_LEVEL` | `max` |

Compatibility (anthropic_api reference): `system`, `max_tokens`, `stream`,
`tools` (`name`/`input_schema`/`description`), `tool_choice` fully supported;
`thinking` supported (`budget_tokens` ignored); image/document content types
NOT supported; `x-api-key` supported; `anthropic-beta`/`anthropic-version`
headers ignored; server-side model mapping: `claude-opus*` → `deepseek-v4-pro`,
`claude-haiku*`/`claude-sonnet*` → `deepseek-v4-flash`, unknown model →
`deepseek-v4-flash` fallback.

⚠️ **Delta vs current code:** `provider.ex:48-49` ships `deepseek-v4-pro` /
`deepseek-v4-flash`; the current docs recommend the `deepseek-v4-pro[1m]`
(1M-context) tag for the main slots. The catalog will ship the documented
values, with the app-env override retained (`:ezagent_plugin_cc` profile
overrides) so a deploy can retarget without a code change. The live proof
(§10) confirms the exact strings against the real endpoint.

### 2.2 Kimi (Moonshot)

Sources:
- `https://platform.kimi.ai/docs/guide/claude-code-kimi` (Claude Code guide;
  canonical host after 301 from `platform.moonshot.ai`)
- `https://platform.kimi.ai/docs/guide/agent-support` (agent overview)

Documented Claude Code env block:

| Var | Documented value |
|---|---|
| `ANTHROPIC_BASE_URL` | `https://api.moonshot.ai/anthropic` |
| `ANTHROPIC_AUTH_TOKEN` | `<Moonshot API key>` — guide explicitly says use `ANTHROPIC_AUTH_TOKEN`, remove `ANTHROPIC_API_KEY` to avoid conflicts |
| `ANTHROPIC_MODEL` | `kimi-k3` |
| `ANTHROPIC_DEFAULT_OPUS_MODEL` | `kimi-k3` |
| `ANTHROPIC_DEFAULT_SONNET_MODEL` | `kimi-k3` |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL` | `kimi-k3` |
| `CLAUDE_CODE_SUBAGENT_MODEL` | `kimi-k3` |
| `ENABLE_TOOL_SEARCH` | `false` |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `1048576` (kimi-k3 1M context; `262144` for kimi-k2.7-code) |

Notes: `ANTHROPIC_SMALL_FAST_MODEL` is NOT used by either vendor's current
guide (legacy). Kimi model variants: `kimi-k3` (default), `kimi-k2.7-code`,
`kimi-k2.6`, `kimi-k2.7-code-highspeed`. Verification per vendor: `/status`
shows base URL + model; send `hi`, a normal reply confirms end-to-end.
Vendor caveats: `/model` menu doesn't list Kimi models; WebFetch tool
unsupported by the endpoint.

**Schema consequence:** the env block is per-profile DATA with an open-valued
static map (Kimi needs two vars DeepSeek doesn't; DeepSeek needs
`CLAUDE_CODE_EFFORT_LEVEL` Kimi doesn't document). The catalog must not
hard-code an "8-var" shape.

### 2.3 Credential-free shape reproduction (this session, 2026-07-17)

Mechanism proof that the ezagent env-block seam drives the **real** Claude Code
binary — the same binary + env the product launches via PTY `cmd_env` and the
SDK sidecar `env=`:

- Ran `claude` 2.1.212 (`-p`, `--dangerously-skip-permissions`) in a scrubbed
  `env -i` clean room (ambient `ANTHROPIC_API_KEY`/`ANTHROPIC_BASE_URL` of this
  session excluded; throwaway `HOME`/`CLAUDE_CONFIG_DIR`) against a **local
  stub** implementing a minimal SSE Messages endpoint.
- Env block = the DeepSeek shape (`ANTHROPIC_BASE_URL=http://127.0.0.1:8799/anthropic`,
  `ANTHROPIC_AUTH_TOKEN=sk-dummy-not-a-real-key`, model tiers as §2.1).
- **Result: exit 0, assistant reply received.** Captured requests:
  1. `POST /anthropic/v1/messages?beta=true` — `Authorization: Bearer` scheme,
     model `deepseek-v4-flash` (small-model slot honored), `stream: true`,
     `max_tokens: 32000`, system + tools present.
  2. `POST /anthropic/v1/messages?beta=true` — `Authorization: Bearer`,
     model `deepseek-v4-pro` (main model honored).
- Proves: (a) `ANTHROPIC_AUTH_TOKEN` → `Authorization: Bearer` header;
  (b) the base URL is a pure path prefix (`{base}/v1/messages?beta=true`) —
  both vendors' documented values fit; (c) the tiered model env vars are
  honored by the real binary; (d) no key material left the box.

### 2.4 Real vendor probes — commands (local run authorized 2026-07-17, §10 Q3)

This session had **no `DEEPSEEK_API_KEY` and no `MOONSHOT_API_KEY`** in its
environment (presence-checked, never printed), so research-phase probing was
blocked. The lead has since authorized the **local** PR-7 run: the operator
places the keys in `~/.ezagent/default/credentials/cc-custom.env`
(git-ignored, chmod 600 — see §10 Q3) and the proof commands source it
(`set -a; . ~/.ezagent/default/credentials/cc-custom.env; set +a`) so the
value never appears in command text, transcripts, logs, or the repo:

```bash
# DeepSeek — through the same env-block seam the product uses
set -a; . ~/.ezagent/default/credentials/cc-custom.env; set +a
env ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic \
    ANTHROPIC_AUTH_TOKEN="$DEEPSEEK_API_KEY" \
    ANTHROPIC_MODEL=deepseek-v4-pro \
    ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4-pro \
    ANTHROPIC_DEFAULT_SONNET_MODEL=deepseek-v4-pro \
    ANTHROPIC_DEFAULT_HAIKU_MODEL=deepseek-v4-flash \
    CLAUDE_CODE_SUBAGENT_MODEL=deepseek-v4-flash \
    CLAUDE_CODE_EFFORT_LEVEL=max \
    claude -p "Reply with exactly: ok" --dangerously-skip-permissions

# Kimi — same seam
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

Record for each: command, sanitized env description, exit status, response
shape, model identity, duration, sanitized failure output. The build handoff's
product evidence (§11) additionally requires the transcripts through the
**product** path (spawned cc-custom agents), not bare CLI.

## 3. Approach comparison (R3)

Hard constraints from the codebase (all verified this session):

- **C1 — 1:1 flavor ↔ template class.** `AgentFlavorResolver.
  flavor_from_template_class/1` (`agent_flavor_resolver.ex:129-137`) and the
  class-name fallback (`:153-164`) reverse-scan `AgentFlavorRegistry.list_all()`;
  two flavors sharing one class make cold-restart flavor resolution ambiguous.
  `AdapterRegistry.validate_adapter` (`adapter_registry.ex:118-137`) rejects an
  adapter whose `flavor/0` ≠ registered flavor.
- **C2 — flavor is the credential-routing key.** `CredentialPrecondition`
  (`credential_precondition.ex:109-125`), `CredentialStatus.classify/4`
  (`credential_status.ex:67-82`), and the host-login-adopt seam all route via
  flavor → template class. A flavor's credential contract is per-flavor, not
  per-instance.
- **C3 — cold restart rides `respawn_template_data`.** Flavor is persisted as
  `respawn_template_data["flavor"]` (`cc_agent/spawn.ex:167-194`); non-reserved
  template-data keys (e.g. today's `"provider"`) survive
  `sanitize_respawn_template_data` and are replayed at respawn.
- **C4 — no back-compat shims** (SPEC v2 §5.11; `feedback_let_it_crash_no_workarounds`).
- **C5 — headless flavors need a `sync_result_action` clause** in
  `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex:339-345`,
  or replies fall to curl's global `:sync_result` and are dropped.

### Approach 1 — `cc-custom` / `cc-headless-custom` flavors + closed profile catalog (RECOMMENDED)

One new flavor per transport; vendor selection is template data
(`"provider" => <catalog profile>`) validated fail-closed against a
server-owned catalog. New thin template classes + thin bridge adapters satisfy
C1 exactly as today's deepseek shims do.

| Constraint | Verdict |
|---|---|
| C1 | ✅ one class per flavor; reverse lookups stay exact |
| C2 | ✅ the flavor's credential contract is "env-key of the selected profile" — uniform per flavor instance; status/precondition thread the profile (§6.4) |
| C3 | ✅ `"flavor" => "cc-custom"` + `"provider" => "deepseek"` both ride `respawn_template_data`; restart re-resolves without persisting any secret |
| C4 | ✅ old vendor flavors are deleted, not aliased |
| C5 | ✅ ONE new clause (`"cc-headless-custom"`); vendor count no longer grows this file |
| Secret non-egress | ✅ catalog (code) owns env-var names; user data only picks a profile NAME from the closed set |
| Vendor growth | ✅ new vendor = one catalog entry (+ tests); zero new modules/flavors |

### Approach 2 — keep `cc` / `cc-headless`, profile as pure template data

REJECTED. Collides with C2: `cc`'s template class declares
`credential_relpaths == [".credentials.json"]`, a host-login dir, and the #161
co-tenant host-login isolation flow. A Kimi-profiled `cc` agent would be
credential-checked, status-displayed, and host-login-adopted as if it were an
OAuth cc agent — including copying the operator's `.credentials.json` into a
vendor-backed agent's config home (secret-egress-adjacent, wrong isolation
model). The #1324 deepseek flavor exists precisely because the credential
model differs per backend; that difference is flavor-level in this codebase,
not data-level.

### Approach 3 — `cc-deepseek` as a migration alias + new custom flavors

REJECTED under C4 (no back-compat shims; retaining the alias is a
discuss-first item the handoff reserves for the lead, and it additionally
breaks C1's reverse lookup unless the alias shares a class). The repo's
established migration pattern is wipe + reseed, which §9 follows.

**Decision: Approach 1** — matches the handoff's expected direction and
violates no registry invariant.

## 4. Design

### 4.1 Provider-profile catalog (new, closed, server-owned)

New module `Ezagent.PluginCc.ProviderCatalog` — pure data + lookup, no I/O:

```elixir
%{
  name: "deepseek",                 # catalog key; the template-data value
  base_url: "https://api.deepseek.com/anthropic",
  api_key_env: "DEEPSEEK_API_KEY",  # SERVER-SIDE env var name; lives ONLY here
  static_env: %{                     # vendor-documented block minus URL+token
    "ANTHROPIC_MODEL" => "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_OPUS_MODEL" => "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL" => "deepseek-v4-pro[1m]",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL" => "deepseek-v4-flash",
    "CLAUDE_CODE_SUBAGENT_MODEL" => "deepseek-v4-flash",
    "CLAUDE_CODE_EFFORT_LEVEL" => "max"
  }
}
```

(Values per the current vendor guide, §2.1 — incl. the `[1m]` context tag,
which is §10 Q1's default answer; the deploy override covers either choice.)

…and the Kimi entry per §2.2. Closed set: `names/0 → ["deepseek", "kimi"]`,
`fetch/1 → {:ok, profile} | :error`. Profile values overridable via
`config :ezagent_plugin_cc` (same override pattern as today's
`:deepseek_base_url` etc., generalized per profile) so a deploy can retarget
endpoint/model tiers without a code change.

### 4.2 `Provider` refactor (facade over the catalog)

`Ezagent.PluginCc.Provider` keeps its chokepoint role, generalized:

- `provider_of/1` → `nil` (key absent or `"anthropic"`) | profile name.
- `provider_env/1`:
  - no provider key → `{:ok, %{}}` (plain cc path byte-unchanged);
  - known profile → `{:ok, static_env ∪ %{ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN}}`
    with the token read from `System.get_env(profile.api_key_env)`;
  - key missing → `{:error, {:backend_api_key_missing, profile}}`;
  - **unknown profile → `{:error, {:unknown_backend_profile, name}}`** —
    deliberate behavior change from today's silent anthropic fallback
    (`provider.ex:76-79`): locked decision #9 requires invalid profiles to be
    distinguishable and fail closed. Creation-time `validate/1` rejects them
    first; this is the defense-in-depth layer.
- `ensure_api_key/2` — `ensure_api_key(profile, uri) ::
  :ok | {:error, {:backend_api_key_missing, profile, uri}}`.
- `credential_status/1` — per profile: `:authenticated` | `:missing` with a
  detail string naming the ENV VAR (never the value).
- `bridge_topic_env/2` — **unchanged** (already vendor-neutral: reads
  `tmpl["flavor"]`).

### 4.3 New flavors / classes / adapters (parity with today's shims)

| Piece | New | Replaces |
|---|---|---|
| PTY flavor | `"cc-custom"` | `"cc-deepseek"` |
| Headless flavor | `"cc-headless-custom"` | `"cc-headless-deepseek"` |
| PTY class | `Template.CcCustomAgent` (`cc_custom.agent`) | `CcDeepseekAgent` |
| Headless class | `Template.CcHeadlessCustomAgent` (`cc_headless_custom.agent`) | `CcHeadlessDeepseekAgent` |
| PTY adapter | `EzagentPluginCc.CcCustomBridgeAdapter` (topic `agent_bridge:cc-custom:`) | `DeepseekBridgeAdapter` |
| Headless adapter | `EzagentPluginCc.CcHeadlessCustomBridgeAdapter` | `CcHeadlessDeepseekBridgeAdapter` |

The classes are the same thin shims as today (delegate everything to
`CcAgent`/`CcHeadlessAgent`; distinct only for C1), with TWO contract deltas:

1. **`"provider"` is REQUIRED user input, not injected.** `validate/1` requires
   a `"provider"` key naming a catalog profile — `{:error, :missing_backend_profile}`
   / `{:error, {:unknown_backend_profile, name}}` (fail closed). The old
   deepseek shims injected `"provider" => "deepseek"` programmatically; the
   custom classes take it from template data, which is exactly why the catalog
   must be closed and validated (locked decision #7: user data names a profile;
   it never names an env var, URL, or model directly). Enforcement is
   structural on every spawn path via `to_template_data/2`'s
   `validate_for_flavor` (§4.5 link 2).
2. `instantiate/3` gates `Provider.ensure_api_key(profile, agent_uri)` with the
   resolved profile, then stores `"flavor"` + passes through
   `instantiate_for_flavor/4` unchanged.

CredentialAdapter surface (both classes): `credential_relpaths/0 == []`,
`secret_relpaths/0 == []`, `host_login_dir/0 == nil`, `credential_status(home,
opts)` → `Provider.credential_status(opts[:backend_profile])` (`:unknown` when
absent — never an alarm, per the #160 enum contract).

### 4.4 Credential routing — the one genuinely new seam

Today the env-credential checks are profile-blind because flavor == vendor.
With one flavor serving N profiles, the **profile must be threaded** at two
domain call sites (both already on the migration surface because they hardcode
the vendor today):

1. **Automatic lane pre-flight** — `CredentialPrecondition.check_source/3`
   (`credential_precondition.ex:64-71`) gains an optional profile argument:
   `check_source(installer, workspace_uri, flavor, opts \\ [])` with
   `opts[:backend_profile]`; the env-credential branch calls
   `module.credential_status(nil, backend_profile: profile)`. Callers
   (`DefinitionAgents`) read the profile from the role slot / template content
   (§4.5). Absent profile on a custom flavor → `{:skip,
   {:credential_unavailable, flavor}}` (fail closed, never a silent pass).
2. **Spawn-fail → skip reclassification** — `definition_agents.ex:585-586`
   generalizes from `{:deepseek_api_key_missing, _}` to
   `{:backend_api_key_missing, _profile}` (and the 3-tuple with uri). The
   "narrow by design" comment + skip-vs-fail contract are preserved.
3. **UI credential status** — `CredentialStatus.classify/4`
   (`credential_status.ex:103-117`) passes `opts` through to the TC already;
   the domain caller (`identity_data.ex:635-651` →
   `Domain.Agent.read_credential_status/2`) resolves the agent's
   `"provider"` from its persisted `respawn_template_data` (domain-side
   SnapshotStore read, same non-activating pattern as `slice_status/2`) and
   puts it in `opts[:backend_profile]`. The plugin TC stays pure
   (name in → status out); plugin code never touches SnapshotStore (SPEC §11).

### 4.5 Profile flow: content → template data → respawn (verified end-to-end)

The chain already exists; the design adds one additive link, no new machinery:

1. **Content seam exists.** `AgentTemplate.to_template_data/2`
   (`agent_template.ex:286-337`) builds a universal base + **flavor-owned
   extras** via `template_data_extra/1` — curl already contributes a
   `provider` content field through this exact seam
   (`agent_template.ex:108`). `CcCustomAgent.template_data_extra/1` =
   `CcAgent`'s fields + `content_field(content, :provider)` passthrough —
   an established pattern, not a new concept. **No content-contract change.**
2. **Fail-closed enforcement exists.** `to_template_data/2` ends with
   `validate_for_flavor(tc, data)` (`agent_template.ex:332-337`) — the
   spawn path runs the flavor's own `validate/1` before any instantiate, so
   a missing/unknown `provider` fails structurally before spawn, on every
   ingress (UI form, CLI, seed, socialware materialization).
3. **Role-slot link (the one additive change).** `DefinitionAgents.spawn_agent`
   (`definition_agents.ex:530-552`) calls
   `RecipeMaterializer.create_agent_from_recipe/1` with the role slot's
   `flavor`; `template_content/2` (`recipe_materializer.ex:47-78`) merges
   recipe config + optional fields into content. Add: role slot map gains an
   optional `provider` key → threaded into the spawn opts → one `maybe_put`
   into content. (Provider is a deployment/role choice, not recipe data —
   recipes stay flavor-free per `recipe_materializer.ex:42`.)
4. **Respawn.** Template data `"provider"` is non-reserved → survives
   `sanitize_respawn_template_data` → replayed at cold restart (C3). No
   secret ever persists: the profile is a NAME.
- Seeds: `CcOrchestratorSeed.write_template_slice` (`cc_orchestrator_seed.ex:431-440`)
  sets `flavor: "cc-custom"` + `provider: "deepseek"`; the built-in socialware
  definition (`definition_registry.ex:502-524`) sets role `flavor: "cc-custom"`
  + `provider: "deepseek"` (link 3).
- Kimi usage (post-build): an operator adds a `cc_custom.agent` template with
  `provider: "kimi"` (UI form gains a closed provider select fed by
  `ProviderCatalog.names/0`; CLI/config same key).

### 4.6 receive.ex headless clause (domain touch — flagged)

`receive.ex:345`: replace the `"cc-headless-deepseek"` clause with
`sync_result_action("cc-headless-custom"), do: :cc_headless_sync_result`.
Required by C5; one line; the file no longer grows per vendor. This and
`definition_agents.ex` are domain-side files on the migration surface because
they hardcode the retired vendor flavor — called out per the handoff's
conflict-avoidance rule.

### 4.7 Redaction / secret boundary (locked decision #6 — explicit)

- The key is read via `System.get_env(profile.api_key_env)` at launch-build
  time only, and lands in the child process env (PTY `cmd_env` / SDK `env=`) —
  identical to today's deepseek path. Accepted parity risk (unchanged):
  process env is `ps`-visible on the host.
- The key NEVER enters: template data, snapshot/respawn data, agent state,
  prompts, transcripts, workspace data, the config directory, logs, telemetry,
  or credential-status detail strings (status reports presence + env-var NAME
  only).
- Failure paths stay distinguishable (locked #9): `:missing_backend_profile` /
  `{:unknown_backend_profile, name}` / `{:backend_api_key_missing, profile}` /
  vendor auth failure (surfaced by the existing auth-failure observers, which
  the custom classes inherit from `CcAgent.auth_failure_signals/0`).

### 4.8 Unchanged-by-design (verified provider-neutral)

PTY env chain (`spawn_plan.ex:101-153` → `server.ex:638-647`), headless env
chain (`cc_headless_agent.ex:274-295` → `sdk_sidecar.ex:268` →
`ezagent_cc_sdk_worker.py:96,108`), bridge-topic mechanism, flavor registry /
resolver / adapter registry, `onboarding_bootstrap.ex`'s `ANTHROPIC_API_KEY`
confirm-guard (semantics reviewed: it guards the *erroneous* `ANTHROPIC_API_KEY`
case; both vendors authenticate via `ANTHROPIC_AUTH_TOKEN`, so it stays a
no-op for catalog agents — no change), `identity_data.ex` flavor lists
(extras flow automatically), Kimi/Moonshot greenfield (zero existing refs).

## 5. Migration (no shims — C4)

1. Retire `cc-deepseek` / `cc-headless-deepseek`: delete the 2 template
   classes, 2 bridge adapters, the 4 `application.ex` declarations, and
   `cc_deepseek_backend_test.exs` (replaced by `cc_custom_backend_test.exs` —
   Appendix B parity map).
2. Existing persisted deepseek agents: per repo migration policy, dev DBs are
   wiped + reseeded; any live deployment runs destroy-and-recreate of
   deepseek agents as `cc-custom` (operator runbook in the build handoff).
   No alias, no dual-read.
3. Seeds flip to `cc-custom` + `provider: "deepseek"` (§4.5); the stored
   socialware definition follows the existing explicit-reseed path
   (`mix ezagent.socialware.reseed_builtins orchestrator --force`).
4. `config/test.exs:86-100`: keep the `DEEPSEEK_API_KEY` dummy (profile still
   resolves it) + add a `MOONSHOT_API_KEY` dummy; mirror in
   `.github/workflows/ci.yml:179-185` + `.gitleaks.toml:16-19`.
5. Collateral updates: `scripts/audit_agent_skill_homes.exs:37` headless
   flavor list; `credential_adapter_completeness_test.exs:34-39` adapter
   roster; `arch_baseline_manifest.exs` def-count if it shifts.

## 6. Test strategy

`apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs` —
full parity with the retired deepseek suite (Appendix B), now parameterized
over BOTH profiles, plus new contract tests:

- catalog closedness: `fetch/1` on unknown → `:error`; env-var names exist
  ONLY in the catalog module (grep-gate test);
- `validate/1`: missing / unknown provider → the §4.3 structured errors;
- `provider_env/1`: anthropic → `%{}` (no leak), each profile → its full
  documented block, missing key → `{:backend_api_key_missing, profile}`,
  unknown profile → `{:unknown_backend_profile, _}`;
- credential status per profile (authenticated/missing/unknown-profile);
- PTY `cmd_env` carries the block + `agent_bridge:cc-custom:` topic; headless
  `sdk_sidecar_params` threads it; plain-cc path provably unchanged;
- cold restart: `respawn_template_data` with `flavor: cc-custom(-headless-custom)`
  + `provider` re-resolves (both resolver paths: flavor key + class name);
- `CredentialPrecondition` profile threading (skip when key missing, proceed
  when present, per profile);
- `definition_agents` spawn-fail→skip on the generalized atom;
- `receive.ex` clause → `:cc_headless_sync_result`;
- seed assertions updated (`cc_orchestrator_seed_flavor_test.exs`).

Gates (from the handoff, unchanged): focused tests,
`mix ezagent.arch.scan`, `mix ezagent.doc.scan`, `mix ezagent.uri_query.scan`,
`mix ezagent.check_invariants`, `mix format --check-formatted`,
`mix precommit`, PR-head CI.

## 7. Build slices (PR-sized, all onto `feat/cc-custom-backends`)

- **PR-1 Catalog + Provider generalization** — `ProviderCatalog`, `Provider`
  facade, profile-parameterized env/status tests. No flavor changes; deepseek
  suite stays green.
- **PR-2 `cc-custom` (PTY)** — class + adapter + registration + validation +
  UI form select + `provider` passthrough in `template_data_extra/1` (§4.5);
  PTY parity tests.
- **PR-3 `cc-headless-custom`** — class + adapter + `receive.ex` clause +
  headless parity tests.
- **PR-4 Credential routing** — precondition profile threading, generalized
  spawn-skip, UI status `opts[:backend_profile]` path; domain tests.
- **PR-5 Seeds + config + collateral** — §5 items 3-5.
- **PR-6 Retire deepseek flavors** — deletions + suite rename to full parity;
  grep-gate: zero `cc-deepseek` refs outside docs/together history.
- **PR-7 Live proof (lead-authorized)** — §2.4 probes + product-path
  transcripts (§11 evidence); requires deploy keys.

Each PR: TDD (red test first), rebased on `origin/main`, independent CI green.

## 8. Rollout / rollback

Rollout: merge stack → deploy with `DEEPSEEK_API_KEY` (+ `MOONSHOT_API_KEY`
when Kimi is enabled) → reseed orchestrator definition → recreate deepseek-era
agents as `cc-custom`. Rollback: revert the branch (old flavors return) +
reseed; the catalog holds no state, so rollback is code-only.

## 9. Deferrals (explicit, lead-adjudicated)

All §1 non-goals; plus: `ANTHROPIC_SMALL_FAST_MODEL` (neither vendor documents
it now — not emitted), Kimi variants beyond `kimi-k3` (catalog extension when a
second model tier is product-required), curl-agent deepseek
renaming (untouched). The `[1m]` model-tag question is resolved (§10 Q1):
catalog ships `deepseek-v4-pro[1m]`; PR-7 live proof re-confirms the string
against the real endpoint (deploy override is the escape hatch).

## 10. Open questions for the lead — RESOLVED 2026-07-17

1. **`deepseek-v4-pro[1m]` vs `deepseek-v4-pro`** — **RESOLVED: ship the
   documented `[1m]` values** (lead, 2026-07-17). Catalog example in §4.1
   stands as written; PR-7 live proof re-confirms against the real endpoint.
2. **Role-slot `provider` key** — **RESOLVED: approved** (lead, 2026-07-17).
   Additive key on definition role maps, threaded per §4.5 link 3.
3. **Live-proof environment** — **RESOLVED: local** (lead, 2026-07-17). PR-7
   runs on the local dev host. Credential handoff for it:

   - The current credential mechanism is **process-env only**:
     `Provider.api_key/0` = `System.get_env("DEEPSEEK_API_KEY")`
     (`provider.ex:42,90`) — no DB store, no file in the repo, no vault, no
     rotation. Deploy supplies it via `docker-compose.disp.yml:27-28`
     (`env_file: ./secrets/ezagent.env`, git-ignored, operator-maintained);
     test/CI supply a dummy (`config/test.exs:86-100`, `ci.yml:179-185`);
     local e2e precedent is operator-per-run injection
     (`DEEPSEEK_API_KEY=sk-... bash docs/e2e/auto/run.sh`,
     `docs/e2e/scenario-07-curl-roundtrip.md:64` — "key 绝不入库").
   - cc-custom keeps this contract verbatim, generalized: the catalog
     allowlists the env-var NAME per profile; the operator supplies the VALUE
     through the process env. Nothing else changes.
   - For the local PR-7 proof the operator places the keys in a
     **git-ignored, chmod-600 env file outside the repo** (house style, cf.
     `docker/secrets/` + `~/.ezagent/<profile>/credentials/`):
     `~/.ezagent/default/credentials/cc-custom.env` containing
     `DEEPSEEK_API_KEY=...` / `MOONSHOT_API_KEY=...`. The proof commands
     source it (`set -a; . <file>; set +a`) so the value never appears in
     command text, chat, transcripts, logs, or the repo. The agent performing
     the proof references only the file PATH.

## 11. Build DoD (goal-derived, closed set)

- [ ] `cc_custom.agent` + `cc_headless_custom.agent` spawn end-to-end with
      `provider: "deepseek"` AND `provider: "kimi"` — one facility, both
      vendors, no vendor-specific module added.
- [ ] Unknown/missing profile fails closed with the §4.3 structured errors;
      missing key fails fast with `{:backend_api_key_missing, profile}`; the
      automatic lane skips (never halts) a key-less role slot.
- [ ] Cold restart of both custom flavors re-resolves flavor + profile from
      `respawn_template_data`; no secret in any persisted artifact (grep
      evidence).
- [ ] Plain `cc` / `cc-headless` behavior byte-unchanged (no catalog env
      leaks into their launch env — proven by test).
- [ ] Migration parity: every Appendix A row ticked; the retired suite's
      coverage survives in `cc_custom_backend_test.exs` (Appendix B).
- [ ] All §6 gates green on the PR head, rebased on `main`.
- [ ] Product evidence: two sanitized success transcripts through the real cc
      path (one DeepSeek, one Kimi) with provider profile, model, transport,
      command/path, timestamp/environment, response outcome — or the §2.4
      blocker recorded with lead-authorized commands.

---

## Appendix A — R1 migration parity checklist

Every deepseek-coupled site found by repo search (2026-07-17), each marked
**migrate** (changes with this design), **retain** (provider-neutral already),
or **defer** (lead decision). `file:line` against base `66734aae5`.

### Flavor registration / shims

| Site | Disposition |
|---|---|
| `plugin_cc/application.ex:97-100` (template_classes) | migrate — swap 2 classes |
| `plugin_cc/application.ex:121-141` (4 flavor decls) | migrate — swap 2 flavors/adapters |
| `template/cc_deepseek_agent.ex` (whole) | migrate — deleted, replaced by `CcCustomAgent` |
| `template/cc_headless_deepseek_agent.ex` (whole) | migrate — deleted, replaced by `CcHeadlessCustomAgent` |
| `plugin_cc/deepseek_bridge_adapter.ex` (whole) | migrate — deleted, replaced |
| `plugin_cc/cc_headless_deepseek_bridge_adapter.ex` (whole) | migrate — deleted, replaced |
| `plugin_cc/provider.ex` (whole) | migrate — catalog-backed facade (§4.2) |

### Domain hardcodes

| Site | Disposition |
|---|---|
| `behavior/agent/receive.ex:345` | migrate — clause → `"cc-headless-custom"` |
| `session_creator/definition_agents.ex:585-586` | migrate — generalized missing-key atom |
| `agent/credential_precondition.ex:64-71,109-125` | migrate — profile threading (§4.4.1) |
| `agent/credential_status.ex:103-117` | retain (opts passthrough) + caller threads profile (§4.4.3) |

### Seeds / config / CI

| Site | Disposition |
|---|---|
| `orchestrator/cc_orchestrator_seed.ex:431-440` | migrate — `cc-custom` + `provider: deepseek` |
| `socialware/definition_registry.ex:502-524` | migrate — role flavor + provider config (§4.5, Q2) |
| `config/test.exs:86-100` | migrate — add `MOONSHOT_API_KEY` dummy |
| `.github/workflows/ci.yml:179-185` | migrate — same |
| `.gitleaks.toml:16-19` | migrate — allowlist both dummies |
| `scripts/audit_agent_skill_homes.exs:37` | migrate — headless flavor list |

### Tests

| Site | Disposition |
|---|---|
| `test/ezagent/template/cc_deepseek_backend_test.exs` (410 lines) | migrate — replaced by `cc_custom_backend_test.exs` (Appendix B) |
| `test/ezagent/orchestrator/cc_orchestrator_seed_flavor_test.exs:5-63` | migrate — assertions → custom flavor |
| `test/integration/cc_config_home_credentials_test.exs:103-141,273-283` | migrate — flavor strings + comments |
| `domain_session` reseed/installation/materialize tests (`definition_registry_reseed_test.exs:158-247`, `installation_test.exs:55-68`, `ezagent_socialware_reseed_builtins_test.exs:72-79`, `definition_agents_materialize_test.exs:62-65,947`) | migrate — flavor strings |
| `architecture/credential_adapter_completeness_test.exs:34-39` | migrate — adapter roster |
| `arch_baseline_manifest.exs:348-350` | migrate if def-count shifts |
| comment sweep: `mcp_config_writer.ex:107,178`, `spawn_plan.ex:101-108`, `cc_agent.ex:332-334,437-440`, `cc_headless_agent.ex:80-83,102-107,274-279` | migrate — PR-6 comment rename (cc-deepseek → cc-custom / profile wording); no behavior change |

### Provider-neutral — retain untouched

`spawn_plan.ex` env merge chain, `cc_agent.ex` / `cc_agent/spawn.ex`,
`cc_headless_agent.ex` (except nothing — it is already profile-driven via
`provider_env/1`), `sdk_sidecar.ex:268`, `ezagent_cc_sdk_worker.py:96,108`,
`ezagent_mcp_bridge.py:135-145`, registries/resolver, `plugin.ex` boot chain,
`onboarding_bootstrap.ex`, `identity_data.ex` + `Identities.tsx`,
`credential_adapter.ex` contract, PTY server env charlist chain.

### Orthogonal — out of scope (defer)

curl-agent `provider: "deepseek"` subsystem (`curl_agent.ex:166-192`,
`plugin_curl_agent/*`, `hello/application.ex:152-156`, `Identities.tsx:230,1563`,
`docker/README.md:14-17`, e2e scripts), docs/together history (historical
record, not migrated), `docs/e2e` + `docs/scenarios` deepseek runbooks
(updated only where they instruct cc-deepseek flavor usage — doc sweep in
PR-6).

## Appendix B — retired-suite → new-suite parity map

| `cc_deepseek_backend_test.exs` describe | `cc_custom_backend_test.exs` disposition |
|---|---|
| `Provider.deepseek_env/0` (8 vars, key gate) | → `ProviderCatalog` + `provider_env/1` per profile (both vendors' documented blocks) |
| anthropic-no-leak (4 tests) | → kept verbatim + unknown-profile error test |
| `agent_flavors/0` + registry lookups | → custom flavors, both transports |
| template metadata / validate | → class names, namespaces, required-profile validation |
| credential adapter contract | → unchanged assertions on both new classes |
| fail-fast launchability gate | → `{:backend_api_key_missing, profile}` per profile |
| cold-restart flavor resolution (both paths) | → custom flavors + persisted profile |
| PTY launch env (8 vars + bridge topic) | → per profile; topic `agent_bridge:cc-custom:` |
| bridge adapters | → new modules, same assertions |
| headless sidecar env threading | → per profile |
