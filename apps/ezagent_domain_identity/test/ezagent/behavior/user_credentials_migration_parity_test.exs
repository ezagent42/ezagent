defmodule Ezagent.ActionSet.UserCredentialsMigrationParityTest do
  @moduledoc """
  P2-b migration parity test (SPEC #445 §7.3 Level 1 — dispatch
  parity).

  Validates that the migrated `Ezagent.ActionSet.UserCredentials`
  produces the same dispatch-visible outcome via the new-contract
  path (`Kind.Runtime.handle_dispatch/4` → `handle_set_password/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration:

  - Same final slice state (`set_password_count` incremented)
  - Same dispatch reply (`{:ok, _state, %{user_uri, password_set: true}, _evt}`)
  - Same observable side effect (`Ezagent.Users.set_password/2` was
    actually called — verified by `Users.verify_password/2` against
    the new password)
  - Same error shapes for bad inputs

  Per §7.3 the parity check goes through Kind.Runtime so the cap-axis
  derivation + slice-change emit + effect bucket-execution all run as
  they would in production.
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_invocation!: 2, signed_required_cap!: 5]

  alias Ezagent.ActionSet.UserCredentials
  alias Ezagent.Entity.User
  alias Ezagent.Invocation
  alias Ezagent.Users

  defp build_invocation(user_uri, action, args) do
    target = Ezagent.URI.with_action(user_uri, :user_credentials, action)

    admin = Ezagent.URI.user(:system, :admin)
    cap = signed_required_cap!(target, :user, UserCredentials, action, admin)

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: admin,
        caps: MapSet.new([cap]),
        reply: :sync
      }
    }
    |> signed_invocation!(:user)
  end

  setup do
    n = System.unique_integer([:positive])
    user_uri = Ezagent.URI.new!("entity://uc-parity-#{n}/user/alice")
    {:ok, _decoded} = Users.create(user_uri, "initial-pw", [])

    state = %{
      user_credentials: UserCredentials.init_slice(%{})
    }

    {:ok, user_uri: user_uri, state: state}
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test "set_password through new-contract dispatch rotates the password + bumps counter",
         %{user_uri: user_uri, state: state} do
      inv = build_invocation(user_uri, :set_password, %{password: "rotated-via-dispatch"})

      assert {:ok, new_state, result, slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, User, user_uri)

      # Result shape preserved from legacy invoke/4 days.
      assert result == %{user_uri: URI.to_string(user_uri), password_set: true}

      # Slice mutation: counter went from 0 to 1.
      # Phase B: two-container slice — persistent counter lives under `.state`.
      assert new_state.user_credentials.state.set_password_count == 1

      # slice_change event fired because :set effect mutated the slice.
      assert is_map(slice_change_event)
      assert slice_change_event.slice_key == :user_credentials

      # Side effect actually happened — verify against the live DB.
      refute Users.verify_password(user_uri, "initial-pw")
      assert Users.verify_password(user_uri, "rotated-via-dispatch")
    end

    test "second dispatch on the post-#1 state lifts counter to 2",
         %{user_uri: user_uri, state: state} do
      inv1 = build_invocation(user_uri, :set_password, %{password: "step1"})

      assert {:ok, state_after_1, _r1, _e1, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv1, state, User, user_uri)

      assert state_after_1.user_credentials.state.set_password_count == 1

      inv2 = build_invocation(user_uri, :set_password, %{password: "step2"})

      assert {:ok, state_after_2, _r2, _e2, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv2, state_after_1, User, user_uri)

      assert state_after_2.user_credentials.state.set_password_count == 2
      assert Users.verify_password(user_uri, "step2")
    end

    test "empty password is rejected with :bad_args (same shape as legacy)",
         %{user_uri: user_uri, state: state} do
      inv = build_invocation(user_uri, :set_password, %{password: ""})

      assert {:error, {:bad_args, _, _}} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, User, user_uri)
    end

    test "missing target user (ghost URI) propagates :not_found from Users.set_password",
         %{state: state} do
      ghost_uri = Ezagent.URI.new!("entity://uc-parity-ghost/user/no-such-user")
      inv = build_invocation(ghost_uri, :set_password, %{password: "x"})

      assert {:error, :not_found} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, User, ghost_uri)
    end
  end
end
