Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.MemberCapGrantSeamTest do
  use ExUnit.Case, async: true

  @moduledoc """
  §14 test 35 (spec Part C / Task C.5) — the member-cap grant SEAM invariant.

  Threat X (co-tenant credential theft) is closed by the admission gate at the ONE
  `handle_join` → `do_join_apply` seam (Part C). The runtime fix closes today's entry
  paths; THIS arch-fitness invariant prevents a future dev from re-opening the CLASS
  by minting the universal member-cap `cap(:session, Session, :receive, S)` — the
  R1.1 receive authority whose grant IS the credential-spend enabler — from a NEW,
  un-gated module.

  Invariant: the 5-arg member-cap SHAPE `*.Capability.cap(:session, <SessionBehavior>,
  :receive, session, ws)` is CONSTRUCTED only in the sanctioned modules — the gated
  at-join grant seam plus the SYSTEM-AUTHORITY seed paths (reconcile + migration, which
  run under system authority on a cold/loaded Kind, NOT a caller-initiated add, and so
  are correctly outside the admission gate per spec §C.1). Any other module building
  the member-cap trips this gate. (The 3-arg required-cap DSL declaration in
  `behavior.ex`, `cap(:session, __MODULE__, :receive)`, is not a grant and is excluded
  by the ≥4-arg shape.)

  Scope note (no silent cap): this is the GRANT-shape signal. A future bypass that
  reconstructs the exact 5 fields WITHOUT the `Capability.cap` constructor (e.g. a
  hand-built `%Capability{}` struct literal) is out of this signal's scope — a tracked
  follow-up (widen to struct-literal detection). The primary threat-X closure is proven
  by the §14.5(A) acceptance + the C.1 gate tests; this is defense-in-depth against the
  entry-path CLASS. Same pattern as the domain-only-Kinds fitness gate.
  """

  @repo_root Path.expand("../../../..", __DIR__)
  @scanned_globs ["apps/*/lib/**/*.ex"]

  # The sanctioned member-cap construction sites: the gated at-join grant seam plus
  # the two system-authority seed paths (reconcile + migration). Widen ONLY for a
  # legitimate new system-authority seed, with a rationale.
  @allowlist [
    # The gated at-join grant seam (Part C admission gate sits at its caller `do_join`).
    "apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex",
    # System-authority reconcile seed ("caps win" on a cold/loaded Kind — not a
    # caller-initiated add, correctly outside the admission gate per spec §C.1).
    "apps/ezagent_domain_session/lib/ezagent/behavior/session/reconcile.ex",
    # System-authority one-shot migration backfill (A1.4).
    "apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex"
  ]

  test "the member-cap shape is constructed only in the sanctioned grant/seed seam (test 35)" do
    offenders =
      @scanned_globs
      |> scan()
      |> Enum.reject(fn {rel, _} -> rel in @allowlist end)

    assert offenders == [],
           """
           A member-cap `cap(:session, <Session>, :receive, session, ws)` is constructed
           OUTSIDE the sanctioned grant/seed seam. The member-cap is the R1.1 receive
           authority — minting it off the gated `handle_join`→`do_join_apply` seam
           re-opens threat X (a co-tenant could grant an agent receive without the
           owner-approval admission gate). Grant it via `Session.MemberCap.grant_at_join/2`
           (the gated seam) instead. If this is a legitimate new SYSTEM-AUTHORITY seed
           (not a caller-initiated add), add it to @allowlist with a rationale. Offenders:
           #{format(offenders)}
           """
  end

  test "scanner detects a planted member-cap grant bypass (gate is not a no-op)" do
    # A module that mints the member-cap OUTSIDE the seam — the exact re-opening this
    # gate must catch. The 3-arg DSL declaration and the :send cap must be ignored.
    snippet = ~S'''
    defmodule Sneaky.Bypass do
      def grant(session, ws, member) do
        cap = Ezagent.Capability.cap(:session, Ezagent.ActionSet.Session, :receive, session, ws)
        Ezagent.Identity.Grant.grant_cap_via_router(member, cap, {:rule, :x, member}, :sync)
      end

      def decl, do: Ezagent.Capability.cap(:session, __MODULE__, :receive)
      def other(s, ws), do: Ezagent.Capability.cap(:session, Ezagent.ActionSet.Session, :send, s, ws)
    end
    '''

    offenders = scan_source(snippet, "sneaky/bypass.ex")

    assert offenders == [{"sneaky/bypass.ex", :member_cap_construction}],
           "the planted 5-arg member-cap grant must trip the gate exactly once " <>
             "(3-arg DSL decl + :send cap must be ignored); got: #{inspect(offenders)}"
  end

  # ── scanner ───────────────────────────────────────────────────────────────

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
    |> member_cap_constructions()
    |> Enum.map(fn :member_cap_construction -> {rel, :member_cap_construction} end)
  rescue
    e -> flunk("AST parse failed for #{rel}: #{Exception.message(e)}")
  end

  # Every `*.Capability.cap(:session, _behavior, :receive, _instance, _ws, ...)` call —
  # the 5-arg (or more) member-cap SHAPE. Matched by trailing alias `:Capability` +
  # fun `:cap` + first arg `:session` + third arg `:receive` + arity ≥ 4.
  defp member_cap_constructions(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mods}, :cap]}, _, args} = node, acc ->
          if List.last(mods) == :Capability and member_cap_args?(args) do
            {node, [:member_cap_construction | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp member_cap_args?(args) when is_list(args) and length(args) >= 4 do
    List.first(args) == :session and Enum.at(args, 2) == :receive
  end

  defp member_cap_args?(_), do: false

  defp format([]), do: "  (none)"

  defp format(offenders) do
    offenders
    |> Enum.map(fn {rel, _} -> "  #{rel}" end)
    |> Enum.uniq()
    |> Enum.join("\n")
  end
end
