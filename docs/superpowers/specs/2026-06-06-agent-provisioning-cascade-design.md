# SPEC: Multi-level agent provisioning — layered credential/config cascade (domain.agent)

> **Status:** design rev 4 — codex adversarial-review rounds 1+2 (mechanism) + round 3
> (goal/effect-level) folded. Round 3 closed three GOAL-level gaps: mandatory controls
> now survive ALL override modes via post-merge validation (D4.1, G1); explicit
> credential-selection state machine with workspace-shared fallback (D4.3, G2); relogin
> = in-place update of a stable per-(owner,ws,flavor) holder (§5.2, G3). §11 now states
> the end-to-end **acceptance gate**. Rounds 1+2 (mechanism) addressed as
> requirements/invariants, concrete mechanism deferred to PR-0/PR-1 (codex code-review
> gates the impl). Allen-approved in brainstorm 2026-06-06. Builds on and
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
   **Mandatory controls survive ALL override modes (round-3 G1 — precedence ≠ trust,
   for overwrite too).** A higher layer must not be able to drop a workspace/base
   security control by *replacing* a policy-bearing file with one that omits it (not
   just by tombstoning it). Therefore workspace/base layers declare a **mandatory set**
   (specific hooks / MCP servers / plugins / settings keys that MUST be present), and
   after the full cascade merge the materializer **validates the mandatory set is
   present and intact in the final tree** (a post-merge invariant). A lower-trust layer
   cannot remove OR replace-to-omit a mandatory control without the management cap; if
   the merged result is missing a mandatory control, materialization **fails loud** (or
   re-injects it, per the mandatory entry's policy). This makes "workspace mandatory
   config applies to every agent" hold regardless of how a higher layer tried to bypass.
2. **Directory union with tombstones** (e.g. `plugins/`, `skills/`): union of files; on
   a filename collision the higher layer wins. A higher layer may **remove** a
   lower-layer file by shipping a **tombstone** for that relpath (a sibling
   `<name>.tombstone` marker, or an entry in the layer's `deny` manifest). After the
   union, every tombstoned relpath is deleted from the merged tree.
   **Trust policy (round-2 H2' — precedence ≠ trust):** a lower-trust higher-precedence
   layer must NOT silently erase a higher-trust layer's security controls. Each layer
   declares a set of **protected/mandatory** relpaths (e.g. workspace policy hooks,
   required MCP/plugins). A tombstone from layer N can remove a contribution from layer
   M<N ONLY if that relpath is not in M's protected set; removing a protected path
   requires an explicit **management cap** at the removing layer (a user/session cannot
   tombstone a workspace/base mandatory hook). Non-protected inherited files remain
   freely tombstonable (the M1 use case — disable an inherited *optional* plugin).
   Mechanism (protected-set declaration + cap gate) deferred to PR-2 planning.
3. **Single credential source per agent — explicit selection state machine (round-3
   G2).** Secret paths are **not** merged across layers; exactly one source is chosen.
   The "default user / fail-loud" rule and the "workspace-shared service account" goal
   are reconciled by an explicit order with a clear absent-vs-revoked distinction:
   1. **explicit** source named at create (cap-checked) → use it.
   2. else **user** default source (the §5.2 pointer) **if present** → use it.
   3. else **workspace** authorized shared service-account source **if present** →
      use it. (This is the "no personal login, workspace provisions the agent" goal.)
   4. else (a credential is required but none of the above exists) → **fail loud**.

   **absent ≠ revoked.** A *missing* user pointer falls THROUGH to workspace-shared
   (step 2→3) — normal provisioning. A source that WAS selected but is now
   **revoked / unauthorized / deleted fails loud and does NOT silently fall through**
   to a different source (no surprise privilege downgrade/upgrade; the operator must
   re-approve or explicitly choose). No silent mixing; per
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

**Required invariants (round-2 H1' — mechanism deferred to PR-0/PR-1, gated by codex
code-review):**
- **Versioned grant + revocation epoch.** The `CredentialGrant` carries a monotonic
  `version`/epoch. Revocation bumps it. There is a single durable grant store with a
  defined read path (PR-0 chooses slice-on-agent vs dedicated table).
- **Grant-scoped principal is concrete.** The non-human materialize principal is a
  specific URI scoped to the grant + approved source (e.g.
  `system://credential-grant/<grant_id>`), holding ONLY `sandbox.read` on
  `approved_scope` — not blanket `system://` caps. PR-0 defines its encoding + catalog
  entry.
- **Leased / TOCTOU-safe materialization.** revalidate → copy secret → exec is a
  guarded sequence: the grant `version` read at the start is **re-checked immediately
  before subprocess exec** (and before writing the curl slice). If it changed (revoked
  mid-start), abort the start — do NOT launch with the stale secret. So a
  revoke-after-pre-check cannot produce a freshly-started process holding revoked creds.
- **Revocation cancels in-flight + running.** Revocation both fails future starts AND
  signals already-running agents bound to that grant to restart (force-kill →
  re-resolve, which now fails loud) — revocation is not "effective only at the next
  voluntary restart."

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
  name convention. Absent pointer → fall through to workspace-shared (D4.3 step 3);
  only when NO source at all exists and a credential is required → **fail loud**, never
  silent `:no_api_key`.
- **Relogin = in-place update of a STABLE holder (round-3 G3 — makes "login once /
  re-login propagates" hold).** The user's default source is a **stable** holder with a
  fixed URI for a given `(owner, workspace, flavor)`; re-login writes the fresh
  credential **into that same holder (same URI)**, NOT into a new one. Existing agents
  bound to that `credential_source_uri` therefore pick up the new credential at their
  next start with **no rebinding** — propagation is automatic. Pointing a user's default
  at a *different* holder is an explicit, audited **rebind** (which must update existing
  agents' grants) and is V2; V1 keeps the holder stable.
- **Migration:** existing per-agent `:api_keys` / per-agent OAuth dirs are adopted by
  registering the appropriate existing agent as the owner's default source for that
  (workspace, flavor); documented one-time step, no silent guess.

**Required invariants (round-2 H4' — the pointer IS a credential authority):**
- **Cap-checked, audited writes.** Only the owner (or an admin) may set/update their
  `user_default_credential_source`; writes are cap-checked and audited. A DB **uniqueness
  constraint** on `(owner, workspace, flavor)` (not just app-level).
- **Pointed-source validation.** On write, the target source MUST be proven to belong to
  the same `(owner, workspace, flavor)` and be the expected source-Kind — reject a
  pointer to another user's / another workspace's / wrong-flavor agent (else a bad write
  redirects a user's default to someone else's credential).
- **Revoke / staleness.** Deleting the pointed source invalidates the pointer (next
  resolve fails loud, prompts re-login); explicit delete/revoke supported.
- **Migration refuses ambiguity.** The one-time adoption command **refuses** when
  existing per-agent credentials are ambiguous for a `(owner, workspace, flavor)` rather
  than guessing — operator resolves explicitly.

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
- **Atomic replace with rollback (round-2 H3' — do NOT rely on the current PR-B impl).**
  The current cc/codex materializer does `File.rm_rf(target)` THEN `File.rename(staging,
  target)`; a crash/rename-failure between the two leaves the agent with **no**
  config_dir (not "untouched"). The cascade materializer MUST use a real replace
  protocol with rollback — stage → move current target to `<target>.bak` → rename
  staging into place → on success drop `.bak`, on failure restore `.bak`. A failed
  materialization leaves the PRIOR good config_dir intact (never an empty/half dir).
  Mechanism deferred to PR-2; **failure-injection tests required** (crash after the
  delete/move step, rename failure) before PR-2 ships.

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
- **Grant TOCTOU (H1'):** revoke the grant AFTER the pre-copy revalidation but BEFORE
  exec → the start aborts; no process launches with the revoked secret. Revoking a grant
  bound to a running agent forces its restart.
- **Atomic-replace rollback (H3'):** inject a crash/failure after the target is moved
  aside / before rename completes → the agent retains its PRIOR good config_dir (never an
  empty or half-merged dir).
- **Tombstone trust (H2'):** a user/session layer cannot tombstone a workspace/base
  protected path without the management cap; a non-protected inherited plugin can be
  tombstoned freely.
- **User-source authz (H4'):** a write pointing at another user's / another workspace's /
  wrong-flavor agent is rejected; DB uniqueness on `(owner, workspace, flavor)` holds;
  pointer writes are cap-checked + audited.
- **Mandatory-control overwrite (G1):** a higher layer that *replaces* a policy file to
  omit a mandatory hook/MCP/plugin still yields an agent WITH that control (post-merge
  validation), not just the tombstone case.
- **Selection state machine (G2):** absent user pointer falls through to an authorized
  workspace-shared source; a revoked selected source fails loud and does NOT fall
  through; precedence explicit > user > workspace holds.
- **Relogin in-place (G3):** re-login updates the stable holder's contents; an existing
  agent bound to that source URI uses the new credential at next start with no rebind.

The full end-to-end **acceptance gate** is §11 (the completion criterion).

## 9. Decomposition (small PRs, each → codex code-review)

- **PR-0 — `CredentialGrant` + user-source SoT (foundations, H1/H1'+H2/H4').** The
  **versioned** durable grant store (§5.1: epoch, grant-scoped principal URI +
  catalog entry, read path) + the cap-checked **`user_default_credential_source`**
  registry with DB uniqueness `(owner,ws,flavor)` + pointed-source validation + audited
  writes (§5.2) + the `secret_relpaths`/config split in the adapter contract (§D6).
  No cascade behavior change yet; migration command that refuses ambiguous existing
  creds. Invariant tests: grant revoke/delete/scope + TOCTOU version re-check, disjoint
  secret∩config, user-source-from-pointer-not-name + cross-owner-write-rejected.
- **PR-1 — Resolution core (domain.agent).** `resolve_layers/…` + ordered layer
  enumeration + `pick_credential_source` precedence + grant-scoped authorize/re-validate;
  pure resolution returning `{config_layers, secret_source}`, no materialization change
  yet. Invariant tests for order + precedence + fail-loud.
- **PR-2 — Layered materialize for file flavors, at every (re)start (H3/H3').** Replace
  the PR-B `rm_rf`-then-rename with a **real atomic-replace-with-rollback** (§7), then
  merge layers 1→4 (whole-file-replace + directory-union + **trust-aware tombstones**
  §D4.2) + `secret_relpaths`-only copy from the resolved source under the **TOCTOU-safe
  leased** materialization (§5.1); route spawn AND cold-restart/self-heal through
  resolve→materialize (respawn stores inputs, not snapshot). cc + codex. Tests:
  cold-restart re-resolution, atomic-replace failure-injection, tombstone-trust, grant
  TOCTOU.
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

Resolved across rev 2 + rev 3 (codex rounds 1+2): user-source storage → §5.2; spawn
authorization → §5.1 versioned `CredentialGrant`; cold-restart staleness → D3/§4; codex
`config.toml` conflation → §D6; directory-union delete + trust → §D4.2 trust-aware
tombstones; grant TOCTOU → §5.1 leased re-check; atomic-materialize falsehood → §7
replace-with-rollback; user-pointer authz → §5.2 invariants.

Still open — design-level requirements stated; **concrete mechanism deferred to PR-0/PR-2
planning** (each gated by codex code-review), NOT unresolved design questions:
- **`CredentialGrant` store shape** (slice-on-agent vs dedicated table) + revocation
  push (sweep) vs pull (check-at-start) — PR-0 decides; both must satisfy §5.1 invariants.
- **Workspace-shared service-account credential**: shared-source storage + the
  workspace-admin authorize step that mints a member `CredentialGrant` + shared-secret
  rotation semantics — PR-3/PR-4.
- **Grant-scoped principal catalog entry** encoding — PR-0.
- **Migration command** exact mapping (refuses ambiguity) — PR-0.

Genuinely open (needs a decision, not just deferral):
- **Interaction with #533 creation-unification**: resolution + grant minting MUST run
  INSIDE the single authorized create chokepoint, not a parallel path — confirm the
  chokepoint exposes the needed hook before PR-1.
- Does any in-process flavor besides curl need a non-slice resolver shape? (likely no.)

## 11. Acceptance gate (end-to-end observable effect)

The design is "done" when an automated end-to-end gate proves these user-observable
conditions (each a test; the gate is the union, per
`feedback_completion_requires_invariant_test`):

1. **Login once → N agents work.** A user logs in once for a flavor, then creates N
   agents (≥1 each of cc, codex, curl) in their workspace; **all N authenticate and
   complete a real round-trip** with no per-agent login.
2. **Re-login propagates.** After the user re-logs in (in-place holder update), each
   existing agent, on its **next start (incl. cold restart / self-heal)**, uses the new
   credential — verified by a workspace-template change + re-login THEN a BEAM restart,
   not just a fresh spawn.
3. **Workspace shared provisioning.** With NO personal user credential but an authorized
   workspace shared service-account source, cc + codex + curl agents **start and work**
   from the workspace-shared credential (D4.3 step 3).
4. **Revocation actually stops access.** Revoking a credential grant: a subsequent start
   **fails loud** (no launch with revoked creds, incl. the revoke-after-precheck TOCTOU
   case), and a running bound agent is restarted into the fail-loud path.
5. **Mandatory config cannot be bypassed.** A user/session layer that omits or replaces
   a workspace mandatory control (hook/MCP/plugin) does **not** yield an agent missing
   that control — the post-merge mandatory-set validation enforces it (overwrite AND
   tombstone paths).
6. **No cross-boundary credential.** A credential never reaches an agent of another
   owner or another workspace; an unauthorized source pointer/grant is rejected; a
   materialized agent dir contains only its own resolved secrets.
7. **Live-update of shared config.** A workspace plugin/config update flows to its agents
   on their next start (cascade re-resolution), without per-agent edits.

This gate (not "PRs merged + unit tests pass") is the completion criterion; PR-2/PR-3/PR-4
each move one or more of these from red to green.
