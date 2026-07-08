defmodule Ezagent.ActionSet.HelloConcierge do
  @moduledoc """
  The hello CONCIERGE agent Behavior — a READ-ONLY navigation/Q&A copilot for the
  public website (the §5.2 门户助手).

  Two entry points:
  - `:receive` — chat delivery (dormant; the concierge is native-flavor, cannot
    receive chat messages). Kept for future T2 §5 table-triggered dispatch.
  - `:answer` — dispatchable action (the ACTIVE entry). Native-flavor members
    cannot receive chat delivery, so the session front-desk dispatches here
    instead of posting a chat message. Takes `session_uri` + `text`, runs the
    concierge LLM pipeline, and posts the reply as a chat message.

  NEVER drives `Behavior.Surface` — structurally cannot edit / generate / publish
  the page (only the builder does that). This is the safety gate.
  """

  use Ezagent.Lifecycle

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Answer a visitor question about the site (read-only, chat delivery)"
  )

  action(:answer,
    args: %{session_uri: :string, text: :string},
    returns: %{},
    caps: [:answer],
    modes: [:cast],
    description:
      "Answer a visitor question about the hello page (dispatchable, for native flavor)"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  Dispatchable answer entry — the ACTIVE path for a native-flavor concierge.
  Mirrors `HelloBuilder.handle_rebuild/2`.
  """
  def handle_answer(%{session_uri: session_str, text: text}, _ctx)
      when is_binary(session_str) and is_binary(text) and text != "" do
    with {:ok, session_uri} <- parse_session_uri(session_str),
         {:ok, concierge_uri} <- EzagentPluginHello.Members.role_uri(session_uri, "concierge") do
      _ = EzagentPluginHello.Generator.concierge_start(session_uri, text, concierge_uri)
    end

    {:ok, %{}, []}
  end

  def handle_answer(_args, _ctx), do: {:ok, %{}, []}

  def handle_receive(_args, _ctx), do: {:ok, %{}, []}

  # caps-data-ownership — admin-only Behavior; no per-entity owner.
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
end
