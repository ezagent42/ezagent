Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.RawPortSpawnTest do
  @moduledoc """
  Subtask B (2026-06-25) — target-zero gate: no lib code may spawn an OS process
  via raw `Port.open({:spawn_executable, …}, …)`. The sanctioned exit is
  `Ezagent.Runtime.OsProcess` (erlexec `run_link` + `{group,0}`+`:kill_group`
  subtree reaping). A bare `Port.open` only signals the DIRECT child on close,
  orphaning the `uv→python` / `codex→vendor` / `node→workers` subtree.

  The counter is AST-based (see `Mix.Tasks.Ezagent.Arch.Scan`) precisely so the
  multi-line `Port.open(\\n  {:spawn_executable, …}` form (feishu's old shape)
  cannot slip past a per-line regex.
  """
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "no raw Port.open({:spawn_executable, …}) in lib code" do
    assert_zero(:raw_port_spawn_executable)
  end
end
