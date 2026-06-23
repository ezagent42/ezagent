defmodule Ezagent.Architecture.CjkLiteralGateTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Anti-hardcoded-CJK arch gate (#91, Allen 2026-06-23).

  User-facing copy must go through the project's i18n mechanism (a `gettext/1,2`
  call against a plugin-/app-owned `Gettext` backend), NOT be baked into source
  as a Chinese string literal. A literal like
  `TurnDriver.say(uri, builder, "📦 已生成结构:…")` can never be translated and
  drifts the copy across the codebase; this gate fails the build when a Han
  ideograph appears inside a **string literal** under a scanned `lib/` tree.

  ## What it catches (and what it does NOT)

  Detection is **AST-based** (`Code.string_to_quoted!` + `Macro.prewalk`), so it
  only flags real string *literals* — including the literal segments of an
  interpolated string (`"页面 \#{title}"`). Two things are deliberately NOT
  flagged, because they are not "hardcoded user copy":

    * **comments** — never present in the AST at all; and
    * **`@moduledoc` / `@doc` / `@typedoc` / `@shortdoc` strings** — pruned
      from the walk. Documentation is allowed to be written in Chinese; this
      codebase's docs frequently are.

  The signal is Han ideographs (CJK Unified `\\x{4E00}-\\x{9FFF}` + Extension A
  `\\x{3400}-\\x{4DBF}`). Pure CJK *punctuation* used as a glyph separator
  (e.g. the `、` join in `Generator.describe_page/1`, the `・` brief bullet) is
  NOT flagged — those are typography, not translatable sentences. A future,
  additive step can widen the signal and the scanned scope.

  ## Scope (start narrow, widen later)

  Allen's #91 ask is "至少覆盖 hello 叙述串" — at least cover the hello builder
  narration. So the enforced scope is `apps/ezagent_plugin_hello/lib` for now.
  `@scanned_globs` is the single place to widen coverage (the broader ~20-file
  sweep across the umbrella is a tracked follow-up). The `scan/1` scanner itself
  is scope-agnostic, and the self-test below proves it actually detects Han, so
  the gate cannot silently rot into a no-op.
  """

  @moduletag :umbrella_only

  @repo_root Path.expand("../../../..", __DIR__)

  # The enforced scope (widen here — see moduledoc "Scope").
  @scanned_globs ["apps/ezagent_plugin_hello/lib/**/*.ex"]

  # Han ideographs: CJK Unified + Extension A. Punctuation is intentionally
  # excluded (see moduledoc).
  @han_re ~r/[\x{4E00}-\x{9FFF}\x{3400}-\x{4DBF}]/u

  # `@doc`-family attributes whose string body is documentation, not user copy.
  @doc_attrs [:moduledoc, :doc, :typedoc, :shortdoc]

  test "no hardcoded Han string literals in the scanned scope (use gettext)" do
    offenders = scan(@scanned_globs)

    assert offenders == [],
           """
           Hardcoded Chinese string literal(s) found — user-facing copy must use
           the i18n mechanism (a `gettext/1,2` call against a plugin/app-owned
           `Gettext` backend; Chinese lives in `priv/gettext/zh_CN`). See
           `EzagentPluginHello.Generator` + `EzagentPluginHello.Gettext` for the
           pattern. Offenders:
           #{format(offenders)}
           """
  end

  test "scanner actually detects Han literals (gate is not a no-op)" do
    # A code snippet with Han in: a plain literal, an interpolation literal
    # segment, a comment (must be ignored), and a @moduledoc (must be ignored).
    snippet = ~S'''
    defmodule Sample do
      @moduledoc "文档字符串 — 应被忽略"
      # 注释 — 应被忽略
      def a, do: "用户文案"
      def b(x), do: "页面 #{x} 标题"
      def c, do: "no han here"
    end
    '''

    offenders = scan_source(snippet, "sample.ex")
    snippets = Enum.map(offenders, fn {_rel, s} -> s end)

    assert "用户文案" in snippets, "plain Han literal must be detected"
    assert Enum.any?(snippets, &(&1 =~ "页面")), "interpolation Han segment must be detected"
    refute Enum.any?(snippets, &(&1 =~ "文档字符串")), "@moduledoc must be ignored"
    refute Enum.any?(snippets, &(&1 =~ "注释")), "comments must be ignored"
    refute Enum.any?(snippets, &(&1 =~ "no han here")), "non-Han literal must not be flagged"
  end

  # ── scanner ───────────────────────────────────────────────────────────────

  # [{relative_path, offending_literal}] across every file matched by `globs`.
  defp scan(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
    |> Enum.uniq()
    |> Enum.flat_map(fn file ->
      rel = Path.relative_to(file, @repo_root)
      scan_source(File.read!(file), rel)
    end)
  end

  defp scan_source(source, rel) do
    source
    |> Code.string_to_quoted!(warn_on_unnecessary_quotes: false, emit_warnings: false)
    |> han_literals()
    |> Enum.map(&{rel, &1})
  rescue
    e -> flunk("AST parse failed for #{rel}: #{Exception.message(e)}")
  end

  # Every string literal containing a Han ideograph, with @doc-family subtrees
  # pruned so documentation strings are not flagged.
  defp han_literals(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        # Prune @moduledoc/@doc/... — return a leaf so the doc string isn't walked.
        {:@, _, [{attr, _, _}]}, acc when attr in @doc_attrs ->
          {:__pruned_doc__, acc}

        bin, acc when is_binary(bin) ->
          if Regex.match?(@han_re, bin), do: {bin, [bin | acc]}, else: {bin, acc}

        node, acc ->
          {node, acc}
      end)

    acc |> Enum.reverse() |> Enum.uniq()
  end

  defp format(offenders) do
    offenders
    |> Enum.map(fn {rel, s} -> "  #{rel}: #{inspect(s)}" end)
    |> Enum.uniq()
    |> Enum.join("\n")
  end
end
