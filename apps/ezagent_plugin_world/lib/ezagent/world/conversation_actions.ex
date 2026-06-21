defmodule Ezagent.World.ConversationActions do
  @moduledoc """
  Socket-side conversation dispatch handlers for the world plugin
  (LV→world parity migration PR-1).

  Mirrors the LiveView plugin's `Admin.Compose` pattern: `WorldLive` keeps
  thin `handle_event` clauses and delegates the bodies here, so the shell
  module stays modular as later PRs add more conversation surface. Pure data
  shaping lives in `Ezagent.World.ConversationData`; this module owns the
  `Ezagent.Invocation.dispatch/1` calls + `push_event`/`assign` plumbing and
  returns `{:noreply, socket}` tuples ready to hand back from `WorldLive`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ezagent.Invocation
  alias Ezagent.World.ConversationData

  @doc """
  Send a chat message into a session via the `:session :send` dispatch
  (`:cast`, mirroring `Admin.Compose.submit/2`). The cast'd message returns
  to the sender through the inbound bridge, so no optimistic insert is done.
  Empty/whitespace text is refused without a dispatch.
  """
  @spec send_message(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def send_message(socket, %URI{} = session_uri, text) when is_binary(text) do
    caller = socket.assigns.current_entity_uri
    caps = Map.get(socket.assigns, :current_caps, MapSet.new())

    if String.trim(text) == "" do
      {:noreply, assign(socket, :last_dispatch_status, "error:empty_message")}
    else
      msg = ConversationData.build_message(caller, text)
      target = Ezagent.URI.with_action(session_uri, :session, :send)

      result =
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{caller: caller, caps: caps, reply: :ignore}
        })

      case result do
        :ok -> {:noreply, assign(socket, :last_dispatch_status, "ok")}
        {:ok, _} -> {:noreply, assign(socket, :last_dispatch_status, "ok")}
        {:error, reason} -> {:noreply, assign(socket, :last_dispatch_status, "error:#{reason(reason)}")}
      end
    end
  end

  @doc """
  Page history backwards and push the older rows to the island for prepend
  (parity: `load_older_messages` over `Ezagent.MessageStore.older_than/3`).
  """
  @spec load_older(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def load_older(socket, %URI{} = session_uri, before) when is_binary(before) do
    {older, next_cursor} = ConversationData.load_older(session_uri, before)

    {:noreply,
     push_event(socket, "chat:older", %{"messages" => older, "oldest_cursor" => next_cursor})}
  end

  @doc """
  Fire-and-forget read marker (parity: `mark_displayed`). Best-effort — never
  surfaces an error to the user.
  """
  @spec mark_displayed(Phoenix.LiveView.Socket.t(), URI.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def mark_displayed(socket, %URI{} = session_uri, msg_id) when is_binary(msg_id) and msg_id != "" do
    _ =
      Ezagent.Session.ReadMarker.mark(
        session_uri,
        socket.assigns.current_entity_uri,
        msg_id,
        :displayed
      )

    {:noreply, socket}
  end

  defp reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason(reason), do: inspect(reason)
end
