defmodule EzagentPluginLoom.Integration.V0Test do
  @moduledoc "v0 页面生成的提取逻辑(纯函数,无 LLM)+ page_update span 格式。迁移自 loom v0 worker。"
  use ExUnit.Case, async: true

  alias EzagentPluginLoom.{Span, V0, V0Prompts}

  test "extract_files_and_summary:单 jsx 块 → /App.jsx + summary" do
    text = "做好了。\n```jsx\nexport default function App(){return <div>hi</div>}\n```"
    assert {:ok, files, summary} = V0.extract_files_and_summary(text)
    assert Map.has_key?(files, "/App.jsx")
    assert files["/App.jsx"] =~ "export default function App"
    assert summary == "做好了。"
  end

  test "extract_files_and_summary:多文件 file= 标注" do
    text = """
    多文件页面。
    ```jsx file=/App.jsx
    import H from './components/H'; export default function App(){return <H/>}
    ```
    ```jsx file=/components/H.jsx
    export default function H(){return <h1>H</h1>}
    ```
    """

    assert {:ok, files, _} = V0.extract_files_and_summary(text)
    assert Map.has_key?(files, "/App.jsx")
    assert Map.has_key?(files, "/components/H.jsx")
  end

  test "无代码块 → :error(交给 conversational 兜底)" do
    assert :error = V0.extract_files_and_summary("你好,这个页面能做成商城吗?")
  end

  test "受保护文件名被丢弃" do
    text = "```jsx file=/platform.js\nhack\n```\n```jsx file=/App.jsx\nok\n```"
    assert {:ok, files, _} = V0.extract_files_and_summary(text)
    refute Map.has_key?(files, "/platform.js")
    assert Map.has_key?(files, "/App.jsx")
  end

  test "Span.span 包成 page_update(前端识别格式)" do
    span = Span.span("page_update", %{"files" => %{"/App.jsx" => "x"}, "summary" => "s"})
    assert span =~ ~s(<span type="page_update">)
    assert span =~ "/App.jsx"
    assert span =~ "</span>"
  end

  test "page_gen system prompt 从 priv 读到(含 jsx/App.jsx 约定)" do
    p = V0Prompts.page_gen_system_prompt()
    assert is_binary(p) and byte_size(p) > 200
    assert p =~ "/App.jsx"
    assert p =~ "export default function App"
    refute p =~ "#DYNAMIC_TOOL_AND_PRESET_BLOCK#"
  end
end
