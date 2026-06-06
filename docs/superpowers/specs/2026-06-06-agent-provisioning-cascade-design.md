# SPEC: Multi-level agent provisioning — layered credential/config cascade (domain.agent)

> **Status:** design rev 2 — codex adversarial-review (rev 1) folded: 4 HIGH + 1 MED
> addressed (durable spawn-time authorization §5.1; concrete user credential source
> §5.2; cold-restart re-resolution §4 + D3; secret-vs-config path split §3 D5/D6;
> directory tombstones §3 D4). Allen-approved in brainstorm 2026-06-06. Builds on and
> **supersedes the
> inheritance half (PR-D / §③) of** `2026-06-03-agent-credential-lifecycle.md`
> (whose PR-A/B/C/C2/E are already merged: #551/552/553/555/556). Builds on
> `2026-06-02-domain-agent-design.md` (PR-3 `Ezagent.Sandbox.ConfigDir`) and
> the unify-uri-query URI invariants (#577).

## 1. Problem

A freshly-created agent has **no credentials** → it 401s on first use (cc/codex
OAuth) or has `:no_api_key` (curl) until someone manually copies creds in (today:
the demo seed task or a hand `cp`). There is no production flow for "a user creates
10 agents and they all just work without logging in 10 times."

Generalizing (Allen 2026-06-06): the real question is **how an organization provides
pre-built agent configuration at different levels** — a workspace offers a curated
set of agents (plugins + config, maybe shared service credentials); a user supplies
their own login once and all their agents inherit it; a session adds a role. The
narrow "copy credentials at create" (the prior spec's PR-D ③) is one slice of this.

## 2. Goals / non-goals

**Goals**
- A created/spawned agent's credentials + config are **resolved by merging
  organizational layers**, so one user login serves all that user's agents and one
  workspace config serves all its agents.
- Resolution is **live** (re-login propagates; workspace config updates flow) without
  re-introducing shared-file hazards.
- The mechanism is **universal across flavors** (cc, codex, curl, echo, np) and lives
  on **domain.agent**; flavors only declare how their resolved credential/config is
  materialized.

**Non-goals (V1)**
- Deep per-key JSON merge of structured config (V1 = whole-file-replace; deep-merge is V2).
- An org/global layer above workspace (extension point left; YAGNI now).
- Pinned/versioned layer references (V1 = live; pinning is V2).
- Eager watch-triggered restart on external credential regen (V1 = lazy; V2 option).
- Production OAuth auto-**refresh** (separate concern; the in-process CLI refresh via
  its own refresh_token is the flavor's business; this spec governs **inheritance**,
  not refresh).
- Forcing curl onto a `.env` file (curl keeps its live `:api_keys` slice; uniform
  file-ization is an optional later choice — see §6).

## 3. Decisions (locked in brainstorm 2026-06-06)

### D1 — URI unchanged; provenance stored; levels on template scope
- Agent URI stays `entity://<workspace>/agent/<name>` — opaque, **unique per
  workspace** (same name ⇒ same agent; no per-user namespacing). Confirmed against the
  unify-uri-query invariants: the 3-segment authority is hard-enforced
  (`validate_3seg_shape!` rejects a 4th segment), and `entity://`'s `<type>` slot is
  load-bearing (agent/user/worker), so a template/user dimension cannot be added to
  the agent URI the way `session://<ws>/<template>/<name>` carries its template.
- **Which template an agent derives from is provenance** — stored in
  `AgentTemplate.parent_template_uri` and read via `Ezagent.UriQuery`, **never parsed
  from / encoded in the agent URI** (the flavor-prefix anti-pattern unify-uri-query
  removed; even `session://`'s template segment is not parsed — `resolve_session_template`
  reads the stored `session_template_uri`).
- **Levels are a property of templates, not of agent URIs.** Templates are already
  workspace-scoped (`template://<workspace>/<type>/<name>`); user-level is expressed by
  an **owner attribute** (a user URI) on the template, not by a new URI segment.

### D2 — Layered cascade (composition model)
An agent's realized credentials + config are the merge of four layers, **low → high
precedence (later overrides earlier)**:

| # | Layer | Owns / contributes | Source |
|---|---|---|---|
| 1 | **flavor-base** (system) | flavor defaults: base settings, orchestrator skill, etc. | the flavor's reference dir (exists today) |
| 2 | **workspace** | curated shared config: plugins, shared MCP, team settings, optional **shared service-account credential** | workspace-scoped `AgentTemplate` (`template://<ws>/agent/<name>`) |
| 3 | **user** | the user's **credential** (their login) + personal customizations | user-owned template / the user's credential source |
| 4 | **session** | role / prompt / per-session bits | `SessionTemplate` / role facet (exists) |

### D3 — Live references via re-materialization at the consumer's read point
- References are **live, not pinned, not symlinked.** Symlinks are rejected: atomic
  write-rename (cc/codex rewrite creds on refresh) severs the link; a shared cred file
  races across agents; symlinks to external absolute paths break under home
  backup/restore (#120) and docker volume remap; and they re-open the per-agent
  isolation PR-3 just closed.
- The consumer (a cc/codex **subprocess**) reads its config/creds **only at process
  startup**, so the only effective materialization moment is **spawn**. Materializing
  into a running agent's dir has no effect (process won't re-read) and is unsafe (races
  with the process's own writes).
- **File flavors (cc/codex, "drive an external CLI"):** re-materialize the merged
  `config_dir` at spawn, reusing PR-B atomic staging (stage → atomic rename), extended
  to merge layers 1→4 instead of one reference dir.
- **In-process / SDK flavors (curl, "call an API in-VM"):** no subprocess, no file —
  the resolved credential is read **live** from the `:api_keys` slice each invoke; no
  spawn-materialize step.
- **Every external-CLI process start is a cascade-resolution boundary — including cold
  restart and sidecar self-heal (H3 fix).** The live guarantee fails if a BEAM restart
  or self-heal replays persisted `respawn_template_data` (a resolved *snapshot*) and
  launches the subprocess with stale config/creds after a relogin/rotation. Therefore
  `respawn_template_data` persists the **resolution INPUTS** (workspace / owner / session
  / explicit-source URIs + the approved `credential_source_uri`), NOT a resolved config
  snapshot; on every (re)start the materialize step **re-runs `resolve_layers/…` fresh**
  (re-walking workspace/user/session + re-validating the credential authorization §5.1).
  Spawn, cold restart, and self-heal all go through the same resolve→materialize path.
- A `watch` on an external credential regen (user re-login elsewhere / admin rotation)
  is **at most a V2 trigger to restart** dependent agents (restart → re-resolve →
  materialize); it never writes into a running agent.

### D4 — Merge rules
Two **disjoint** path classes per flavor (see D6): **config paths** participate in the
layer merge below; **secret paths** do NOT merge — they come from the single credential
source (D4.3). A path may be in exactly one class (codex `config.toml` is config, NOT
secret — H4 fix).

1. **Whole-file-replace** (V1): for same-path **config** files (e.g. `settings.json`),
   the higher layer's file wins entirely. (Deep per-key JSON merge for `.mcp.json` /
   `settings.json` is V2.)
2. **Directory union with tombstones** (e.g. `plugins/`, `skills/`): union of files; on
   a filename collision the higher layer wins. A higher layer may **remove** a
   lower-layer file by shipping a **tombstone** for that relpath (a sibling
   `<name>.tombstone` marker, or an entry in the layer's `deny` manifest). After the
   union, every tombstoned relpath is deleted from the merged tree. This lets a
   user/session disable an inherited unsafe/outdated plugin/skill/MCP/hook it does not
   own (M1 fix). Tombstoning a path it cannot otherwise see is allowed (deny-by-relpath).
3. **Single credential source per agent.** Secret paths are **not** merged across
   layers. Exactly one source is chosen by precedence:
   **explicit (an operator-named source agent) > user (personal credential source,
   §5.2) > workspace (shared service account)**. Default = the user source.
   Workspace-shared is opt-in. No silent mixing; a missing/unauthorized/revoked source
   **fails loud** (no silent fallback to an empty or wrong credential), per
   `feedback_let_it_crash_no_workarounds`.

### D5 — Universality: domain resolution + flavor materialization
- **domain.agent owns RESOLUTION** (universal, flavor-agnostic): given an agent's
  workspace, owner, session, and any explicit source, resolve the ordered layer set
  and the single credential source, cap-checking each read (reuse the existing
  `sandbox.read` cap seam used by the `--from` path in
  `Ezagent.Behavior.Workspace`).
- **The flavor's adapter owns MATERIALIZATION** (the plugin-isolation boundary):
  - cc/codex: write resolved **config** files (from the merge) + copy **secret** files
    (from the single credential source) into `config_dir`.
  - curl: resolve the credential (API key) into the **`:api_keys` slice**.
  Whether an in-process flavor uses a slice or a `.env` file is a flavor-local
  adapter detail, NOT a cascade-design decision.

### D6 — Adapter contract splits SECRET paths from CONFIG paths (H4 fix)
`Ezagent.Agent.CredentialAdapter` (the merged PR-A contract) currently exposes one
`credential_relpaths/0`. That conflates token material with config: codex declares
`["auth.json", "config.toml"]`, but `config.toml` is **configuration**, not a secret.
Copying it from the single credential source would override workspace/session config
decisions made in the layer merge (importing another source's codex settings).

Split the contract into two disjoint sets:
- `secret_relpaths/0` — pure token material copied ONLY from the resolved credential
  source (cc: `[".credentials.json"]`; codex: `["auth.json"]`).
- config files (codex `config.toml`, cc `settings.json`, etc.) carry **no special
  treatment** — they are ordinary config paths that participate in the D4.1/D4.2 layer
  merge like any other file.

A path MUST be in at most one class; an invariant test asserts `secret_relpaths` and the
merged config paths are disjoint per flavor. This restores the clean "domain resolves
config (merge) vs selects credential (single source)" split.

## 4. Resolution algorithm (domain.agent)

At agent CREATE (human caller present, cap-checked) the credential **source** is
resolved and recorded; at SPAWN the merge is materialized.

```
resolve_layers(agent_uri, workspace_uri, owner_uri, session_uri, explicit_source?):
  layers = [
    flavor_base(flavor_of(agent_uri)),                # layer 1
    workspace_template(workspace_uri),                # layer 2 (may be absent)
    user_layer(owner_uri),                            # layer 3
    session_layer(session_uri),                       # layer 4 (may be absent)
  ]
  config   = merge_low_to_high(layers, rules=D4)      # files / dirs
  cred_src = pick_credential_source(                  # single source, D4
              explicit_source?, owner_uri, workspace_uri)   # precedence
  authorize!(cred_src, caller, caps)                  # sandbox.read cap; fail loud
  {config, cred_src}
```

- **CREATE-time** (human caller, caps): resolve + cap-check + persist the durable
  **`CredentialGrant`** (§5.1) and the resolution INPUTS into `respawn_template_data`
  (§D3) — NOT a resolved snapshot. No source read under `system://agent-internal` caps.
- **EVERY (re)start (spawn / cold-restart / self-heal):** re-run `resolve_layers/…`
  fresh, then materialize via the flavor adapter:
  - cc/codex: atomic-staging copy of the merged **config** paths (D4.1/D4.2, tombstones
    applied) + a copy of only the credential source's **`secret_relpaths`** (D6) —
    never the whole source dir, never config paths from the source;
  - curl: write the resolved key into `:api_keys`.
  The credential copy runs under the **grant-scoped principal** and re-validates the
  grant first (§5.1); failure is loud.

## 5. Cap / management model

| Layer | Managed by | Cap |
|---|---|---|
| flavor-base | system (plugin-provided, immutable) | n/a |
| workspace | workspace admin | `manage`-cap on the workspace (curate workspace template; authorize a shared service-account credential) |
| user | the user | owns their credential (their `/login`); personal template |
| session | session creator / orchestrator | existing session create / role caps |

- Resolving a credential **source** is cap-checked with the existing `sandbox.read`
  seam. A user reading their own source needs no extra cap; reading another agent's
  source (explicit source / workspace-shared) requires the caller to hold `sandbox.read`
  on it. Workspace-shared credentials require the workspace to have explicitly
  authorized the service-account source.

### 5.1 Credential authorization lifecycle — approve at CREATE, re-validate at every materialize (H1 fix)

The hazard: CREATE has a human caller + caps, but SPAWN / boot / cold-restart / self-heal
have **no human caller**. Using blanket `system://` caps there would let an agent keep
reading a **revoked or cross-user** source (leak); using no caps would break boot.

Model — a durable **credential grant**, not a re-derived cap check:
- **At CREATE** (human caller, caps present): authorize `sandbox.read` on the chosen
  source, then persist a durable **`CredentialGrant`** on the new agent:
  `{credential_source_uri, approved_by (principal URI), approved_scope (exact source URI
  + relpaths), granted_at}`. **Never** resolve a source under `system://agent-internal`
  caps (prior codex BLOCKER — privilege-escalation leak).
- **At every materialize** (spawn / cold-restart / self-heal — no human caller):
  the materializer acts under a **grant-scoped principal** derived from the stored
  `CredentialGrant` (authority bounded to exactly `approved_scope`), NOT blanket system
  caps. Before copying, it **re-validates** the grant: (a) the source still exists, (b)
  the grant has not been **revoked**, (c) `approved_scope` still matches the source's
  identity. Any failure → **fail loud** (agent does not spawn with stale/leaked creds);
  surface via the PR-C auth-failure notify path so the owner re-approves/re-logins.
- **Revocation:** deleting the source, or revoking the grant (operator/owner action),
  invalidates future materializations immediately (checked at next start). A running
  process keeps its loaded creds until it restarts — restart then fails-or-re-resolves.
- Tests (design-level): revoked grant, deleted source, cross-user source under a
  non-owning grant, and boot-time re-materialization all behave per the above.

### 5.2 The user credential source is a concrete Kind+slice — not a naming convention (H2 fix)

The merged lifecycle put `:api_keys` on **Agent** Kinds and cc/codex OAuth files in
per-agent `config_dir`s; there is **no User-Kind credential store today**, so "user is
the default source" has no concrete URI to authorize/read. Inferring it from the
`<username>-default` agent name is rejected (collision / drift → `:no_api_key` or
cross-agent credential reads).

Define the **user credential source** explicitly and durably:
- A per-**(owner, workspace, flavor)** credential-holder, addressed by a concrete URI
  and carrying the credential in its natural form (file flavors: a `config_dir` with the
  OAuth file; curl: an `:api_keys` slice entry). Candidate realization: the user's base
  agent for that flavor (e.g. `entity://<workspace>/agent/<owner-handle>-base`) **but
  referenced by a stored pointer, not by name-parsing** — a registry/attribute
  `user_default_credential_source(owner_uri, workspace_uri, flavor) -> source_uri`,
  written when the user first logs in / their base is created, **queried via UriQuery**.
  Uniqueness enforced on `(owner, workspace, flavor)`.
- `pick_credential_source/3` reads this stored pointer for the user layer — never a
  name convention. Absent pointer + required credential → **fail loud** (prompt the user
  to log in / create their base), never silent `:no_api_key`.
- **Migration:** existing per-agent `:api_keys` / per-agent OAuth dirs are adopted by
  registering the appropriate existing agent as the owner's default source for that
  (workspace, flavor); documented one-time step, no silent guess.

## 6. Flavor archetypes (informs materialization)

- **External-CLI / PTY** (cc, codex): config **must** be files (subprocess reads disk
  at startup) → spawn-time atomic-staging materialize.
- **In-process / SDK** (curl, and any future Claude-Agent-SDK-based flavor): config read
  in-VM → live slice read (or, optionally, a flavor-emitted `.env`). V1: curl keeps the
  live, cap-gated `:api_keys` slice (no subprocess ⇒ no natural re-materialize moment ⇒
  a file would add a "when to re-read" ambiguity the slice avoids).

## 7. Failure modes (let-it-crash)

- Missing/unauthorized credential source → **raise** (no silent empty credential, no
  default-workspace fallback). The agent fails to create/spawn with a clear reason.
- A layer that points at a non-existent template → raise at resolution, not a silent skip.
- Partial materialization is impossible by construction: atomic staging means a target
  config_dir is either the full merged tree or untouched (supersedes blind stale-wipe;
  PR-B guarantee, extended to the merged set).

## 8. Testing strategy

- **Cascade-order invariant:** a key set in workspace AND user layers resolves to the
  user value; a plugin present only in workspace appears in the agent; precedence holds
  across all four layers.
- **Single-credential-source invariant:** with user + workspace-shared both present,
  the user source wins; with an explicit source, it wins over both; with none and a
  required credential, resolution **raises** (no silent default).
- **Live-propagation test:** user re-login (new credential) → next spawn materializes
  the new credential (file flavors); curl reads the updated `:api_keys` live.
- **Isolation test:** materialized agent dirs are per-agent real files (no symlink to a
  shared source); a credential written into one agent's home does not appear in another's.
- **Flavor-parity invariant:** every flavor either implements the CredentialAdapter
  (file) or declares a slice-based credential resolver (curl); all-or-none gate (like
  the extension-callback contract).
- **curl inclusion:** an orch-spawned curl worker resolves its key from the
  workspace-shared layer when the user layer has none.
- **Authorization lifecycle (§5.1):** revoked grant → next start fails loud; deleted
  source → fails loud; a grant approved for source A cannot read source B; cold-restart
  re-validates rather than blindly replaying.
- **Cold-restart re-resolution (H3):** workspace template update OR user relogin
  **followed by a BEAM restart / self-heal** yields the NEW config/credential (not a
  stale `respawn_template_data` snapshot) — distinct from the fresh-spawn test.
- **Secret/config separation (H4):** an explicit credential source whose `config.toml`
  differs cannot override the workspace/session-merged `config.toml`; only `auth.json`
  (secret) comes from the source. Invariant: `secret_relpaths` ∩ merged-config-paths = ∅.
- **Directory tombstone (M1):** a higher layer removes an inherited plugin/skill/MCP/hook
  via a tombstone; the merged tree omits it.
- **User-source SoT (§5.2):** the default user source is read from the stored pointer,
  never name-inferred; absent pointer + required credential → fail loud, no `:no_api_key`.

## 9. Decomposition (small PRs, each → codex code-review)

- **PR-0 — `CredentialGrant` + user-source SoT (foundations, H1+H2).** The durable
  grant record (§5.1) + the `user_default_credential_source(owner,ws,flavor)` pointer
  registry queried via UriQuery (§5.2) + the `secret_relpaths`/config split in the
  adapter contract (§D6, H4). No cascade behavior change yet; migration step for
  existing per-agent creds. Invariant tests: grant revoke/delete/scope, disjoint
  secret∩config, user-source-from-pointer-not-name.
- **PR-1 — Resolution core (domain.agent).** `resolve_layers/…` + ordered layer
  enumeration + `pick_credential_source` precedence + grant-scoped authorize/re-validate;
  pure resolution returning `{config_layers, secret_source}`, no materialization change
  yet. Invariant tests for order + precedence + fail-loud.
- **PR-2 — Layered materialize for file flavors, at every (re)start (H3).** Extend PR-B
  atomic staging from one reference dir to merge layers 1→4 (whole-file-replace +
  directory-union + tombstones) + `secret_relpaths`-only copy from the resolved source;
  route spawn AND cold-restart/self-heal through resolve→materialize (respawn stores
  inputs, not snapshot). cc + codex. Tests: cold-restart re-resolution.
- **PR-3 — Workspace + user layer scoping.** Workspace-scoped AgentTemplate as layer 2
  (exists; wire as a layer); user-owned template (owner attribute) as layer 3; default
  resolution via the §5.2 pointer.
- **PR-4 — curl into the model.** curl’s `:api_keys` resolved through the same layered
  source precedence (workspace-shared key ⇒ user key ⇒ explicit); slice materialization
  adapter; flavor-parity gate.
- **PR-5 — (optional/V2) eager watch-propagation + deep-merge + pinned references** —
  deferred; tracked.

Sequencing note: PR-0 must land first (it defines the grant + source-of-truth + adapter
split that PR-1/PR-2 depend on). PR-2 depends on PR-1; PR-3/PR-4 follow.

## 10. Open items

Resolved in rev 2 (was open in rev 1): user-source storage → §5.2 (stored pointer);
credential-source vs `parent_template_uri` → §5.1 `CredentialGrant` is distinct from
provenance; directory-union delete → §D4.2 tombstones; spawn authorization → §5.1;
cold-restart staleness → D3/§4; codex `config.toml` conflation → §D6.

Still open (for PR-0/PR-1 planning + a second codex pass):
- **Workspace-shared service-account credential**: concrete storage of the shared
  source, the workspace-admin authorize step that mints the `CredentialGrant` for member
  agents, and rotation of the shared secret (re-validate semantics when it rotates).
- **`CredentialGrant` persistence location**: a slice on the agent Kind vs a dedicated
  grant store; and whether revocation is push (sweep grants) or pull (check at start).
- **Interaction with #533 creation-unification**: the resolution + grant minting MUST run
  inside the single authorized create chokepoint, not as a parallel path.
- **Migration concreteness**: the one-time adoption of existing per-agent `:api_keys` /
  OAuth dirs into per-(owner,workspace,flavor) default sources — exact mapping + operator
  command.
- Does any in-process flavor besides curl need a non-slice resolver shape?
