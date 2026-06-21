defmodule EzagentCore.Invariants.SessionCreateSinglePathTest do
  @moduledoc """
  Single-path invariant for operator-facing Session creation (#533 PR-5).

  The external creation interface is `Ezagent.Workspace.create_session/3`,
  which dispatches `Behavior.Workspace.:create_session`. The lower-level
  instance-message materialization code is an internal implementation detail
  and must not be called by UI, Web, CLI, plugin, or E2E setup code.
  """

  use ExUnit.Case, async: true

  @forbidden ~r/EzagentDomainInstanceMessage\.create_session\s*\(/

  @allowed_internal_paths []

  test "operator-facing create_session goes through Ezagent.Workspace.create_session/3" do
    root = Path.expand("../../../..", __DIR__)

    violations =
      root
      |> candidate_files()
      |> Enum.flat_map(&direct_refs(root, &1))
      |> Enum.reject(fn {path, _line} -> path in @allowed_internal_paths end)

    assert violations == [],
           """
           Direct `EzagentDomainInstanceMessage.create_session/3` calls bypass
           the authorized Workspace create-session interface:

             #{format_violations(violations)}

           Use `Ezagent.Workspace.create_session/3` with the real caller ctx.
           E2E setup is included because it must exercise the same interface
           users/operators rely on.
           """
  end

  defp candidate_files(root) do
    [
      "apps/*/lib/**/*.ex",
      "apps/*/test/e2e/**/*.exs",
      "apps/ezagent_core/test/e2e/**/*.exs",
      "apps/ezagent_web/test/**/*.exs"
    ]
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(root, pattern)) end)
    |> Enum.uniq()
    |> Enum.map(&Path.relative_to(&1, root))
  end

  defp direct_refs(root, rel_path) do
    root
    |> Path.join(rel_path)
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} -> Regex.match?(@forbidden, line) end)
    |> Enum.map(fn {_line, idx} -> {rel_path, idx} end)
  end

  defp format_violations([]), do: "(none)"

  defp format_violations(violations) do
    violations
    |> Enum.map(fn {path, line} -> "#{path}:#{line}" end)
    |> Enum.join("\n             ")
  end
end
