defmodule Ezagent.ActionSet.HelloSharer do
  @moduledoc """
  The hello SHARER agent Behavior — wraps "create share link" as a dispatchable
  action so the front-desk relay can route a share request here.

  Native-flavor (no bridge adapter) — reachable via dispatch, not chat delivery
  (T2 I-1). On `:share`, posts a chat message with the public session URL.
  """

  use Ezagent.Lifecycle

  action(:share,
    args: %{session_uri: :string},
    returns: %{},
    caps: [:share],
    modes: [:cast],
    description: "Create and post a public share link for the hello session"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  Dispatchable share entry. Posts the session's public URL as a chat message.
  """
  def handle_share(%{session_uri: session_str}, _ctx)
      when is_binary(session_str) and session_str != "" do
    case parse_session_uri(session_str) do
      {:ok, session_uri} ->
        share_url = "/socialware/chat?session_uri=#{URI.to_string(session_uri)}"
        _ = post_share_message(session_uri, share_url)
        {:ok, %{}, []}

      :error ->
        {:ok, %{}, []}
    end
  end

  def handle_share(_args, _ctx), do: {:ok, %{}, []}

  def handle_receive(_args, _ctx), do: {:ok, %{}, []}

  # caps-data-ownership
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals --------------------------------------------------------

  defp parse_session_uri(session_str) do
    case Ezagent.URI.new!(session_str) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp post_share_message(%URI{} = session_uri, share_url) do
    _ =
      EzagentPluginHello.TurnDriver.say(
        session_uri,
        Ezagent.Entity.User.admin_uri(),
        "Public URL: #{share_url}"
      )

    :ok
  end
end
