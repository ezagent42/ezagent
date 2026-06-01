defmodule Ezagent.Behavior.EchoMigrationParityTest do
  @moduledoc """
  Phase 2-g r3 migration parity test for `Ezagent.Behavior.Echo`.

  Asserts the new-contract Behavior preserves the OUTCOMES the
  legacy `invoke/4`-based implementation provided. The legacy code
  did three things on each invocation:

  1. Mutate slice (`count`, `last_msg`)
  2. Return a result map (`:say` → `%{echo: msg}`)
  3. On `:receive`, side-effect a `chat.send` Invocation back to the
     originating session

  Post-migration the same three outcomes appear as EFFECTS:

  1. `{:set, :count, _}` + `{:set, :last_msg, _}`
  2. `{:ok, %{echo: msg}, _}` direct return tuple
  3. `{:dispatch, %Cmd{action: :send, target: session-URI?action=chat.send,
                       args: %{message: %Message{}}}}`

  This test pins the externally-observable contract at the boundary
  the runtime cares about. If a future refactor breaks any of these
  invariants the migration is structurally broken.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Echo

  describe ":say parity" do
    test "increments count by 1 starting from any base" do
      # Lifecycle (SPEC 2026-05-29 §2.3): the `read` closure +
      # `apply_effects/2` both work against the FLAT persistent `.state`
      # container (`apply_effects` returns `{:ok, %{state: new_state}}`).
      state0 = Echo.init_slice(%{}).state
      ctx0 = %{read: fn k, d -> Map.get(state0, k, d) end}
      {:ok, _result, effects0} = Echo.handle_say(%{msg: "first"}, ctx0)
      {:ok, %{state: state1}} = Ezagent.Behavior.apply_effects(effects0, state0)
      assert state1.count == 1
      assert state1.last_msg == "first"

      # second say with the new state
      ctx1 = %{read: fn k, d -> Map.get(state1, k, d) end}
      {:ok, _result, effects1} = Echo.handle_say(%{msg: "second"}, ctx1)
      {:ok, %{state: state2}} = Ezagent.Behavior.apply_effects(effects1, state1)
      assert state2.count == 2
      assert state2.last_msg == "second"
    end

    test ":say result tuple shape is {:ok, %{echo: msg}, [effects]}" do
      ctx = %{read: fn _k, d -> d end}

      assert {:ok, result, effects} = Echo.handle_say(%{msg: "world"}, ctx)
      assert result == %{echo: "world"}
      assert is_list(effects)
    end
  end

  describe ":receive parity" do
    test "produces a chat.send dispatch with text='echo: <input>'" do
      input_msg =
        Ezagent.Message.new(
          Ezagent.URI.new!("entity://user/ws/alice"),
          %{text: "ping"}
        )

      session_uri = Ezagent.URI.new!("session://default/ws/main")
      self_uri = Ezagent.URI.new!("entity://agent/ws/echo_test")

      ctx = %{
        read: fn _k, d -> d end,
        self_uri: self_uri,
        caller: session_uri
      }

      assert {:ok, _, effects} = Echo.handle_receive(%{message: input_msg}, ctx)

      assert [{:dispatch, cmd}] = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert cmd.action == :send
      assert %Ezagent.Message{body: %{text: "echo: ping"}, sender: ^self_uri} = cmd.args.message
    end

    test "increments count + stashes last_msg on :receive" do
      input_msg =
        Ezagent.Message.new(Ezagent.URI.new!("entity://user/ws/alice"), %{text: "pong"})

      ctx = %{
        read: fn :count, _ -> 3; _, d -> d end,
        self_uri: Ezagent.URI.new!("entity://agent/ws/echo_test"),
        caller: Ezagent.URI.new!("session://default/ws/main")
      }

      assert {:ok, _, effects} = Echo.handle_receive(%{message: input_msg}, ctx)
      assert {:set, :count, 4} in effects
      assert {:set, :last_msg, "pong"} in effects
    end

    test "stress meta gates the reply dispatch (hop >= turn_cap → no dispatch)" do
      msg =
        Ezagent.Message.new(
          Ezagent.URI.new!("entity://user/ws/alice"),
          %{text: "x", meta: %{"hop" => 2, "turn_cap" => 2}}
        )

      ctx = %{
        read: fn _k, d -> d end,
        self_uri: Ezagent.URI.new!("entity://agent/ws/echo_test"),
        caller: Ezagent.URI.new!("session://default/ws/main")
      }

      assert {:ok, _, effects} = Echo.handle_receive(%{message: msg}, ctx)
      assert Enum.filter(effects, &match?({:dispatch, _}, &1)) == []
    end
  end

  describe "macro-derived legacy callbacks (backwards-compat parity)" do
    test "actions/0 returns same set as pre-migration" do
      assert MapSet.new(Echo.actions()) == MapSet.new([:say, :receive])
    end

    test "interface/0 keys cover both actions" do
      iface = Echo.interface()
      assert Map.has_key?(iface, :say)
      assert Map.has_key?(iface, :receive)
    end

    test "required_caps/0 keys match actions/0" do
      caps = Echo.required_caps()
      assert MapSet.new(Map.keys(caps)) == MapSet.new(Echo.actions())
    end

    test "cap_subjects/0 has English descriptions" do
      Enum.each(Echo.cap_subjects(), fn {_action, desc} ->
        assert is_binary(desc) and byte_size(desc) > 0
      end)
    end
  end
end
