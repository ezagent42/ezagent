# PR-3 — domain allocates the per-agent config_dir, plugin materializes (rev 3)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development
> or executing-plans. Steps use `- [ ]` checkboxes.
> **Status:** DESIGN+PLAN **rev 3** — rev 1 (codex adversarial-review NO-SHIP, 1
> BLOCKER + 3 HIGH) → rev 2 fixes → rev 3 closes the rev-2 codex-round-2 signals
> (codex round 2 ORPHANED mid-run per the known long-job failure mode; its two
> partial findings were verified by hand and resolved here — see "rev-2→rev-3").
> Cleared to implement (the PR's actual code still gets a codex CODE review before
> merge). Branch `feat/pr3-domain-config-dir` off main (5a/5b/PR-2/PR-6 in).
> Spec: `docs/superpowers/specs/2026-06-02-domain-agent-design.md` §3.1.2/§3.1.3/§3.2,
> D2, §6.

## rev-2 → rev-3 (codex round-2 partial signals, hand-verified)

- **Dispatch layer confirmed, 4 sites complete.** The `Behavior.Template :instantiate`
  action (`behavior/template.ex:282,371`) funnels into `Agent.spawn_from_template_content/4`
  → `class.instantiate/3` at `agent.ex:598` — so the dispatch/`add_managed_member`/
  `ensure_orchestrator` paths are all the SAME site (agent.ex:598). The only direct
  bypasses are `loader.ex:131`, `loader.ex:389`, `workspace_detail_live.ex:325`. Four
  sites is the complete set (grep verified) — the wrapper covers every seam.
- **F (key risk): `to_template_data/2` emits NO `"flavor"` key** (`agent_template.ex:242-247`
  — base = `class`/`agent_uri`/`cwd` + `config_dir` + desired_*), and `template_name/0`
  is `"cc.agent"` not `"cc"`. So sourcing flavor from `tmpl_data["flavor"]` would break on
  boot. **Resolution:** source the path namespace from **`class_module`** (the receiver of
  every `instantiate/3` call — always present, incl. boot), via a new OPTIONAL
  `Kind.Template.config_dir_namespace/0` callback (cc → `"cc"` ⇒ prefix `cc-agents`,
  byte-identical; default derives from `template_name` by stripping the `.agent` suffix).
  `agent_uri` comes from `tmpl_data["agent_uri"]` (present in fresh AND persisted data).
  **Task 0 (add a flavor key) is DROPPED** — no data-shape change, no backfill.
- **Cold-restart key confirmed present.** Fresh create persists `respawn_template_data`
  with `put_agent_config_dir(tmpl,"agent_config_dir")` (`cc_agent.ex:504,518`); rev-3
  keeps that key ⇒ `ensure_subprocess_alive/2` restart is unchanged.

**Goal:** Make the domain (core) the authoritative owner of the per-agent
**config_dir TARGET** (path computation + directory allocation), provided to the
plugin **as data**; the plugin only **materializes content** into the dir it is
handed. Removes the "any writer can pick a shared/mis-seeded path" scatter
(spec §3.1.3). NOT the blocker-#1 fix — structural hygiene.

**Architecture:** D2 "domain allocates, plugin materializes" + North-Star plugin
isolation (the plugin must NOT know the path scheme — it receives `config_dir` as
data). On-disk layout is **unchanged** (`<Home>/<flavor>-agents/<ws>/<name>` — for
cc this is the existing `cc-agents/...`), so **no migration**.

---

## rev-1 adversarial findings → rev-2 resolutions

- **F-BLOCKER (DD-3): `Workspace.Loader` bypasses the single domain seam.** Allocation
  was placed only in `Agent.spawn_from_template_content/4`, but there are **4**
  `instantiate/3` call sites (verified): `agent.ex:598`, `loader.ex:131` (invoke),
  `loader.ex:389` (boot `load_all`), `workspace_detail_live.ex:325` (operator create).
  A persisted cc template with `"config_dir"` hitting the loader would miss the
  injected key. **Resolution:** move allocation+injection to a **single core
  contract-boundary wrapper** `Ezagent.Kind.Template.provision_and_instantiate/4`
  that ALL 4 call sites route through (rev-2 DD-3). One chokepoint, every seam covered.
- **F-HIGH (DD-4): fail-loud unsafe while bypasses exist.** Resolved by F-BLOCKER:
  once every seam goes through the wrapper, the injected key is guaranteed present, so
  fail-loud on absent-key (with a present reference) is a correct defensive contract.
