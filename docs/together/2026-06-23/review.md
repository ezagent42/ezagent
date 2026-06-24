# dev-together close review — 2026-06-23 cycle (lead: Claude)

_What landed at close, the post-close arch-debt burn-down, and the carry-forward
items. Authored against `origin/main` after the close + arch work merged._

## 1. Close: returned handoffs merged to `main`

All gated by full `mix precommit` (EXIT=0, all suites 0 failures) +
`mix ezagent.check_invariants` (EXIT=0) before each merge. Self-approve is
impossible on agent-authored PRs ("Can not approve your own pull request"), so
each used the authorized `--admin --squash` merge (REVIEW_REQUIRED bypass).

| PR | Task | Dev | merge commit |
|---|---|---|---|
| #912 | session-create ↔ orchestrator decouple (impl) | (Claude/codex) | 036ce540 |
| #910 | world ↔ hello convergence | FatNine | b6c50400 |
| #905 | world agent create/config/detail → agent-contract (MVP) | gagameow | 63e493c4 |
| #914 (supersedes #902) | world-deploy-e2e-pg: PG runbook + E2E matrix + evidence | zylideveloper | e5a70976 |
| #915 (re-land of #907) | agent-flavor-headless-protocol-api (URI-arch fixed) | gagameow | e99e6005 |

