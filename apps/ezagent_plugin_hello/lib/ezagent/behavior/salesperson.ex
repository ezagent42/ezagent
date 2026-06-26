defmodule Ezagent.Behavior.Salesperson do
  @moduledoc """
  The `@salesperson` Behavior — a session-member agent that answers a user
  request with a json-render FRAGMENT (a table/card shown inline in a chat
  bubble), WITHOUT touching the page. The counterpart to `Behavior.HelloBuilder`:
  `@hello` edits the page, `@salesperson` replies with json-render data cards — a
  clean, mention-gated split (no `card:` prefix needed).

  On `:receive` of a USER message (the session's `chat.send` fans `chat.receive`
  out to the mentioned members), it kicks off `EzagentPluginHello.Generator`'s
  card path in a supervised Task, which calls the LLM, validates the fragment
  against the catalog, and posts it via `TurnDriver.say_render`. Non-user senders
  (the builder's output, its own output) are ignored so it never loops.
  """

  use Ezagent.Lifecycle

  alias Ezagent.Message

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Reply to a user request with a json-render card (no page edit)"
  )

  # Keys on the `:salesperson` axis (mirrors hello_builder's `:hello_builder`).
  def required_caps do
    %{receive: Ezagent.Capability.cap(:salesperson, __MODULE__, :receive)}
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    with true <- from_user?(msg),
         %URI{} = session_uri <- session_from_ctx(ctx),
         text when is_binary(text) and text != "" <- extract_text(msg.body) do
      _ = EzagentPluginHello.Generator.start_card_reply(session_uri, text)
    end

    {:ok, %{}, []}
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals (same classification as hello_builder) ------------------

  defp from_user?(%Message{sender: %URI{} = uri}), do: Ezagent.URI.type?(uri, :user)
  defp from_user?(_), do: false

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp session_from_ctx(%{caller: %URI{} = u}), do: u

  defp session_from_ctx(%{caller: s}) when is_binary(s) do
    try do
      Ezagent.URI.new!(s)
    rescue
      ArgumentError -> nil
    end
  end

  defp session_from_ctx(_), do: nil
end
