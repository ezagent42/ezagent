defmodule EzagentPluginFeishu.FeishuChatBindingTest do
  @moduledoc """
  PR-EM-6 unit tests for `EzagentPluginFeishu.FeishuChatBinding`.

  Focus areas:

  - `init/1` validation (chat_id must start with `oc_`).
  - `publish/2` shape mismatch (recoverable error path).
  - `publish/2` empty list (immediate ok success).
  - `terminate/2` no-op.

  Tests that exercise the real Lark `Client` GenServer (sending
  actual HTTP) are NOT exercised here — those live in the E2E
  parity test (or a dedicated integration test gated by
  EZAGENT_FEISHU_LIVE=1 env). The unit tests focus on the
  Binding's contract: init validation, payload-shape handling,
  state threading.
  """

  use ExUnit.Case, async: true

  alias EzagentPluginFeishu.FeishuChatBinding

  describe "adapter_module/0" do
    test "names FeishuAdapter (Grill-5 reciprocity)" do
      assert FeishuChatBinding.adapter_module() == EzagentPluginFeishu.FeishuAdapter
    end
  end

  describe "init/1" do
    test "accepts a valid Feishu chat_id (oc_ prefix)" do
      assert {:ok, state} =
               FeishuChatBinding.init({"oc_valid_chat", EzagentPluginFeishu.FeishuAdapter, %{}})

      assert state.chat_id == "oc_valid_chat"
      assert state.publish_count == 0
      assert state.error_count == 0
      assert state.last_retry_at == nil
    end

    test "rejects a chat_id without the oc_ prefix" do
      assert {:error, {:invalid_chat_id, "bad_chat"}} =
               FeishuChatBinding.init({"bad_chat", EzagentPluginFeishu.FeishuAdapter, %{}})
    end

    test "rejects a non-string target_id" do
      assert {:error, {:invalid_target_id, 42}} =
               FeishuChatBinding.init({42, EzagentPluginFeishu.FeishuAdapter, %{}})
    end

    test "carries opts into state for later inspection" do
      opts = %{bound_by: "entity://user/system/admin", custom: "metadata"}

      assert {:ok, state} =
               FeishuChatBinding.init({"oc_test", EzagentPluginFeishu.FeishuAdapter, opts})

      assert state.opts == opts
    end
  end

  describe "publish/2 — shape handling" do
    test "an empty payload list is an immediate ok success (counter bumped)" do
      state = base_state()

      assert {:ok, new_state} = FeishuChatBinding.publish([], state)
      assert new_state.publish_count == state.publish_count + 1
    end

    test "an unexpected non-list payload returns a recoverable error" do
      state = base_state()

      assert {:error, {:invalid_payload, %{whatever: 1}}, ^state} =
               FeishuChatBinding.publish(%{whatever: 1}, state)
    end

    test "an unknown payload tag at pos-0 returns a recoverable {:error, _, _} (sent==0 path)" do
      state = base_state()

      # First payload fails → sent==0 → recoverable per codex r1 HIGH fix.
      # The partial-publish RAISE branch (sent>=1) requires a successful
      # Client.send_text/2 followed by a failure — that needs a real
      # (mocked) Client and is exercised by the integration/E2E test.
      # Pure-unit coverage of the contract is the assertion below.
      assert {:error, {:unknown_payload_tag, {:something_new, "x"}}, new_state} =
               FeishuChatBinding.publish([{:something_new, "x"}], state)

      assert new_state.error_count == state.error_count + 1
      assert new_state.last_retry_at != nil
    end

    # codex r1 HIGH fix (2026-05-25) — partial-publish RAISE branch.
    # Uses the test-only `:lark_test_ok` / `:lark_test_fail` payload
    # tags (compiled in only under Mix.env() == :test) so the unit
    # test can exercise the (sent >= 1 + later-payload-fails) →
    # RAISE branch without mocking the Client GenServer.
    test "partial-publish (sent >= 1 then a later payload fails) RAISES" do
      state = base_state()

      assert_raise RuntimeError, ~r/partial-publish failure/, fn ->
        FeishuChatBinding.publish(
          [
            {:lark_test_ok, "first-succeeds"},
            {:lark_test_fail, :synthetic_429}
          ],
          state
        )
      end
    end

    test "pre-publish failure (sent == 0) stays recoverable {:error, _, _}" do
      state = base_state()

      # First payload fails → pre-send path → recoverable error.
      assert {:error, :synthetic_lark_down, new_state} =
               FeishuChatBinding.publish(
                 [
                   {:lark_test_fail, :synthetic_lark_down},
                   {:lark_test_ok, "would-have-followed"}
                 ],
                 state
               )

      assert new_state.error_count == state.error_count + 1
    end

    test "all payloads succeed → ok + publish_count bumped" do
      state = base_state()

      assert {:ok, new_state} =
               FeishuChatBinding.publish(
                 [
                   {:lark_test_ok, "first"},
                   {:lark_test_ok, "second"},
                   {:lark_test_ok, "third"}
                 ],
                 state
               )

      assert new_state.publish_count == state.publish_count + 1
    end
  end

  describe "terminate/2" do
    test "is a no-op" do
      state = base_state()
      assert :ok = FeishuChatBinding.terminate(:shutdown, state)
      assert :ok = FeishuChatBinding.terminate(:normal, state)
    end
  end

  # ----- helpers -----------------------------------------------------------

  defp base_state do
    %{
      chat_id: "oc_test_chat",
      opts: %{},
      publish_count: 0,
      error_count: 0,
      last_retry_at: nil
    }
  end
end
