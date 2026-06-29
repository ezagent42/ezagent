# hello plugin + autoservice — state check under the socialware unification

**Date:** 2026-06-29
**Base:** `origin/main` @ `5d2b5d0d`
**Scope:** Did #1069 (socialware P1–P10), #1037 (retire customer concept),
#1075 (kanban de-bake), #1066 (cc readygate) delete or break prior work by
zhaomato (hello / 官网) and gaga (autoservice / agent-config)? Do hello and
autoservice still run / rebuild under the new socialware rules?
**Method:** READ-ONLY static + compile + test verification in a fresh worktree
off `origin/main`.

## TL;DR

- **hello still runs.** Compiles clean; all 31 plugin tests pass, including the
  end-to-end test that proves an anonymous viewer sees the builder's page
  (`hello_page_e2e_test.exs`). #1069 rewrote ONLY the socialware *gating*
  (`public_view: true` flag → `installs` list + `DefinitionRegistry` +
  `Installation` + `visibility_policy.web_anon_access`); zhaomato's renderer
  / Surface tree / json-render catalog / builder are intact.
- **autoservice is rebuildable as a chat socialware fixture under the new
  rules.** The Tier-1 seed was migrated to the identical install-relation
  pattern; `autoservice_tier1_seed_test.exs` passes (2/2). The seed is now
  data-driven (visibility, adapters, shape live in a socialware definition
  ConfigObject, not in code). The remaining gap is the live cc *answer* loop
  (cc PTY/startup blockers), NOT the socialware wiring.
