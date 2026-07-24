defmodule EzagentWeb.Socialware.KanbanPublishedReadAdapter do
  @moduledoc """
  Web composition adapter that publishes a Hello reference through Kanban's
  existing permission-checked share-link contract.

  The adapter never copies board contents or mints capabilities. Receiving the
  signed reference remains the responsibility of `KanbanShareController`,
  which mounts the original board read-only through `Ezagent.Socialware.Mount`.
  """

  @behaviour EzagentPluginHello.KanbanPublishedRead

  import Phoenix.Component, only: [assign: 3]

  alias EzagentPluginKanban.WorldActions
  alias EzagentPluginHello.PublishedBoardRef

  @impl true
  def publish_board_read(ctx, %URI{} = source_session_uri, %URI{} = board_uri) do
    with {:ok, receive_ref} <- issue_receive_ref(ctx, board_uri) do
      PublishedBoardRef.new(%{
        board_uri: board_uri,
        source_session_uri: source_session_uri,
        receive_ref: receive_ref,
        revision: 1
      })
    end
  end

  @impl true
  def refresh_published_board(ctx, %PublishedBoardRef{} = ref) do
    with {:ok, receive_ref} <- issue_receive_ref(ctx, ref.board_uri) do
      PublishedBoardRef.new(%{
        board_uri: ref.board_uri,
        source_session_uri: ref.source_session_uri,
        receive_ref: receive_ref,
        revision: ref.revision + 1
      })
    end
  end

  defp issue_receive_ref(%{caller: %URI{} = caller} = ctx, board_uri) do
    endpoint = Map.get(ctx, :endpoint, EzagentWeb.Endpoint)
    workspace_uri = Map.get(ctx, :workspace_uri, Ezagent.URI.workspace_of(caller))

    issue_receive_ref(ctx, caller, endpoint, workspace_uri, board_uri)
  end

  defp issue_receive_ref(_ctx, _board_uri), do: {:error, :unavailable}

  defp issue_receive_ref(
         ctx,
         caller,
         endpoint,
         %URI{scheme: "workspace"} = workspace_uri,
         board_uri
       )
       when is_atom(endpoint) do
    # `ctx.caps` is a request-time JIT capability (`Ezagent.Cap.issue/3`, via
    # EzagentPluginHello.KanbanDelegation) that is NEVER written to the caller's
    # durable Identity slice. It is carried through PresenterCaps' explicit
    # EPHEMERAL narrow path, tagged so ONLY this JIT-cap opt-in is admitted (a
    # bare/stale %Capability{} is rejected). Plain `load/1` would (correctly)
    # drop it — after actor-extraction C1, `load/1` re-derives caps FRESH and no
    # longer merges a mount snapshot.
    ephemeral = %Ezagent.World.PresenterCaps.EphemeralCaps{caps: Map.get(ctx, :caps, MapSet.new())}

    socket =
      %Phoenix.LiveView.Socket{endpoint: endpoint}
      |> assign(:current_entity_uri, caller)
      |> assign(:current_workspace_uri, workspace_uri)

    # This web path reaches `WorldActions.share_link/2` WITHOUT going through
    # world_live's `world:dispatch` chokepoint, so this world-aware caller (at
    # the ezagent_web transport edge, which legitimately deps on world) injects
    # the presenter's caps itself — the plugin consumes `:presenter_caps` and
    # never compile-deps on `Ezagent.World.PresenterCaps` (#1476).
    socket =
      assign(
        socket,
        :presenter_caps,
        Ezagent.World.PresenterCaps.load_with_ephemeral(socket, ephemeral)
      )

    case WorldActions.share_link(socket, URI.to_string(board_uri)) do
      {:ok, receive_ref} -> {:ok, receive_ref}
      {:error, :no_access} -> {:error, :forbidden}
      {:error, :bad_kanban_uri} -> {:error, :not_found}
    end
  end

  defp issue_receive_ref(_ctx, _caller, _endpoint, _workspace_uri, _board_uri),
    do: {:error, :unavailable}
end
