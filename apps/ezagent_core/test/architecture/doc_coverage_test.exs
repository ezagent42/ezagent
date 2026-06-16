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

  test "no new dynamically-named public def heads beyond baseline (enforced)" do
    assert_doc_at_or_below(:dynamic_public_def_heads)
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

    test "undocumented public defs inside a module-level for comprehension are counted" do
      source = """
      defmodule Sample do
        for _ <- [1, 2, 3] do
          def in_for(a), do: a
        end
      end
      """

      assert {:in_for, 1} in Mix.Tasks.Ezagent.Doc.Scan.scan_source(source),
             "a public def generated inside a module-level `for` must be counted"
    end

    test "a documented branch does NOT mask an undocumented same-name def in a sibling branch" do
      # Order-independent: whichever branch is undocumented, the conservative
      # cross-branch merge counts the function (codex 2026-06-14).
      doc_first = """
      defmodule Sample do
        if Mix.env() == :prod do
          @doc "prod variant"
          def env_api(a), do: a
        else
          def env_api(a), do: a
        end
      end
      """

      doc_last = """
      defmodule Sample do
        if Mix.env() == :prod do
          def env_api(a), do: a
        else
          @doc "test variant"
          def env_api(a), do: a
        end
      end
      """

      assert {:env_api, 1} in Mix.Tasks.Ezagent.Doc.Scan.scan_source(doc_first),
             "an undocumented else-branch must count regardless of branch order"

      assert {:env_api, 1} in Mix.Tasks.Ezagent.Doc.Scan.scan_source(doc_last),
             "an undocumented if-branch must count regardless of branch order"
    end

    test "normal multi-clause def with @doc on the first clause is documented" do
      source = """
      defmodule Sample do
        @doc "covers all clauses"
        def foo(1), do: :a
        def foo(_), do: :b
      end
      """

      assert Mix.Tasks.Ezagent.Doc.Scan.scan_source(source) == [],
             "the @doc on the first clause documents the whole function"
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

    test "dynamically-named public defs are surfaced (not silently dropped)" do
      # A `def unquote(name)` head has no static {name, arity} — it cannot be a
      # counter entry, but it MUST be surfaced so it is not a silent bypass
      # (codex 2026-06-14). Holds for a module-level `for` (no macro backstop)
      # and a quoted generator alike.
      for_source = """
      defmodule Sample do
        for name <- [:foo, :bar] do
          def unquote(name)(a), do: a
        end
      end
      """

      quote_source = """
      defmodule Sample do
        defmacro emit(name) do
          quote do
            def unquote(name)(a), do: a
          end
        end
      end
      """

      # One `def unquote(name)` node in SOURCE (the comprehension generates many
      # at compile time, but the scanner sees the single source form).
      assert length(Mix.Tasks.Ezagent.Doc.Scan.dynamic_public_defs(for_source)) == 1,
             "the `def unquote(name)` head in the for must be surfaced"

      assert length(Mix.Tasks.Ezagent.Doc.Scan.dynamic_public_defs(quote_source)) == 1

      # They are surfaced, not counted in the denominator (no static {name,arity}).
      assert Mix.Tasks.Ezagent.Doc.Scan.scan_source(for_source) == []
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

    test "@doc is consumed by @callback/@type and does NOT leak onto a later def" do
      # @doc before a doc-consuming attribute documents THAT attribute, not the
      # next def — preserving it would falsely mark the def documented
      # (codex 2026-06-14, a false-negative).
      callback_source = """
      defmodule Sample do
        @doc "documents the callback, not the def below"
        @callback cb(term()) :: term()
        def undocumented_after_callback(a), do: a
      end
      """

      type_source = """
      defmodule Sample do
        @typedoc "documents the type"
        @type t :: term()
        def undocumented_after_type(a), do: a
      end
      """

      assert {:undocumented_after_callback, 1} in Mix.Tasks.Ezagent.Doc.Scan.scan_source(
               callback_source
             ),
             "a def after a documented @callback must still count as undocumented"

      assert {:undocumented_after_type, 1} in Mix.Tasks.Ezagent.Doc.Scan.scan_source(type_source),
             "a def after a @typedoc'd @type must still count as undocumented"
    end

    test "@doc is preserved across def-adjacent metadata (@spec/@deprecated)" do
      source = """
      defmodule Sample do
        @doc "real doc"
        @spec ok(term()) :: term()
        def ok(a), do: a

        @doc "another"
        @deprecated "use ok/1"
        def deprecated_ok(a), do: a
      end
      """

      assert Mix.Tasks.Ezagent.Doc.Scan.scan_source(source) == [],
             "a @doc must still attach to its def across @spec/@deprecated"
    end

    test "a default-arg public def is ONE documentation obligation, not one per arity" do
      # `def foo(a \\ 1, b \\ 2)` exports foo/0..2 at the BEAM level but is one
      # @doc'd function (ExDoc shows one entry). The gate measures documentation
      # obligations, so it counts once (codex 2026-06-14 — decided NOT to expand
      # into per-arity entries, which would over-count one @doc).
      undocumented = """
      defmodule Sample do
        def foo(a \\\\ 1, b \\\\ 2), do: {a, b}
      end
      """

      documented = """
      defmodule Sample do
        @doc "one doc covers foo/0, foo/1, foo/2"
        def foo(a \\\\ 1, b \\\\ 2), do: {a, b}
      end
      """

      offenders = Mix.Tasks.Ezagent.Doc.Scan.scan_source(undocumented)
      assert offenders == [{:foo, 2}], "counted once at max arity, got #{inspect(offenders)}"

      assert Mix.Tasks.Ezagent.Doc.Scan.scan_source(documented) == [],
             "one @doc documents all default-arg arities"
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
