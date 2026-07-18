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
    3. **issue + bind** — resolve the recipe caps, run complete `Cap.issue`
       authorization under the canonical admin issuer, and atomically upsert the
       issued artifacts in the identity tier before any spawn.
    4. **spawn** — recipe × declared flavor (default `cc`) →
       `Agent.spawn_from_template_content` at a fresh uuid agent URI.
    5. **join + cleanup** — faceted `session.join` carrying `%{role_name: name}`;
       on a definitive spawn/join failure terminate the worker and conditionally
       tombstone the exact binding version.
    6. **no post-spawn recipe grant** — `create/1` self-stores the exact issued
       artifacts from the binding. The recipe-cap path never drives a cap write
       into the new agent and therefore never waits for its transport readiness.
       The separate orchestrator-scoped post-hook remains an S7 cutover.

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
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Invocation
  alias Ezagent.Orchestrator.Tools.Participants
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.Materializer
  alias Mix.Tasks.Ezagent.Agent.GrantRecipeCaps

  @telemetry_prefix [:ezagent, :socialware, :definition_agents]
  @agent_description "socialware-declared agent materialized per-session (Definition.roles)"

  @doc """
  Materialize agent role slots into `session_uri`. `granted_by` is the session owner
  (the #154-clean grant/spawn root). Idempotent on the repair/restart path.

  Returns `{:ok, summary}` where `summary` is
  `%{satisfied: [role_name], skipped: [%{role_name:, reason:}]}`.

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

              {:skip, reason} ->
                report_skip(session_uri, role_name, reason)

                {:cont,
                 {:ok, seen, installed, [%{role_name: role_name, reason: reason} | skipped],
                  role_members}}

              {:error, reason} ->
                partial = %{
                  satisfied: Enum.reverse(installed),
                  skipped: Enum.reverse(skipped)
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

          {:skip, _reason} = skip ->
            skip

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
         {:ok, planned_uri} <-
           planned_uri_for_role(session_uri, workspace_uri, agent, role_name, recipe),
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
         # logged in": skip the slot rather than join a silent zombie. The role
         # slot's `provider` (cc-custom) names the backend profile whose env key
         # gates this check; plain-cc/legacy slots carry none (opt NOT passed).
         :ok <- check_credential_source(granted_by, workspace_uri, flavor, provider),
         # S5 I9/C2: complete Cap.issue authorization and commit the durable
         # identity-tier binding before Kind.spawn. No DB transaction spans the
         # spawn. create/1 can therefore self-store the issued artifacts.
         {:ok, binding} <- bind_recipe_caps(planned_uri, recipe_name, recipe),
         :ok <-
           spawn_bound_agent(
             session_uri,
             granted_by,
             planned_uri,
             recipe,
             recipe_name,
             role_name,
             flavor,
             provider,
             binding
           ) do
      {:ok, planned_uri}
    end
  end

  # The cc-custom seam: only a non-empty role-slot `provider` passes the
  # `backend_profile` opt down — plain-cc/legacy slots call the unchanged
  # `check_source/3` path (byte-unchanged legacy behavior).
  defp check_credential_source(installer, workspace_uri, flavor, provider)
       when is_binary(provider) and provider != "",
       do:
         CredentialPrecondition.check_source(installer, workspace_uri, flavor,
           backend_profile: provider
         )

  defp check_credential_source(installer, workspace_uri, flavor, _no_provider),
    do: CredentialPrecondition.check_source(installer, workspace_uri, flavor)

  defp spawn_bound_agent(
         session_uri,
         granted_by,
         planned_uri,
         recipe,
         recipe_name,
         role_name,
         flavor,
         provider,
         binding
       ) do
    workspace_uri = Ezagent.Capability.workspace_of(planned_uri)

    result =
      with :ok <-
             spawn_agent(
               workspace_uri,
               granted_by,
               planned_uri,
               recipe,
               recipe_name,
               role_name,
               flavor,
               provider
             ),
           # Safety net for the class the pre-flight cannot see (#1311).
           # This agent was just spawned by us — if it has no credentials,
           # terminate it (it was never joined). REUSE path leaves its agent.
           :ok <- verify_credentials_on_fresh(planned_uri, flavor),
           :ok <- join_or_cleanup(session_uri, planned_uri, role_name, recipe) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:skip, _reason} = skip ->
        compensate_recipe_binding(planned_uri, binding)
        skip

      {:error, _reason} = error ->
        compensate_recipe_binding(planned_uri, binding)
        error
    end
  end

  # For the FRESH path only: the agent was just spawned by us, so a credential
  # skip tears it down. The REUSE path must NEVER terminate the pre-existing agent
  # (it belongs to someone else — CRITICAL, codex r2).
  defp verify_credentials_on_fresh(%URI{} = agent_uri, flavor) do
    case CredentialPrecondition.check_materialized(agent_uri, flavor) do
      :ok ->
        :ok

      {:skip, _reason} = skip ->
        _ = terminate_worker(agent_uri)
        skip
    end
  end

  # For the REUSE path: skip the reuse but leave the existing agent alive.
  defp verify_credentials_on_reuse(%URI{} = agent_uri, flavor) do
    case CredentialPrecondition.check_materialized(agent_uri, flavor) do
      :ok -> :ok
      {:skip, _reason} = skip -> skip
    end
  end

  defp reuse_existing_agent(session_uri, workspace_uri, operator, agent, recipe_name, role_name) do
    with %URI{} = agent_uri <- reuse_agent_uri_of(agent),
         :ok <- ensure_reuse_recipe_match(agent_uri, recipe_name, role_name),
         # Chain C — a reused agent may be a legacy zombie. Verify its config
         # home before joining it; on skip, LEAVE the agent alive (it is not ours
         # to destroy — CRITICAL, codex r2).
         :ok <- verify_credentials_on_reuse(agent_uri, flavor_of(agent)),
         {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         # A reused agent already exists, so I9's pre-spawn ordering does not
         # apply. Bind only after a successful join: an unrelated join failure
         # must never tombstone or overwrite that agent's pre-existing binding.
         {:ok, ^agent_uri} <-
           Participants.add_participant(agent_uri, role_name,
             caller: operator,
             caps: reuse_caps(session_uri, operator),
             workspace_uri: workspace_uri,
             session_uri: session_uri,
             in_session_template: true
           ),
         {:ok, _binding} <- bind_recipe_caps(agent_uri, recipe_name, recipe) do
      {:ok, agent_uri}
    else
      nil -> {:error, {:invalid_reuse_agent_uri, role_name}}
      {:skip, _reason} = skip -> skip
      {:error, _} = error -> error
      other -> {:error, {:reuse_agent_join_failed, role_name, other}}
    end
  end

  defp maybe_after_materialize(session_uri, workspace_uri, granted_by, agent, agent_uri) do
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
      caps: SessionCreator.list_caps_for_materialization(granted_by),
      source_template_uri: source_template_uri,
      description: @agent_description
    }

    # The cc-custom seam: the role slot's selected backend profile rides into
    # the materialized content's `provider` — only when the slot declares one
    # (plain-cc/legacy slots keep the byte-unchanged opts map).
    spawn_opts =
      case provider do
        p when is_binary(p) and p != "" -> Map.put(spawn_opts, :provider, p)
        _ -> spawn_opts
      end

    case Ezagent.Agent.RecipeMaterializer.create_agent_from_recipe(spawn_opts) do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        # SKIP vs FAIL (chain C contract, §"Skip vs fail"): a spawn that
        # fails BECAUSE the flavor has no credential in this environment is the
        # SAME "credential-less role → SKIP, not fatal" class the pre-flight
        # `CredentialPrecondition.check_source/3` catches — it just surfaces one
        # layer later, at spawn, for flavors whose credential is an ENV VAR
        # (the selected catalog profile's API-key var) rather than a config-home
        # FILE, so `check_source`
        # (file-based `credential_bearing?/1`) waves them through. Without this,
        # a keyless env (every CI without the profile's key) turns the
        # orchestrator slot into a HARD `{:agent_spawn_failed, …}` that halts the
        # whole batch (and, via the unhandled 3-tuple, CRASHED the install
        # transaction) — so a co-declared credential-less role (e.g. the py
        # helper) was never materialized. Classify it as a skip so the batch
        # continues and the durable `unfilled_agent_role_slots` record is written,
        # exactly as a file-credential-missing role already is.
        if credential_missing_spawn_reason?(reason) do
          {:skip, {:no_credential_source, flavor}}
        else
          {:error, {:agent_spawn_failed, role_name, reason}}
        end
    end
  end

  # NARROW by design: only a KNOWN missing-credential spawn reason reclassifies
  # to a skip. Every other spawn failure stays a hard error (a bug, not the
  # environment — §"Skip vs fail"). Env-var-credential flavors (the cc-custom
  # catalog profiles) fail this way; file-credential
  # flavors are already pre-skipped by `CredentialPrecondition.check_source/3`.
  defp credential_missing_spawn_reason?({:backend_api_key_missing, _, _}), do: true
  defp credential_missing_spawn_reason?({:backend_api_key_missing, _}), do: true
  defp credential_missing_spawn_reason?(_), do: false

  # Faceted `session.join` carrying the `%{role_name: name}` facet. On failure,
  # terminate the worker we just spawned (the add_managed_member cleanup
  # envelope) so a denied/failed join never leaves an orphan.
  defp join_or_cleanup(session_uri, %URI{} = member_uri, role_name, recipe)
       when is_map(recipe) do
    if passive_recipe?(recipe) do
      :ok
    else
      do_join_or_cleanup(session_uri, member_uri, role_name)
    end
  end

  defp do_join_or_cleanup(session_uri, %URI{} = member_uri, role_name) do
    case join_member(session_uri, member_uri, role_name) do
      :ok ->
        :ok

      {:error, reason} ->
        _ = terminate_worker(member_uri)
        {:error, {:agent_join_failed, role_name, reason}}
    end
  end

  defp join_member(%URI{} = session_uri, %URI{} = member_uri, role_name) do
    _ = Ezagent.Domain.Agent.ensure_declared_member(member_uri)
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

  # --- durable recipe-cap binding -------------------------------------------

  defp refresh_existing_binding(workspace_uri, agent_uri, recipe_name, role_name) do
    with {:ok, recipe} <- lookup_recipe(workspace_uri, recipe_name),
         {:ok, _binding} <- bind_recipe_caps(agent_uri, recipe_name, recipe) do
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

  defp compensate_recipe_binding(%URI{} = agent_uri, %{version: version}) do
    case RecipeCapBinding.tombstone_if_version(agent_uri, version) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "recipe-cap binding compensation FAILED for #{inspect(agent_uri)} " <>
            "version=#{version}: #{inspect(reason)} — tombstone GC must retry"
        )

        :ok
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

  # The role slot's OPTIONAL cc-custom backend profile (atom or string key).
  # Absent/empty → nil: plain-cc and legacy slots carry no profile, and the
  # credential seams below must see NO opt at all (byte-unchanged behavior).
  defp provider_of(agent) do
    case Map.get(agent, :provider) || Map.get(agent, "provider") do
      provider when is_binary(provider) and provider != "" -> provider
      _ -> nil
    end
  end
end
