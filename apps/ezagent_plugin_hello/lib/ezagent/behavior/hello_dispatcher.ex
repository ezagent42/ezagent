defmodule Ezagent.ActionSet.HelloDispatcher do
  @moduledoc """
  Hello's dedicated conversational delegation role.

  This ActionSet does not own Kanban data and never mutates a board directly.
  It hands the authenticated instruction to the hello-owned delegation service,
  which uses the sanctioned workspace and Kanban dispatch paths.
  """

  use Ezagent.Lifecycle

  action(:delegate_to_kanban,
    args: %{session_uri: :string, instruction: :string, sender_uri: :string},
    returns: %{},
    caps: [:delegate_to_kanban],
    modes: [:cast],
    description: "Delegate a hello conversation instruction to the workspace Kanban"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  def handle_delegate_to_kanban(
        %{session_uri: session, instruction: instruction, sender_uri: sender},
        _ctx
      )
      when is_binary(session) and is_binary(instruction) and is_binary(sender) do
    with {:ok, session_uri} <- parse_uri(session, :session),
         {:ok, sender_uri} <- parse_uri(sender, :entity),
         instruction when instruction != "" <- String.trim(instruction) do
      delegation_start().(session_uri, instruction, sender_uri)
    end

    {:ok, %{}, []}
  end

  def handle_delegate_to_kanban(_args, _ctx), do: {:ok, %{}, []}

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  defp delegation_start do
    Application.get_env(:ezagent_plugin_hello, :kanban_delegation_start, fn
      session_uri, instruction, sender_uri ->
        apply(EzagentPluginHello.KanbanDelegation, :start, [session_uri, instruction, sender_uri])
    end)
  end

  defp parse_uri(value, expected) do
    case Ezagent.URI.new!(value) do
      %URI{} = uri ->
        if Ezagent.URI.scheme?(uri, expected), do: {:ok, uri}, else: :error
    end
  rescue
    ArgumentError -> :error
  end
end
