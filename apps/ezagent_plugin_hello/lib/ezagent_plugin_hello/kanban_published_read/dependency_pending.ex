defmodule EzagentPluginHello.KanbanPublishedRead.DependencyPending do
  @moduledoc false

  @behaviour EzagentPluginHello.KanbanPublishedRead

  @impl true
  def publish_board_read(_ctx, _source_session_uri, _board_uri),
    do: {:error, :dependency_not_landed}

  @impl true
  def refresh_published_board(_ctx, _published_board_ref),
    do: {:error, :dependency_not_landed}
end
