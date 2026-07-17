defmodule Ezagent.Entity.Agent.TemplateSpawn do
  @moduledoc false

  @doc """
  Phase 7 completion PR-1 (SPEC §1.6a) — spawn a worker agent from an
  AgentTemplate's `:template` slice CONTENT, delegating the launch to
  the flavor's plugin Template Class and re-establishing the post-spawn
  obligations (lineage + workspace binding) the Class does not perform.

  This is the **content-taking** spawn helper. It takes the template
  content as an ARGUMENT — it does NOT dispatch `:read` (the
  `Ezagent.ActionSet.Template` `:instantiate` action that calls it is
  ALREADY running inside the AgentTemplate Kind process with the slice
  in hand; a `:read` self-dispatch would be a `GenServer.call(self)`
  deadlock — codex rev-5 HIGH-2).

  ## Contract (SPEC §1.6a)

  1. **Look up the Class** — from `content.flavor`,
     `Ezagent.AgentFlavorRegistry.lookup/1` → `%{template_class: tc}`.
  2. **Build the Class data map** — `AgentTemplate.to_template_data/2`
     (§1.5 adapter) from the content + `instance_uri`.
  3. **Delegate the launch** — `tc.instantiate(tc.template_name(),
     data, workspace_uri)` → `{:ok, [worker_uri]}` (the plugin owns
     exactly this — the Agent Kind + PTY).
  4. **Record lineage (helper-owned, fresh-only)** — for each returned
     `worker_uri`, `Ezagent.AgentLineage.record(worker_uri,
     spawned_by_uri)`. The plugin Template Class does NOT do this, so
     cap #2 (`{:spawned_by, orchestrator}`) would never resolve without
     this step. Runs ONLY when `fresh?: true` (see codex round-7 below).
  5. **Bind workspace (helper-owned, fresh-only)** — for each
     `worker_uri`, `Ezagent.WorkspaceRegistry.bind(worker_uri,
     workspace_uri)` (invariant 4 — workspace-scoped routing rules must
     fire). Runs ONLY when `fresh?: true` (see codex round-7 below).

  NO `:read` dispatch anywhere.

  ## Args

  - `template_content_map` — the AgentTemplate `:template` slice content
    (carries `flavor`, `project_cwd`, the sandbox keys incl. `config_dir`).
  - `instance_uri` — the per-instance agent URI the caller built.
  - `spawned_by_uri` — `%URI{}` of the principal authorizing the spawn
    (the owner for the orchestrator agent; the orchestrator's own URI
    for `add_agent_slot` workers, so cap #2 resolves).
  - `workspace_uri` — `%URI{}` scope the worker belongs to.

  ## Return — the fresh-vs-adopted signal (codex round-5 MEDIUM-3, round-6 HIGH-1)

  `{:ok, %{workers: [worker_uri], fresh?: boolean()}}` on success,
  `{:error, reason}` otherwise.

  Every plugin `Ezagent.Kind.Template` `instantiate/3` is documented as
  IDEMPOTENT — re-calling after the Kinds are alive is a no-op that
  returns the SAME URIs. That idempotency is correct for the
  Workspace.Loader boot path, but it must not ERASE a signal
  `update_agent_template` needs: did THIS call freshly create the
  worker, or did it adopt a pre-existing one? (A concurrent spawn
  registering the candidate URI → `instantiate` silently adopts a
  worker the swap did NOT create; `record_lineage`/`bind_workspace`
  then mutate ownership for an adopted worker.)

  ## codex round-6 HIGH-1 — `fresh?` comes from the ATOMIC spawn result

  Round 5 reconstructed `fresh?` by probing `KindRegistry` for
  `instance_uri` BEFORE delegating to `template_class.instantiate/3`.
  That probe is a TOCTOU window: a concurrent registration BETWEEN the
  probe and the plugin's spawn makes an adopted worker read as fresh.

  Round 6 removes the window structurally. `Ezagent.Kind.Template`
  `instantiate/3` now returns the 3-element `{:ok, [URI.t()], %{fresh?:
  boolean()}}` form, where `fresh?` is derived from the ATOMIC
  `DynamicSupervisor.start_child` outcome (`SpawnRegistry.spawn_detailed/1`
  preserves `:started` vs `:already_started`) — exactly one concurrent
  caller wins the start. `spawn_from_template_content/4` reads `fresh?`
  from THAT result. No pre-probe; the check+spawn is atomic, so the
  window is removed, not narrowed.

  A Template Class returning the legacy 2-element `{:ok, [URI.t()]}`
  form supplies no `fresh?` — it is treated conservatively as `false`
  (the swap then errs on the side of refusing a possible adoption).

  ## codex round-7 HIGH-1 — side effects gated on `fresh?: true`

  Round 6 made `fresh?` an ATOMIC signal but still recorded lineage and
  bound the workspace for EVERY returned worker, BEFORE the caller saw
  `fresh?`. `AgentLineage.record/2` is an ETS set insert that OVERWRITES
  the worker's `spawned_by`, and `WorkspaceRegistry.bind/2` OVERWRITES
  the binding. So a `fresh?: false` worker — one created by some other
  operation, which `instantiate` merely ADOPTED — got re-parented under
  THIS orchestrator (its `{:spawned_by, orchestrator}` cap then matched!)
  and workspace-rebound, even though `update_agent_template` then
  correctly refused the adoption (`:candidate_uri_already_live`). The
  "safe-degraded" abort was not actually side-effect-free.

  Round 7 gates the post-spawn obligations on `fresh?: true` — a worker
  THIS call created. A `fresh?: false` result is returned with the
  worker URI and ZERO side effects: the pre-existing worker's lineage +
  workspace binding are left exactly as they were. The swap's
  `:candidate_uri_already_live` abort is now genuinely side-effect-free.

  ## codex round-10 HIGH-2 — a post-spawn failure undoes the fresh spawn

  Round 7 ran the post-spawn obligations as `:ok = record_lineage(...)`
  / `:ok = bind_workspace(...)`. A `bind_workspace/2` failure AFTER a
  successful `record_lineage/2` would (a) RAISE on the `:ok =` match —
  an exception, not a clean `{:error, _}` — and (b) leave the freshly
  created worker with a lineage row but no workspace binding: residue
  the caller could not see or clean.

  Round 10 makes this helper own its own partial-spawn teardown. The
  obligations run as a CHECKED step (`establish_post_spawn_obligations/3`);
  on ANY failure after the plugin Template Class freshly created the
  worker, this helper undoes everything IT established for that worker —
  terminate the Kind, forget the lineage row, unbind the workspace
  (`undo_fresh_workers/1`) — and returns a clean `{:error, reason}`. A
  fresh `spawn_from_template_content/4` therefore either fully succeeds
  or leaves ZERO residue: combined with the plugin Template Class
  cleaning up its own freshly-started-then-failed Kind (cc/echo round
  10), a per-slot instantiate is all-or-nothing, so the Generator's
  `instantiate_agent_slots/4` `acc`-only accumulator (round 9) is
  correct — a failed slot has already self-cleaned.
  """
  @spec spawn_from_template_content(map(), URI.t(), URI.t(), URI.t()) ::
          {:ok,
           %{
             :workers => [URI.t()],
             :fresh? => boolean(),
             optional(:role_degraded) => boolean(),
             optional(:role_degraded_reason) => term()
           }}
          | {:error, term()}
  def spawn_from_template_content(
        template_content_map,
        %URI{} = instance_uri,
        %URI{} = spawned_by_uri,
        %URI{} = workspace_uri
      ) do
    spawn_from_template_content(
      template_content_map,
      instance_uri,
      spawned_by_uri,
      workspace_uri,
      []
    )
  end

  def spawn_from_template_content(_content, _instance, _spawned_by, _workspace) do
    {:error, :invalid_spawn_from_template_content_args}
  end

  @doc """
  2026-06-07 file-flavor-create-cascade — content→data conversion ONLY, with NO
  cascade resolution. Used by the Workspace boot Loader to replay a persisted
  file-flavor CONTENT template (`flavor`/`project_cwd`/`config_dir`) into the
  Template-Class DATA shape so `provision_and_instantiate/4` can allocate the
  isolated config_dir + spawn the Kind.

  The boot Loader MUST NOT run the credential cascade: the cascade keys off the
  agent OWNER, and at cold boot the dispatch runs under the workspace's own boot
  self-authority, NOT the human who originally created the agent — resolving a
  user-default under the wrong owner would be incorrect. Credential
  re-resolution at cold restart is the Agent Kind's `Sandbox.activate →
  ensure_subprocess_alive → CascadeRuntime` self-heal, which reads the ORIGINAL
  owner from the persisted Sandbox-slice `cascade_resolution`. This function is
  the cascade-free conversion the Loader uses instead.
  """
  @spec content_to_template_data(map(), URI.t()) :: {:ok, map()} | {:error, term()}
  def content_to_template_data(content, %URI{} = instance_uri) when is_map(content) do
    Ezagent.Entity.AgentTemplate.to_template_data(content, instance_uri)
  end

  @doc """
  Spawn an agent from an AgentManifest executor.

  This wraps the existing `spawn_from_template_content/5` path: each executor
  candidate is rendered into transient AgentTemplate content, then delegated to
  the normal spawn/rollback machinery. `fresh?: false` is a success because the
  worker is already live at the target URI.
  """
  @spec spawn_from_manifest(
          Ezagent.AgentManifest.t(),
          map(),
          URI.t(),
          URI.t(),
          URI.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def spawn_from_manifest(
        manifest,
        slots,
        instance_uri,
        spawned_by_uri,
        workspace_uri,
        opts \\ []
      )

  def spawn_from_manifest(
        %Ezagent.AgentManifest{} = manifest,
        slots,
        %URI{} = instance_uri,
        %URI{} = spawned_by_uri,
        %URI{} = workspace_uri,
        opts
      )
      when is_map(slots) and is_list(opts) do
    spawn_fun =
      Keyword.get(opts, :spawn_fun, fn content, uri, spawned_by, workspace, spawn_opts ->
        spawn_from_template_content(content, uri, spawned_by, workspace, spawn_opts)
      end)

    spawn_opts = Keyword.delete(opts, :spawn_fun)

    try_manifest_flavors(
      manifest.executor.flavor,
      manifest,
      slots,
      instance_uri,
      spawned_by_uri,
      workspace_uri,
      spawn_opts,
      spawn_fun,
      []
    )
  end

  def spawn_from_manifest(_manifest, _slots, _instance, _spawned_by, _workspace, _opts),
    do: {:error, :invalid_spawn_from_manifest_args}

  @doc false
  @spec spawn_from_template_content(map(), URI.t(), URI.t(), URI.t(), keyword()) ::
          {:ok,
           %{
             :workers => [URI.t()],
             :fresh? => boolean(),
             optional(:role_degraded) => boolean(),
             optional(:role_degraded_reason) => term()
           }}
          | {:error, term()}
  def spawn_from_template_content(
        template_content_map,
        %URI{} = instance_uri,
        %URI{} = spawned_by_uri,
        %URI{} = workspace_uri,
        opts
      )
      when is_map(template_content_map) and is_list(opts) do
    {pre_start_ref, opts} = Keyword.pop(opts, :pre_start_ref)
    behavior_overlay = Keyword.get(opts, :behavior_overlay, [])

    with {:ok, template_class} <-
           Ezagent.Entity.AgentTemplate.resolve_template_class(template_content_map),
         {:ok, flavor} <- template_content_flavor(template_content_map),
         # `resolve_cascade_content` is the grant-MINT boundary. Its own failures
         # (incl. a unique-constraint insert conflict from a concurrent duplicate
         # create — where the WINNER owns the row, not this call) must NOT trigger
         # the grant cleanup below: this call did not successfully mint, so deleting
         # would erase the winner's grant (codex r6 HIGH — race). So it stays in the
         # OUTER `with`, whose `else` returns the error WITHOUT deleting any grant.
         {:ok, template_content_map} <-
           resolve_cascade_content(
             template_content_map,
             template_class,
             instance_uri,
             spawned_by_uri,
             workspace_uri,
             flavor,
             opts
           ),
         # Past the mint boundary: from here, ANY failure is owned by THIS call
         # (this call minted the grant, if any), so the grant cleanup is safe. The
         # nested `with` scopes the grant-delete to exactly these post-mint steps.
         {:ok, result} <-
           spawn_after_cascade(
             template_class,
             template_content_map,
             instance_uri,
             spawned_by_uri,
             workspace_uri,
             flavor,
             behavior_overlay,
             pre_start_ref
           ) do
      {:ok, result}
    end
  end

  def spawn_from_template_content(_content, _instance, _spawned_by, _workspace, _opts) do
    {:error, :invalid_spawn_from_template_content_args}
  end

  defp try_manifest_flavors(
         [],
         _manifest,
         _slots,
         _instance_uri,
         _spawned_by_uri,
         _workspace_uri,
         _spawn_opts,
         _spawn_fun,
         attempts
       ) do
    {:error, {:no_backend, Enum.reverse(attempts)}}
  end

  defp try_manifest_flavors(
         [flavor | rest],
         manifest,
         slots,
         instance_uri,
         spawned_by_uri,
         workspace_uri,
         spawn_opts,
         spawn_fun,
         attempts
       ) do
    with {:ok, content} <-
           Ezagent.AgentManifest.to_template_content(
             manifest,
             flavor,
             slots,
             candidate_params(manifest, flavor)
           ) do
      case spawn_fun.(content, instance_uri, spawned_by_uri, workspace_uri, spawn_opts) do
        {:ok, result} when is_map(result) ->
          {:ok, Map.put(result, :chosen_flavor, flavor)}

        {:error, reason} ->
          try_manifest_flavors(
            rest,
            manifest,
            slots,
            instance_uri,
            spawned_by_uri,
            workspace_uri,
            spawn_opts,
            spawn_fun,
            [{flavor, reason} | attempts]
          )
      end
    end
  end

  defp candidate_params(%Ezagent.AgentManifest{} = manifest, flavor) do
    manifest.executor.fallback
    |> List.wrap()
    |> Enum.find_value(%{}, fn
      %{} = candidate ->
        candidate_flavor = Map.get(candidate, "flavor") || Map.get(candidate, :flavor)

        if candidate_flavor == flavor do
          Map.get(candidate, "params") || Map.get(candidate, :params) || %{}
        end

      _ ->
        nil
    end)
  end

  # Post-grant-mint spawn steps. ANY failure here is owned by THIS call (the grant
  # was just minted by this call's `resolve_cascade_content`), so on failure we
  # HARD-delete the grant — leaving zero residue — via `revoke_cascade_grant_best_effort/1`.
  # This is the ONLY grant-cleanup site (the pre-mint outer `with` must not delete).
  defp spawn_after_cascade(
         template_class,
         template_content_map,
         instance_uri,
         spawned_by_uri,
         workspace_uri,
         flavor,
         behavior_overlay,
         pre_start_ref
       ) do
    with {:ok, data} <-
           Ezagent.Entity.AgentTemplate.to_template_data(template_content_map, instance_uri) do
      previous_flavor = Ezagent.AgentFlavorAttributes.get(instance_uri)

      case instantiate_workers(template_class, data, workspace_uri, pre_start_ref) do
        {:ok, workers, false, _instantiate_meta, %{claim: _claim} = pre_start_completion} ->
          result =
            finalize_pre_start(
              pre_start_completion,
              {:ok, %{workers: workers, fresh?: false}}
            )

          revoke_cascade_grant_best_effort(instance_uri)
          restore_agent_flavor(instance_uri, previous_flavor)
          result

        {:ok, workers, fresh?, instantiate_meta, pre_start_completion} ->
          run_after_prepare(pre_start_completion, fn ->
            complete_spawn_obligations(
              template_class,
              template_content_map,
              instance_uri,
              spawned_by_uri,
              workspace_uri,
              flavor,
              behavior_overlay,
              workers,
              fresh?,
              instantiate_meta
            )
          end)

        {:error, reason, pre_start_completion} ->
          revoke_cascade_grant_best_effort(instance_uri)
          Ezagent.AgentFlavorAttributes.delete(instance_uri)
          finalize_pre_start(pre_start_completion, {:error, reason})

        {:error, reason} ->
          revoke_cascade_grant_best_effort(instance_uri)
          Ezagent.AgentFlavorAttributes.delete(instance_uri)
          {:error, reason}

        {:raised, kind, reason, stacktrace, pre_start_completion} ->
          finish_after_prepare(
            pre_start_completion,
            {:raised, kind, reason, stacktrace}
          )
      end
    else
      {:error, _reason} = err ->
        revoke_cascade_grant_best_effort(instance_uri)
        Ezagent.AgentFlavorAttributes.delete(instance_uri)
        err
    end
  end

  defp complete_spawn_obligations(
         template_class,
         template_content_map,
         instance_uri,
         spawned_by_uri,
         workspace_uri,
         flavor,
         behavior_overlay,
         workers,
         fresh?,
         instantiate_meta
       ) do
    instantiate_meta = put_respawn_flavor(instantiate_meta, template_content_map)

    # codex PR #408 review HIGH-3 — surface role-bootstrap degradation
    # from the plugin Template Class's instantiate meta. The plugin
    # (cc) attaches `:role_degraded` + `:role_degraded_reason` keys to
    # its meta when an orchestrator skill-bootstrap step failed but
    # the agent itself was still spawned successfully. We propagate
    # them so the orchestrator-aware caller (Session.ensure_orchestrator)
    # can notify the session owner per Invariant #9.
    role_degraded_passthrough =
      instantiate_meta
      |> Map.take([
        :role_degraded,
        :role_degraded_reason,
        # #17 (c) — spawn-time OAuth credential-staleness reminder, propagated on
        # the same owner-surfacing path as role_degraded.
        :credential_stale,
        :credential_stale_reason
      ])
      |> case do
        map when map_size(map) == 0 -> %{}
        map -> map
      end

    # codex round-7 HIGH-1 — the post-spawn obligations (lineage +
    # workspace binding) are side effects that OVERWRITE existing rows:
    # `AgentLineage.record/2` is an ETS set insert (re-parents the
    # worker under `spawned_by_uri`) and `WorkspaceRegistry.bind/2`
    # overwrites the binding. They must run ONLY for a worker THIS call
    # actually created — `fresh?: true`.
    #
    # When `fresh?: false`, the instantiate ADOPTED a pre-existing
    # worker (one created by some other operation — e.g. a concurrent
    # spawn). Recording lineage / binding workspace for it would
    # re-parent a worker this call did NOT create. `update_agent_template`
    # then correctly refuses the adoption (`require_fresh_candidate/1` →
    # `:candidate_uri_already_live`), but the damage would already be
    # done. So a `fresh?: false` result returns the worker URI with
    # ZERO side effects — the pre-existing worker's lineage + workspace
    # binding are left exactly as they were, making the swap's abort
    # genuinely side-effect-free.
    # codex round-10 HIGH-2 — the post-spawn obligations are now a
    # CHECKED step that self-cleans on failure. Pre-round-10 this was
    # `:ok = record_lineage(...)` / `:ok = bind_workspace(...)` — if
    # `bind_workspace/2` failed AFTER `record_lineage/2` succeeded, the
    # `:ok =` match RAISED (an exception, not a clean `{:error, _}`)
    # and left a worker that the plugin Template Class freshly created
    # WITH a lineage row but WITHOUT a workspace binding — a residue
    # the caller could not see. Now: if a step AFTER the fresh spawn
    # fails, `spawn_from_template_content/4` undoes everything IT
    # established for the worker it created — terminate the Kind
    # (`Ezagent.Kind.terminate/1`), forget the lineage row, unbind the
    # workspace — and returns a clean `{:error, reason}`. A fresh
    # instantiate therefore either fully succeeds or leaves ZERO
    # residue. (`fresh?: false` adopts a pre-existing worker — no
    # obligations run, nothing to undo — round 7.)
    if fresh? do
      # PR3 2026-05-24 — `record_sandbox_state/3` is a NEW CHECKED step
      # after post-spawn obligations: dispatches `sandbox.update_config`
      # on each worker so its `:sandbox` slice carries the per-agent
      # config_dir + template_class. Without this, a destroy_config_dir
      # callback later cannot know what to clean up.
      #
      # A failure here triggers `undo_fresh_workers/1` (same Round-10
      # rollback as a post-spawn-obligation failure): terminate the
      # worker, unbind workspace, forget lineage, AND (cc-specific)
      # the plugin's own `rollback_agent_config_dir` already ran
      # inside `instantiate/3` if PTY failed there. Here we additionally
      # delete the dir we just created if the update_config dispatch
      # itself fails — otherwise the agent terminates but the dir
      # leaks because `Sandbox.invoke(:destroy, ...)` would never run
      # (the agent never even came up).
      with :ok <-
             establish_ownership_obligations(
               workers,
               spawned_by_uri,
               workspace_uri,
               Map.get(instantiate_meta, :creation_attempt_id)
             ),
           :ok <- record_sandbox_state(workers, instantiate_meta, template_class),
           :ok <- mount_behavior_overlay(workers, behavior_overlay) do
        :ok = Ezagent.AgentFlavorAttributes.put(instance_uri, flavor)
        {:ok, Map.merge(%{workers: workers, fresh?: fresh?}, role_degraded_passthrough)}
      else
        {:error, reason} ->
          undo_fresh_workers(workers)
          cleanup_partial_config_dirs(workers, template_class)
          Ezagent.AgentFlavorAttributes.delete(instance_uri)
          # codex r5 HIGH — the #17 grant was minted in `resolve_cascade_content`
          # BEFORE instantiate; a post-spawn failure must not leave an orphaned
          # GrantRow (unique by agent_uri → would poison retries + leave a stale
          # authorization/audit row for an agent that never came up).
          revoke_cascade_grant_best_effort(instance_uri)
          {:error, reason}
      end
    else
      # `fresh?: false` — adopted a pre-existing worker. Still
      # update_config so its slice reflects the (already-existing)
      # config_dir, but don't roll back on failure (we didn't create
      # the worker).
      _ = record_sandbox_state(workers, instantiate_meta, template_class)
      :ok = Ezagent.AgentFlavorAttributes.put(instance_uri, flavor)
      {:ok, Map.merge(%{workers: workers, fresh?: fresh?}, role_degraded_passthrough)}
    end
  end

  defp mount_behavior_overlay(_workers, []), do: :ok

  defp mount_behavior_overlay(workers, behaviors) when is_list(workers) and is_list(behaviors) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      case mount_behaviors(worker_uri, behaviors) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mount_behavior_overlay(_workers, overlay),
    do: {:error, {:invalid_behavior_overlay, overlay}}

  defp mount_behaviors(worker_uri, behaviors) do
    Enum.reduce_while(behaviors, :ok, fn behavior, :ok ->
      case Ezagent.Kind.mount(worker_uri, behavior, %{}) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:behavior_overlay_mount_failed, worker_uri, behavior, reason}}}
      end
    end)
  end

  # codex r5 HIGH — best-effort HARD-delete of the #17 credential grant for an
  # agent whose fresh spawn failed after the grant was minted. Delete (not soft
  # `revoke`) so the unique `agent_uri` key is freed and a later retry's
  # `GrantRow.insert/1` does not conflict (the agent never came up — no row should
  # survive). Idempotent: a no-op when no grant exists (e.g. no credential source
  # was resolved).
  defp revoke_cascade_grant_best_effort(%URI{} = agent_uri) do
    _ = Ezagent.Credential.GrantRow.delete(URI.to_string(agent_uri))
    :ok
  rescue
    _ -> :ok
  end

  defp template_content_flavor(template_content_map) when is_map(template_content_map) do
    case Map.get(template_content_map, :flavor) || Map.get(template_content_map, "flavor") do
      flavor when is_binary(flavor) and flavor != "" -> {:ok, flavor}
      _ -> {:error, :missing_flavor}
    end
  end

  defp resolve_cascade_content(
         content,
         template_class,
         agent_uri,
         spawned_by_uri,
         workspace_uri,
         flavor,
         opts
       ) do
    Ezagent.Entity.Agent.TemplateSpawn.Cascade.resolve_content(
      content,
      template_class,
      agent_uri,
      spawned_by_uri,
      workspace_uri,
      flavor,
      opts
    )
  end

  @doc false
  def sanitize_respawn_template_data(respawn_data, template_content) do
    Ezagent.Entity.Agent.TemplateSpawn.Cascade.sanitize_respawn_template_data(
      respawn_data,
      template_content
    )
  end

  defp put_respawn_flavor(meta, template_content_map) do
    Ezagent.Entity.Agent.TemplateSpawn.Cascade.put_respawn_flavor(meta, template_content_map)
  end

  # codex round-6 HIGH-1 + PR3 2026-05-24 — call the plugin Template
  # Class's `instantiate/3` and normalize its return to `{:ok, workers,
  # fresh?, meta}`. The 3-element `{:ok, workers, %{fresh?:, ...}}`
  # form carries the atomic fresh-vs-adopted signal AND any
  # plugin-supplied PR3-style per-spawn metadata (e.g.
  # `:config_dir_path` for cc). The legacy 2-element `{:ok, workers}`
  # form has no signal — `fresh?` defaults conservatively to `false`
  # and meta is an empty map.
  defp instantiate_workers(template_class, data, workspace_uri, nil) do
    case instantiate_workers_direct(template_class, data, workspace_uri) do
      {:ok, workers, fresh?, meta} -> {:ok, workers, fresh?, meta, nil}
      {:error, reason} -> {:error, reason, nil}
    end
  end

  defp instantiate_workers(template_class, data, %URI{} = workspace_uri, pre_start_ref) do
    with {:ok, %{cwd: cwd, claim: claim} = prepared} <-
           Ezagent.Kind.Template.PreStart.prepare(pre_start_ref) do
      completion = %{
        claim: claim,
        creation_attempt_id: Map.get(prepared, :creation_attempt_id)
      }

      launch_context = Map.get(prepared, :launch_context)

      try do
        case instantiate_workers_direct(
               template_class,
               Map.put(data, "cwd", cwd),
               workspace_uri,
               launch_context
             ) do
          {:ok, workers, fresh?, meta} ->
            meta = Map.put(meta, :creation_attempt_id, completion.creation_attempt_id)
            {:ok, workers, fresh?, meta, completion}

          {:error, reason} ->
            {:error, reason, completion}
        end
      rescue
        exception -> {:raised, :error, exception, __STACKTRACE__, completion}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__, completion}
      end
    end
  end

  defp instantiate_workers_direct(template_class, data, %URI{} = workspace_uri) do
    instantiate_workers_direct(template_class, data, workspace_uri, nil)
  end

  defp instantiate_workers_direct(template_class, data, %URI{} = workspace_uri, launch_context) do
    # PR-3 (domain.agent D2) — route through the core contract-boundary wrapper so
    # the per-agent config_dir TARGET is domain-allocated + provided as data
    # (`"allocated_config_dir"`) before the plugin materializes into it.
    opts = if is_nil(launch_context), do: [], else: [launch_context: launch_context]

    case Ezagent.Kind.Template.provision_and_instantiate(
           template_class,
           template_class.template_name(),
           data,
           workspace_uri,
           opts
         ) do
      {:ok, workers, meta} when is_list(workers) and is_map(meta) ->
        {:ok, workers, Map.get(meta, :fresh?, false) == true, meta}

      {:ok, workers} when is_list(workers) ->
        {:ok, workers, false, %{}}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_instantiate_result, other}}
    end
  end

  defp run_after_prepare(pre_start_completion, operation) do
    operation
    |> capture_operation()
    |> then(&finish_after_prepare(pre_start_completion, &1))
  end

  defp capture_operation(operation) do
    try do
      {:returned, operation.()}
    rescue
      exception ->
        {:raised, :error, exception, __STACKTRACE__}
    catch
      kind, reason ->
        {:raised, kind, reason, __STACKTRACE__}
    end
  end

  defp finish_after_prepare(pre_start_completion, {:returned, result}) do
    finalize_pre_start(pre_start_completion, result)
  end

  defp finish_after_prepare(pre_start_completion, {:raised, kind, reason, stacktrace}) do
    _ = complete_error_best_effort(pre_start_completion, kind, reason)
    :erlang.raise(kind, reason, stacktrace)
  end

  defp complete_error_best_effort(pre_start_completion, kind, reason) do
    try do
      finalize_pre_start(pre_start_completion, {:error, {kind, reason}})
    rescue
      _exception -> :completion_failed
    catch
      _kind, _reason -> :completion_failed
    end
  end

  defp restore_agent_flavor(instance_uri, {:ok, flavor}) do
    Ezagent.AgentFlavorAttributes.put(instance_uri, flavor)
  end

  defp restore_agent_flavor(instance_uri, :none) do
    Ezagent.AgentFlavorAttributes.delete(instance_uri)
  end

  defp finalize_pre_start(nil, result), do: result

  defp finalize_pre_start(%{claim: claim}, {:ok, %{workers: workers, fresh?: false}}) do
    case Ezagent.Kind.Template.PreStart.complete(
           claim,
           {:ok, %{workers: workers, fresh?: false}}
         ) do
      :ok -> {:error, :sidecar_start_not_fresh}
      {:error, _reason} = error -> error
    end
  end

  defp finalize_pre_start(%{claim: claim}, {:ok, %{workers: workers, fresh?: fresh?}} = result) do
    case Ezagent.Kind.Template.PreStart.complete(
           claim,
           {:ok, %{workers: workers, fresh?: fresh?}}
         ) do
      :ok -> result
      {:error, _reason} = error -> error
    end
  end

  defp finalize_pre_start(%{claim: claim}, {:error, reason} = result) do
    case Ezagent.Kind.Template.PreStart.complete(claim, {:error, reason}) do
      :ok -> result
      {:error, _reason} = error -> error
    end
  end

  # PR3 2026-05-24 — dispatch `sandbox.update_config` on each worker URI
  # so the agent's `:sandbox` slice carries the per-agent
  # `config_dir_path` + `template_class`. Both fields are needed by
  # `Sandbox.invoke(:destroy, ...)` to invoke the right cleanup callback
  # with the right path.
  #
  # Codex PR3 round-2 HIGH-1 — SKIP dispatch entirely when meta lacks
  # `:config_dir_path`. The :already_started loser path returns no
  # config_dir_path; if we still dispatched, we'd write `nil` into the
  # slice and CLOBBER the live state the :started winner just populated.
  # The result would be a slice with no path → destroy_config_dir would
  # never run → credential dir leaks.
  #
  # When meta carries :config_dir_path = nil EXPLICITLY (a plugin that
  # opted out of per-agent dirs, e.g. echo template returning
  # %{config_dir_path: nil}), we DO dispatch — recording that the
  # template_class manages no dir is a meaningful state. The "missing
  # key" vs "explicit nil" distinction is the gate.
  defp record_sandbox_state(workers, meta, template_class) do
    if Map.has_key?(meta, :config_dir_path) do
      do_record_sandbox_state(
        workers,
        Map.get(meta, :config_dir_path),
        template_class,
        # PTY-orphan-restart 2026-05-26 — the plugin Template Class
        # may also emit `:respawn_template_data` in meta (cc does;
        # echo doesn't). Passed through to `sandbox.update_config` so
        # the slice carries enough state for `Sandbox.post_init/2` to
        # respawn the subprocess on a phx restart. Absent in meta →
        # `nil` here → not written into the slice.
        Map.get(meta, :respawn_template_data)
      )
    else
      # Loser/short-circuit path: meta has no :config_dir_path → don't
      # touch the slice (it was populated by the winner OR was already
      # in the right state). No-op = safe.
      :ok
    end
  end

  defp do_record_sandbox_state(workers, config_dir, template_class, respawn_data) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      target = Ezagent.URI.new!("#{URI.to_string(worker_uri)}?action=sandbox.update_config")

      if sandbox_state_matches?(worker_uri, config_dir, template_class, respawn_data) do
        {:cont, :ok}
      else
        # codex E2E fix v2 Bug A (2026-05-29) — the Agent Kind was just
        # spawned by `template_class.instantiate/3`. `Kind.Server.init/1`
        # registers `:not_ready` synchronously and returns
        # `{:continue, :announce_ready}`; the `:ready` flip happens
        # asynchronously in `handle_continue` after the post-init Behavior
        # chain runs. The orchestrator-spawn path
        # (`Session.ensure_orchestrator` → `spawn_from_template_content` →
        # `record_sandbox_state`) hits this dispatch microseconds after
        # `start_link` returns — typically before the GenServer's
        # `handle_continue(:announce_ready, ...)` message has been
        # processed. A `:call` dispatch in that window fails fast with
        # `{:error, :not_ready}` (hard invariant #3, so the synchronous
        # caller doesn't block on `deadline_ms`), and the Sandbox slice's
        # `respawn_template_data` never gets written — which means
        # `Sandbox.post_init/2` cannot re-spawn the PTY subprocess on the
        # next phx restart. Allen e2e symptom 2026-05-28 was
        # `{:sandbox_update_config_failed, %URI{cc_orchestrator-main},
        # :not_ready}`.
        #
        # Bridge-backed cc agents are spawned with this sandbox state in their
        # Kind init args before transport readiness can hold ReadyGate at
        # `:not_ready`. The slice-match check above covers that case without
        # adding a core dispatch bypass; this fallback remains the normal
        # post-spawn write path for templates that do not initialize sandbox in
        # spawn args.
        #
        # FIRE-AND-FORGET (go-live 2026-07-06): do NOT block the spawning
        # caller on the agent reaching `:ready`. This shared spawn machinery
        # was tuned for the SYNCHRONOUS cc-orchestrator spawn (the 5s
        # `ReadyGate.await` above), but the socialware-install path reuses it
        # for role-slot agents of ANY flavor. A cold agent whose `activate`
        # provisions a heavy subprocess — e.g. the `np` recipe's first
        # `uv run` per container downloading numpy/sympy, measured ~9.6s —
        # would hold the await past the `create_session` dispatch budget
        # (`deadline_ms || 5000`), the observed "first socialware install per
        # boot times out at 5s" (install completed server-side regardless).
        #
        # Switch to `:cast`: a cast to a not-ready target is BUFFERED via
        # `PendingDelivery` (`invocation.ex` `{:not_ready, :cast}`) and
        # delivered once the agent flips `:ready`; a ready target gets it
        # immediately. Either way the spawning caller returns without
        # blocking — so we drop the `ReadyGate.await`. The `:sandbox` slice
        # write only feeds respawn-on-restart (`Sandbox.post_init/2`), which
        # ALSO self-heals via `ensure_subprocess_alive`/CascadeRuntime, so a
        # late (or, on a dead agent, dropped) write never corrupts a running
        # agent — hence no rollback-on-write-failure anymore.
        #
        # Self-authority (#154): `caller: worker_uri` dispatching to
        # `worker_uri?action=sandbox.update_config` IS the agent acting on
        # its OWN `:sandbox` slice (capbac.md §7 actor-self). The agent's own
        # `sandbox.update_config` cap is carried INLINE in `ctx.caps` (the
        # step-5.5 `granted_via_ctx_caps?` authorizer), scoped to this
        # specific agent; `granted_by` = the agent itself, never persisted
        # through `Ezagent.Identity.Grant`.
        admin = Ezagent.Entity.User.admin_uri()

        case Ezagent.Cap.issue_for_action({:admin, admin}, worker_uri, target) do
          {:ok, cap} ->
            _ =
              Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                target: target,
                mode: :cast,
                args: %{
                  config_dir_path: config_dir,
                  template_class: template_class,
                  respawn_template_data: respawn_data
                },
                ctx: %{
                  caller: worker_uri,
                  caps: [cap],
                  # `:ignore` — nobody awaits this write. `Kind.Server.handle_cast`
                  # unconditionally calls `Invocation.reply(inv.ctx, ...)`, which
                  # requires a `:reply` key (an absent key raises FunctionClause);
                  # `:ignore` is the no-op reply target for fire-and-forget.
                  reply: :ignore
                },
                origin: :trusted_internal
              })

            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:sandbox_update_config_cap_issue_failed, worker_uri, reason}}}
        end
      end
    end)
  end

  defp sandbox_state_matches?(%URI{} = worker_uri, config_dir, template_class, respawn_data) do
    case Ezagent.Kind.get_slice(worker_uri, :sandbox) do
      {:ok, slice} when is_map(slice) ->
        state = Ezagent.Kind.normalize_slice_view(slice)

        Map.get(state, :config_dir_path) == config_dir and
          Map.get(state, :template_class) == template_class and
          Map.get(state, :respawn_template_data) == respawn_data

      _ ->
        false
    end
  end

  # PR3 2026-05-24 — additional rollback (beyond `undo_fresh_workers/1`)
  # for the case where `record_sandbox_state/3` itself fails: the per-
  # agent config_dir was created by the plugin's `instantiate/3` but
  # the slice was never populated, so `Sandbox.invoke(:destroy, ...)`
  # would never know to clean it up. Call the plugin's
  # `destroy_config_dir/2` directly with the path we know
  # PR-3 (domain.agent D2/DD-1) — the per-agent config_dir path authority is core
  # (`Ezagent.Sandbox.ConfigDir`), NOT the plugin. The domain derives the dir from
  # the agent URI + the class's namespace (no dependency on a plugin path builder)
  # and asks the plugin only to MATERIALIZE-cleanup it via `destroy_config_dir/2`.
  defp cleanup_partial_config_dirs(workers, template_class) do
    cond do
      not is_atom(template_class) ->
        :ok

      not function_exported?(template_class, :destroy_config_dir, 2) ->
        :ok

      true ->
        namespace = Ezagent.Kind.Template.namespace_of(template_class)

        Enum.each(workers, fn worker_uri ->
          dir = Ezagent.Sandbox.ConfigDir.path(worker_uri, namespace)
          _ = template_class.destroy_config_dir(worker_uri, dir)
        end)
    end
  end

  # codex round-10 HIGH-2 — establish lineage + workspace binding for
  # each freshly-created worker as a CHECKED step. `record_lineage/2`
  # always returns `:ok`; `bind_workspace/2` may not — a failure here is
  # returned as `{:error, {:post_spawn_obligation_failed, _}}` (NOT
  # raised) so the caller can self-clean. `Enum.reduce_while/3` stops at
  # the first failure.
  defp establish_post_spawn_obligations(workers, spawned_by_uri, workspace_uri) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      with :ok <- record_lineage(worker_uri, spawned_by_uri),
           :ok <- bind_workspace(worker_uri, workspace_uri) do
        {:cont, :ok}
      else
        other ->
          {:halt, {:error, {:post_spawn_obligation_failed, worker_uri, other}}}
      end
    end)
  rescue
    error ->
      {:error, {:post_spawn_obligation_failed, :exception, error}}
  end

  defp establish_ownership_obligations(workers, spawned_by_uri, workspace_uri, nil) do
    with :ok <- establish_post_spawn_obligations(workers, spawned_by_uri, workspace_uri) do
      record_creation_inventory(workers, spawned_by_uri, workspace_uri)
    end
  end

  defp establish_ownership_obligations(
         workers,
         spawned_by_uri,
         workspace_uri,
         attempt_id
       )
       when is_binary(attempt_id) and attempt_id != "" do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      case Ezagent.Agent.CreationInventory.exact(
             attempt_id,
             worker_uri,
             spawned_by_uri,
             workspace_uri
           ) do
        {:ok, _receipt} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :ownership_receipt_missing}}
      end
    end)
  end

  defp record_creation_inventory(workers, spawned_by_uri, workspace_uri) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      attempt_id = Ezagent.Agent.CreationInventory.new_attempt_id()

      case Ezagent.Agent.CreationInventory.record(
             attempt_id,
             worker_uri,
             spawned_by_uri,
             workspace_uri
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:creation_inventory_failed, reason}}}
      end
    end)
  end

  # codex round-10 HIGH-2 — undo everything `spawn_from_template_content/4`
  # established for the workers IT freshly created, when a post-spawn
  # step fails: terminate the Kind process, forget the lineage row,
  # unbind the workspace. Best-effort + idempotent — a worker for which
  # the obligation never ran (binding/lineage absent) just no-ops.
  # `Ezagent.Kind.terminate/1` is the tier-clean Kind-process teardown;
  # `AgentLineage`/`WorkspaceRegistry` are Ezagent-domain registries this
  # Ezagent-layer helper legitimately owns (it is the layer that recorded
  # them — unlike the plugin Template Class, which must not touch them).
  defp undo_fresh_workers(workers) do
    Enum.each(workers, fn worker_uri ->
      _ = Ezagent.Kind.terminate(worker_uri)

      Ezagent.Entity.Agent.SpawnObligations.safe(fn ->
        Ezagent.WorkspaceRegistry.unbind(worker_uri)
      end)

      if Code.ensure_loaded?(Ezagent.AgentLineage) and
           function_exported?(Ezagent.AgentLineage, :forget, 1) do
        Ezagent.Entity.Agent.SpawnObligations.safe(fn ->
          Ezagent.AgentLineage.forget(worker_uri)
        end)
      end
    end)

    :ok
  end

  defp bind_workspace(worker_uri, workspace_uri),
    do: Ezagent.Entity.Agent.SpawnObligations.bind_workspace(worker_uri, workspace_uri)

  defp record_lineage(agent_uri, granted_by),
    do: Ezagent.Entity.Agent.SpawnObligations.record_lineage(agent_uri, granted_by)
end
