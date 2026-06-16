defmodule Ezagent.Behavior.LoomBuilderWorkerTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.LoomBuilderWorker

  describe "extract_files_and_summary/1 (2026-06-02 多文件)" do
    test "单个未标 file= 的裸 jsx 块 → 归到 /App.jsx" do
      text = """
      好的，给你做一个页面
      ```jsx
      export default function App() { return <div>hi</div>; }
      ```
      """

      assert {:ok, files, summary} = LoomBuilderWorker.extract_files_and_summary(text)
      assert Map.keys(files) == ["/App.jsx"]
      assert files["/App.jsx"] =~ "export default function App"
      assert summary == "好的，给你做一个页面"
    end

    test "多个带 file= 的块 → 多键 files map" do
      text = """
      拆成两个文件
      ```jsx file=/App.jsx
      import Header from './components/Header';
      export default function App() { return <Header />; }
      ```
      ```jsx file=/components/Header.jsx
      export default function Header() { return <h1>Hi</h1>; }
      ```
      """

      assert {:ok, files, _summary} = LoomBuilderWorker.extract_files_and_summary(text)
      assert Enum.sort(Map.keys(files)) == ["/App.jsx", "/components/Header.jsx"]
      assert files["/components/Header.jsx"] =~ "function Header"
    end

    test "受保护文件 /platform.js / ezagent-ui 被丢弃(agent 写了也不生效)" do
      text = """
      ```jsx file=/App.jsx
      export default function App() { return <div/>; }
      ```
      ```jsx file=/platform.js
      export function sendMessage() { /* 恶意覆盖 */ }
      ```
      ```jsx file=/ezagent-ui.js
      export function EzagentMessage() {}
      ```
      ```jsx file=/lib/platform.jsx
      export const x = 1;
      ```
      """

      assert {:ok, files, _} = LoomBuilderWorker.extract_files_and_summary(text)
      assert Map.keys(files) == ["/App.jsx"]
      refute Map.has_key?(files, "/platform.js")
      refute Map.has_key?(files, "/ezagent-ui.js")
    end

    test "相对路径 ./x 与无前导 / 归一成 /x" do
      text = """
      ```jsx file=./App.jsx
      export default function App() { return <Card/>; }
      ```
      ```jsx file=components/Card.jsx
      export default function Card() { return <div/>; }
      ```
      """

      assert {:ok, files, _} = LoomBuilderWorker.extract_files_and_summary(text)
      assert Enum.sort(Map.keys(files)) == ["/App.jsx", "/components/Card.jsx"]
    end

    test "没有任何代码块 → :error" do
      assert :error = LoomBuilderWorker.extract_files_and_summary("我没法理解这个需求")
    end

    test "只有受保护文件(无有效页面文件)→ :error" do
      text = """
      ```jsx file=/platform.js
      export function sendMessage() {}
      ```
      """

      assert :error = LoomBuilderWorker.extract_files_and_summary(text)
    end

    test "缺 summary prose → fallback 页面已更新" do
      text = """
      ```jsx
      export default function App() { return <div/>; }
      ```
      """

      assert {:ok, _files, "页面已更新"} = LoomBuilderWorker.extract_files_and_summary(text)
    end
  end
end
