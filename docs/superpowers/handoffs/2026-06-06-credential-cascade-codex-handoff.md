# Codex handoff — complete the agent-provisioning credential/config cascade (#17)

You are taking over an in-progress, well-specified feature in the **ezagent** Elixir
umbrella and driving it to completion against an explicit acceptance gate. The design is
DONE and codex-reviewed; PR-0 and PR-1 are merged; PR-2 is a reviewed draft with 2 known
HIGH findings; PR-3/PR-4/PR-5 remain. Finish all of it to the acceptance gate in §ACCEPTANCE.

## 0. Authoritative documents — READ THESE FIRST
- **Design spec (your authority):** `docs/superpowers/specs/2026-06-06-agent-provisioning-cascade-design.md` (rev 5). Sections you will rely on: §4 resolution algorithm, §5.1 CredentialGrant, §5.2 user source, §D2 the four layers, §D4 merge rules + tombstone trust, §D6 secret/config split, §7 atomic replace, §11 ACCEPTANCE GATE, §12 management UI.
- **PR-0 plan (the established patterns):** `docs/superpowers/plans/2026-06-06-agent-provisioning-cascade-pr0.md` (rev 3).
- **PR-2 draft & its remaining findings:** GitHub PR **#585** (branch `feat/cascade-pr2`) — its description lists the 2 remaining HIGH precisely.

## 1. The model (one paragraph)
An agent's credentials + config are resolved by merging organizational LAYERS
(flavor-base → workspace → user → session, low→high, later overrides earlier). The
**domain owns RESOLUTION** (universal, flavor-agnostic); the **flavor owns
MATERIALIZATION** (cc/codex write files into the per-agent `config_dir`; curl resolves an
API key into its `:api_keys` slice). Agent URIs are unchanged/opaque (provenance is
stored, never encoded). References are **live** via re-materialization at every (re)start
(not symlink). The credential SOURCE is a single value chosen by precedence
(**explicit > user > workspace-shared > fail-loud**, with **absent ≠ revoked**). All
mutating writes go through cap-checked + audited Behavior dispatch (no raw setters).

