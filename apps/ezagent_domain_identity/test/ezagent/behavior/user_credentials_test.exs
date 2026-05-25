defmodule Ezagent.Behavior.UserCredentialsTest do
  @moduledoc """
  Tests for the dispatch-backed UserCredentials Behavior — HIGH-2
  completion (`docs/futures/todo.md` CLI ↔ GUI parity).

  Split into:

  - Contract surface (`actions/0`, `required_caps/0`, `state_slice/0`,
    `interface/0`, `cap_subjects/0`) — pure unit, async.
  - `invoke(:set_password, ...)` action body — needs the DB (uses
    `EzagentCore.DataCase`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Behavior.UserCredentials, as: UC
  alias Ezagent.Users

  describe "contract surface" do
    test "actions/0 lists :set_password only" do
      assert UC.actions() == [:set_password]
    end

    test "required_caps/0 has an entry per action with the SPEC v2 struct shape" do
      caps = UC.required_caps()

      for action <- UC.actions() do
        assert Map.has_key?(caps, action),
               "required_caps/0 missing #{action} — dispatch step 5.5 would crash"
      end

      %Ezagent.Capability{kind: kind, behavior: behavior} = caps[:set_password]
      # P15: cap kind is the User Kind axis (not :user as atom but
      # AS the kind axis tag), behavior is the MODULE reference.
      assert kind == :user
      assert behavior == Ezagent.Behavior.UserCredentials
    end

    test "state_slice/0 is :user_credentials" do
      assert UC.state_slice() == :user_credentials
    end

    test "init_slice/1 starts with set_password_count: 0" do
      assert UC.init_slice(%{}) == %{set_password_count: 0}
    end

    test "interface/0 covers every action in actions/0" do
      iface = UC.interface()

      for action <- UC.actions() do
        assert Map.has_key?(iface, action), "interface/0 missing #{action}"
      end
    end

    test "cap_subjects/0 has one row per action with a human description" do
      subjects = Map.new(UC.cap_subjects())

      for action <- UC.actions() do
        assert is_binary(subjects[action]) and String.length(subjects[action]) > 10,
               "cap_subjects/0 missing #{action} or description too short"
      end
    end

    test "data_owner/1 mirrors Identity (self-owned for concrete URIs, :any wildcard)" do
      # Codex PR #356 r1 MED fix: :self is NOT a valid return shape per
      # Ezagent.Behavior @callback data_owner. Mirrors the Identity /
      # ApiKeys pattern: concrete URI → itself, :any → :any, else no_owner.
      user_uri = URI.parse("entity://user/team-alpha/alice")
      assert UC.data_owner(user_uri) == user_uri
      assert UC.data_owner(:any) == :any
      assert UC.data_owner(:set_password) == :no_owner
    end
  end

  describe "invoke(:set_password, ...) action body" do
    setup do
      # Each test gets a unique user URI so DB isolation is clean.
      n = System.unique_integer([:positive])
      ws_name = "uc-test-#{n}"
      user_uri = URI.parse("entity://user/#{ws_name}/alice")

      {:ok, _decoded} = Users.create(user_uri, "initial-password", [])

      ctx = %{caller: user_uri, caps: MapSet.new(), self_uri: user_uri, reply: :sync}
      slice = UC.init_slice(%{})

      {:ok, user_uri: user_uri, ctx: ctx, slice: slice}
    end

    test "happy path rotates the password + bumps counter + returns new state",
         %{user_uri: user_uri, ctx: ctx, slice: slice} do
      assert {:ok, new_slice, %{user_uri: returned_uri, password_set: true}} =
               UC.invoke(:set_password, slice, %{password: "rotated"}, ctx)

      assert new_slice.set_password_count == 1
      assert returned_uri == URI.to_string(user_uri)

      # Verify the password actually rotated in the DB (this is the
      # one piece the legacy task did + we MUST preserve).
      refute Users.verify_password(user_uri, "initial-password")
      assert Users.verify_password(user_uri, "rotated")
    end

    test "second rotation bumps counter to 2", %{user_uri: user_uri, ctx: ctx, slice: slice} do
      {:ok, slice1, _} = UC.invoke(:set_password, slice, %{password: "step1"}, ctx)
      {:ok, slice2, _} = UC.invoke(:set_password, slice1, %{password: "step2"}, ctx)

      assert slice2.set_password_count == 2
      assert Users.verify_password(user_uri, "step2")
    end

    test "empty password is refused with :bad_args (defence in depth past validator)",
         %{ctx: ctx, slice: slice} do
      assert {:error, {:bad_args, _, _}} =
               UC.invoke(:set_password, slice, %{password: ""}, ctx)
    end

    test "nil password is refused with :bad_args", %{ctx: ctx, slice: slice} do
      assert {:error, {:bad_args, _, _}} =
               UC.invoke(:set_password, slice, %{password: nil}, ctx)
    end

    test "non-existent user URI returns {:error, :not_found}", %{ctx: ctx, slice: slice} do
      ghost_uri = URI.parse("entity://user/uc-test-ghost/no-such-user")
      ghost_ctx = %{ctx | self_uri: ghost_uri}

      assert {:error, :not_found} =
               UC.invoke(:set_password, slice, %{password: "x"}, ghost_ctx)
    end

    test "bad self_uri (wrong scheme) is refused with :bad_target_uri",
         %{ctx: ctx, slice: slice} do
      bad_ctx = %{ctx | self_uri: URI.parse("workspace://x")}

      assert {:error, {:bad_target_uri, _}} =
               UC.invoke(:set_password, slice, %{password: "x"}, bad_ctx)
    end

    test "bad self_uri (agent entity, not user) is refused with :bad_target_uri",
         %{ctx: ctx, slice: slice} do
      agent_ctx = %{ctx | self_uri: URI.parse("entity://agent/x/cc_x")}

      assert {:error, {:bad_target_uri, _}} =
               UC.invoke(:set_password, slice, %{password: "x"}, agent_ctx)
    end
  end
end
