defmodule Ezagent.Socialware.SessionInstaller do
  @moduledoc false

  alias Ezagent.Entity.Session
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.{DefinitionAgents, Materializer, TemplateTeam}

  @doc false
  @spec install(URI.t(), URI.t(), map(), URI.t() | nil, keyword()) ::
          {:ok, DefinitionAgents.summary()} | {:error, term()}
  def install(
        %URI{scheme: "session"} = session_uri,
        %URI{} = workspace_uri,
        working_copy,
        actor_uri,
        opts \\ []
      )
      when is_map(working_copy) and is_list(opts) do
    case Session.owner(session_uri) do
      {:ok, %URI{} = owner} ->
        agents =
          working_copy
          |> Map.get(:member_declarations, [])
          |> TemplateTeam.agent_role_slots()

        composition? =
          Enum.any?(agents, fn role ->
            match?([_ | _], Map.get(role, :operates) || Map.get(role, "operates"))
          end)

        owner_authorized? =
          match?(%URI{}, actor_uri) and same_uri?(actor_uri, owner)

        authorization =
          if composition? and not owner_authorized?,
            do: {:error, {:composition_install_not_owner_authorized, session_uri}},
            else: :ok

        with :ok <- authorization do
          case DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 workspace_uri,
                 owner,
                 agents,
                 install_authorized?: owner_authorized?
               ) do
            {:ok, summary} ->
              converge_view_caps =
                Keyword.get(
                  opts,
                  :view_cap_converger,
                  &Ezagent.Socialware.ViewCapConvergence.converge/2
                )

              with :ok <- SessionCreator.record_unfilled_role_slots(session_uri, summary.skipped),
                   :ok <- converge_view_caps.(session_uri, []) do
                {:ok, summary}
              end

            {:error, reason, partial} = error ->
              _ =
                SessionCreator.record_unfilled_role_slots(
                  session_uri,
                  Map.get(partial, :skipped, [])
                )

              _ = Materializer.tombstone_orchestrator_binding(session_uri, reason)
              error

            {:error, reason} = error ->
              _ = Materializer.tombstone_orchestrator_binding(session_uri, reason)
              error
          end
        end

      _ ->
        {:error, {:no_session_owner, session_uri}}
    end
  end

  defp same_uri?(left, right),
    do:
      Ezagent.URI.stable_key(Ezagent.URI.instance(left)) ==
        Ezagent.URI.stable_key(Ezagent.URI.instance(right))
end
