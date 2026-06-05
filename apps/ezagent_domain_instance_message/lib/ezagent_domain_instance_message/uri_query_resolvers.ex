defmodule EzagentDomainInstanceMessage.UriQueryResolvers do
  @moduledoc """
  Domain-owned resolvers for `Ezagent.UriQuery`.

  `Ezagent.UriQuery` lives in core and cannot depend on domain storage. This
  module registers the instance-message attributes whose source of truth is the
  live/durable Kind state owned by this domain.
  """

  alias Ezagent.Behavior.Chat

  @doc "Register the instance-message UriQuery resolvers."
  @spec register() :: :ok | {:error, term()}
  def register do
    with :ok <- Ezagent.UriQuery.register(:flavor, &__MODULE__.resolve_flavor/1),
         :ok <- Ezagent.UriQuery.register(:orchestrator, &__MODULE__.resolve_orchestrator/1),
         :ok <- Ezagent.UriQuery.register(:member_by_role, &__MODULE__.resolve_member_by_role/1),
         :ok <-
           Ezagent.UriQuery.register(:session_template, &__MODULE__.resolve_session_template/1) do
      :ok
    end
  end

  @doc false
  @spec resolve_flavor(term()) :: Ezagent.UriQuery.result()
  def resolve_flavor(%URI{} = agent_uri) do
    case Ezagent.AgentFlavorAttributes.get(agent_uri) do
      {:ok, _flavor} = ok -> ok
      :none -> resolve_flavor_from_kind(agent_uri)
    end
  end

  def resolve_flavor(_), do: :none

  defp resolve_flavor_from_kind(%URI{} = agent_uri) do
    with {:ok, sandbox} <- kind_slice(agent_uri, :sandbox) do
      resolve_flavor_from_sandbox(sandbox)
    end
  end

  @doc false
  @spec resolve_orchestrator(term()) :: Ezagent.UriQuery.result()
  def resolve_orchestrator(%URI{scheme: "session"} = session_uri) do
    with {:ok, working_copy} <- template_working_copy(session_uri) do
      uri_result(Map.get(working_copy, :orchestrator_uri))
    end
  end

  def resolve_orchestrator(_), do: :none

  @doc false
  @spec resolve_member_by_role(term()) :: Ezagent.UriQuery.result()
  def resolve_member_by_role({%URI{scheme: "session"} = session_uri, role_name})
      when is_binary(role_name) do
    with {:ok, chat_slice} <- kind_slice(session_uri, :chat) do
      case Chat.role_name_to_uri(Map.get(chat_slice, :members, %{}), role_name) do
        %URI{} = member_uri -> {:ok, member_uri}
        nil -> :none
      end
    end
  end

  def resolve_member_by_role(_), do: :none

  @doc false
  @spec resolve_session_template(term()) :: Ezagent.UriQuery.result()
  def resolve_session_template(%URI{scheme: "session"} = session_uri) do
    with {:ok, working_copy} <- template_working_copy(session_uri) do
      uri_result(Map.get(working_copy, :session_template_uri))
    end
  end

  def resolve_session_template(_), do: :none

  defp template_working_copy(%URI{} = session_uri) do
    with {:ok, chat_slice} <- kind_slice(session_uri, :chat) do
      {:ok, Chat.template_working_copy(chat_slice)}
    end
  end

  defp kind_slice(%URI{} = uri, slice_key) when is_atom(slice_key) do
    case Ezagent.Kind.get_slice(uri, slice_key) do
      {:ok, slice} when is_map(slice) -> {:ok, slice}
      {:ok, _} -> :none
      {:error, :not_found} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp uri_result(%URI{} = uri), do: {:ok, uri}
  defp uri_result(_), do: :none

  @doc false
  @spec resolve_flavor_from_sandbox(term()) :: Ezagent.UriQuery.result()
  def resolve_flavor_from_sandbox(sandbox) when is_map(sandbox) do
    template_class = Map.get(sandbox, :template_class)
    respawn_template_data = Map.get(sandbox, :respawn_template_data)

    cond do
      is_map(respawn_template_data) ->
        flavor_from_respawn_data(respawn_template_data)

      is_atom(template_class) and template_class != nil ->
        flavor_from_template_class(template_class)

      true ->
        :none
    end
  end

  def resolve_flavor_from_sandbox(_), do: :none

  defp flavor_from_template_class(template_class) do
    case Enum.find(Ezagent.AgentFlavorRegistry.list_all(), fn
           {_flavor, %{template_class: registered}} -> registered == template_class
           _ -> false
         end) do
      {flavor, _decl} -> {:ok, flavor}
      nil -> :none
    end
  end

  defp flavor_from_respawn_data(data) when is_map(data) do
    case Map.get(data, :flavor) || Map.get(data, "flavor") do
      flavor when is_binary(flavor) and flavor != "" ->
        {:ok, flavor}

      _ ->
        data
        |> class_name_from_respawn_data()
        |> flavor_from_class_name()
    end
  end

  defp flavor_from_class_name(nil), do: :none

  defp flavor_from_class_name(class_name) when is_binary(class_name) do
    case Enum.find(Ezagent.AgentFlavorRegistry.list_all(), fn
           {_flavor, %{template_class: template_class}} ->
             template_name(template_class) == class_name

           _ ->
             false
         end) do
      {flavor, _decl} -> {:ok, flavor}
      nil -> :none
    end
  end

  defp class_name_from_respawn_data(data) when is_map(data) do
    Map.get(data, :class) || Map.get(data, "class")
  end

  defp template_name(template_class) when is_atom(template_class) do
    template_class.template_name()
  rescue
    _ -> nil
  end
end
