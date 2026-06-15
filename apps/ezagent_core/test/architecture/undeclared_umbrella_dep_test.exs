defmodule Ezagent.Architecture.UndeclaredUmbrellaDepTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Arch-fitness invariant: **a lib/ HARD reference to a module DEFINED in another
  umbrella app must be backed by a declared prod `in_umbrella` dependency** (#57).

  ## The defect class this guards

  cc's `mix.exs` declared `ezagent_domain_session` as `only: :test` while its
  PR-8 transport (`mcp_*`, `live_join_registry`) called
  `Ezagent.Session.SessionManager` / `Ezagent.Entity.Session.*` directly in
  `lib/`. That is a latent layering hazard: the prod dep is REAL but undeclared,
  and it escapes a compile warning only by alphabetical umbrella build order
  (the defining app happens to compile first, so its beam exists when the
  referencing app compiles). Rename an app, reorder the build, or build the app
  in isolation and it becomes a real `module ... is not available` warning.
  (#796 declared the cc → session dep; this test stops the class from recurring.)

  ## What counts as a HARD reference

  A reference that creates a compile/export dependency on the target module —
  i.e. one that produces a "module not available" warning if the module is
  absent at compile time:

    * remote call          `Mod.fun(...)`
    * struct expansion     `%Mod{}`
    * `@behaviour Mod` / `@behavior Mod`
    * `use` / `import` / `require Mod`

  BARE-ATOM value references are EXCLUDED — they create no compile dependency
  and no warning. This is the umbrella's deliberate inversion-of-control
  backbone: `kind: Ezagent.Entity.Agent` in a flavor map, `[Mod, ...]` in a
  behaviour/Kind registry, `Module.concat(...)`. core REFERENCES domain modules
  this way constantly (it cannot compile-dep on a domain — that would be a
  cycle), so a bare-atom-inclusive scan would false-positive the entire IoC
  layer (~23 edges); a hard-ref scan finds only the real undeclared deps.

  ## `Code.ensure_loaded?` does NOT exempt a direct call

  `if Code.ensure_loaded?(Mod), do: Mod.fun(...)` still hard-references `Mod` —
  the `Mod.fun(...)` call compiles to the same export dependency and emits the
  same "module not available" warning when `Mod`'s app is off the compile path.
  The runtime guard prevents the *call*, not the *compile-time dependency*. So a
  guarded direct call is NOT exempted here; declare the dep (the module is on the
  compile path) or reach the peer indirectly via `apply/3` / a module value (a
  bare atom, which is not a hard reference and is therefore never flagged).

  ## Limitation (matches `ImSessionAgentAcyclicTest`)

  References are collected from the AST as written, WITHOUT alias resolution, so
  only FULLY-QUALIFIED hard refs are detected (an `alias Ezagent.Domain.Pty`
  then `Pty.alive?()` is not). This is the same trade-off the sibling acyclic
  test accepts; fully-qualified refs are the common case and exactly the shape
  that caused the cc → session and liveview defects.
  """

  @moduletag :umbrella_only

  @repo_root Path.expand("../../../..", __DIR__)

  # core is the shared base every app already compile-deps on — never an offender.
  @always_available :ezagent_core

  # Known-good cross-app HARD refs that are NOT backed by a declared dep. Should
  # stay []; an entry needs a written justification (why the dep is intentionally
  # undeclared and warning-safe).
  @allowlist []

  test "every lib/ hard-ref to another umbrella app's module is a declared prod dep" do
    index = defmodule_app_index()
    deps = prod_dep_graph()

    offenders =
      Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.ex"))
      |> Enum.flat_map(fn file ->
        app = file |> Path.relative_to(@repo_root) |> Path.split() |> Enum.at(1) |> String.to_atom()
        ast = parse(file)
        declared = Map.get(deps, app, MapSet.new())
        rel = Path.relative_to(file, @repo_root)

        hard_refs(ast)
        |> Enum.flat_map(fn mod ->
          def_app = Map.get(index, mod)

          cond do
            is_nil(def_app) -> []
            def_app == app -> []
            def_app == @always_available -> []
            MapSet.member?(declared, def_app) -> []
            true -> [{rel, app, def_app, mod}]
          end
        end)
      end)
      |> Enum.uniq()
      |> reject_allowlisted()

    assert offenders == [],
           "lib/ hard-references a module DEFINED in an umbrella app that is NOT a " <>
             "declared prod in_umbrella dep (latent 'module not available' hazard — #57). " <>
             "Declare the dep, or reach the peer via `apply/3` / a module value. Offenders:\n" <>
             format(offenders)
  end

  # ── hard-ref + ensure_loaded? collection (AST) ───────────────────────────

  defp hard_refs(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        # remote call  Mod.fun(...)
        {{:., _, [{:__aliases__, _, p}, f]}, _, _} = n, acc when is_atom(f) ->
          {n, add_mod(acc, p)}

        # struct  %Mod{}
        {:%, _, [{:__aliases__, _, p}, _]} = n, acc ->
          {n, add_mod(acc, p)}

        # @behaviour Mod / @behavior Mod
        {:@, _, [{kw, _, [{:__aliases__, _, p}]}]} = n, acc when kw in [:behaviour, :behavior] ->
          {n, add_mod(acc, p)}

        # use / import / require Mod
        {kw, _, [{:__aliases__, _, p} | _]} = n, acc when kw in [:use, :import, :require] ->
          {n, add_mod(acc, p)}

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(acc)
  end

  defp add_mod(acc, parts) do
    if is_list(parts) and Enum.all?(parts, &is_atom/1), do: [Module.concat(parts) | acc], else: acc
  end

  # ── module → defining app, and app → prod deps (mix.exs) ──────────────────

  defp defmodule_app_index do
    Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.ex"))
    |> Enum.flat_map(fn file ->
      app = file |> Path.relative_to(@repo_root) |> Path.split() |> Enum.at(1) |> String.to_atom()

      {_, mods} =
        Macro.prewalk(parse(file), [], fn
          {:defmodule, _, [{:__aliases__, _, p}, _]} = n, acc -> {n, add_mod(acc, p)}
          n, acc -> {n, acc}
        end)

      Enum.map(mods, &{&1, app})
    end)
    |> Map.new()
  end

  defp prod_dep_graph do
    Path.wildcard(Path.join(@repo_root, "apps/*/mix.exs"))
    |> Map.new(fn mix ->
      app = mix |> Path.dirname() |> Path.basename() |> String.to_atom()
      # Strip line comments first — a commented-out `{:dep, in_umbrella: true}`
      # (e.g. external_mirror's "DO NOT add ..." note) must NOT count as a
      # declared dep, or a future hard ref to it would be silently accepted.
      src = File.read!(mix) |> strip_comments()

      prod =
        Regex.scan(~r/\{:(\w+),\s*in_umbrella:\s*true([^}]*)\}/, src)
        |> Enum.flat_map(fn [_, dep, rest] ->
          if test_only?(rest), do: [], else: [String.to_atom(dep)]
        end)
        |> MapSet.new()

      {app, prod}
    end)
  end

  # Drop `#`-to-EOL line comments, but not a `#` inside a double-quoted string.
  defp strip_comments(src) do
    src |> String.split("\n") |> Enum.map_join("\n", &strip_line_comment/1)
  end

  defp strip_line_comment(line) do
    {kept, _in_str} =
      line
      |> String.to_charlist()
      |> Enum.reduce_while({[], false}, fn
        ?", {acc, in_str} -> {:cont, {[?" | acc], not in_str}}
        ?#, {acc, false} -> {:halt, {acc, false}}
        ch, {acc, in_str} -> {:cont, {[ch | acc], in_str}}
      end)

    kept |> Enum.reverse() |> List.to_string()
  end

  # `only: :test` (but not `only: [:dev, :test]`, which is available in dev too).
  defp test_only?(rest) do
    String.contains?(rest, "only:") and String.contains?(rest, ":test") and
      not String.contains?(rest, ":dev")
  end

  defp reject_allowlisted(offenders), do: Enum.reject(offenders, &(&1 in @allowlist))

  defp parse(file) do
    File.read!(file) |> Code.string_to_quoted!(warn_on_unnecessary_quotes: false, emit_warnings: false)
  rescue
    e -> flunk("AST parse failed for #{file}: #{Exception.message(e)}")
  end

  defp format(offenders) do
    offenders
    |> Enum.map(fn {rel, app, def_app, mod} ->
      "  #{rel}: #{app} -> #{def_app} via #{inspect(mod)}"
    end)
    |> Enum.uniq()
    |> Enum.join("\n")
  end
end
