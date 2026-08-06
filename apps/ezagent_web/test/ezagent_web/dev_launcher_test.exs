defmodule EzagentWeb.DevLauncherTest do
  use ExUnit.Case, async: true

  @launcher Path.expand("../../../../bin/dev", __DIR__)
  @project_mix Path.expand("../../../../mix.exs", __DIR__)

  test "clears the actual vite.js process shape before boot" do
    source = File.read!(@launcher)

    assert source =~ ~S"vite(\.js)? --host 0.0.0.0 --port ${port}"
  end

  test "uses the supported phx.server invocation" do
    source = File.read!(@launcher)

    assert source =~ "exec iex -S mix phx.server\n"
    refute source =~ "phx.server --permanent"
  end

  test "starts dev applications permanently so a dead domain cannot leave HTTP serving" do
    source = File.read!(@project_mix)

    assert source =~ "start_permanent: Mix.env() != :test"
  end
end
