defmodule Ezagent.PluginCc.Template.CcPtyLaunchChokepointTest do
  @moduledoc """
  Regression guard for the cc PTY-launch create-chokepoint (#701, codex
  PR-3T review).

  The cc PTY launch — `Ezagent.Domain.Pty.start/2` — must only be reachable
  through the credential-grant gate. The chokepoint is the call chain in
  `cc_agent/spawn.ex`:

      Domain.Pty.start  ⟵ start_pty/2 ⟵ ensure_pty_server/4 ⟵ {spawn_for_local_pty/3, respawn_subprocess/2}

  where `spawn_for_local_pty/3` (fresh spawn) and `respawn_subprocess/2`
  (cold restart) are the ONLY public entrypoints and each runs the grant
  gate before launching.

  This guard is **AST-based** over ALL cc plugin lib files, tracking
  function identity as `{name, arity}` (codex #701 review rounds 1-5). It
  recognizes the launch / chain references whether written as a qualified
  call (`Ezagent.Domain.Pty.start(...)`), an aliased call (incl
  `alias ..Pty, as: X`), a bare local call, or a function capture
  (`&start_pty/2`, `&Pty.start/2`). So a new raw launch site, a 2nd launch
  call, the helpers made public, a public wrapper (by call or capture),
  an alias rename, OR a same-name different-arity overload that reaches
  the private chain all fail.

  Inherently out of scope for a STATIC guard (codex-agreed): runtime
  dispatch obfuscation — `apply/3`, `Module.concat` + apply, macro-
  generated calls, `Code.eval_*`. Those are not idiomatic accidental
  regressions; the production path is spelled safely and the build-only
  SpawnPlan + private gated chain is the structural guarantee.
  """
  use ExUnit.Case, async: true

  @lib_root Path.join([__DIR__, "..", "..", "..", "lib"]) |> Path.expand()
  @allowed_relpath "ezagent/template/cc_agent/spawn.ex"

  # Sanctioned chain by {name, arity}: the EXACT allowed callers at each hop.
  @launcher_id {:start_pty, 2}
  @allowed_callers %{
    {:start_pty, 2} => MapSet.new([{:ensure_pty_server, 4}]),
    {:ensure_pty_server, 4} => MapSet.new([{:spawn_for_local_pty, 3}, {:respawn_subprocess, 2}])
  }

  # Per-file %{{name, arity} => %{private, locals (MapSet of referenced
  # local {name, arity} — calls AND captures), pty? (references
  # Domain.Pty.start by call/capture, qualified/aliased/as:-renamed)}}.
  defp analyze(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()
    fn_map(ast, pty_alias_names(ast))
  end

  defp pty_alias_names(ast) do
    {_, names} =
      Macro.prewalk(ast, MapSet.new([:Pty]), fn
        {:alias, _, [{:__aliases__, _, [:Ezagent, :Domain, :Pty]}, opts]} = node, acc
        when is_list(opts) ->
          case opts[:as] do
            {:__aliases__, _, [as_name]} -> {node, MapSet.put(acc, as_name)}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    names
  end

  test "Domain.Pty.start/2 is reachable only inside spawn.ex's private start_pty/2" do
    launch_sites =
      Path.wildcard(Path.join(@lib_root, "**/*.ex"))
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, @lib_root)
        for {id, info} <- analyze(path), info.pty?, do: {rel, id}
      end)
      |> Enum.sort()

    assert launch_sites == [{@allowed_relpath, @launcher_id}],
           "Ezagent.Domain.Pty.start/2 must be referenced (call or capture) only by " <>
             "start_pty/2 in #{@allowed_relpath} — found: #{inspect(launch_sites)}. " <>
             "Route every launch through CcAgent.Spawn's grant-gated private chain."
  end

  test "the spawn.ex launch chain is reachable only via the grant-gated entrypoints" do
    fns = analyze(Path.join(@lib_root, @allowed_relpath))

    for {callee_id, allowed} <- @allowed_callers do
      actual =
        for {id, info} <- fns, MapSet.member?(info.locals, callee_id), into: MapSet.new(), do: id

      assert MapSet.equal?(actual, allowed),
             "#{fmt(callee_id)} may be reached only by #{fmt_set(allowed)} (the grant-gated " <>
               "chain) — actual: #{fmt_set(actual)}. A new caller/capturer/overload is a " <>
               "#701-class bypass."
    end

    for helper_id <- [{:start_pty, 2}, {:ensure_pty_server, 4}] do
      assert fns[helper_id] && fns[helper_id].private,
             "#{fmt(helper_id)} must be `defp` (private) in #{@allowed_relpath}."
    end
  end

  test "no cc lib file imports Ezagent.Domain.Pty (would make `start/2` a bare local launch)" do
    importers =
      Path.wildcard(Path.join(@lib_root, "**/*.ex"))
      |> Enum.filter(fn path ->
        ast = path |> File.read!() |> Code.string_to_quoted!()
        imports_pty?(ast, pty_alias_names(ast))
      end)
      |> Enum.map(&Path.relative_to(&1, @lib_root))
      |> Enum.sort()

    assert importers == [],
           "cc lib files must NOT `import Ezagent.Domain.Pty` — that turns `start(...)` " <>
             "into a bare local launch that bypasses the grant-gated chain. Offenders: " <>
             "#{inspect(importers)}. Use the gated CcAgent.Spawn chain instead."
  end

  defp imports_pty?(ast, names) do
    {_, found} =
      Macro.prewalk(ast, false, fn
        {:import, _, [target | _opts]} = node, acc ->
          {node, acc or pty_alias?(target, names)}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp fmt({name, arity}), do: "#{name}/#{arity}"
  defp fmt_set(set), do: set |> Enum.map(&fmt/1) |> inspect()

  # ---- AST helpers ---------------------------------------------------

  defp fn_map(ast, pty_names) do
    {_, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, kw]} = node, acc when kind in [:def, :defp] and is_list(kw) ->
          case fn_id(head) do
            nil -> {node, acc}
            id -> {node, [{id, kind == :defp, body_refs(Keyword.get(kw, :do), pty_names)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reduce(defs, %{}, fn {id, private, {locals, pty?}}, acc ->
      Map.update(acc, id, %{private: private, locals: locals, pty?: pty?}, fn cur ->
        %{
          private: cur.private and private,
          locals: MapSet.union(cur.locals, locals),
          pty?: cur.pty? or pty?
        }
      end)
    end)
  end

  defp fn_id({:when, _, [head | _]}), do: fn_id(head)
  defp fn_id({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp fn_id({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, 0}
  defp fn_id(_), do: nil

  defp alias_last({:__aliases__, _, segs}) when is_list(segs), do: List.last(segs)
  defp alias_last(_), do: nil

  defp pty_alias?({:__aliases__, _, [:Ezagent, :Domain, :Pty]}, _names), do: true
  defp pty_alias?({:__aliases__, _, _} = al, names), do: MapSet.member?(names, alias_last(al))
  defp pty_alias?(_, _), do: false

  defp body_refs(nil, _names), do: {MapSet.new(), false}

  defp body_refs(body, names) do
    {_, {locals, pty?}} =
      Macro.prewalk(body, {MapSet.new(), false}, fn
        # qualified/aliased remote CALL  Foo.Bar.start(args) where Bar refers to Pty
        {{:., _, [al, :start]}, _, args} = node, {l, p} when is_list(args) ->
          {node, {l, p or pty_alias?(al, names)}}

        # remote CAPTURE  &Foo.Bar.start/2 where Bar refers to Pty
        {:&, _, [{:/, _, [{{:., _, [al, :start]}, _, _}, _arity]}]} = node, {l, p} ->
          {node, {l, p or pty_alias?(al, names)}}

        # local CAPTURE  &name/arity  ->  {name, arity}
        {:&, _, [{:/, _, [{name, _, ctx}, arity]}]} = node, {l, p}
        when is_atom(name) and is_atom(ctx) and is_integer(arity) ->
          {node, {MapSet.put(l, {name, arity}), p}}

        # bare local CALL  name(args)  ->  {name, length(args)}
        {name, _meta, args} = node, {l, p} when is_atom(name) and is_list(args) ->
          {node, {MapSet.put(l, {name, length(args)}), p}}

        node, acc ->
          {node, acc}
      end)

    {locals, pty?}
  end
end
