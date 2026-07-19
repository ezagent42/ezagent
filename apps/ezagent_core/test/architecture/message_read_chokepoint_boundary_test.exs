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

    # round-3 evasions: raw Repo reads that build NO `from`/`in` source at all.
    repo_get = """
    defmodule Sneaky5 do
      def peek(id), do: Ezagent.Repo.get(Ezagent.Message, id)
    end
    """

    repo_pipe = """
    defmodule Sneaky6 do
      import Ecto.Query
      def peek(s), do: Ezagent.Message |> where([m], m.session_uri == ^s) |> Ezagent.Repo.all()
    end
    """

    for src <- [aliased, fully_qualified_split, raw_query, qualified_from, repo_get, repo_pipe] do
      assert offenses_in_source(src, "fixture") != [],
             "AST gate must flag a disguised message-store read:\n#{src}"
    end

    # No false positives: a chokepoint call, a Message STRUCT (not a read), and a
    # Repo read of a DIFFERENT schema must all pass clean.
    benign = """
    defmodule Fine do
      alias Ezagent.Socialware.SessionReads, as: Reads
      def read(caller, s), do: Reads.messages(caller, s, :conversation, %{limit: 50})
      def build(sender), do: %Ezagent.Message{sender: sender}
      def other, do: Ezagent.Repo.all(Ezagent.OtherSchema)
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
      {:ok, ast0} ->
        # `Code.string_to_quoted` does NOT expand pipes, so `Message |> where(…)
        # |> Repo.all()` keeps `Repo.all()` with EMPTY args (Message lives in the
        # `|>` chain, not the call args). Expand pipes first so Rule B sees the
        # real queryable. (round-3 repo_pipe evasion.)
        ast = expand_pipes(ast0)
        aliases = collect_aliases(ast)

        ast
        |> collect_offenses(aliases)
        |> Enum.map(fn {line, desc} -> "#{rel}:#{line}: #{desc}" end)

      {:error, _} ->
        []
    end
  end

  # Rewrite `left |> call(args…)` into `call(left, args…)` throughout the AST, so
  # the offense matchers see the fully-applied call. prewalk re-descends into the
  # rewritten node, so nested pipes expand too.
  defp expand_pipes(ast) do
    Macro.prewalk(ast, fn
      {:|>, _, [left, {call, meta, args}]} when is_list(args) -> {call, meta, [left | args]}
      other -> other
    end)
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

  # Rule A — the Ecto SOURCE operator. A raw Message query, in ANY builder form,
  # sources the schema with `_ in Ezagent.Message` (`from m in Message`,
  # `join: x in Message`, subqueries). Match the `in`-node itself, not the `from`
  # wrapper, so bare/imported/qualified `from` AND joins are all caught. (round-3.)
  defp offense_for({:in, meta, [_lhs, modast]}, aliases) do
    if resolves_to?(modast, [:Ezagent, :Message], aliases) do
      [
        {line_of(meta),
         "Ecto query sources Ezagent.Message (`_ in Message`) — only MessageStore may"}
      ]
    else
      []
    end
  end

  # Rule B — the Repo ENTRYPOINT. A raw read that never builds an `in`-source —
  # `Repo.all(Message)`, `Repo.get(Message, id)`, `Message |> where(...) |> Repo.all()`
  # (which is `Repo.all(where(Message, …))`, Message nested in the args). Flag any
  # `Repo.<fn>` whose args reference the Message schema. (round-3 #1.)
  defp offense_for({{:., _, [modast, fun]}, meta, args}, aliases)
       when is_atom(fun) and is_list(args) do
    if repo_module?(modast, aliases) and contains_message_alias?(args, aliases) do
      [{line_of(meta), "raw Repo.#{fun} referencing Ezagent.Message — only MessageStore may"}]
    else
      []
    end
  end

  defp offense_for(_node, _aliases), do: []

  # A module reference resolving to any `*.Repo` (Ezagent.Repo, EzagentCore.Repo,
  # or an aliased `Repo`) — the Ecto entrypoint.
  defp repo_module?({:__aliases__, _, parts}, aliases),
    do: List.last(resolve(parts, aliases)) == :Repo

  defp repo_module?(_other, _aliases), do: false

  # Does the Message schema alias appear anywhere in this AST subtree?
  defp contains_message_alias?(ast, aliases) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:__aliases__, _, parts} = node, acc ->
          {node, acc or resolve(parts, aliases) == [:Ezagent, :Message]}

        node, acc ->
          {node, acc}
      end)

    found?
  end

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
