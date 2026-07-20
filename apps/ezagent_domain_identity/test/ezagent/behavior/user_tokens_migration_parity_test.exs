defmodule Ezagent.ActionSet.UserTokensMigrationParityTest do
  @moduledoc """
  P2-b migration parity test (SPEC #445 §7.3 Level 1 — dispatch
  parity).

  Validates that the migrated `Ezagent.ActionSet.UserTokens` produces
  the same dispatch-visible outcome via the new-contract path
  (`Kind.Runtime.handle_dispatch/4` → `handle_<action>/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration:

  - Same final slice state (`mint_count` / `revoke_count` incremented)
  - Same dispatch reply shape
  - Same observable side effects (`Token.mint/2` row inserted;
    `Token.revoke/1` row deleted)
  - Same error shapes (`:not_found` / `:cross_entity_token`)
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_invocation!: 2, signed_required_cap!: 5]

  alias Ezagent.ActionSet.UserTokens
  alias Ezagent.Entity.{Token, User}
  alias Ezagent.Invocation
  alias Ezagent.Users

  defp build_invocation(user_uri, action, args) do
    target = Ezagent.URI.new!("#{URI.to_string(user_uri)}?action=user_tokens.#{action}")

    admin = Ezagent.URI.user(:system, :admin)
    cap = signed_required_cap!(target, :user, UserTokens, action, admin)

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{caller: admin, caps: MapSet.new([cap]), reply: :sync}
    }
    |> signed_invocation!(:user)
  end

  setup do
    n = System.unique_integer([:positive])
    user_uri = Ezagent.URI.new!("entity://ut-parity-#{n}/user/alice")
    {:ok, _decoded} = Users.create(user_uri, nil, [])

    state = %{user_tokens: UserTokens.init_slice(%{})}

    {:ok, user_uri: user_uri, state: state}
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test "mint_token dispatch inserts row + bumps mint_count",
         %{user_uri: user_uri, state: state} do
      inv = build_invocation(user_uri, :mint_token, %{label: "parity-mint"})

      assert {:ok, new_state, %{token_id: token_id, plain: plain, label: "parity-mint"}, _evt,
              _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, User, user_uri)

      # Phase B: two-container slice — persistent counter lives under `.state`.
      assert new_state.user_tokens.state.mint_count == 1
      assert String.starts_with?(plain, "esr_pat_")

      # DB row exists.
      rows = Token.list(user_uri)
      assert length(rows) == 1
      assert hd(rows).id == token_id
    end

    test "list_tokens dispatch returns the user's tokens without mutating slice",
         %{user_uri: user_uri, state: state} do
      {_plain, _row} = Token.mint(user_uri, label: "preexisting")

      inv = build_invocation(user_uri, :list_tokens, %{})

      assert {:ok, new_state, %{tokens: [token]}, slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, User, user_uri)

      # No slice mutation — read-only action.
      assert new_state.user_tokens == state.user_tokens
      # slice_change_event is nil because no :set effect mutated state.
      assert slice_change_event == nil
      assert token.label == "preexisting"
    end

    test "revoke_token dispatch deletes row + bumps revoke_count",
         %{user_uri: user_uri, state: state} do
      {_plain, row} = Token.mint(user_uri, label: "to-revoke")

      inv = build_invocation(user_uri, :revoke_token, %{token_id: row.id})

      assert {:ok, new_state, %{revoked: revoked_id}, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, User, user_uri)

      assert revoked_id == row.id
      assert new_state.user_tokens.state.revoke_count == 1
      assert Token.list(user_uri) == []
    end

    test "revoke_token cross-entity returns :cross_entity_token without deleting",
         %{user_uri: user_uri, state: state} do
      n = System.unique_integer([:positive])
      other_workspace = "ut-parity-other-" <> Integer.to_string(n)
      other_uri = URI.parse("entity://" <> other_workspace <> "/user/bob")
      {:ok, _} = Users.create(other_uri, nil, [])
      {_plain, other_row} = Token.mint(other_uri, label: "bob-token")

      inv = build_invocation(user_uri, :revoke_token, %{token_id: other_row.id})

      assert {:error, {:cross_entity_token, requested_owner: _, actual_owner: _}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, User, user_uri)

      # Bob's token survives.
      assert length(Token.list(other_uri)) == 1
    end
  end
end
