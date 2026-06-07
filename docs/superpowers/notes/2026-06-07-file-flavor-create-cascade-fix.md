# File-flavor unified-create must route through the #17 credential cascade

**Date:** 2026-06-07
**Branch:** `fix/file-flavor-create-cascade`
**Status:** IMPLEMENTED (TDD). Codex adversarial approach-review run (verdict
`needs-attention`, approach SOUND, three under-specifications folded in — see §7). Failing
test → green; affected suites + create-path/parity invariants pass. PR open, not merged.

## 1. The bug (confirmed by code trace)

The unified, cap-checked operator create —

```
Ezagent.Workspace.create_agent/3
  → Behavior.Workspace.handle_create_agent/2   (apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:690)
  → do_create_agent("cc"|"codex", …)            (:1063 / :1120)
  → register_and_invoke_template/7              (:1211)
  → Ezagent.Workspace.Loader.invoke_template/2  (loader.ex:72 → do_invoke/4 :115)
  → Ezagent.Kind.Template.provision_and_instantiate/4  (apps/ezagent_core/lib/ezagent/kind/template.ex:294)
  → CcAgent.instantiate/3 (or CodexAgent.instantiate/3)
```

**never** passes through `Ezagent.Entity.Agent.spawn_from_template_content/5`
(`apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex:511`) — the **sole**
site that runs the #17 credential cascade (`resolve_cascade_content/7` :645 →
`maybe_resolve_default_cascade_content/7` :699 → `build_cascade/5` :799).

Two distinct consequences for a file-flavor (cc / codex — any flavor whose Template
Class implements `Ezagent.Agent.CredentialAdapter`):

1. **No isolated config_dir unless `--from` was passed.** `provision_and_instantiate`
   allocates a per-agent config_dir TARGET **only when the template carries a
   `"config_dir"` reference key** (`template.ex:305-306` → `maybe_allocate_config_dir`).
   The bare-create cc template built at `do_create_agent("cc", …)` (workspace.ex:1073)
   omits `"config_dir"` entirely — it is added **only** by `maybe_put_clone_source/2`
   (:1195), i.e. only when `--from <source>` is supplied. So a "+ New agent" / unified
   CLI create with no `--from` produces a template with **no `"config_dir"` key** →
   no allocation → `CcAgent.resolve_config_home/2` falls to clause 4 and returns **nil**
   (`cc_agent.ex:1255-1268`) → `CLAUDE_CONFIG_DIR` is unset → claude **silently uses
   the operator's `~/.claude`**. No per-agent isolation, no credential provenance.

