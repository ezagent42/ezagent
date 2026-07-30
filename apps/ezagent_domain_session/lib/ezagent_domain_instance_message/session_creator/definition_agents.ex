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

  alias Ezagent.Agent.CredentialPrecondition
  alias Ezagent.Agent.RecipeMaterializer
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Entity.Session.Orchestrator, as: SessionOrchestrator
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Invocation
  alias Ezagent.Orchestrator.Tools.Participants
  alias Ezagent.Session.Participants, as: SessionParticipants
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
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

  ## Skip vs fail (chain C, Allen 2026-07-10 / #1326)

  A FILE-credential role slot (cc: OAuth `.credentials.json`) whose installer has
  no resolvable credential source is SKIPPED, not fatal: it is logged, emitted as
  telemetry, recorded on the session (`unfilled_agent_role_slots`), and the rest
  of the batch continues. Creating it anyway produces an agent that boots "Not
  logged in", never joins its transport bridge, and hangs at `:not_ready` forever
  — a silent zombie member (see `check_credential_source/3` +
  `Ezagent.Agent.CredentialPrecondition`). env-/slice-credential flavors
  keyless-spawn by design (credentialless template membership — the credential
  may still arrive through the cascade at cold spawn), so they are NOT gated here.

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
        with :ok <- refresh_existing_binding(workspace_uri, existing_uri, recipe_name, role_name),
             :ok <- maybe_clear_admission(session_uri, agent),
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

      case credential_admission_of(agent) do
        :before_session_join ->
          materialize_gated_agent(
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

        :immediate ->
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
  end

  defp materialize_gated_agent(
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
    case active_admission(session_uri, role_name) do
      %{status: status} = admission when status in [:authenticating, :materializing] ->
        {:deferred, admission}

      _ ->
        opts = [
          backend_profile: provider,
          credential_optional: map_field(role_config(agent), :credential_optional)
        ]

        case CredentialPrecondition.check_source(granted_by, workspace_uri, flavor, opts) do
          :ok ->
            with :ok <- AgentAdmission.clear(session_uri, agent) do
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

          {:skip, _reason} ->
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
         workspace_uri,
         granted_by,
         _agent,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider,
         planned_uri
       ) do
    # #1201 A② + chain C (#1326) — BEFORE the spawn (whose #17 cascade resolves
    # the installer's credential source), auto-adopt the HOST operator's login as
    # that source (no-op for non-operators / credential-less flavors / login-less
    # nodes), then gate FILE-credential roles on a resolvable source. Without a
    # source a cc role can only boot "Not logged in": skip the slot rather than
    # join a silent zombie member. Neither step copies credentials — the unchanged
    # cascade inside `spawn_bound_agent` does that when a source resolves.
    with :ok <-
           Ezagent.Agent.HostLoginAdopt.ensure_installer_source(
             granted_by,
             workspace_uri,
             flavor
           ),
         :ok <- check_credential_source(granted_by, workspace_uri, flavor),
         :ok <-
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

  # Chain C gate, scoped to FILE-credential flavors ONLY (cc: OAuth
  # `.credentials.json`). Such a role with no resolvable source is skipped rather
  # than spawned into a "Not logged in" zombie. env-/slice-credential flavors are
  # deliberately NOT gated here — they keyless-spawn by design (credentialless
  # template membership; the credential may still arrive through the cascade at
  # cold spawn). `CredentialPrecondition.check_source/4` stays the standalone
  # predicate the other lanes call directly; gating on `credential_bearing?/1`
  # here selects exactly its file branch.
  defp check_credential_source(installer, workspace_uri, flavor) do
    if CredentialPrecondition.credential_bearing?(flavor) do
      CredentialPrecondition.check_source(installer, workspace_uri, flavor)
    else
      :ok
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
      finish_spawned_agent(
        session_uri,
        workspace_uri,
        granted_by,
        planned_uri,
        recipe,
        recipe_name,
        role_name,
        fn error, binding_version ->
          rollback_failed_fresh(
            error,
            session_uri,
            planned_uri,
            fresh_receipt,
            binding_version
          )
        end
      )
    end
  end

  defp finish_spawned_agent(
         session_uri,
         workspace_uri,
         granted_by,
         planned_uri,
         recipe,
         recipe_name,
         role_name,
         cleanup
       ) do
    case bind_recipe_caps(planned_uri, recipe_name, recipe) do
      {:ok, binding} ->
        result =
          with :ok <- RecipeCapBinding.sync_live(planned_uri),
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
          :ok -> :ok
          {:error, _reason} = error -> cleanup.(error, binding.version)
        end

      {:error, _reason} = error ->
        cleanup.(error, nil)
    end
  end

  @doc false
  @spec spawn_provisional(URI.t(), URI.t(), URI.t(), map()) ::
          {:ok, URI.t(), String.t()} | {:error, term()}
  def spawn_provisional(
        %URI{} = session_uri,
        %URI{} = workspace_uri,
        %URI{} = granted_by,
        declaration
      )
      when is_map(declaration) do
    recipe_name = lookup_ref(recipe_of(declaration))
    role_name = role_name_of(declaration)
    flavor = flavor_of(declaration)
    provider = provider_of(declaration)
    planned_uri = planned_agent_uri(workspace_uri)

    with true <- credential_admission_of(declaration) == :before_session_join,
         :fresh <- install_mode_of(declaration),
         {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         recipe = merge_role_config(recipe, role_config(declaration)) do
      case spawn_agent(
             workspace_uri,
             granted_by,
             planned_uri,
             recipe,
             recipe_name,
             role_name,
             flavor,
             provider
           ) do
        {:ok, fresh_receipt} ->
          finish_provisional_spawn(
            session_uri,
            workspace_uri,
            granted_by,
            planned_uri,
            fresh_receipt
          )

        {:error, _reason} = error ->
          error
      end
    else
      false ->
        {:error, :role_does_not_require_agent_admission}

      mode when mode != :fresh ->
        {:error, :agent_admission_requires_fresh_role}

      {:error, _reason} = error ->
        error
    end
  end

  defp finish_provisional_spawn(
         _session_uri,
         workspace_uri,
         granted_by,
         planned_uri,
         fresh_receipt
       ) do
    result =
      with :ok <-
             Ezagent.Workspace.grant_creator_manage_cap(
               :agent,
               planned_uri,
               workspace_uri,
               granted_by
             ),
           :ok <-
             Materializer.grant_owner_participant_teardown_cap(
               planned_uri,
               granted_by,
               workspace_uri
             ),
           {:ok, attempt_id} <-
             Ezagent.Agent.CreationInventory.find_attempt(planned_uri, workspace_uri) do
        {:ok, planned_uri, attempt_id}
      end

    case result do
      {:ok, _, _} = ok ->
        ok

      {:error, _reason} = error ->
        _ = RecipeMaterializer.rollback_fresh_agent(fresh_receipt, nil)
        error
    end
  end

  @doc false
  @spec complete_provisional(URI.t(), URI.t(), map(), URI.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def complete_provisional(
        %URI{} = session_uri,
        %URI{} = granted_by,
        declaration,
        %URI{} = agent_uri,
        attempt_id,
        ctx
      )
      when is_map(declaration) and is_binary(attempt_id) and is_map(ctx) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    recipe_name = lookup_ref(recipe_of(declaration))
    role_name = role_name_of(declaration)

    with {:ok, ^attempt_id} <-
           Ezagent.Agent.CreationInventory.find_attempt(agent_uri, workspace_uri),
         {:ok, ^granted_by} <- Ezagent.AgentLineage.lookup(agent_uri),
         {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name) do
      recipe = merge_role_config(recipe, role_config(declaration))

      # AgentAdmission owns the durable state transition and the one cleanup
      # path for every post-spawn failure. The shared materialization helper
      # returns the original error so its caller can compensate and write
      # `:failed` atomically with respect to the admission lock.
      cleanup = fn error, _binding_version -> error end

      case finish_spawned_agent(
             session_uri,
             workspace_uri,
             granted_by,
             agent_uri,
             recipe,
             recipe_name,
             role_name,
             cleanup
           ) do
        :ok ->
          case maybe_after_materialize(
                 session_uri,
                 workspace_uri,
                 granted_by,
                 declaration,
                 agent_uri
               ) do
            :ok -> :ok
            {:error, _reason} = error -> error
          end

        {:error, _reason} = error ->
          error
      end
    else
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_provisional_agent, other}}
    end
  end

  @doc false
  @spec cleanup_provisional(URI.t(), URI.t(), URI.t(), String.t(), map(), term()) ::
          :ok | {:error, term()}
  def cleanup_provisional(
        %URI{} = session_uri,
        %URI{} = provenance_root,
        %URI{} = agent_uri,
        attempt_id,
        ctx,
        reason
      )
      when is_binary(attempt_id) and is_map(ctx) do
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)

    with :ok <- tombstone_active_binding(agent_uri),
         :ok <- remove_fresh_member(session_uri, agent_uri) do
      retirement =
        Ezagent.Domain.Agent.retire_spawned(agent_uri, %{
          caller: Map.fetch!(ctx, :caller),
          authenticated_principal: Map.fetch!(ctx, :authenticated_principal),
          caps:
            ctx
            |> Map.fetch!(:caps)
            |> Enum.concat(
              EzagentDomainInstanceMessage.SessionCreator.list_caps_for_materialization(
                provenance_root
              )
            )
            |> MapSet.new(),
          workspace_uri: workspace_uri,
          provenance_root: provenance_root,
          creation_attempt_id: attempt_id,
          reason: reason
        })

      if retirement_evidence_transferred?(retirement) do
        :ok
      else
        {:error, {:provisional_retirement_failed, retirement}}
      end
    end
  end

  defp tombstone_active_binding(agent_uri) do
    case RecipeCapBinding.fetch(agent_uri) do
      :not_found -> :ok
      {:ok, binding} -> RecipeCapBinding.tombstone_if_version(agent_uri, binding.version)
    end
  end

  defp retirement_evidence_transferred?({:ok, %{cleanup: :complete}}), do: true

  defp retirement_evidence_transferred?(
         {:partial, %{cleanup: :pending, obligation_id: obligation_id}}
       )
       when is_integer(obligation_id),
       do: true

  defp retirement_evidence_transferred?(_result), do: false

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

  defp credential_admission_of(agent) do
    case Map.get(agent, :credential_admission) ||
           Map.get(agent, "credential_admission") do
      value when value in [:before_session_join, "before_session_join"] ->
        :before_session_join

      _ ->
        :immediate
    end
  end

  defp active_admission(session_uri, role_name) do
    Enum.find(AgentAdmission.list(session_uri), &(&1.role_name == role_name))
  end

  defp maybe_clear_admission(session_uri, agent) do
    if credential_admission_of(agent) == :before_session_join,
      do: AgentAdmission.clear(session_uri, agent),
      else: :ok
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
