defmodule EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentLifecycle do
  @moduledoc false

  import EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentSupport

  alias Ezagent.ActionSet.Session.Members
  alias Ezagent.Agent.RecipeMaterializer
  alias Ezagent.Entity.Session.Orchestrator, as: SessionOrchestrator
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Invocation
  alias Ezagent.Session.Participants, as: SessionParticipants
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.Materializer
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @telemetry_prefix [:ezagent, :socialware, :definition_agents]
  @agent_description "socialware-declared agent materialized per-session (Definition.roles)"
  @role_member_attempts 100
  @role_member_poll_ms 10

  @doc false
  @spec materialize_at_planned_uri(
          URI.t(),
          URI.t(),
          URI.t(),
          map(),
          map(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          URI.t()
        ) :: {:ok, URI.t()} | {:skip, term()} | {:error, term()}
  def materialize_at_planned_uri(
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
  @spec refresh_existing_binding(URI.t(), URI.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def refresh_existing_binding(workspace_uri, agent_uri, recipe_name, role_name) do
    with {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         {:ok, _binding} <- bind_recipe_caps(agent_uri, recipe_name, recipe),
         :ok <- RecipeCapBinding.sync_live(agent_uri) do
      :ok
    else
      {:error, reason} -> {:error, {:agent_recipe_binding_refresh_failed, role_name, reason}}
    end
  end

  @doc false
  @spec after_materialize(URI.t(), URI.t(), URI.t(), map(), URI.t()) ::
          :ok | {:error, term()}
  def after_materialize(session_uri, workspace_uri, granted_by, agent, agent_uri) do
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
         {:ok, connection} <-
           Ezagent.Agent.CredentialConnection.for_flavor(flavor, role: declaration),
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
             provider,
             provisional_content_overrides(connection)
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
      false -> {:error, :role_does_not_require_agent_admission}
      {:error, _reason} = error -> error
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
        :ok -> after_materialize(session_uri, workspace_uri, granted_by, declaration, agent_uri)
        {:error, _reason} = error -> error
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

    with :ok <-
           validate_provisional_cleanup(attempt_id, agent_uri, provenance_root, workspace_uri),
         :ok <- tombstone_active_binding(agent_uri),
         :ok <- remove_fresh_member(session_uri, agent_uri) do
      retirement =
        Ezagent.Domain.Agent.retire_spawned(agent_uri, %{
          caller: Map.fetch!(ctx, :caller),
          authenticated_principal: Map.fetch!(ctx, :authenticated_principal),
          caps:
            ctx
            |> Map.fetch!(:caps)
            |> Enum.concat(SessionCreator.list_caps_for_materialization(provenance_root))
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

  defp spawn_fresh_at_planned_uri(
         session_uri,
         workspace_uri,
         granted_by,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider,
         planned_uri
       ) do
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

  defp check_credential_source(installer, workspace_uri, flavor) do
    if Ezagent.Agent.CredentialPrecondition.credential_bearing?(flavor) do
      Ezagent.Agent.CredentialPrecondition.check_source(installer, workspace_uri, flavor)
    else
      :ok
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
             provider,
             session_member_content_overrides()
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

      {:error, reason} = error ->
        case RecipeMaterializer.rollback_fresh_agent(fresh_receipt, nil) do
          {:ok, :retired} -> error
          {:error, rollback_reason} -> {:error, {reason, {:rollback_failed, rollback_reason}}}
        end
    end
  end

  defp validate_provisional_cleanup(attempt_id, agent_uri, provenance_root, workspace_uri) do
    with {:ok, _entry} <-
           Ezagent.Agent.CreationInventory.exact(
             attempt_id,
             agent_uri,
             provenance_root,
             workspace_uri
           ) do
      case Ezagent.AgentLineage.lookup(agent_uri) do
        {:ok, current_root} ->
          if same_uri?(current_root, provenance_root) do
            :ok
          else
            {:error, {:provisional_lineage_mismatch, current_root}}
          end

        :error ->
          {:error, :provisional_lineage_not_found}
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

  defp maybe_after_orchestrator_materialize(
         session_uri,
         workspace_uri,
         granted_by,
         agent,
         agent_uri
       ) do
    if orchestrator_recipe_slot?(agent) do
      parent_template_uri = parent_template_uri_for(session_uri)

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

  defp parent_template_uri_for(%URI{} = session_uri) do
    case SessionOrchestrator.read_template_working_copy(session_uri) do
      %{session_template_uri: %URI{} = uri} -> uri
      %{"session_template_uri" => %URI{} = uri} -> uri
      %{session_template_uri: uri} when is_binary(uri) and uri != "" -> Ezagent.URI.new!(uri)
      %{"session_template_uri" => uri} when is_binary(uri) and uri != "" -> Ezagent.URI.new!(uri)
      _ -> Ezagent.URI.template(:system, :session, "default")
    end
  rescue
    _ -> Ezagent.URI.template(:system, :session, "default")
  end

  defp spawn_agent(
         workspace_uri,
         granted_by,
         planned_uri,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider,
         template_content_overrides
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
      template_content_overrides: template_content_overrides
    }

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

  defp provisional_content_overrides({:pty, _descriptor}) do
    session_member_content_overrides()
    |> Map.put(:credential_bootstrap, :pty)
  end

  defp provisional_content_overrides(_connection), do: session_member_content_overrides()

  defp session_member_content_overrides do
    %{
      credential_optional: true,
      credential_source_policy: :session_local,
      session_template_member: true
    }
  end

  defp join_or_cleanup(session_uri, %URI{} = member_uri, role_name, recipe) do
    if passive_recipe?(recipe), do: :ok, else: do_join(session_uri, member_uri, role_name)
  end

  defp do_join(session_uri, %URI{} = member_uri, role_name) do
    case join_member(session_uri, member_uri, role_name) do
      :ok -> :ok
      {:error, reason} -> {:error, {:agent_join_failed, role_name, reason}}
    end
  end

  defp maybe_await_role_member(session_uri, member_uri, role_name, recipe) do
    if passive_recipe?(recipe) do
      :ok
    else
      await_role_membership(session_uri, member_uri, role_name)
    end
  end

  @doc false
  def await_role_membership(session_uri, planned_uri, role_name) do
    case await_role_member(session_uri, planned_uri, role_name) do
      :ok -> :ok
      {:error, reason} -> {:error, {:agent_membership_convergence_failed, role_name, reason}}
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

  @doc false
  def bind_recipe_caps(%URI{} = agent_uri, recipe_name, recipe) do
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
      {:error, rollback_reason} -> {:error, {reason, {:rollback_failed, rollback_reason}}}
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

  @doc false
  def read_members(%URI{} = session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, chat_slice} -> Map.get(chat_slice, :members, %{})
      {:error, _reason} -> %{}
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)
end
