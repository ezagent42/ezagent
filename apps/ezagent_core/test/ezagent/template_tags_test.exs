defmodule Ezagent.TemplateTagsTest do
  @moduledoc """
  Phase 7 completion PR-3 (SPEC §1.7 (c)) — the `Ezagent.TemplateTags`
  registry.

  Covers:

  - `put`/`resolve` round-trip;
  - **cross-workspace tag non-collision** — a `stable` tag in
    workspace A and a `stable` tag in workspace B are distinct rows
    and never resolve to each other (SPEC §1.2; codex rev-2 CRITICAL);
  - **CAS `move`** — concurrent moves race, exactly one wins, the
    losers get `{:error, :tag_moved}`;
  - `template_tags` rows carry a non-nil `workspace_uri` (invariant 14);
  - `list/1` is workspace-scoped.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.TemplateTags

  defp uniq, do: System.unique_integer([:positive])

  defp hexhash(seed), do: :crypto.hash(:sha256, "#{seed}") |> Base.encode16(case: :lower)

  describe "put/5 + resolve/3 round-trip" do
    test "a put makes the tag resolvable to its hash" do
      ws = "workspace://team-alpha"
      name = "code-review-#{uniq()}"
      hash = hexhash("v1")

      assert :ok = TemplateTags.put(ws, name, "stable", hash, "entity://team-alpha/user/admin")
      assert {:ok, ^hash} = TemplateTags.resolve(ws, name, "stable")
    end

    test "resolve of an unknown tag returns :error" do
      assert :error =
               TemplateTags.resolve("workspace://team-alpha", "no-such-#{uniq()}", "stable")
    end

    test "a second put to the same tag overwrites the hash" do
      ws = "workspace://team-alpha"
      name = "overwrite-#{uniq()}"
      h1 = hexhash("a")
      h2 = hexhash("b")

      assert :ok = TemplateTags.put(ws, name, "stable", h1, nil)
      assert {:ok, ^h1} = TemplateTags.resolve(ws, name, "stable")

      assert :ok = TemplateTags.put(ws, name, "stable", h2, nil)
      assert {:ok, ^h2} = TemplateTags.resolve(ws, name, "stable")

      # Still exactly one row for the (workspace, name, tag) key.
      rows = TemplateTags.list(ws) |> Enum.filter(&(&1.name == name))
      assert length(rows) == 1
    end

    test "a URI struct workspace argument is accepted" do
      ws = URI.new!("workspace://team-alpha")
      name = "uri-arg-#{uniq()}"
      hash = hexhash("u")

      assert :ok = TemplateTags.put(ws, name, "stable", hash, nil)
      assert {:ok, ^hash} = TemplateTags.resolve(ws, name, "stable")
    end
  end

  describe "cross-workspace non-collision (SPEC §1.2, codex rev-2 CRITICAL)" do
    test "`stable` in workspace A and `stable` in workspace B are distinct" do
      name = "shared-template-#{uniq()}"
      ws_a = "workspace://team-alpha"
      ws_b = "workspace://team-beta"
      hash_a = hexhash("in-A")
      hash_b = hexhash("in-B")

      assert :ok = TemplateTags.put(ws_a, name, "stable", hash_a, nil)
      assert :ok = TemplateTags.put(ws_b, name, "stable", hash_b, nil)

      # Each workspace's `stable` resolves to its OWN hash — no leak.
      assert {:ok, ^hash_a} = TemplateTags.resolve(ws_a, name, "stable")
      assert {:ok, ^hash_b} = TemplateTags.resolve(ws_b, name, "stable")
      refute hash_a == hash_b

      # They are separate rows.
      assert [%{version_hash: ^hash_a}] =
               TemplateTags.list(ws_a) |> Enum.filter(&(&1.name == name))

      assert [%{version_hash: ^hash_b}] =
               TemplateTags.list(ws_b) |> Enum.filter(&(&1.name == name))
    end

    test "a put in workspace A is invisible to a resolve in workspace B" do
      name = "only-in-a-#{uniq()}"
      assert :ok = TemplateTags.put("workspace://team-alpha", name, "stable", hexhash("a"), nil)

      assert :error = TemplateTags.resolve("workspace://team-beta", name, "stable")
    end
  end

  describe "template_tags rows carry a non-nil workspace_uri (invariant 14)" do
    test "every persisted row has a workspace_uri" do
      ws = "workspace://team-alpha"
      name = "ws-col-#{uniq()}"
      assert :ok = TemplateTags.put(ws, name, "stable", hexhash("x"), nil)

      [row] = TemplateTags.list(ws) |> Enum.filter(&(&1.name == name))
      assert row.workspace_uri == ws
      refute is_nil(row.workspace_uri)
    end

    test "the NOT NULL constraint is enforced at the DB layer" do
      # A direct insert with a nil workspace_uri must be rejected by the
      # `workspace_uri` NOT NULL column (invariant 14). The database raise
      # is the proof that the column-level NOT NULL is in force.
      row = %TemplateTags{
        workspace_uri: nil,
        name: "nil-ws-#{uniq()}",
        tag: "stable",
        version_hash: hexhash("n"),
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert_raise Postgrex.Error, ~r/null value in column "workspace_uri"/, fn ->
        EzagentCore.Repo.insert(row)
      end
    end
  end

  describe "list/1" do
    test "returns only the rows in the given workspace, ordered by (name, tag)" do
      ws = "workspace://list-test-#{uniq()}"
      n1 = "alpha"
      n2 = "beta"

      assert :ok = TemplateTags.put(ws, n2, "stable", hexhash("b-s"), nil)
      assert :ok = TemplateTags.put(ws, n1, "v2", hexhash("a-2"), nil)
      assert :ok = TemplateTags.put(ws, n1, "v1", hexhash("a-1"), nil)

      rows = TemplateTags.list(ws)
      assert length(rows) == 3
      assert Enum.map(rows, &{&1.name, &1.tag}) == [{n1, "v1"}, {n1, "v2"}, {n2, "stable"}]
    end
  end

  describe "CAS move/5" do
    test "move re-points a tag only when the expected hash matches" do
      ws = "workspace://team-alpha"
      name = "cas-basic-#{uniq()}"
      h_old = hexhash("old")
      h_new = hexhash("new")

      assert :ok = TemplateTags.put(ws, name, "stable", h_old, nil)
      assert :ok = TemplateTags.move(ws, name, "stable", h_old, h_new)
      assert {:ok, ^h_new} = TemplateTags.resolve(ws, name, "stable")
    end

    test "move with a stale expected hash fails with :tag_moved" do
      ws = "workspace://team-alpha"
      name = "cas-stale-#{uniq()}"
      h_old = hexhash("old")
      h_actual = hexhash("actual")
      h_new = hexhash("new")

      assert :ok = TemplateTags.put(ws, name, "stable", h_actual, nil)

      # Expected h_old, but the tag points at h_actual — CAS rejects.
      assert {:error, :tag_moved} = TemplateTags.move(ws, name, "stable", h_old, h_new)
      # Unchanged.
      assert {:ok, ^h_actual} = TemplateTags.resolve(ws, name, "stable")
    end

    test "move of a non-existent tag fails with :no_such_tag" do
      assert {:error, :no_such_tag} =
               TemplateTags.move(
                 "workspace://team-alpha",
                 "missing-#{uniq()}",
                 "stable",
                 hexhash("e"),
                 hexhash("n")
               )
    end

    test "concurrent moves race — exactly one wins, the rest get :tag_moved" do
      ws = "workspace://team-alpha"
      name = "cas-race-#{uniq()}"
      h_start = hexhash("start")

      assert :ok = TemplateTags.put(ws, name, "stable", h_start, nil)

      # N callers all attempt to move `stable` off the SAME expected
      # hash onto DIFFERENT new hashes, concurrently. The CAS arbiter
      # (a single atomic UPDATE ... WHERE version_hash = ?expected)
      # must let exactly one win.
      n = 12

      results =
        1..n
        |> Enum.map(fn i ->
          Task.async(fn ->
            TemplateTags.move(ws, name, "stable", h_start, hexhash("contender-#{i}"))
          end)
        end)
        |> Enum.map(&Task.await/1)

      winners = Enum.count(results, &(&1 == :ok))
      losers = Enum.count(results, &(&1 == {:error, :tag_moved}))

      assert winners == 1, "exactly one concurrent move must win, got #{winners}"
      assert losers == n - 1, "every loser must get :tag_moved, got #{losers}"

      # The tag now points at SOME contender hash (the winner's), and
      # it is no longer the start hash.
      assert {:ok, final} = TemplateTags.resolve(ws, name, "stable")
      refute final == h_start
      assert String.starts_with?(final, "") and byte_size(final) == 64
    end
  end

  describe "load_into_registry/0" do
    test "hydrates the ETS cache from the DB" do
      ws = "workspace://team-alpha"
      name = "hydrate-#{uniq()}"
      hash = hexhash("h")

      assert :ok = TemplateTags.put(ws, name, "stable", hash, nil)

      # Clear the ETS cache, then re-hydrate from the DB — resolve must
      # work again afterwards.
      :ets.delete_all_objects(TemplateTags.table())
      assert :error = TemplateTags.resolve(ws, name, "stable")

      assert :ok = TemplateTags.load_into_registry()
      assert {:ok, ^hash} = TemplateTags.resolve(ws, name, "stable")
    end
  end
end
