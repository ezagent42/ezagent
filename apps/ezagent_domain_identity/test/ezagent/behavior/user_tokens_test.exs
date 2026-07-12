defmodule Ezagent.ActionSet.UserTokensTest do
  @moduledoc """
  Tests for the dispatch-backed UserTokens Behavior — HIGH-2
  completion (`docs/futures/todo.md` CLI ↔ GUI parity).

  P2-b migration (2026-05-28): rewritten to exercise the new-contract
  `handle_<action>/2` handlers (SPEC #445 §4 + §6.2). Dispatch parity
  via Kind.Runtime lives in
  `user_tokens_migration_parity_test.exs`.

  Split into:

  - Contract surface — pure unit, async-ish.
  - `handle_<action>/2` action bodies — need the DB (use `EzagentCore.DataCase`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.UserTokens, as: UT
  alias Ezagent.Users
  alias Ezagent.Entity.Token

  describe "contract surface" do
    test "actions/0 lists all three actions" do
      assert UT.actions() == [:mint_token, :list_tokens, :revoke_token]
    end

    test "new-contract marker __behavior__?/0 is true" do
      assert UT.__behavior__?() == true
    end

    test "__action_names__/0 lists all three actions" do
      assert UT.__action_names__() == [:mint_token, :list_tokens, :revoke_token]
    end

    test "required_caps/0 has an entry per action with the SPEC v2 struct shape" do
      caps = UT.required_caps()

      for action <- UT.actions() do
        assert Map.has_key?(caps, action),
               "required_caps/0 missing #{action} — dispatch step 5.5 would crash"
      end

      # P2-b migration: cap shape preserved via explicit
      # `def required_caps` (kind: :user axis).
      for {_action, %Ezagent.Capability{} = cap} <- caps do
        assert cap.kind == :user
        assert cap.behavior == Ezagent.ActionSet.UserTokens
      end
    end

    test "state_slice/0 is :user_tokens" do
      assert UT.state_slice() == :user_tokens
    end

    # Phase B: `init_slice/1` → `create/1` (PERSISTENT state).
    test "create/1 starts with mint_count + revoke_count both at 0" do
      assert UT.create(%{}) == {:ok, %{mint_count: 0, revoke_count: 0}}
    end

    test "__actions__/0 covers every action in actions/0" do
      action_specs = UT.__actions__()

      for action <- UT.actions() do
        assert Map.has_key?(action_specs, action), "__actions__/0 missing #{action}"
      end
    end

    test "cap_subjects/0 has one row per action with a human description" do
      subjects = Map.new(UT.cap_subjects())

      for action <- UT.actions() do
        assert is_binary(subjects[action]) and String.length(subjects[action]) > 10
      end
    end

    test "data_owner/1 mirrors Identity (self-owned for concrete URIs, :any wildcard)" do
      user_uri = Ezagent.URI.new!("entity://team-alpha/user/alice")
      assert UT.data_owner(user_uri) == user_uri
      assert UT.data_owner(:any) == :any
      assert UT.data_owner(:mint_token) == :no_owner
      assert UT.data_owner(:list_tokens) == :no_owner
      assert UT.data_owner(:revoke_token) == :no_owner
    end
  end

  describe "handle_mint_token/2" do
    setup :setup_user

    test "happy path mints a token + emits :set + :emit effects + returns plain once",
         %{user_uri: user_uri, ctx: ctx} do
      assert {:ok, %{token_id: token_id, plain: plain, label: nil}, effects} =
               UT.handle_mint_token(%{}, ctx)

      assert is_integer(token_id)
      assert String.starts_with?(plain, "esr_pat_")
      assert {:set, :mint_count, 1} in effects
      assert Enum.any?(effects, &match?({:emit, :token_minted, _}, &1))

      # Verify against the DB: the row exists but plain isn't recoverable.
      rows = Token.list(user_uri)
      assert length(rows) == 1
      assert hd(rows).id == token_id
      refute hd(rows).token_hash == plain

      assert {:ok, ^user_uri} = Ezagent.Authentication.authenticate(plain)
    end

    test "label is propagated into the row", %{ctx: ctx} do
      assert {:ok, %{label: "cli-laptop"}, _effects} =
               UT.handle_mint_token(%{label: "cli-laptop"}, ctx)
    end

    test "ctx[:read] returning N produces mint_count: N+1", %{ctx: ctx} do
      ctx_after_one = %{
        ctx
        | read: fn key, default ->
            case key do
              :mint_count -> 1
              _ -> default
            end
          end
      }

      assert {:ok, _result, effects} = UT.handle_mint_token(%{}, ctx_after_one)
      assert {:set, :mint_count, 2} in effects
    end

    test "bad self_uri (wrong scheme) returns :bad_target_uri", %{ctx: ctx} do
      bad_ctx = %{ctx | self_uri: Ezagent.URI.new!("workspace://x")}

      assert {:error, {:bad_target_uri, _}} = UT.handle_mint_token(%{}, bad_ctx)
    end

    test "expires_at as RFC3339 string is parsed to DateTime (codex r1 MED fix)",
         %{ctx: ctx} do
      iso = "2099-12-31T23:59:59Z"

      assert {:ok, %{token_id: token_id}, _effects} =
               UT.handle_mint_token(%{expires_at: iso}, ctx)

      row = EzagentCore.Repo.get(Ezagent.Entity.Token, token_id)
      assert %DateTime{year: 2099} = row.expires_at
    end

    test "expires_at as %DateTime{} passes through unchanged", %{ctx: ctx} do
      dt = DateTime.new!(~D[2099-12-31], ~T[23:59:59], "Etc/UTC")

      assert {:ok, %{token_id: token_id}, _effects} =
               UT.handle_mint_token(%{expires_at: dt}, ctx)

      row = EzagentCore.Repo.get(Ezagent.Entity.Token, token_id)
      assert DateTime.compare(row.expires_at, dt) == :eq
    end

    test "expires_at as bad string returns :bad_expires_at", %{ctx: ctx} do
      assert {:error, {:bad_expires_at, "not-a-date", _reason}} =
               UT.handle_mint_token(%{expires_at: "not-a-date"}, ctx)
    end
  end

  describe "handle_list_tokens/2" do
    setup :setup_user

    test "empty list when no tokens minted (no effects, slice unchanged)",
         %{ctx: ctx} do
      assert {:ok, %{tokens: []}, []} = UT.handle_list_tokens(%{}, ctx)
    end

    test "lists newly minted tokens (id + label + timestamps) but NOT plain",
         %{user_uri: user_uri, ctx: ctx} do
      {_plain, _row} = Token.mint(user_uri, label: "cli-1")
      {_plain2, _row2} = Token.mint(user_uri, label: "cli-2")

      assert {:ok, %{tokens: tokens}, []} = UT.handle_list_tokens(%{}, ctx)

      assert length(tokens) == 2

      for token <- tokens do
        refute Map.has_key?(token, :plain)
        refute Map.has_key?(token, :token_hash)
        assert Map.has_key?(token, :id)
        assert Map.has_key?(token, :label)
        assert Map.has_key?(token, :inserted_at)
        assert Map.has_key?(token, :last_used_at)
        assert Map.has_key?(token, :expires_at)
      end

      labels = tokens |> Enum.map(& &1.label) |> Enum.sort()
      assert labels == ["cli-1", "cli-2"]
    end

    test "bad self_uri returns :bad_target_uri", %{ctx: ctx} do
      bad_ctx = %{ctx | self_uri: Ezagent.URI.new!("entity://x/agent/cc_x")}

      assert {:error, {:bad_target_uri, _}} = UT.handle_list_tokens(%{}, bad_ctx)
    end
  end

  describe "handle_revoke_token/2" do
    setup :setup_user

    test "revokes the token by id + emits effects + token can no longer verify",
         %{user_uri: user_uri, ctx: ctx} do
      {plain, row} = Token.mint(user_uri, label: "to-revoke")

      assert {:ok, %{revoked: revoked_id}, effects} =
               UT.handle_revoke_token(%{token_id: row.id}, ctx)

      assert revoked_id == row.id
      assert {:set, :revoke_count, 1} in effects
      assert Enum.any?(effects, &match?({:emit, :token_revoked, _}, &1))

      # Subsequent verify fails — the row is gone.
      assert {:error, :invalid_credentials} = Ezagent.Authentication.authenticate(plain)
    end

    test "unknown id returns :not_found (codex r1 HIGH cross-entity hardening)",
         %{ctx: ctx} do
      assert {:error, :not_found} =
               UT.handle_revoke_token(%{token_id: 999_999}, ctx)
    end

    test "cross-entity revoke is refused with :cross_entity_token",
         %{user_uri: user_uri, ctx: ctx} do
      n = System.unique_integer([:positive])
      other_workspace = "ut-other-" <> Integer.to_string(n)
      other_uri = URI.parse("entity://" <> other_workspace <> "/user/bob")
      {:ok, _decoded} = Ezagent.Users.create(other_uri, nil, [])
      {_plain, other_row} = Ezagent.Entity.Token.mint(other_uri, label: "bob-token")

      assert {:error, {:cross_entity_token, requested_owner: requested, actual_owner: actual}} =
               UT.handle_revoke_token(%{token_id: other_row.id}, ctx)

      assert requested == URI.to_string(user_uri)
      assert actual == URI.to_string(other_uri)

      # Critically: Bob's token survives Alice's attempted hijack.
      assert length(Ezagent.Entity.Token.list(other_uri)) == 1
    end

    test "non-integer token_id is refused with :bad_args", %{ctx: ctx} do
      assert {:error, {:bad_args, _, _}} =
               UT.handle_revoke_token(%{token_id: "not-an-int"}, ctx)
    end
  end

  defp setup_user(_ctx) do
    n = System.unique_integer([:positive])
    ws_name = "ut-test-#{n}"
    user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/alice")

    {:ok, _decoded} = Users.create(user_uri, nil, [])

    ctx = %{
      caller: user_uri,
      caps: MapSet.new(),
      self_uri: user_uri,
      reply: :sync,
      read: fn _key, default -> default end
    }

    {:ok, user_uri: user_uri, ctx: ctx}
  end
end
