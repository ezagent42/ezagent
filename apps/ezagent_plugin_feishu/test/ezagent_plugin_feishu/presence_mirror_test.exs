defmodule EzagentPluginFeishu.PresenceMirrorTest do
  @moduledoc """
  Tests for `EzagentPluginFeishu.PresenceMirror` — PR-C of the Presence
  rollout. Mirrors Feishu-bound user activity into `Ezagent.Presence`
  as `:transport => :feishu` so chat surfaces (PresenceFanout → session
  :events) reflect "this user is reachable via Feishu".
  """

  use ExUnit.Case, async: false

  alias Ezagent.Presence
  alias EzagentPluginFeishu.PresenceMirror

  defp unique_user_uri(suffix),
    do:
      URI.parse(
        "entity://user/default/feishu_presence_test_#{suffix}_#{System.unique_integer([:positive])}"
      )

  defp wait_for(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if do_wait(fun, deadline) do
      :ok
    else
      flunk("wait_for timed out")
    end
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  describe "touch/1" do
    test "tracks the caller in Ezagent.Presence with :feishu transport" do
      caller_uri = unique_user_uri("first_touch")

      refute Presence.present?(caller_uri)

      :ok = PresenceMirror.touch(caller_uri)

      wait_for(fn -> Presence.present?(caller_uri) end)

      list = Presence.list(caller_uri)
      assert map_size(list) == 1

      [metas] = Map.values(list)
      assert hd(metas).transport == :feishu
    end

    test "repeat touch is idempotent (single entry)" do
      caller_uri = unique_user_uri("repeat_touch")

      :ok = PresenceMirror.touch(caller_uri)
      wait_for(fn -> Presence.present?(caller_uri) end)

      :ok = PresenceMirror.touch(caller_uri)
      :ok = PresenceMirror.touch(caller_uri)

      # Give casts a tick to settle
      Process.sleep(50)

      list = Presence.list(caller_uri)
      assert map_size(list) == 1

      tracked = PresenceMirror.__tracked__()
      assert MapSet.member?(tracked, caller_uri)
    end
  end
end
