defmodule EzagentCore.ListReadChokepointBoundaryTest do
  @moduledoc """
  Read-plane-authz PR-4 rework (Pillar B) — the LIST/ENUMERATION plane gate.

  A principal-facing / presenter-tier module MUST NOT call a GLOBAL or
  workspace ENUMERATION read primitive directly: every list read of
  sessions, agents, users, or templates routes through a caller-authorizing
  chokepoint — `Ezagent.Workspace.WorkspaceReads` (sessions/agents),
  `Ezagent.Workspace.UserReads` (user roster), `Ezagent.Session.TemplateReads`
  (session templates), `Ezagent.Identity.OperatorReads` (operator-scoped
  global registry), `Ezagent.Socialware.SessionReads` (conversation plane).

  ## Banned primitives (the complete set)

    * `Ezagent.KindRegistry.list_all/0` — live global registry
    * `Ezagent.Ecto.KindSnapshot.list_all/0` — durable global scan
    * `Ezagent.Ecto.KindSnapshot.list_in_workspace/1` — durable workspace scan
    * `EzagentDomainInstanceMessage.list_sessions/{0,1,2}` — session enumeration
      (the /0 arity is GLOBAL — it scans the whole KindRegistry)
    * `EzagentDomainInstanceMessage.list_persisted_sessions/1` — durable session scan
    * `Ezagent.Entity.Agent.list_in_workspace/1` — workspace agent scan
    * `Ezagent.Users.list_all/0` / `list_in_workspace/1` — user enumeration

  A direct call added to the presenter tier → this test RED, with the
  offenders listed — the red build IS the reader-migration worklist (the
  allowlist is EMPTY by design: the only legal set is "no direct calls").

  ## AST-based + evasion-hardened

  The gate parses each file to an AST (via `EzagentCore.AstScan`) and resolves
  module aliases/imports, so it is NOT fooled by:

    * `alias` renaming (`alias Ezagent.KindRegistry, as: Reg`),
    * root-qualification (`Elixir.Ezagent.KindRegistry.list_all/0` — a
      leading `Elixir` segment is normalized away),
    * `import`ed bare calls (`import Ezagent.KindRegistry; list_all()`),
    * function captures (`&KindRegistry.list_all/0`),
    * dynamic dispatch (`apply(KindRegistry, :list_all, [])`), including the
      qualified forms `Kernel.apply(KindRegistry, :list_all, [])` and
      `:erlang.apply(KindRegistry, :list_all, [])`, and the 2-arity
      `apply(KindRegistry, :list_all)` form for 0-arity primitives,
    * splitting a call across lines.

  ## Known matcher limitations (NOT caught — documented, not claimed)

    * MODULE-VARIABLE indirection — `m = Ezagent.KindRegistry; m.list_all()`
      dispatches through a runtime binding; resolving it soundly needs flow
      analysis, which this gate does not attempt. A self-test below pins the
      current (uncaught) behavior so a future matcher upgrade must update
      this documentation explicitly. The mitigating control is review
      discipline plus the fact that the chokepoints are the only modules
      with legitimate reason to name these primitives at all.
    * `apply(mod_var, :fun, args)` with a non-literal module — the same
      limitation from the dynamic side.

  ## Deliberately NOT banned

  `Ezagent.Workspace.Store.get_by_name/1` is a single-workspace LOOKUP, not
  an enumeration (legitimate callers: `workspace_switch_controller`,
  `error_cards`, …). Global CODE registries (`PluginRegistry`,
  `AgentFlavorRegistry`, `TemplateRegistry`, `AgentBridge.Registry`) are not
  tenant data. The chokepoint modules themselves live OUTSIDE the scanned
  tiers by construction.
  """
  use ExUnit.Case, async: true

  alias EzagentCore.AstScan

  @repo_root Path.expand("../../../..", __DIR__)

  # The presenter / principal-facing read tiers for the list plane:
  # world plugin (presenter), web (controllers/LiveViews), domain UI kit,
  # and the feishu plugin (inbound mention resolution).
  @scan_dirs [
    "apps/ezagent_plugin_world/lib",
    "apps/ezagent_web/lib",
    "apps/ezagent_domain_ui/lib",
    "apps/ezagent_plugin_feishu/lib"
  ]

  # The banned enumeration primitives: {resolved module parts, fun, arity}.
  @banned_primitives [
    {[:Ezagent, :KindRegistry], :list_all, 0},
    {[:Ezagent, :Ecto, :KindSnapshot], :list_all, 0},
    {[:Ezagent, :Ecto, :KindSnapshot], :list_in_workspace, 1},
    {[:EzagentDomainInstanceMessage], :list_sessions, 0},
    {[:EzagentDomainInstanceMessage], :list_sessions, 1},
    {[:EzagentDomainInstanceMessage], :list_sessions, 2},
    {[:EzagentDomainInstanceMessage], :list_persisted_sessions, 1},
    {[:Ezagent, :Entity, :Agent], :list_in_workspace, 1},
    {[:Ezagent, :Users], :list_all, 0},
    {[:Ezagent, :Users], :list_in_workspace, 1}
  ]

  # Starts EMPTY — the red build is the exhaustive worklist, not a
  # hand-maintained census. A module may only be added here with a written
  # justification; the goal state is an empty allowlist forever.
  @allowlisted_basenames []

  test "no presenter-tier module calls an enumeration primitive outside the chokepoints" do
    offenders =
      @scan_dirs
      |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**/*.ex"])))
      |> Enum.reject(&(Path.basename(&1) in @allowlisted_basenames))
      |> Enum.flat_map(&offenders_in_file/1)

    assert offenders == [],
           """
           Read-plane-authz LIST gate: a presenter/web/ui/feishu module calls a
           global/workspace ENUMERATION primitive DIRECTLY. Route the read
           through the caller-authorizing chokepoint instead:
             sessions  → Ezagent.Workspace.WorkspaceReads.sessions/2
             agents    → Ezagent.Workspace.WorkspaceReads.agents/2
             users     → Ezagent.Workspace.UserReads.users/2
             templates → Ezagent.Session.TemplateReads.session_templates/2
             operator  → Ezagent.Identity.OperatorReads.registry_all/1
           Offenders:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "the allowlist stays EMPTY (the gate is the completeness enumerator)" do
    assert @allowlisted_basenames == [],
           "the list-plane gate allowlist must stay empty — migrate the reader instead"
  end

  test "the gate catches every evasion form of every banned primitive (AST, not substring)" do
    for {mod_parts, fun, arity} <- @banned_primitives do
      mod = Enum.map_join(mod_parts, ".", &Atom.to_string/1)
      args = Enum.map_join(1..arity//1, ", ", fn i -> "a#{i}" end)
      args = if arity == 0, do: "", else: args
      apply_args = "[" <> args <> "]"
      short = List.last(mod_parts) |> Atom.to_string()

      evasions = %{
        "fully-qualified" =>
          "defmodule E1 do\n  def go(#{args}), do: #{mod}.#{fun}(#{args})\nend",
        "root-qualified Elixir." =>
          "defmodule E2 do\n  def go(#{args}), do: Elixir.#{mod}.#{fun}(#{args})\nend",
        "aliased" =>
          "defmodule E3 do\n  alias #{mod}, as: Sneaky\n  def go(#{args}), do: Sneaky.#{fun}(#{args})\nend",
        "imported bare call" =>
          "defmodule E4 do\n  import #{mod}\n  def go(#{args}), do: #{fun}(#{args})\nend",
        "capture (qualified)" =>
          "defmodule E5 do\n  def go, do: &#{short}.#{fun}/#{arity}\n  alias #{mod}\nend",
        "capture (root-qualified)" =>
          "defmodule E6 do\n  def go, do: &Elixir.#{mod}.#{fun}/#{arity}\nend",
        "apply/3" => "defmodule E7 do\n  def go, do: apply(#{mod}, :#{fun}, #{apply_args})\nend",
        "apply/3 (aliased)" =>
          "defmodule E8 do\n  alias #{mod}, as: Sneaky\n  def go, do: apply(Sneaky, :#{fun}, #{apply_args})\nend",
        "Kernel.apply/3 (qualified)" =>
          "defmodule E10 do\n  def go, do: Kernel.apply(#{mod}, :#{fun}, #{apply_args})\nend",
        ":erlang.apply/3 (qualified)" =>
          "defmodule E11 do\n  def go, do: :erlang.apply(#{mod}, :#{fun}, #{apply_args})\nend",
        "apply/2 (0-arity only)" =>
          if arity == 0 do
            "defmodule E12 do\n  def go, do: apply(#{mod}, :#{fun})\nend"
          else
            nil
          end,
        "Kernel.apply/2 (0-arity only)" =>
          if arity == 0 do
            "defmodule E13 do\n  def go, do: Kernel.apply(#{mod}, :#{fun})\nend"
          else
            nil
          end,
        "piped (for arity-1)" =>
          if arity == 1 do
            "defmodule E9 do\n  def go(x), do: x |> #{mod}.#{fun}()\nend"
          else
            nil
          end
      }

      for {label, src} <- evasions, not is_nil(src) do
        assert offenses_in_source(src, "fixture") != [],
               "AST gate must flag the #{label} form of #{mod}.#{fun}/#{arity}:\n#{src}"
      end
    end
  end

  test "KNOWN LIMITATION: module-variable indirection is NOT caught (documented, not claimed)" do
    # `m = Ezagent.KindRegistry; m.list_all()` dispatches through a runtime
    # binding — resolving it soundly requires flow analysis this gate does
    # not attempt (see the moduledoc "Known matcher limitations" section).
    # This test pins the CURRENT behavior: if the matcher is ever upgraded
    # to resolve module-variable indirection, it must start flagging this
    # fixture — flip the assertion and update the moduledoc in the same
    # change. Until then the gate does NOT claim evasion-proof coverage
    # against this form.
    src = """
    defmodule Evasion do
      def go do
        m = Ezagent.KindRegistry
        m.list_all()
      end
    end
    """

    assert offenses_in_source(src, "fixture") == [],
           "matcher now catches module-variable indirection? Update the moduledoc and flip this test."
  end

  test "no false positives on chokepoint calls and non-enumeration reads" do
    benign = """
    defmodule Fine do
      alias Ezagent.Workspace.WorkspaceReads
      alias Ezagent.Workspace.UserReads
      alias Ezagent.Session.TemplateReads
      alias Ezagent.Identity.OperatorReads
      alias Ezagent.Socialware.SessionReads

      def sessions(caller, ws), do: WorkspaceReads.sessions(caller, ws)
      def agents(caller, ws), do: WorkspaceReads.agents(caller, ws)
      def users(caller, ws), do: UserReads.users(caller, ws)
      def one_user(caller, uri), do: UserReads.user(caller, uri)
      def templates(caller, name), do: TemplateReads.session_templates(caller, name)
      def registry(caller), do: OperatorReads.registry_all(caller)
      def members(caller, s), do: SessionReads.members(caller, s)
      def store(name), do: Ezagent.Workspace.Store.get_by_name(name)
      def lookup(uri), do: Ezagent.KindRegistry.lookup(uri)
      def plugins, do: Ezagent.PluginRegistry.list_all()
      def user_by_uri(uri), do: Ezagent.Users.get_by_uri(uri)
      def flavors, do: Ezagent.AgentFlavorRegistry.list_all()
    end
    """

    assert offenses_in_source(benign, "fixture") == []
  end

  test "the chokepoint modules exist outside the scanned tiers (the doors exist)" do
    for rel <- [
          "apps/ezagent_domain_workspace/lib/ezagent/workspace/workspace_reads.ex",
          "apps/ezagent_domain_workspace/lib/ezagent/workspace/user_reads.ex",
          "apps/ezagent_domain_session/lib/ezagent/session/template_reads.ex",
          "apps/ezagent_domain_identity/lib/ezagent/identity/operator_reads.ex",
          "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex"
        ] do
      assert File.regular?(Path.join(@repo_root, rel)),
             "chokepoint module missing: #{rel}"
    end
  end

  # ----- AST scan --------------------------------------------------------------

  defp offenders_in_file(path) do
    offenses_in_source(File.read!(path), Path.relative_to(path, @repo_root))
  end

  defp offenses_in_source(source, rel) do
    case Code.string_to_quoted(source) do
      {:ok, ast0} ->
        # Expand pipes first so `x |> Mod.fun()` reads as `Mod.fun(x)`.
        ast = AstScan.expand_pipes(ast0)
        aliases = AstScan.collect_aliases(ast)
        imports = AstScan.collect_imports(ast)
        local_defs = collect_local_defs(ast)

        ast
        |> collect_offenses(aliases, imports, local_defs)
        |> Enum.map(fn {line, desc} -> "#{rel}:#{line}: #{desc}" end)

      {:error, _} ->
        []
    end
  end

  defp collect_offenses(ast, aliases, imports, local_defs) do
    {_, offenses} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, offense_for(node, aliases, imports, local_defs) ++ acc}
      end)

    Enum.reverse(offenses)
  end

  # Locally-defined `{fun, arity}` set (def/defp heads) — a bare call matching
  # a LOCAL definition is not an imported call (local defs shadow imports), so
  # Rule 2 must skip it. Also keeps def HEADS themselves out of Rule 2.
  defp collect_local_defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {kind, _, [head | _]} = node, acc when kind in [:def, :defp] ->
          {node, MapSet.put(acc, head_fun_arity(head))}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp head_fun_arity({:when, _, [call | _]}), do: head_fun_arity(call)
  defp head_fun_arity({fun, _, args}) when is_atom(fun) and is_list(args), do: {fun, length(args)}
  defp head_fun_arity({fun, _, _}) when is_atom(fun), do: {fun, 0}
  defp head_fun_arity(_), do: {nil, -1}

  # Rule 0 — QUALIFIED dynamic dispatch: `Kernel.apply(Mod, :fun, …)` or
  # `:erlang.apply(Mod, :fun, …)` with a literal banned target. This clause
  # MUST precede Rule 1: the qualified-apply call is itself a remote call
  # whose `{mod, fun}` (`Kernel.apply` / `:erlang.apply`) is NOT banned —
  # Rule 1 would match the node first and return [] without ever inspecting
  # the dispatch TARGET. Arity handling mirrors Rule 4: literal args list →
  # length; non-literal → `:any`; the 2-arity form dispatches with NO args,
  # so only 0-arity banned primitives can match it.
  defp offense_for({{:., _, [via, :apply]}, meta, [modast, fun]}, aliases, _imports, _local_defs)
       when is_atom(fun) do
    qualified_apply_offense(via, modast, fun, 0, meta, aliases)
  end

  defp offense_for({{:., _, [via, :apply]}, meta, [modast, fun, args]}, aliases, _imports, _local_defs)
       when is_atom(fun) do
    arity = if is_list(args), do: length(args), else: :any
    qualified_apply_offense(via, modast, fun, arity, meta, aliases)
  end

  # Rule 1 — remote call `<Mod>.<banned>(args…)`: `Mod` resolves (via aliases +
  # `Elixir.` normalization) to a banned module and `{mod, fun, arity}` is
  # banned. `args` nil (a no-parens remote reference) is flagged too.
  defp offense_for({{:., _, [modast, fun]}, meta, args}, aliases, _imports, _local_defs)
       when is_atom(fun) and (is_list(args) or is_nil(args)) do
    arity = if is_list(args), do: length(args), else: nil

    case banned_match(modast, fun, arity, aliases) do
      {mod, fun, arity} ->
        [
          {AstScan.line_of(meta),
           "#{format_mod(mod)}.#{fun}/#{arity} — route through the caller-authorizing list chokepoint"}
        ]

      nil ->
        []
    end
  end

  # Rule 3 — function capture `&Mod.fun/arity` (qualified, root-qualified, or
  # imported-bare `&fun/arity`).
  defp offense_for(
         {:&, meta, [{:/, _, [{{:., _, [modast, fun]}, _, _}, arity]}]},
         aliases,
         _imports,
         _local_defs
       )
       when is_atom(fun) and is_integer(arity) do
    case banned_match(modast, fun, arity, aliases) do
      {mod, fun, arity} ->
        [
          {AstScan.line_of(meta),
           "capture &#{format_mod(mod)}.#{fun}/#{arity} — route through the caller-authorizing list chokepoint"}
        ]

      nil ->
        []
    end
  end

  defp offense_for({:&, meta, [{:/, _, [{fun, _, _}, arity]}]}, _aliases, imports, local_defs)
       when is_atom(fun) and is_integer(arity) do
    cond do
      MapSet.member?(local_defs, {fun, arity}) ->
        []

      match = Enum.find(imports, &banned_import?(&1, fun, arity)) ->
        resolved = AstScan.resolve(match, %{}, &normalize/1)

        [
          {AstScan.line_of(meta),
           "capture of imported &#{fun}/#{arity} from #{format_mod(resolved)} — route through the caller-authorizing list chokepoint"}
        ]

      true ->
        []
    end
  end

  # Rule 4 — dynamic dispatch `apply(Mod, :fun, args)`. Arity from a literal
  # list; a non-literal args expression is flagged on module+fun alone (the
  # call cannot be arity-verified statically, and the fun name already names a
  # banned enumeration).
  defp offense_for({:apply, meta, [modast, fun, args]}, aliases, _imports, _local_defs)
       when is_atom(fun) do
    arity = if is_list(args), do: length(args), else: :any

    case banned_match(modast, fun, arity, aliases) do
      {mod, fun, _arity} ->
        [
          {AstScan.line_of(meta),
           "apply(#{format_mod(mod)}, :#{fun}, …) — route through the caller-authorizing list chokepoint"}
        ]

      nil ->
        []
    end
  end

  # Rule 4b — `apply(Mod, :fun)` with NO args list: dispatches with zero
  # arguments, so only 0-arity banned primitives can match.
  defp offense_for({:apply, meta, [modast, fun]}, aliases, _imports, _local_defs)
       when is_atom(fun) do
    case banned_match(modast, fun, 0, aliases) do
      {mod, fun, _arity} ->
        [
          {AstScan.line_of(meta),
           "apply(#{format_mod(mod)}, :#{fun}) — route through the caller-authorizing list chokepoint"}
        ]

      nil ->
        []
    end
  end

  # Rule 2 — imported bare call: the file `import`s a banned module and calls
  # the banned fun unqualified. A bare call matching a LOCAL def is the local
  # function (local defs shadow imports) — skipped.
  defp offense_for({fun, meta, args}, _aliases, imports, local_defs)
       when is_atom(fun) and is_list(args) and fun not in [:&, :apply] do
    arity = length(args)

    cond do
      MapSet.member?(local_defs, {fun, arity}) ->
        []

      match = Enum.find(imports, &banned_import?(&1, fun, arity)) ->
        resolved = AstScan.resolve(match, %{}, &normalize/1)

        [
          {AstScan.line_of(meta),
           "imported bare #{fun}/#{arity} from #{format_mod(resolved)} — route through the caller-authorizing list chokepoint"}
        ]

      true ->
        []
    end
  end

  defp offense_for(_node, _aliases, _imports, _local_defs), do: []

  # Rule 0 helper — flag `Kernel.apply` / `:erlang.apply` dispatching to a
  # literal banned target; anything else is not this rule's concern.
  defp qualified_apply_offense(via, modast, fun, arity, meta, aliases) do
    with true <- apply_via?(via, aliases),
         {mod, fun, _arity} <- banned_match(modast, fun, arity, aliases) do
      [
        {AstScan.line_of(meta),
         "#{format_via(via)}.apply(#{format_mod(mod)}, :#{fun}, …) — route through the caller-authorizing list chokepoint"}
      ]
    else
      _ -> []
    end
  end

  # The two modules bare `apply/2,3` can be qualified through: `Kernel`
  # (also `Elixir.`-prefixed or `alias`ed) and `:erlang`.
  defp apply_via?(:erlang, _aliases), do: true

  defp apply_via?({:__aliases__, _, _} = modast, aliases),
    do: resolve_mod(modast, aliases) == [:Kernel]

  defp apply_via?(_other, _aliases), do: false

  defp format_via(:erlang), do: ":erlang"
  defp format_via({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  # `{mod, fun, arity}` when modast resolves to a banned module and fun/arity
  # match a banned primitive (`:any` arity matches any banned arity of fun).
  defp banned_match(modast, fun, arity, aliases) do
    resolved = resolve_mod(modast, aliases)

    Enum.find(@banned_primitives, fn
      {^resolved, ^fun, banned_arity} -> arity == :any or arity == banned_arity or is_nil(arity)
      _ -> false
    end)
  end

  defp banned_import?(import_parts, fun, arity) do
    resolved = AstScan.resolve(import_parts, %{}, &normalize/1)

    Enum.any?(@banned_primitives, fn
      {^resolved, ^fun, banned_arity} -> arity == banned_arity
      _ -> false
    end)
  end

  defp resolve_mod({:__aliases__, _, parts}, aliases),
    do: AstScan.resolve(parts, aliases, &normalize/1)

  defp resolve_mod(_other, _aliases), do: nil

  # Bare single-segment names in this codebase default to their canonical
  # homes, so a missing explicit `alias` line doesn't create a false negative.
  defp normalize([:KindRegistry]), do: [:Ezagent, :KindRegistry]
  defp normalize([:KindSnapshot]), do: [:Ezagent, :Ecto, :KindSnapshot]
  defp normalize([:Users]), do: [:Ezagent, :Users]
  # `Agent` here means Ezagent.Entity.Agent — the stdlib `Agent` has no
  # `list_in_workspace/1`, and an explicit `alias …, as: Agent` wins via
  # the alias map BEFORE this hook runs, so no false positive is possible.
  defp normalize([:Agent]), do: [:Ezagent, :Entity, :Agent]
  defp normalize(parts), do: parts

  defp format_mod(nil), do: "<unknown>"
  defp format_mod(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)
end
