# SPEC: Multi-level agent provisioning — layered credential/config cascade (domain.agent)

> **Status:** design — Allen-approved in brainstorm 2026-06-06. To be hardened by
> codex adversarial-review before writing-plans. Builds on and **supersedes the
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
- A `watch` on an external credential regen (user re-login elsewhere / admin rotation)
  is **at most a V2 trigger to restart** dependent agents (restart → spawn
  re-materializes); it never writes into a running agent.

### D4 — Merge rules
- **Whole-file-replace** (V1): for same-path files (e.g. `settings.json`), the
  higher layer's file wins entirely. (Deep per-key JSON merge for `.mcp.json` /
  `settings.json` is V2.)
- **Directory union** (e.g. `plugins/`, `skills/`): union of files; on a filename
  collision the higher layer wins.
- **Single credential source per agent.** Credentials are **not** merged across
  layers. Exactly one source is chosen by precedence:
  **explicit (an operator-named source agent) > user (personal login) > workspace
  (shared service account)**. Default = the user layer. Workspace-shared is opt-in.
  No silent mixing; a missing/unauthorized source **fails loud** (no silent fallback
  to an empty or wrong credential), per `feedback_let_it_crash_no_workarounds`.

### D5 — Universality: domain resolution + flavor materialization
- **domain.agent owns RESOLUTION** (universal, flavor-agnostic): given an agent's
  workspace, owner, session, and any explicit source, resolve the ordered layer set
  and the single credential source, cap-checking each read (reuse the existing
  `sandbox.read` cap seam used by the `--from` path in
  `Ezagent.Behavior.Workspace`).
- **The flavor's adapter owns MATERIALIZATION** (the plugin-isolation boundary):
  - cc/codex: write the resolved credential as a **file** in `config_dir`
    (`Ezagent.Agent.CredentialAdapter`, already defined — `credential_relpaths/0`).
  - curl: resolve the credential (API key) into the **`:api_keys` slice**.
  Whether an in-process flavor uses a slice or a `.env` file is a flavor-local
  adapter detail, NOT a cascade-design decision.

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

- **CREATE-time** (per prior spec D3, retained): resolve + cap-check + persist the
  approved credential source into the new agent's template (`parent_template_uri` /
  a stored `credential_source_uri`). No source read under
  `system://agent-internal` caps (prior codex BLOCKER — privilege-escalation leak).
- **SPAWN-time:** materialize `config` via the flavor adapter (cc/codex: atomic-staging
  file copy of `config` + a **filtered** copy of only the credential source's
  `credential_relpaths` — never the whole source dir; curl: write the resolved key into
  `:api_keys`).

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

## 9. Decomposition (small PRs, each → codex code-review)

- **PR-1 — Resolution core (domain.agent).** `resolve_layers/…` + ordered layer
  enumeration + `pick_credential_source` precedence + cap-checked source authorize;
  pure resolution returning `{config_layers, cred_src}`, no materialization change yet.
  Invariant tests for order + precedence + fail-loud.
- **PR-2 — Layered materialize for file flavors.** Extend PR-B atomic staging from one
  reference dir to merge layers 1→4 (whole-file-replace + directory-union) + filtered
  credential copy from the resolved source. cc + codex.
- **PR-3 — Workspace + user layer scoping.** Workspace-scoped AgentTemplate as layer 2
  (exists; wire as a layer); user-owned template (owner attribute) as layer 3; default
  resolution (user’s base template / `<username>-default`).
- **PR-4 — curl into the model.** curl’s `:api_keys` resolved through the same layered
  source precedence (workspace-shared key ⇒ user key ⇒ explicit); slice materialization
  adapter; flavor-parity gate.
- **PR-5 — (optional/V2) eager propagation + deep-merge + pinning** — deferred; tracked.

## 10. Open items (for codex adversarial-review to pressure-test)

- Exact storage of the user-level template / owner attribute (new field vs reuse
  `created_by` + a `role: :user_base` tag) and how "the user's default base" is selected.
- Where the resolved `credential_source_uri` is persisted on the agent template and how
  it interacts with `parent_template_uri` (provenance vs credential source may differ).
- Workspace-shared service-account credential: storage + the authorize step + rotation.
- Merge determinism across directory-union when two layers ship the same skill at
  different versions (last-wins is defined; is that always right?).
- Interaction with #533 creation-unification (single authorized create chokepoint): the
  resolution must run inside that chokepoint, not as a parallel path.
- Does any in-process flavor besides curl need a non-slice resolver shape?
