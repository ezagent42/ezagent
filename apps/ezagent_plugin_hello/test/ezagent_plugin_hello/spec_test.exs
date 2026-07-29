defmodule EzagentPluginHello.SpecTest do
  use ExUnit.Case, async: true

  alias EzagentPluginHello.Spec

  describe "catalog/0 — the shadcn component contract (frontend↔backend parity)" do
    # The 36 @json-render/shadcn components the frontend renderer
    # (catalog_jsonrender.mjs -> shadcnComponentDefinitions) renders. The backend
    # Spec catalog MUST match this set exactly, or an LLM-emitted node validates
    # server-side but fails to render (the "Unsupported node" class of bug). This
    # is the DoD parity check (frontend catalog == backend Spec, diff = empty).
    @shadcn_components ~w(
      Accordion Alert Avatar Badge Button ButtonGroup Card Carousel Checkbox
      Collapsible Dialog Drawer DropdownMenu Grid Heading Image Input Link
      Pagination Popover Progress Radio Select Separator Skeleton Slider Spinner
      Stack Switch Table Tabs Text Textarea Toggle ToggleGroup Tooltip
    )

    test "catalog is exactly the 36 shadcn components (parity diff = empty)" do
      backend = MapSet.new(Spec.types())
      shadcn = MapSet.new(@shadcn_components)

      assert MapSet.size(shadcn) == 36

      assert MapSet.difference(backend, shadcn) |> MapSet.to_list() == [],
             "backend has components the shadcn renderer does not"

      assert MapSet.difference(shadcn, backend) |> MapSet.to_list() == [],
             "shadcn renderer has components the backend catalog does not"
    end

    test "every catalog entry declares props and a container? flag" do
      for {type, meta} <- Spec.catalog() do
        assert is_binary(type)
        assert is_list(meta.props), "#{type} props must be a list"
        assert is_boolean(meta.container?), "#{type} container? must be boolean"
      end
    end
  end

  describe "validate/1 — the catalog-constraint chokepoint" do
    test "accepts a tree built only from catalog node types" do
      assert {:ok, _} = Spec.validate(Spec.seed())

      page = %{
        "type" => "Stack",
        "props" => %{"direction" => "vertical", "title" => "Hi"},
        "children" => [
          %{"type" => "Heading", "props" => %{"text" => "H", "level" => 1}, "children" => []},
          %{"type" => "Text", "props" => %{"text" => "body"}, "children" => []},
          %{
            "type" => "Button",
            "props" => %{"label" => "Go", "variant" => "primary"},
            "children" => []
          }
        ]
      }

      assert {:ok, ^page} = Spec.validate(page)
    end

    test "fails closed on an out-of-catalog node type (nested)" do
      bad = %{
        "type" => "Stack",
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

  describe "compose_page/2 — the fan-out merge" do
    setup do
      hero = %{
        "type" => "Stack",
        "props" => %{"direction" => "vertical"},
        "children" => [
          %{"type" => "Heading", "props" => %{"text" => "Hero", "level" => 1}, "children" => []}
        ]
      }

      menu = %{
        "type" => "Stack",
        "props" => %{},
        "children" => [
          %{"type" => "Card", "props" => %{"title" => "Espresso"}, "children" => []}
        ]
      }

      %{hero: hero, menu: menu}
    end

    test "assembles ordered section sub-trees into one valid page", %{hero: hero, menu: menu} do
      assert {:ok, page} = Spec.compose_page("Bean & Leaf", [hero, menu])
      assert page["type"] == "Stack"
      assert page["props"]["title"] == "Bean & Leaf"
      # order preserved
      assert page["children"] == [hero, menu]
      # the assembled page is itself catalog-valid
      assert {:ok, ^page} = Spec.validate(page)
    end

    test "fails closed if ANY worker sub-tree has an out-of-catalog node", %{hero: hero} do
      poisoned = %{
        "type" => "Stack",
        "props" => %{},
        "children" => [%{"type" => "iframe", "props" => %{}, "children" => []}]
      }

      assert {:error, {:unknown_type, "iframe"}} = Spec.compose_page("X", [hero, poisoned])
    end

    test "an empty section list still yields a valid (empty) page" do
      assert {:ok, %{"children" => []}} = Spec.compose_page("Empty", [])
    end

    test "rejects bad args" do
      assert {:error, :bad_args} = Spec.compose_page(nil, [])
      assert {:error, :bad_args} = Spec.compose_page("t", %{})
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

    test "recovers a response that is missing only terminal JSON delimiters" do
      json =
        String.duplicate(~s({"type":"Stack","props":{},"children":[), 6) <>
          ~s({"type":"Text","props":{"text":"ready"},"children":[]}) <>
          String.duplicate("]}", 6)

      truncated = binary_part(json, 0, byte_size(json) - 6)

      assert {:ok, %{"type" => "Stack"}} = Spec.extract(truncated)
    end

    test "does not recover a response truncated inside a JSON string" do
      assert {:error, _} =
               Spec.extract(~s({"type":"Text","props":{"text":"unterminated))
    end

    test "does not recover a response that ends before a JSON value closes" do
      assert {:error, _} = Spec.extract(~s({"type":"Stack","props":{},"children":[))
    end
  end
end
