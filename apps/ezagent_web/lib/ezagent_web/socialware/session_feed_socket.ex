defmodule EzagentWeb.Socialware.SessionFeedSocket do
  @moduledoc """
  Generic socialware feed socket.

  This socket is additive in PR-1: it is not mounted in the endpoint yet. It
  lifts the existing per-surface token flow inline: parse the requested session,
  verify the server-minted `ChatFeedAuth` caller token for that session, and
  resolve the requested pull adapter from `AdapterRegistry`.
  """

  use Phoenix.Socket

  alias Ezagent.Socialware.ChatFeedAuth
  alias EzagentWeb.Socialware.SessionFeedChannel

  @adapter Module.concat(["Ezagent", "ExternalMirror", "Adapter"])
  @adapter_registry Module.concat(["Ezagent", "ExternalMirror", "AdapterRegistry"])

  channel "socialware:feed:*", SessionFeedChannel

  @impl true
  def connect(params, socket, _connect_info) do
    with {:ok, adapter_id} <- Map.fetch(params, "adapter_id"),
         {:ok, session_str} <- Map.fetch(params, "session_uri"),
         {:ok, token} <- Map.fetch(params, "token"),
         {:ok, session_uri} <- parse_session(session_str),
         {:ok, caller} <- ChatFeedAuth.verify(token, session_uri),
         {:ok, adapter} <- adapter_lookup(adapter_id) do
      {:ok,
       socket
       |> assign(:adapter_id, adapter_id)
       |> assign(:adapter, adapter)
       |> assign(:session_uri, session_uri)
       |> assign(:caller, caller)
       |> assign(:delivery_discipline, adapter_delivery_discipline(adapter))
       |> assign(:participation_profile, adapter_participation_profile(adapter))}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "socialware_feed:" <> URI.to_string(socket.assigns.session_uri)

  defp adapter_lookup(adapter_id), do: apply(@adapter_registry, :lookup, [adapter_id])

  defp adapter_delivery_discipline(adapter),
    do: apply(@adapter, :delivery_discipline_of, [adapter])

  defp adapter_participation_profile(adapter),
    do: apply(@adapter, :participation_profile_of, [adapter])

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
