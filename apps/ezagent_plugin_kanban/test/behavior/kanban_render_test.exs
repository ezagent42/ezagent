defmodule Ezagent.ActionSet.KanbanRenderTest do
  @moduledoc """
  S4 unit gate for `Ezagent.ActionSet.KanbanRender` — the kanban-team board
  view's **view read ActionSet**（cap-only，照 `Ezagent.ActionSet.HelloRender`）.

  Two halves:

    * the cap-only contract — a unique `:kanban_render` read action, NO dispatch
      surface (`dispatchable?/0 → false`), so `{Session, :kanban_render}` can be
      registered on the Session Kind (conformance assertion 2/9) and checked by
      `Ezagent.UI.SessionView.authorize_view/3`;
    * `render_tree/2` — the PURE read-only board projection (`:kanban` slice
      tree + recipe stages → JSON-safe json-render map, string-keyed like the
      hello `@json-render` spec convention). No `{:set, ...}`, no dispatch — a
      projection, never a write.
  """
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.KanbanRender

  describe "cap-only view read ActionSet contract (T2-2a shape)" do
    test "declares the unique :kanban_render read action" do
      assert KanbanRender.actions() == [:kanban_render]
    end

    test "is cap-only: no dispatch surface" do
      refute KanbanRender.dispatchable?()
      assert KanbanRender.interface() == %{}
    end

    test "declares the {Session, :kanban_render} cap subject + required cap" do
      assert [{:kanban_render, doc}] = KanbanRender.cap_subjects()
      assert is_binary(doc) and doc != ""

      assert %{kanban_render: %Ezagent.Capability{} = cap} = KanbanRender.required_caps()
      assert cap.action == :kanban_render
    end

    test "data_owner is :any (a read view, not per-instance owned)" do
      assert KanbanRender.data_owner(%{}) == :any
    end
  end

  describe "render_tree/2 — pure read-only board projection" do
    # A minimal `:kanban` slice tree the way the board actor persists it
    # (`Shared.commit/1`): nodes keyed by id, each with parent_id/title/order/
    # stage/owner/status.
    defp board_tree do
      %{
        root_id: "root",
        nodes: %{
          "root" => %{parent_id: nil, title: "产品", order: 0, stage: nil, owner: nil, status: nil},
          "a" => %{
            parent_id: "root",
            title: "登录页",
            order: 0,
            stage: :feature,
            owner: "entity://ws-a/user/u1",
            status: :doing
          },
          "b" => %{
            parent_id: "root",
            title: "支付",
            order: 1,
            stage: :feature,
            owner: nil,
            status: nil
          },
          "c" => %{
            parent_id: "root",
            title: "登录页 CI",
            order: 2,
            stage: :pr,
            owner: nil,
            status: :done
          }
        }
      }
    end

    test "projects a board tree into a JSON-safe kanban json-render tree" do
      stages = [:feature, :test, :pr]
      tree = KanbanRender.render_tree(board_tree(), stages)

      # string-keyed, serializable (JSON round-trip safe, hello spec convention).
      assert tree["type"] == "kanban_board"
      assert tree["stages"] == ["feature", "test", "pr"]
      assert Jason.encode!(tree)

      # one column per stage, in stage (relay) order.
      columns = tree["columns"]
      assert Enum.map(columns, & &1["stage"]) == ["feature", "test", "pr"]

      # cards land in their stage's column, sorted by order; values stringified.
      [feature_col, test_col, pr_col] = columns
      assert Enum.map(feature_col["cards"], & &1["title"]) == ["登录页", "支付"]
      assert test_col["cards"] == []
      assert [%{"id" => "c", "stage" => "pr", "status" => "done"}] = pr_col["cards"]

      [login | _] = feature_col["cards"]
      assert login["id"] == "a"
      assert login["status"] == "doing"
      assert login["owner"] == "entity://ws-a/user/u1"

      # the root node is structure, not a card.
      all_ids = columns |> Enum.flat_map(& &1["cards"]) |> Enum.map(& &1["id"])
      refute "root" in all_ids
    end

    test "unstaged (stage=nil / unknown-stage) non-root nodes fold into an 未排期 column" do
      tree =
        KanbanRender.render_tree(
          %{
            root_id: "r",
            nodes: %{
              "r" => %{parent_id: nil, title: "root", order: 0, stage: nil},
              "x" => %{parent_id: "r", title: "backlog 想法", order: 0, stage: nil},
              "y" => %{parent_id: "r", title: "旧棒", order: 1, stage: :retired_stage}
            }
          },
          [:feature]
        )

      unstaged = Enum.find(tree["columns"], &(&1["stage"] == "unstaged"))
      assert unstaged
      assert Enum.map(unstaged["cards"], & &1["title"]) == ["backlog 想法", "旧棒"]
    end

    test "empty / missing board tree → stage columns with zero cards (never raises)" do
      for empty <- [%{}, %{nodes: %{}, root_id: nil}, nil] do
        tree = KanbanRender.render_tree(empty, [:feature, :pr])
        assert tree["type"] == "kanban_board"
        assert Enum.all?(tree["columns"], &(&1["cards"] == []))
      end
    end

    test "is a projection — the input tree is not mutated (pure function)" do
      input = board_tree()
      _ = KanbanRender.render_tree(input, [:feature])
      assert input == board_tree()
    end
  end

  describe "external_tree/1 — per-session board read (fail-safe)" do
    test "a workspace with no kanban-manager board → nil (nothing to render yet)" do
      session_uri = Ezagent.URI.session("ws-kanban-render-none", "kanban", "s1")
      assert KanbanRender.external_tree(session_uri) == nil
    end

    test "a non-session URI → nil" do
      assert KanbanRender.external_tree(Ezagent.URI.workspace("ws-x")) == nil
    end
  end
end
