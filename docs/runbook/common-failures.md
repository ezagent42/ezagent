# Common failures runbook

Symptom-first list of known failure modes in Ezagent. For each, an actionable fix and a pointer to the forensic record / Decision Log entry / CI gate test.

Your Claude Code agent's `esr-developer` skill has a condensed version of this; this doc is the detailed reference.

---

## Symptom: skill-seed logs `SKIPPED release upgrade`

### Cause: operator-edited deployed skill plus changed release seed

The boot skill seed compared `$EZAGENT_HOME/<profile>/skills/<ref>/` with the
last shipped hash and the new release's `priv/skills_seed/<ref>/`. Both the
operator copy and the release seed changed, so Ezagent preserved the operator
edit and did not apply the release bytes.

**Fix:** back up the deployed skill dir, remove
`$EZAGENT_HOME/<profile>/skills/<ref>/`, then rerun the boot seed or
`mix ezagent.home.init`. The next seed copies the release version and updates the
skill index.

**Pre-P3 caveat:** before P3 lands, an already-spawned agent does not pick up a
skill upgrade in place. Regenerate that agent's `config_dir` by deleting the
config dir and marker so the next spawn re-materializes it.

---

## Symptom: message appears to send but recipient never sees it (silent drop)

By far the most common class of bug in Ezagent. Causes, in order of likelihood:

### Cause 1: Channel notification meta has a non-string value

