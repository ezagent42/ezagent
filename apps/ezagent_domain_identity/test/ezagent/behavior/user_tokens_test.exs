defmodule Ezagent.Behavior.UserTokensTest do
  @moduledoc """
  Tests for the dispatch-backed UserTokens Behavior — HIGH-2
  completion (`docs/futures/todo.md` CLI ↔ GUI parity).

  Split into:

  - Contract surface — pure unit, async.
  - `invoke/4` action bodies — need the DB (use `EzagentCore.DataCase`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.UserTokens, as: UT
  alias Ezagent.Users
  alias Ezagent.Entity.Token

  describe "contract surface" do
    test "actions/0 lists all three actions" do
      assert UT.actions() == [:mint_token, :list_tokens, :revoke_token]
    end

    test "required_caps/0 has an entry per action with the SPEC v2 struct shape" do
      caps = UT.required_caps()

      for action <- UT.actions() do
        assert Map.has_key?(caps, action),
               "required_caps/0 missing #{action} — dispatch step 5.5 would crash"
      end

      # P15 — module reference, not atom; cap kind axis is :user.
      for {_action, %Ezagent.Capability{} = cap} <- caps do
        assert cap.kind == :user
        assert cap.behavior == Ezagent.Behavior.UserTokens
      end
    end

    test "state_slice/0 is :user_tokens" do
      assert UT.state_slice() == :user_tokens
    end

    test "init_slice/1 starts with mint_count + revoke_count both at 0" do
      assert UT.init_slice(%{}) == %{mint_count: 0, revoke_count: 0}
    end

    test "interface/0 covers every action in actions/0" do
      iface = UT.interface()

      for action <- UT.actions() do
        assert Map.has_key?(iface, action), "interface/0 missing #{action}"
      end
    end

    test "cap_subjects/0 has one row per action with a human description" do
      subjects = Map.new(UT.cap_subjects())

      for action <- UT.actions() do
        assert is_binary(subjects[action]) and String.length(subjects[action]) > 10
      end
    end

    test "data_owner/1 mirrors Identity (self-owned for concrete URIs, :any wildcard)" do
      # Codex PR #356 r1 MED fix.
      user_uri = URI.parse("entity://user/team-alpha/alice")
      assert UT.data_owner(user_uri) == user_uri
      assert UT.data_owner(:any) == :any
      assert UT.data_owner(:mint_token) == :no_owner
      assert UT.data_owner(:list_tokens) == :no_owner
      assert UT.data_owner(:revoke_token) == :no_owner
    end
  end

  describe "invoke(:mint_token, ...)" do
    setup :setup_user

    test "happy path mints a token + bumps counter + returns plain only once",
         %{user_uri: user_uri, ctx: ctx, slice: slice} do
      assert {:ok, new_slice, %{token_id: token_id, plain: plain, label: nil}} =
               UT.invoke(:mint_token, slice, %{}, ctx)

      assert new_slice.mint_count == 1
      assert is_integer(token_id)
      # The plain token returns the `esr_pat_` prefix per `generate_token/0`.
      assert String.starts_with?(plain, "esr_pat_")

      # Verify against the DB: the row exists but plain isn't recoverable.
      rows = Token.list(user_uri)
      assert length(rows) == 1
      assert hd(rows).id == token_id
      # token_hash is bcrypt — definitely NOT the plain.
      refute hd(rows).token_hash == plain

      # The plain DOES verify against the stored hash.
      assert {:ok, %{caps: _}} = Token.verify(user_uri, plain)
    end

    test "label is propagated into the row", %{ctx: ctx, slice: slice} do
      assert {:ok, _, %{label: "cli-laptop"}} =
               UT.invoke(:mint_token, slice, %{label: "cli-laptop"}, ctx)
    end

    test "second mint bumps counter to 2", %{user_uri: user_uri, ctx: ctx, slice: slice} do
      {:ok, slice1, _} = UT.invoke(:mint_token, slice, %{}, ctx)
      {:ok, slice2, _} = UT.invoke(:mint_token, slice1, %{}, ctx)

      assert slice2.mint_count == 2
      assert length(Token.list(user_uri)) == 2
    end

    test "bad self_uri (wrong scheme) returns :bad_target_uri", %{ctx: ctx, slice: slice} do
      bad_ctx = %{ctx | self_uri: URI.parse("workspace://x")}

      assert {:error, {:bad_target_uri, _}} =
               UT.invoke(:mint_token, slice, %{}, bad_ctx)
    end

    test "expires_at as RFC3339 string is parsed to DateTime (codex r1 MED fix)",
         %{user_uri: user_uri, ctx: ctx, slice: slice} do
      iso = "2099-12-31T23:59:59Z"

      assert {:ok, _, %{token_id: token_id}} =
               UT.invoke(:mint_token, slice, %{expires_at: iso}, ctx)

      row = EzagentCore.Repo.get(Ezagent.Entity.Token, token_id)
      assert %DateTime{year: 2099} = row.expires_at
      _ = user_uri
    end

    test "expires_at as %DateTime{} passes through unchanged",
         %{ctx: ctx, slice: slice} do
      dt = DateTime.new!(~D[2099-12-31], ~T[23:59:59], "Etc/UTC")

      assert {:ok, _, %{token_id: token_id}} =
               UT.invoke(:mint_token, slice, %{expires_at: dt}, ctx)

      row = EzagentCore.Repo.get(Ezagent.Entity.Token, token_id)
      assert DateTime.compare(row.expires_at, dt) == :eq
    end

    test "expires_at as bad string returns :bad_expires_at", %{ctx: ctx, slice: slice} do
      assert {:error, {:bad_expires_at, "not-a-date", _reason}} =
               UT.invoke(:mint_token, slice, %{expires_at: "not-a-date"}, ctx)
    end
  end

  describe "invoke(:list_tokens, ...)" do
    setup :setup_user

    test "empty list when no tokens minted", %{ctx: ctx, slice: slice} do
      assert {:ok, ^slice, %{tokens: []}} =
               UT.invoke(:list_tokens, slice, %{}, ctx)
    end

    test "lists newly minted tokens (id + label + timestamps) but NOT plain",
         %{user_uri: user_uri, ctx: ctx, slice: slice} do
      {_plain, _row} = Token.mint(user_uri, label: "cli-1")
      {_plain2, _row2} = Token.mint(user_uri, label: "cli-2")

      assert {:ok, ^slice, %{tokens: tokens}} =
               UT.invoke(:list_tokens, slice, %{}, ctx)

      assert length(tokens) == 2

      # NEVER include plain — the moduledoc + cap_subject promise.
      for token <- tokens do
        refute Map.has_key?(token, :plain)
        refute Map.has_key?(token, :token_hash)
        # Keys we DO return:
        assert Map.has_key?(token, :id)
        assert Map.has_key?(token, :label)
        assert Map.has_key?(token, :inserted_at)
        assert Map.has_key?(token, :last_used_at)
        assert Map.has_key?(token, :expires_at)
      end

      labels = tokens |> Enum.map(& &1.label) |> Enum.sort()
      assert labels == ["cli-1", "cli-2"]
    end

    test "bad self_uri returns :bad_target_uri", %{ctx: ctx, slice: slice} do
      bad_ctx = %{ctx | self_uri: URI.parse("entity://agent/x/cc_x")}

      assert {:error, {:bad_target_uri, _}} =
               UT.invoke(:list_tokens, slice, %{}, bad_ctx)
    end
  end

  describe "invoke(:revoke_token, ...)" do
    setup :setup_user

    test "revokes the token by id + bumps counter + token can no longer verify",
         %{user_uri: user_uri, ctx: ctx, slice: slice} do
      {plain, row} = Token.mint(user_uri, label: "to-revoke")

      assert {:ok, new_slice, %{revoked: revoked_id}} =
               UT.invoke(:revoke_token, slice, %{token_id: row.id}, ctx)

      assert revoked_id == row.id
      assert new_slice.revoke_count == 1

      # Subsequent verify fails — the row is gone.
      assert {:error, :no_such_entity} = Token.verify(user_uri, plain)
    end

    test "unknown id returns :not_found (codex r1 HIGH cross-entity hardening)",
         %{ctx: ctx, slice: slice} do
      # Codex PR #356 r1 HIGH fix: revoke now pre-fetches the row and
      # refuses if it doesn't belong to ctx.self_uri. Unknown id
      # returns :not_found (not :ok like the legacy idempotent shape)
      # so operators get a clear "no such row" signal.
      assert {:error, :not_found} =
               UT.invoke(:revoke_token, slice, %{token_id: 999_999}, ctx)
    end

    test "cross-entity revoke is refused with :cross_entity_token",
         %{user_uri: user_uri, ctx: ctx, slice: slice} do
      # Mint a token for a DIFFERENT user — the attacker pre-existing
      # in the DB. The current ctx.self_uri is `user_uri` (Alice).
      n = System.unique_integer([:positive])
      # Build via concatenation so the codebase grep gate
      # (`entities_have_workspace_test.exs`) doesn't false-flag
      # the `#{n}` interpolation as a 2-segment literal.
      other_workspace = "ut-other-" <> Integer.to_string(n)
      other_uri = URI.parse("entity://user/" <> other_workspace <> "/bob")
      {:ok, _decoded} = Ezagent.Users.create(other_uri, nil, [])
      {_plain, other_row} = Ezagent.Entity.Token.mint(other_uri, label: "bob-token")

      assert {:error, {:cross_entity_token, requested_owner: requested, actual_owner: actual}} =
               UT.invoke(:revoke_token, slice, %{token_id: other_row.id}, ctx)

      assert requested == URI.to_string(user_uri)
      assert actual == URI.to_string(other_uri)

      # Critically: Bob's token survives Alice's attempted hijack.
      assert length(Ezagent.Entity.Token.list(other_uri)) == 1
    end

    test "non-integer token_id is refused with :bad_args", %{ctx: ctx, slice: slice} do
      assert {:error, {:bad_args, _, _}} =
               UT.invoke(:revoke_token, slice, %{token_id: "not-an-int"}, ctx)
    end
  end

  defp setup_user(_ctx) do
    n = System.unique_integer([:positive])
    ws_name = "ut-test-#{n}"
    user_uri = URI.parse("entity://user/#{ws_name}/alice")

    {:ok, _decoded} = Users.create(user_uri, nil, [])

    ctx = %{caller: user_uri, caps: MapSet.new(), self_uri: user_uri, reply: :sync}
    slice = UT.init_slice(%{})

    {:ok, user_uri: user_uri, ctx: ctx, slice: slice}
  end
end