`b3b23b74` (the one #902 product commit) kept **inline** per goal. `#904`
(agent-console-operate-first-demo) **not merged** — reclassified as a supplement
to #905 (it is a demo, not a real agent console).

## 2. #907 owner-violation log → REMINDER for gagameow

Per Allen's directive ("直接帮 #907 owner 改掉违规的地方，但登记进 review 里面,
未来提醒注意"), the #907 re-land (#915) fixed violations the owner's branch
shipped. **gagameow: please note these for future PRs:**

1. **5 real URI-architecture violations** in `apps/ezagent_plugin_protocol_api`
   (hard zero-tolerance UriQuery scan — NOT just baseline drift):
   - `openai_chat_plug.ex`: 3× `Ezagent.URI.new!("entity://system/agent/echo_default")`
     → typed builder `Ezagent.URI.entity("system", :agent, "echo_default")`.
   - `openai_chat_plug.ex` `flavor_from_uri`: positional `List.last(String.split(rest, "/"))`
     name derivation → `Ezagent.URI.name(agent_uri)` accessor.
   - `api_key_store.ex` `parse_token`: `String.split(rest, "_", parts: 2)` tripped the
     flavor-prefix scan → `:binary.split(rest, "_")` + comment clarifying it parses an
     API *token*, not a URI.
2. **2 regex-`==` credential test bugs**: `~r/a/ == ~r/a/` is **false** (Regex structs
   never compare equal across compilations). The cc-headless / codex-remote
   `auth_failure_signals` delegation tests now compare via `Enum.map(&inspect/1)`.
3. **8 mechanical arch-baseline + UriQuery-anchor drifts** (spawn_registry caps,
   template-LOC, duplicate-groups) — bumped with `# arch-cap-bump:` annotations.

**Takeaway for owners:** run `mix ezagent.check_invariants` + the full
`mix precommit` (read the `EXIT=` line explicitly) before returning — the hard
zero-tolerance UriQuery categories fail the build, they are not advisory.

## 3. Post-close: i18n + anti-CJK gate (#91, PR #916)

- Hello builder narration (`Generator`, ~17 CJK `TurnDriver.say` strings) routed
  through the plugin-owned `EzagentPluginHello.Gettext` backend (English msgids +
  `priv/gettext/zh_CN`; per-turn `put_locale` + config `default_locale: "zh_CN"`
  preserve the Chinese rendering — verified empirically).
- New target-zero arch gate `Ezagent.Architecture.CjkLiteralGateTest` (AST-based,
  `Macro.prewalk`; comments + `@moduledoc`/`@doc` pruned) forbids Han string
  literals under `apps/ezagent_plugin_hello/lib`. Includes a **self-test** so the
  gate can't rot into a no-op. Scope = plugin_hello now; umbrella-wide widening
  tracked in `docs/futures/todo.md`.

## 4. Post-close: ESR → Ezagent brand cleanup (#89, PR #917)

84 files; 148 → 8 ESR mentions, all sanctioned keeps. Line-level (not file-level)
`\bESR\b → Ezagent` with a keep-set preserving runtime identifiers
(`esr-bridge`/`esr-channel`/`esr-orchestrator`, the `Mix.Tasks.Esr` `mix esr`
deprecation alias, the `esr-ng` path) and rebrand-history docs. Diff-grep
confirmed no historical reference was corrupted. The 3 acronym-expansion lines
(ESR = **E**zagent **S**ession **R**outer) reworded to "Session Router".

## 5. Post-close: arch-debt burn-down (Allen 2026-06-23)

Allen: "将 arch debt 中可以清理的也全部清理后再进 review 和 plan." Honest accounting
of what was cleaned vs. what is **deliberately not** cleaned, and why:

### ✅ Cleaned — `oversized_modules_gt_1000` 3 → 0 (PR #919)

Real debt (a module too big to hold in one context). All three trimmed under 1000
by cohesive extractions + thin delegates (pure refactors, API unchanged):
- `pty/server.ex` 1027→892 → `Ezagent.Domain.Pty.AutoPrompts`
- im `application.ex` 1025→867 → `…SessionBehaviorRegistration.register/0`
- `kind.ex` 1025→882 → `Ezagent.Kind.BehaviorSet` + new `Ezagent.Kind.SliceAccess`

Cap ratcheted to a hard **0**.

### ⛔ Not cleanable — `raw_home_path_outside_core` 2 (world `layout_dir/0`)

Investigated per Allen's flag. The `resource://` registry (`Resource.FsResolver`)
is **core-compile-time only** (`Registry.boot_registrations/0`, no plugin
self-registration); migrating the world layout there would force **core to name a
world-plugin type** (tier violation / breaks plugin isolation) — strictly worse
than the current exact-anchored `HomePathExceptions` entry. The codex SUN_LEN
app-server socket is genuinely un-migratable (OS handle, Decision D2). Both stay
sanctioned. **Proper fix = a separate feature**: plugin-owned resource-type
registration on `Resource.FsResolver`, then migrate world layout (+ future plugin
artifacts) onto it. Spec-worthy, not a sweep. (Tracked: `docs/futures/todo.md`.)

### 🟡 Deliberately deferred — judgment calls, NOT impossibility

Correcting my earlier "都可清" framing — these are mechanically reducible but
**not worth doing as number-chasing**, or not responsibly doable tonight:

- **`cc_codex_template_class_combined_loc` 1684** — a **growth ceiling**, not a
  too-big-file. Both `cc_agent.ex` (930) and `codex_agent.ex` (754) are already
  <1000 individually. Reducing the *combined* cap means extracting cohesive flavor
  logic purely to lower a number → fragments code that belongs together (violates
  the no-workarounds/cohesion principle). Recommend leaving as the growth ceiling
  it is; revisit only if either file individually approaches 1000.
- **`cross_file_duplicate_fn_groups` 32** — manifest comments describe several
  groups as **sanctioned intentional mirrors** (flavor-template delegations, the
  KindBaseBackfill/SliceMigration row-selector mirror, …). **I have NOT audited the
  full 32 breakdown** (sanctioned vs. genuinely-dedupable) — that audit is itself a
  small task before any dedup work. Not asserting a number I didn't verify.
- **`undocumented_public_defs` 392 (#55)** — genuinely reducible, but a mass
  @doc-sweep would ship **unverified** doc claims, violating
  `feedback_doc_why_must_be_code_verified` (every behavioral claim verified against
  the code). Needs a deliberate, codex-reviewed, batched campaign — fits neither
  tonight's budget nor tomorrow's manual-full-flow focus. Structured as its own
  future track (see plan).

## 6. Carry-forward / watch items

- **WorldHostRoutingTest flaky** (pre-existing): a PID in `world_state` makes
  `Jason.encode!` fail under async concurrency; proven transient (isolated 10/0
  twice). Not a close regression. Owner: world/test-isolation.
- **external_mirror `facade_test` PG-sandbox flake** (LOW, pre-existing, already in
  `docs/futures/todo.md`).
- **i18n umbrella-wide gate widening** — extend `CjkLiteralGateTest.@scanned_globs`
  beyond plugin_hello (~20-file sweep). Tracked in `docs/futures/todo.md`.
- **#55 doc-coverage campaign** + **plugin-owned resource-type registration** (to
  unblock world `layout_dir` migration) — both spec/codex-review-worthy future
  tracks.
