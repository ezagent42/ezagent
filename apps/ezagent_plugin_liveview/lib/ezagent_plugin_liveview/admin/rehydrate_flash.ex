defmodule EzagentPluginLiveview.Admin.RehydrateFlash do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  use Gettext, backend: EzagentPluginLiveview.Gettext

  @doc false
  def assign(socket, meta) when is_map(meta) do
    case Map.get(meta, :orchestrator_status) do
      :ready ->
        socket

      :failed ->
        reason = Map.get(meta, :orchestrator_error)

        if reason == :no_orchestrator do
          socket
        else
          assign(
            socket,
            :flash_error,
            gettext(
              "Orchestrator failed during main-session rehydrate: %{reason}; click Restart to retry.",
              reason: inspect(reason)
            )
          )
        end

      _ ->
        socket
    end
  end

  def assign(socket, _), do: socket
end
