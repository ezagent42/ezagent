defmodule EzagentWeb.Socialware.ExternalFeedSocket do
  @moduledoc """
  Socket for the external socialware surface feed.

  Authenticates a signed caller-identity token (`ChatFeedAuth`) before any
  channel can subscribe, recovering a TRUSTED caller `%URI{}` (a minted read-only
  anon-User or a signed-in member). The actual read authorization (is this caller
  an owner/member of the session?) is the LIVE `Membership` check the channel +
  `ExternalFeed` run on every read — the token only proves the SERVER minted it
  for that caller on that session. External clients never join raw session feeds.
  """
  use Phoenix.Socket

  alias Ezagent.Socialware.ChatFeedAuth

  channel "socialware:external:*", EzagentWeb.Socialware.SessionFeedChannel

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
  def id(socket), do: "socialware_external:" <> URI.to_string(socket.assigns.session_uri)

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
