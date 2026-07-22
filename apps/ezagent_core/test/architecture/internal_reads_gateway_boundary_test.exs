defmodule EzagentCore.InternalReadsGatewayBoundaryTest do
  @moduledoc """
  Read-plane-authz PR-5 (Pillar B) — the `Ezagent.Session.InternalReads`
  gateway TWO-SIDED boundary (design §3.4 —
  `docs/superpowers/specs/2026-07-19-read-plane-authz-chokepoint-design.md`).

  Framework-internal reads with NO principal (delivery replay, reconcile,
  GC, boot, snapshot-rehydrate) route through the dedicated narrow gateway
  `Ezagent.Session.InternalReads` — never through a blanket "this whole
  module is exempt". The gateway is a boundary in BOTH directions:

    * **OUTBOUND (design §3.3)** — the gated raw-store read functions (the
      `MessageStore` windowed reads + the workspace enumeration primitives)
      are callable only from {the read chokepoints, `InternalReads`}. The
      PR-1..4 gates already pin the presenter tiers to the chokepoints; the
      outbound scan below pins the FRAMEWORK tier (`ezagent_domain_session`)
      to the gateway. A direct raw-store read added anywhere in that tier →
      this test RED.
    * **INBOUND (design §3.4)** — `InternalReads` may be CALLED only from
      the enumerated framework-internal caller tier
      (`@allowed_caller_modules`: session delivery replay + session
      reconcile). A principal-facing module (LiveView loader, controller,
      chokepoint caller) calling `InternalReads` → this test RED. This side
      is what stops the gateway becoming a LAUNDERING path around
      `SessionReads` (acceptance criterion #12).

  ## Module-keyed, not path-keyed

  Unlike the PR-1..4 basename allowlists, both boundaries here key on the
  resolved caller MODULE (design §3.3: "small stable module sets, NOT
  paths"): a file is exempt only if EVERY module it defines is allowlisted.

  ## AST-based + evasion-hardened

  Same matcher family as the PR-4 list gate (`alias` renaming,
  root-qualification, `import`ed bare calls, captures, `apply/2,3` incl.
  `Kernel.`/`:erlang.`-qualified, pipes, line splits) via
  `EzagentCore.AstScan`. The module-variable indirection limitation
  (`m = Ezagent.Session.InternalReads; m.messages_since(...)`) is NOT
  caught — pinned by a test below, same as the list gate.

  ## Deliberately NOT covered here (plan-PR-5 follow-ups)

  The session-STATE plane residual (`Kind.get_slice(_, :session)` reads in
  the presenter tier — `uninstall_socialware`, `AnonTakeover`
  split-then-relocate), the recipe/template content plane, and the
  `KindSnapshot`-scanning boot migrations are out of THIS gate's scope; the
  plan's rollout tightens each plane as its piece lands. This gate owns the
  two-sided boundary of the gateway itself.
  """
  use ExUnit.Case, async: true

  alias EzagentCore.AstScan

  @repo_root Path.expand("../../../..", __DIR__)

  @gateway [:Ezagent, :Session, :InternalReads]
  @gateway_rel "apps/ezagent_domain_session/lib/ezagent/session/internal_reads.ex"

  # INBOUND allowlist (design §3.4) — the enumerated framework-internal
  # caller tier, module-keyed. Adding a module = a written justification
  # that the caller is framework-internal with NO principal; a
  # principal-facing caller must go through a chokepoint instead.
  @allowed_caller_modules [
    [:Ezagent, :ActionSet, :Session, :Delivery],
    [:Ezagent, :ActionSet, :Session, :MemberCap],
    [:Ezagent, :ActionSet, :Session, :Reconcile]
  ]

  # The files the allowed caller modules live in (anti-vacuity + sync check).
  @allowed_caller_files [
    "apps/ezagent_domain_session/lib/ezagent/behavior/session/delivery.ex",
    "apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex",
    "apps/ezagent_domain_session/lib/ezagent/behavior/session/reconcile.ex"
  ]

  # The gateway's public surface — ratcheted NARROW (design §3.4: "a
  # dedicated NARROW gateway module"). Adding a function = adding laundering
  # surface; this ratchet forces the red-build review.
  @gateway_surface %{
    messages_since: 2,
    current_message_sequence: 1,
    messages_after_sequence: 2,
    users_in_workspace: 1,
    agents_in_workspace: 1
  }

  # OUTBOUND gated set (design §3.3) — raw-store read functions callable
  # only from {the read chokepoints, `InternalReads`}: the MessageStore
  # windowed reads (the PR-1 message plane) + the workspace enumeration
  # primitives the reconcile candidate scan uses (the PR-4 list plane).
  @gated_raw_reads [
    {[:Ezagent, :MessageStore], :recent_in_session, 2},
    {[:Ezagent, :MessageStore], :recent_visible_in_session, 2},
    {[:Ezagent, :MessageStore], :older_than, 3},
    {[:Ezagent, :MessageStore], :older_visible_than, 3},
    {[:Ezagent, :MessageStore], :chat_visible_recent, 2},
    {[:Ezagent, :MessageStore], :committed_external_visible, 2},
    {[:Ezagent, :MessageStore], :committed_external_visible_by_ids, 2},
    {[:Ezagent, :MessageStore], :in_session_since, 2},
    {[:Ezagent, :MessageStore], :current_session_sequence, 1},
    {[:Ezagent, :MessageStore], :in_session_after_sequence, 2},
    {[:Ezagent, :Users], :list_all, 0},
    {[:Ezagent, :Users], :list_in_workspace, 1},
    {[:Ezagent, :Entity, :Agent], :list_in_workspace, 1}
  ]

  # The framework tier the OUTBOUND scan owns. (Presenter tiers are already
  # owned by the PR-1..4 gates; the union over all gates is "callable only
  # from {chokepoints, InternalReads}".)
  @framework_scan_dirs ["apps/ezagent_domain_session/lib"]

  # ----- the two-sided boundary --------------------------------------------

  test "OUTBOUND: in the framework tier the gated raw-store reads are callable only from InternalReads" do
    offenders =
      @framework_scan_dirs
      |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**/*.ex"])))
      |> Enum.flat_map(&offenses_in_file(&1, :outbound))

    assert offenders == [],
           """
           Read-plane InternalReads OUTBOUND gate (design §3.3/§3.4): a
           framework-tier module calls a gated raw-store read DIRECTLY. A
           framework-internal read with no principal routes through
           `Ezagent.Session.InternalReads`; a principal-facing read routes
           through the caller-authorizing chokepoints. Offenders:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "INBOUND: InternalReads is callable only from the enumerated framework-internal caller tier" do
    offenders =
      [Path.join(@repo_root, "apps/*/lib/**/*.ex")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(&offenses_in_file(&1, :inbound))

    assert offenders == [],
           """
           Read-plane InternalReads INBOUND gate (design §3.4): a module OUTSIDE
           the enumerated framework-internal caller tier calls the InternalReads
           gateway. A principal-facing caller LAUNDERS around the SessionReads
           chokepoint — route it through the caller-authorizing chokepoint
           instead. Offenders:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  # ----- anti-vacuity --------------------------------------------------------

  test "the gateway module exists (the door exists)" do
    assert File.regular?(Path.join(@repo_root, @gateway_rel))
  end

  test "the enumerated inbound callers DO call the gateway (anti-vacuity)" do
    for rel <- @allowed_caller_files do
      offenses = offenses_in_file(Path.join(@repo_root, rel), :inbound, [])

      assert offenses != [],
             "expected #{rel} to call InternalReads (allowlist disabled) — " <>
               "if the caller stopped using the gateway, shrink @allowed_caller_modules"
    end
  end

  test "the inbound allowlist is module-keyed and in sync with the caller files" do
    for rel <- @allowed_caller_files do
      ast = @repo_root |> Path.join(rel) |> File.read!() |> Code.string_to_quoted!()
      modules = collect_defmodules(ast, AstScan.collect_aliases(ast))

      assert modules != [] and Enum.all?(modules, &(&1 in @allowed_caller_modules)),
             "#{rel} defines #{inspect(modules)} — keep @allowed_caller_modules " <>
               "and @allowed_caller_files in sync"
    end
  end

  test "the gateway's public surface stays NARROW (ratchet)" do
    ast = @repo_root |> Path.join(@gateway_rel) |> File.read!() |> Code.string_to_quoted!()

    assert public_defs(ast) == MapSet.new(@gateway_surface),
           "Ezagent.Session.InternalReads grew a new public function — the gateway " <>
             "must stay NARROW (design §3.4); extending it is a reviewed, deliberate act"
  end

  # ----- fails-closed fixtures (acceptance #12) -------------------------------

  test "FAILS-CLOSED: a principal-facing module calling InternalReads is flagged (criterion #12)" do
    fixtures = [
      {"LiveView loader (fully-qualified)",
       """
       defmodule EzagentWeb.WorldLive do
         def load(s, t), do: Ezagent.Session.InternalReads.messages_since(s, t)
       end
       """},
      {"world presenter (aliased + piped)",
       """
       defmodule Ezagent.World.ConversationData do
         alias Ezagent.Session.InternalReads, as: IR
         def load(ws), do: ws |> IR.users_in_workspace()
       end
       """},
      {"controller (imported bare call)",
       """
       defmodule EzagentWeb.UploadsController do
         import Ezagent.Session.InternalReads
         def go(ws), do: agents_in_workspace(ws)
       end
       """},
      {"chokepoint caller (capture)",
       """
       defmodule Ezagent.World.KanbanData do
         alias Ezagent.Session.InternalReads
         def go, do: &InternalReads.messages_since/2
       end
       """},
      {"admin LiveView (apply/3)",
       """
       defmodule EzagentWeb.AdminLive do
         def go(s, t), do: apply(Ezagent.Session.InternalReads, :messages_since, [s, t])
       end
       """},
      {"ops LiveView (Kernel.apply)",
       """
       defmodule EzagentWeb.OpsLive do
         def go(s, t), do: Kernel.apply(Ezagent.Session.InternalReads, :messages_since, [s, t])
       end
       """},
      {"controller (:erlang.apply)",
       """
       defmodule EzagentWeb.FeedController do
         def go(s, t), do: :erlang.apply(Ezagent.Session.InternalReads, :messages_since, [s, t])
       end
       """},
      {"LiveView (root-qualified Elixir.)",
       """
       defmodule EzagentWeb.RootLive do
         def go(s, t), do: Elixir.Ezagent.Session.InternalReads.messages_since(s, t)
       end
       """}
    ]

    for {label, src} <- fixtures do
      assert offenses_in_source(src, "fixture", :inbound) != [],
             "INBOUND gate must flag a principal-facing caller (#{label}):\n#{src}"
    end
  end

  test "OUTBOUND fixtures: disguised raw-store reads in the framework tier are flagged" do
    fixtures = [
      {"aliased MessageStore read",
       """
       defmodule Ezagent.ActionSet.Session.Sneaky do
         alias Ezagent.MessageStore, as: Store
         def peek(s, t), do: Store.in_session_since(s, t)
       end
       """},
      {"imported bare enumeration",
       """
       defmodule Ezagent.Session.Sneaky do
         import Ezagent.Users
         def peek(ws), do: list_in_workspace(ws)
       end
       """},
      {"capture of the agent enumeration",
       """
       defmodule Ezagent.Session.Sneaky2 do
         def go, do: &Ezagent.Entity.Agent.list_in_workspace/1
       end
       """},
      {"apply of a gated read",
       """
       defmodule Ezagent.Session.Sneaky3 do
         def go(s, t), do: apply(Ezagent.MessageStore, :in_session_since, [s, t])
       end
       """},
      {"piped gated enumeration",
       """
       defmodule Ezagent.Session.Sneaky4 do
         alias Ezagent.Users
         def go(ws), do: ws |> Users.list_in_workspace()
       end
       """}
    ]

    for {label, src} <- fixtures do
      assert offenses_in_source(src, "fixture", :outbound) != [],
             "OUTBOUND gate must flag a disguised raw-store read (#{label}):\n#{src}"
    end
  end

  test "no false positives: chokepoint calls, gateway calls, and non-gated reads pass clean" do
    benign_inbound = """
    defmodule EzagentWeb.WorldLive do
      alias Ezagent.Socialware.SessionReads
      def read(caller, s), do: SessionReads.messages(caller, s, :conversation, %{limit: 50})
      def session_state(s), do: Ezagent.Kind.get_slice(s, :session)
    end
    """

    assert offenses_in_source(benign_inbound, "fixture", :inbound) == []

    benign_outbound = """
    defmodule Ezagent.Session.Helper do
      alias Ezagent.Session.InternalReads
      def via_gateway(s, t), do: InternalReads.messages_since(s, t)
      def write(msg), do: Ezagent.MessageStore.write(msg, [])
      def one_user(uri), do: Ezagent.Users.get_by_uri(uri)
    end
    """

    assert offenses_in_source(benign_outbound, "fixture", :outbound) == []
  end

  test "KNOWN LIMITATION: module-variable indirection is NOT caught (documented, not claimed)" do
    # Same limitation as the list gate: `m = Ezagent.Session.InternalReads;
    # m.messages_since(...)` dispatches through a runtime binding; resolving
    # it soundly needs flow analysis this gate does not attempt. If the
    # matcher is ever upgraded, flip this assertion and update the moduledoc.
    src = """
    defmodule Evasion do
      def go(s, t) do
        m = Ezagent.Session.InternalReads
        m.messages_since(s, t)
      end
    end
    """

    assert offenses_in_source(src, "fixture", :inbound) == [],
           "matcher now catches module-variable indirection? Update the moduledoc and flip this test."
  end

  # ----- AST scan --------------------------------------------------------------

  defp offenses_in_file(path, mode, allowed_override \\ nil) do
    offenses_in_source(
      File.read!(path),
      Path.relative_to(path, @repo_root),
      mode,
      allowed_override
    )
  end

  # A file is exempt from a boundary scan only when EVERY module it defines
  # is on that boundary's allowlist (module-keyed exemption — a sneaky
  # sibling module in the same file does NOT inherit the exemption).
  defp offenses_in_source(source, rel, mode, allowed_override \\ nil) do
    case Code.string_to_quoted(source) do
      {:ok, ast0} ->
        ast = AstScan.expand_pipes(ast0)
        aliases = AstScan.collect_aliases(ast)
        imports = AstScan.collect_imports(ast)
        local_defs = collect_local_defs(ast)
        defmodules = collect_defmodules(ast, aliases)
        allowed = allowed_override || allowed_modules(mode)

        if defmodules != [] and Enum.all?(defmodules, &(&1 in allowed)) do
          []
        else
          ast
          |> collect_offenses(aliases, imports, local_defs, mode)
          |> Enum.map(fn {line, desc} -> "#{rel}:#{line}: #{desc}" end)
        end

      {:error, _} ->
        []
    end
  end

  defp allowed_modules(:inbound), do: @allowed_caller_modules
  defp allowed_modules(:outbound), do: [@gateway]

  defp collect_defmodules(ast, aliases) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts} | _]} = node, acc ->
          {node, [AstScan.resolve(parts, aliases, &normalize/1) | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp public_defs(ast) do
    {_, acc} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:def, _, [head | _]} = node, acc -> {node, MapSet.put(acc, head_fun_arity(head))}
        node, acc -> {node, acc}
      end)

    acc
  end

  # Locally-defined `{fun, arity}` set (def/defp heads) — a bare call matching
  # a LOCAL definition is not an imported call (local defs shadow imports).
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

  defp collect_offenses(ast, aliases, imports, local_defs, mode) do
    {_, offenses} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, offense_for(node, aliases, imports, local_defs, mode) ++ acc}
      end)

    Enum.reverse(offenses)
  end

  # Rule 0 — QUALIFIED dynamic dispatch: `Kernel.apply(Mod, :fun, …)` or
  # `:erlang.apply(Mod, :fun, …)` with a literal gated target. MUST precede
  # Rule 1 (the qualified-apply call is itself a non-gated remote call).
  defp offense_for(
         {{:., _, [via, :apply]}, meta, [modast, fun]},
         aliases,
         _imports,
         _local_defs,
         mode
       )
       when is_atom(fun) do
    qualified_apply_offense(via, modast, fun, 0, meta, aliases, mode)
  end

  defp offense_for(
         {{:., _, [via, :apply]}, meta, [modast, fun, args]},
         aliases,
         _imports,
         _local_defs,
         mode
       )
       when is_atom(fun) do
    arity = if is_list(args), do: length(args), else: :any
    qualified_apply_offense(via, modast, fun, arity, meta, aliases, mode)
  end

  # Rule 1 — remote call `<Mod>.<fun>(args…)` on a gated target. A no-parens
  # remote reference (`args` nil) is flagged too.
  defp offense_for({{:., _, [modast, fun]}, meta, args}, aliases, _imports, _local_defs, mode)
       when is_atom(fun) and (is_list(args) or is_nil(args)) do
    arity = if is_list(args), do: length(args), else: nil

    case banned_match(modast, fun, arity, aliases, mode) do
      {:ok, desc} -> [{AstScan.line_of(meta), desc}]
      nil -> []
    end
  end

  # Rule 3 — function capture `&Mod.fun/arity` (qualified or root-qualified).
  defp offense_for(
         {:&, meta, [{:/, _, [{{:., _, [modast, fun]}, _, _}, arity]}]},
         aliases,
         _imports,
         _local_defs,
         mode
       )
       when is_atom(fun) and is_integer(arity) do
    case banned_match(modast, fun, arity, aliases, mode) do
      {:ok, desc} -> [{AstScan.line_of(meta), "capture — " <> desc}]
      nil -> []
    end
  end

  # Rule 3b — imported bare capture `&fun/arity`.
  defp offense_for(
         {:&, meta, [{:/, _, [{fun, _, _}, arity]}]},
         _aliases,
         imports,
         local_defs,
         mode
       )
       when is_atom(fun) and is_integer(arity) do
    cond do
      MapSet.member?(local_defs, {fun, arity}) ->
        []

      match = Enum.find(imports, &banned_import?(&1, fun, arity, mode)) ->
        resolved = AstScan.resolve(match, %{}, &normalize/1)

        [
          {AstScan.line_of(meta),
           "capture of imported &#{fun}/#{arity} from #{format_mod(resolved)} — " <>
             boundary(mode)}
        ]

      true ->
        []
    end
  end

  # Rule 4 — dynamic dispatch `apply(Mod, :fun, args)`.
  defp offense_for({:apply, meta, [modast, fun, args]}, aliases, _imports, _local_defs, mode)
       when is_atom(fun) do
    arity = if is_list(args), do: length(args), else: :any

    case banned_match(modast, fun, arity, aliases, mode) do
      {:ok, desc} -> [{AstScan.line_of(meta), "apply — " <> desc}]
      nil -> []
    end
  end

  # Rule 4b — `apply(Mod, :fun)` with NO args list (zero-argument dispatch).
  defp offense_for({:apply, meta, [modast, fun]}, aliases, _imports, _local_defs, mode)
       when is_atom(fun) do
    case banned_match(modast, fun, 0, aliases, mode) do
      {:ok, desc} -> [{AstScan.line_of(meta), "apply/2 — " <> desc}]
      nil -> []
    end
  end

  # Rule 2 — imported bare call: the file `import`s a gated module and calls
  # the gated fun unqualified. A bare call matching a LOCAL def is skipped.
  defp offense_for({fun, meta, args}, _aliases, imports, local_defs, mode)
       when is_atom(fun) and is_list(args) and fun not in [:&, :apply] do
    arity = length(args)

    cond do
      MapSet.member?(local_defs, {fun, arity}) ->
        []

      match = Enum.find(imports, &banned_import?(&1, fun, arity, mode)) ->
        resolved = AstScan.resolve(match, %{}, &normalize/1)

        [
          {AstScan.line_of(meta),
           "imported bare #{fun}/#{arity} from #{format_mod(resolved)} — " <> boundary(mode)}
        ]

      true ->
        []
    end
  end

  defp offense_for(_node, _aliases, _imports, _local_defs, _mode), do: []

  # INBOUND — ANY call resolving to the gateway module is gated (the offense
  # is calling the gateway at all, regardless of fun/arity).
  defp banned_match(modast, fun, _arity, aliases, :inbound) do
    if resolve_mod(modast, aliases) == @gateway do
      {:ok, "Ezagent.Session.InternalReads.#{fun} — " <> boundary(:inbound)}
    else
      nil
    end
  end

  # OUTBOUND — `{mod, fun, arity}` must match the gated raw-read set exactly
  # (`:any`/nil arity from an unverifiable dynamic call matches on mod+fun).
  defp banned_match(modast, fun, arity, aliases, :outbound) do
    resolved = resolve_mod(modast, aliases)

    case Enum.find(@gated_raw_reads, fn
           {^resolved, ^fun, banned_arity} ->
             arity == :any or is_nil(arity) or arity == banned_arity

           _ ->
             false
         end) do
      {mod, fun, banned_arity} ->
        {:ok, "#{format_mod(mod)}.#{fun}/#{banned_arity} — " <> boundary(:outbound)}

      nil ->
        nil
    end
  end

  defp banned_import?(import_parts, fun, arity, :inbound) do
    AstScan.resolve(import_parts, %{}, &normalize/1) == @gateway and
      Map.get(@gateway_surface, fun) == arity
  end

  defp banned_import?(import_parts, fun, arity, :outbound) do
    resolved = AstScan.resolve(import_parts, %{}, &normalize/1)

    Enum.any?(@gated_raw_reads, fn
      {^resolved, ^fun, ^arity} -> true
      _ -> false
    end)
  end

  defp boundary(:inbound),
    do:
      "the InternalReads gateway may be called ONLY from the enumerated " <>
        "framework-internal caller tier (design §3.4) — a principal-facing caller " <>
        "launders around SessionReads"

  defp boundary(:outbound),
    do:
      "gated raw-store read — callable only from {the read chokepoints, " <>
        "Ezagent.Session.InternalReads} (design §3.3/§3.4)"

  # Rule 0 helper — flag `Kernel.apply` / `:erlang.apply` dispatching to a
  # literal gated target; anything else is not this rule's concern.
  defp qualified_apply_offense(via, modast, fun, arity, meta, aliases, mode) do
    with true <- apply_via?(via, aliases),
         {:ok, desc} <- banned_match(modast, fun, arity, aliases, mode) do
      [{AstScan.line_of(meta), "#{format_via(via)}.apply — " <> desc}]
    else
      _ -> []
    end
  end

  defp apply_via?(:erlang, _aliases), do: true

  defp apply_via?({:__aliases__, _, _} = modast, aliases),
    do: resolve_mod(modast, aliases) == [:Kernel]

  defp apply_via?(_other, _aliases), do: false

  defp format_via(:erlang), do: ":erlang"
  defp format_via({:__aliases__, _, parts}), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp resolve_mod({:__aliases__, _, parts}, aliases),
    do: AstScan.resolve(parts, aliases, &normalize/1)

  defp resolve_mod(_other, _aliases), do: nil

  # Bare single-segment names default to their canonical homes, so a missing
  # explicit `alias` line doesn't create a false negative. An explicit
  # `alias …, as: X` wins via the alias map BEFORE this hook runs.
  defp normalize([:InternalReads]), do: @gateway
  defp normalize([:MessageStore]), do: [:Ezagent, :MessageStore]
  defp normalize([:Users]), do: [:Ezagent, :Users]
  # `Agent` here means Ezagent.Entity.Agent — the stdlib `Agent` has no
  # `list_in_workspace/1`, so no false positive is possible (same tradeoff
  # as the PR-4 list gate).
  defp normalize([:Agent]), do: [:Ezagent, :Entity, :Agent]
  defp normalize(parts), do: parts

  defp format_mod(nil), do: "<unknown>"
  defp format_mod(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)
end
