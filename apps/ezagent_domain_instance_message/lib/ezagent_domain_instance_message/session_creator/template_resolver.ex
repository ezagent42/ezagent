defmodule EzagentDomainInstanceMessage.SessionCreator.TemplateResolver do
  @moduledoc false

  alias Ezagent.Entity.Session
  alias Ezagent.KindRegistry

  @spec resolve_template_class(map()) :: {:ok, module()} | {:error, term()}
  def resolve_template_class(content) when is_map(content) do
    case content_get(content, :flavor) do
      flavor when is_binary(flavor) and flavor != "" ->
        case Ezagent.AgentFlavorRegistry.lookup(flavor) do
          {:ok, %{template_class: tc}} -> {:ok, tc}
          :error -> {:error, {:unknown_flavor, flavor}}
        end

      _ ->
        {:error, :missing_flavor}
    end
  end

  @spec resolve_agent_template_class(URI.t()) :: {:ok, module()} | {:error, term()}
  def resolve_agent_template_class(%URI{} = agent_uri) do
    case Ezagent.UriQuery.resolve(:flavor, agent_uri) do
      {:ok, flavor} when is_binary(flavor) and flavor != "" ->
        case Ezagent.AgentFlavorRegistry.lookup(flavor) do
          {:ok, %{template_class: tc}} -> {:ok, tc}
          :error -> {:error, :unknown_flavor}
        end

      :none ->
        {:error, :unknown_flavor}

      {:ok, _other} ->
        {:error, :bad_agent_flavor}

      {:error, reason} ->
        {:error, {:flavor_lookup_failed, reason}}
    end
  end

  def resolve_agent_template_class(_), do: {:error, :bad_agent_uri}

  @spec require_template_name!(keyword()) :: String.t()
  def require_template_name!(opts) do
    case Keyword.fetch(opts, :template_name) do
      {:ok, name} when is_binary(name) and name != "" ->
        name

      {:ok, other} ->
        raise ArgumentError,
              "EzagentDomainInstanceMessage.SessionCreator.create_session/3 requires opts[:template_name] to be " <>
                "a non-empty String, got: #{inspect(other)}. Per SPEC #366 the silent " <>
                "`\"default\"` fallback was removed; pick a class explicitly from the " <>
                "workspace's `session_templates` map (or use `\"default\"` literally " <>
                "for the bootstrap session-naming convention)."

      :error ->
        raise ArgumentError,
              "EzagentDomainInstanceMessage.SessionCreator.create_session/3 requires opts[:template_name] " <>
                "(SPEC #366, Allen 2026-05-26). The previous silent `\"default\"` " <>
                "fallback was removed. Callers — LV forms, CLI tasks, test seeds, " <>
                "bootstrap — must choose a template class explicitly. Examples:\n" <>
                "  * Bootstrap / preserve existing URI shape: `template_name: \"default\"`\n" <>
                "  * Tenant flows: `template_name: <key from workspace.session_templates>`\n" <>
                "Got: opts=#{inspect(opts)}."
    end
  end

  @spec resolve_for_repair(URI.t(), String.t(), URI.t()) ::
          {:ok, URI.t(), map()} | {:error, term()}
  def resolve_for_repair(%URI{} = session_uri, template_name, %URI{} = workspace_uri) do
    wc = Session.read_template_working_copy(session_uri)

    case Map.get(wc, :session_template_uri) do
      %URI{} = recorded ->
        with {:ok, _pid} <- Session.ensure_template_alive(recorded),
             {:ok, content} <- Session.read_template_content(recorded) do
          {:ok, recorded, content}
        else
          _ -> resolve_session_template!(template_name, workspace_uri)
        end

      _ ->
        resolve_session_template!(template_name, workspace_uri)
    end
  end

  @spec resolve_session_template!(String.t(), URI.t()) :: {:ok, URI.t(), map()} | {:error, term()}
  def resolve_session_template!(template_name, %URI{} = workspace_uri)
      when is_binary(template_name) do
    workspace_name = workspace_name_of!(workspace_uri)

    case find_session_template_uri(template_name, workspace_name) do
      {:ok, %URI{} = session_template_uri} ->
        with {:ok, _pid} <- Session.ensure_template_alive(session_template_uri),
             {:ok, content} <- Session.read_template_content(session_template_uri) do
          {:ok, session_template_uri, content}
        else
          {:error, reason} ->
            {:error, {:session_template_not_readable, template_name, reason}}
        end

      :error when template_name == "default" ->
        ensure_and_resolve_default_session_template(template_name, workspace_uri, workspace_name)

      :error ->
        {:error, {:session_template_not_found, template_name, workspace_name}}
    end
  end

  @spec orchestrator_template_uri_of(map()) :: URI.t() | nil
  def orchestrator_template_uri_of(template_content) when is_map(template_content) do
    case Map.get(template_content, :orchestrator_template_uri) ||
           Map.get(template_content, "orchestrator_template_uri") do
      %URI{} = uri ->
        uri

      uri_str when is_binary(uri_str) and uri_str != "" ->
        Ezagent.URI.new!(uri_str)

      _ ->
        nil
    end
  end

  defp ensure_and_resolve_default_session_template(
         template_name,
         %URI{} = workspace_uri,
         workspace_name
       ) do
    case EzagentDomainInstanceMessage.Application.ensure_default_session_template(workspace_uri) do
      :ok ->
        case find_session_template_uri(template_name, workspace_name) do
          {:ok, %URI{} = session_template_uri} ->
            with {:ok, _pid} <- Session.ensure_template_alive(session_template_uri),
                 {:ok, content} <- Session.read_template_content(session_template_uri) do
              {:ok, session_template_uri, content}
            else
              {:error, reason} ->
                {:error, {:session_template_not_readable, template_name, reason}}
            end

          :error ->
            {:error, {:session_template_not_found, template_name, workspace_name}}
        end

      {:error, reason} ->
        {:error, {:session_template_seed_failed, template_name, workspace_name, reason}}
    end
  end

  defp find_session_template_uri(template_name, workspace_name) do
    prefix =
      workspace_name
      |> Ezagent.URI.template(:session, "#{template_name}@")
      |> URI.to_string()

    live =
      KindRegistry.list_all()
      |> Enum.find_value(false, fn {uri_str, _pid} ->
        if String.starts_with?(uri_str, prefix), do: {:ok, Ezagent.URI.new!(uri_str)}, else: false
      end)

    cond do
      live != false -> live
      true -> find_session_template_uri_in_snapshots(prefix)
    end
  end

  defp find_session_template_uri_in_snapshots(prefix) do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.find_value(:error, fn %{uri: uri_str} ->
      if is_binary(uri_str) and String.starts_with?(uri_str, prefix) do
        {:ok, Ezagent.URI.new!(uri_str)}
      else
        false
      end
    end)
  rescue
    _ -> :error
  end

  defp workspace_name_of!(%URI{scheme: "workspace"} = uri), do: Ezagent.URI.name!(uri)

  defp workspace_name_of!(other),
    do: raise(ArgumentError, "expected %URI{scheme: \"workspace\"}, got: #{inspect(other)}")

  defp content_get(content, key) when is_map(content) do
    Map.get(content, key) || Map.get(content, Atom.to_string(key))
  end
end
