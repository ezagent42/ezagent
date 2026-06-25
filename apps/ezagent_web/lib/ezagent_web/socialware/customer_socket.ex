defmodule EzagentWeb.Socialware.CustomerSocket do
  @moduledoc """
  Socket for customer-facing socialware feeds.

  The socket authenticates a session-binding token before any channel can
  subscribe. Customer clients never join raw session feeds.
  """
  use Phoenix.Socket

  alias Ezagent.Socialware.{ChatFeedAuth, CustomerFeed}

  channel "socialware:customer:*", EzagentWeb.Socialware.CustomerChannel

  @impl true
  def connect(params, socket, _connect_info) do
    with {:ok, session_str} <- Map.fetch(params, "session_uri"),
         {:ok, token} <- Map.fetch(params, "token"),
         {:ok, session_uri} <- parse_session(session_str),
         {:ok, _snapshot} <- CustomerFeed.snapshot(session_uri, token) do
      {:ok,
       socket
       |> assign(:session_uri, session_uri)
       |> assign(:token, token)
       |> assign(:viewer_principal, viewer_principal(params, session_uri))}
    else
      _ -> :error
    end
  end

  # The OPTIONAL logged-in viewer identity (or nil for anonymous). The customer
  # `token` (CustomerAuth) only proves session+ws access; `viewer_token`
  # (ChatFeedAuth) proves WHO is viewing — used by the channel for join/post. A
  # missing/invalid viewer_token degrades to anonymous read-only, NEVER an error
  # (an anonymous visitor must still get the read-only page).
  defp viewer_principal(params, session_uri) do
    case Map.get(params, "viewer_token") do
      token when is_binary(token) and token != "" ->
        case ChatFeedAuth.verify(token, session_uri) do
          {:ok, %URI{} = principal} -> principal
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def id(socket), do: "socialware_customer:" <> URI.to_string(socket.assigns.session_uri)

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
