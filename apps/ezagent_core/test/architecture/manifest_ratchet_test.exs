Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.ManifestRatchetTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "all manifest counters are implemented by a baseline scanner" do
    # The shared baseline manifest is fed by two source-tree scanners:
    # `ezagent.arch.scan` (architecture fitness) and `ezagent.doc.scan`
    # (documentation-coverage, 2026-06-13). Every manifest key must be measured
    # by one of them.
    measured =
      (Mix.Tasks.Ezagent.Arch.Scan.measure() ++ Mix.Tasks.Ezagent.Doc.Scan.measure())
      |> Map.new()

    for key <- Map.keys(manifest()) do
      assert Map.has_key?(measured, key), "missing scanner counter #{inspect(key)}"
    end
  end

  test "manifest cap raises against origin/main require # arch-cap-bump annotation" do
    for key <- Map.keys(manifest()) do
      assert_manifest_cap_raise_is_annotated(key)
    end
  end
end
