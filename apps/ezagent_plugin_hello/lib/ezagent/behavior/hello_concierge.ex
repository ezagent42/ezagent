defmodule Ezagent.Behavior.HelloConcierge do
  @moduledoc """
  The hello CONCIERGE agent Behavior — a READ-ONLY navigation/Q&A copilot for the
  public website (the §5.2 门户助手).

  On `:receive` of a USER message (routed to it by `@`-mention when the sender is
  NOT the session owner — see `EzagentWeb.Socialware.SessionFeedChannel`), it
  answers grounded in the current page content via
  `EzagentPluginHello.Generator.concierge_answer/3` and posts a chat reply. It
  NEVER drives `Behavior.Surface` — it structurally cannot edit / generate /
  publish the page (only the builder, `Ezagent.Behavior.HelloBuilder`, does that).
  That hard separation is the safety gate: even a prompt-injected concierge has no
  page-write path.

  Mirrors `Ezagent.Behavior.HelloBuilder`'s `:receive` shape; no durable state.
  """

  use Ezagent.Lifecycle

  alias Ezagent.Message

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Answer a visitor question about the site (read-only)"
  )

  # The concierge Kind is `Ezagent.Entity.HelloConcierge` (type_name
  # :hello_concierge), so the cap subject keys on the `:hello_concierge` axis.
  def required_caps do
    %{receive: Ezagent.Capability.cap(:hello_concierge, __MODULE__, :receive)}
  end

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  On an inbound USER message, answer as the concierge (fire-and-forget Task).
  Ignores non-user messages (other agents, its own output) so it never loops.
  Emits no effects — the reply lands via `Generator.concierge_answer`'s `say`.
  """
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    with true <- from_user?(msg),
         %URI{} = session_uri <- session_from_ctx(ctx),
         text when is_binary(text) and text != "" <- extract_text(msg.body) do
      _ =
        EzagentPluginHello.Generator.concierge_start(
          session_uri,
          text,
          concierge_uri(session_uri)
        )
    end

    {:ok, %{}, []}
  end

  # caps-data-ownership — admin-only Behavior; no per-entity owner.
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals (mirror HelloBuilder) ----------------------------------

  defp from_user?(%Message{sender: %URI{} = uri}), do: Ezagent.URI.type?(uri, :user)
  defp from_user?(_), do: false

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  defp session_from_ctx(%{caller: %URI{} = u}), do: u

  defp session_from_ctx(%{caller: s}) when is_binary(s) do
    Ezagent.URI.new!(s)
  rescue
    ArgumentError -> nil
  end

  defp session_from_ctx(_), do: nil

  # session://<ws>/<tmpl>/<name> → entity://<ws>/agent/concierge_<name>
  defp concierge_uri(%URI{} = session_uri) do
    ws = Ezagent.URI.workspace_name!(session_uri)
    name = session_uri.path |> to_string() |> String.split("/", trim: true) |> List.last()
    Ezagent.URI.entity(ws, :agent, "concierge_#{name}")
  end
end
