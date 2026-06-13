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

    test "undocumented public defs inside top-level if/unless/case/cond are counted" do
      source = """
      defmodule Sample do
        if Mix.env() == :prod do
          def in_if(a), do: a
        else
          def in_else(a), do: a
        end

        unless Mix.env() == :test do
          def in_unless(a), do: a
        end

        case System.otp_release() do
          "26" -> def in_case(a), do: a
          _ -> :ok
        end

        cond do
          true -> def in_cond(a), do: a
        end
      end
      """

      offenders = Mix.Tasks.Ezagent.Doc.Scan.scan_source(source)

      for fn_name <- [:in_if, :in_else, :in_unless, :in_case, :in_cond] do
        assert {fn_name, 1} in offenders,
               "undocumented public def #{fn_name}/1 nested in a compile-time container must count; got #{inspect(offenders)}"
      end
    end

    test "a documented public def inside a compile-time container is NOT counted" do
      source = """
      defmodule Sample do
        if Mix.env() == :prod do
          @doc "why this prod-only entry exists"
          def documented_in_if(a), do: a
        end
      end
      """

      assert Mix.Tasks.Ezagent.Doc.Scan.scan_source(source) == []
    end

    test "statically-named quoted public defs ARE counted; dynamically-named are not" do
      # Policy: a statically-named public def in a quote block is real public API
      # (written once in source) and is counted — so adding one under an
      # already-documented generator still moves the counter (codex 2026-06-14).
      # A `def unquote(n)` head has no static {name, arity} and is skipped; the
      # counted generating macro is its doc backstop.
      source = """
      defmodule Sample do
        @doc "documented generator"
        defmacro emit_api(name) do
          quote do
            def static_generated(a), do: a
            def unquote(name)(a), do: a
          end
        end
      end
      """

      offenders = Mix.Tasks.Ezagent.Doc.Scan.scan_source(source)

      assert {:static_generated, 1} in offenders,
             "an undocumented statically-named quoted def must be counted"

      refute Enum.any?(offenders, fn {n, _a} -> n == :unquote end),
             "a dynamically-named `def unquote(n)` head has no static arity and must be skipped"
    end

    test "@impl false does NOT exempt a public def (only @impl true / @impl Behaviour)" do
      source = """
      defmodule Sample do
        @impl false
        def not_a_callback(a), do: a

        @impl true
        def real_callback(a), do: a

        @impl SomeBehaviour
        def aliased_callback(a), do: a
      end
      """

      offenders = Mix.Tasks.Ezagent.Doc.Scan.scan_source(source)

      assert {:not_a_callback, 1} in offenders,
             "@impl false is not a callback obligation — the def must still be counted"

      refute {:real_callback, 1} in offenders, "@impl true exempts"
      refute {:aliased_callback, 1} in offenders, "@impl SomeBehaviour exempts"
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
