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

  ## Sanctioned exception: `Code.ensure_loaded?`-guarded optional peers

  A reference guarded by `Code.ensure_loaded?(Mod)` in the same file is the
  sanctioned way to call an OPTIONAL runtime peer without taking a compile dep
  (e.g. liveview probing `Ezagent.AgentBridge.Registry` before reading a
  connected-bridge count). Such refs are excluded — the guard is the contract.

  The exclusion is FILE-SCOPED: a module probed with `Code.ensure_loaded?/1`
  anywhere in a file is treated as an optional peer throughout that file. This
  matches how the pattern is used in practice (probe once, then call within the
  same module) and keeps the check free of control-flow analysis; the trade-off
  is that a stray unguarded call in a file that probes the module elsewhere is
  not flagged.

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

  # Known-good cross-app HARD refs that are NOT backed by a declared dep and are
  # NOT ensure_loaded?-guarded. Should stay []; an entry needs a written
  # justification (why the dep is intentionally undeclared and warning-safe).
  @allowlist []

  test "every lib/ hard-ref to another umbrella app's module is a declared prod dep" do
    index = defmodule_app_index()
    deps = prod_dep_graph()

    offenders =
      Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.ex"))
      |> Enum.flat_map(fn file ->
        app = file |> Path.relative_to(@repo_root) |> Path.split() |> Enum.at(1) |> String.to_atom()
        ast = parse(file)
        guarded = ensure_loaded_modules(ast)
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
            MapSet.member?(guarded, mod) -> []
            true -> [{rel, app, def_app, mod}]
          end
        end)
      end)
      |> Enum.uniq()
      |> reject_allowlisted()

    assert offenders == [],
           "lib/ hard-references a module DEFINED in an umbrella app that is NOT a " <>
             "declared prod in_umbrella dep (latent 'module not available' hazard — #57). " <>
             "Declare the dep, or guard the call with `Code.ensure_loaded?/1`. Offenders:\n" <>
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

  defp ensure_loaded_modules(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Code]}, :ensure_loaded?]}, _, [{:__aliases__, _, p}]} = n, acc ->
          {n, add_mod(acc, p)}

        n, acc ->
          {n, acc}
      end)

    MapSet.new(acc)
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
      src = File.read!(mix)

      prod =
        Regex.scan(~r/\{:(\w+),\s*in_umbrella:\s*true([^}]*)\}/, src)
        |> Enum.flat_map(fn [_, dep, rest] ->
          if test_only?(rest), do: [], else: [String.to_atom(dep)]
        end)
        |> MapSet.new()

      {app, prod}
    end)
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
