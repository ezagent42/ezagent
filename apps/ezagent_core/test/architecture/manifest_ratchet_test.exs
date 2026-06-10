Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.ManifestRatchetTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "all manifest counters are implemented by ezagent.arch.scan" do
    measured = Mix.Tasks.Ezagent.Arch.Scan.measure() |> Map.new()

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
