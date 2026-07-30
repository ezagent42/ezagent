defmodule EzagentPluginHello.GeneratorTest do
  use ExUnit.Case, async: false

  alias EzagentPluginHello.Generator

  describe "error_signal_reason/1" do
    test "preserves a missing API key so World can render credential guidance" do
      assert Generator.error_signal_reason({:no_api_key, "deepseek"}) ==
               {:no_api_key, "deepseek"}
    end

    test "wraps an unclassified generation failure for Layer 3 handling" do
      reason = {:http, 502, "bad gateway"}
      assert Generator.error_signal_reason(reason) == {:generation_failed, reason}
    end

    test "wraps lookalike missing-key errors that are not the supported two-tuple" do
      reason = {:no_api_key, "deepseek", :retryable}
      assert Generator.error_signal_reason(reason) == {:generation_failed, reason}
    end
  end

  describe "decode_page_spec_with_retry/2" do
    test "retries an unrecoverable JSON response exactly once" do
      retry = fn ->
        send(self(), :retried)

        {:ok,
         Jason.encode!(%{
           "type" => "Text",
           "props" => %{"text" => "recovered"},
           "children" => []
         })}
      end

      assert {:ok, %{"props" => %{"text" => "recovered"}}} =
               Generator.decode_page_spec_with_retry("{not json", retry)

      assert_received :retried
      refute_received :retried
    end

    test "does not retry a valid response" do
      valid = Jason.encode!(%{"type" => "Text", "props" => %{"text" => "ok"}, "children" => []})

      assert {:ok, %{"props" => %{"text" => "ok"}}} =
               Generator.decode_page_spec_with_retry(valid, fn ->
                 flunk("valid JSON must not retry")
               end)
    end
  end

  # The incremental-edit core: nodes are id-annotated (pre-order), the model emits
  # ops referencing those ids, and `apply_patch/2` applies them. These pin the
  # patch semantics so "change one button's text" stays a one-op edit, not a full
  # page regeneration.
  describe "apply_patch/2 — incremental edit ops" do
    setup do
      page = %{
        "type" => "Stack",
        "props" => %{"direction" => "vertical", "className" => "page-root"},
        "children" => [
          %{
            "type" => "Heading",
            "props" => %{"text" => "Old title", "level" => 1},
            "children" => []
          },
          %{
            "type" => "Stack",
            "props" => %{"className" => "cta"},
            "children" => [
              %{"type" => "Button", "props" => %{"label" => "Buy"}, "children" => []}
            ]
          }
        ]
      }

      # ids are assigned pre-order: root=n0, Heading=n1, inner Stack=n2, Button=n3.
      %{page: page}
    end

    test "set merges props on the addressed node, leaving the rest untouched", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{"op" => "set", "id" => "n1", "props" => %{"text" => "New title"}}
        ])

      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "New title"
      # level preserved (merge, not replace); the rest of the tree unchanged.
      assert get_in(patched, ["children", Access.at(0), "props", "level"]) == 1

      assert get_in(patched, [
               "children",
               Access.at(1),
               "children",
               Access.at(0),
               "props",
               "label"
             ]) ==
               "Buy"

      # ids are stripped from the result.
      refute Map.has_key?(patched, "id")
    end

    test "set reaches a deeply nested node by id", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{"op" => "set", "id" => "n3", "props" => %{"label" => "Start free"}}
        ])

      assert get_in(patched, [
               "children",
               Access.at(1),
               "children",
               Access.at(0),
               "props",
               "label"
             ]) ==
               "Start free"
    end

    test "replace swaps the whole node", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{
            "op" => "replace",
            "id" => "n1",
            "node" => %{"type" => "Text", "props" => %{"text" => "Hi"}, "children" => []}
          }
        ])

      assert get_in(patched, ["children", Access.at(0), "type"]) == "Text"
    end

    test "insert adds a child at the parent (append when no index)", %{page: page} do
      new = %{"type" => "Text", "props" => %{"text" => "Sub"}, "children" => []}

      patched =
        Generator.apply_patch(page, [%{"op" => "insert", "parent" => "n0", "node" => new}])

      kids = patched["children"]
      assert length(kids) == 3
      assert List.last(kids)["props"]["text"] == "Sub"
    end

    test "insert honors an explicit index", %{page: page} do
      new = %{"type" => "Text", "props" => %{"text" => "First"}, "children" => []}

      patched =
        Generator.apply_patch(page, [
          %{"op" => "insert", "parent" => "n0", "index" => 0, "node" => new}
        ])

      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "First"
    end

    test "remove deletes the addressed node", %{page: page} do
      patched = Generator.apply_patch(page, [%{"op" => "remove", "id" => "n1"}])

      types = Enum.map(patched["children"], & &1["type"])
      refute "Heading" in types
      assert "Stack" in types
    end

    test "an unknown op is a no-op (degrade, never crash)", %{page: page} do
      patched = Generator.apply_patch(page, [%{"op" => "frobnicate", "id" => "n1"}])
      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "Old title"
    end

    test "multiple ops apply in order", %{page: page} do
      patched =
        Generator.apply_patch(page, [
          %{"op" => "set", "id" => "n1", "props" => %{"text" => "T2"}},
          %{"op" => "set", "id" => "n3", "props" => %{"label" => "L2"}}
        ])

      assert get_in(patched, ["children", Access.at(0), "props", "text"]) == "T2"

      assert get_in(patched, [
               "children",
               Access.at(1),
               "children",
               Access.at(0),
               "props",
               "label"
             ]) ==
               "L2"
    end
  end
end
