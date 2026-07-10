defmodule Ezagent.ActionSet.HelloPublisher do
  @moduledoc """
  The hello PUBLISHER agent Behavior — wraps "publish as template" as a
  dispatchable action so the front-desk relay can route a publish request here.

  Native-flavor (no bridge adapter) — reachable via dispatch, not chat delivery
  (T2 I-1). On `:publish`, snapshots the session's current state as a new
  immutable template version, equivalent to clicking "Publish as Template" in
  the world UI.
  """

  use Ezagent.Lifecycle

  action(:publish,
    args: %{session_uri: :string},
    returns: %{},
    caps: [:publish],
    modes: [:cast],
    description: "Publish the session state as a new immutable template version"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  Dispatchable publish entry. Calls `update_template` to snapshot the session's
  working-copy state as a new version of its parent SessionTemplate.
  """
  def handle_publish(%{session_uri: session_str}, _ctx)
      when is_binary(session_str) and session_str != "" do
    case parse_session_uri(session_str) do
      {:ok, session_uri} ->
        case Ezagent.Orchestrator.Tools.Templates.update_template(session_uri: session_uri) do
          {:ok, %{template_uri: tmpl_uri}} ->
            _ =
              EzagentPluginHello.TurnDriver.say(
                session_uri,
                Ezagent.Entity.User.admin_uri(),
                "Template published: #{URI.to_string(tmpl_uri)}"
              )

          {:error, reason} ->
            _ =
              EzagentPluginHello.TurnDriver.say(
                session_uri,
                Ezagent.Entity.User.admin_uri(),
                "Publish failed: #{inspect(reason)}"
              )
        end

      :error ->
        :ok
    end

    {:ok, %{}, []}
  end

  def handle_publish(_args, _ctx), do: {:ok, %{}, []}

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
end
