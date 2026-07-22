defmodule Mix.Tasks.Ezagent.Socialware.CheckTest do
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureIO

  alias Ezagent.Socialware.{Definition, DefinitionRegistry}

  @workspace_uri Ezagent.URI.workspace(:system)
  @actor_uri Ezagent.Entity.User.admin_uri()
  @task_path Path.expand("../../../lib/mix/tasks/ezagent.socialware.check.ex", __DIR__)

  setup do
    :ok = DefinitionRegistry.seed_builtin_definitions()
    Mix.Task.reenable("ezagent.socialware.check")
    :ok
  end

  test "gate checks a third published definition instead of narrowing to hardcoded builtins" do
    name = "t8-check-third-#{System.unique_integer([:positive])}"

    {:ok, definition} =
      Definition.new(%{
        name: name,
        roles: [
          %{
            role_name: "broken",
            fill: :agent,
            recipe: "missing-recipe-#{name}",
            flavor: "curl"
          }
        ]
      })

    {:ok, _object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace_uri,
        caller_workspace_uri: @workspace_uri,
        actor_uri: @actor_uri
      )

    output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/socialware conformance FAILED/, fn ->
          Mix.Task.rerun("ezagent.socialware.check", [])
        end
      end)

    assert output =~ name
    assert output =~ "agent_recipes_resolve"
  end

  test "enumeration path has no function_exported? probe or hardcoded socialware-name fallback" do
    source = File.read!(@task_path)

    refute source =~ "function_exported?(DefinitionRegistry, :list"
    refute source =~ ~s(["chat", "socialware"])
  end

  # Contract-level regression proof for ci.fast MIX_ENV propagation.
  #
  # ci.fast runs via preferred_envs (Mix.env() = :test). run_socialware_check/1
  # (in mix.exs) spawns a child `mix` process. When the OS has no MIX_ENV set,
  # a naive child falls back to :dev, and config/runtime.exs demands
  # EZAGENT_PROVIDER_AUTH_* keys that are absent in CI/dev machines.
  #
  # The fix in mix.exs: run_socialware_check/1 explicitly passes the parent
  # Mix.env() as MIX_ENV via System.cmd's env: option.
  #
  # NOTE: This test verifies the CONTRACT (child without MIX_ENV → :dev crash),
  # not the implementation. It does not exercise run_socialware_check/1 directly
  # (that function is private in mix.exs and unreachable from ExUnit). The
  # implementation regression lock is the run_socialware_check/1 code itself,
  # manually verified by running `env -u MIX_ENV mix ci.fast`.
  test "child mix without explicit MIX_ENV falls back to :dev and fails on missing auth keys" do
    env_no_mix = System.get_env() |> Map.delete("MIX_ENV") |> Map.to_list()

    {output, status} =
      System.cmd("mix", ["ezagent.socialware.check"],
        env: env_no_mix,
        stderr_to_stdout: true
      )

    assert status != 0,
           "Without explicit MIX_ENV, child mix MUST fail on :dev fallback (requires auth keys). " <>
             "If this assertion fails, the :dev config no longer requires provider auth keys " <>
             "and run_socialware_check/1's explicit MIX_ENV propagation may be unnecessary.\n" <>
             "output:\n#{output}"
  end
end
