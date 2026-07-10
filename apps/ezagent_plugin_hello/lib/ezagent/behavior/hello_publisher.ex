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
  Extract the template name from this chat message. Rules:
  - If the message contains \"发布为XXX\", \"名字为XXX\", \"name XXX\",
    \"叫XXX\", \"named XXX\", or \"命名为XXX\" — return ONLY the XXX value.
  - If the message is \"@publisher 发布\" with NO name — return \"auto\".
  - Ignore @mentions and agent names. They are NOT template names.
  - Return ONLY the name. One word, lowercase, 2-30 chars, URL-safe
    (letters/digits/hyphens). No spaces, no punctuation.
  """

  defp resolve_template_name(session_uri, instruction) do
    # Ask the LLM for a name
    prompt = "#{@name_prompt}\n\nMessage: #{instruction}"
    candidate = llm_name(prompt) |> sanitize_name()

    # LLM returns "auto" when no explicit name — generate one
    candidate = if candidate == "auto", do: auto_name(), else: candidate

    # Check for collision with existing template names
    case template_name_exists?(candidate) do
      true -> {:ok, "#{candidate}-#{suffix()}"}
      false -> {:ok, candidate}
    end
  end

  defp auto_name do
    ts = DateTime.utc_now() |> Calendar.strftime("%m%d-%H%M")
    "site-#{ts}"
  end

  defp template_name_exists?(name) do
    uri = "template://system/session/#{name}@"

    {:ok, rows} =
      EzagentCore.Repo.query(
        "SELECT 1 FROM kind_snapshots WHERE uri LIKE $1 LIMIT 1",
        [uri <> "%"]
      )

    rows.num_rows > 0
  rescue
    _ -> false
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
