defmodule Ezagent.World.KbSourceStoreTest do
  use ExUnit.Case, async: false

  alias Ezagent.Resource.FsResolver
  alias Ezagent.World.KbSourceStore
  alias Ezagent.World.WorkspacePluginActions

  @workspace "kb-import-test"
  @workspace_uri URI.new!("workspace://#{@workspace}")

  setup_all do
    spec = %{
      backend_component: "kb-sources",
      authority: &FsResolver.config_dir_authority/2
    }

    case FsResolver.register_type("kb-source", spec) do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
      {:error, {:duplicate_type, _}} -> :ok
    end

    :ok
  end

  setup do
    on_exit(fn ->
      @workspace
      |> then(&Path.join(Ezagent.Home.path("kb-sources"), &1))
      |> File.rm_rf()
    end)

    :ok
  end

  test "stores pasted text through the workspace-scoped resolver" do
    assert {:ok, source} =
             KbSourceStore.store(@workspace_uri, %{
               "title" => "Incident Guide",
               "content" => "Escalate severity one incidents immediately."
             })

    assert String.starts_with?(
             source.source_uri,
             "resource://#{@workspace}/kb-source/"
           )

    assert File.read!(source.path) ==
             "# Incident Guide\n\nEscalate severity one incidents immediately."
  end

  test "accepts txt and md uploads and rejects unsupported types" do
    for filename <- ["guide.txt", "guide.MD"] do
      assert {:ok, source} =
               KbSourceStore.store(@workspace_uri, %{
                 "title" => "Guide",
                 "content" => "Useful text",
                 "filename" => filename
               })

      assert File.exists?(source.path)
    end

    assert {:error, :unsupported_file_type} =
             KbSourceStore.store(@workspace_uri, %{
               "title" => "PDF",
               "content" => "not accepted",
               "filename" => "guide.pdf"
             })
  end

  test "rejects blank, invalid, and oversized content without creating a file" do
    invalid_documents = [
      {%{"title" => "", "content" => "text"}, :title_required},
      {%{"title" => "Guide", "content" => "   "}, :content_required},
      {%{"title" => "Guide", "content" => :not_text}, :content_required},
      {%{
         "title" => "Guide",
         "content" => String.duplicate("a", KbSourceStore.max_content_bytes() + 1)
       }, :content_too_large}
    ]

    for {document, expected_error} <- invalid_documents do
      assert {:error, ^expected_error} = KbSourceStore.store(@workspace_uri, document)
    end

    workspace_dir = Path.join(Ezagent.Home.path("kb-sources"), @workspace)
    assert not File.exists?(workspace_dir)
  end

  test "cleanup removes a source after a failed downstream ingest" do
    assert {:ok, source} =
             KbSourceStore.store(@workspace_uri, %{
               "title" => "Temporary",
               "content" => "Remove me"
             })

    assert File.exists?(source.path)
    assert :ok = KbSourceStore.cleanup(source)
    refute File.exists?(source.path)
  end

  test "an unauthorized import is rejected before a kb-source file is created" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        world_state: %{},
        current_caps: MapSet.new(),
        current_entity_uri: nil,
        current_workspace_uri: @workspace_uri
      }
    }

    {:noreply, socket} =
      WorkspacePluginActions.ingest_kb_documents(
        socket,
        "entity://#{@workspace}/agent/handbook",
        [%{"title" => "Denied", "content" => "Must not be written"}]
      )

    assert socket.assigns.last_dispatch_status == "error:kb_import_failed"
    assert socket.assigns.world_state["kb_error"] == "unauthorized"

    workspace_dir = Path.join(Ezagent.Home.path("kb-sources"), @workspace)
    refute File.exists?(workspace_dir)
  end
end
