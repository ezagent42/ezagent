# File-flavor unified-create must route through the #17 credential cascade

**Date:** 2026-06-07
**Branch:** `fix/file-flavor-create-cascade`
**Status:** design note — pending codex adversarial approach-review before implementation.

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

### 4a. Minimal-but-complete change

For **file-flavors only** (decided by `Ezagent.Agent.CredentialAdapter.credentialled?(class_module)`
— the same predicate the cascade uses — NOT a hardcoded `"cc"`/`"codex"` list), the unified
create's `do_create_agent` for cc/codex:

1. **Always inline a `"config_dir"` reference into the per-agent template content**
   (today it is added only by `maybe_put_clone_source` on `--from`). The reference value
   for a non-`--from` create is the per-agent TARGET derived from the agent URI +
   the class namespace (`Ezagent.Sandbox.ConfigDir.path/2`), exactly what
   `CcAgent.resolve_config_home/2` clause 3 already derives. This makes config_dir
   allocation **unconditional** for file-flavors and satisfies
   `default_cascade_configured?(:file, content, _)` via the content branch.

2. **Route the file-flavor instantiate through `Agent.spawn_from_template_content/5`**
   instead of `Loader.invoke_template/2 → provision_and_instantiate` directly, threading
   `caller` + `caps` (from `ctx`) so the cascade can mint the grant, and
   `source_template_uri: <the per-agent template URI>` so the cascade's
   `source_template_uri`-branch is *also* available (defence in depth — the content
   branch is the primary trigger). Non-file flavors (echo / np / curl-as-slice) keep
   the existing behavior unchanged.

   The cleanest seam: introduce a file-flavor branch in `invoke_or_rollback` /
   `invoke_template_now` (or a sibling) that, for a credentialled class, calls
   `Agent.spawn_from_template_content/5` with the template content; non-credentialled
   classes keep `Loader.invoke_template`. The Store write + rollback wrapper
   (`register_and_invoke_template`) is preserved verbatim around it — we are swapping
   only the *instantiate* call, keeping persistence + rollback + cap-grant intact.

3. **Fail loud, no shared fallback.** A file-flavor that cannot resolve a config home
   must return `{:error, …}` rather than spawn with `CLAUDE_CONFIG_DIR` unset. Because
   step 1 makes the config_dir reference unconditional for file-flavors, the only way
   `resolve_config_home` returns nil for a file-flavor is a genuine bug (missing
   `agent_uri`, allocation failure), which already surfaces as an error from
   `Sandbox.ConfigDir.allocate/2` (`template.ex:309-311`). We add a guard so that a
   file-flavor reaching the consume path with a nil config home raises/`{:error}`
   instead of silently proceeding — converting the silent-degrade into a loud failure.

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
