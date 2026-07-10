defmodule Ezagent.ActionSet.HelloPublisher do
  @moduledoc """
  The hello PUBLISHER agent Behavior — wraps "publish as template" as a
  dispatchable action so the front-desk relay can route a publish request here.

  Native-flavor (no bridge adapter) — reachable via dispatch, not chat delivery
  (T2 I-1). On `:publish`, uses an LLM round-trip to extract or generate a
  template name from the user's instruction (auto-unique if not specified,
  auto-suffix on collision), then calls `save_template_as` to create the
  template and posts the result as the publisher agent itself (loop-guard-safe).
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
  Dispatchable publish entry. Lets the LLM decide the template name from the
  instruction: extracts a specified name, auto-generates a unique one otherwise,
  and appends a suffix on collision. Posts the result from the publisher agent.
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

  def handle_publish(_args, _ctx), do: {:ok, %{}, []}

  def handle_receive(_args, _ctx), do: {:ok, %{}, []}

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  # --- internals --------------------------------------------------------

  @name_prompt """
  You are a template-name assistant. Given a user's chat instruction, produce a
  short, descriptive, URL-safe template name (lowercase letters, digits, hyphens).
  Reply with ONLY the name, nothing else.

  Rules:
  - If the user EXPLICITLY named the template (e.g. \"名字为xxx\", \"叫xxx\",
    \"发布为xxx\", \"name xxx\", \"named xxx\"), use that name, sanitised.
  - If NO name was specified, generate a brief descriptive name reflecting what
    this session/page is about (e.g. \"company-site\", \"product-page\",
    \"team-portal\"). Do NOT use command words like \"publish\", \"发布\",
    \"share\", \"template\", or agent names like \"builder\", \"publisher\" as
    the name.
  - Keep it under 30 characters. One or two words at most.
  """

  defp resolve_template_name(session_uri, instruction) do
    # Ask the LLM for a name
    prompt = "#{@name_prompt}\n\nUser said: #{instruction}"
    candidate = llm_name(prompt)

    # If it collides, append a random suffix and retry once
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    candidate = sanitize_name(candidate)

    case Ezagent.Socialware.DefinitionRegistry.lookup(workspace_uri, candidate) do
      {:ok, _definition, _object} ->
        suffix = suffix()
        {:ok, "#{candidate}-#{suffix}"}

      :error ->
        {:ok, candidate}
    end
  end

  defp llm_name(prompt) do
    case EzagentPluginHello.LLM.ClaudeCode.chat(prompt, "extract name") do
      {:ok, %{content: content}} when is_binary(content) ->
        String.trim(content)

      _ ->
        # Fallback: generate a timestamp-based name
        ts = DateTime.utc_now() |> Calendar.strftime("%m%d-%H%M")
        "site-#{ts}"
    end
  end

  defp sanitize_name(raw) do
    raw
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\-_]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "template"
      s -> String.slice(s, 0, 30)
    end
  end

  defp suffix, do: :erlang.unique_integer([:positive]) |> Integer.to_string(16)

  # Extract a human-readable name from the template URI, e.g.
  # template://system/session/hello-main@hash → "hello-main".
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
