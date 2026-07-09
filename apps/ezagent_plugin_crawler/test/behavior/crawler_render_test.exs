defmodule Ezagent.ActionSet.CrawlerRenderTest do
  @moduledoc """
  段4 D2 unit gate for `Ezagent.ActionSet.CrawlerRender` — crawler 线索 view 的
  **view read ActionSet**（cap-only，照 `Ezagent.ActionSet.KanbanRender` 模具）。

  Two halves:

    * the cap-only contract — a unique `:crawler_render` read action, NO
      dispatch surface (`dispatchable?/0 → false`), so `{Session,
      :crawler_render}` can be registered on the Session Kind (conformance
      views 断言) and checked by `Ezagent.UI.SessionView.authorize_view/3`;
    * `render_tree/1` — the PURE read-only leads projection (retained `:items`
      → shared-catalog（page/section/text/table）string-keyed json-render map).
      No `{:set, ...}`, no dispatch — a projection, never a write.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.CrawlerRender

  describe "cap-only view read ActionSet contract (T2-2a shape)" do
    test "declares the unique :crawler_render read action" do
      assert CrawlerRender.actions() == [:crawler_render]
    end

    test "is cap-only: no dispatch surface" do
      refute CrawlerRender.dispatchable?()
      assert CrawlerRender.interface() == %{}
    end

    test "declares the {Session, :crawler_render} cap subject + required cap" do
      assert [{:crawler_render, doc}] = CrawlerRender.cap_subjects()
      assert is_binary(doc) and doc != ""

      assert %{crawler_render: %Ezagent.Capability{} = cap} = CrawlerRender.required_caps()
      assert cap.action == :crawler_render
    end

    test "data_owner is :any (a read view, not per-instance owned)" do
      assert CrawlerRender.data_owner(%{}) == :any
    end
  end

  describe "render_tree/1 — pure read-only leads projection" do
    # retained entries the way the Crawler write side persists them
    # (string-keyed, JSON round-trip safe — `retained_entry/1`).
    defp retained_items do
      [
        %{
          "title" => "Show HN: Postgres proxy",
          "url" => "https://example.com/pgp",
          "summary" => "s1",
          "source" => "hn",
          "source_type" => "public",
          "retained_at" => "2026-07-10T00:00:00Z"
        },
        %{
          "title" => "Acme raises tooling",
          "url" => "https://example.com/acme",
          "summary" => "s2",
          "source" => "acme",
          "source_type" => "directed",
          "retained_at" => "2026-07-10T00:00:01Z"
        }
      ]
    end

    test "projects retained leads into a shared-catalog json-render page (JSON-safe)" do
      tree = CrawlerRender.render_tree(retained_items())

      # string-keyed, serializable, catalog-typed（viewer 的共享 renderer
      # 直接认 page/section/text/table，无 hello 专属 catalog 依赖）。
      assert tree["type"] == "page"
      assert Jason.encode!(tree)

      [section] = tree["children"]
      assert section["type"] == "section"
      [text, table] = section["children"]

      assert text["type"] == "text"
      assert text["props"]["text"] =~ "2 条"

      assert table["type"] == "table"
      assert "title" in table["props"]["columns"]
      rows = table["props"]["rows"]
      assert Enum.map(rows, & &1["title"]) == ["Show HN: Postgres proxy", "Acme raises tooling"]
      assert Enum.map(rows, & &1["source_type"]) == ["public", "directed"]
    end

    test "atom-keyed entries (pre-snapshot shape) normalize into the same projection" do
      tree =
        CrawlerRender.render_tree([
          %{title: "t", url: "u", summary: "s", source: "hn", source_type: :public}
        ])

      [%{"children" => [_text, table]}] = tree["children"]
      assert [%{"title" => "t", "source_type" => "public"}] = table["props"]["rows"]
    end

    test "junk / empty input → empty table (never raises)" do
      for junk <- [nil, "x", %{}, [%{"no_title" => true}], [nil, 42]] do
        tree = CrawlerRender.render_tree(junk)
        assert tree["type"] == "page"
        [%{"children" => [_text, table]}] = tree["children"]
        assert table["props"]["rows"] == []
      end
    end

    test "is a projection — the input is not mutated (pure function)" do
      input = retained_items()
      _ = CrawlerRender.render_tree(input)
      assert input == retained_items()
    end
  end

  describe "external_tree/1 / items_for/1 — per-session read (fail-safe)" do
    test "a session with no live Kind / no retained leads → nil (nothing to render yet)" do
      session_uri = Ezagent.URI.session("ws-cr-none", "generic", "s1")
      assert CrawlerRender.items_for(session_uri) == []
      assert CrawlerRender.external_tree(session_uri) == nil
    end

    test "a non-session URI / junk → nil" do
      assert CrawlerRender.external_tree(Ezagent.URI.workspace("ws-x")) == nil
      assert CrawlerRender.external_tree(nil) == nil
      assert CrawlerRender.items_for("junk") == []
    end
  end
end
