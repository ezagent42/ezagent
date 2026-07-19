defmodule EzagentCore.MessageReadChokepointBoundaryTest do
  @moduledoc """
  Read-plane-authz drift gate (Pillar B) — the message plane (PR-1) plus the
  feed-tier DELIVERY and SURFACE planes (PR-2).

  A principal-facing / presenter-tier module MUST NOT read the session's
  persisted feed content directly: every conversation/feed message read, every
  delivery-outbox read, and every `:surface`-slice page/shell read routes
  through the `Ezagent.Socialware.SessionReads` chokepoint (which authorizes
  the caller FIRST). A direct `MessageStore.<windowed-read>`, a raw
  `Repo`/`Ecto` query over the `Message` or `Ezagent.Socialware.DeliveryOutbox`
  schema, or a `Kind.get_slice(_, :surface)` call added to the presenter tier →
  this test RED, so a new bypass cannot merge and re-open the deep-link
  info-disclosure (or the caller-less delivery/surface reads of finding-#4).

  ## AST-based (round-2 F3 fix)

  The gate parses each file to an AST and resolves module aliases (including
  the brace form `alias Foo.{Bar, Baz}`), so it is NOT fooled by
  `alias Ezagent.MessageStore, as: Store` + `Store.recent_in_session`,
  nor by splitting a call across lines — the substring gate it replaced was
  evadable both ways (codex round-2 F3).

  ## Scope (PR-1 + PR-2 slices)

  The MESSAGE, feed-DELIVERY, and feed-SURFACE planes in the world/web/
  socialware presenter tier. The member ROSTER read is closed a different way —
  routed through `SessionReads.members/2` (round-2 F2) — so it is not gated
  here. The residual `Kind.get_slice(_, :session)` reads (role-slot /
  convergence / session-state facets) are the SESSION-STATE plane and tighten
  in PR-4/PR-5 as their chokepoints land; gating them here would flag those
  deferred reads. `session_reads.ex` is the door. The uploads controller stays
  allowlisted for the ATTACHMENT plane: PR-3 kept its absent-grantee LEGACY
  message-participation recheck (the zero-breakage path for pre-PR-3 tokens),
  which reads Message rows directly; the attachment plane's own gate lives in
  `attachment_plane_chokepoint_boundary_test`.

  Completeness (Pillar B): the allowlist is the ONLY legal set for the gated
  planes — the red build is the exhaustive worklist, not a hand-maintained
  census.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  # The presenter / principal-facing read tier for the gated planes.
  @scan_dirs [
    "apps/ezagent_plugin_world/lib",
    "apps/ezagent_web/lib",
    "apps/ezagent_domain_socialware/lib"
  ]

  # Windowed conversation-content reads on `Ezagent.MessageStore` — the bypass
  # vector migrated onto `SessionReads`. (Non-content ops like `write`,
  # `by_id`, `sessions_for_message`, `mark_visibility` are not conversation reads.)
  @banned_message_store_reads ~w(
    recent_in_session recent_visible_in_session older_than older_visible_than
    chat_visible_recent committed_external_visible committed_external_visible_by_ids
    in_session_since
  )a

  # Modules permitted to touch the gated roots directly:
  #   * session_reads.ex     — THE chokepoint (authorized reader / store-owner caller)
  #   * uploads_controller.ex — the ATTACHMENT plane's legacy recheck (PR-3:
  #     absent-grantee tokens only; grantee-bound tokens never touch Message)
  @allowlisted_basenames ~w(
    session_reads.ex uploads_controller.ex
  )

  test "no presenter-tier module reads the message/delivery/surface stores outside SessionReads" do
    offenders =
      @scan_dirs
      |> Enum.flat_map(&Path.wildcard(Path.join([@repo_root, &1, "**/*.ex"])))
      |> Enum.reject(&(Path.basename(&1) in @allowlisted_basenames))
      |> Enum.flat_map(&offenders_in_file/1)

    assert offenders == [],
           """
           Read-plane-authz feed-tier gate: a presenter/web/socialware module reads the
           conversation message store, the delivery outbox, or the `:surface` slice
           DIRECTLY. Route the read through the caller-authorizing
           `Ezagent.Socialware.SessionReads` chokepoint (`messages/4`,
           `external_deliveries_since/3`, `latest_external_delivery_cursor/2`,
           `committed_external_surface_version/2`, `external_surface/2`) instead of
           touching `MessageStore`/`Repo`/`Kind.get_slice(_, :surface)`. Offenders:

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

    # PR-2 evasions: the delivery-outbox and surface-slice reads the feed tier
    # used to make directly (incl. the brace-alias form ExternalFeed used).
    delivery_query = """
    defmodule Sneaky7 do
      import Ecto.Query
      alias Ezagent.Socialware.{DeliveryOutbox, PublicView}
      alias EzagentCore.Repo
      def peek(s), do: from(o in DeliveryOutbox, where: o.session_uri == ^s) |> Repo.all()
    end
    """

    delivery_repo_get = """
    defmodule Sneaky8 do
      def peek(t), do: EzagentCore.Repo.get_by(Ezagent.Socialware.DeliveryOutbox, turn_id: t)
    end
    """

    surface_slice_read = """
    defmodule Sneaky9 do
      def peek(s), do: Ezagent.Kind.get_slice(s, :surface)
    end
    """

    surface_slice_piped = """
    defmodule Sneaky10 do
      alias Ezagent.Kind
      def peek(s), do: s |> Kind.get_slice(:surface)
    end
    """

    for src <- [
          aliased,
          fully_qualified_split,
          raw_query,
          qualified_from,
          repo_get,
          repo_pipe,
          delivery_query,
          delivery_repo_get,
          surface_slice_read,
          surface_slice_piped
        ] do
      assert offenses_in_source(src, "fixture") != [],
             "AST gate must flag a disguised feed-tier store read:\n#{src}"
    end

    # No false positives: a chokepoint call, a Message STRUCT (not a read), a
    # Repo read of a DIFFERENT schema, and a non-:surface slice read must all
    # pass clean.
    benign = """
    defmodule Fine do
      alias Ezagent.Socialware.SessionReads, as: Reads
      def read(caller, s), do: Reads.messages(caller, s, :conversation, %{limit: 50})
      def deliver(caller, s), do: Reads.external_deliveries_since(caller, s, 0)
      def surface(caller, s), do: Reads.external_surface(caller, s)
      def build(sender), do: %Ezagent.Message{sender: sender}
      def other, do: Ezagent.Repo.all(Ezagent.OtherSchema)
      def session_slice(s), do: Ezagent.Kind.get_slice(s, :session)
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

  # `alias Foo.Bar` → %{Bar: [:Foo, :Bar]}; `alias Foo.Bar, as: B` → %{B: [:Foo, :Bar]};
  # `alias Foo.{Bar, Baz}` → %{Bar: [:Foo, :Bar], Baz: [:Foo, :Baz]}.
  defp collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{{:., _, [{:__aliases__, _, prefix}, :{}]}, _, kids}]} = node, acc
        when is_list(kids) ->
          acc =
            Enum.reduce(kids, acc, fn
              {:__aliases__, _, [last]}, a -> Map.put(a, last, prefix ++ [last])
              _, a -> a
            end)

          {node, acc}

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

  # PR-2 SURFACE rule — `Kind.get_slice(_, :surface)` is the feed-tier
  # page/shell read; only SessionReads may make it.
  defp offense_for({{:., _, [modast, :get_slice]}, meta, args}, aliases)
       when is_list(args) do
    if resolves_to?(modast, [:Ezagent, :Kind], aliases) and Enum.member?(args, :surface) do
      [
        {line_of(meta),
         "Kind.get_slice(_, :surface) — route through SessionReads.external_surface/2"}
      ]
    else
      []
    end
  end

  # Rule A — the Ecto SOURCE operator. A raw Message/DeliveryOutbox query, in ANY
  # builder form, sources the schema with `_ in Ezagent.Message` /
  # `_ in Ezagent.Socialware.DeliveryOutbox` (`from m in Message`,
  # `join: x in Message`, subqueries). Match the `in`-node itself, not the `from`
  # wrapper, so bare/imported/qualified `from` AND joins are all caught. (round-3.)
  defp offense_for({:in, meta, [_lhs, modast]}, aliases) do
    cond do
      resolves_to?(modast, [:Ezagent, :Message], aliases) ->
        [
          {line_of(meta),
           "Ecto query sources Ezagent.Message (`_ in Message`) — only MessageStore may"}
        ]

      resolves_to?(modast, [:Ezagent, :Socialware, :DeliveryOutbox], aliases) ->
        [
          {line_of(meta),
           "Ecto query sources Ezagent.Socialware.DeliveryOutbox — only SessionReads may"}
        ]

      true ->
        []
    end
  end

  # Rule B — the Repo ENTRYPOINT. A raw read that never builds an `in`-source —
  # `Repo.all(Message)`, `Repo.get(Message, id)`, `Message |> where(...) |> Repo.all()`
  # (which is `Repo.all(where(Message, …))`, Message nested in the args). Flag any
  # `Repo.<fn>` whose args reference a gated schema. (round-3 #1.)
  defp offense_for({{:., _, [modast, fun]}, meta, args}, aliases)
       when is_atom(fun) and is_list(args) do
    if repo_module?(modast, aliases) do
      cond do
        contains_schema_alias?(args, [:Ezagent, :Message], aliases) ->
          [{line_of(meta), "raw Repo.#{fun} referencing Ezagent.Message — only MessageStore may"}]

        contains_schema_alias?(args, [:Ezagent, :Socialware, :DeliveryOutbox], aliases) ->
          [
            {line_of(meta),
             "raw Repo.#{fun} referencing Ezagent.Socialware.DeliveryOutbox — only SessionReads may"}
          ]

        true ->
          []
      end
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

  # Does the gated schema alias appear anywhere in this AST subtree?
  defp contains_schema_alias?(ast, target, aliases) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:__aliases__, _, parts} = node, acc ->
          {node, acc or resolve(parts, aliases) == target}

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

  # Bare `MessageStore` / `Message` / `Kind` / `DeliveryOutbox` in this codebase
  # are `Ezagent.MessageStore` / `Ezagent.Message` / `Ezagent.Kind` /
  # `Ezagent.Socialware.DeliveryOutbox` (aliased or same-namespace); normalize so a
  # missing explicit `alias` line doesn't create a false negative.
  defp normalize([:MessageStore]), do: [:Ezagent, :MessageStore]
  defp normalize([:Message]), do: [:Ezagent, :Message]
  defp normalize([:Kind]), do: [:Ezagent, :Kind]
  defp normalize([:DeliveryOutbox]), do: [:Ezagent, :Socialware, :DeliveryOutbox]
  defp normalize(parts), do: parts

  defp line_of(meta), do: Keyword.get(meta, :line, 0)
end
