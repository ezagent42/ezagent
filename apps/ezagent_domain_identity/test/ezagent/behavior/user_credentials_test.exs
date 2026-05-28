defmodule Ezagent.Behavior.UserCredentialsTest do
  @moduledoc """
  Tests for the dispatch-backed UserCredentials Behavior — HIGH-2
  completion (`docs/futures/todo.md` CLI ↔ GUI parity).

  P2-b migration (2026-05-28): rewritten to exercise the new-contract
  `handle_set_password/2` handler (SPEC #445 §4 + §6.2). The legacy
  `invoke/4` shim is gone; assertions are against the new
  `(args, ctx) → {:ok, result, effects}` shape. Dispatch parity (the
  Router.dispatch end-to-end check) lives in the sibling
  `user_credentials_migration_parity_test.exs`.

  Split into:

  - Contract surface (`__action_names__/0`, `required_caps/0`,
    `state_slice/0`, `__actions__/0`, `cap_subjects/0`) — pure unit, async.
  - `handle_set_password/2` action body — needs the DB (uses
    `EzagentCore.DataCase`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.UserCredentials, as: UC
  alias Ezagent.Users

  describe "contract surface" do
    test "actions/0 lists :set_password only" do
      assert UC.actions() == [:set_password]
    end

    test "new-contract __action_names__/0 lists :set_password" do
      assert UC.__action_names__() == [:set_password]
    end

    test "new-contract marker __behavior__?/0 is true" do
      assert UC.__behavior__?() == true
    end

    test "required_caps/0 has an entry per action with the SPEC v2 struct shape" do
      caps = UC.required_caps()

      for action <- UC.actions() do
        assert Map.has_key?(caps, action),
               "required_caps/0 missing #{action} — dispatch step 5.5 would crash"
      end

      %Ezagent.Capability{kind: kind, behavior: behavior} = caps[:set_password]
      # P2-b migration: cap shape preserved via explicit
      # `def required_caps` (the auto-derived macro version
      # hardcodes `kind: :any`; we override to keep `kind: :user`).
      assert kind == :user
      assert behavior == Ezagent.Behavior.UserCredentials
    end

    test "state_slice/0 is :user_credentials" do
      assert UC.state_slice() == :user_credentials
    end

    test "init_slice/1 starts with set_password_count: 0" do
      assert UC.init_slice(%{}) == %{set_password_count: 0}
    end

    test "__actions__/0 covers every action in actions/0 (new-contract interface source)" do
      action_specs = UC.__actions__()

      for action <- UC.actions() do
        assert Map.has_key?(action_specs, action), "__actions__/0 missing #{action}"
      end

      spec = action_specs[:set_password]
      assert spec.args == %{password: :string}
      assert spec.returns == %{user_uri: :string, password_set: :boolean}
      assert spec.modes == [:call]
    end

    test "cap_subjects/0 has one row per action with a human description" do
      subjects = Map.new(UC.cap_subjects())

      for action <- UC.actions() do
        assert is_binary(subjects[action]) and String.length(subjects[action]) > 10,
               "cap_subjects/0 missing #{action} or description too short"
      end
    end

    test "data_owner/1 mirrors Identity (self-owned for concrete URIs, :any wildcard)" do
      user_uri = URI.parse("entity://user/team-alpha/alice")
      assert UC.data_owner(user_uri) == user_uri
      assert UC.data_owner(:any) == :any
      assert UC.data_owner(:set_password) == :no_owner
    end
  end

  describe "handle_set_password/2 action body" do
    setup do
      # Each test gets a unique user URI so DB isolation is clean.
      n = System.unique_integer([:positive])
      ws_name = "uc-test-#{n}"
      user_uri = URI.parse("entity://user/#{ws_name}/alice")

      {:ok, _decoded} = Users.create(user_uri, "initial-password", [])

      ctx = %{
        caller: user_uri,
        caps: MapSet.new(),
        self_uri: user_uri,
        reply: :sync,
        read: fn _key, default -> default end
      }

      {:ok, user_uri: user_uri, ctx: ctx}
    end

    test "happy path rotates the password + returns effects",
         %{user_uri: user_uri, ctx: ctx} do
      assert {:ok, %{user_uri: returned_uri, password_set: true}, effects} =
               UC.handle_set_password(%{password: "rotated"}, ctx)

      assert returned_uri == URI.to_string(user_uri)

      # Effects: one `:set` (bumps counter) + one `:emit` (audit event).
      assert {:set, :set_password_count, 1} in effects
      assert Enum.any?(effects, &match?({:emit, :password_set, _}, &1))

      # Verify the password actually rotated in the DB (this is the
      # one piece the legacy task did + we MUST preserve).
      refute Users.verify_password(user_uri, "initial-password")
      assert Users.verify_password(user_uri, "rotated")
    end

    test "second rotation reads via ctx[:read] and bumps counter to 2",
         %{user_uri: user_uri, ctx: ctx} do
      # First rotation — ctx[:read].(:set_password_count, 0) returns 0.
      assert {:ok, %{password_set: true}, effects1} =
               UC.handle_set_password(%{password: "step1"}, ctx)

      assert {:set, :set_password_count, 1} in effects1

      # Second rotation — simulate the runtime exposing the bumped slice
      # via ctx[:read].
      ctx2 = %{ctx | read: fn key, default ->
                       case key do
                         :set_password_count -> 1
                         _ -> default
                       end
                     end}

      assert {:ok, %{password_set: true}, effects2} =
               UC.handle_set_password(%{password: "step2"}, ctx2)

      assert {:set, :set_password_count, 2} in effects2
      assert Users.verify_password(user_uri, "step2")
    end

    test "empty password is refused with :bad_args (defence in depth past validator)",
         %{ctx: ctx} do
      assert {:error, {:bad_args, _, _}} =
               UC.handle_set_password(%{password: ""}, ctx)
    end

    test "nil password is refused with :bad_args", %{ctx: ctx} do
      assert {:error, {:bad_args, _, _}} =
               UC.handle_set_password(%{password: nil}, ctx)
    end

    test "non-existent user URI returns {:error, :not_found}", %{ctx: ctx} do
      ghost_uri = URI.parse("entity://user/uc-test-ghost/no-such-user")
      ghost_ctx = %{ctx | self_uri: ghost_uri}

      assert {:error, :not_found} =
               UC.handle_set_password(%{password: "x"}, ghost_ctx)
    end

    test "bad self_uri (wrong scheme) is refused with :bad_target_uri", %{ctx: ctx} do
      bad_ctx = %{ctx | self_uri: URI.parse("workspace://x")}

      assert {:error, {:bad_target_uri, _}} =
               UC.handle_set_password(%{password: "x"}, bad_ctx)
    end

    test "bad self_uri (agent entity, not user) is refused with :bad_target_uri",
         %{ctx: ctx} do
      agent_ctx = %{ctx | self_uri: URI.parse("entity://agent/x/cc_x")}

      assert {:error, {:bad_target_uri, _}} =
               UC.handle_set_password(%{password: "x"}, agent_ctx)
    end
  end
end
