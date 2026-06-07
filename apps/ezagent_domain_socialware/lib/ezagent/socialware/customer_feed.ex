defmodule Ezagent.Socialware.CustomerFeed do
  @moduledoc """
  Gated customer projection for socialware sessions.

  Customer routes must use this module rather than raw MessageStore,
  Publisher, or ExternalMirror streams.
  """

  alias Ezagent.{Behavior.Surface, MessageStore}
  alias Ezagent.Socialware.CustomerAuth

  @history_limit 100

  @spec topic(URI.t()) :: String.t()
  def topic(%URI{} = session_uri), do: "socialware:customer:" <> URI.to_string(session_uri)

  @spec snapshot(URI.t(), String.t()) :: {:ok, map()} | {:error, :unauthorized}
  def snapshot(%URI{} = session_uri, token) do
    with {:ok, workspace_uri} <- workspace(session_uri),
         :ok <- CustomerAuth.authorize(token, session_uri, workspace_uri) do
      {:ok,
       %{
         messages: MessageStore.committed_customer_visible(session_uri, @history_limit),
         page: customer_page(session_uri)
       }}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @spec history(URI.t(), String.t()) :: {:ok, map()} | {:error, :unauthorized}
  def history(%URI{} = session_uri, token) do
    with {:ok, workspace_uri} <- workspace(session_uri),
         :ok <- CustomerAuth.authorize(token, session_uri, workspace_uri) do
      {:ok, %{messages: MessageStore.committed_customer_visible(session_uri, @history_limit)}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp workspace(session_uri) do
    case Ezagent.WorkspaceRegistry.lookup(session_uri) do
      {:ok, workspace_uri} -> {:ok, workspace_uri}
      :error -> {:error, :unbound_session}
    end
  end

  defp customer_page(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, surface} -> Surface.customer_tree(surface)
      _ -> nil
    end
  end
end
