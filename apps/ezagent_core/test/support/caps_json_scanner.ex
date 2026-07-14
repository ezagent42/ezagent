defmodule EzagentCore.CapsJsonScanner do
  @moduledoc """
  Finds every call to an `Ezagent.Users` writer that puts caps into
  `users.caps_json`.

  It lives HERE, not inside a test module, for one reason: two tests must run
  the SAME detector. `cap_issue_chokepoint_test.exs` uses it to enumerate the
  real call sites; `cap_issue_chokepoint_boundary_test.exs` uses it to prove
  which spellings the detector can and cannot see. A boundary test that carried
  its own copy of this logic would be testing its copy, not the gate.

  ## What it sees, and what it is blind to

  This has been evaded three times. Each fix was "teach it one more spelling",
  and each time it was still wrong. So the boundary is stated here — and every
  line of it is MEASURED by a fixture in `cap_issue_chokepoint_boundary_test.exs`,
  which runs THIS detector, not a copy of it.

  SEEN — 8 fixtures (a plain baseline + the 7 evasions that actually got past
  earlier cuts):

      Ezagent.Users.create(uri, pw, caps)        plain remote call
      uri |> Ezagent.Users.create(pw, caps)      pipe — the first arg sits
                                                 OUTSIDE the call node, so an
                                                 arity guard silently misses it
      alias Ezagent.Users, as: U; U.create(...)  alias, both `as:` and
                                                 `alias Ezagent.{Users, ...}`
      import Ezagent.Users; create(...)          import → bare local call
      @users Ezagent.Users; @users.create(...)   module attribute
      apply(Ezagent.Users, :create, [...])       apply with a literal module
      &Ezagent.Users.create/3                    capture — the caps arg is not
                                                 visible, so it is recorded
                                                 `:opaque`, which CANNOT be
                                                 classified `:no_caps`; a human
                                                 must decide

  NOT SEEN — and nothing else sees it either:

      m = Module.concat([:Ezagent, :Users])      the module atom is resolved
      m.create(uri, pw, forged_caps)             at RUNTIME

  **Leg 3a (the column ratchet) does NOT back that up.** An evasive CALLER never
  writes `caps_json:` itself — `users.ex` does, on its behalf. Leg 3a catches a
  new WRITER FUNCTION inside `Ezagent.Users`, not an unenumerated caller. (An
  earlier version of this comment claimed leg 3a was a "structural backstop" for
  exactly this case. It is not. That claim was false and is retracted.)

  ## So what does this scanner actually prove?

  Only this, and not a word more:

  > **Every STATICALLY RESOLVABLE call to a `caps_json` writer is enumerated.**

  It does NOT prove "every cap in `users.caps_json` passed `Cap.issue/3`". That
  property is about what happens at RUNTIME, and no source scan can prove it —
  the gap is not closable by a better scanner.

  Closing it for real means making the property structural: have `Cap.issue/3`
  record what it issued, and have `Ezagent.Users` REFUSE a cap that was never
  issued. Then the spelling of the call stops mattering entirely. That changes
  core and a public API contract, so it is a decision, not a test fix — see
  `docs/notes/2026-07-14-cap-issue-structural-enforcement.md`.
  """

  @doc false
  def users_create_cap_args(file) do
    ast = quoted!(file)
    env = scan_env(ast)

    {_ast, acc} =
      ast
      |> expand_pipes()
      |> Macro.prewalk([], fn node, acc -> {node, collect_site(node, env) ++ acc} end)

    Enum.reverse(acc)
  end

  # What the names in this file MEAN: `alias` (incl. `as:` and the multi form),
  # `import` (which turns a writer into a BARE local call), and module attributes
  # bound to a module (`@users Ezagent.Users` → `@users.create(...)`).
  defp scan_env(ast) do
    {_ast, env} =
      Macro.prewalk(ast, %{aliases: %{}, imported?: false, attrs: %{}}, fn
        # alias Ezagent.{Users, Identity}
        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, mods}]} = node, env ->
          {node,
           Enum.reduce(mods, env, fn {:__aliases__, _, seg}, e ->
             put_alias(e, [List.last(seg)], base ++ seg)
           end)}

        # alias Ezagent.Users  /  alias Ezagent.Users, as: U
        {:alias, _, [{:__aliases__, _, mod} | opts]} = node, env ->
          {node, put_alias(env, alias_as(opts, mod), mod)}

        # import Ezagent.Users  → bare `create(...)` becomes a Users call
        {:import, _, [{:__aliases__, _, mod} | _]} = node, env ->
          {node, %{env | imported?: env.imported? or List.last(mod) == :Users}}

        # @users Ezagent.Users
        {:@, _, [{name, _, [{:__aliases__, _, mod}]}]} = node, env when is_atom(name) ->
          {node, %{env | attrs: Map.put(env.attrs, name, mod)}}

        node, env ->
          {node, env}
      end)

    env
  end

  defp put_alias(env, as, mod), do: %{env | aliases: Map.put(env.aliases, as, mod)}

  defp alias_as([kw | _], mod) when is_list(kw) do
    case Keyword.get(kw, :as) do
      {:__aliases__, _, seg} -> seg
      _ -> [List.last(mod)]
    end
  end

  defp alias_as(_opts, mod), do: [List.last(mod)]

  # `a |> M.f(b)` parses with `a` OUTSIDE the call node, so an arity guard on the
  # call's args silently under-counts. Rewrite pipes into ordinary calls first.
  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [lhs, {call, meta, args}]} when is_list(args) -> {call, meta, [lhs | args]}
      node -> node
    end)
  end

  defp users?(mod, env), do: List.last(Map.get(env.aliases, mod, mod)) == :Users

  # A plain (or piped, or aliased) remote call.
  defp collect_site({{:., _, [{:__aliases__, _, mod}, fun]}, _, args}, env)
       when is_list(args) do
    if users?(mod, env), do: caps_arg(fun, args), else: []
  end

  # `@users.create(...)` where `@users Ezagent.Users`
  defp collect_site({{:., _, [{:@, _, [{name, _, ctx}]}, fun]}, _, args}, env)
       when is_atom(name) and is_atom(ctx) and is_list(args) do
    case Map.get(env.attrs, name) do
      nil -> []
      mod -> if List.last(mod) == :Users, do: caps_arg(fun, args), else: []
    end
  end

  # `apply(Users, :create, [uri, pw, caps])`
  defp collect_site({:apply, _, [{:__aliases__, _, mod}, fun, args]}, env)
       when is_atom(fun) do
    cond do
      not users?(mod, env) -> []
      is_list(args) -> caps_arg(fun, args)
      # a runtime-built arg list hides the caps
      writer?(fun) -> [:opaque]
      true -> []
    end
  end

  # `&Users.create/3` — the caps argument is not visible at the capture site.
  defp collect_site(
         {:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, mod}, fun]}, _, _}, _arity]}]},
         env
       ) do
    if users?(mod, env) and writer?(fun), do: [:opaque], else: []
  end

  # `import Ezagent.Users` turns a writer into a BARE local call, otherwise
  # indistinguishable from any local `create/3`. Only a file that actually
  # imports Users is read this way.
  defp collect_site({fun, _, args}, env) when is_atom(fun) and is_list(args) do
    if env.imported? and writer?(fun), do: caps_arg(fun, args), else: []
  end

  defp collect_site(_node, _env), do: []

  defp writer?(fun), do: fun in [:create, :create_read_only]

  defp caps_arg(:create, args) when length(args) >= 3, do: [Enum.at(args, 2)]
  defp caps_arg(:create_read_only, args) when length(args) >= 2, do: [Enum.at(args, 1)]
  # `create_read_only/1` defaults to `[]` — no caps, nothing to police.
  defp caps_arg(_fun, _args), do: []

  defp quoted!(file) do
    case Code.string_to_quoted(File.read!(file)) do
      {:ok, ast} -> ast
      {:error, reason} -> raise "cannot scan #{file}: #{inspect(reason)}"
    end
  end
end
