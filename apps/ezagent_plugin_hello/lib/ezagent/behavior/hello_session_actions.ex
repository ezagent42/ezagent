defmodule Ezagent.ActionSet.HelloSessionActions do
  @moduledoc """
  Deterministic Hello operations hosted by the Hello Session.

  Hello only materializes two agents: the chat-facing `front-desk` and the
  flavor-backed `llm`. Building, answering, sharing, publishing, and Kanban
  delegation are session-scoped actions; they do not need independent agent
  identities, recipes, or membership edges.
  """

  use Ezagent.Lifecycle

  action(:rebuild,
    args: %{session_uri: :string, instruction: :string},
    returns: %{},
    caps: [:rebuild],
    modes: [:cast],
    description: "Generate or update the Hello page for this session"
  )

  action(:answer,
    args: %{session_uri: :string, text: :string},
    returns: %{},
    caps: [:answer],
    modes: [:cast],
    description: "Answer a question about the Hello page without changing it"
  )

  action(:share,
    args: %{session_uri: :string},
    returns: %{},
    caps: [:share],
    modes: [:cast],
    description: "Post the public Hello session URL"
  )

  action(:publish,
    args: %{session_uri: :string, instruction: :string},
    returns: %{},
    caps: [:publish],
    modes: [:cast],
    description: "Publish the current Hello session as a template"
  )

  action(:delegate_to_kanban,
    args: %{session_uri: :string, instruction: :string, sender_uri: :string},
    returns: %{},
    caps: [:delegate_to_kanban],
    modes: [:cast],
    description: "Delegate a Hello instruction to the workspace Kanban"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_rebuild(%{session_uri: session, instruction: instruction}, _ctx)
      when is_binary(session) and is_binary(instruction) and instruction != "" do
    with {:ok, session_uri} <- parse_session_uri(session) do
      _ = generator_start(session_uri, instruction)
    end

    {:ok, %{}, []}
  end

  def handle_rebuild(_args, _ctx), do: {:ok, %{}, []}

  def handle_answer(%{session_uri: session, text: text}, _ctx)
      when is_binary(session) and is_binary(text) and text != "" do
    with {:ok, session_uri} <- parse_session_uri(session),
         {:ok, actor_uri} <- front_desk_uri(session_uri) do
      _ = EzagentPluginHello.Generator.concierge_start(session_uri, text, actor_uri)
    end

    {:ok, %{}, []}
  end

  def handle_answer(_args, _ctx), do: {:ok, %{}, []}

  def handle_share(%{session_uri: session}, _ctx) when is_binary(session) and session != "" do
    with {:ok, session_uri} <- parse_session_uri(session),
         {:ok, actor_uri} <- front_desk_uri(session_uri) do
      share_url = "/socialware/chat?session_uri=#{URI.to_string(session_uri)}"
      _ = EzagentPluginHello.TurnDriver.say(session_uri, actor_uri, "Public URL: #{share_url}")
    end

    {:ok, %{}, []}
  end

  def handle_share(_args, _ctx), do: {:ok, %{}, []}

  def handle_publish(args, ctx) when is_map(args) and is_map(ctx) do
    _ = Ezagent.ActionSet.HelloPublisher.publish_from_session(args, ctx)
    {:ok, %{}, []}
  end

  def handle_publish(_args, _ctx), do: {:ok, %{}, []}

  def handle_delegate_to_kanban(
        %{session_uri: session, instruction: instruction, sender_uri: sender},
        _ctx
      )
      when is_binary(session) and is_binary(instruction) and is_binary(sender) do
    with {:ok, session_uri} <- parse_session_uri(session),
         {:ok, sender_uri} <- parse_entity_uri(sender),
         instruction when instruction != "" <- String.trim(instruction) do
      EzagentPluginHello.KanbanDelegation.start(session_uri, instruction, sender_uri)
    end

    {:ok, %{}, []}
  end

  def handle_delegate_to_kanban(_args, _ctx), do: {:ok, %{}, []}

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  defp front_desk_uri(session_uri),
    do: EzagentPluginHello.Members.role_uri(session_uri, "front-desk")

  defp generator_start(%URI{} = session_uri, instruction) when is_binary(instruction) do
    Application.get_env(
      :ezagent_plugin_hello,
      :generator_start,
      &EzagentPluginHello.Generator.start/2
    )
    |> then(& &1.(session_uri, instruction))
  end

  defp parse_session_uri(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp parse_entity_uri(value) do
    case Ezagent.URI.new!(value) do
      %URI{scheme: "entity"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
