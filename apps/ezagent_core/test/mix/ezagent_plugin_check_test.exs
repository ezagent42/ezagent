defmodule Mix.Tasks.Compile.EzagentPluginCheckTest do
  @moduledoc """
  Tests for the `:ezagent_plugin_check` Mix compiler (SPEC §3.2).

  PR-1 only DEFINES the compiler — it is wired into a plugin app's
  `mix.exs` at migration time (PR-2/3). The behaviour these tests pin:

  - **un-migrated app (no `:ezagent_plugin` key) → no-op pass.** This
    is the design choice (see the compiler moduledoc): the
    `compilers:` line may land before the plugin module, so the gate
    must not block a partial migration. `ezagent_core` itself sets no
    `:ezagent_plugin` key, so running the compiler in this project
    exercises exactly that path.

  The cross-module / scheme / grep checks run only once an app sets
  `:ezagent_plugin`; they are integration-exercised when echo + curl
  migrate in PR-2 (SPEC §7 row 2 — "acceptance tests use the real
  echo/curl startup paths").
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Compile.EzagentPluginCheck

  test "is a no-op pass for an app with no :ezagent_plugin app-env key" do
    # ezagent_core declares no :ezagent_plugin key — the un-migrated
    # case. The compiler must pass cleanly. This also exercises the
    # `Mix.Task.Compiler` `run/1` entry point.
    assert {:ok, []} = EzagentPluginCheck.run([])
  end

  test "is a Mix.Task.Compiler" do
    behaviours =
      EzagentPluginCheck.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Mix.Task.Compiler in behaviours
  end
end
