defmodule EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents do
  @moduledoc """
  Materialize a socialware `Definition`'s agent role slots into live actors.

  Agent role slots declare "this socialware needs an agent with this role";
  materialization turns each into a live, session/workspace-scoped agent. Active
  roles are JOINED as session members with their `role_name` facet (so
  `{:role, name}` routing rules resolve to them). Passive data roles remain
  outside membership and are made available to composition-cap reconciliation.

  Per agent, the pipeline REUSES the existing safe managed-member envelope shape
  (`Ezagent.Orchestrator.Tools.add_managed_member`: preflight → spawn → faceted
  `session.join` → cleanup-on-join-failure) so a join failure never leaves an
  orphan worker:

    1. **role_name uniqueness FIRST** — reject duplicate role names in the same
       role batch. An existing live member with that role means idempotent
       re-materialize/repair has already bound the role, so skip.
    2. **resolve recipe by workspace** — `RecipeRegistry.lookup(workspace, name)`,
       fail-closed on `:error` (never a cap-less spawn; #1116).
    3. **spawn + seal authority** — recipe × declared flavor (default `cc`) →
       `Agent.spawn_from_template_content` at a fresh uuid agent URI.
    4. **issue + bind + sync** — with the target Kind live, resolve recipe caps
       through its `K.grant`, atomically upsert the signed artifacts, and
       version-reconcile them into the live Identity slice.
    5. **join + cleanup** — faceted `session.join` carrying `%{role_name: name}`;
       on a bind/sync/join/convergence failure, conditionally tombstone the exact
       binding version and retire the fresh worker through its opaque spawn
       receipt. Retirement calls the Kind lifecycle directly and does not depend
       on the failed worker becoming dispatch-ready.
    6. **no cold-target signing bypass** — recipe artifacts can only be minted
       after the target authority exists. Cold restart hydrates the durable
       binding; live materialization uses a fixed VM-internal sync action, not a
       second signer.

  Authority is SYSTEM-MEDIATED materialization (mirrors
  `Materializer.join_session_members`):
  the spawn runs under the session owner (`granted_by`) with
  `list_caps_for_materialization/1`, and the join dispatch under the genesis
  admin entity with an inline least-priv cap.

  > **Rebase note (T1, reconciled):** T1's structured `recipe:<name>` subject has
  > landed. Role `recipe` accepts EITHER a plain recipe name (`guide`) or the
  > structured subject (`recipe:guide`); `lookup_ref/1` strips a single leading
  > `recipe:` prefix so both resolve identically through `RecipeRegistry.lookup/2`
  > (which itself takes a plain name and re-derives the subject).
  """

  require Logger

  import EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentSupport,
    except: [planned_agent_uri: 1]

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Orchestrator.Tools.Participants
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentLifecycle
  alias EzagentDomainInstanceMessage.SessionCreator.Materializer

  @telemetry_prefix [:ezagent, :socialware, :definition_agents]

  @doc """
  Materialize agent role slots into `session_uri`. `granted_by` is the session owner
  (the #154-clean grant/spawn root). Idempotent on the repair/restart path.

  Returns `{:ok, summary}` where `summary` is
  `%{satisfied: [role_name], skipped: [%{role_name:, reason:}]}`.

  A role whose registered flavor declares a credential connection is deferred
  into durable admission. Session materialization never resolves a prior user or
  workspace credential source for it; the owner must authenticate the fresh
  provisional agent before it can join. Credential-free roles still materialize
  immediately.

  Every OTHER failure still halts the batch (`{:error, reason, partial}`): a
  duplicate role name, an unknown recipe, a failed spawn/bind/join. Those are
  bugs, not environment, and must not be swallowed as "skipped".
  """
  @type summary :: %{
          optional(:deferred) => [String.t()],
          satisfied: [String.t()],
          skipped: [%{role_name: String.t(), reason: term()}]
        }

  @spec materialize_definition_agents(URI.t(), URI.t(), URI.t(), [map()]) ::
          {:ok, summary()} | {:error, term()} | {:error, term(), summary()}
  def materialize_definition_agents(session_uri, workspace_uri, granted_by, agents),
    do: materialize_definition_agents(session_uri, workspace_uri, granted_by, agents, [])

  @spec materialize_definition_agents(URI.t(), URI.t(), URI.t(), [map()], keyword()) ::
          {:ok, summary()} | {:error, term()} | {:error, term(), summary()}
  def materialize_definition_agents(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        agents,
        opts
      )
      when is_list(agents) and is_list(opts) do
    with :ok <-
           Ezagent.Socialware.CompositionCaps.assert_install_authorized(
             session_uri,
             agents,
             opts
           ) do
      do_materialize_definition_agents(
        session_uri,
        workspace_uri,
        granted_by,
        agents,
        opts
      )
    end
  end

  def materialize_definition_agents(_session, _ws, _granted_by, _agents, _opts),
    do: {:ok, %{satisfied: [], skipped: [], deferred: []}}

  defp do_materialize_definition_agents(session_uri, workspace_uri, granted_by, agents, opts) do
    result =
      Enum.reduce_while(agents, {:ok, MapSet.new(), [], [], [], %{}}, fn agent,
                                                                         {:ok, batch_seen,
                                                                          installed, skipped,
                                                                          deferred, role_members} ->
        role_name = role_name_of(agent)

        cond do
          not valid_agent?(agent) ->
            {:halt, {:error, {:invalid_socialware_agent, agent}}}

          MapSet.member?(batch_seen, role_name) ->
            {:halt, {:error, {:duplicate_agent_role_name, role_name}}}

          true ->
            seen = MapSet.put(batch_seen, role_name)

            case materialize_one(session_uri, workspace_uri, granted_by, agent) do
              {:ok, %URI{} = agent_uri} ->
                {:cont,
                 {:ok, seen, [role_name | installed], skipped, deferred,
                  Map.put(role_members, role_name, agent_uri)}}

              {:deferred, _admission} ->
                {:cont, {:ok, seen, installed, skipped, [role_name | deferred], role_members}}

              # Chain C — a credential-less FILE-flavor role is skipped, not
              # fatal: the batch continues and the durable, user-facing record is
              # written from `summary.skipped` by the caller.
              {:skip, reason} ->
                report_skip(session_uri, role_name, reason)

                {:cont,
                 {:ok, seen, installed, [%{role_name: role_name, reason: reason} | skipped],
                  deferred, role_members}}

              {:error, reason} ->
                partial = %{
                  satisfied: Enum.reverse(installed),
                  skipped:
                    Enum.reverse([
                      %{role_name: role_name, reason: reason} | skipped
                    ])
                }

                {:halt, {:error, reason, partial}}
            end
        end
      end)

    case result do
      {:ok, _seen, satisfied, skipped, deferred, role_members} ->
        summary = %{
          satisfied: Enum.reverse(satisfied),
          skipped: Enum.reverse(skipped),
          deferred: Enum.reverse(deferred)
        }

        case Ezagent.Socialware.CompositionCaps.reconcile_session(
               session_uri,
               workspace_uri,
               granted_by,
               agents,
               Keyword.put(opts, :role_members, role_members)
             ) do
          {:ok, _composition_summary} -> {:ok, summary}
          {:error, reason} -> {:error, reason, summary}
        end

      {:error, reason, partial} ->
        {:error, reason, partial}

      {:error, _} = err ->
        err
    end
  end

  # LOUD, but not fatal. The durable, user-facing record is written by
  # `SessionCreator.record_unfilled_role_slots/2` from the returned summary — a
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
        # joined. Refresh its durable recipe binding without re-spawning, then
        # re-run post materialization hooks because both are idempotent and may
        # be absent on legacy sessions.
        with :ok <-
               DefinitionAgentLifecycle.refresh_existing_binding(
                 workspace_uri,
                 existing_uri,
                 recipe_name,
                 role_name
               ),
             :ok <- maybe_clear_admission(session_uri, agent),
             :ok <-
               DefinitionAgentLifecycle.after_materialize(
                 session_uri,
                 workspace_uri,
                 granted_by,
                 agent,
                 existing_uri
               ) do
          {:ok, existing_uri}
        end

      nil ->
        result =
          with {:ok, _recipe} <- lookup_recipe(workspace_uri, recipe_name) do
            case install_mode_of(agent) do
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
                case credential_admission_of(agent) do
                  :before_session_join ->
                    materialize_gated_agent(session_uri, agent)

                  :immediate ->
                    materialize_fresh_agent(
                      session_uri,
                      workspace_uri,
                      granted_by,
                      agent,
                      recipe_name,
                      role_name
                    )
                end
            end
          end

        case result do
          {:ok, agent_uri} ->
            # The orchestrator-recipe hook: grants scoped delegation caps +
            # registers MCP context. Non-orchestrator roles are a no-op.
            case DefinitionAgentLifecycle.after_materialize(
                   session_uri,
                   workspace_uri,
                   granted_by,
                   agent,
                   agent_uri
                 ) do
              :ok -> {:ok, agent_uri}
              {:error, _reason} = error -> error
            end

          # Chain C — a credential-less FILE-flavor role is skipped (not spawned),
          # so no post-materialize hooks run; propagate the skip to the batch loop.
          {:skip, _reason} = skip ->
            skip

          {:deferred, _admission} = deferred ->
            deferred

          {:error, _reason} = error ->
            error
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
    flavor = flavor_of(agent)
    provider = provider_of(agent)

    with {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name) do
      recipe = merge_role_config(recipe, role_config(agent))

      materialize_planned_agent(
        session_uri,
        workspace_uri,
        granted_by,
        agent,
        recipe,
        recipe_name,
        role_name,
        flavor,
        provider
      )
    end
  end

  defp materialize_gated_agent(session_uri, agent) do
    with {:ok, current_admission} <- AgentAdmission.current(session_uri, agent) do
      case current_admission do
        %{status: status} = admission when status in [:authenticating, :materializing] ->
          {:deferred, admission}

        %{status: :pending_auth, failure_code: :authentication_failed} = admission ->
          {:deferred, admission}

        _other ->
          with {:ok, admission} <- AgentAdmission.defer(session_uri, agent) do
            {:deferred, admission}
          end
      end
    end
  end

  defp materialize_planned_agent(
         session_uri,
         workspace_uri,
         granted_by,
         agent,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider
       ) do
    with {:ok, planned_uri} <-
           planned_uri_for_role(session_uri, workspace_uri, agent, role_name, recipe) do
      DefinitionAgentLifecycle.materialize_at_planned_uri(
        session_uri,
        workspace_uri,
        granted_by,
        agent,
        recipe,
        recipe_name,
        role_name,
        flavor,
        provider,
        planned_uri
      )
    end
  end

  @doc false
  @spec spawn_provisional(URI.t(), URI.t(), URI.t(), map()) ::
          {:ok, URI.t(), String.t()} | {:error, term()}
  def spawn_provisional(session_uri, workspace_uri, granted_by, declaration),
    do:
      DefinitionAgentLifecycle.spawn_provisional(
        session_uri,
        workspace_uri,
        granted_by,
        declaration
      )

  @doc false
  @spec complete_provisional(URI.t(), URI.t(), map(), URI.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def complete_provisional(session_uri, granted_by, declaration, agent_uri, attempt_id, ctx),
    do:
      DefinitionAgentLifecycle.complete_provisional(
        session_uri,
        granted_by,
        declaration,
        agent_uri,
        attempt_id,
        ctx
      )

  @doc false
  @spec cleanup_provisional(URI.t(), URI.t(), URI.t(), String.t(), map(), term()) ::
          :ok | {:error, term()}
  def cleanup_provisional(session_uri, provenance_root, agent_uri, attempt_id, ctx, reason),
    do:
      DefinitionAgentLifecycle.cleanup_provisional(
        session_uri,
        provenance_root,
        agent_uri,
        attempt_id,
        ctx,
        reason
      )

  defp reuse_existing_agent(session_uri, workspace_uri, operator, agent, recipe_name, role_name) do
    with %URI{} = agent_uri <- reuse_agent_uri_of(agent),
         {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         {:ok, _live_or_rehydrated} <- Ezagent.Domain.Agent.ensure_deliverable(agent_uri),
         {:ok, reuse_caps} <- reuse_caps(session_uri, operator),
         # The declaration can drift after its installation preflight. Verify
         # the existing agent still fulfils the complete reuse contract at the
         # final join boundary; failures become durable unfilled roles rather
         # than a fatal install or a fresh replacement.
         :ok <-
           revalidate_reuse_contract(
             agent_uri,
             operator,
             recipe_name,
             flavor_of(agent),
             role_name
           ),
         # A reused agent already exists. Bind only after a successful join: an unrelated join failure
         # must never tombstone or overwrite that agent's pre-existing binding.
         {:ok, ^agent_uri} <-
           Participants.add_participant(agent_uri, role_name,
             caller: operator,
             caps: reuse_caps,
             workspace_uri: workspace_uri,
             session_uri: session_uri,
             in_session_template: true
           ),
         :ok <-
           DefinitionAgentLifecycle.await_role_membership(session_uri, agent_uri, role_name),
         {:ok, _binding} <-
           DefinitionAgentLifecycle.bind_recipe_caps(agent_uri, recipe_name, recipe),
         :ok <- RecipeCapBinding.sync_live(agent_uri) do
      {:ok, agent_uri}
    else
      nil -> {:error, {:invalid_reuse_agent_uri, role_name}}
      {:skip, _reason} = skip -> skip
      {:error, _} = error -> error
      other -> {:error, {:reuse_agent_join_failed, role_name, other}}
    end
  end

  defp revalidate_reuse_contract(agent_uri, operator, recipe_name, flavor, role_name) do
    reason =
      cond do
        agent_recipe(agent_uri) != {:ok, recipe_name} -> :recipe_mismatch
        Ezagent.AgentFlavorAttributes.get(agent_uri) != {:ok, flavor} -> :flavor_mismatch
        not Ezagent.Identity.Authority.manages?(operator, agent_uri) -> :unauthorized
        true -> :ok
      end

    case reason do
      :ok -> :ok
      reason -> {:skip, {:reuse_agent_revalidation_failed, role_name, reason}}
    end
  end

  defp agent_recipe(%URI{} = agent_uri),
    do: Ezagent.Agent.RecipeAttributes.fetch_or_resolve(agent_uri)

  defp reuse_caps(%URI{} = session_uri, %URI{} = operator) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)

    case Ezagent.Cap.issue_for_action({:admin, Ezagent.Entity.User.admin_uri()}, operator, target) do
      {:ok, cap} -> {:ok, MapSet.new([cap])}
      {:error, _reason} = error -> error
    end
  end

  # --- resolve --------------------------------------------------------------

  # T1 rebase reconciliation: recipe subjects are the structured `recipe:<name>`
  # form (T1 project B). `RecipeRegistry.lookup/2` takes a PLAIN recipe name and
  # re-derives the `recipe:<name>` subject internally, and the same plain name is
  # reused as the AgentTemplate name — so normalize a single leading `recipe:`
  # prefix here so both a bare `guide` and a prefixed `recipe:guide` in role
  # slots resolve identically. Idempotent: strips at most one prefix.
  # --- helpers --------------------------------------------------------------

  @doc """
  Fresh per-session agent URI. Definition declarations intentionally carry only
  role data; the runtime chooses a UUID instance URI at materialization time.
  """
  @spec planned_agent_uri(URI.t()) :: URI.t()
  def planned_agent_uri(%URI{} = workspace_uri),
    do:
      EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentSupport.planned_agent_uri(
        workspace_uri
      )

  defp planned_uri_for_role(session_uri, workspace_uri, agent, role_name, recipe) do
    if orchestrator_recipe_slot?(agent) do
      case Materializer.stored_orchestrator_binding(session_uri) do
        {:ok, %{uri: %URI{} = uri}} ->
          case Materializer.ensure_orchestrator_binding(session_uri, uri) do
            {:ok, _binding} -> {:ok, uri}
            {:error, reason} -> {:error, {:store_orchestrator_uri_failed, reason}}
          end

        _ ->
          uri = planned_agent_uri(workspace_uri)

          case Materializer.ensure_orchestrator_binding(session_uri, uri) do
            {:ok, _binding} -> {:ok, uri}
            {:error, reason} -> {:error, {:store_orchestrator_uri_failed, reason}}
          end
      end
    else
      {:ok, planned_agent_uri(workspace_uri, session_uri, role_name, passive_recipe?(recipe))}
    end
  end

  defp planned_agent_uri(workspace_uri, _session_uri, _role_name, false),
    do: planned_agent_uri(workspace_uri)

  defp planned_agent_uri(workspace_uri, session_uri, role_name, true) do
    digest =
      [URI.to_string(session_uri), "\0", role_name]
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    Ezagent.URI.agent(Ezagent.URI.workspace_name!(workspace_uri), "sw-data-#{digest}")
  end

  defp existing_member_for_role(%URI{} = session_uri, role_name) do
    Members.role_name_to_uri(DefinitionAgentLifecycle.read_members(session_uri), role_name)
  end

  defp valid_agent?(%{} = agent) do
    is_binary(recipe_of(agent)) and is_binary(role_name_of(agent)) and
      (install_mode_of(agent) == :fresh or match?(%URI{}, reuse_agent_uri_of(agent)))
  end

  defp valid_agent?(_), do: false

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

  defp maybe_clear_admission(session_uri, agent) do
    if credential_admission_of(agent) == :before_session_join,
      do: AgentAdmission.clear(session_uri, agent),
      else: :ok
  end

  # The role slot's OPTIONAL cc-custom backend profile (atom or string key).
  # Absent/empty → nil: plain-cc and legacy slots carry no profile, and the
  # credential seams below must see NO opt at all (byte-unchanged behavior).
end
