defmodule Ezagent.Invariants.CapIssueChokepointTest do
  @moduledoc """
  I7: ratchet every provenance-bearing capability construction and every
  explicit `:caps` slice write while Phase 3 moves them behind `Cap.issue/3`.

  S1 introduced the leg-2 shrink-only allowlist. S4 adds leg 1: the one
  capability-adding writer is verification-gated, while revoke remains a
  monotonic removal. Later stages may only shrink these counts as proposed-cap
  constructors become issue callers; widening either map is a review-blocking
  chokepoint bypass.
  """
  use ExUnit.Case, async: true

  alias EzagentCore.CapsJsonScanner, as: Scanner

  @mint_candidates %{
    "apps/ezagent_core/lib/ezagent/cap/authority.ex" => 1,
    "apps/ezagent_core/lib/ezagent/capability/normalize.ex" => 3,
    "apps/ezagent_core/lib/ezagent/capability/parser.ex" => 2,
    "apps/ezagent_core/lib/ezagent/capability_registry.ex" => 1,
    "apps/ezagent_core/lib/ezagent/creator_grant.ex" => 1,
    "apps/ezagent_domain_identity/lib/ezagent/identity.ex" => 1,
    "apps/ezagent_domain_session/lib/ezagent/e2e/scenarios/agent_contract_g4.ex" => 3,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex" =>
      4,
    "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/rollback.ex" =>
      1,
    "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex" => 1,
    "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex" => 1,
    "apps/ezagent_plugin_world/lib/ezagent/world/layout_bootstrap.ex" => 1
  }
  @mint_candidate_files 12
  @mint_candidate_sites 20

  @caps_writers %{
    "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex" => 1
  }
  @caps_writer_files 1
  @caps_writer_sites 1

  # ------------------------------------------------------------------
  # Leg 3 (2026-07-14) — `users.caps_json` is a BACK DOOR into the cap slice.
  #
  # Legs 1-2 above ratchet who CONSTRUCTS a provenance-bearing cap and who
  # writes the Kind's `:caps` slice. Neither watches `Ezagent.Users.create/3,4`,
  # which writes a cap list straight into the `users.caps_json` COLUMN — and
  # `Behavior.Identity.post_init/2` reconciles the Kind's cap slice FROM that
  # column. So anything that can put a cap in `caps_json` has put a cap in the
  # user's authority, without ever passing `Cap.issue/3`.
  #
  # Something did. `WorkspaceUserAdmin.handle_create_user/2` parsed ARBITRARY
  # caller-supplied cap text, stamped it `granted_by: admin` regardless of who
  # was actually calling, and stored it. A holder of
  # `workspace_user_admin.create_user` — a WORKSPACE admin, not necessarily a
  # global one — could mint themselves a full wildcard: a second global admin.
  # (Codex PR #356 r1 had narrowed WHO can reach that action. It did not disarm
  # the action.)
  #
  # Every call site is therefore enumerated here, and each declares how it
  # satisfies the chokepoint. Adding one is a security decision, made here,
  # deliberately — not discovered later.
  #
  #   :issued            — hands `Users.create` only artifacts from `Cap.issue/3`
  #   :no_caps           — every call passes a literal `[]`
  #   :genesis_bootstrap — the ROOT OF TRUST: mints the admin's own wildcard at
  #                        first boot, when no prior authority exists to issue
  #                        from. Exactly one of these may exist.
  @caps_json_writers %{
    "apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_user_admin.ex" => :issued,
    "apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.create.ex" => :issued,
    "apps/ezagent_domain_identity/lib/ezagent/registration.ex" => :no_caps,
    "apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex" =>
      :genesis_bootstrap,

    # The anonymous-viewer mint. `Users.create_read_only/2` is a caps_json writer
    # too — the first version of this gate scanned only `Users.create/3,4` and
    # MISSED it, which is exactly the false comfort a gate must not give. Its
    # caps are code-constructed and narrow (a session join + public view reads),
    # never caller-supplied, so the exposure was latent rather than live; it now
    # issues under `{:rule, :anon_public_view_mint, _}`, whose rule branch
    # enforces `rule_cap_bounded?/1` — an anon cannot be BORN with a wildcard.
    "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_user.ex" => :issued,

    # Seed scripts. `scripts/*.exs` is NOT `apps/**/*.ex` — the first cut of this
    # gate scanned only the latter, so these were invisible to it while forging
    # provenance-bearing caps and storing them via `create_read_only/2`. Running
    # a seed means shell access, which is admin-equivalent, so they now issue
    # under `{:genesis, admin}`: the same power, taken through the front door.
    "scripts/world_e2e_seed.exs" => :issued,
    "scripts/autoservice_tier1_seed.exs" => :issued,
    "scripts/cc_headless_sdk_sidecar_e2e_seed.exs" => :no_caps,
    # G5 error-mechanism E2E seed (#1451): issues caps via Ezagent.Cap.issue/3.
    "scripts/g5_e2e_seed.exs" => :issued
  }

  test "provenance-bearing capability construction allowlist can only shrink" do
    actual = provenance_constructors()

    assert actual == @mint_candidates,
           "capability constructor ratchet changed; migrate new sites through Cap.issue, never widen:\n#{inspect(actual, pretty: true)}"

    assert map_size(@mint_candidates) == @mint_candidate_files
    assert Enum.sum(Map.values(@mint_candidates)) == @mint_candidate_sites
  end

  test "explicit caps-slice writer allowlist can only shrink" do
    actual = caps_writers()

    assert actual == @caps_writers,
           "caps writer ratchet changed; no new store path may bypass the issue/store model:\n#{inspect(actual, pretty: true)}"

    assert map_size(@caps_writers) == @caps_writer_files
    assert Enum.sum(Map.values(@caps_writers)) == @caps_writer_sites
  end

  test "I7 leg 1 classifies the adding writer as verified and revoke as removal-only" do
    identity =
      repo_root()
      |> Path.join("apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex")
      |> File.read!()

    persist = between(identity, "def handle_persist_caps", "defp store_verified_cap")
    store = between(identity, "defp store_verified_cap", "def handle_revoke_cap")
    revoke = between(identity, "def handle_revoke_cap", "defp uri_to_str")
    writer = between(identity, "defp set_caps_effect", "defp normalize_artifact")

    assert store =~ "Ezagent.Cap.storable_for?(cap_struct"
    assert persist =~ "set_caps_effect(new_caps)"
    assert store =~ "set_caps_effect(new_caps)"
    assert revoke =~ "set_caps_effect(new_caps)"
    assert writer =~ "{:set, :caps, caps}"
    assert revoke =~ "Ezagent.Capability.revoke(current_caps, cap_struct)"
    refute revoke =~ "MapSet.put"
  end

  # ------------------------------------------------------------------
  # Leg 3a — the COLUMN itself.
  #
  # The caller enumeration below is an allowlist of selected APIs. It is NOT an
  # invariant over the authority column, and it never was: `create_read_only/2`
  # sat outside it for as long as the first cut of this gate existed, because the
  # scanner knew call-site spellings and nothing about `caps_json`.
  #
  # So pin the column. `users.caps_json` is where a user's authority actually
  # lives — the user Kind reconciles its cap slice FROM it. Every assignment to
  # it, repo-wide, is enumerated here. Add a new writer function to
  # `Ezagent.Users` and this goes red BEFORE the caller allowlist has any chance
  # to be wrong about it.
  @caps_json_assignments %{
    # `create/3` and `create_read_only/2` — the two entry points the caller
    # allowlist below governs.
    "apps/ezagent_domain_identity/lib/ezagent/users.ex" => 2,

    # EntityCaps is the sole post-create storage facade. It replaces the full
    # verified set and cannot mint or authorize a grant by itself.
    "apps/ezagent_domain_identity/lib/ezagent/entity_caps/user_store.ex" => 1,

    # #189 PR-1 — the unified identity-caps store writes its OWN `identity_caps`
    # table column (a separate table from `users.caps_json`). In PR-1 it is a
    # WRITE-SHADOW: reads are never store-authoritative, and it MIRRORS the
    # verified set on every legacy write — it cannot mint, grant, or authorize
    # by itself. codex adversarial review (5 rounds) covered the write paths.
    "apps/ezagent_domain_identity/lib/ezagent/entity_caps/store.ex" => 8,

    # Rewrites the retired Chat behavior name inside EXISTING artifacts. It
    # preserves authority rather than broadening it, and grants nothing new.
    "apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex" => 1
  }

  test "the authority column has exactly the known writers" do
    actual = caps_json_assignment_sites()

    assert actual == @caps_json_assignments, """
    The set of `caps_json` ASSIGNMENTS changed.

    This column IS a user's authority — the user Kind reconciles its cap slice
    from it. A new writer is a new way for authority to enter the system, and
    the caller allowlist cannot see it (that is exactly how `create_read_only/2`
    went unwatched). Justify it here.

      actual: #{inspect(actual, pretty: true)}
    """
  end

  test "every `users.caps_json` writer is enumerated — a new one is a security decision" do
    found = users_create_sites()
    expected = @caps_json_writers |> Map.keys() |> MapSet.new()

    assert found == expected, """
    The set of `Ezagent.Users.create/3,4` call sites changed.

    `users.caps_json` feeds the user Kind's cap slice, so anything written there
    is authority granted. Every cap that lands in it must have passed
    `Ezagent.Cap.issue/3` (Decision #162). Add your site to `@caps_json_writers`
    with the reason it is safe — :issued, :no_caps, or :genesis_bootstrap.

      added:   #{inspect(MapSet.to_list(MapSet.difference(found, expected)))}
      removed: #{inspect(MapSet.to_list(MapSet.difference(expected, found)))}
    """
  end

  test "`:issued` caps_json writers actually call Cap.issue" do
    for {file, :issued} <- @caps_json_writers do
      src = repo_root() |> Path.join(file) |> File.read!()

      assert src =~ "Ezagent.Cap.issue(",
             "#{file} is declared `:issued` but never calls `Ezagent.Cap.issue/3`"
    end
  end

  test "`:no_caps` caps_json writers pass a literal empty cap list" do
    for {file, :no_caps} <- @caps_json_writers do
      args = repo_root() |> Path.join(file) |> Scanner.users_create_cap_args()

      assert args != [], "#{file} is declared `:no_caps` but calls no Users.create"

      for arg <- args do
        assert arg == [],
               "#{file} is declared `:no_caps` but passes `#{Macro.to_string(arg)}` as caps"
      end
    end
  end

  test "authority begins in exactly ONE place" do
    roots = for {file, :genesis_bootstrap} <- @caps_json_writers, do: file

    assert length(roots) == 1,
           "there must be exactly one root of trust, found: #{inspect(roots)}"
  end

  # Leg 3 scans a WIDER surface than legs 1-2: `caps_json` is written from
  # `scripts/*.exs` too, and scanning only `apps/**/*.ex` is precisely how the
  # first cut of this gate missed the seeds. Legs 1-2 keep their own (narrower)
  # file set so their ratchets stay comparable.
  defp caps_json_source_files do
    root = repo_root()

    (Path.wildcard(Path.join(root, "apps/**/*.ex")) ++
       Path.wildcard(Path.join(root, "scripts/**/*.exs")))
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&{String.replace_prefix(&1, root <> "/", ""), &1})
  end

  defp users_create_sites do
    caps_json_source_files()
    |> Enum.filter(fn {_rel, abs} -> Scanner.users_create_cap_args(abs) != [] end)
    |> Enum.map(fn {rel, _abs} -> rel end)
    |> MapSet.new()
  end

  # Every `caps_json: ...` assignment (a changeset / struct key), repo-wide.
  # Docstrings and comments naturally fall out — this walks the AST, not text.
  defp caps_json_assignment_sites do
    caps_json_source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      {_ast, count} =
        Macro.prewalk(quoted!(absolute), 0, fn
          {:%{}, _, fields} = node, n when is_list(fields) ->
            {node, n + count_caps_json_key(fields)}

          {:{}, _, _} = node, n ->
            {node, n}

          node, n ->
            {node, n + count_caps_json_kw(node)}
        end)

      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp count_caps_json_key(fields) do
    Enum.count(fields, fn
      {:caps_json, _} -> true
      _ -> false
    end)
  end

  # A bare keyword list (e.g. `change(uri: x, caps_json: y)`) is a plain list of
  # 2-tuples in the AST, not a `%{}` node.
  defp count_caps_json_kw(node) when is_list(node) do
    Enum.count(node, fn
      {:caps_json, _} -> true
      _ -> false
    end)
  end

  defp count_caps_json_kw(_node), do: 0

  defp provenance_constructors do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      ast = quoted!(absolute)

      {_ast, count} =
        Macro.prewalk(ast, 0, fn node, count ->
          {node, count + provenance_constructor?(node)}
        end)

      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp provenance_constructor?({:%, _, [alias_ast, {:%{}, _, fields}]}) when is_list(fields) do
    if String.ends_with?(Macro.to_string(alias_ast), "Capability") and
         Keyword.has_key?(fields, :granted_by),
       do: 1,
       else: 0
  end

  defp provenance_constructor?(_node), do: 0

  defp caps_writers do
    source_files()
    |> Enum.reduce(%{}, fn {relative, absolute}, acc ->
      ast = quoted!(absolute)

      {_ast, count} =
        Macro.prewalk(ast, 0, fn
          {:{}, _, [:set, :caps | _]} = node, count -> {node, count + 1}
          node, count -> {node, count}
        end)

      if count == 0, do: acc, else: Map.put(acc, relative, count)
    end)
  end

  defp source_files do
    root = repo_root()

    root
    |> Path.join("apps/**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/test/"))
    |> Enum.map(&{String.replace_prefix(&1, root <> "/", ""), &1})
  end

  defp quoted!(file) do
    case Code.string_to_quoted(File.read!(file)) do
      {:ok, ast} -> ast
      {:error, reason} -> raise "cannot scan #{file}: #{inspect(reason)}"
    end
  end

  defp between(source, first, last) do
    [_, tail] = String.split(source, first, parts: 2)
    [section | _] = String.split(tail, last, parts: 2)
    section
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
