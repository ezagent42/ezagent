defmodule EzagentPluginAdvisor.Template.AdvisorSession do
  @moduledoc """
  `session.advisor` Template Class.

  This template materializes a domain-owned SocialwareSession and annotates
  its chat working copy with advisor vertical metadata. It deliberately avoids
  spawning real sidecar agents in isolated tests; live agent-browser validation
  is author-owned after merge per the P5 handoff.
  """

  @behaviour Ezagent.Kind.Template

  alias Ezagent.{Invocation, KindRegistry, WorkspaceRegistry}
  alias Ezagent.Entity.{SocialwareSession, User}
  alias EzagentPluginAdvisor.NodeTypes

  @impl Ezagent.Kind.Template
  def template_name, do: "session.advisor"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_session_name(tmpl),
         :ok <- check_operator_uri(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  @impl Ezagent.Kind.Template
  def instantiate(
        _tmpl_name,
        %{"session_name" => session_name, "operator_uri" => _operator_uri} = tmpl,
        %URI{} = workspace_uri
      ) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    session_uri = Ezagent.URI.session(workspace_name, :advisor, session_name)
    operator_uri = operator_uri!(tmpl)

    case ensure_session(session_uri) do
      {:ok, fresh?} ->
        with :ok <- WorkspaceRegistry.bind(session_uri, workspace_uri),
             {:ok, _} <-
               Ezagent.Behavior.Chat.system_set_working_copy(session_uri, working_copy(tmpl)),
             :ok <- ensure_operator_user(operator_uri),
             {:ok, _} <- join_operator(session_uri, operator_uri) do
          {:ok, [session_uri], %{fresh?: fresh?, vertical: :advisor}}
        else
          {:error, _reason} = error ->
            cleanup_if_fresh(session_uri, fresh?)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  defp check_class(%{"class" => "session.advisor"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_session_name(%{"session_name" => name}) when is_binary(name) and name != "",
    do: :ok

  defp check_session_name(_), do: {:error, :missing_session_name}

  defp check_operator_uri(%{"operator_uri" => uri}) when is_binary(uri) and uri != "" do
    case parse_user_uri(uri) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp check_operator_uri(%{"operator_uri" => _}), do: {:error, :bad_operator_uri}
  defp check_operator_uri(_), do: {:error, :missing_operator_uri}

  defp parse_user_uri(uri_str) do
    uri = Ezagent.URI.new!(uri_str)

    if uri.scheme == "entity" and Ezagent.URI.type?(uri, :user) do
      {:ok, uri}
    else
      {:error, {:invalid_operator_uri, uri_str}}
    end
  rescue
    ArgumentError -> {:error, :bad_operator_uri}
  end

  defp operator_uri!(%{"operator_uri" => uri_str}) do
    {:ok, uri} = parse_user_uri(uri_str)
    uri
  end

  defp ensure_session(session_uri) do
    case Ezagent.Kind.spawn(SocialwareSession, %{uri: session_uri}) do
      {:ok, _pid} -> {:ok, true}
      {:error, {:already_started, _pid}} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp working_copy(tmpl) do
    operator_uri_str = tmpl |> operator_uri!() |> URI.to_string()

    %{
      "class" => template_name(),
      "vertical" => "advisor",
      "session_name" => Map.fetch!(tmpl, "session_name"),
      "operator_uri" => operator_uri_str,
      "roles" => NodeTypes.default_roles(),
      "node_types" => NodeTypes.node_types(),
      "sample_tree" => NodeTypes.sample_tree()
    }
  end

  defp ensure_operator_user(%URI{} = operator_uri) do
    case KindRegistry.lookup(operator_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.Kind.spawn(User, %{
               uri: operator_uri,
               initial_caps: User.initial_caps_for_spawn(operator_uri)
             }) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp join_operator(session_uri, operator_uri) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=chat.join"),
      mode: :call,
      args: %{member: operator_uri, role_name: "operator", in_session_template: true},
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("template-materialize"),
        caps:
          "template-materialize"
          |> Ezagent.SystemPrincipal.uri()
          |> Ezagent.SystemPrincipal.caps(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp cleanup_if_fresh(_session_uri, false), do: :ok

  defp cleanup_if_fresh(session_uri, true) do
    _ = Ezagent.Kind.terminate(session_uri)
    :ok
  end
end
