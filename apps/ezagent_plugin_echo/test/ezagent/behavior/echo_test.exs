defmodule Ezagent.Behavior.EchoTest do
  @moduledoc """
  Phase 2-g r3 migration: tests refactored to exercise the
  new-contract `handle_<action>/2` + effects vocabulary instead of
  the legacy `invoke/4` callback.

  Parity assertions (same OUTCOMES as pre-migration):

  - `:say` increments `:count` and stashes `:last_msg`
  - `:say` returns `%{echo: msg}` to the caller
  - state_slice + init_slice + interface shape unchanged
  - the legacy `interface/0` callback is now MACRO-DERIVED — the
    test asserts the macro emits the right shape (same as the
    hand-written interface/0 it replaced)
  """

  use ExUnit.Case, async: true
  alias Ezagent.Behavior.Echo

  describe "macro-derived metadata" do
    test "actions/0 returns [:say, :receive]" do
      assert :say in Echo.actions()
      assert :receive in Echo.actions()
      assert length(Echo.actions()) == 2
    end

    test "interface/0 declares :say with :string args + returns" do
      iface = Echo.interface()
      assert %{say: %{args: %{msg: :string}, returns: %{echo: :string}, modes: modes}} = iface
      assert :call in modes
      assert :cast in modes
    end

    test "interface/0 declares :receive (chat-fanout reply action)" do
      iface = Echo.interface()
      assert %{receive: %{args: %{message: :map}, modes: modes}} = iface
      assert :cast in modes
    end

    test "state_slice/0 is :echo" do
      assert Echo.state_slice() == :echo
    end

    test "init_slice/1 returns the two-container slice; .state holds the persistent fields" do
      # Lifecycle (SPEC 2026-05-29 §2.3): `init_slice/1` is macro-emitted
      # and returns `%{state:, transients:}`; `create/1` builds the
      # persistent `.state` (Echo has no transients).
      # A8 — added `flavor: "echo"` to persistent state for cold-load
      # flavor resolution via `AgentFlavorResolver.flavor_from_durable_snapshot/1`.
      assert Echo.init_slice(%{}) ==
               %{state: %{flavor: "echo", count: 0, last_msg: nil}, transients: %{}}

      assert {:ok, %{flavor: "echo", count: 0, last_msg: nil}} = Echo.create(%{})
    end

    test "required_caps/0 uses :agent kind axis (echo is now Entity.Agent)" do
      caps = Echo.required_caps()
      assert %Ezagent.Capability{} = caps.say
      # Kind axis is :agent because echo agents ride Ezagent.Entity.Agent (type_name :agent).
      assert caps.say.kind == :agent
      assert caps.receive.kind == :agent
    end

    test "cap_subjects/0 returns descriptions for every action" do
      subjects = Echo.cap_subjects() |> Map.new()
      assert is_binary(subjects[:say])
      assert is_binary(subjects[:receive])
    end

    test "Behavior.new_style?/1 detects the new contract" do
      assert Ezagent.Behavior.new_style?(Echo)
    end
  end

  describe "handle_say/2 — new-contract handler" do
    test "returns {:ok, %{echo: msg}, [:set count, :set last_msg]} effects" do
      ctx = %{read: fn _key, default -> default end}

      assert {:ok, %{echo: "hello"}, effects} =
               Echo.handle_say(%{msg: "hello"}, ctx)

      assert {:set, :count, 1} in effects
      assert {:set, :last_msg, "hello"} in effects
    end

    test "increments count using ctx.read" do
      ctx = %{
        read: fn
          :count, _ -> 5
          _, d -> d
        end
      }

      assert {:ok, _result, effects} = Echo.handle_say(%{msg: "x"}, ctx)
      assert {:set, :count, 6} in effects
    end

    test "apply_effects/2 commits :set effects against slice" do
      # End-to-end: handle_say emits effects, apply_effects mutates state.
      # The framework `read` closure + `apply_effects/2` work against the
      # FLAT persistent `.state` container.
      state = Echo.init_slice(%{}).state
      ctx = %{read: fn k, d -> Map.get(state, k, d) end}

      {:ok, _result, effects} = Echo.handle_say(%{msg: "hello"}, ctx)

      assert {:ok, %{state: new_state}} = Ezagent.Behavior.apply_effects(effects, state)
      assert new_state.count == 1
      assert new_state.last_msg == "hello"
    end
  end

  describe "handle_receive/2 — chat fan-out reply" do
    test "ignores message when caller is absent (no dispatch effect emitted)" do
      msg =
        Ezagent.Message.new(
          Ezagent.URI.new!("entity://team-alpha/agent/echo_default"),
          %{text: "hi"}
        )

      ctx = %{
        read: fn _k, d -> d end,
        self_uri: Ezagent.URI.new!("entity://team-alpha/agent/echo_default")
        # no :caller in ctx → no session URI → no dispatch effect
      }

      assert {:ok, _, effects} = Echo.handle_receive(%{message: msg}, ctx)

      # `:set` effects still apply (count + last_msg), but no `:dispatch`.
      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert dispatches == []
    end

    test "emits :dispatch effect targeting the session's chat.send when caller is a session URI" do
      msg =
        Ezagent.Message.new(
          Ezagent.URI.new!("entity://team-alpha/user/alice"),
          %{text: "ping"}
        )

      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")
      agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/echo_default")

      ctx = %{
        read: fn _k, d -> d end,
        self_uri: agent_uri,
        caller: session_uri
      }

      assert {:ok, _, effects} = Echo.handle_receive(%{message: msg}, ctx)

      assert [{:dispatch, %Ezagent.Cmd{} = cmd}] =
               Enum.filter(effects, &match?({:dispatch, _}, &1))

      assert cmd.action == :send
      assert URI.to_string(cmd.target) =~ "action=session.send"
      assert URI.to_string(cmd.target) =~ "session://team-alpha/default/main"
      # The reply text format
      assert %Ezagent.Message{body: %{text: "echo: ping"}} = cmd.args.message
    end

    test "suppresses reply when stress turn_cap == 0 (sink mode)" do
      msg =
        Ezagent.Message.new(
          Ezagent.URI.new!("entity://team-alpha/user/alice"),
          %{text: "ping", meta: %{"hop" => 0, "turn_cap" => 0}}
        )

      ctx = %{
        read: fn _k, d -> d end,
        self_uri: Ezagent.URI.new!("entity://team-alpha/agent/echo_default"),
        caller: Ezagent.URI.new!("session://team-alpha/default/main")
      }

      assert {:ok, _, effects} = Echo.handle_receive(%{message: msg}, ctx)

      dispatches = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert dispatches == [], "turn_cap=0 must NOT emit a dispatch (sink mode)"
    end

    test "still increments count via :set effects on receive" do
      msg =
        Ezagent.Message.new(
          Ezagent.URI.new!("entity://team-alpha/user/alice"),
          %{text: "hi"}
        )

      ctx = %{
        read: fn
          :count, _ -> 7
          _, d -> d
        end,
        self_uri: Ezagent.URI.new!("entity://team-alpha/agent/echo_default"),
        caller: Ezagent.URI.new!("session://team-alpha/default/main")
      }

      assert {:ok, _, effects} = Echo.handle_receive(%{message: msg}, ctx)
      assert {:set, :count, 8} in effects
      assert {:set, :last_msg, "hi"} in effects
    end
  end

  describe "data_owner/1" do
    test "returns :no_owner (admin-only Behavior)" do
      assert Echo.data_owner(:any) == :no_owner
      assert Echo.data_owner(Ezagent.URI.new!("entity://x/agent/y")) == :no_owner
    end
  end
end
