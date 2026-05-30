# DemoSmokeTest "Bug 2" asserts the compiled Tailwind bundle exists at
# priv/static/assets/css/app.css (a gitignored build artifact). The bare
# `mix test` gate — including the umbrella-root run — does not invoke the
# per-app `assets.build` alias, so the artifact is absent unless someone
# built it manually, and the smoke test fails environmentally. Build it
# here (only when missing) so the artifact is present under every test
# invocation. Cheap: skipped entirely once the bundle exists.
css_path = Path.expand("../priv/static/assets/css/app.css", __DIR__)

unless File.exists?(css_path) do
  IO.puts(:stderr, "[ezagent_web test setup] building tailwind+esbuild bundle (missing app.css)")
  {_out, 0} = System.cmd("mix", ["tailwind", "ezagent_web"], cd: Path.expand("..", __DIR__))
  {_out, 0} = System.cmd("mix", ["esbuild", "ezagent_web"], cd: Path.expand("..", __DIR__))
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
