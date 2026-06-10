defmodule EzagentWeb.Socialware.CustomerChannel do
  @moduledoc """
  Authenticated channel for the gated socialware customer projection.

  Join replies and live pushes are derived exclusively from
  `Ezagent.Socialware.CustomerFeed`, so operator-only/raw session content is
  never exposed on this customer route.
  """
  use Phoenix.Channel

  alias Ezagent.Socialware.CustomerFeed

  @impl true
  def join("socialware:customer:" <> session_str, _params, socket) do
    with true <- session_str == URI.to_string(socket.assigns.session_uri),
         {:ok, snapshot} <-
           CustomerFeed.snapshot(socket.assigns.session_uri, socket.assigns.token),
         :ok <-
           Phoenix.PubSub.subscribe(
             EzagentCore.PubSub,
             CustomerFeed.topic(socket.assigns.session_uri)
           ) do
      {:ok, %{snapshot: encode_snapshot(snapshot)}, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("history", _params, socket) do
    case CustomerFeed.history(socket.assigns.session_uri, socket.assigns.token) do
      {:ok, %{messages: messages}} ->
        {:reply, {:ok, %{messages: encode_messages(messages)}}, socket}

      {:error, :unauthorized} ->
        {:reply, {:error, %{reason: "unauthorized"}}, socket}
    end
  end

  @impl true
  def handle_info({:customer_delivery, _payload}, socket) do
    case CustomerFeed.snapshot(socket.assigns.session_uri, socket.assigns.token) do
      {:ok, snapshot} -> push(socket, "snapshot", encode_snapshot(snapshot))
      {:error, :unauthorized} -> :ok
    end

    {:noreply, socket}
  end

  defp encode_snapshot(%{messages: messages, page: page}) do
    %{messages: encode_messages(messages), page: page}
  end

  defp encode_messages(messages) do
    Enum.map(messages, fn message ->
      %{
        id: message.id,
        text: message_text(message),
        sender: URI.to_string(message.sender)
      }
    end)
  end

  defp message_text(message) do
    Map.get(message.body, "text") || Map.get(message.body, :text)
  end
end
