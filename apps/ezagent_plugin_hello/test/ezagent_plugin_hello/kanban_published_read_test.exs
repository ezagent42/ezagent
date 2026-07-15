defmodule EzagentPluginHello.KanbanPublishedReadTest do
  use ExUnit.Case, async: true

  alias EzagentPluginHello.{KanbanPublishedRead, PublishedBoardRef}

  describe "PublishedBoardRef.new/1" do
    test "accepts stable identifiers and derives the entity-URI identity key" do
      assert {:ok, ref} =
               PublishedBoardRef.new(%{
                 board_uri: "entity://system/agent/hello-kanban",
                 source_session_uri: "session://system/default/author",
                 receive_ref: "/socialware/kanban/receive?token=redacted",
                 revision: 2
               })

      assert ref.board_uri == URI.new!("entity://system/agent/hello-kanban")
      assert ref.source_session_uri == URI.new!("session://system/default/author")

      assert PublishedBoardRef.identity_key(ref) ==
               {"session://system/default/author", "entity://system/agent/hello-kanban"}
    end

    test "rejects copied Kanban payload fields" do
      attrs = valid_attrs()

      for forbidden <- [:tree, :nodes, :tasks, :statuses] do
        assert {:error, {:forbidden_board_payload, ^forbidden}} =
                 PublishedBoardRef.new(Map.put(attrs, forbidden, %{}))
      end

      assert {:error, {:forbidden_board_payload, "tree"}} =
               PublishedBoardRef.new(Map.put(attrs, "tree", %{}))
    end

    test "fails closed for wrong URI kinds and malformed publication metadata" do
      assert {:error, {:invalid_uri, :board_uri}} =
               valid_attrs()
               |> Map.put(:board_uri, "session://system/default/not-a-board")
               |> PublishedBoardRef.new()

      assert {:error, {:invalid_uri, :source_session_uri}} =
               valid_attrs()
               |> Map.put(:source_session_uri, "entity://system/user/not-a-session")
               |> PublishedBoardRef.new()

      assert {:error, {:invalid_field, :receive_ref}} =
               valid_attrs()
               |> Map.put(:receive_ref, "")
               |> PublishedBoardRef.new()

      assert {:error, {:invalid_field, :revision}} =
               valid_attrs()
               |> Map.put(:revision, 0)
               |> PublishedBoardRef.new()
    end
  end

  describe "default publication port" do
    test "fails honestly while the Kanban Mount dependency is not on main" do
      ctx = %{caller: URI.new!("entity://system/user/admin"), caps: MapSet.new()}

      assert {:error, :dependency_not_landed} =
               KanbanPublishedRead.publish_board_read(
                 ctx,
                 URI.new!("session://system/default/author"),
                 URI.new!("entity://system/agent/hello-kanban")
               )

      assert {:error, :dependency_not_landed} =
               KanbanPublishedRead.refresh_published_board(
                 ctx,
                 %PublishedBoardRef{
                   board_uri: URI.new!("entity://system/agent/hello-kanban"),
                   source_session_uri: URI.new!("session://system/default/author"),
                   receive_ref: "/socialware/kanban/receive?token=redacted",
                   revision: 1
                 }
               )
    end
  end

  defp valid_attrs do
    %{
      board_uri: "entity://system/agent/hello-kanban",
      source_session_uri: "session://system/default/author",
      receive_ref: "/socialware/kanban/receive?token=redacted",
      revision: 1
    }
  end
end