- **F-HIGH (DD-6): claude uses explicit `--mcp-config <cwd>/.mcp.json`** (`cc_agent.ex:1002-1009`);
  moving the file without repointing the flag leaves claude reading the old path; source
  does NOT prove `CLAUDE_CONFIG_DIR` auto-discovers `<config_dir>/.mcp.json`.
  **Resolution (rev-2 DD-6):** pass `config_dir` into `build_claude_cmd/3`, write
  `<config_dir>/.mcp.json`, and repoint `--mcp-config` to that exact path; KEEP the
  project-root + cwd content-identical compat copies.
- **F-MEDIUM (DD-1): `agent.ex:724 cleanup_partial_config_dirs/2` calls
  `template_class.agent_config_dir/1`.** Dropping that plugin fn without replacing this
  caller leaks dirs. **Resolution:** point cleanup at `Ezagent.Sandbox.ConfigDir.path/2`.
- **F-MEDIUM (DD-7): allocation runs before `KindRegistry.put_new`** (init, `server.ex:134`).
  **Resolution:** the allocator is idempotent `mkdir_p + chmod` only, invoked inside the
  wrapper at materialize time (not speculatively) — concurrent same-URI is prevented
  downstream by `put_new`; a losing race just re-mkdirs the same dir (harmless, tested).
  No new lock.