- **zhaomato's prior work survived** — the customer SPA was *renamed*
  (customer→external) by #1037, not deleted; the page generator (#982) and
  world-hello convergence (#910) are intact, only re-pointed at the new
  install gate.
- **gaga's prior work survived AND became load-bearing** — #938's
  `ConfigStore` + `config_schema/0` callback is the substrate #1069's
  `Installation` relation is built on.

---

## 1. hello plugin — current state

### Build + run: GREEN

- `mix compile.app ezagent_plugin_hello` — clean (generates the whole closure).
- `mix test apps/ezagent_plugin_hello/test/` — **31 tests, 0 failures**
  (incl. `integration/hello_page_e2e_test.exs`).

### What the page renders

The hello page is an agent-generated **Surface tree** rendered through
`@json-render` islands. The internal reader gets `PageView`
(`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex`), which
emits a `<div phx-hook="HelloRenderer" data-spec=…>` hydrating
`/assets/hello/main.js` (the same renderer the external surface uses) inside
the world LiveView shell. The anonymous visitor gets the approved tree via
`ExternalFeed.snapshot/2` (was `CustomerFeed` before #1037's rename).

### What #1069 changed in hello (the ONLY rewrite)

`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex` (commit `e825e032`,
46-line diff). The gating mechanism changed; nothing else did.

Before (#1069):
```elixir
content = %{name: "hello-#{name}", public_view: true}
{:ok, tmpl} = SessionTemplate.persist_version_as_system(content, ws)
spawn_kind(Session, %{uri: session_uri, behaviors: Session.socialware_behaviors()})
```

After (#1069):
```elixir
socialware_name = "hello-#{name}"
content = %{name: socialware_name, installs: [socialware_name]}
{:ok, _} <- seed_hello_definition(ws, socialware_name),          # NEW
{:ok, tmpl} <- SessionTemplate.persist_version_as_system(content, ws),
{:ok, behaviors} <- Installation.behavior_set_for_template(content, workspace),  # NEW
spawn_kind(Session, %{uri: session_uri, behaviors: behaviors}),  # was socialware_behaviors/0
Installation.install_template_installs(session_uri, workspace, content, User.admin_uri())  # NEW
```

`seed_hello_definition/2` seeds a `DefinitionRegistry` definition whose
`visibility_policy: %{publish_policy: :auto, web_anon_access: true}` replaces
the old `public_view: true` flag. The behaviors now come from the install
union (`Installation.behavior_set_for_template/2`) instead of the hardcoded
`Session.socialware_behaviors/0`.

### The page still serves — proven

`hello_page_e2e_test.exs:116` ("ensure_app spawns the session through the
socialware install set") asserts the session's `:kind_base` slice carries
exactly `Session + Turn + Surface + Publisher.SessionImpl` from the install
set; `:61` asserts an anon viewer's `ExternalFeed.snapshot` returns the
approved spec. Both green. The `public_view?/1` → `web_anon_access?/1` gate
now reads the LIVE session's installed definitions
(`PublicView.web_anon_access?/1` is a one-line facade over
`Installation.web_anon_access?/1`, `public_view.ex:18`).

### Files (hello) — what #1069 touched

| File | Change | Verdict |
|------|--------|---------|
| `app.ex` | gating rewrite (above) | mechanical migration, correct |
| `page_view.ex` | 14 lines (external-rename wording) | substance unchanged |
| `application.ex` | 6 lines | boot wiring |
| `generator.ex` | 8 lines | narration |
| `template/hello_session.ex` | 4 lines | template class intact |
| `assets/src/catalog.ts`, `registry.tsx` | 4 lines each | zhaomato's renderer intact |

---

## 2. autoservice — current state (rebuildable? YES)

### The seed was migrated to the new model

`scripts/autoservice_tier1_seed.exs` — `ensure_public_view_session/2`
(lines 423–476) got the **identical** #1069 migration as hello's `app.ex`:
`DefinitionRegistry.seed_definition_if_absent` (with
`visibility_policy: %{publish_policy: :auto, web_anon_access: true}`) +
`installs: [definition_name]` + `Installation.behavior_set_for_template` +
`Installation.install_template_installs`. The seed was touched in #1069
(48-line diff to the seed, 11 to its test).

### Seed test: GREEN

`apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs` —
`Code.require_file`s the shipped seed (so the test exercises the real wiring,
not a parallel one) — **2 tests, 0 failures**.

The test proves:
- **S1** anon access: `PublicView.web_anon_access?(session_uri)` is true.
- **S2a/S2b** routing: a BARE (un-@-mentioned) customer message resolves to
  the AutoService agent via the seeded `always(in_session)→agent` rule; a
  negative probe confirms the rule is session-scoped, not global.
- **S3 retrieval soul**: `kb.query` carrying the orchestrator's seeded cap
  returns the `ZEPHYR-7731` fact that exists only in the ingested corpus.
- The (non-cc) test flavor creates the AutoService agent, grants `kb.query`,
  and joins it — `autoservice_agent_status == :created`.

### Is autoservice now a chat socialware fixture under the new rules? YES

Under #1069 a socialware fixture = a `DefinitionRegistry` definition (a
ConfigObject holding bases/shape/members/routing_rules/prompt_templates/
legends/adapters/visibility_policy) + a SessionTemplate whose `installs`
names it. The autoservice seed builds EXACTLY this:

- the definition (`autosvc-<short>`) carries `bases: [Session,
  Publisher.SessionImpl]`, `shape: [Turn, Surface]`, the `web_feed` customer
  adapter, and `visibility_policy`. No business logic in code.
- the SessionTemplate `installs: [autosvc-<short>]`.

What remains **business-logic-in-code** (not yet data) is the
always→AutoService routing rule, which the seed writes via
`RuleStore.add` (`ensure_always_to_agent_rule/2`, line 523). That is a
routing rule, not a socialware-shape concern, and is idempotent + tested —
acceptable for a fixture seed.

### What the seed needs to fully rebuild on a live stack

1. **kb-agent + corpus** — wires today (`ensure_kb_agent` + `ingest_corpus`),
   flavor `native` on a booted node.
2. **public_view session** — wires today via the install relation (above).
3. **always→agent routing rule** — wires today.
4. **AutoService cc-orchestrator agent** — STILL BEST-EFFORT / BLOCKED on the
   live path: `Workspace.create_agent` with flavor `"cc"` + role
   `"orchestrator"` returns `{:role_unsupported_for_flavor, "cc"}`; a live cc
   orchestrator is materialized via the session-create orchestrator-template
   path, not `create_agent`. The seed REPORTS this as
   `autoservice_agent_status: {:blocked, reason}` (not a silent degrade) and
   the deterministic chain (kb + route + public_view) is wired before it
   runs. This is the SAME documented gap as before #1069 — the socialware
   rewrite did not introduce it and did not regress it.

### Serve-seed

`scripts/autoservice_tier1_serve_seed.exs` (the live in-node wrapper that
keeps the public_view session LIVE in the serving BEAM — the §2 cold-restart
trap) is present and unchanged in substance.

---

## 3. zhaomato's prior PR work — affected summary

zhaomato = `zhaomaota97` on GitHub.

| PR | Work | Effect of #1069 / #1037 |
|----|------|-------------------------|
| #891 | first hello plugin (AI @json-render pages on socialware substrate) | base; gating re-pointed by #1069, renderer intact |
| #910 | world-hello convergence (create / preview / public-link / chat) | **SURVIVES.** `Template.HelloSession` (`session.hello` Template Class) still registered via `template_classes/0` (`application.ex:53`); `instantiate/3` delegates to `App.ensure_app/2`, so world's generic New-session form still creates a hello app with NO world edit. #1069 P7 ("unify form socialware authoring") touched the socialware author form, not the hello class seam. |
| #961 | official-site / AI page generation (supersedes #956) | survives |
| #982 | AI page generator — pure-shadcn rendering, collaborative whiteboard, incremental edits | **SURVIVES.** `assets/src/{catalog,main,registry}.tsx` intact; #1069 touched 4 lines in `catalog.ts` + `registry.tsx`. The Surface tree + `HelloRenderer` hook unchanged. |
| #603 | customer React feed (SPA) | **RENAMED, not deleted, by #1037.** `customer_app.js`→`viewer_app.js`, `CustomerController`→`ExternalFeedController`, `CustomerFeed`→`ExternalFeed`, `/socialware/customer`→`/socialware/external` (with 301 back-compat at `router.ex:125`). The `/socialware/chat` route hello's anon visitors use is UNCHANGED. `CustomerAuth` was deleted (anon-user/membership replaces it). |

**What got rewritten:** ONLY the socialware *gating* (template boolean
`public_view` → install relation + `web_anon_access` visibility field).
zhaomato's page-generation / rendering / world-convergence work is intact
and re-pointed at the new gate mechanically.

### Stale wording (cosmetic, non-blocking)

`apps/ezagent_plugin_hello/mix.exs:43` comment still says "`CustomerFeed` +
`public_view`" — both names are now historical (`ExternalFeed` + install
relation). Harmless comment; could be refreshed.

---

## 4. gaga's prior PR work — affected summary

gaga = `Gaga` / `gagameow` on GitHub.

| PR | Work | Effect of #1069 / #1037 |
|----|------|-------------------------|
| #938 | agent-config backend facade + CRUD contract (`agent_config.ex`, `config_store.ex`, `config_schema/0` callback) | **SURVIVED AND BECAME LOAD-BEARING.** #1069's `Installation` module (`apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex`) aliases and uses gaga's `ConfigStore` + `ConfigObject` to materialize per-session install records (line 10, line 147+). The `config_schema/0` callback is still implemented across `agent_template.ex`, `cc_agent.ex`, `codex_agent.ex`, `py_agent.ex`, etc. gaga's config substrate IS the socialware-def-as-ConfigObject model #1069 built on. |
| #981 | agent console M1-M4 design (`@callback config_schema/0` explanation) | design docs; still describe the callback that lives in main |
| #994 | agent console M1-M4 (world) | separate concern (operator console), not touched by socialware |
| #1024 | autoservice agent-config 对标验证 + Feishu WSS fix + E2E eval (FP2) | verification context. The autoservice seed itself (#1051, by Allen) was migrated to the new model in #1069 and still passes. gaga's "对标" (parity-check) goal — "does the original autoservice chain still run after the runtime rewrite" — is re-answered: YES, the deterministic half (kb + route + public_view session) runs + is tested; the live cc answer loop remains the documented gap. |
| #907 | cc-headless + codex-remote flavors, protocol-api flavor resolution | flavor layer; orthogonal to socialware, not regressed |

### Is gaga's agent-config validation still meaningful under the new model? YES

The new model is "socialware-def as ConfigObject" — and `ConfigStore` +
`config_schema/0` (gaga's #938) are exactly the substrate that makes a
socialware definition a versioned, addressable config object. gaga's
agent-config contract is MORE meaningful now, not less: it is the reason
`Installation.installed_definitions/1` can resolve a session's installed
socialwares by reading ConfigStore pointers.

---

## 5. What zhaomato + gaga each need to do today

### zhaomato (hello / 官网)

1. **Re-run the hello page on a live disposable stack** to confirm the
   browser path (not just the ExUnit test). The unit test proves the
   substrate path; a live browser screenshot is the ESR sign-off bar
   (`/socialware/chat?session_uri=session://<ws>/hello/<name>` after
   `mix ezagent.demo.seed_hello` or `App.ensure_app/2`). The customer SPA
   bundle is now `viewer_app.js` (renamed by #1037) — confirm
   `cd apps/ezagent_web/assets && pnpm install && mix assets.build` so the
   page is not blank.
2. **Refresh the one stale comment** in `apps/ezagent_plugin_hello/mix.exs:43`
   (`CustomerFeed`/`public_view` → `ExternalFeed`/install relation) — trivial.
3. No structural rework needed: his renderer, catalog, and the
   `session.hello` Template Class all survived. The only behavioral change
   is that anon access is now gated by the install relation's
   `web_anon_access` field, which `App.ensure_app/2` already sets correctly.

### gaga (autoservice / agent-config)

1. **Re-run the autoservice Tier-1 seed on a live disposable stack** to
   confirm the deterministic chain (kb + public_view session + routing)
   still stands up live, and to report the live cc-orchestrator answer-loop
   status. The seed is `scripts/autoservice_tier1_serve_seed.exs` (keeps the
   session live in the serving BEAM). The deterministic regression
   (`autoservice_tier1_seed_test.exs`) is already green on main.
2. **The AutoService cc-orchestrator live-create is still blocked** by
   `{:role_unsupported_for_flavor, "cc"}` — the orchestrator must be
   materialized via the session-create orchestrator-template path, not
   `Workspace.create_agent`. This is the same pre-#1069 gap, not a
   regression. If gaga wants the live answer loop, that path is the work
   item, not the socialware wiring.
3. **His agent-config / `ConfigStore` work needs no rework** — it is now the
   substrate #1069 builds on. He can extend the socialware definition shape
   (members/routing_rules/prompt_templates/legends are already fields in the
   definition gaga's ConfigStore persists) if autoservice needs richer
   orchestration-as-data.

---

## Verification reproducer (worktree off `origin/main` @ `5d2b5d0d`)

```
git worktree add .worktrees/hello-autosvc-state origin/main -b docs/hello-autosvc-state
cd .worktrees/hello-autosvc-state
mix compile.app ezagent_plugin_hello                       # GREEN
mix test apps/ezagent_plugin_hello/test/ --no-deps-check   # 31 tests, 0 failures
mix test apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs   # 2 tests, 0 failures
```

(Worktree deps: symlink `deps` from the main checkout; the seed test's
`Ezagent.AutoService.Tier1Seed` "undefined" warnings are expected — the
module is `Code.require_file`-loaded at runtime by design.)
