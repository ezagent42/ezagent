# #52 Mode-A fix — standalone-vs-umbrella exclusion.
#
# Many `ezagent_core` test suites are CROSS-TIER: they reference modules
# defined in SIBLING umbrella apps (e.g. `Ezagent.Users` in
# ezagent_domain_identity, `Ezagent.Workspace.Store` in
# ezagent_domain_workspace, `Ezagent.Entity.Session` in
# ezagent_domain_session). `ezagent_core`'s `mix.exs` does NOT —
# and per the three-tier rule MUST NOT — depend on those apps, so when you
# run `cd apps/ezagent_core && mix test` (STANDALONE) those modules are not
# on the BEAM code path and the suites fail with
# `UndefinedFunctionError … is not available`. That is NOT a sandbox race;
# it is "running a cross-tier suite outside the only context (the umbrella
# root) that can satisfy its deps." The supported test command is
# `mix test` from the umbrella root.
#
# Those suites carry `@moduletag :umbrella_only`. Here we EXCLUDE that tag
# ONLY in standalone mode — detected by the absence of a sentinel sibling
# module (`Ezagent.Users`). In the umbrella run every sibling app's `ebin`
# is loaded, so the module resolves and the tag is NOT excluded (the
# cross-tier suites run, as they must). This mirrors the existing
# `:uv`-exclusion precedent in ezagent_domain_python/test/test_helper.exs.
standalone? = not Code.ensure_loaded?(Ezagent.Users)

# native-mac full-suite unblock — `:security_probe` platform gate.
#
# `Ezagent.Security.OsProcessSecretIsolationProbeTest` "same-uid child
# environment is visible through proc" reads `/proc/<pid>/environ` to prove a
# same-uid child's env is visible via procfs. That is Linux-only kernel
# surface — macOS has no `/proc`, so the probe deterministically fails there
# with `cat: /proc/<pid>/environ: No such file or directory` (exit 256). This
# is the FIRST native-mac execution of this suite (the dockerized CI gate
# runs Linux, where the probe genuinely exercises procfs and passes); a
# mac-equivalent probe (e.g. via `vmmap`/`ps eww`) is out of scope here — the
# reproduction value of this probe is specifically the Linux `/proc`
# semantics, and a mac substitute would prove nothing about that boundary. So
# rather than fake the semantics on a platform that doesn't have them, skip
# the tag outright on any non-Linux host and document why.
exclude_tags =
  if(standalone?, do: [:umbrella_only], else: []) ++
    if match?({:unix, :linux}, :os.type()), do: [], else: [:security_probe]

ExUnit.start(exclude: exclude_tags)
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)

# Flake-hardening (2026-07-03): pre-warm the architecture-scan cache ONCE,
# single-threaded, before any async arch test runs.
#
# `Mix.Tasks.Ezagent.Arch.Scan.measure/0` memoizes a full-tree scan (~645 lib
# files, each AST-parsed several times — measured ~4.4s cold) in `:persistent_term`;
# the FIRST caller pays that cost, every caller after reads the cached term in ~0ms.
# The 16 `async: true` architecture suites all funnel through `count/1` → `measure/0`,
# so exactly ONE of them — whichever ExUnit happens to schedule first — pays the 4.4s
# scan plus a `:persistent_term.put` (which forces a global GC across every live
# process). Under the full-umbrella parallel run that cost lands INSIDE the contended
# window and can breach the 60s ExUnit test timeout, failing that one arbitrary test
# non-deterministically (green in isolation, ~flaky under load — see mix.exs note and
# `runtime_ordering_test` / `cc_bridge_shim_test`). Warming the cache here moves the
# cost out of the timeout-sensitive window; every arch test then only reads the
# pre-populated term. This removes a real, movable cost — it is not a masked sleep or
# a widened timeout.
Mix.Tasks.Ezagent.Arch.Scan.measure()