- **F-HIGH (cross-PR): cold restart reuses persisted respawn data.** `Sandbox.activate/2`
  (`sandbox.ex:241`) → `CcAgent.ensure_subprocess_alive/2` (`cc_agent.ex:1539`) relaunches
  from `respawn_template_data`, which already carries the realized path under key
  **`"agent_config_dir"`**. **Resolution:** rev-2 KEEPS writing the realized target under
  the SAME `"agent_config_dir"` key at fresh create, so restart is byte-for-byte
  unaffected — no respawn normalization needed (the dir already exists; restart reads the
  persisted path, doesn't re-allocate). The NEW `"allocated_config_dir"` key is the
  create-time wrapper→plugin channel ONLY.

## 1. Current state (verified, esr-pr3 @ main)

- `CcAgent.agent_config_dir/1` (`cc_agent.ex:1314`) — pure path builder
  `Path.join([Ezagent.Home.path("cc-agents"), <ws>, <name>])`. ONLY place the TARGET
  is computed. Callers: `do_create_agent_config_dir/2` (`:1803`), `destroy_config_dir/2`
  (`:1486`, the `==` assertion), and **`agent.ex:724`** (domain partial-cleanup).
- `CcAgent.create_agent_config_dir/2` (`:1769`) — reads template **`"config_dir"`** =
  REFERENCE (source) dir; computes TARGET via `agent_config_dir/1`; `do_atomic_copy/3`
  (`:1836`) = `mkdir_p(dirname) → cp_r(ref,target) → chmod 700 → chmod creds 600 →
  marker`. Marker `.ezagent-config-complete` (codex PR3 r1 HIGH-2); idempotent on marker;
  wipes stale (marker-absent) dirs.
- `try_role_bootstrap/3` (`:587`) → `apply_orchestrator_role_bootstrap/2` (`:558`) —
  orchestrator skill cp + CLAUDE.md hint INTO the target. Best-effort (codex #408 HIGH-3).
- Create chain `spawn_for_local_pty` `with` (`:497-513`): `create_agent_config_dir →
  put_agent_config_dir(tmpl,"agent_config_dir") → try_role_bootstrap → ensure_pty_server`;
  persists `respawn_template_data: tmpl_with_dir` (`:504`).
- `build_claude_cmd/3` (`:981`) calls `McpConfigWriter.write_with_token!(agent_uri, agent_cwd)`
  and sets `--mcp-config <agent_cwd>/.mcp.json` (`:1002-1009`); `CLAUDE_CONFIG_DIR` env at
  `:1102-1108`.
- `McpConfigWriter.write_with_token!/1` (`mcp_config_writer.ex:99`) — mints token,
  writes SHARED `.mcp.json` (env block = `EZAGENT_BRIDGE_WS_URL` ONLY post-PR-1) to 3
  paths: `~/.ezagent/bridge.mcp.json`, `<git toplevel>/.mcp.json`, `<agent_cwd>/.mcp.json`.
- 4 `instantiate/3` callers: `agent.ex:598`, `loader.ex:131`, `loader.ex:389`,
  `workspace_detail_live.ex:325`.
- `Sandbox` (`sandbox.ex`): slice `config_dir_path`; `:destroy` (`:324`) reads it +
  `invoke_destroy_config_dir/3` (`:531`, `function_exported?` guard) → plugin
  `destroy_config_dir/2`. Cold restart `activate/2` (`:241`) → `ensure_subprocess_alive/2`.
- `Kind.Template` (`template.ex:106-117`) note: "no `create_config_dir` callback —
  plugin's `instantiate/3` owns creation." PR-3 inverts via the wrapper.

## 2. Mechanical design decisions (rev 2)

**DD-1 — TARGET path scheme stays byte-identical; namespace from the class, not data.**
Core computes `Path.join([Ezagent.Home.path("#{namespace}-agents"), <ws>, <name>])`. The
`namespace` is sourced from the **`class_module`** (new optional
`Kind.Template.config_dir_namespace/0`; cc → `"cc"` ⇒ `cc-agents`, byte-identical; default
= `template_name` with a trailing `.agent`/`.` stripped). NOT from `tmpl_data` (which has no
flavor key). For cc this is today's `cc-agents/...` ⇒ no migration. The URI→`<ws>`/`<name>`
segment logic relocates verbatim to core. `agent.ex:724` cleanup switches to `ConfigDir.path/2`.

**DD-2 — Allocator in core, owned by the sandbox concept.** New `Ezagent.Sandbox.ConfigDir`
(`ezagent_core`):
- `path(agent_uri, flavor) :: String.t()` — pure; raises on non-canonical URI (same
  contract as today's `agent_workspace_segment/agent_name_segment`).
- `allocate(agent_uri, flavor) :: {:ok, target} | {:error, term}` — generic allocation
  ONLY: `mkdir_p(target) → chmod 700`. No content copy. Idempotent.
- `safe_to_destroy?(path, agent_uri, flavor) :: boolean` — path-shape guard; replaces the
  plugin's `== agent_config_dir(uri)` assertion.

**DD-3 — single core contract-boundary wrapper; location provided as DATA.** New
`Ezagent.Kind.Template.provision_and_instantiate(class_module, tmpl_name, tmpl_data, ws_uri)`:
1. If `tmpl_data["config_dir"]` (reference) is a non-empty binary →
   `ConfigDir.allocate(URI.new!(tmpl_data["agent_uri"]), namespace_of(class_module))`, put
   result under NEW key `"allocated_config_dir"`. (`namespace_of` = DD-1, from the class.)
2. Delegate to `class_module.instantiate(tmpl_name, tmpl_data, ws_uri)`.
ALL 4 `instantiate/3` callers (`agent.ex:598`, `loader.ex:131`, `loader.ex:389`,
`workspace_detail_live.ex:325`) switch to the wrapper. The plugin receives `config_dir` as
data — it never computes the scheme (North-Star isolation). Reference vs target stay
distinct keys (`"config_dir"` = input ref; `"allocated_config_dir"` = realized target).

**DD-4 — plugin `create_agent_config_dir/2` materializes into the provided target.** Reads
`"allocated_config_dir"` (target) + `"config_dir"` (reference); `cp_r(ref→target)` + chmod
creds + marker (stale-wipe/idempotence kept, keyed on target). FAIL LOUD
`{:error, :config_dir_not_allocated}` if reference present but target absent (the wrapper
guarantees presence on every seam — this catches a future direct caller, not a live path).
Drop the target-computing `agent_config_dir/1` from the plugin. **Still persist the realized
target under `"agent_config_dir"`** in `respawn_template_data` (restart contract unchanged).

**DD-5 — destroy uses the sandbox slice path, guarded by `ConfigDir.safe_to_destroy?`.**
`destroy_config_dir/2` keeps its signature; its safety check calls
`Ezagent.Sandbox.ConfigDir.safe_to_destroy?/3` instead of the removed plugin builder.

**DD-6 — `.mcp.json`: write into `config_dir` AND repoint `--mcp-config` there.** Pass the
allocated `config_dir` into `build_claude_cmd/3`; `McpConfigWriter` writes the authoritative
per-agent `<config_dir>/.mcp.json`; `--mcp-config` (`cc_agent.ex:1002-1009`) points at that
exact file. KEEP the project-root + cwd content-identical compat copies (claude's dev-channel
name-lookup; removing them reprints the `no MCP server configured` warning — `mcp_config_writer.ex:15-21`).
The env block stays `EZAGENT_BRIDGE_WS_URL`-only (PR-1; not per-agent identity). Follow-up
(noted): prove `config_dir`-only discovery + delete the shared copies.

**DD-7 — concurrency.** Allocator is idempotent `mkdir_p+chmod` invoked at materialize time;
same-URI concurrent create prevented downstream by `KindRegistry.put_new` (`server.ex:134`);
a losing race re-mkdirs the same path (harmless). No new lock. Tested for idempotence.

## 3. Files

- Create: `apps/ezagent_core/lib/ezagent/sandbox/config_dir.ex` (DD-2) + test.
- Modify: `apps/ezagent_core/lib/ezagent/kind/template.ex` — add
  `provision_and_instantiate/4` (DD-3); update the `:106-117` note; document
  `"allocated_config_dir"`.
- Modify: `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` — `:598` → wrapper;
  `:724` cleanup → `ConfigDir.path/2`; `to_template_data/2` flavor key if absent.
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/loader.ex` — `:131`, `:389`
  → wrapper.
- Modify: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/workspace_detail_live.ex`
  — `:325` → wrapper.
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — materialize-into-target
  (DD-4); destroy via core guard (DD-5); drop `agent_config_dir/1` authority; pass+use
  `config_dir` for `.mcp.json`/`--mcp-config` (DD-6).
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/mcp_config_writer.ex` — per-agent
  write target = `config_dir` (DD-6).

## 4. Tasks (TDD, bite-sized)

### Task 1 — `Ezagent.Sandbox.ConfigDir` + `config_dir_namespace/0` callback
- [ ] Test: `path/2` = `<Home>/cc-agents/<ws>/<name>` for canonical `entity://agent/<ws>/<name>`
      + namespace `"cc"`; raises on non-canonical; `<ns>-agents` for another namespace. FAIL → impl → PASS.
- [ ] Add optional `@callback config_dir_namespace/0` to `Kind.Template`; cc returns `"cc"`;
      a `namespace_of(class_module)` helper (callback if exported, else `template_name` minus
      `.agent`). Test cc → `"cc"`. FAIL → impl → PASS.
- [ ] Test: `allocate/2` creates dir (0o700), idempotent twice, `{:ok, target}`. FAIL → impl → PASS.
- [ ] Test: `safe_to_destroy?/3` true for canonical, false for `/etc` + outside-`Home`. FAIL → impl → PASS. Commit.

### Task 2 — `provision_and_instantiate/4` wrapper + route all 4 callers
- [ ] Test (core): wrapper with a cc-shaped `tmpl_data` (reference + agent_uri + flavor) allocates
      + injects `"allocated_config_dir" == ConfigDir.path(...)` then delegates; with NO reference
      (curl) injects nothing + allocates nothing. FAIL → impl → PASS.
- [ ] Route `agent.ex:598`, `loader.ex:131`, `loader.ex:389`, `workspace_detail_live.ex:325` to the
      wrapper. Test each still spawns. PASS. Commit.

### Task 3 — plugin materializes into the provided target
- [ ] Test (cc): `create_agent_config_dir/2` with `"allocated_config_dir"` set copies the reference
      INTO it (creds 600, marker) without computing its own path; reference-present + target-absent →
      `{:error, :config_dir_not_allocated}`. FAIL → reimpl (target from key; drop `agent_config_dir/1`)
      → PASS. Confirm `respawn_template_data` still carries `"agent_config_dir"` = target. Commit.

### Task 4 — destroy via core guard
- [ ] Test: `destroy_config_dir/2` removes slice path when `safe_to_destroy?` true; `{:error,
      {:path_mismatch,_}}` else. FAIL → impl → PASS. `manage_behavior_test` destroy green. Commit.

### Task 5 — `.mcp.json` into config_dir + `--mcp-config` repoint
- [ ] Test: `McpConfigWriter.write_with_token!(config_dir: d)` writes `<d>/.mcp.json`; project-root +
      cwd compat copies still written; env == `%{"EZAGENT_BRIDGE_WS_URL" => _}`. FAIL → impl → PASS.
- [ ] `build_claude_cmd/3`: pass `config_dir`, set `--mcp-config <config_dir>/.mcp.json`. Test argv. PASS. Commit.

### Task 6 — full suite + E2E smoke
- [ ] `mix test apps/ezagent_core apps/ezagent_plugin_cc apps/ezagent_domain_chat apps/ezagent_domain_workspace` green.
- [ ] Manual: spawn a cc agent; files under `<Home>/cc-agents/<ws>/<name>/` incl. `.mcp.json`;
      `--mcp-config` points there; bridge connects (传话游戏 path intact). Restart the agent → it
      relaunches from persisted `"agent_config_dir"` (no re-allocation, no break). Commit.

## 5. Out of scope (note, don't silently drop)
- Full `prepare_launch(agent_spec, flavor_content)` contract rename (§3.2 shape) — kept on
  `instantiate/3` + wrapper; rename is later interface-tidy.
- §3.1.4 rich allocated-vs-materialized ledger — slice records `config_dir_path`; richer
  provenance deferred.
- Deleting the project-root/cwd shared `.mcp.json` copies — follow-up after a source/E2E
  discovery proof (DD-6).
- `cc_orchestrator_seed.ex` template-seed writes, np Python runtime dir, bridge `TokenStore`
  file — separate lifecycles, out of per-agent-config scope.
