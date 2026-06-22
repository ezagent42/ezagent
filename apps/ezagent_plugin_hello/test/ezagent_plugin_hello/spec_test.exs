defmodule EzagentPluginHello.SpecTest do
  use ExUnit.Case, async: true

  alias EzagentPluginHello.Spec

  describe "validate/1 — the catalog-constraint chokepoint" do
    test "accepts a tree built only from catalog node types" do
      assert {:ok, _} = Spec.validate(Spec.seed())

      page = %{
        "type" => "page",
        "props" => %{"title" => "Hi"},
        "children" => [
          %{"type" => "heading", "props" => %{"text" => "H", "level" => 1}, "children" => []},
          %{"type" => "text", "props" => %{"text" => "body"}, "children" => []},
          %{"type" => "button", "props" => %{"label" => "Go", "href" => "/x"}, "children" => []}
        ]
      }

      assert {:ok, ^page} = Spec.validate(page)
    end

    test "fails closed on an out-of-catalog node type (nested)" do
      bad = %{
        "type" => "page",
        "props" => %{},
        "children" => [%{"type" => "iframe", "props" => %{"src" => "evil"}, "children" => []}]
      }

      assert {:error, {:unknown_type, "iframe"}} = Spec.validate(bad)
    end

    test "rejects a non-node / missing type" do
      assert {:error, {:missing_type, _}} = Spec.validate(%{"props" => %{}})
      assert {:error, {:not_a_node, _}} = Spec.validate("nope")
    end
  end

  describe "extract/1" do
    test "pulls a bare JSON object" do
      assert {:ok, %{"type" => "page"}} = Spec.extract(~s({"type":"page","props":{}}))
    end

    test "pulls JSON from a ```json fence (LLMs wrap output)" do
      content =
        "Here is your page:\n```json\n{\"type\":\"text\",\"props\":{\"text\":\"hi\"}}\n```\n"

      assert {:ok, %{"type" => "text", "props" => %{"text" => "hi"}}} = Spec.extract(content)
    end

    test "errors on non-JSON" do
      assert {:error, _} = Spec.extract("not json at all")
    end
  end
end
