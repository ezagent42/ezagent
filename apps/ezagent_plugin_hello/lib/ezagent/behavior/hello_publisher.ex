defmodule Ezagent.ActionSet.HelloPublisher do
  @moduledoc """
  The hello PUBLISHER agent Behavior — wraps "publish as template" as a
  dispatchable action so the front-desk relay can route a publish request here.

  Native-flavor (no bridge adapter) — reachable via dispatch, not chat delivery
  (T2 I-1). On `:publish`, snapshots the session's current state as a new
  immutable template version and posts the result as a chat message from ITS OWN
  URI (so the front-desk loop guard excludes it).
  """

  use Ezagent.Lifecycle

  action(:publish,
    args: %{session_uri: :string, instruction: :string},
    returns: %{},
    caps: [:publish],
    modes: [:cast],
    description: "Publish the session state as a new immutable template version"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{}}

  @doc """
  Dispatchable publish entry. If the user specified a template name
  (\"名字为XXX\" / \"name XXX\"), calls `save_template_as` to create a new
  template family; otherwise calls `update_template` to publish as a new
  version of the parent template. Posts the result from the publisher agent.
  """
  def handle_publish(%{session_uri: session_str} = args, _ctx)
      when is_binary(session_str) and session_str != "" do
    case parse_session_uri(session_str) do
      {:ok, session_uri} ->
        workspace_uri = Ezagent.Capability.workspace_of(session_uri)
        caller_uri = Ezagent.Entity.User.admin_uri()
        caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

        # If the user specified a custom template name, create a NEW family.
        result =
          case extract_template_name(args) do
            {:ok, new_name} ->
              Ezagent.Orchestrator.Tools.Templates.save_template_as(new_name,
                session_uri: session_uri,
                workspace_uri: workspace_uri,
                caller: caller_uri,
                caps: caps
              )

            :use_parent ->
              with {:ok, parent_uri} <- read_parent_template_uri(session_uri) do
                Ezagent.Orchestrator.Tools.Templates.update_template(
                  session_uri: session_uri,
                  workspace_uri: workspace_uri,
                  caller: caller_uri,
                  caps: caps,
                  parent_template_uri: parent_uri
                )
              end
          end
          |> case do
            {:ok, %URI{} = tmpl_uri} ->
              name = template_display_name(tmpl_uri)
              "Template \"#{name}\" published."

            {:error, reason} ->
              "Template save failed: #{inspect(reason)}"

            other ->
              "Template save unexpected result: #{inspect(other)}"
          end

        case EzagentPluginHello.Members.role_uri(session_uri, "publisher") do
          {:ok, publisher_uri} ->
            _ = EzagentPluginHello.TurnDriver.say(session_uri, publisher_uri, result)

          :error ->
            :ok
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

  # Parse the user's instruction for a custom template name.
  # Supports: "名字为XXX", "name XXX", "叫XXX", "named XXX", "命名为XXX".
  # Returns {:ok, name} or :use_parent (fall through to update_template).
  defp extract_template_name(%{instruction: instruction})
       when is_binary(instruction) and instruction != "" do
    patterns = [
      ~r/名字为\s*[：:]*\s*(\S+)/u,
      ~r/name\s+(\S+)/i,
      ~r/叫\s*[：:]*\s*(\S+)/u,
      ~r/named\s+(\S+)/i,
      ~r/命名为\s*[：:]*\s*(\S+)/u
    ]

    Enum.find_value(patterns, :use_parent, fn re ->
      case Regex.run(re, instruction) do
        [_, name] -> {:ok, String.trim(name)}
        nil -> nil
      end
    end)
  end

  defp extract_template_name(_args), do: :use_parent

  # Extract a human-readable name from the template URI, e.g.
  # template://system/session/hello-main@hash → "hello-main".
  defp template_display_name(%URI{path: "/session/" <> rest}) do
    rest |> String.split("@") |> List.first() || rest
  end

  defp template_display_name(%URI{} = uri), do: URI.to_string(uri)

  # Read the session's parent template URI from its working copy.
  defp read_parent_template_uri(%URI{} = session_uri) do
    wc = Ezagent.Entity.Session.read_template_working_copy(session_uri)

    case Map.get(wc || %{}, :session_template_uri) || Map.get(wc || %{}, "session_template_uri") do
      %URI{} = uri -> {:ok, uri}
      nil -> {:error, :no_template_bound}
    end
  end

  defp parse_session_uri(session_str) do
    case Ezagent.URI.new!(session_str) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
