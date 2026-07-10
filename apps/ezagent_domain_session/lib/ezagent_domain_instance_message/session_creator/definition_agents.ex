defmodule EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents do
  @moduledoc """
  Materialize a socialware `Definition`'s agent role slots into a live session
  as spawned members.

  Agent role slots declare "this socialware needs an agent with this role";
  materialization turns each into a live,
  session/workspace-scoped agent that is JOINED as a session member with its
  `role_name` facet (so `{:role, name}` routing rules resolve to it) and holds
  its recipe's `requested_caps`.

  Per agent, the pipeline REUSES the existing safe managed-member envelope shape
  (`Ezagent.Orchestrator.Tools.add_managed_member`: preflight → spawn → faceted
  `session.join` → cleanup-on-join-failure) so a join failure never leaves an
  orphan worker:

    1. **role_name uniqueness FIRST** — reject duplicate role names in the same
       role batch. An existing live member with that role means idempotent
       re-materialize/repair has already bound the role, so skip.
    2. **resolve recipe by workspace** — `RecipeRegistry.lookup(workspace, name)`,
       fail-closed on `:error` (never a cap-less spawn; #1116).
    3. **spawn** — recipe × declared flavor (default `cc`) →
       `Agent.spawn_from_template_content` at a fresh uuid agent URI.
    4. **join + cleanup** — faceted `session.join` carrying `%{role_name: name}`;
       on join `{:error, _}` terminate the worker we just spawned.
    5. **grant caps LAST** — `GrantRecipeCaps.grant_recipe_caps` grants the
       recipe's `requested_caps` (fail-closed, no partial). Runs after a
       successful join so join-failure cleanup only has to terminate.

  Authority is SYSTEM-MEDIATED materialization (mirrors
  `Materializer.join_session_members`):
  the spawn runs under the session owner (`granted_by`) with
  `list_caps_for_materialization/1`, and the join/cleanup dispatch under the
  genesis admin entity with an inline least-priv cap.

  > **Rebase note (T1, reconciled):** T1's structured `recipe:<name>` subject has
  > landed. Role `recipe` accepts EITHER a plain recipe name (`guide`) or the
  > structured subject (`recipe:guide`); `lookup_ref/1` strips a single leading
  > `recipe:` prefix so both resolve identically through `RecipeRegistry.lookup/2`
  > (which itself takes a plain name and re-derives the subject).
  """

  require Logger

  alias Ezagent.Agent.CredentialPrecondition
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Entity.Session.Orchestrator, as: SessionOrchestrator
  alias Ezagent.Invocation
  alias Ezagent.Orchestrator.Tools.Participants
  alias EzagentDomainInstanceMessage.SessionCreator
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @telemetry_prefix [:ezagent, :socialware, :definition_agents]
  @agent_description "socialware-declared agent materialized per-session (Definition.roles)"

  @doc """
  Materialize agent role slots into `session_uri`. `granted_by` is the session owner
  (the #154-clean grant/spawn root). Idempotent on the repair/restart path.

  Returns `{:ok, summary}` where `summary` is
  `%{installed: [role_name], skipped: [%{role_name:, reason:}]}`.

  ## Skip vs fail (chain C, Allen 2026-07-10)

  A role slot whose flavor **cannot be given credentials for this installer** is
  SKIPPED, not fatal: it is logged, emitted as telemetry, recorded on the
  session, and the rest of the batch continues. Creating it anyway produces an
  agent that boots "Not logged in", never joins its transport bridge, and hangs
  at `:not_ready` forever — a silent zombie member (see
  `Ezagent.Agent.CredentialPrecondition`).

  Every OTHER failure still halts the batch (`{:error, reason}`): a duplicate
  role name, an unknown recipe, a failed join. Those are bugs, not environment,
  and must not be swallowed as "skipped".
  """
  @type summary :: %{
          installed: [String.t()],
          skipped: [%{role_name: String.t(), reason: term()}]
        }

  @spec materialize_definition_agents(URI.t(), URI.t(), URI.t(), [map()]) ::
          {:ok, summary()} | {:error, term()}
  def materialize_definition_agents(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        agents
      )
      when is_list(agents) do
    agents
    |> Enum.reduce_while({:ok, MapSet.new(), [], []}, fn agent,
                                                         {:ok, batch_seen, installed, skipped} ->
      role_name = role_name_of(agent)

      cond do
        not valid_agent?(agent) ->
          {:halt, {:error, {:invalid_socialware_agent, agent}}}

        MapSet.member?(batch_seen, role_name) ->
          {:halt, {:error, {:duplicate_agent_role_name, role_name}}}

        true ->
          seen = MapSet.put(batch_seen, role_name)

          case materialize_one(session_uri, workspace_uri, granted_by, agent) do
            :ok ->
              {:cont, {:ok, seen, [role_name | installed], skipped}}

            {:skip, reason} ->
              report_skip(session_uri, role_name, reason)
              {:cont, {:ok, seen, installed, [%{role_name: role_name, reason: reason} | skipped]}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, _seen, installed, skipped} ->
        {:ok, %{installed: Enum.reverse(installed), skipped: Enum.reverse(skipped)}}

      {:error, _} = err ->
        err
    end
  end

  def materialize_definition_agents(_session, _ws, _granted_by, _agents),
    do: {:ok, %{installed: [], skipped: []}}

  # LOUD, but not fatal. The durable, user-facing record is written by
  # `SessionCreator.install_session_socialware/1` from the returned summary — a
  # server log alone would be a silent drop at a user-facing surface (#9).
  defp report_skip(session_uri, role_name, reason) do
    Logger.error(
      "socialware role slot #{inspect(role_name)} SKIPPED on " <>
        "#{URI.to_string(session_uri)}: #{inspect(reason)} — the agent would boot " <>
        "without credentials, never join its transport bridge, and hang at :not_ready. " <>
        "The session is alive without this role."
    )

    :telemetry.execute(
      @telemetry_prefix ++ [:skipped],
      %{count: 1},
      %{session_uri: session_uri, role_name: role_name, reason: reason}
    )
  end

  defp materialize_one(session_uri, workspace_uri, granted_by, %{} = agent) do
    recipe_name = lookup_ref(recipe_of(agent))
    role_name = role_name_of(agent)

    case existing_member_for_role(session_uri, role_name) do
      %URI{} = existing_uri ->
        # Idempotent re-materialize (repair/restart) — the role is already
        # joined. Do not re-spawn; do re-run post materialization hooks because
        # they are idempotent and may be absent on legacy sessions.
        maybe_after_materialize(session_uri, workspace_uri, granted_by, agent, existing_uri)

      nil ->
        with {:ok, agent_uri} <-
               (case install_mode_of(agent) do
                  :reuse ->
                    reuse_existing_agent(
                      session_uri,
                      workspace_uri,
                      granted_by,
                      agent,
                      recipe_name,
                      role_name
                    )

                  :fresh ->
                    materialize_fresh_agent(
                      session_uri,
                      workspace_uri,
                      granted_by,
                      agent,
                      recipe_name,
                      role_name
                    )
                end),
             :ok <-
               maybe_after_materialize(session_uri, workspace_uri, granted_by, agent, agent_uri) do
          :ok
        end
    end
  end

  defp materialize_fresh_agent(
         session_uri,
         workspace_uri,
         granted_by,
         agent,
         recipe_name,
         role_name
       ) do
    planned_uri = planned_agent_uri(workspace_uri)
    flavor = flavor_of(agent)

    with {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         # #1201 A② — installer host-login inheritance. BEFORE the spawn (whose
         # #17 cascade resolves the installer's user-default source), ensure the
         # INSTALLER's host login is adopted as that source. No-ops for
         # credential-less flavors (py/curl), for flavors/nodes without a host
         # login, and for non-host-operator installers; the spawn below then
         # inherits through the UNCHANGED cascade (no ad-hoc copy here).
         :ok <-
           Ezagent.Agent.HostLoginAdopt.ensure_installer_source(
             granted_by,
             workspace_uri,
             flavor
           ),
         # Chain C — the adopt above NO-OPS for a non-admin installer (#161 /
         # DoD 6). Without a credential source this agent can only boot "Not
         # logged in": skip the slot rather than join a silent zombie.
         :ok <- CredentialPrecondition.check_source(granted_by, workspace_uri, flavor),
         :ok <-
           spawn_agent(
             workspace_uri,
             granted_by,
             planned_uri,
             recipe,
             recipe_name,
             role_name,
             flavor
           ),
         # Safety net for the class the pre-flight cannot see: a source that
         # resolves but whose copy silently produced nothing (#1311). Verified
         # BEFORE the join, so a skipped agent never becomes a session member.
         :ok <- verify_credentials(planned_uri, flavor),
         :ok <- join_or_cleanup(session_uri, planned_uri, role_name),
         :ok <- grant_recipe_caps(planned_uri, recipe) do
      {:ok, planned_uri}
    end
  end

  # `{:skip, _}` from `check_materialized/2` tears the just-spawned worker down
  # first — it was never joined, so termination is the whole cleanup.
  defp verify_credentials(%URI{} = agent_uri, flavor) do
    case CredentialPrecondition.check_materialized(agent_uri, flavor) do
      :ok ->
        :ok

      {:skip, _reason} = skip ->
        _ = terminate_worker(agent_uri)
        skip
    end
  end

  defp reuse_existing_agent(session_uri, workspace_uri, operator, agent, recipe_name, role_name) do
    with %URI{} = agent_uri <- reuse_agent_uri_of(agent),
         :ok <- ensure_reuse_recipe_match(agent_uri, recipe_name, role_name),
         {:ok, ^agent_uri} <-
           Participants.add_participant(agent_uri, role_name,
             caller: operator,
             caps: reuse_caps(session_uri, operator),
             workspace_uri: workspace_uri,
             session_uri: session_uri,
             in_session_template: true
           ) do
      {:ok, agent_uri}
    else
      nil -> {:error, {:invalid_reuse_agent_uri, role_name}}
      {:error, _} = error -> error
      other -> {:error, {:reuse_agent_join_failed, role_name, other}}
    end
  end

  defp maybe_after_materialize(session_uri, workspace_uri, granted_by, agent, agent_uri) do
    if orchestrator_recipe_slot?(agent) do
      parent_template_uri = parent_template_uri_for(session_uri)

      with :ok <-
             SessionOrchestrator.grant_orchestrator_scoped_caps(
               agent_uri,
               session_uri,
               granted_by
             ),
           :ok <-
             SessionOrchestrator.register_orchestrator_mcp_context(
               agent_uri,
               session_uri,
               workspace_uri,
               granted_by,
               parent_template_uri
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp orchestrator_recipe_slot?(agent) do
    role_name_of(agent) == "orchestrator" and lookup_ref(recipe_of(agent)) == "orchestrator"
  end

  defp parent_template_uri_for(%URI{} = session_uri) do
    case SessionOrchestrator.read_template_working_copy(session_uri) do
      %{session_template_uri: %URI{} = uri} ->
        uri

      %{"session_template_uri" => %URI{} = uri} ->
        uri

      %{session_template_uri: uri} when is_binary(uri) and uri != "" ->
        Ezagent.URI.new!(uri)

      %{"session_template_uri" => uri} when is_binary(uri) and uri != "" ->
        Ezagent.URI.new!(uri)

      _ ->
        Ezagent.URI.template(:system, :session, "default")
    end
  rescue
    _ -> Ezagent.URI.template(:system, :session, "default")
  end

  defp ensure_reuse_recipe_match(%URI{} = agent_uri, recipe_name, role_name) do
    case agent_recipe(agent_uri) do
      {:ok, ^recipe_name} -> :ok
      _ -> {:error, {:reuse_agent_recipe_mismatch, role_name, agent_uri}}
    end
  end

  defp agent_recipe(%URI{} = agent_uri) do
    case Ezagent.Agent.RecipeAttributes.fetch(agent_uri) do
      {:ok, recipe} -> {:ok, recipe}
      :none -> Ezagent.UriQuery.resolve(:recipe, agent_uri)
    end
  rescue
    _ -> :none
  end

  defp reuse_caps(%URI{} = session_uri, %URI{} = operator) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    MapSet.new([
      %Ezagent.Capability{
        kind: :session,
        behavior: :any,
        action: :any,
        instance: {:within_session, session_uri},
        workspace_uri: workspace_uri,
        granted_by: operator,
        granted_at: DateTime.utc_now()
      }
    ])
  end

  # --- resolve --------------------------------------------------------------

  defp lookup_recipe(%URI{} = workspace_uri, recipe_name) do
    case RecipeRegistry.lookup(URI.to_string(workspace_uri), recipe_name) do
      {:ok, recipe} -> {:ok, recipe}
      :error -> {:error, {:unknown_agent_recipe, recipe_name}}
    end
  end

  # T1 rebase reconciliation: recipe subjects are the structured `recipe:<name>`
  # form (T1 project B). `RecipeRegistry.lookup/2` takes a PLAIN recipe name and
  # re-derives the `recipe:<name>` subject internally, and the same plain name is
  # reused as the AgentTemplate name — so normalize a single leading `recipe:`
  # prefix here so both a bare `guide` and a prefixed `recipe:guide` in role
  # slots resolve identically. Idempotent: strips at most one prefix.
  defp lookup_ref("recipe:" <> rest) when rest != "", do: rest
  defp lookup_ref(name), do: name

  # --- spawn + join ---------------------------------------------------------

  # Spawn ONLY. The join moved out so `verify_credentials/2` can run between the
  # two — a credential-less agent must never become a session member.
  defp spawn_agent(
         workspace_uri,
         granted_by,
         planned_uri,
         recipe,
         recipe_name,
         role_name,
         flavor
       ) do
    source_template_uri = Ezagent.URI.template(:system, :agent, recipe_name)

    case Ezagent.Agent.RecipeMaterializer.create_agent_from_recipe(%{
           recipe: recipe,
           recipe_name: recipe_name,
           role_name: role_name,
           flavor: flavor,
           agent_uri: planned_uri,
           workspace_uri: workspace_uri,
           owner_uri: granted_by,
           caller: granted_by,
           caps: SessionCreator.list_caps_for_materialization(granted_by),
           source_template_uri: source_template_uri,
           description: @agent_description
         }) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, {:agent_spawn_failed, role_name, reason}}
    end
  end

  # Faceted `session.join` carrying the `%{role_name: name}` facet. On failure,
  # terminate the worker we just spawned (the add_managed_member cleanup
  # envelope) so a denied/failed join never leaves an orphan.
  defp join_or_cleanup(session_uri, %URI{} = member_uri, role_name) do
    case join_member(session_uri, member_uri, role_name) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = terminate_worker(member_uri)
        {:error, {:agent_join_failed, role_name, reason}}
    end
  end

  defp join_member(%URI{} = session_uri, %URI{} = member_uri, role_name) do
    _ = SessionCreator.demand_spawn_member(member_uri)
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    admin = Ezagent.Entity.User.admin_uri()

    result =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{member: member_uri, role_name: role_name},
        ctx: %{
          caller: admin,
          caps: MapSet.new([join_cap(session_uri, admin)]),
          reply: {:caller_inbox, self()}
        }
      })

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_join_result, other}}
    end
  end

  defp terminate_worker(%URI{} = member_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(member_uri)}?action=sandbox.destroy")
    admin = Ezagent.Entity.User.admin_uri()

    _ =
      Invocation.dispatch(%Invocation{
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: admin,
          caps: MapSet.new([destroy_cap(member_uri, admin)]),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  # --- grant ----------------------------------------------------------------

  defp grant_recipe_caps(%URI{} = agent_uri, recipe) do
    case GrantRecipeCaps.grant_recipe_caps(agent_uri, recipe, @telemetry_prefix) do
      :ok -> :ok
      {:error, reason} -> {:error, {:agent_grant_recipe_caps_failed, reason}}
    end
  end

  # --- inline caps (system-mediated materialization) ------------------------

  defp join_cap(%URI{} = session_uri, %URI{} = admin) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :session,
        :any,
        :join,
        Ezagent.URI.instance(session_uri),
        Ezagent.Capability.workspace_of(session_uri)
      )
      | granted_by: admin,
        granted_at: DateTime.utc_now()
    }
  end

  defp destroy_cap(%URI{} = member_uri, %URI{} = admin) do
    %Ezagent.Capability{
      Ezagent.Capability.cap(
        :agent,
        :any,
        :destroy,
        Ezagent.URI.instance(member_uri),
        Ezagent.Capability.workspace_of(member_uri)
      )
      | granted_by: admin,
        granted_at: DateTime.utc_now()
    }
  end

  # --- helpers --------------------------------------------------------------

  @doc """
  Fresh per-session agent URI. Definition declarations intentionally carry only
  role data; the runtime chooses a UUID instance URI at materialization time.
  """
  @spec planned_agent_uri(URI.t()) :: URI.t()
  def planned_agent_uri(%URI{} = workspace_uri) do
    workspace_uri
    |> Ezagent.URI.workspace_name!()
    |> Ezagent.URI.agent(Ecto.UUID.generate())
  end

  defp existing_member_for_role(%URI{} = session_uri, role_name) do
    Members.role_name_to_uri(read_members(session_uri), role_name)
  end

  defp read_members(%URI{} = session_uri) do
    slice_module = Ezagent.ActionSet.Session.state_slice()

    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        chat_slice =
          pid
          |> :sys.get_state()
          |> Map.get(:state, %{})
          |> Map.get(slice_module, %{})

        Map.get(Map.get(chat_slice, :state, chat_slice), :members, %{})

      :error ->
        %{}
    end
  end

  defp valid_agent?(%{} = agent) do
    is_binary(recipe_of(agent)) and is_binary(role_name_of(agent)) and
      (install_mode_of(agent) == :fresh or match?(%URI{}, reuse_agent_uri_of(agent)))
  end

  defp valid_agent?(_), do: false

  defp recipe_of(agent), do: Map.get(agent, :recipe) || Map.get(agent, "recipe")
  defp role_name_of(agent), do: Map.get(agent, :role_name) || Map.get(agent, "role_name")

  defp install_mode_of(agent) do
    case Map.get(agent, :install_mode) || Map.get(agent, "install_mode") || Map.get(agent, :mode) ||
           Map.get(agent, "mode") do
      mode when mode in [:reuse, "reuse"] -> :reuse
      _ -> :fresh
    end
  end

  defp reuse_agent_uri_of(agent) do
    case Map.get(agent, :reuse_agent_uri) || Map.get(agent, "reuse_agent_uri") ||
           Map.get(agent, :agent_uri) || Map.get(agent, "agent_uri") do
      %URI{} = uri -> uri
      value when is_binary(value) and value != "" -> Ezagent.URI.new!(value)
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp flavor_of(agent) do
    case Map.get(agent, :flavor) || Map.get(agent, "flavor") do
      flavor when is_binary(flavor) and flavor != "" -> flavor
      _ -> "cc"
    end
  end
end
