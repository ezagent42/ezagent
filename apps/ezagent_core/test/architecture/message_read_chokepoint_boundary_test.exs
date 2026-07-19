defmodule EzagentCore.MessageReadChokepointBoundaryTest do
  @moduledoc """
  Read-plane-authz PR-1 drift gate (Pillar B) — the message plane, NARROW slice.

  A principal-facing / presenter-tier module MUST NOT read the conversation
  message store directly: every conversation message read routes through the
  `Ezagent.Socialware.SessionReads` chokepoint (which authorizes the caller
  FIRST). A direct `MessageStore.<windowed-read>` OR a raw `Repo`/`Ecto` query
  over the `Message` schema added to the presenter tier → this test RED, so a new
  bypass cannot merge and re-open the deep-link info-disclosure.

  ## AST-based (round-2 F3 fix)

  The gate parses each file to an AST and resolves module aliases, so it is NOT
  fooled by `alias Ezagent.MessageStore, as: Store` + `Store.recent_in_session`,
  nor by splitting a call across lines — the substring gate it replaced was
  evadable both ways (codex round-2 F3).

  ## Scope (this PR's slice only)

  The MESSAGE plane in the world/web/socialware presenter tier. The member ROSTER
  read is closed a different way — routed through `SessionReads.members/2`
  (round-2 F2) — so it is not gated here. The residual `Kind.get_slice(_, :session)`
  reads (role-slot / convergence / session-state facets) are the SESSION-STATE
  plane and tighten in PR-4/PR-5 as their chokepoints land; gating them here would
  flag those deferred reads. The still-unmigrated feed + uploads message readers
  are explicitly allowlisted until PR-2/PR-3; `session_reads.ex` is the door.

  Completeness (Pillar B): the allowlist is the ONLY legal set for the message
  plane — the red build is the exhaustive worklist, not a hand-maintained census.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  # The presenter / principal-facing read tier for the message plane.
  @scan_dirs [
    "apps/ezagent_plugin_world/lib",
    "apps/ezagent_web/lib",
    "apps/ezagent_domain_socialware/lib"
  ]

  # Windowed conversation-content reads on `Ezagent.MessageStore` — the bypass
  # vector this PR migrates onto `SessionReads`. (Non-content ops like `write`,
  # `by_id`, `sessions_for_message`, `mark_visibility` are not conversation reads.)
  @banned_message_store_reads ~w(
    recent_in_session recent_visible_in_session older_than older_visible_than
    chat_visible_recent committed_external_visible committed_external_visible_by_ids
    in_session_since
  )a

  # Modules permitted to read the message store directly:
  #   * session_reads.ex     — THE chokepoint (authorized reader / store-owner caller)
  #   * chat_feed.ex         — deferred to PR-2 (routes through SessionReads there)
  #   * external_feed.ex     — deferred to PR-2
  #   * uploads_controller.ex — deferred to PR-3 (attachment plane)
  @allowlisted_basenames ~w(
    session_reads.ex chat_feed.ex external_feed.ex uploads_controller.ex
  )

  test "no presenter-tier module reads the conversation message store outside SessionReads" do
    offenders =
      @scan_dirs
      |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**/*.ex"])))
      |> Enum.reject(&(Path.basename(&1) in @allowlisted_basenames))
      |> Enum.flat_map(&offenders_in_file/1)

    assert offenders == [],
           """
           Read-plane-authz message gate: a presenter/web/socialware module reads the
           conversation message store DIRECTLY. Route the read through
           `Ezagent.Socialware.SessionReads.messages/4` (which authorizes the caller
           first) instead of touching `MessageStore`/`Repo`. Offenders:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "the SessionReads chokepoint IS in the allowlist (the door exists)" do
    # Guards against the allowlist silently drifting to exclude the one module
    # that legitimately reads the store — which would make the gate vacuous.
    assert "session_reads.ex" in @allowlisted_basenames

    assert File.regular?(
             Path.join(
               @repo_root,
               "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex"
             )
           )
  end

  test "the gate is alias- and line-split-resistant (AST, not substring)" do
    # The exact evasions codex round-2 F3 flagged on the old substring gate.
    aliased = """
    defmodule Sneaky do
      alias Ezagent.MessageStore, as: Store
      def peek(s), do: Store.recent_in_session(s, 50)
    end
    """

    fully_qualified_split = """
    defmodule Sneaky2 do
      def peek(s) do
        Ezagent.MessageStore.recent_visible_in_session(
          s,
          50
        )
      end
    end
    """

    raw_query = """
    defmodule Sneaky3 do
      import Ecto.Query
      def peek(s), do: from(m in Ezagent.Message, where: m.session_uri == ^s) |> Repo.all()
    end
    """

    # The round-2 F3 evasion: a MODULE-QUALIFIED from, not a bare/imported one.
    qualified_from = """
    defmodule Sneaky4 do
      def peek(s) do
        Ecto.Query.from(m in Ezagent.Message, where: m.session_uri == ^s) |> Ezagent.Repo.all()
      end
    end
    """

    for src <- [aliased, fully_qualified_split, raw_query, qualified_from] do
      assert offenses_in_source(src, "fixture") != [],
             "AST gate must flag a disguised message-store read:\n#{src}"
    end

    # A legitimately-aliased NON-store call must NOT be flagged (no false positive).
    benign = """
    defmodule Fine do
      alias Ezagent.Socialware.SessionReads, as: Reads
      def peek(caller, s), do: Reads.messages(caller, s, :conversation, %{limit: 50})
    end
    """

    assert offenses_in_source(benign, "fixture") == []
  end

  # ----- AST scan --------------------------------------------------------------

  defp offenders_in_file(path) do
    offenses_in_source(File.read!(path), Path.relative_to(path, @repo_root))
  end

  defp offenses_in_source(source, rel) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        aliases = collect_aliases(ast)

        ast
        |> collect_offenses(aliases)
        |> Enum.map(fn {line, desc} -> "#{rel}:#{line}: #{desc}" end)

      {:error, _} ->
        []
    end
  end

  # `alias Foo.Bar` → %{Bar: [:Foo, :Bar]}; `alias Foo.Bar, as: B` → %{B: [:Foo, :Bar]}.
  defp collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, parts}]} = node, acc ->
          {node, Map.put(acc, List.last(parts), parts)}

        {:alias, _, [{:__aliases__, _, parts}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as_name]} -> {node, Map.put(acc, as_name, parts)}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp collect_offenses(ast, aliases) do
    {_, offenses} =
      Macro.prewalk(ast, [], fn node, acc -> {node, offense_for(node, aliases) ++ acc} end)

    Enum.reverse(offenses)
  end

  # `<Mod>.<banned>(...)` where <Mod> resolves to Ezagent.MessageStore.
  defp offense_for({{:., _, [modast, fun]}, meta, _args}, aliases)
       when fun in @banned_message_store_reads do
    if resolves_to?(modast, [:Ezagent, :MessageStore], aliases) do
      [{line_of(meta), "MessageStore.#{fun} — route through SessionReads"}]
    else
      []
    end
  end

  # `from(x in <Mod>, ...)` — the bare/imported form (`import Ecto.Query`).
  defp offense_for({:from, meta, [{:in, _, [_, modast]} | _]}, aliases) do
    if resolves_to?(modast, [:Ezagent, :Message], aliases) do
      [{line_of(meta), "raw Ecto query over Message — only MessageStore may build one"}]
    else
      []
    end
  end

  # `<mod>.from(x in <Mod>, ...)` — the QUALIFIED form (`Ecto.Query.from(...)`),
  # a remote-call AST the bare-`from` clause above does not see. Without this a
  # presenter could bypass the gate with `Ecto.Query.from(m in Ezagent.Message,
  # …) |> Repo.all()`. (round-2 F3/#1.)
  defp offense_for({{:., _, [_mod, :from]}, meta, [{:in, _, [_, modast]} | _]}, aliases) do
    if resolves_to?(modast, [:Ezagent, :Message], aliases) do
      [{line_of(meta), "raw Ecto query over Message (qualified from) — only MessageStore may build one"}]
    else
      []
    end
  end

  defp offense_for(_node, _aliases), do: []

  # Does a module-reference AST resolve (via the file's aliases) to `target`?
  defp resolves_to?({:__aliases__, _, parts}, target, aliases) do
    resolve(parts, aliases) == target
  end

  defp resolves_to?(_other, _target, _aliases), do: false

  defp resolve([first | rest], aliases) do
    case Map.get(aliases, first) do
      nil -> normalize([first | rest])
      full -> full ++ rest
    end
  end

  # Bare `MessageStore` / `Message` in this codebase are `Ezagent.MessageStore` /
  # `Ezagent.Message` (aliased or same-namespace); normalize so a missing explicit
  # `alias` line doesn't create a false negative.
  defp normalize([:MessageStore]), do: [:Ezagent, :MessageStore]
  defp normalize([:Message]), do: [:Ezagent, :Message]
  defp normalize(parts), do: parts

  defp line_of(meta), do: Keyword.get(meta, :line, 0)
end
