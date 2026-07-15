Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.ToolchainVersionTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Keeps every executable toolchain entry on the supported Elixir 1.19 /
  Erlang/OTP 28 line.

  The umbrella root, child applications, plugin fixtures, local mise config,
  CI, Docker images, and seeded operator scripts all participate in the same
  compatibility contract. This source-level gate prevents a newly added app
  or copied script from silently restoring an older runtime requirement.
  """

  defp umbrella_root do
    case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
      {top, 0} -> String.trim(top)
      _ -> Path.expand("../../../..", __DIR__)
    end
  end

  test "every Mix project requires Elixir 1.19" do
    root = umbrella_root()

    mix_files =
      [Path.join(root, "mix.exs") | Path.wildcard(Path.join(root, "apps/**/mix.exs"))]
      |> Enum.uniq()
      |> Enum.sort()

    drift =
      Enum.reject(mix_files, fn path ->
        File.read!(path) =~ ~r/elixir:\s*"~> 1\.19"/
      end)

    assert drift == [],
           "Mix projects outside the Elixir 1.19 compatibility line:\n" <>
             Enum.map_join(drift, "\n", &Path.relative_to(&1, root))
  end

  test "runtime carriers stay on Elixir 1.19 and OTP 28" do
    root = umbrella_root()

    expectations = [
      {".tool-versions", ~r/^elixir 1\.19\.\d+-otp-28$/m},
      {".tool-versions", ~r/^erlang 28\.\d+(?:\.\d+)*$/m},
      {".github/workflows/ci.yml", ~r/elixir-version:\s*"1\.19"/},
      {".github/workflows/ci.yml", ~r/otp-version:\s*"28"/},
      {"docker/Dockerfile.ci", ~r/^FROM hexpm\/elixir:1\.19\.\d+-erlang-28\./m},
      {"docker/Dockerfile.dev", ~r/^FROM hexpm\/elixir:1\.19\.\d+-erlang-28\./m},
      {
        ".claude/skills/kanban-assistant/scripts/kanban-cli.sh",
        ~r/mise exec elixir@1\.19\.\d+-otp-28 erlang@28\./
      },
      {
        "apps/ezagent_web/priv/skills_seed/kanban-assistant/scripts/kanban-cli.sh",
        ~r/mise exec elixir@1\.19\.\d+-otp-28 erlang@28\./
      }
    ]

    drift =
      for {relative_path, pattern} <- expectations,
          content = File.read!(Path.join(root, relative_path)),
          not (content =~ pattern),
          do: "#{relative_path} does not match #{inspect(pattern)}"

    assert drift == [],
           "Runtime toolchain carriers drifted from Elixir 1.19 / OTP 28:\n" <>
             Enum.join(drift, "\n")
  end
end
