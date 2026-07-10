defmodule Ezagent.ActionSet.HelloSharer do
  @moduledoc """
  The hello SHARER agent Behavior — wraps "create share link" as a dispatchable
  action so the front-desk relay can route a share request here.

  Native-flavor (no bridge adapter) — reachable via dispatch, not chat delivery
  (T2 I-1). On `:share`, posts a chat message with the public session URL using
  ITS OWN URI as sender, so the front-desk loop guard excludes it.
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
  @doc false
  def create(_args), do: {:ok, %{}}

  @doc """
  Dispatchable share entry. Posts the session's public URL as a chat message
  from the sharer agent itself (so the front-desk loop guard blocks re-routing).
  """
  def handle_share(%{session_uri: session_str}, _ctx)
      when is_binary(session_str) and session_str != "" do
    case parse_session_uri(session_str) do
      {:ok, session_uri} ->
        share_url = "/socialware/chat?session_uri=#{URI.to_string(session_uri)}"

        case EzagentPluginHello.Members.role_uri(session_uri, "sharer") do
          {:ok, sharer_uri} ->
            _ =
              EzagentPluginHello.TurnDriver.say(
                session_uri,
                sharer_uri,
                "Public URL: #{share_url}"
              )

          :error ->
            :ok
        end

      :error ->
        :ok
    end

    {:ok, %{}, []}
  end

  @doc false
  def handle_share(_args, _ctx), do: {:ok, %{}, []}

  @doc false
  def handle_receive(_args, _ctx), do: {:ok, %{}, []}

  # caps-data-ownership
  @doc false
  def data_owner(:any), do: :any

  @doc false
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
end
