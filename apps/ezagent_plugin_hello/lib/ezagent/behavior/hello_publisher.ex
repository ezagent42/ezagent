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
  (e.g. user says \"name it zzz\"), uses that name + timestamp. Always unique.
  Posts the result from the publisher agent itself.
  """
  def handle_publish(%{session_uri: session_str} = args, ctx)
      when is_binary(session_str) and session_str != "" do
    _ = publish_from_session(args, ctx)
    {:ok, %{}, []}
  end

  @doc false
  def handle_publish(_args, _ctx), do: {:ok, %{}, []}

  @doc false
  def publish_from_session(%{session_uri: session_str} = args, ctx)
      when is_binary(session_str) and session_str != "" do
    case parse_session_uri(session_str) do
      {:ok, session_uri} ->
        caller_uri = Ezagent.Entity.User.admin_uri()
        caps = Map.get(ctx, :caps, MapSet.new())
        instruction = Map.get(args, :instruction, "")

        result =
          with {:ok, name} <- resolve_template_name(session_uri, instruction),
               {:ok, %URI{} = tmpl_uri} <-
                 Ezagent.Orchestrator.Tools.Templates.save_template_as(name,
                   workspace_uri: Ezagent.Capability.workspace_of(session_uri),
                   caller: caller_uri,
                   caps: caps
                 ) do
            {:ok, "Template \"#{template_display_name(tmpl_uri)}\" published."}
          end

        case result_actor(session_uri) do
          {:ok, publisher_uri} ->
            case result do
              {:ok, text} ->
                _ = EzagentPluginHello.TurnDriver.say(session_uri, publisher_uri, text)

              {:error, reason} ->
                # G5 source 2 — structured error, no hand-written prose.
                _ =
                  EzagentPluginHello.TurnDriver.say_error(
                    session_uri,
                    publisher_uri,
                    {:template_save_failed, reason}
                  )
            end

          :error ->
            :ok
        end

      :error ->
        :ok
    end
  end

  @doc false
  def publish_from_session(_args, _ctx), do: :ok

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
    case extract_explicit_name(session_uri, instruction) do
      {:ok, name} -> name
      :none -> session_base_name(session_uri)
    end
  end

  @name_prompt """
  Extract only the template name from this chat message.
  - If the user explicitly named it (e.g. \"name xxx\", \"named xxx\",
    \"call it xxx\", \"save as yyy\", etc.), return ONLY the name.
  - If NO name was specified, return \"auto\".
  - Return ONLY the name or \"auto\". No punctuation, no extra text.
  """

  defp extract_explicit_name(session_uri, instruction)
       when is_binary(instruction) and instruction != "" do
    case EzagentPluginHello.Generator.complete(session_uri, @name_prompt, instruction) do
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

  defp extract_explicit_name(_session_uri, _), do: :none

  # Session URIs are `session://<ws>/hello/<name>` (template/type axis is
  # "hello"). Read the name segment through the Ezagent.URI accessors rather
  # than pattern-matching %URI{path:} (unify-uri-query: URI is opaque).
  defp session_base_name(%URI{} = uri) do
    with {:ok, "hello"} <- Ezagent.URI.type(uri),
         {:ok, name} <- Ezagent.URI.name(uri) do
      name |> String.replace(~r/[^a-zA-Z0-9\-_]/, "-")
    else
      _ -> "site"
    end
  end

  defp session_base_name(_), do: "site"

  # Extract a human-readable name from the template URI. Session templates are
  # `template://<ws>/session/<name>` (type axis "session"); read the name
  # segment via Ezagent.URI accessors and strip the `@version` suffix.
  defp template_display_name(%URI{} = uri) do
    with {:ok, "session"} <- Ezagent.URI.type(uri),
         {:ok, name} <- Ezagent.URI.name(uri) do
      name |> String.split("@") |> List.first() || name
    else
      _ -> URI.to_string(uri)
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

  defp result_actor(session_uri) do
    case EzagentPluginHello.Members.role_uri(session_uri, "front-desk") do
      {:ok, uri} -> {:ok, uri}
      :error -> EzagentPluginHello.Members.role_uri(session_uri, "publisher")
    end
  end
end
