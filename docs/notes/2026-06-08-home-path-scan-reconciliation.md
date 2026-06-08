# `home_path_in_runtime_code` scan gate — reconciliation with #25 `raw_home_path`

**Date:** 2026-06-08 · **Phase:** Resource-unification P0.5 · **PR:** feat(resource):
P0.5 home_path_in_runtime_code scan gate + reconcile with #25 raw_home_path

## Two scanners, one source of truth

Resource-unification P0.5 adds a hard-fail-NEW gate for raw `Ezagent.Home.path`
callers. #25 already shipped a `raw_home_path_outside_core` counter on a
*different* scanner. Allen flagged the coordination risk: do **not** build two
divergent hardcoded lists. This note records the decision.

### What each scanner does (decision **b** — crisp division of labor)

| | `mix ezagent.arch.scan` `raw_home_path_outside_core` (#25) | `mix ezagent.uri_query.scan` `home_path_in_runtime_code` (P0.5) |
|---|---|---|
| Role | **count ratchet** for the #25 fitness goal ("core should own `Home`") | **hard-fail-NEW enforcement** + boot/operator/OS-handle exemptions |
| Detection | text-grep `Home.path(` | AST match `path` / `profile_dir` / `home`, alias-/import-/`__MODULE__`-aware |
| Scope | `apps/*/lib/**/*.ex`, hits **outside** `apps/ezagent_core/` | **all** `apps/**/*.ex` (incl. core) |
| Tolerance | a single integer cap (`arch_baseline_manifest.exs`) | line-anchored burn-down baseline + exact `Module.function/arity` exceptions |
| Fails when | outside-core count exceeds cap | a NEW call is neither baselined nor exactly-anchored-exempt |

We chose **(b) division of labor over (a) shared detector** because the two have
genuinely different jobs and surfaces. A shared detector would force arch.scan to
adopt AST semantics over all-apps and change its count meaning, putting the #25
ratchet at risk for no benefit.

### The anti-drift mechanism (the actual reconciliation)

`apps/ezagent_core/test/ezagent/uri_query/scan_home_path_reconcile_test.exs`
asserts:

> **Every `Home.path(` call arch.scan counts in `raw_home_path_outside_core`
> MUST be known to P0.5 — present in EITHER `HomePathBaseline` OR
> `HomePathExceptions`.**

So neither scanner can grow a raw `Home.path` call the other doesn't know about.
A new outside-core call raises arch.scan's count (ratchet) AND, being neither
baselined nor exempt, fails P0.5's hard-fail-new gate — and the consistency test
fails if someone updates one list's awareness but not the other's. A second test
asserts no outside-core P0.5 exception anchor is invisible to arch.scan (an
exemption can't hide a call the ratchet must count).

### A real drift the gate caught

`cc_agent.ex:1460` is a **doc comment** (`#   <Ezagent.Home.path("cc-agents")>...`),
not a call. arch.scan's text-grep counted it (cap was inflated to 9). P0.5's AST
scanner correctly ignores it. The reconcile test flagged the divergence. Fix:
the comment now carries `# arch-allow:` and the cap tightened 9 → **8** (the real
outside-core call count). This is the "one source of truth" working as intended.

## Baseline + exemption census (current main: post-#641, post-Phase-3, post-#648)

The pre-#648 spec/plan examples (`admin_live.ex:701/731`,
`uploads_controller.ex:108`) no longer hold raw `Home.path` calls — #648 moved
uploads into `apps/ezagent_core/lib/ezagent/uploads.ex`. The census was rebuilt
on `origin/main`.

**Baseline (12 burn-down entries — migrate in P1/P2/P3):**
`config_dir.ex:32` (→P1); `uploads.ex:40,75` (→P2b);
`token_store.ex:120`, `identity application.ex:143`,
`feishu client.ex:164,176,414`, `feishu ws_client.ex:165`,
`feishu application.ex:176`, `python server.ex:708` (→P3).

**Exceptions (exact `Module.function/arity` anchors — permanent):**
`Ezagent.Resource.FsResolver.resolve/2` (the R-4 sanctioned single chokepoint);
`Ezagent.Runtime.cookie_path/0`; `Ezagent.Runtime.PidFile.dir/1`;
`Mix.Tasks.Ezagent.{Home.Init,Home.Backup,Home.AdoptDb,Bootstrap}` run/helpers;
`Ezagent.Home.Migration.{backup/1,write_manifest/2}`;
`Ezagent.PluginCodex.Template.CodexAgent.default_app_server_socket_path/1`
(OS-handle SUN_LEN socket); plus `config/runtime.exs:14,17` (config-eval, listed
for completeness — outside the scanner globs).

Module/line corrections vs the spec snapshot: pid_file is `Ezagent.Runtime.PidFile`
(not `EzagentRuntime.PidFile`); codex template is
`Ezagent.PluginCodex.Template.CodexAgent`; `config/dev.exs` and
`ezagent.home.restore.ex` have no live Home calls on current main and were dropped.

## Exemption robustness (codex adversarial-review, two rounds, folded in)

- Exceptions are exact `Module.function/arity` + line; the S-2 guard rejects any
  `*` or bare path/dir prefix. **No glob/dir allowlist.**
- Exception subtraction is by **enclosing-function identity**
  (`home_call_anchor_matches?/3`), not `{path, line}` alone: a changed call at the
  same line, or a wrong fn id, is not exempted.
- Baseline subtraction is a **per-line budget** (codex MEDIUM): a second Home call
  added on an already-baselined line fires.
- Detection is alias-aware: fully-qualified, plain `alias`, renamed
  `alias …, as: H`, `alias Ezagent.{Home, …}`, `__MODULE__.Home.path`, and
  `import Ezagent.Home` (respecting `only:`/`except:`). Bare local `path/1` in a
  file that does not import Home is **not** a false positive.
