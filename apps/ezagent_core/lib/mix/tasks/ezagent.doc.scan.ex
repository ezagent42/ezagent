defmodule Mix.Tasks.Ezagent.Doc.Scan do
  @shortdoc "Scan documentation-coverage fitness-function counters"

  @moduledoc """
  > **Documentation-coverage gate (2026-06-13, Allen).** A source-tree
  > scan in the same family as `mix ezagent.arch.scan` /
  > `mix ezagent.check_invariants`: it runs without the runtime BEAM and
  > reuses the `arch_baseline_manifest.exs` ratchet + `# arch-cap-bump:`
  > convention.

  Enforces that documentation coverage across `apps/*/lib` does not
  REGRESS — no NEW undocumented public modules / public functions beyond
  the calibrated baseline. It is intentionally a ratchet (cap = current
  count), not a day-one red build; the comment-improvement campaign
  ratchets the caps DOWN over time. See
  `docs/notes/doc-coverage-audit.md`.

  ## Counters (in `test/architecture/arch_baseline_manifest.exs`)

  - `undocumented_public_modules` — `defmodule`s under `apps/*/lib`
    (excluding test files + this scanner) with NO `@moduledoc` (neither a
    real one nor an explicit `@moduledoc false`).
  - `undocumented_public_defs` — distinct `{name, arity}` public
    API-creating forms (`def`, `defmacro`, `defdelegate`, `defguard` —
    NOT their `defp`/`defmacrop`/`defguardp` siblings) with NO `@doc`
    (real or `@doc false`), EXCLUDING `@impl` callbacks (framework contract
    obligations — mirrors how the arch gate exempts behaviour callbacks) and
    a small justified allowlist (`@doc_def_allowlist`). `defdelegate` /
    `defmacro` are counted because public API in this repo is not limited to
    raw `def` (a facade's delegates + the Kind/Behavior DSL macros are public
    surface that must be documented too).

  An explicit `@moduledoc false` / `@doc false` COUNTS AS DOCUMENTED — the
  author made a deliberate "this is internal, no prose" decision, which is
  exactly the escape hatch the gate wants (vs. silently omitting it).

  ## Macro-generated public API (quote blocks)

  `quote` blocks ARE scanned. A STATICALLY-named public def emitted from a quote
  block (e.g. the `kinds/0` / `behaviors/0` defaults injected by
  `Ezagent.Plugin.__using__/1`) is real public API, written once in source, so
  it is counted here — once, not per call-site. (Skipping quotes would let a new
  quoted public def under an already-documented generator grow the API surface
  without moving the counter.) A DYNAMICALLY-named head (`def unquote(n)(...)`)
  has no static `{name, arity}`, so it is skipped; for those the
  documentation obligation falls back to the GENERATING macro, which is itself a
  counted `defmacro` / `__using__`.

  ## Analysis

  AST-based (`Code.string_to_quoted` → `Macro.prewalk`), not line/regex
  heuristics, so nested modules, multi-clause defs, and the association of
  a `@doc`/`@impl`/`@moduledoc` attribute to the form it precedes are
  exact. `@impl` is tracked per def head and a def is exempt if ANY of its
  clauses is preceded by `@impl`.

  ## WARN-only heuristic (never fails)

  Public `def`s WITH a `@doc` whose doc text looks like it merely restates
  the code — doc shorter than the signature, or the doc's first sentence is
  just the function name humanized — are printed as a WARN. This is advisory
  for the improvement campaign; it does NOT affect PASS/FAIL.

  ## Suppression

  Cap raises must carry `# arch-cap-bump: <reason>` on the manifest line
  (checked by `EzagentCore.Architecture.ManifestRatchetTest`).
  """
  use Mix.Task

  @scanner_path "apps/ezagent_core/lib/mix/tasks/ezagent.doc.scan.ex"
  @manifest_path "apps/ezagent_core/test/architecture/arch_baseline_manifest.exs"

  # A small justified allowlist of `{name, arity}` public defs that never need
  # a `@doc`: the conventional `child_spec/1` / `start_link/1` OTP entry points
  # are mechanically-shaped boilerplate (the existing arch gate treats them the
  # same way in `@dup_always_exempt`). Empty by default beyond these — grow only
  # with a comment justifying each entry.
  @doc_def_allowlist MapSet.new([{:child_spec, 1}, {:start_link, 0}, {:start_link, 1}])

  # The public-API-creating top-level forms the gate's denominator must cover.
  # `def` alone undercounts: this codebase exposes public API via `defdelegate`
  # (e.g. the `EzagentDomainInstanceMessage` facade) and `defmacro` / `defguard`
  # (DSL like `Ezagent.Kind.attach/2`, `Ezagent.Behavior.action/2`). Counting
  # only `def` would let a branch add an undocumented delegate/macro/guard
  # without tripping the ratchet (codex 2026-06-14). Their private siblings
  # break @doc/@impl adjacency exactly like `defp`.
  @public_def_forms [:def, :defmacro, :defdelegate, :defguard]
  @private_def_forms [:defp, :defmacrop, :defguardp]

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("ezagent.doc.scan — documentation-coverage fitness functions")

    manifest = manifest()

    results =
      measure()
      |> Enum.map(fn {name, count} ->
        cap = Map.fetch!(manifest, name)
        status = if count <= cap, do: "PASS", else: "FAIL"
        {status, name, count, cap}
      end)

    Enum.each(results, fn {status, name, count, cap} ->
      Mix.shell().info("  #{status} #{name}: count=#{count} cap=#{cap}")
    end)

    print_restates_warnings()

    failures = Enum.reject(results, fn {status, _name, _count, _cap} -> status == "PASS" end)

    if failures == [] do
      :ok
    else
      Mix.raise("ezagent.doc.scan: #{length(failures)} documentation counter(s) above cap")
    end
  end

  @doc false
  def count(name) when is_atom(name) do
    measure()
    |> Map.new()
    |> Map.fetch!(name)
  end

  @doc false
  def measure do
    modules = all_modules()

    [
      undocumented_public_modules: Enum.count(modules, &(&1.moduledoc == :none)),
      undocumented_public_defs:
        modules
        |> Enum.flat_map(& &1.public_defs)
        |> Enum.count(&undocumented_def?/1)
    ]
  end

  @doc false
  # The offender lists, for the WARN heuristic + ad-hoc operator inspection.
  def offenders do
    modules = all_modules()

    %{
      modules:
        modules
        |> Enum.filter(&(&1.moduledoc == :none))
        |> Enum.map(&{&1.file, &1.name}),
      defs:
        modules
        |> Enum.flat_map(fn m ->
          m.public_defs
          |> Enum.filter(&undocumented_def?/1)
          |> Enum.map(&{m.file, m.name, &1.name, &1.arity})
        end)
    }
  end

  @doc false
  # Analyze an in-memory source string (not a file on disk) and return the
  # `{name, arity}` list of UNDOCUMENTED public API forms in it. Exists so the
  # gate's denominator (def/defmacro/defdelegate/defguard coverage + the @doc /
  # @impl / allowlist exemptions) is unit-testable with fixtures, independent of
  # the real source tree the ratchet measures.
  def scan_source(source) when is_binary(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        ast
        |> modules("<memory>")
        |> Enum.flat_map(fn m ->
          m.public_defs
          |> Enum.filter(&undocumented_def?/1)
          |> Enum.map(&{&1.name, &1.arity})
        end)

      {:error, _} ->
        []
    end
  end

  defp undocumented_def?(d) do
    d.doc == :none and not d.impl and
      not MapSet.member?(@doc_def_allowlist, {d.name, d.arity})
  end

  # ── WARN heuristic: docs that look like they restate the signature ──

  defp print_restates_warnings do
    suspects = restates_suspects()

    if suspects != [] do
      Mix.shell().info(
        "\n  WARN (advisory, non-failing): #{length(suspects)} @doc(s) may merely restate the signature:"
      )

      suspects
      |> Enum.take(40)
      |> Enum.each(fn {file, mod, name, arity} ->
        Mix.shell().info("    - #{mod}.#{name}/#{arity}  (#{file})")
      end)

      if length(suspects) > 40 do
        Mix.shell().info("    ... and #{length(suspects) - 40} more")
      end
    end
  end

  @doc false
  def restates_suspects do
    all_modules()
    |> Enum.flat_map(fn m ->
      m.public_defs
      |> Enum.filter(&restates_code?/1)
      |> Enum.map(&{m.file, m.name, &1.name, &1.arity})
    end)
  end

  # Low-false-positive: only flag a REAL @doc (not :none / false) whose text is
  # so short it cannot carry rationale — shorter than the rendered signature, OR
  # its first line is just the humanized function name. We are conservative on
  # purpose (WARN, not fail), so we only flag the clearest restates.
  defp restates_code?(%{doc_text: text} = d) when is_binary(text) do
    sig = "#{d.name}/#{d.arity}"
    first_line = text |> String.split("\n", parts: 2) |> List.first() |> String.trim()
    normalized_name = d.name |> Atom.to_string() |> String.replace("_", " ")

    String.length(text) < String.length(sig) or
      String.downcase(first_line) == normalized_name or
      String.downcase(first_line) == normalized_name <> "."
  end

  defp restates_code?(_), do: false

  # ── shared AST scan ──

  defp all_modules do
    lib_files()
    |> Enum.flat_map(&analyze_file/1)
  end

  defp manifest do
    @manifest_path
    |> Code.eval_file()
    |> elem(0)
  end

  defp repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end

  defp lib_files do
    repo_root()
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&relative/1)
    |> Enum.reject(&excluded_file?/1)
    |> Enum.sort()
  end

  defp excluded_file?(path) do
    path == @scanner_path or String.contains?(path, "/test/") or
      String.ends_with?(path, "_test.ex")
  end

  defp relative(path), do: Path.relative_to(path, repo_root())
  defp absolute(path), do: Path.join(repo_root(), path)
  defp read!(file), do: file |> absolute() |> File.read!()

  defp analyze_file(file) do
    case Code.string_to_quoted(read!(file)) do
      {:ok, ast} -> modules(ast, file)
      {:error, _} -> []
    end
  end

  # Each `defmodule` → %{file, name, moduledoc, public_defs}.
  defp modules(ast, file) do
    Macro.prewalk(ast, [], fn node, acc ->
      case node do
        {:defmodule, _meta, [name_ast, [{:do, body} | _]]} ->
          forms = top_forms(body)

          entry = %{
            file: file,
            name: mod_name(name_ast),
            moduledoc: moduledoc_status(forms),
            public_defs: public_defs(forms)
          }

          {node, [entry | acc]}

        _ ->
          {node, acc}
      end
    end)
    |> elem(1)
  end

  defp mod_name({:__aliases__, _, mods}), do: Enum.map_join(mods, ".", &Atom.to_string/1)
  defp mod_name(_), do: "?"

  defp top_forms({:__block__, _meta, forms}) when is_list(forms), do: forms
  defp top_forms(form), do: [form]

  # `:real` | `false` | `:none` — first @moduledoc wins.
  defp moduledoc_status(forms) do
    Enum.reduce_while(forms, :none, fn
      {:@, _, [{:moduledoc, _, [false]}]}, _ -> {:halt, false}
      {:@, _, [{:moduledoc, _, [_]}]}, _ -> {:halt, :real}
      _, acc -> {:cont, acc}
    end)
  end

  # Distinct {name, arity} public defs in module-body order, carrying the
  # @doc / @impl status of the FIRST clause (where the attributes sit). A later
  # clause carrying @impl upgrades the impl flag (an @impl on any clause exempts
  # the function). `doc_text` is the literal doc string when it is a plain
  # binary (for the WARN heuristic only).
  defp public_defs(forms) do
    direct = collect_defs(forms, %{})

    # Also count STATICALLY-named public defs emitted from `quote` blocks
    # (macro-generated public API — e.g. the `kinds/0`/`behaviors/0` defaults a
    # `__using__/1` injects). These live inside `defmacro`/`def` BODIES, so a
    # single prewalk over the whole module finds every quote at any depth; each
    # quote's body is run through the same `collect_defs` reducer. Counting them
    # at the source (not per call-site) closes the hole where a new quoted public
    # def under an already-documented generator would never move the counter
    # (codex 2026-06-14). Dynamically-named heads (`def unquote(n)`) yield no
    # static {name, arity} and are skipped by `fn_key/1`.
    forms
    |> collect_quoted_defs(direct)
    |> Map.values()
  end

  defp collect_quoted_defs(ast, defs) do
    {_ast, defs} =
      Macro.prewalk(ast, defs, fn
        {:quote, _meta, qargs} = node, acc when is_list(qargs) ->
          {node, scan_quote_body(qargs, acc)}

        node, acc ->
          {node, acc}
      end)

    defs
  end

  defp scan_quote_body(qargs, defs) do
    case List.last(qargs) do
      kw when is_list(kw) ->
        case Keyword.fetch(kw, :do) do
          {:ok, body} -> collect_defs(top_forms(body), defs)
          :error -> defs
        end

      _ ->
        defs
    end
  end

  # Reduce a flat list of module-body forms into a `{name, arity} => def-info`
  # map, accumulating into `defs`. Recurses into top-level compile-time
  # containers (`if`/`unless`/`case`/`cond`) because a public def nested inside
  # one is real public API — counting only DIRECT forms would let an
  # environment-/version-gated public function escape the ratchet (codex
  # 2026-06-14). `quote` blocks are deliberately NOT recursed (macro-generated
  # code, not a hand-written public def the author must document).
  defp collect_defs(forms, defs) when is_list(forms) do
    {defs, _pdoc, _ptext, _pimpl} =
      Enum.reduce(forms, {defs, :none, nil, false}, fn form, {defs, pdoc, ptext, pimpl} ->
        case form do
          {:@, _, [{:doc, _, [false]}]} ->
            {defs, false, nil, pimpl}

          {:@, _, [{:doc, _, [text]}]} ->
            {defs, :real, doc_text(text), pimpl}

          {:@, _, [{:impl, _, [impl_arg]}]} ->
            {defs, pdoc, ptext, pimpl or impl_exempts?(impl_arg)}

          {form, _, [head | _]} when form in @public_def_forms ->
            case fn_key(head) do
              nil ->
                {defs, :none, nil, false}

              key ->
                defs =
                  Map.update(
                    defs,
                    key,
                    %{name: elem(key, 0), arity: elem(key, 1), doc: pdoc, doc_text: ptext, impl: pimpl},
                    fn existing -> %{existing | impl: existing.impl or pimpl} end
                  )

                {defs, :none, nil, false}
            end

          {form, _, _} when form in @private_def_forms ->
            {defs, :none, nil, false}

          {:@, _, _} ->
            # An interleaved module attribute (@spec, @dialyzer, @typedoc, ...)
            # is normal between @doc/@impl and the def — preserve pending state.
            {defs, pdoc, ptext, pimpl}

          _ ->
            # Either a compile-time container wrapping defs (recurse into each
            # branch with its OWN @doc scope — a @doc cannot attach across the
            # wrapper) or a genuine non-def form. Either way the pending
            # @doc/@impl is cleared so it can't leak onto a later def.
            defs =
              case container_branches(form) do
                nil -> defs
                branches -> Enum.reduce(branches, defs, &collect_defs(&1, &2))
              end

            {defs, :none, nil, false}
        end
      end)

    defs
  end

  # The form-lists of a top-level compile-time container that can legally hold
  # `def`s, or `nil` for anything else (including `quote`, which we skip). Each
  # branch body is normalized through `top_forms/1` so a single-def branch and a
  # multi-def `__block__` branch are handled uniformly.
  defp container_branches({:if, _, [_cond, kw]}), do: keyword_branches(kw)
  defp container_branches({:unless, _, [_cond, kw]}), do: keyword_branches(kw)
  defp container_branches({:case, _, [_subj, [{:do, clauses}]]}), do: clause_branches(clauses)
  defp container_branches({:cond, _, [[{:do, clauses}]]}), do: clause_branches(clauses)
  # `quote` is handled separately (see `collect_quoted_defs/2`) via a whole-module
  # prewalk, because quote blocks live inside def/defmacro bodies, not at the
  # module-body level this function scans.
  defp container_branches(_), do: nil

  defp keyword_branches(kw) when is_list(kw) do
    for {k, body} <- kw, k in [:do, :else], do: top_forms(body)
  end

  defp keyword_branches(_), do: nil

  defp clause_branches(clauses) when is_list(clauses) do
    for {:->, _, [_pattern, body]} <- clauses, do: top_forms(body)
  end

  defp clause_branches(_), do: nil

  # `@impl` exempts a public def as a behaviour-callback obligation ONLY for
  # `@impl true` or `@impl SomeBehaviour` (a module alias). `@impl false`
  # explicitly means "this is NOT a callback", so it must NOT exempt the def
  # from the doc ratchet (codex 2026-06-14).
  defp impl_exempts?(true), do: true
  defp impl_exempts?({:__aliases__, _, _}), do: true
  defp impl_exempts?(_), do: false

  defp doc_text(text) when is_binary(text), do: text
  defp doc_text(_), do: nil

  defp fn_key({:when, _meta, [head | _]}), do: fn_key(head)
  defp fn_key({name, _meta, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp fn_key({name, _meta, nil}) when is_atom(name), do: {name, 0}
  defp fn_key(_), do: nil
end