`notifications/claude/channel` payloads (per Anthropic channels-reference spec, Decision #132) require `meta` to be `Record<string, string>`. List, map, or nested-object values cause claude TUI to silently drop the entire notification — no error to either side.

**Diagnose:**
```bash
# In your bridge log:
grep "meta_keys=" ~/.ezagent/<profile>/logs/cc-bridge-*.log | tail
```

If meta_keys includes anything other than known string keys, that's likely the bug.

**Fix:** strip non-string values from meta. Structured data goes in `content` text or via `tools/call` round-trip. The only allowed non-trivial value is the single optional `meta.file_path` string (mirroring cc-openclaw convention).

**Forensic:** `docs/notes/phase-6-architecture-closeout.md` §2.3, Phase 6 PR 26.
**CI gate:** `apps/ezagent_domain_instance_message/test/esr/behavior/chat_test.exs` "to_claude payload meta values are all strings".

### Cause 2: Cap shape mismatch on `behavior` field (atom vs module)

`Capability.matches?/2` requires exact equality on `behavior`. The atom `:chat` is structurally different from `Ezagent.ActionSet.Chat` (a module reference). Atom-shorthand cap silently denies.

**Diagnose:**
```elixir
# In iex shell connected to the runtime:
caps = Ezagent.Identity.list_caps_for(URI.parse("user://someone"))
caps |> MapSet.to_list() |> Enum.each(fn c ->
  IO.puts("kind=#{inspect(c.kind)} behavior=#{inspect(c.behavior)} instance=#{inspect(c.instance)}")
end)
```

If `behavior` shows an atom like `:chat` (not `Ezagent.ActionSet.Chat`), that's the bug.

**Fix:** revoke + re-grant the cap with the module reference. Or if your code constructed it with `:any` and a narrow `:kind` (the documented workaround per `docs/notes/phase-7-handoff.md` §"Three trade-offs"), verify the kind matches.

**Forensic:** Phase 6 PR 27 — `feedback_let_it_crash_no_workarounds` debugging session.
**CI gate:** `apps/ezagent_core/test/esr/capability_test.exs` indirectly enforces via the existing tests.

### Cause 3: Workspace scope not plumbed

`Ezagent.ActionSet.Chat.invoke(:send)` at chat.ex:116 must call `Ezagent.Routing.Resolver.resolve/4` with `workspace_uri:` opt — derived from `Ezagent.WorkspaceRegistry.lookup(session_uri)`. If the session is unbound (custom Template Class spawned it without `WorkspaceRegistry.bind`), workspace-scoped routing rules never fire.

**Diagnose:**
```elixir
Ezagent.WorkspaceRegistry.lookup(URI.parse("session://your-session"))
# {:ok, %URI{...}} = bound
# :error = unbound (fallback to nil scope = pre-PR-31 global behavior)
```

**Fix:** in your plugin's spawn-session code path, call `Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)` after `Ezagent.SpawnRegistry.spawn`. `Ezagent.Workspace.Loader.invoke_template` does this for the canonical session classes; custom Template Classes follow the same pattern.

**Forensic:** `docs/phase-specs/phase7/DECISIONS.md` IMPL-7-1, Decision #135.
**CI gate:** `apps/ezagent_domain_instance_message/test/integration/workspace_isolation_test.exs`.

### Cause 4: Inbound transport using `:cast` instead of `:call`

For human-facing inbound transports (Feishu, future Slack/Discord/email), dispatch must use `mode: :call` so cap-denial returns synchronously and your handler can send an error message back. `mode: :cast` silently drops on `:unauthorized`.

**Fix:** in `your_plugin.InboundDispatcher.do_dispatch`, use `mode: :call`, decompose the result, on `{:error, :unauthorized}` send a text message back to the originating channel + a reaction emoji.

**Forensic:** `docs/notes/phase-6-architecture-closeout.md` §2.2, Phase 6 PR 27.
**Decision:** #134.

---

## Symptom: `:unauthorized` despite cap granted

### Cause 1: User Kind isn't alive (in-memory)

`Ezagent.Identity.list_caps_for/1` returns `MapSet.new()` if the User Kind isn't currently spawned. The DB has the cap row, but the in-memory slice is empty until the Kind starts.

**Diagnose:**
```elixir
Ezagent.KindRegistry.lookup(URI.parse("user://alice"))
# {:ok, pid} = alive
# :error = not spawned
```

**Fix:**
```elixir
Ezagent.SpawnRegistry.spawn(URI.parse("user://alice"))
# Then list_caps_for again
```

Note: SenderResolver in Feishu already does this auto-spawn (Phase 6 PR 18) for bound users.

### Cause 2: Cap shape mismatch (see "silent drop" cause 2)

### Cause 3: Scope-tuple cap doesn't match the action's context

If the user holds `{:within_session, session://main}` but the action targets `session://other`, the cap denies. Same for `{:spawned_by, _}` — agent not in the principal's lineage denies.

**Fix:** verify the scope dimension matches. Use a broader (less scoped) cap if appropriate, or re-grant with the correct scope.

**Decision:** #137 (scope-tuple cap shapes).
**CI gate:** `apps/ezagent_core/test/esr/capability_test.exs` "scope-bounded instance tuples".

### Cause 4: `{:spawned_by, _}` cap relying on PR-40-not-yet-shipped data

PR 42 ships `{:spawned_by, _}` as a deny-by-default placeholder. Until PR 40 ships the `Agent.spawned_by` slice field + lineage registry, this cap shape matches nothing.

**Fix:** wait for PR 40 to ship, or use `{:within_session, _}` as the bounded delegation cap for now.

---

## Symptom: orphan Node sidecar processes after phx restart

### Cause: Sidecar's stdin EOF handler missing or broken

`apps/ezagent_plugin_feishu/priv/ws_sidecar/main.js` must call `process.stdin.on('end', () => process.exit(0))` + `process.stdin.resume()`. When the Elixir Port closes (parent dies / Port.close called / VM exits), stdin sees EOF and the handler fires.

**Diagnose:**
```bash
# Kill phx; wait 10s; check for orphan node processes
pgrep -fla "node.*ws_sidecar"
# Should be empty (or only sidecars from sibling phx instances).
```

**Fix:** restore the EOF handler in main.js. Verify via:
```bash
mix test apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs --include slow
```

**Forensic:** Phase 6 PR 27 debug session (3 orphans accumulated, stealing inbound events).
**Decision:** #144 cross-PR invariant table.
**CI gate:** `apps/ezagent_plugin_feishu/test/sidecar_orphan_reap_test.exs` (`:slow` integration test spawns + kills + asserts pid dies in 3s).

---

## Symptom: workspace-scoped routing rule never fires

See "silent drop" cause 3 above. The rule's `workspace_uri` field is non-nil but `Chat.invoke(:send)` is passing `nil` to Resolver because the session is unbound in WorkspaceRegistry.

---

## Symptom: SessionTemplate fork loses lineage

### Cause: `parent_template_uri` field not set

`Ezagent.Entity.SessionTemplate.fork(parent_uri@hash, new_name)` MUST set `parent_template_uri = parent_uri@hash` (the specific source hash, not just the parent name).

**Diagnose:**
```bash
mix ezagent.session_template.show <forked-name>
# Inspect parent_template_uri field — should not be nil
```

**Fix:** verify the fork code path sets the field. The instantiated session also references this — `Ezagent.Entity.Session.spawn_from_template/2` reads it to track lineage.

**CI gate:** `template_fork_lineage_test.exs` (Phase 7 PR 38+ deliverable).
**Decision:** #141 (Fork unit = config only).

---

## Symptom: plugin install fails with `:already_loaded` or `:duplicate`

### Cause 1: Application already loaded

`:application.load/1` returns `{:error, {:already_loaded, app}}` if the app is already loaded. The install task treats this as success (idempotent install).

### Cause 2: TemplateRegistry strict-duplicate

If the new plugin registers a Template Class with a name another plugin already claims, `TemplateRegistry.register/1` returns `{:error, {:duplicate, existing, attempted}}`.

**Fix:** rename the Template Class with a plugin-prefixed name (e.g. `"yourplugin.classname"` instead of `"classname"`).

**Decision:** #136 (Template Class umbrella + strict-duplicate per Q3 in template_registry moduledoc).

### Cause 3: Mix.env() compile-time pitfall

Plugin's `Application.start/2` uses compile-time `Mix.env()` which returns the BUILD-time env, NOT the runtime env. Behavior diverges if the plugin was compiled with a different env than the host runtime.

**Fix:** use `System.get_env("MIX_ENV")` for env-dependent boot logic. Document this in your plugin's Application moduledoc.

**Decision:** #142 (Plugin runtime hot-install + Mix.env pitfall).

---

## Symptom: Feishu user message arrives but no reply or react

### Cause 1: Bound user lacks `session.chat` baseline cap

Phase 6 PR 27: every user should have `User.default_caps()` (currently `kind=:session behavior=:any`) installed. If the user was created pre-PR-27 (or via a path that skipped Users.create), they lack the baseline.

**Diagnose:**
```elixir
caps = Ezagent.Identity.list_caps_for(URI.parse("user://linyilun"))
caps |> MapSet.to_list() |> Enum.any?(fn c -> c.kind == :session and c.behavior == :any end)
# false = needs backfill
```

**Fix:**
- Forward: BindingPolicy.apply/2 idempotently grants defaults on (re-)bind. Run `mix ezagent.feishu.bind` for the user.
- One-off: dispatch `identity/grant_cap` directly.

**Forensic:** `docs/notes/phase-6-architecture-closeout.md` §2.1.
**Decision:** #133.

### Cause 2: Feishu InboundDispatcher silent-drop (resolved Phase 6 PR 27)

Phase 6 PR 27 fixed `InboundDispatcher` to use `mode: :call` + error feedback. If you're on a pre-PR-27 build, the dispatcher silently drops. Upgrade.

**Decision:** #134.

### Cause 3: Wrong Feishu chat (chat_id mismatch)

Ezagent's Feishu plugin binds specific chat IDs via routing rules. If the user is in a chat not bound to any session, the message goes nowhere.

**Diagnose:** check `routing_rules` table for the chat_id:
```sql
SELECT * FROM routing_rules WHERE receivers LIKE '%oc_xxxxxxx%';
```

**Fix:** add a routing rule binding the chat_id to a session via `mix ezagent.routing.add_rule` or `/admin/routing` LV form.

---

## Symptom: CC bridge can't reach Ezagent / `agent://cc-demo` shows offline

### Cause 1: Bridge process died

Each agent has a Python MCP bridge running. If it died, the agent's bridge isn't reachable.

**Diagnose:**
```bash
ls -lt ~/.ezagent/<profile>/logs/cc-bridge-*.log
tail ~/.ezagent/<profile>/logs/cc-bridge-<bridge_id>.log
```

**Fix:** restart claude in the PTY (it'll respawn the bridge), or `mix phx.server` restart if the PTY itself died.

### Cause 2: Bridge bound via v1 prototype after v2 cutover (PR 32 era)

If your build is post-PR-32 (CC v1→v2 cutover), no agent should bind via v1 prototype. If `agent://cc-demo` is still binding via v1, the cutover left a stale reference.

**Diagnose:** grep the codebase:
```bash
git grep "Ezagent.Bridge.V1Prototype" apps/
# Post-PR-32, this should return ZERO matches.
```

**CI gate:** `no_v1_bridge_after_cutover_test.exs`.

---

## Symptom: `Phoenix.Ecto.PendingMigrationError` at `GET /`

The browser shows "there are pending migrations for repo: EzagentCore.Repo. Try running `mix ecto.migrate`". The app boots OK but every web request 500s on the migration-check plug.

**Root cause:** `EzagentCore.MigrationGate.skip?/0` (`apps/ezagent_core/lib/ezagent_core/migration_gate.ex`) decides whether the `Ecto.Migrator` child runs migrations on boot. It runs iff one of:

- `RELEASE_NAME` env var is set (Mix release / `bin/ezagent start`)
- `MIX_ENV=prod` (e.g. `MIX_ENV=prod mix phx.server` — the app.ezagent.chat deploy)

Dev (`MIX_ENV=dev`) and test boots **never** auto-migrate — devs are expected to run `mix ecto.migrate` manually so the schema change is visible & deliberate.

**Fix on the prod box:**

```bash
cd <ezagent-checkout> && MIX_ENV=prod mix ecto.migrate
```

Then refresh the browser. If you want this to apply automatically on the next deploy, double-check the start script actually exports `MIX_ENV=prod` before invoking `mix phx.server` — without it the gate falls back to skip.

**Escape hatch:** if you ever need to boot prod WITHOUT applying a pending migration (e.g. troubleshooting, or rolling code back without rolling schema back), set `EZAGENT_SKIP_MIGRATIONS=1` for that boot. The override wins over both `RELEASE_NAME` and `MIX_ENV=prod`.

**CI gate:** `apps/ezagent_core/test/ezagent_core/migration_gate_test.exs` — 13-case env-var matrix locking the run/skip decision.

---

## Symptom: `npm install` / `pnpm install` (or `mix assets.build`'s tailwind/esbuild binary download) hangs or fails to resolve hosts

**Cause:** some dev boxes reach the public internet through a filtering proxy (GFW-style), so plain outbound HTTPS to the npm registry, GitHub releases (tailwind/esbuild download their platform binary from `github.com/tailwindlabs/...` / `github.com/evanw/esbuild` on first use), etc. times out or resets.

**Fix:** export a proxy before running any of `npm install`, `pnpm install`, `mix tailwind`, `mix esbuild`, or `mix assets.build`/`mix assets.setup` in `apps/ezagent_web`, `apps/ezagent_plugin_world`, `apps/ezagent_plugin_hello`:

```bash
export HTTPS_PROXY=http://127.0.0.1:7896
export HTTP_PROXY=http://127.0.0.1:7896
```

(matches the proxy already documented for the dockerized CI build in `docs/guide/ci-docker-local.md`, port 7896 — same box, same proxy, non-docker case). `mix tailwind`/`mix esbuild` print `Using HTTPS_PROXY: ...` in their download log when this is picked up.

**Note:** you should rarely need this for `mix test apps/ezagent_web/test` itself — that command no longer builds assets as a side effect (see `apps/ezagent_web/test/test_helper.exs`); it skips the one test that needs a real compiled bundle (`@describetag :requires_built_assets` in `demo_smoke_test.exs`) when `priv/static/assets/css/app.css` is absent. You only need the proxy + an explicit `mix assets.build` (from `apps/ezagent_web`) when you want that test to actually run locally, or when doing real frontend dev (`mix phx.server`, `mix assets.setup`).

**CI gate:** N/A locally; in CI, `mix ci.local`/`mix ci.shard.web` (see `mix.exs` `pnpm_install_assets/1` + `build_web_assets/1`) and the `frontend` GitHub Actions job (`.github/workflows/frontend-ci.yml`) build the real assets — those runners are not behind this proxy.

---

## When this runbook doesn't have your symptom

In order:

1. Search `docs/notes/` for the topic (e.g. "session", "cap", "bridge", "fork")
2. Search Decision Log (`ARCHITECTURE.md` Appendix B) for the area
3. Check `docs/phase-specs/<phase>/SPEC.md` for the relevant phase's design
4. Read the invariant test that covers the area — the test name often hints at the failure mode
5. Ask in the dev team channel

When you figure it out, **add it here**. Future contributors will thank you. The runbook grows with the team's collective experience.
