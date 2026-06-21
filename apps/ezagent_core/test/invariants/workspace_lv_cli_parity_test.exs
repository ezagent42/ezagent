defmodule EzagentCore.Invariants.WorkspaceLvCliParityTest do
  @moduledoc """
  Workspace-shell retirement invariant.

  The old version grepped the retired operator UI for direct
  `Ezagent.Workspace.*` calls and required matching mix tasks. World now owns the
  operator shell, so this gate makes the retirement explicit and keeps the
  operator-facing single path check in `session_create_single_path_test`.
  """
  use ExUnit.Case, async: true

  @retired_app Path.expand("../../../ezagent_plugin_liveview", __DIR__)

  test "workspace parity no longer depends on the retired LiveView plugin" do
    refute File.dir?(@retired_app),
           "apps/ezagent_plugin_liveview must stay retired; add world or CLI coverage instead."
  end
end
