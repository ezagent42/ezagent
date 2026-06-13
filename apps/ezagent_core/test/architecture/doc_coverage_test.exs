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

  describe "denominator covers all public API forms (codex 2026-06-14)" do
    test "undocumented defdelegate / defmacro / defguard are counted, not just def" do
      source = """
      defmodule Sample do
        def plain_def(a), do: a
        defdelegate delegated(a), to: Other
        defmacro a_macro(a), do: a
        defguard is_thing(a) when is_atom(a)
      end
      """

      offenders = Mix.Tasks.Ezagent.Doc.Scan.scan_source(source)

      assert {:plain_def, 1} in offenders
      assert {:delegated, 1} in offenders,
             "a public defdelegate without @doc must count toward the ratchet"
      assert {:a_macro, 1} in offenders,
             "a public defmacro without @doc must count toward the ratchet"
      assert {:is_thing, 1} in offenders,
             "a public defguard without @doc must count toward the ratchet"
    end

    test "documented / @doc false / private forms are NOT counted" do
      source = """
      defmodule Sample do
        @doc "why this delegate exists"
        defdelegate documented(a), to: Other

        @doc false
        defmacro internal_macro(a), do: a

        defp private_fn(a), do: a
        defmacrop private_macro(a), do: a
        defguardp is_private(a) when is_atom(a)
      end
      """

      offenders = Mix.Tasks.Ezagent.Doc.Scan.scan_source(source)

      assert offenders == [],
             "documented, @doc false, and private forms must not count; got #{inspect(offenders)}"
    end
  end
end
