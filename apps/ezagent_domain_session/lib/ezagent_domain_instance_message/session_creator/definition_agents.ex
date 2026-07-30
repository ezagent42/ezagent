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

  alias Ezagent.Agent.RecipeMaterializer
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Entity.Session.Orchestrator, as: SessionOrchestrator
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Invocation
  alias Ezagent.Orchestrator.Tools.Participants
  alias Ezagent.Session.Participants, as: SessionParticipants
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.Materializer
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @telemetry_prefix [:ezagent, :socialware, :definition_agents]
  @agent_description "socialware-declared agent materialized per-session (Definition.roles)"
  @role_member_attempts 100
  @role_member_poll_ms 10

  @doc """
  Materialize agent role slots into `session_uri`. `granted_by` is the session owner
  (the #154-clean grant/spawn root). Idempotent on the repair/restart path.

  Returns `{:ok, summary}` where `summary` is
  `%{satisfied: [role_name], skipped: [%{role_name:, reason:}]}`.

  Credential setup is deliberately outside this materialization path. Every
  materialization failure halts the batch (`{:error, reason}`): duplicate role
  names, unknown recipes, failed spawns, and failed joins are all surfaced to
  the caller.
  """
  @type summary :: %{
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
    do: {:ok, %{satisfied: [], skipped: []}}

  defp do_materialize_definition_agents(session_uri, workspace_uri, granted_by, agents, opts) do
    result =
      Enum.reduce_while(agents, {:ok, MapSet.new(), [], [], %{}}, fn agent,
                                                                     {:ok, batch_seen, installed,
                                                                      skipped, role_members} ->
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
                 {:ok, seen, [role_name | installed], skipped,
                  Map.put(role_members, role_name, agent_uri)}}

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
      {:ok, _seen, satisfied, skipped, role_members} ->
        summary = %{satisfied: Enum.reverse(satisfied), skipped: Enum.reverse(skipped)}

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

  defp materialize_one(session_uri, workspace_uri, granted_by, %{} = agent) do
    recipe_name = lookup_ref(recipe_of(agent))
    role_name = role_name_of(agent)

    case existing_member_for_role(session_uri, role_name) do
      %URI{} = existing_uri ->
        # Idempotent re-materialize (repair/restart) — the role is already
        # joined. Refresh its durable recipe binding without re-spawning, then
        # re-run post materialization hooks because both are idempotent and may
        # be absent on legacy sessions.
        with :ok <- refresh_existing_binding(workspace_uri, existing_uri, recipe_name, role_name),
             :ok <-
               maybe_after_materialize(
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
              materialize_fresh_agent(
                session_uri,
                workspace_uri,
                granted_by,
                agent,
                recipe_name,
                role_name
              )
          end

        case result do
          {:ok, agent_uri} ->
            # The orchestrator-recipe hook: grants scoped delegation caps +
            # registers MCP context. Non-orchestrator roles are a no-op.
            case maybe_after_materialize(
                   session_uri,
                   workspace_uri,
                   granted_by,
                   agent,
                   agent_uri
                 ) do
              :ok -> {:ok, agent_uri}
              {:error, _reason} = error -> error
            end

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

    with {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         recipe = merge_role_config(recipe, role_config(agent)),
         {:ok, planned_uri} <-
           planned_uri_for_role(session_uri, workspace_uri, agent, role_name, recipe) do
      materialize_at_planned_uri(
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

  # A DETERMINISTIC-URI role (a passive data role's `sw-data-<digest>` URI is a
  # pure function of session + role_name) whose agent is ALREADY LIVE from a
  # prior materialize is an idempotent re-materialize/repair. Re-running the full
  # spawn would fail: `spawn_from_template_content` correctly rejects a spawn onto
  # an already-live URI as `:agent_uri_already_live` (the reject-double-spawn
  # contract). Mirror the existing-member idempotent branch — refresh the durable
  # recipe binding without re-spawning. A fresh (non-passive) role's URI is a
  # random UUID, so it is never live here and always takes the spawn path.
  defp materialize_at_planned_uri(
         session_uri,
         workspace_uri,
         granted_by,
         agent,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider,
         %URI{} = planned_uri
       ) do
    if Ezagent.Kind.alive?(planned_uri) do
      with :ok <-
             refresh_existing_binding(workspace_uri, planned_uri, recipe_name, role_name) do
        {:ok, planned_uri}
      end
    else
      spawn_fresh_at_planned_uri(
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

  defp spawn_fresh_at_planned_uri(
         session_uri,
         _workspace_uri,
         granted_by,
         _agent,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider,
         planned_uri
       ) do
    with :ok <-
           spawn_bound_agent(
             session_uri,
             granted_by,
             planned_uri,
             recipe,
             recipe_name,
             role_name,
             flavor,
             provider
           ) do
      {:ok, planned_uri}
    end
  end

  defp map_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp spawn_bound_agent(
         session_uri,
         granted_by,
         planned_uri,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider
       ) do
    workspace_uri = Ezagent.Capability.workspace_of(planned_uri)

    with {:ok, fresh_receipt} <-
           spawn_agent(
             workspace_uri,
             granted_by,
             planned_uri,
             recipe,
             recipe_name,
             role_name,
             flavor,
             provider
           ) do
      case bind_recipe_caps(planned_uri, recipe_name, recipe) do
        {:ok, binding} ->
          result =
            with :ok <- RecipeCapBinding.sync_live(planned_uri),
                 # Session admission checks whether the caller manages the
                 # credential-bearing agent. This must exist before `join`;
                 # granting it afterwards turns a valid fresh role into a
                 # pending admission and aborts the whole template roster.
                 :ok <-
                   Ezagent.Workspace.grant_creator_manage_cap(
                     :agent,
                     planned_uri,
                     workspace_uri,
                     granted_by
                   ),
                 :ok <- join_or_cleanup(session_uri, planned_uri, role_name, recipe),
                 :ok <- maybe_await_role_member(session_uri, planned_uri, role_name, recipe) do
              :ok
            end

          case result do
            :ok ->
              :ok

            {:error, _reason} = error ->
              rollback_failed_fresh(
                error,
                session_uri,
                planned_uri,
                fresh_receipt,
                binding.version
              )
          end

        {:error, _reason} = error ->
          rollback_failed_fresh(error, session_uri, planned_uri, fresh_receipt, nil)
      end
    end
  end

  defp reuse_existing_agent(session_uri, workspace_uri, operator, agent, recipe_name, role_name) do
    with %URI{} = agent_uri <- reuse_agent_uri_of(agent),
         :ok <- ensure_reuse_recipe_match(agent_uri, recipe_name, role_name),
         {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         {:ok, reuse_caps} <- reuse_caps(session_uri, operator),
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
         :ok <- await_role_membership(session_uri, agent_uri, role_name),
         {:ok, _binding} <- bind_recipe_caps(agent_uri, recipe_name, recipe),
         :ok <- RecipeCapBinding.sync_live(agent_uri) do
      {:ok, agent_uri}
    else
      nil -> {:error, {:invalid_reuse_agent_uri, role_name}}
      {:error, _} = error -> error
      other -> {:error, {:reuse_agent_join_failed, role_name, other}}
    end
  end

  defp maybe_after_materialize(session_uri, workspace_uri, granted_by, agent, agent_uri) do
    # Session role agents are created on behalf of the session owner,
    # not through Workspace.AgentCreate. Grant the same instance-scoped
    # Manage authority that a direct creator receives: it authorizes the
    # owner to read and type in the agent's PTY, including an initial
    # `codex login` / `claude /login` before credentials exist.
    with :ok <-
           Materializer.grant_owner_participant_teardown_cap(
             agent_uri,
             granted_by,
             workspace_uri
           ) do
      maybe_after_orchestrator_materialize(
        session_uri,
        workspace_uri,
        granted_by,
        agent,
        agent_uri
      )
    end
  end

  defp maybe_after_orchestrator_materialize(
         session_uri,
         workspace_uri,
         granted_by,
         agent,
         agent_uri
       ) do
    if orchestrator_recipe_slot?(agent) do
      parent_template_uri = parent_template_uri_for(session_uri)

      # Ordering (R2 + R3 + P1):
      #   1. verify the durable binding pre-stored before spawn still names the
      #      ACTUAL spawned agent URI, and obtain its materialization epoch;
      #   2. register the MCP context BEFORE granting (R3 — the readiness/
      #      tool-surface registration must precede the grant, not follow it).
      #   3. grant the orchestrator's scope-bounded caps LAST.
      with {:ok, binding} <- Materializer.ensure_orchestrator_binding(session_uri, agent_uri),
           :ok <-
             SessionOrchestrator.register_orchestrator_mcp_context(
               agent_uri,
               session_uri,
               workspace_uri,
               granted_by,
               parent_template_uri,
               binding.epoch
             ),
           :ok <-
             SessionOrchestrator.grant_orchestrator_scoped_caps(
               agent_uri,
               session_uri,
               granted_by
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

  # Spawn only. Binding and joining follow after the target has materialized.
  defp spawn_agent(
         workspace_uri,
         granted_by,
         planned_uri,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider
       ) do
    source_template_uri = Ezagent.URI.template(:system, :agent, recipe_name)

    spawn_opts = %{
      recipe: recipe,
      recipe_name: recipe_name,
      role_name: role_name,
      flavor: flavor,
      agent_uri: planned_uri,
      workspace_uri: workspace_uri,
      owner_uri: granted_by,
      caller: granted_by,
      authenticated_principal: granted_by,
      caps: SessionCreator.list_caps_for_materialization(granted_by),
      source_template_uri: source_template_uri,
      description: @agent_description,
      template_content_overrides: %{
        credential_optional: true,
        session_template_member: true
      }
    }

    # The cc-custom seam: the role slot's selected backend profile rides into
    # the materialized content's `provider` — only when the slot declares one
    # (plain-cc/legacy slots keep the byte-unchanged opts map).
    spawn_opts =
      case provider do
        p when is_binary(p) and p != "" -> Map.put(spawn_opts, :provider, p)
        _ -> spawn_opts
      end

    case RecipeMaterializer.create_agent_from_recipe(spawn_opts) do
      {:ok, {:created, fresh_receipt}} ->
        {:ok, fresh_receipt}

      {:ok, :already_present} ->
        {:error, {:agent_spawn_failed, role_name, :agent_uri_already_live}}

      {:error, reason} ->
        {:error, {:agent_spawn_failed, role_name, reason}}
    end
  end

  # Faceted `session.join` carrying the `%{role_name: name}` facet. The caller
  # owns receipt-based compensation for every failure after a fresh spawn.
  defp join_or_cleanup(session_uri, %URI{} = member_uri, role_name, recipe)
       when is_map(recipe) do
    if passive_recipe?(recipe) do
      :ok
    else
      do_join(session_uri, member_uri, role_name)
    end
  end

  defp do_join(session_uri, %URI{} = member_uri, role_name) do
    case join_member(session_uri, member_uri, role_name) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:agent_join_failed, role_name, reason}}
    end
  end

  defp maybe_await_role_member(session_uri, member_uri, role_name, recipe)
       when is_map(recipe) do
    if passive_recipe?(recipe) do
      :ok
    else
      await_role_membership(session_uri, member_uri, role_name)
    end
  end

  defp await_role_membership(session_uri, planned_uri, role_name) do
    case await_role_member(session_uri, planned_uri, role_name) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, {:agent_membership_convergence_failed, role_name, reason}}
    end
  end

  defp await_role_member(session_uri, planned_uri, role_name, attempts \\ @role_member_attempts)

  defp await_role_member(_session_uri, _planned_uri, _role_name, 0),
    do: {:error, :membership_convergence_timeout}

  defp await_role_member(session_uri, planned_uri, role_name, attempts) do
    if Members.role_name_to_uri(read_members(session_uri), role_name) == planned_uri do
      :ok
    else
      Process.sleep(@role_member_poll_ms)
      await_role_member(session_uri, planned_uri, role_name, attempts - 1)
    end
  end

  defp join_member(%URI{} = session_uri, %URI{} = member_uri, role_name) do
    _ = Ezagent.Domain.Agent.ensure_declared_member(member_uri)
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    admin = Ezagent.Entity.User.admin_uri()

    result =
      with {:ok, cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, admin, target) do
        Invocation.dispatch(%Invocation{
          target: target,
          mode: :call,
          args: %{member: member_uri, role_name: role_name},
          ctx: %{
            caller: admin,
            authenticated_principal: admin,
            caps: MapSet.new([cap]),
            reply: {:caller_inbox, self()}
          },
          origin: :trusted_internal
        })
      end

    case result do
      {:ok, %{status: status, member: ^member_uri}}
      when status in [:granted, :already_member] ->
        :ok

      {:ok, %{status: :pending, member: ^member_uri}} ->
        {:error, :admission_pending}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_join_result, other}}
    end
  end

  # --- durable recipe-cap binding -------------------------------------------

  defp refresh_existing_binding(workspace_uri, agent_uri, recipe_name, role_name) do
    with {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         {:ok, _binding} <- bind_recipe_caps(agent_uri, recipe_name, recipe),
         :ok <- RecipeCapBinding.sync_live(agent_uri) do
      :ok
    else
      {:error, reason} -> {:error, {:agent_recipe_binding_refresh_failed, role_name, reason}}
    end
  end

  defp bind_recipe_caps(%URI{} = agent_uri, recipe_name, recipe) do
    issuer = Ezagent.Entity.User.admin_uri()

    with {:ok, proposals} <-
           GrantRecipeCaps.propose_recipe_caps(agent_uri, recipe, @telemetry_prefix),
         {:ok, binding} <-
           RecipeCapBinding.issue_and_upsert(agent_uri, recipe_name, issuer, proposals) do
      {:ok, binding}
    else
      {:error, reason} -> {:error, {:agent_bind_recipe_caps_failed, reason}}
    end
  end

  defp rollback_failed_fresh(
         {:error, reason} = original_error,
         session_uri,
         agent_uri,
         fresh_receipt,
         binding_version
       ) do
    with {:ok, :retired} <-
           RecipeMaterializer.rollback_fresh_agent(fresh_receipt, binding_version),
         :ok <- remove_fresh_member(session_uri, agent_uri) do
      original_error
    else
      {:error, rollback_reason} ->
        {:error, {reason, {:rollback_failed, rollback_reason}}}
    end
  end

  defp remove_fresh_member(%URI{} = session_uri, %URI{} = agent_uri) do
    admin = Ezagent.Entity.User.admin_uri()
    target = Ezagent.URI.with_action(session_uri, :session, :remove_participant)

    with {:ok, cap} <- Ezagent.Cap.issue_for_action({:admin, admin}, admin, target),
         {:ok, result} <-
           SessionParticipants.remove_participant(session_uri, agent_uri, %{
             caller: admin,
             authenticated_principal: admin,
             caps: MapSet.new([cap])
           }) do
      case result do
        :already_removed -> :ok
        %{status: :removed} -> :ok
        other -> {:error, {:unexpected_failed_member_removal, other}}
      end
    end
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

  defp passive_recipe?(recipe),
    do: Map.get(recipe, :passive, Map.get(recipe, "passive", false)) == true

  defp existing_member_for_role(%URI{} = session_uri, role_name) do
    Members.role_name_to_uri(read_members(session_uri), role_name)
  end

  defp read_members(%URI{} = session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, chat_slice} ->
        Map.get(chat_slice, :members, %{})

      {:error, _reason} ->
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

  # The role slot's OPTIONAL cc-custom backend profile (atom or string key).
  # Absent/empty → nil: plain-cc and legacy slots carry no profile, and the
  # credential seams below must see NO opt at all (byte-unchanged behavior).
  defp provider_of(agent) do
    case Map.get(agent, :provider) || Map.get(agent, "provider") do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> nil
    end
  end

  defp role_config(agent) do
    case map_field(agent, :config) do
      config when is_map(config) -> config
      _ -> %{}
    end
  end

  defp merge_role_config(recipe, config) when is_map(recipe) and is_map(config) do
    base =
      case map_field(recipe, :config) do
        current when is_map(current) -> current
        _ -> %{}
      end

    Map.put(recipe, :config, Map.merge(base, config))
  end
end
