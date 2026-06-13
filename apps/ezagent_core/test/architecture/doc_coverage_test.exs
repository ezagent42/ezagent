Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.DocCoverageTest do
  @moduledoc """
  Documentation-coverage enforcement gate (2026-06-13, Allen).

  A RATCHET (calibrated GREEN at the current main count, like the arch gates):
  no NEW undocumented public modules / public functions beyond the baseline in
  `arch_baseline_manifest.exs`. The comment-improvement campaign ratchets the
  caps DOWN. Backed by `Mix.Tasks.Ezagent.Doc.Scan`; see
  `docs/notes/doc-coverage-audit.md`.
  """
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  test "no new undocumented public modules beyond baseline" do
    assert_doc_at_or_below(:undocumented_public_modules)
  end

  test "no new undocumented public functions beyond baseline" do
    assert_doc_at_or_below(:undocumented_public_defs)
  end

  test "doc.scan counters are wired into the shared manifest" do
    manifest = manifest()

    for {key, _count} <- Mix.Tasks.Ezagent.Doc.Scan.measure() do
      assert Map.has_key?(manifest, key),
             "doc.scan counter #{inspect(key)} missing from arch_baseline_manifest.exs"
    end
  end
end
