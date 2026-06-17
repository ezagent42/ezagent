defmodule Ezagent.Behavior.LoomWorkerTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.LoomWorker
  alias Ezagent.Message

  @worker_uri URI.parse("entity://agent/system/loomworker_policy")
  @orchestrator_uri URI.parse("entity://agent/system/loom_orch")
  @session_uri URI.parse("session://system/s_test")

  # New-contract ctx: `:read` exposes the slice to the handler (Kind.Runtime
  # injects it); `:self_uri` + `:caller` (= session on chat.receive) mirror
  # what the runtime passes.
  defp ctx(slice),
    do: %{self_uri: @worker_uri, caller: @session_uri, read: fn k, d -> Map.get(slice, k, d) end}

  describe "loop-guard (PRD §5.3 — no message storm)" do
    test "ignores a message that does NOT @mention this worker — no effects, no reply" do
      slice = LoomWorker.init_slice(%{})

      # A user message broadcast into the room (mentions = []). The worker
      # must NOT react. Short-circuits BEFORE any DeepSeek call → no effects.
      msg =
        Message.new(URI.parse("entity://user/system/tmp_x"), %{text: "你们有哪些服务", attachments: []})

      assert {:ok, %{}, []} = LoomWorker.handle_receive(%{message: msg}, ctx(slice))
    end

    test "ignores a message addressed to a DIFFERENT member" do
      slice = LoomWorker.init_slice(%{})

      # Orchestrator @mentions the OTHER worker, not us.
      other = URI.parse("entity://agent/system/loomworker_company")

      msg =
        Message.new(@orchestrator_uri, %{text: "梳理企业匹配", attachments: []}, mentions: [other])

      assert {:ok, %{}, []} = LoomWorker.handle_receive(%{message: msg}, ctx(slice))
    end
  end

  describe "init_slice/1" do
    test "defaults role + a non-empty system prompt; accepts per-slot overrides" do
      default = LoomWorker.init_slice(%{})
      assert default.role == "worker"
      assert is_binary(default.system_prompt) and default.system_prompt != ""

      override = LoomWorker.init_slice(%{"role" => "政策侧", "system_prompt" => "你是政策专家"})
      assert override.role == "政策侧"
      assert override.system_prompt == "你是政策专家"
    end
  end

  describe "theme_for/1 (S3-B name-derived theme)" do
    test "derives policy/company from the worker's URI name; nil otherwise" do
      assert LoomWorker.theme_for(URI.parse("entity://agent/system/loomworker_s1_policy")) ==
               "policy"

      assert LoomWorker.theme_for(URI.parse("entity://agent/system/loomworker_s1_company")) ==
               "company"

      assert LoomWorker.theme_for(URI.parse("entity://agent/system/loomworker_s1_misc")) == nil
      assert LoomWorker.theme_for(nil) == nil
    end
  end
end
