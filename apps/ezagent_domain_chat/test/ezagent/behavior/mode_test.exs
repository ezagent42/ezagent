defmodule Ezagent.Behavior.ModeTest do
  @moduledoc """
  Tests for `Ezagent.Behavior.Mode` — the session-level operator/agent
  control mode Behavior (feat/takeover-mode, PR-A).

  Uses the Lifecycle API (`use Ezagent.Lifecycle`). Tests call handlers
  directly via the Behavior contract (not through Kind dispatch) to keep
  things unit-level. `BehaviorInvoker` is used for effect-folding
  assertions.
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Mode
  alias Ezagent.{Capability, Cmd}
  alias EzagentDomainChat.Test.BehaviorInvoker, as: Invoker

  # Minimal ctx used in direct handler tests. The `read` closure reads
  # from `state` (a flat map), matching the BehaviorInvoker's enriched_ctx
  # setup.
  defp make_ctx(state, opts \\ []) do
    self_uri = Keyword.get(opts, :self_uri, nil)
    siblings = Keyword.get(opts, :siblings, %{})

    %{
      read: fn key, default -> Map.get(state, key, default) end,
      self_uri: self_uri,
      transients: %{},
      caps: MapSet.new(),
      siblings: siblings
    }
  end

  # ---- Contract shape ----------------------------------------------------

  describe "Behavior contract shape" do
    test "actions/0 declares :get and :set" do
      assert Mode.actions() == [:get, :set]
    end

    test "state_slice/0 auto-derives to :mode" do
      assert Mode.state_slice() == :mode
    end

    test "cap_subjects/0 has descriptive entries for :get and :set" do
      subjects = Mode.cap_subjects()
      assert {:get, get_desc} = List.keyfind(subjects, :get, 0)
      assert {:set, set_desc} = List.keyfind(subjects, :set, 0)
      assert is_binary(get_desc) and String.length(get_desc) > 0
      assert is_binary(set_desc) and String.length(set_desc) > 0
    end

    test "required_caps/0 declares :session kind-axis caps" do
      caps = Mode.required_caps()
      assert %{get: %Capability{} = get_cap, set: %Capability{} = set_cap} = caps
      assert get_cap.kind == :session
      assert get_cap.behavior == Mode
      assert set_cap.kind == :session
      assert set_cap.behavior == Mode
    end

    # Lifecycle migration: `init_slice/1` is macro-emitted, wrapping
    # `create/1`'s return in `%{state: ..., transients: %{}}`.
    test "create/1 returns {:ok, %{mode: :auto}}" do
      assert {:ok, %{mode: :auto}} = Mode.create(%{})
    end

    test "init_slice/1 wraps create/1 in the two-container shape" do
      result = Mode.init_slice(%{})
      assert %{state: %{mode: :auto}, transients: %{}} = result
    end
  end

  # ---- handle_get/2 ------------------------------------------------------

  describe "handle_get/2" do
    test "returns {:ok, %{mode: :auto}, []} when state is :auto" do
      ctx = make_ctx(%{mode: :auto})
      assert {:ok, %{mode: :auto}, []} = Mode.handle_get(%{}, ctx)
    end

    test "returns {:ok, %{mode: :takeover}, []} when state is :takeover" do
      ctx = make_ctx(%{mode: :takeover})
      assert {:ok, %{mode: :takeover}, []} = Mode.handle_get(%{}, ctx)
    end

    test "returns :auto as fallback when :mode is not in state" do
      ctx = make_ctx(%{})
      assert {:ok, %{mode: :auto}, []} = Mode.handle_get(%{}, ctx)
    end
  end

  # ---- handle_set/2 ------------------------------------------------------

  describe "handle_set/2 — valid modes" do
    test "auto -> auto: sets mode, no dispatch effect" do
      ctx = make_ctx(%{mode: :auto})

      assert {:ok, %{mode: :auto, previous: :auto}, effects} =
               Mode.handle_set(%{mode: :auto}, ctx)

      assert {:set, :mode, :auto} in effects
      # No dispatch effect — notice only fires on :auto → :takeover
      refute Enum.any?(effects, &match?({:dispatch, _}, &1))
    end

    test "auto -> takeover: sets mode, returns dispatch effect for takeover notice" do
      session_uri = URI.parse("session://default/ws-test/session-mode-test")
      ctx = make_ctx(%{mode: :auto}, self_uri: session_uri)

      assert {:ok, %{mode: :takeover, previous: :auto}, effects} =
               Mode.handle_set(%{mode: :takeover}, ctx)

      assert {:set, :mode, :takeover} in effects

      dispatch_effects = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert length(dispatch_effects) == 1
      [{:dispatch, %Cmd{} = cmd}] = dispatch_effects
      assert cmd.action == :send
      # Target is the session's chat.send endpoint
      assert URI.to_string(cmd.target) =~
               URI.to_string(session_uri) <> "?action=chat.send"
    end

    test "takeover -> auto: sets mode, no dispatch effect (silent transition)" do
      session_uri = URI.parse("session://default/ws-test/session-mode-silent-test")
      ctx = make_ctx(%{mode: :takeover}, self_uri: session_uri)

      assert {:ok, %{mode: :auto, previous: :takeover}, effects} =
               Mode.handle_set(%{mode: :auto}, ctx)

      assert {:set, :mode, :auto} in effects
      # Reverse transition is silent — no notice sent
      refute Enum.any?(effects, &match?({:dispatch, _}, &1))
    end

    test "takeover -> takeover: sets mode, no dispatch effect (no duplicate notice)" do
      session_uri = URI.parse("session://default/ws-test/session-mode-dup-test")
      ctx = make_ctx(%{mode: :takeover}, self_uri: session_uri)

      assert {:ok, %{mode: :takeover, previous: :takeover}, effects} =
               Mode.handle_set(%{mode: :takeover}, ctx)

      assert {:set, :mode, :takeover} in effects
      refute Enum.any?(effects, &match?({:dispatch, _}, &1))
    end

    test "auto -> takeover: notice dispatch has :ignore reply (no deadlock)" do
      session_uri = URI.parse("session://default/ws-test/session-mode-nodeadlock")
      ctx = make_ctx(%{mode: :auto}, self_uri: session_uri)

      {:ok, _, effects} = Mode.handle_set(%{mode: :takeover}, ctx)

      [{:dispatch, %Cmd{ctx: cmd_ctx}}] =
        Enum.filter(effects, &match?({:dispatch, _}, &1))

      assert cmd_ctx.reply == :ignore
    end

    test "auto -> takeover: notice has is_takeover_notice: true in body" do
      session_uri = URI.parse("session://default/ws-test/session-mode-noticetag")
      ctx = make_ctx(%{mode: :auto}, self_uri: session_uri)

      {:ok, _, effects} = Mode.handle_set(%{mode: :takeover}, ctx)

      [{:dispatch, %Cmd{args: %{message: msg}}}] =
        Enum.filter(effects, &match?({:dispatch, _}, &1))

      assert Map.get(msg.body, :is_takeover_notice) == true
    end
  end

  describe "handle_set/2 — defensive cases" do
    test "unsupported mode returns {:error, {:unsupported_mode, bad}}" do
      ctx = make_ctx(%{mode: :auto})
      assert {:error, {:unsupported_mode, :copilot}} = Mode.handle_set(%{mode: :copilot}, ctx)
    end

    test "auto -> takeover without self_uri (non-session ctx): no dispatch effect" do
      # Defensive: if ctx.self_uri is nil or not a session URI, skip the
      # notice effect. The mode flip still applies (the {:set, :mode, ...}
      # effect is returned).
      ctx = make_ctx(%{mode: :auto}, self_uri: nil)

      assert {:ok, %{mode: :takeover, previous: :auto}, effects} =
               Mode.handle_set(%{mode: :takeover}, ctx)

      assert {:set, :mode, :takeover} in effects
      refute Enum.any?(effects, &match?({:dispatch, _}, &1))
    end
  end

  # ---- via BehaviorInvoker (effect-folding) ------------------------------

  describe "via BehaviorInvoker" do
    test "get via invoker returns current mode" do
      slice = %{mode: :auto}
      assert {:ok, _new_slice, %{mode: :auto}} = Invoker.invoke(Mode, :get, slice, %{}, %{})
    end

    test "set via invoker folds {:set, :mode, new_mode} onto slice" do
      slice = %{mode: :auto}

      {:ok, new_slice, result} = Invoker.invoke(Mode, :set, slice, %{mode: :takeover}, %{})
      assert new_slice.mode == :takeover
      assert result.mode == :takeover
      assert result.previous == :auto
    end
  end

  # ---- takeover_notice_text/0 --------------------------------------------

  describe "takeover_notice_text/0" do
    test "returns the AutoService-locked notice text" do
      assert Mode.takeover_notice_text() == "(客服已接管对话)"
    end
  end

  # ---- data_owner/1 ------------------------------------------------------

  describe "data_owner/1" do
    test "for a session URI, delegates to Behavior.Chat.data_owner/1" do
      # Chat.data_owner reads slice.chat.owner_uri via Session.owner/1.
      # Without a live session, owner/1 returns {:error, _} and Chat
      # returns :no_owner.
      session_uri =
        URI.parse("session://default/system/dead-mode-test-session-#{:rand.uniform(99_999)}")

      assert Mode.data_owner(session_uri) == :no_owner
    end

    test "for :any, returns :any (class-wide cap)" do
      assert Mode.data_owner(:any) == :any
    end

    test "for any other input, returns :no_owner" do
      assert Mode.data_owner(URI.parse("workspace://system")) == :no_owner
      assert Mode.data_owner(URI.parse("entity://user/system/admin")) == :no_owner
    end
  end
end
