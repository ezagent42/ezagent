defmodule EzagentPluginLoom.Integration.LlmCcFlavorTest do
  @moduledoc "LLM cc-flavor:用本地 claude 二进制(one-shot)。live 需 claude + ANTHROPIC env。"
  use ExUnit.Case, async: true

  alias EzagentPluginLoom.LLM

  @tag :live
  test "cc-flavor routes through the local claude binary" do
    assert {:ok, text} =
             LLM.chat([%{role: "user", content: "reply with exactly: CC_OK"}], flavor: :cc, system: "只回复要求的内容")

    assert is_binary(text) and text != ""
  end

  test "cc-flavor errors gracefully if claude binary is absent (PATH override)" do
    # 用一个没有 claude 的 PATH 验证 graceful 错误(不崩)
    original = System.get_env("PATH")
    System.put_env("PATH", "/nonexistent")
    on_exit(fn -> if original, do: System.put_env("PATH", original) end)

    assert {:error, :no_claude_binary} = LLM.chat([%{role: "user", content: "hi"}], flavor: :cc)
  end
end
