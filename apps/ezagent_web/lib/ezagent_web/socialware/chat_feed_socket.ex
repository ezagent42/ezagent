defmodule EzagentWeb.Socialware.ChatFeedSocket do
  @moduledoc """
  P4 — socket for the CHAT external SPA view. The chat analogue of
  `EzagentWeb.Socialware.ExternalFeedSocket` (P3-2): it authenticates a signed
  caller-identity token (`ChatFeedAuth`) before any channel can subscribe,
  recovering a TRUSTED caller `%URI{}`. The actual read authorization (is this
  caller an owner/member of the chat session?) is the LIVE `ChatMembership`
  check the channel runs on join — the token only proves the SERVER minted it
  for that caller on that session.
  """
  use Phoenix.Socket

  alias Ezagent.Socialware.ChatFeedAuth

  channel "socialware:chat_feed:*", EzagentWeb.Socialware.ChatFeedChannel

  @impl true
  def connect(params, socket, _connect_info) do
    with {:ok, session_str} <- Map.fetch(params, "session_uri"),
         {:ok, token} <- Map.fetch(params, "token"),
         {:ok, session_uri} <- parse_session(session_str),
         {:ok, caller} <- ChatFeedAuth.verify(token, session_uri) do
      {:ok,
       socket
       |> assign(:session_uri, session_uri)
       |> assign(:caller, caller)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket),
    do: "socialware_chat_feed:" <> URI.to_string(socket.assigns.session_uri)

  defp parse_session(value) when is_binary(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_session(_value), do: :error
end
