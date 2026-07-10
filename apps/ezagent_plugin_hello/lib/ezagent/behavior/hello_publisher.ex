defmodule Ezagent.ActionSet.HelloPublisher do
  @moduledoc """
  The hello PUBLISHER agent Behavior — wraps "publish as template" as a
  dispatchable action so the front-desk relay can route a publish request here.

  Native-flavor (no bridge adapter) — reachable via dispatch, not chat delivery
  (T2 I-1). On `:publish`, derives a unique template name from the session name
  + timestamp (or user-specified name + timestamp), calls `save_template_as`,
  and posts the result as the publisher agent itself (loop-guard-safe).
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
  @doc false
  def create(_args), do: {:ok, %{}}

  @doc """
  Dispatchable publish entry. Derives a template name from the session name +
  timestamp by default; if the instruction carries an explicit name
  (e.g. \"发布为zzz\"), uses that name + timestamp instead. Always unique.
  Posts the result from the publisher agent itself.
  """
  def handle_publish(%{session_uri: session_str} = args, _ctx)
      when is_binary(session_str) and session_str != "" do
    case parse_session_uri(session_str) do
      {:ok, session_uri} ->
        caller_uri = Ezagent.Entity.User.admin_uri()
        caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])
        instruction = Map.get(args, :instruction, "")

        result =
          with {:ok, name} <- resolve_template_name(session_uri, instruction),
               {:ok, %URI{} = tmpl_uri} <-
                 Ezagent.Orchestrator.Tools.Templates.save_template_as(name,
                   session_uri: session_uri,
                   workspace_uri: Ezagent.Capability.workspace_of(session_uri),
                   caller: caller_uri,
                   caps: caps
                 ) do
            "Template \"#{template_display_name(tmpl_uri)}\" published."
          else
            {:error, reason} -> "Template save failed: #{inspect(reason)}"
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

  @doc false
  def handle_publish(_args, _ctx), do: {:ok, %{}, []}

  @doc false
  def handle_receive(_args, _ctx), do: {:ok, %{}, []}

  @doc false
  def data_owner(:any), do: :any

  @doc false
  def data_owner(_), do: :no_owner

  # --- internals --------------------------------------------------------

  # Derive a unique template name: <base>-<MMDD>-<HHMM>.
  # Base = user-specified name if present, otherwise the session name.
  # E.g. "hello-main-0709-201015" or "zzzmn-0709-211530".
  defp resolve_template_name(session_uri, instruction) do
    base = extract_base_name(session_uri, instruction)
    ts = DateTime.utc_now() |> Calendar.strftime("%m%d-%H%M%S")
    {:ok, "#{base}-#{ts}"}
  end

  defp extract_base_name(session_uri, instruction) do
    case extract_explicit_name(instruction) do
      {:ok, name} -> name
      :none -> session_base_name(session_uri)
    end
  end

  @name_prompt """
  Extract only the template name from this chat message.
  - If the user explicitly named it (e.g. \"发布为xxx\", \"叫xxx\", \"name xxx\",
    \"发布，名字是xxx\", \"存为yyy\", etc.), return ONLY the name.
  - If NO name was specified, return \"auto\".
  - Return ONLY the name or \"auto\". No punctuation, no extra text.
  """

  defp extract_explicit_name(instruction) when is_binary(instruction) and instruction != "" do
    case EzagentPluginHello.LLM.ClaudeCode.chat(@name_prompt, instruction) do
      {:ok, %{content: content}} when is_binary(content) ->
        name =
          content
          |> String.trim()
          |> String.replace(~r/[^a-zA-Z0-9\-_]/, "-")
          |> String.slice(0, 30)

        if name in ["", "auto"] do
          :none
        else
          {:ok, name}
        end

      _ ->
        :none
    end
  end

  defp extract_explicit_name(_), do: :none

  defp session_base_name(%URI{path: "/hello/" <> name}) do
    name |> String.replace(~r/[^a-zA-Z0-9\-_]/, "-")
  end

  defp session_base_name(_), do: "site"

  # Extract a human-readable name from the template URI.
  defp template_display_name(%URI{path: "/session/" <> rest}) do
    rest |> String.split("@") |> List.first() || rest
  end

  defp template_display_name(%URI{} = uri), do: URI.to_string(uri)

  defp parse_session_uri(session_str) do
    case Ezagent.URI.new!(session_str) do
      %URI{scheme: "session"} = uri -> {:ok, uri}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
