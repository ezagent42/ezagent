defmodule EzagentCore.AttachmentPlaneChokepointBoundaryTest do
  @moduledoc """
  Read-plane-authz drift gate (Pillar B) — the ATTACHMENT plane (PR-3).

  The signed `Ezagent.Uploads.DownloadToken` is the SOLE authorization carrier
  for every upload download. It may be minted only inside an AUTHORIZING read
  (a cap-gated chokepoint — the external-feed approved-only mint, the kanban
  board's cap-gated artifact render, the world conversation render) and
  verified only at the two serve paths (the authenticated `UploadsController`
  and the public `ExternalFeedController`). A NEW module minting or verifying
  the token outside this allowlist would bypass the chokepoint (mint-without-
  authz, or a serve path that skips the grantee / approved-only checks) →
  this test RED, so the attachment plane cannot drift back open.

  ## AST-based

  Alias-resolved (incl. the brace form `alias Ezagent.Uploads.{DownloadToken}`),
  so it is NOT fooled by `alias ..., as: Tok` + `Tok.mint!(uri)` or by splitting
  the call across lines.

  ## Scope

  All `apps/*/lib` — the signer is a core module reachable from every tier, so
  the gate scans every tier (a plugin minting its own token would be the same
  bypass). The allowlist is the ONLY legal set: the red build is the exhaustive
  worklist, not a hand-maintained census.
  """

  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  @scan_glob "apps/*/lib/**/*.ex"

  # Token-signer entrypoints a bypassing module would call. Reading
  # `default_ttl/0`/`max_ttl/0` (constants) and `grantee_match?/2` (a pure
  # predicate, no signing/verify authority) is NOT gated.
  @banned_calls ~w(mint! verify verify_at verify_payload verify_payload_at)a

  # The ONLY modules that may touch the token signer/verifier:
  #   * download_token.ex          — the signer itself
  #   * external_feed.ex           — the socialware approved-only MINT chokepoint
  #                                  (`mint_approved_token/4`, caller-authorizing,
  #                                  binds grantee = caller)
  #   * world_data.ex              — the kanban cap-gated artifact mint (inside
  #                                  the `get_tree`-authorized board render; #9).
  #                                  #1472 EXTRACTED this from the world plugin's
  #                                  deleted `kanban_data.ex` into the kanban
  #                                  plugin verbatim — the mint stays strictly
  #                                  inside the `board_snapshot/2` `{:ok, tree}`
  #                                  branch, AFTER the cap-gated `:get_tree`
  #                                  dispatch (the gate lives in the core
  #                                  CapabilityRegistry chokepoint, not the file),
  #                                  still `grantee: caller`-bound. Relocated
  #                                  chokepoint, unchanged authz.
  #   * conversation_data.ex       — the world conversation render mint (bound
  #                                  to the authorized viewer as grantee)
  #   * uploads_controller.ex      — the authenticated SERVE path (grantee check,
  #                                  legacy recheck for unbound tokens)
  #   * external_feed_controller.ex — the public SERVE path (grantee check +
  #                                  approved-only serve-time re-validation)
  @allowlisted_basenames ~w(
    download_token.ex
    external_feed.ex
    world_data.ex
    conversation_data.ex
    uploads_controller.ex
    external_feed_controller.ex
  )

  test "no module mints/verifies a DownloadToken outside the attachment chokepoints" do
    offenders =
      @repo_root
      |> Path.join(@scan_glob)
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) in @allowlisted_basenames))
      |> Enum.reject(&String.contains?(&1, "/test/"))
      |> Enum.flat_map(&offenders_in_file/1)

    assert offenders == [],
           """
           Read-plane-authz attachment-plane gate: a module mints or verifies an
           `Ezagent.Uploads.DownloadToken` OUTSIDE the attachment chokepoints.
           Mint only inside an authorizing read (`ExternalFeed.mint_approved_token/4`,
           the kanban cap-gated render); serve only via the two controllers (which
           enforce the PR-3 grantee binding + the legacy/approved rechecks).
           Offenders:

           #{Enum.map_join(offenders, "\n", &("  " <> &1))}
           """
  end

  test "the chokepoint allowlist still names the door modules (gate not vacuous)" do
    for basename <- @allowlisted_basenames do
      assert @repo_root
             |> Path.join(@scan_glob)
             |> Path.wildcard()
             |> Enum.any?(&(Path.basename(&1) == basename)),
             "allowlisted #{basename} no longer exists — is the gate vacuous?"
    end
  end

  test "EVERY DownloadToken.mint! call site binds a :grantee (no NEW unbound token)" do
    # Read-plane PR-3 structural invariant (codex blocking): the person binding
    # is defeated if ANY mint path issues an absent-grantee token — such a token
    # enters the replayable legacy serve path. The signer raises without a
    # `:grantee`, and this scan proves statically that no call site even tries:
    # every `mint!` call in every tier passes `grantee: <authorized caller>`.
    unbound =
      @repo_root
      |> Path.join(@scan_glob)
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/test/"))
      |> Enum.flat_map(&unbound_mints_in_file/1)

    assert unbound == [],
           """
           Read-plane PR-3 invariant: a `DownloadToken.mint!` call WITHOUT a
           `:grantee` option — a NEW unbound token is forbidden (it would enter
           the replayable legacy serve path and defeat the person binding).
           Pass `grantee: <the authorized caller %URI{}>`:

           #{Enum.map_join(unbound, "\n", &("  " <> &1))}
           """
  end

  test "the gate is alias- and line-split-resistant (AST, not substring)" do
    aliased = """
    defmodule Sneaky do
      alias Ezagent.Uploads.DownloadToken, as: Tok
      def go(uri), do: Tok.mint!(uri)
    end
    """

    brace_aliased = """
    defmodule Sneaky2 do
      alias Ezagent.Uploads.{DownloadToken}
      def go(t), do: DownloadToken.verify(t)
    end
    """

    fully_qualified_split = """
    defmodule Sneaky3 do
      def go(uri) do
        Ezagent.Uploads.DownloadToken.verify_payload(
          uri
        )
      end
    end
    """

    for src <- [aliased, brace_aliased, fully_qualified_split] do
      assert offenses_in_source(src, "fixture") != [],
             "AST gate must flag a disguised DownloadToken call:\n#{src}"
    end

    # No false positives: the pure predicate + the TTL constants are free; an
    # unrelated `verify/1` on another module is free.
    benign = """
    defmodule Fine do
      alias Ezagent.Uploads.DownloadToken
      def check(g, c), do: DownloadToken.grantee_match?(g, c)
      def ttl, do: DownloadToken.default_ttl()
      def other(t), do: Phoenix.Token.verify(t, t, t)
    end
    """

    assert offenses_in_source(benign, "fixture") == []
  end

  # ----- the PR-3 grantee-binding invariant --------------------------------------

  defp unbound_mints_in_file(path) do
    case Code.string_to_quoted(File.read!(path)) do
      {:ok, ast} ->
        aliases = collect_aliases(ast)
        rel = Path.relative_to(path, @repo_root)

        {_, found} =
          Macro.prewalk(ast, [], fn node, acc ->
            {node, unbound_mint(node, aliases, rel) ++ acc}
          end)

        Enum.reverse(found)

      {:error, _} ->
        []
    end
  end

  # `<Mod>.mint!(uri, opts)` where <Mod> resolves to DownloadToken: `opts` must
  # be a keyword literal carrying `:grantee`. Any other shape (no opts, an
  # opts variable, a keyword without :grantee) is an unbound-mint suspect —
  # fail and let a human route the mint through the binding.
  defp unbound_mint({{:., _, [modast, :mint!]}, meta, args}, aliases, rel)
       when is_list(args) do
    if resolves_to?(modast, [:Ezagent, :Uploads, :DownloadToken], aliases) and
         not grantee_opt?(args) do
      [
        "#{rel}:#{line_of(meta)}: DownloadToken.mint! without `grantee: <caller>`"
      ]
    else
      []
    end
  end

  defp unbound_mint(_node, _aliases, _rel), do: []

  defp grantee_opt?([_uri, opts]) when is_list(opts), do: Keyword.has_key?(opts, :grantee)
  defp grantee_opt?(_args), do: false

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

  # `<Mod>.<banned>(...)` where <Mod> resolves to Ezagent.Uploads.DownloadToken.
  defp offense_for({{:., _, [modast, fun]}, meta, _args}, aliases)
       when fun in @banned_calls do
    if resolves_to?(modast, [:Ezagent, :Uploads, :DownloadToken], aliases) do
      [
        {line_of(meta), "DownloadToken.#{fun} — mint/serve only via the attachment chokepoints"}
      ]
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

  # A bare `DownloadToken` in this codebase is `Ezagent.Uploads.DownloadToken`
  # (aliased or same-namespace); normalize so a missing explicit `alias` line
  # doesn't create a false negative.
  defp normalize([:DownloadToken]), do: [:Ezagent, :Uploads, :DownloadToken]
  defp normalize(parts), do: parts

  defp line_of(meta), do: Keyword.get(meta, :line, 0)
end
