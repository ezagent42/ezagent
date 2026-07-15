defmodule EzagentPluginHello.KanbanPublishedRead do
  @moduledoc """
  Hello-owned port for publishing and refreshing permission-aware Kanban reads.

  The configured adapter must delegate authorization and data reads to Kanban.
  Until #1374/#1376 land on main, the default adapter fails explicitly.
  """

  alias EzagentPluginHello.PublishedBoardRef

  @type caller_ctx :: %{required(:caller) => URI.t(), optional(:caps) => MapSet.t()}
  @type error_reason ::
          :forbidden
          | :expired
          | :not_found
          | :no_target_session
          | :unavailable
          | :dependency_not_landed

  @callback publish_board_read(caller_ctx(), URI.t(), URI.t()) ::
              {:ok, PublishedBoardRef.t()} | {:error, error_reason()}

  @callback refresh_published_board(caller_ctx(), PublishedBoardRef.t()) ::
              {:ok, map()} | {:error, error_reason()}

  @spec publish_board_read(caller_ctx(), URI.t(), URI.t()) ::
          {:ok, PublishedBoardRef.t()} | {:error, error_reason()}
  def publish_board_read(ctx, %URI{} = source_session_uri, %URI{} = board_uri)
      when is_map(ctx) do
    adapter().publish_board_read(ctx, source_session_uri, board_uri)
  end

  @spec refresh_published_board(caller_ctx(), PublishedBoardRef.t()) ::
          {:ok, map()} | {:error, error_reason()}
  def refresh_published_board(ctx, %PublishedBoardRef{} = ref) when is_map(ctx) do
    adapter().refresh_published_board(ctx, ref)
  end

  defp adapter do
    Application.get_env(
      :ezagent_plugin_hello,
      :kanban_published_read_adapter,
      EzagentPluginHello.KanbanPublishedRead.DependencyPending
    )
  end
end