## 2. Current state
- **PR-0 MERGED (#583):** `apps/ezagent_core/lib/ezagent/credential/` — `GrantRow`
  (`insert/fetch_for_materialize/revalidate_version!/reapprove`), `UserDefaultSource`
  (read-only store; write only via the `UserDefaultCredentialSource` Behavior in
  `ezagent_domain_identity`), `GrantCap`, `adopt`. Adapter `secret_relpaths/0` split on
  cc/codex. The materializer principal `system://credential-materializer` is in the
  Catalog.
- **PR-1 MERGED (#584):** `Ezagent.Credential.Resolver` — `resolve_layers/1`,
  `pick_credential_source/1` (D4.3 state machine, with an injectable
  `workspace_shared_lookup` + a `:workspace_shared_credential_source` UriQuery hook that is
  NOT yet registered), `authorize_and_mint_grant!/1` (cap-checks the source read against
  the caller's caps; approver = the cap-checked caller; same-workspace agent/source;
  forbids `system://agent-internal`).
- **PR-2 DRAFT (#585, branch `feat/cascade-pr2`, NOT merged):** `Ezagent.Agent.Materializer`
  (atomic-replace-with-rollback + `recover_orphaned`, layer merge + trust tombstones +
  mandatory post-merge validation, secret-only copy, grant TOCTOU re-validated immediately
  before subprocess launch with rollback on revoke). cc/codex delegate to it; backward-compat
  by construction (no `tmpl["cascade"]` inputs → byte-for-byte the prior single-reference
  materialize). Suites green: materializer 24, cc 179, codex 44.

## 3. Remaining work (do in order; each is a PR)

### PR-2 finish (close the 2 HIGH from #585, then merge)
1. **[HIGH] marker-confirmed recovery** — `Ezagent.Agent.Materializer.recover_orphaned/1`
   currently treats any NON-EMPTY `target` as committed and drops the `.bak`. A partial
   non-empty target + a good `.bak` then loses the backup. Require the **completion
   marker** (the same marker `stage_and_swap` writes) — not non-emptiness — before dropping
   `.bak`; if `target` and `.bak` coexist but `target` is not marker-confirmed, preserve
   `.bak` and restore-or-error. Tests: partial-non-empty-target + `.bak` → `.bak` preserved
   and materialize entry aborts unless target is marker-confirmed.
2. **[HIGH] ancestor tombstone bypass** — the tombstone gate in `merge_layers/2` checks
   only EXACT membership of `target_rel` in the protected set, so `hooks.tombstone` can
   remove a protected `hooks/policy.sh`; and `strip_tombstone_markers/1` re-applies deletion
   without a protected check. Reject a tombstone whose target is **equal to OR an ancestor
   of** any protected lower-layer path unless the tombstoning layer holds the management
   cap; apply tombstones per-layer and delete markers immediately so unchecked markers
   can't re-delete later higher-layer content. Tests: parent-directory tombstone vs a
   protected child path; markers don't delete later higher-layer files.
3. **docker-e2e spawn validation** (see §ACCEPTANCE, human-assisted) before merge.

### PR-3 — activate the cascade + cold-restart re-resolution
- Populate `tmpl["cascade"]` (the `%{layer_dirs, source_dir_for}` inputs the PR-2
  materializer consumes) from the real layers: the **workspace template layer** (layer 2,
  `template://<workspace>/agent/<name>`) and the **user layer** (layer 3) directories.
- Register the **`:workspace_shared_credential_source`** UriQuery resolver (PR-1 left the
  hook); implement workspace-shared service-account source storage + the **workspace-admin
  authorize step** that mints a member `CredentialGrant` (reuse the cap-checked dispatch
  chokepoint pattern; never a raw write).
- Default resolution via the §5.2 stored user pointer.
- **D3 cold-restart re-resolution (deferred from PR-2):** `respawn_template_data` stores
  the resolution INPUTS (workspace/owner/session/explicit-source URIs + the approved
  `credential_source_uri`), NOT a resolved snapshot; every (re)start (incl. cold restart /
  self-heal) re-runs `resolve_layers` + re-materializes. This is entangled with the #533
  create chokepoint and the #539 cold-restart snapshot path — coordinate carefully; keep
  the empty-over-good snapshot guard intact.

### PR-3.5 (or fold into PR-3) — wire into the #533 create chokepoint
- Resolution (`resolve_layers`) + grant minting (`authorize_and_mint_grant!`) MUST run
  **inside the single authorized create chokepoint** (spec §10), not as a parallel path —
  so that creating/forking an agent actually triggers the cascade with the human caller's
  `{caller, caps}` and the authentic `agent_uri` under creation.

### PR-4 — curl into the model
- `apps/ezagent_plugin_curl_agent` is in-process (no PTY); its credential is an API key in
  the `:api_keys` slice. Resolve curl's key through the SAME layered precedence
  (workspace-shared key ⇒ user key ⇒ explicit); materialize into the `:api_keys` slice (a
  slice materialization adapter, not a file). Add a flavor-parity gate so every credentialled
  flavor either implements the file adapter or declares a slice resolver.

### PR-5 — management UI (spec §12)
- A LiveView extending `admin_templates_live` / `plugins_live` / `auto_derive_live`:
  templates-by-level; an agent's resolved layer-stack + its chosen credential source;
  set/change the user default source (through the §5.2 cap-checked Behavior — no LV bypass);
  view/revoke credential grants (cap-checked); workspace template curation + mandatory set.

## 4. Conventions & constraints (NON-NEGOTIABLE)
- **Load the project skills** before writing code: read + apply
  `.claude/skills/ezagent-developer/SKILL.md` and `.claude/skills/elixir-phoenix-helper/SKILL.md`
  (let-it-crash; **no silent defaults / shims / fallbacks** that hide bugs; no
  back-compat shims that mask failures; dispatch chokepoint = the only authorized write
  path; URI canonical form).
- **TDD:** write the failing test, watch it fail, implement minimal, green, commit. Small
  frequent commits.
- **Test loop:** host `mix test <path>` from the repo root (the worktree has compiled
  `_build`/`deps`). Migrations apply to the TEST DB only. **NEVER** run `mix ecto.migrate`
  against a dev/prod DB and **NEVER** touch the running dev/prod docker containers or their
  data.
- **Real APIs (already learned — use them, don't reinvent):** `Capability.cap/3`
  (kind,behavior,action) vs `cap/5` (…,instance,workspace_uri); `Capability.workspace_of/1`
  returns a `workspace://` URI; `Capability.matches?/2`; `SystemPrincipal.Catalog` is a
  CLOSED allowlist (`caps_for!/1` raises); modules are `Ezagent.PluginCc.Template.CcAgent`,
  `Ezagent.PluginCodex.Template.CodexAgent`, `EzagentCore.DataCase`, `Ezagent.URI.new!/1`
  (raising) / `parse/1` (non-raising). Ecto pattern: copy
  `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex`.
- **Per-PR review gate:** every PR gets a codex adversarial code-review and must reach
  **SHIP** (no CRITICAL/HIGH) before merge. Address findings; re-review. Then squash-merge
  to `main` (admin merge is authorized in this repo when REVIEW_REQUIRED blocks).
- **Scope discipline:** one PR at a time, in the order above; don't bundle.

## 5. ACCEPTANCE — the completion gate (this, not "PRs merged + units pass")
Per spec §11. The feature is DONE when ALL of the following hold. The gate is a SUPERSET
of human review and is ergonomic (paste-able commands; no manual UUID typing).

### A. Automated (must be green, runnable by anyone)
Run the full umbrella suite from the repo root: `MIX_ENV=test mix test` → **0 failures**
(no regressions), AND these specific invariants pass (add any that don't yet exist):
- **G1 layer order + precedence** — `resolve_layers` enumerates flavor-base→workspace→user→session;
  `pick_credential_source` precedence explicit>user>workspace-shared>fail-loud (PR-1 tests; extend).
- **G2 absent ≠ revoked** — an absent user pointer falls through to workspace-shared; a
  revoked/unauthorized/unavailable SELECTED source fails loud (never silently downgrades).
- **G3 mandatory config unbypassable** — a lower-trust higher layer that OMITS (overwrite)
  OR tombstones (incl. an ANCESTOR dir) a workspace/base mandatory control yields an agent
  that STILL has it (post-merge validation), unless the layer holds the management cap.
- **G4 no cross-boundary credential** — a grant/source pointer cannot bind a credential to
  an agent of another owner or workspace; cross-owner/cross-workspace/wrong-flavor source
  writes are rejected; a materialized agent dir contains only its own resolved secrets.
- **G5 crash-safe materialize** — failure-injection: a crash between move-aside and rename,
  or a failed rename/rollback, leaves the PRIOR good `config_dir` intact (never empty/partial);
  `recover_orphaned` never drops the only good `.bak` (marker-confirmed); rollback failures
  surface as blocking errors.
- **G6 revocation stops access** — a grant revoked before/at launch (incl. the
  revoke-after-precheck TOCTOU) aborts the spawn; the materialized secret dir is removed or
  the cleanup failure is surfaced as blocking (never a silently-left secret).
- **G7 cold-restart re-resolution** — a workspace-template change OR a user re-login,
  FOLLOWED BY a BEAM restart / self-heal, yields the NEW config/credential (not a stale
  `respawn_template_data` snapshot). Distinct from a fresh-spawn test.
- **G8 workspace-shared provisioning** — with NO personal user credential but an authorized
  workspace shared source, resolution selects the shared source (and an agent provisions
  from it).
- **G9 curl in the model** — an orch-spawned curl worker resolves its key through the same
  layered precedence (workspace-shared when the user layer has none); flavor-parity gate
  passes.
- **G10 single-writer / chokepoint invariants** — no raw cap-less writer for the user
  source or grants; the only write path is the cap-checked + audited dispatch (the existing
  single-writer invariant test must still pass and cover any new write site).

### B. Human-assisted (flag clearly; these need a person or the test provisioner)
- **docker-e2e spawn** (dev docker): log in ONCE for a flavor, create N≥2 agents across
  cc+codex+curl, confirm all authenticate + complete a real round-trip with no per-agent
  login; re-login → next (re)start picks up the new credential; revoke → the agent stops;
  a workspace-shared source provisions an agent with no personal login. (Credentials/login
  are a human step or via the #17 PR-E test provisioner; do not invent credentials.)
- **management UI** (PR-5): an `agent-browser` screenshot at the dev base URL
  (`http://100.64.0.27:10042`, the Tailscale IP — NOT localhost) showing, for a real agent,
  its resolved layer-stack + credential source, the set-user-default-source action, and a
  grant revoke.

### C. Process
- Each of PR-2(finish)/PR-3/PR-3.5/PR-4/PR-5 individually codex-adversarial-reviewed to
  SHIP before merge. No CRITICAL/HIGH open at merge. Final: §5.A green in one full-umbrella
  run + the §5.B demonstrations captured.

## 6. Notes
- Known PR-0 layer nit (fix opportunistically): a couple of core tests
  (`credential_adapter_split_test`, `resolver_db_test`) reference plugin modules → they pass
  from the umbrella root but fail if run per-app in isolation. Consider moving those
  flavor-specific assertions to a plugin test app or guarding them.
- If any step is too entangled to do safely (e.g. the D3 cold-restart vs #533/#539), implement
  the safe slice, FLAG the rest explicitly with the concrete blocker — honesty over forced
  completion.

## 7. Execution process (REQUIRED — Allen 2026-06-06, loose-audit mode)
You self-merge, but you operate inside a human-run **post-merge audit loop** that pulls
`main`, runs the §5 gate, and files GitHub issues labeled **`cascade-audit`** when
something is red. Follow this process so that loop can steer you:

1. **Worktree per PR.** For each sub-PR, create a FRESH git worktree off the latest
   `origin/main` (`git fetch origin && git worktree add ../cascade-<pr> origin/main`),
   implement + test there, and open the PR from that branch. Do NOT develop directly in a
   shared/long-lived checkout (it tangles `_build`/stash across PRs). Remove the worktree
   after the PR merges (`git worktree remove ../cascade-<pr>`).
2. **One PR per sub-PR, self-reviewed to SHIP.** Open a PR, run your adversarial
   code-review, fix until there is no CRITICAL/HIGH, then squash-merge to `main` and delete
   the branch. Never bundle sub-PRs.
3. **Check issues EVERY cycle (and before every merge).** Run
   `gh issue list --state open --label cascade-audit`. These are the audit loop's findings
   (gate failures / regressions it caught on `main`). For each: read it, FIX what applies to
   the current or next PR **before merging that area**, and close the issue with a comment
   referencing the fixing commit/PR. **Treat an open `cascade-audit` issue as a merge
   blocker for the part of the cascade it names** — do not merge new work over an unaddressed
   audit finding in the same area.
4. **Never regress a green gate item.** Do not merge a PR that turns a previously-green §5
   G-invariant red; keep the umbrella `mix test` green as you go.
5. **Boundaries (repeat):** test on the TEST DB only; never run `mix ecto.migrate` against a
   dev/prod DB; never touch the running dev/prod docker containers or their data.
