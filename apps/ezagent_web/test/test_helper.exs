# DemoSmokeTest "Bug 2" (@describetag :requires_built_assets) asserts against the
# REAL compiled Tailwind bundle at priv/static/assets/css/app.css (a gitignored
# build artifact produced by `mix tailwind`/`mix esbuild`, which in turn need
# `assets/node_modules` — see apps/ezagent_web/assets/css/app.css's
# `@import "../node_modules/xterm/css/xterm.css"` and the xterm/xterm-addon-fit
# imports in assets/js/hooks/pty_terminal.js).
#
# This test_helper used to shell out to `mix tailwind`/`mix esbuild` here to
# build that bundle on demand. That made EVERY invocation of `mix test` —
# including a bare `mix test apps/ezagent_web/test` in a fresh worktree where
# `npm install`/`pnpm install` was never run — hard-depend on a full JS
# toolchain, and test_helper.exs (which runs before ANY test starts) died
# before a single test could execute. Tests should not need a real built asset
# bundle merely to boot.
#
# Fix (mirrors the `:uv` pattern in apps/ezagent_domain_python/test/test_helper.exs
# — skip-by-default when the prerequisite isn't present, no build side-effect at
# test boot): if the bundle is missing, exclude :requires_built_assets so the
# Bug-2 tests skip with a clear reason instead of crashing test setup. CI's `web`
# shard (`mix ci.shard.web`, see mix.exs `build_web_assets/1`) and `mix ci.local`
# build the bundle explicitly BEFORE tests run, so this tag is not excluded there
# and Bug-2 keeps running for real in CI. A dev who wants it locally runs
# `mix assets.build` (from apps/ezagent_web) first — see
# docs/runbook/common-failures.md for the npm-via-proxy note.
css_path = Path.expand("../priv/static/assets/css/app.css", __DIR__)

exclude =
  if File.exists?(css_path) do
    []
  else
    IO.puts(
      :stderr,
      "[ezagent_web test setup] skipping :requires_built_assets tests — " <>
        "priv/static/assets/css/app.css not built. Run `mix assets.build` " <>
        "(from apps/ezagent_web; needs assets/node_modules — see " <>
        "docs/runbook/common-failures.md) or `mix ci.local`/`mix ci.shard.web` " <>
        "(which build it automatically) to include these."
    )

    [:requires_built_assets]
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