2. **No #17 cascade.** Even with a config_dir, the unified path never reaches
   `resolve_cascade_content`, so a user who has a **default credential source** set
   (the #17 user-default) never gets it injected via `copy_secret_relpaths`. The
   agent comes up un-credentialled even though the platform knows where its creds
   should come from.

This is a **silent-degrade** — it type-checks, tests pass, and the agent "works"
by quietly sharing the operator's home. That directly violates the codebase's own
`feedback_let_it_crash_no_workarounds` ethos, quoted throughout `cc_agent.ex`
(e.g. the `resolve_config_home` precedence comment :1241-1253 explicitly forbids the
shared-fallback; `reject_stale_config_dir_data_key!` :1290 fails loud on a stale key).
The shared-home fallback is the one degrade path that slipped through.

## 2. The reference path that already does it right

The orchestrator / session / fork path goes through the **AgentTemplate Kind's
`:instantiate` action** (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/template.ex:374`),
which calls:

```elixir
Ezagent.Entity.Agent.spawn_from_template_content(
  content, instance_uri, spawned_by, workspace_uri,
  caller: ctx.caller, caps: ctx.caps,
  source_template_uri: self_uri,          # ← the AgentTemplate Kind's own URI
  explicit_source: args.explicit_source
)
```

Inside `spawn_from_template_content/5`, `maybe_resolve_default_cascade_content/7`
(:699) fires when **all three** hold:

- `credential_adapter_kind(template_class) != :none` — true for cc/codex (`:file`).
- `source_template_uri` is a `%URI{}`.
- `default_cascade_configured?(:file, content, source_template_uri)` is true (:786),
  which is satisfied if **either** `content["config_dir"]` is a non-empty binary
  **or** `UriQuery.resolve(:config_dir, source_template_uri)` yields one.

When it fires, `build_cascade/5` resolves the #17 layers via
`Ezagent.Credential.Resolver.resolve_layers/1`, mints the grant
(`maybe_mint_cascade_grant/4`, with workspace-shared fallback :902), and stamps
`content[:cascade]` + `content[:cascade_resolution]`. Then `instantiate_workers/3`
(:1121) routes through the **same** `provision_and_instantiate/4` core wrapper the
unified path uses — so config_dir allocation is identical; the cascade is the *only*
thing the unified path is missing.

## 3. Key constraint discovered: there is NO workspace cc/codex BASE template

The task's lead candidate — "thread a flavor-base / workspace cc|codex
`source_template_uri`" — has a **missing prerequisite**: no such base template exists.
The unified create constructs an **ad-hoc per-agent** template inline
(`tmpl_name = "cc.agent." <> agent_name`, workspace.ex:1071) and registers it in the
Workspace `:session_templates` slice. `grep` for a registered workspace-scoped `cc`/`codex`
*base* template (`cc_orchestrator_seed.ex`, store.ex, demo seeds) finds only per-instance
templates and demo tasks — there is no stable `template://…/cc` base URI to point
`source_template_uri` at.

`default_cascade_configured?(:file, …)` (:786) gives us the escape: it is satisfied by
**content** carrying a `config_dir` — we do **not** need a `source_template_uri` to make
the cascade fire on the `content` branch. The orchestrator path uses `source_template_uri`
because *its* content (the AgentTemplate slice) does not always inline `config_dir`; our
inline template can carry it directly.

## 4. Decision — converge, don't fork

We must NOT add a second spawn path that bypasses the cap-checked chokepoint
(#533 creation-unification; anti-pattern "DynamicSupervisor.start_child a Kind directly").
The unified create already IS the cap-checked chokepoint (`Behavior.Workspace.:create_agent`,
guarded by the `agent_create_single_path_test.exs` invariant). The fix **converges the
file-flavor branch of that one chokepoint onto the cascade chokepoint** rather than forking.

### 4a. The change (REVISED — folds in codex §7 findings 1+2)

For **file-flavors only** (decided by `Ezagent.Agent.CredentialAdapter.credentialled?(class_module)`
— the same predicate the cascade uses — NOT a hardcoded `"cc"`/`"codex"` list), the unified
create's `do_create_agent("cc"|"codex", …)`:

1. **Build the AgentTemplate CONTENT schema, not the Template-Class DATA schema.**
   (codex Finding 1.) `spawn_from_template_content/5` consumes the *content* schema and
   runs it through `Ezagent.Entity.AgentTemplate.to_template_data/2`, which requires
   `flavor` + `project_cwd` (NOT `class` + `cwd`) and reads `config_dir` + `cascade` +
   `cascade_resolution`. The current unified template is data-shape
   (`%{"class","agent_uri","cwd"}`) → handing it straight to `spawn_from_template_content`
   fails `:missing_flavor` / `:missing_project_cwd`. So the file-flavor branch builds:
   ```
   %{
     "flavor"      => flavor,            # "cc" | "codex"
     "project_cwd" => Path.expand(cwd),  # was "cwd"
     "config_dir"  => per_agent_target,  # ALWAYS present (step 2)
   }
   ```
   `to_template_data` then emits the `"class"`/`"agent_uri"`/`"cwd"` data shape + flavor
   extras the plugin `instantiate/3` expects. The flavor's `to_template_data` path is the
   exact one the orchestrator already exercises — no new conversion code, we reuse it.

2. **`"config_dir"` reference is ALWAYS present for file-flavors** (today added only by
   `maybe_put_clone_source` on `--from`). Non-`--from` create derives the per-agent TARGET
   from the agent URI + the class namespace (`Ezagent.Sandbox.ConfigDir.path/2`), exactly
   what `CcAgent.resolve_config_home/2` clause 3 derives. This makes allocation
   unconditional AND satisfies `default_cascade_configured?(:file, content, _)` via the
   content branch (so the cascade fires even with no `source_template_uri`).

3. **Route the file-flavor instantiate through `Agent.spawn_from_template_content/5`**,
   threading `caller` + `caps` (from `ctx`) so the cascade mints the grant, and
   `explicit_source` (see step 5 / codex Finding 3). Non-file flavors (echo / np /
   curl-as-slice) keep the existing `Loader.invoke_template` path untouched.

4. **Persist the CONTENT in `session_templates`; cold-restart cascade re-resolution is
   handled by the EXISTING Sandbox-slice self-heal — NOT a boot-loader change.**
   (Resolves codex Finding 2 — see the runtime trace below that supersedes codex's
   static-only conclusion.)

   The persisted file-flavor template stores the **content schema** (`flavor`,
   `project_cwd`, `config_dir`, + `explicit_source` when `--from`), PLUS a `"class"` key
   (the boot loader's `extract_class_name` + `TemplateRegistry.lookup` require it). All
   JSON-safe (`Store.update_templates` Jason-encodes — no functions/structs).

   **The boot loader MUST route file-flavor templates through the cascade too (codex
   Finding 2 confirmed, with two reinforcing reasons):**

   - *Shape:* the persisted file-flavor template is CONTENT schema (`project_cwd`), but the
     plugin `instantiate/3` the boot loader reaches via `provision_and_instantiate` reads
     the DATA key `cwd` (`Map.fetch!(tmpl, "cwd")`). Only `spawn_from_template_content →
     to_template_data` performs the content→data conversion. So the boot loader's
     file-flavor branch routes through the same spawn facade (which converts + re-resolves
     the cascade from the persisted `config_dir`/`flavor` inputs). Non-credentialled
     classes (echo) keep the direct `provision_and_instantiate` path (DATA shape).
   - *Ordering:* persisting DATA shape and leaving the loader unchanged was considered and
     REJECTED — the loader's fresh-boot `:started` branch materializes single-reference
     (no cascade) and the Agent Kind's `Sandbox.activate/2` self-heal then re-resolves the
     cascade AFTER, a backwards ordering (single-ref then cascade) that races. Routing the
     loader through the cascade gives ONE materialization path with no race.

   Cold-restart owner-provenance is still preserved by the Sandbox slice: `owner_uri` lives
   in the persisted `cascade_resolution` (populated by `record_sandbox_state` at create),
   and `Ezagent.Credential.CascadeRuntime.rehydrate_respawn_data/2` (driven by
   `Sandbox.activate → ensure_subprocess_alive`) reads it from there. The boot loader's
   cascade routing handles the FRESH Kind spawn + content→data conversion; the Sandbox-slice
   self-heal handles the subprocess respawn — both re-resolve from persisted inputs, never
   from stored secrets. ONE cascade-aware seam (`spawn_from_template_content`) is used by
   create, boot loader, and (transitively) the Sandbox self-heal.

5. **`--from` preserves single-reference clone semantics.** (codex Finding 3.) When
   `--from <source>` is given, thread the source as `explicit_source` into
   `spawn_from_template_content/5`. The cascade's `Resolver.resolve_layers` honours
   `explicit_source` over the user-default, so a `--from` clone copies from the requested
   source — NOT silently from a configured user-default. (Today `--from` sets the
   `config_dir` reference to the source's dir; under the cascade, `explicit_source` is the
   correct lever — the cascade resolves the source layer, the materializer copies its
   secrets.) A test covers `--from` + a conflicting user-default both present.

6. **Fail loud, no shared fallback.** A file-flavor that cannot resolve a config home
   returns `{:error, …}` rather than spawning with `CLAUDE_CONFIG_DIR` unset. Step 2 makes
   the reference unconditional, so a nil config home for a file-flavor is a genuine bug
   (missing `agent_uri` / allocation failure) — already an error from
   `Sandbox.ConfigDir.allocate/2` (`template.ex:309-311`). We add a guard converting any
   residual silent-nil into a loud failure for credentialled flavors.

### 4b. Why not the alternative "just force a config_dir, skip the cascade"

That fixes consequence #1 (isolation) but not #2 (the #17 user-default never resolves).
A user who set a default credential source would get an isolated-but-empty `~/.claude`
and have to re-login per agent — defeating the whole point of #17. The fuller fix costs
little more (the cascade machinery already exists and is the *same* code the orchestrator
path runs) and is what the goal explicitly asks for. So the fuller fix is warranted.

## 5. Invariant preservation

| Invariant | How preserved |
|---|---|
| **Single create-chokepoint / single-writer (#533)** | The cap-checked chokepoint is unchanged — `Behavior.Workspace.:create_agent` is still the only operator-facing create. We swap the *instantiate* call *inside* that chokepoint to the existing cascade chokepoint (`spawn_from_template_content`); we do **not** add a new caller of `SpawnRegistry.spawn` / `Kind.spawn`. `agent_create_single_path_test.exs` allowlist is unchanged (the action body file stays the only `entity://agent` literal-spawn site; `spawn_from_template_content` lives in already-allowlisted `entity/agent.ex`). |
| **CapBAC cap-checks** | The cap check at dispatch step 5.5 on `:create_agent` is upstream and untouched. The cascade grant-mint (`maybe_mint_cascade_grant/4`) is itself authorized via `Credential.Resolver.authorize_and_mint_grant!` using the threaded `caller`+`caps` — same authorization the orchestrator path uses. No `admin_caps()`, no new system principal. |
| **No silent fallback** | Step 3: a file-flavor that cannot resolve a config home FAILS LOUD; config_dir allocation is unconditional for file-flavors, so the shared-`~/.claude` path is structurally removed for them. echo/np/curl legitimately have no config home → unchanged. |
| **Snapshot / respawn** | The cascade's outputs (`content[:cascade_resolution]` with the resolved `credential_source_uri`) are the **inputs**, not realized secrets — `respawn_template_data` already stores the template content (`put_respawn_flavor/2` :1092, `record_sandbox_state` :1163). A cold restart re-runs `spawn_from_template_content`'s cascade with the stored inputs and re-resolves, identical to the orchestrator path. We must verify the unified path's persisted template content carries the cascade-resolution inputs (the `config_dir` ref + flavor) so cold-restart re-resolution works — covered by a test. |
| **echo / np / curl unaffected** | Branch is gated on `CredentialAdapter.credentialled?(class_module)`. echo's `instantiate` returns `%{config_dir_path: nil}` and implements no CredentialAdapter → `:none` → not credentialled → original `Loader.invoke_template` path. curl/np go through `direct_spawn_flavor_agent` (do_create_agent catch-all) — never touched. |

## 6. Open question for Allen (pre-merge)

- **`source_template_uri` for the unified path.** I thread the *per-agent* template URI
  (the one just registered in `:session_templates`) as `source_template_uri`. This is a
  real, resolvable Template URI (its content carries `config_dir`), so the cascade's
  `source_template_uri` branch resolves. It is *not* a shared flavor-base (none exists).
  If you intend a future shared per-user `<username>-default` cc base template
  (per memory `project_username_default_agent`) to be the canonical cascade layer source,
  that is a follow-up — this fix is correct for the current topology and forward-compatible
  (the cascade reads layers from the resolved source, which a base template would extend).

## 7. Codex adversarial approach-review (2026-06-07) — verdict + resolution

**Verdict: `needs-attention`** — "the design note proposes the right chokepoint in spirit,
but the written plan still leaves concrete create/boot paths that either fail outright or
bypass the cascade." The *approach* (converge file-flavor create onto the cascade
chokepoint) was NOT challenged as wrong or too risky — three concrete seam
under-specifications were flagged, all foldable. Each verified against the code and folded
into §4a:

1. **[HIGH] data-shape mismatch** — feeding Template-Class *data* (`class`/`agent_uri`/`cwd`)
   to `spawn_from_template_content/5`, which requires *content* (`flavor`/`project_cwd`),
   would fail `:missing_flavor` / `:missing_project_cwd`. VERIFIED against
   `AgentTemplate.to_template_data/2` (`fetch_project_cwd` requires `project_cwd`;
   `resolve_template_class` requires `flavor`). → Folded into §4a step 1 (build content
   schema; reuse the orchestrator's existing `to_template_data` conversion).

2. **[HIGH] boot loader is a second non-cascade spawn path** — `Workspace.Loader` walks
   persisted `session_templates` at boot and calls `provision_and_instantiate/4` directly;
   a persisted cc/codex template would cold-start bypassing the cascade. VERIFIED
   (`loader.ex` `load_one → instantiate_via_dispatch → spawn_child → invoke_template/4 →
   provision_and_instantiate`; persisted templates are data-shape). → Folded into §4a
   step 4: persist content + cascade INPUTS (JSON-safe, keep `"class"` key) AND route the
   loader's credentialled-flavor branch through the same cascade wrapper. This was the
   most important finding — my original "cold restart re-runs spawn_from_template_content"
   claim was wrong for the workspace-template seam.

3. **[MEDIUM] `--from` clone semantics not preserved** — under cascade materialization,
   threading only `config_dir` (not `explicit_source`) lets a configured user-default
   override the requested `--from` source, silently changing clone semantics. VERIFIED
   (`Resolver.resolve_layers` honours `explicit_source`; cc/codex materializers prefer the
   cascade source when `cascade` data is present). → Folded into §4a step 5: thread
   `from_uri` as `explicit_source`; test `--from` + conflicting user-default.

**Disposition:** approach sound; proceed to TDD implementation with the three fixes folded
in (per the task's "IF codex's approach review is sound (fold in its fixes), TDD-implement").
The scope is larger than the original minimal sketch — it now changes the persisted
workspace-template schema for file-flavors AND converges the boot loader — so the
single-path / boot-replay invariant is preserved by ONE cascade-aware seam used by both
create and boot, rather than two divergent seams.
