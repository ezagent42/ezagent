defmodule Ezagent.PidSurfaceScanner do
  @moduledoc """
  V5 pid-closure, Track A (obtain side) — the no-pid ENUMERATOR (**report-only**).

  A static AST scanner (same dev/CI source-tree idiom as
  `Ezagent.ActorBoundaryScanner`) that enumerates every PUBLIC function on the
  sanctioned Kind/actor surface whose signature **yields or accepts a `pid()`**,
  so a later phase can close the pid surface. It is deliberately NOT a gate:
  with an EMPTY allowlist it EMITS the full list; nothing here fails CI on a
  violation. The enforcement flip is a separate, later, human-decided phase.

  ## Scan scope (A1a broadening)

    * `apps/*/lib/**/*.ex` — the WHOLE umbrella public surface (A1a: widened
      from the A0 scope of `apps/ezagent_actor/lib/**` + 5 seed files). Every
      public function anywhere in the tree whose spec/return/param/guard/body
      yields or accepts a `pid()` is enumerated. The empty-allowlist emit is
      the **frozen ledger authority** for the A1b/A1c migration phases
      (`docs/notes/v5-obtain-side-pid-surface.md`).

  ## Detection (why-flagged)

  `@spec`s are preferred; the function-head/body AST is the fallback. A public
  `def`/`defdelegate` is flagged with one or more of:

    * `return` — the spec's return type IS a bare `pid()`;
    * `nested` — a `pid()` appears INSIDE the returned tuple / struct / map /
      list / union (local `@type` references are expanded, so
      `[instance_summary()]` with `pid: pid()` in the type is caught);
    * `param` — a `pid()` appears in a parameter type;
    * `guard` — the head guards on `is_pid/1`;
    * `body` — no signature signal, but the body OBTAINS a pid (binds a var
      from a known pid-source call — `KindRegistry.lookup`,
      `LocalRuntime.ensure_started`, `Kind.spawn`, supervisor/GEN-server
      starts, `Registry.select`, …) and then USES it (passes it on, compares
      it against `self()`, calls/sends through it). This is what surfaces the
      self-detection + raw-serialized-call shapes (`Cap.revoke_all_to/2`,
      `Cap.issue_for_action/3`) whose specs mention only URIs.

  The has-teeth self-test
  (`apps/ezagent_core/test/invariants/pid_surface_scanner_test.exs`) asserts the
  scanner surfaces every known pid-yielding seed site — a FLOOR proving the
  scanner is not blinded — and regenerates the committed Track-A worklist
  `docs/notes/v5-obtain-side-pid-surface.md`.
  """

  # A1a: the scan scope is the WHOLE umbrella public surface — every
  # `apps/*/lib/**/*.ex` file. The A0 scope (`apps/ezagent_actor/lib/**` + 5
  # hand-picked seed files) missed public Kind-pid contracts in the domain
  # apps (codex round-2 #1: `Ezagent.Domain.Agent.materialize_declared/1`,
  # `Ezagent.Workspace.create/2`, `Ezagent.Entity.Session.ensure_template_alive/1`);
  # the blanket sweep is the only scope that provably cannot miss one.
  @scan_glob "apps/*/lib/**/*.ex"

  # PID-SOURCE calls: a variable bound from one of these carries an actor pid.
  # Matched by trailing module-alias parts (string form, dot-boundary) so both
  # fully-qualified and aliased call sites resolve. Strings — never module
  # atoms — so this dev-tool file stays invisible to the FORWARD reach-in gate.
  @pid_sources [
    {"KindRegistry", [:lookup, :list_all]},
    {"LocalRuntime", [:ensure_started]},
    {"SpawnRegistry", [:spawn, :spawn_detailed]},
    {"Kind", [:spawn, :spawn_detailed, :list_instances]},
    {"DynamicSupervisor", [:start_child, :start_link]},
    {"Supervisor", [:start_link, :start_child]},
    {"GenServer", [:start, :start_link]},
    {"Registry", [:lookup, :match, :select]},
    {"Task", [:async, :start, :start_link]},
    {"Process", [:spawn]}
  ]

  @doc """
  The repository root (absolute). Resolved from the working directory (the mix
  test / task cwd), NOT a compile-time `__DIR__` — this is a dev/CI source-tree
  scanner, not a shipped runtime asset (same idiom as `Ezagent.ActorBoundaryScanner`).
  """
  def repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end

  @doc """
  All pid-surface sites currently in scan scope (EMPTY allowlist = full emit).

  Each entry: `%{module, fun, arity, path, line, whys}` where `whys` is a
  sorted subset of `[:body, :guard, :nested, :param, :return]`.
  """
  @spec scan() :: [map()]
  def scan do
    root = repo_root()

    root
    |> Path.join(@scan_glob)
    |> Path.wildcard()
    |> Enum.flat_map(fn abs ->
      sites_in_source(File.read!(abs), Path.relative_to(abs, root))
    end)
    |> Enum.sort_by(&{&1.module, &1.fun, &1.arity, &1.line})
    |> Enum.uniq()
  end

  @doc """
  Render the emitted sites as the committed Track-A worklist markdown
  (`docs/notes/v5-obtain-side-pid-surface.md`). Deterministic output.
  """
  @spec markdown([map()]) :: String.t()
  def markdown(sites) do
    rows =
      Enum.map_join(sites, "\n", fn s ->
        "| `#{inspect(s.module)}` | `#{s.fun}/#{s.arity}` | `#{s.path}:#{s.line}` | " <>
          "#{Enum.map_join(s.whys, " + ", &Atom.to_string/1)} |"
      end)

    """
    # V5 pid-closure — Track A: obtain-side pid surface (ENUMERATION, report-only)

    > Generated by `Ezagent.PidSurfaceScanner` (empty allowlist = full emit) via
    > `mix test apps/ezagent_core/test/invariants/pid_surface_scanner_test.exs`.
    > **Report-only**: this is a census, NOT a gate — no violation here fails CI,
    > and the enforcement flip is a separate later phase (human decision).

    Every PUBLIC function on the sanctioned Kind/actor surface whose signature
    yields or accepts a `pid()` (spec-preferred, AST fallback):

    - `return` — returns a bare `pid()`
    - `nested` — `pid()` inside a returned tuple / struct / map / list / union
      (local `@type`s expanded)
    - `param` — takes a `pid()` parameter (spec)
    - `guard` — head guards on `is_pid/1`
    - `body` — no signature signal, but the body OBTAINS an actor pid from a
      pid-source call and USES it (self-detection `pid == self()`, raw
      serialized `GenServer.call(pid, …)`, pass-through)

    Scan scope (A1a): the WHOLE umbrella public surface — every
    `apps/*/lib/**/*.ex` file (A0 scanned only `apps/ezagent_actor/lib/**` +
    5 seed files). This umbrella-wide list is the **frozen ledger authority**
    for the A1b/A1c migration phases. **#{length(sites)} entries.**

    | Module | Function/Arity | File:Line | Why flagged |
    |---|---|---|---|
    #{rows}

    ## Notable entries (seed annotations)

    - `Ezagent.SpawnRegistry.spawn/2` + `spawn_detailed/2` — return pids; only
      `register/2` is meant to stay public.
    - `Ezagent.Cap.revoke_all_to/2` — pid self-detection (`pid == self()`) + a
      raw serialized `GenServer.call(pid, {:ezagent_revoke_all_to, …})`; does
      NOT go through `issue_for_action`.
    - `Ezagent.Cap.issue_for_action/3` — pid self-detect + action-subject
      resolution against the live target.
    - `Ezagent.Kind.list_instances/0` — the returned pids drive supervised
      termination in `Ezagent.Behavior.Terminable` and Sandbox.
    - `EzagentDomainUi.AutoDerive` — exposes pids in instance summaries/details.
    - `Ezagent.DomainGit.TaskAccessSupervisor.ensure_started/1` — pid-returning
      wrapper that re-obtains the pid from `KindRegistry`.
    - `Ezagent.Kind.runtime_view/1` — pid form consumed by
      `composition_caps.ex` and `auto_derive.ex`.
    - `Ezagent.Identity.OperatorReads.registry_all/1` — INTENTIONAL operator
      metadata (the operator-gated global list-all chokepoint): flagged by the
      scanner as required, noted here as a candidate ENUMERATED-EXCEPTION for
      the later enforcement phase.
    - A1a has-teeth additions (codex round-2 #1 — public Kind-pid contracts
      the A0 scope missed):
      `Ezagent.Domain.Agent.materialize_declared/1`,
      `Ezagent.Workspace.create/2`,
      `Ezagent.Entity.Session.ensure_template_alive/1`.
    """
  end

  @doc false
  def sites_in_source(source, rel) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {_, acc} =
          Macro.prewalk(ast, [], fn
            {:defmodule, _, [{:__aliases__, _, parts}, [do: body]]} = node, acc
            when is_list(parts) ->
              if Enum.all?(parts, &is_atom/1) do
                {node, module_sites(Module.concat(parts), body, rel) ++ acc}
              else
                {node, acc}
              end

            node, acc ->
              {node, acc}
          end)

        acc

      {:error, _} ->
        []
    end
  end

  # ── Per-module analysis ────────────────────────────────────────────────────

  defp module_sites(module, body, rel) do
    {specs, types, defs} = collect_module_parts(body)

    Enum.flat_map(defs, fn {kind, meta, head, fbody} ->
      case head_name_arity(head) do
        {name, arity} ->
          whys =
            (spec_whys(Map.get(specs, {name, arity}, []), types) ++
               guard_whys(head) ++ body_whys(fbody))
            |> Enum.uniq()
            |> Enum.sort()

          if whys == [] do
            []
          else
            [
              %{
                module: module,
                fun: name,
                arity: arity,
                path: rel,
                line: Keyword.get(meta, :line, 0),
                whys: whys,
                kind: kind
              }
            ]
          end

        nil ->
          []
      end
    end)
  end

  # `{specs, types, defs}` for one module body. Nested `defmodule`s are pruned
  # (their defs belong to the inner module, matched by the outer prewalk pass).
  defp collect_module_parts(body) do
    {_, acc} =
      Macro.prewalk(body, {[], [], []}, fn
        {:defmodule, _, _}, acc ->
          {{:__pruned__, [], nil}, acc}

        {:@, _, [{:spec, _, [spec_ast]}]} = node, {specs, types, defs} ->
          {node, {[spec_ast | specs], types, defs}}

        {:@, _, [{kind, _, [type_ast]}]} = node, {specs, types, defs}
        when kind in [:type, :typep, :opaque] ->
          {node, {specs, [type_ast | types], defs}}

        {:def, meta, clauses} = node, {specs, types, defs} ->
          {node, {specs, types, [{:def, meta, clauses} | defs]}}

        {:defdelegate, meta, clauses} = node, {specs, types, defs} ->
          {node, {specs, types, [{:defdelegate, meta, clauses} | defs]}}

        node, acc ->
          {node, acc}
      end)

    specs =
      acc
      |> elem(0)
      |> Enum.reduce(%{}, fn spec_ast, m ->
        case spec_parts(spec_ast) do
          {name, arity, _params, _ret} ->
            Map.update(m, {name, arity}, [spec_ast], &[spec_ast | &1])

          nil ->
            m
        end
      end)

    types =
      acc
      |> elem(1)
      |> Enum.reduce(%{}, fn
        {:"::", _, [{name, _, _}, def_ast]}, m when is_atom(name) ->
          Map.put(m, name, def_ast)

        _, m ->
          m
      end)

    defs =
      Enum.map(elem(acc, 2), fn
        {:def, meta, [head]} -> {:def, meta, head, nil}
        {:def, meta, [head, fbody]} -> {:def, meta, head, fbody}
        {:defdelegate, meta, [head | _]} -> {:defdelegate, meta, head, nil}
      end)

    {specs, types, defs}
  end

  # `{name, arity, param_type_asts, return_type_ast}` from a `@spec` AST.
  defp spec_parts({:"::", _, [call, ret]}) do
    case call do
      {:when, _, [inner | _]} ->
        spec_parts({:"::", [], [inner, ret]})

      {name, _, args} when is_atom(name) and is_list(args) ->
        {name, length(args), args, unwrap_when(ret)}

      _ ->
        nil
    end
  end

  defp spec_parts(_), do: nil

  defp unwrap_when({:when, _, [ret | _]}), do: ret
  defp unwrap_when(ret), do: ret

  # `{name, arity}` from a def/defdelegate head (defaults counted once; a
  # no-parens `def foo do …` head carries an atom CONTEXT, not an args list).
  defp head_name_arity({:when, _, [inner | _]}), do: head_name_arity(inner)

  defp head_name_arity({name, _, ctx}) when is_atom(name) and (is_atom(ctx) or is_nil(ctx)),
    do: {name, 0}

  defp head_name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp head_name_arity(_), do: nil

  # ── Why detectors ──────────────────────────────────────────────────────────

  defp spec_whys(spec_asts, types) do
    Enum.flat_map(spec_asts, fn spec_ast ->
      case spec_parts(spec_ast) do
        {_name, _arity, params, ret} ->
          param? = Enum.any?(params, &type_has_pid?(&1, types))

          return_whys =
            cond do
              bare_pid_type?(ret) -> [:return]
              type_has_pid?(ret, types) -> [:nested]
              true -> []
            end

          if(param?, do: [:param], else: []) ++ return_whys

        nil ->
          []
      end
    end)
  end

  defp guard_whys(head) do
    {_, found?} =
      Macro.prewalk(head, false, fn
        {:is_pid, _, [_]} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    if found?, do: [:guard], else: []
  end

  defp body_whys(nil), do: []

  defp body_whys(fbody) do
    bound = pid_bound_vars(fbody)

    if MapSet.size(bound) > 0 and Enum.any?(bound, &var_used?(fbody, &1)) do
      [:body]
    else
      []
    end
  end

  # Variable names bound (in any pattern position) from a pid-source call:
  # `{:ok, pid} <- src`, `pid = src`, or a `case src do {:ok, pid} -> …`.
  defp pid_bound_vars(fbody) do
    {_, vars} =
      Macro.prewalk(fbody, MapSet.new(), fn
        {op, _, [lhs, rhs]} = node, acc when op in [:=, :<-] ->
          if pid_source?(rhs), do: {node, Enum.into(pattern_vars(lhs), acc)}, else: {node, acc}

        {:case, _, [subject, [do: clauses]]} = node, acc ->
          if pid_source?(subject) do
            clause_vars =
              clauses
              |> Enum.flat_map(fn
                {:->, _, [[lhs], _]} -> pattern_vars(lhs)
                _ -> []
              end)
              |> Enum.into(acc)

            {node, clause_vars}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    vars
  end

  # Is `name` used anywhere in `fbody` BEYOND its pid-source binding sites?
  defp var_used?(fbody, name) do
    total = count_var(fbody, name)
    total > count_var(pid_source_binds(fbody), name)
  end

  # The pid-source binding RHS/LHS subtrees only — occurrences of the var there
  # are its BINDING, not a use.
  defp pid_source_binds(fbody) do
    {_, binds} =
      Macro.prewalk(fbody, [], fn
        {op, _, [lhs, rhs]} = node, acc when op in [:=, :<-] ->
          if pid_source?(rhs), do: {node, [lhs | acc]}, else: {node, acc}

        {:case, _, [subject, [do: clauses]]} = node, acc ->
          if pid_source?(subject) do
            lhss =
              Enum.flat_map(clauses, fn
                {:->, _, [[lhs], _]} -> [lhs]
                _ -> []
              end)

            {node, lhss ++ acc}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    binds
  end

  defp count_var(ast, name) do
    {_, n} =
      Macro.prewalk(ast, 0, fn
        {^name, _, ctx} = node, acc when is_atom(ctx) or is_nil(ctx) -> {node, acc + 1}
        node, acc -> {node, acc}
      end)

    n
  end

  # The bound variable names in a match pattern (`_` skipped).
  defp pattern_vars(pattern) do
    {_, vars} =
      Macro.prewalk(pattern, [], fn
        {name, _, ctx} = node, acc
        when is_atom(name) and (is_atom(ctx) or is_nil(ctx)) and name != :_ ->
          {node, [name | acc]}

        node, acc ->
          {node, acc}
      end)

    vars
  end

  # A call whose result carries an actor pid (config table above), or `self()`.
  defp pid_source?({{:., _, [modast, fun]}, _, _args}) when is_atom(fun) do
    mod = Macro.to_string(modast)

    Enum.any?(@pid_sources, fn {suffix, funs} ->
      fun in funs and (mod == suffix or String.ends_with?(mod, "." <> suffix))
    end)
  end

  defp pid_source?({:self, _, args}) when is_atom(args) or is_list(args), do: true
  defp pid_source?(_), do: false

  # ── Type AST: pid detection with local @type expansion ────────────────────

  defp bare_pid_type?({:pid, _, args}) when is_list(args), do: true
  defp bare_pid_type?(_), do: false

  defp type_has_pid?(ast, types, depth \\ 8)

  defp type_has_pid?({:pid, _, args}, _types, _depth) when is_list(args), do: true

  # Local type call (`instance_summary()`) — expand its definition (depth-capped
  # against recursive types).
  defp type_has_pid?({name, _, args}, types, depth)
       when is_atom(name) and is_list(args) and depth > 0 do
    case Map.fetch(types, name) do
      {:ok, def_ast} -> type_has_pid?(def_ast, types, depth - 1)
      :error -> Enum.any?(args, &type_has_pid?(&1, types, depth))
    end
  end

  defp type_has_pid?(tuple, types, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&type_has_pid?(&1, types, depth))

  defp type_has_pid?(list, types, depth) when is_list(list),
    do: Enum.any?(list, &type_has_pid?(&1, types, depth))

  defp type_has_pid?(_other, _types, _depth), do: false
end
