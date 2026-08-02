defmodule Ezagent.Entity.Agent.TemplateSpawn.Rollback do
  @moduledoc false

  @receipt_version 1

  @enforce_keys [
    :receipt_version,
    :workers,
    :ownership_receipts,
    :template_class,
    :instance_uri,
    :workspace_uri,
    :config_dirs,
    :preserve_creation_receipts?,
    :grant_incarnation_id
  ]
  defstruct @enforce_keys

  @type config_dir_receipt :: %{worker_uri: URI.t(), path: String.t()}

  @opaque fresh_receipt :: %__MODULE__{
            receipt_version: pos_integer(),
            workers: [URI.t()],
            ownership_receipts: [term()],
            template_class: module(),
            instance_uri: URI.t(),
            workspace_uri: URI.t(),
            config_dirs: [config_dir_receipt()],
            preserve_creation_receipts?: boolean(),
            grant_incarnation_id: String.t() | nil
          }

  @doc false
  @spec fresh_receipt(
          [URI.t()],
          [term()],
          module(),
          URI.t(),
          URI.t(),
          map(),
          boolean()
        ) :: fresh_receipt()
  def fresh_receipt(
        workers,
        ownership_receipts,
        template_class,
        %URI{} = instance_uri,
        %URI{} = workspace_uri,
        instantiate_meta,
        preserve_creation_receipts?
      )
      when is_list(workers) and is_list(ownership_receipts) and is_atom(template_class) and
             is_map(instantiate_meta) and is_boolean(preserve_creation_receipts?) do
    %__MODULE__{
      receipt_version: @receipt_version,
      workers: workers,
      ownership_receipts: ownership_receipts,
      template_class: template_class,
      instance_uri: instance_uri,
      workspace_uri: workspace_uri,
      config_dirs: config_dir_receipts(workers, instantiate_meta),
      preserve_creation_receipts?: preserve_creation_receipts?,
      grant_incarnation_id: Map.get(instantiate_meta, :grant_incarnation_id)
    }
  end

  @doc false
  @spec instance_uri(fresh_receipt()) :: {:ok, URI.t()} | {:error, :invalid_fresh_spawn_receipt}
  def instance_uri(%__MODULE__{
        receipt_version: @receipt_version,
        instance_uri: %URI{} = instance_uri
      }),
      do: {:ok, instance_uri}

  def instance_uri(_receipt), do: {:error, :invalid_fresh_spawn_receipt}

  @doc false
  @spec fresh_spawn(fresh_receipt()) :: {:ok, :retired} | {:error, term()}
  def fresh_spawn(%__MODULE__{} = receipt) do
    with :ok <- validate_receipt(receipt),
         :ok <- validate_current_ownership(receipt),
         :ok <- terminate_workers(receipt.workers) do
      errors =
        []
        |> append_errors(unbind_workers(receipt.workers))
        |> append_errors(
          rollback_receipts(
            receipt.ownership_receipts,
            receipt.preserve_creation_receipts?
          )
        )
        |> append_errors(cleanup_config_dirs(receipt.config_dirs, receipt.template_class))
        |> append_errors(cleanup_launch_attributes(receipt.instance_uri))
        |> append_errors(compensate_grant(receipt.instance_uri, receipt.grant_incarnation_id))

      case errors do
        [] -> {:ok, :retired}
        errors -> {:error, {:fresh_spawn_rollback_incomplete, errors}}
      end
    end
  end

  def fresh_spawn(_receipt), do: {:error, :invalid_fresh_spawn_receipt}

  defp validate_receipt(%__MODULE__{
         receipt_version: @receipt_version,
         workers: workers,
         ownership_receipts: receipts,
         template_class: template_class,
         instance_uri: %URI{},
         workspace_uri: %URI{},
         config_dirs: config_dirs,
         preserve_creation_receipts?: preserve?,
         grant_incarnation_id: grant_incarnation_id
       })
       when is_list(workers) and workers != [] and is_list(receipts) and is_atom(template_class) and
              is_list(config_dirs) and is_boolean(preserve?) and
              (is_nil(grant_incarnation_id) or is_binary(grant_incarnation_id)) do
    if Enum.all?(workers, &match?(%URI{}, &1)) and
         Enum.all?(config_dirs, &valid_config_dir_receipt?/1) do
      :ok
    else
      {:error, :invalid_fresh_spawn_receipt}
    end
  end

  defp validate_receipt(_receipt), do: {:error, :invalid_fresh_spawn_receipt}

  defp valid_config_dir_receipt?(%{worker_uri: %URI{}, path: path}),
    do: is_binary(path) and path != ""

  defp valid_config_dir_receipt?(_receipt), do: false

  # Validate exact ownership before terminating. A retry after partial cleanup is
  # allowed (absent workspace/lineage facts are already retired); facts belonging
  # to another owner or workspace stop compensation before it touches the Kind.
  defp validate_current_ownership(receipt) do
    errors =
      Enum.flat_map(receipt.workers, fn worker_uri ->
        workspace_errors(worker_uri, receipt.workspace_uri) ++
          lineage_errors(worker_uri, receipt.ownership_receipts)
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:fresh_spawn_ownership_changed, errors}}
    end
  end

  defp workspace_errors(worker_uri, workspace_uri) do
    case Ezagent.WorkspaceRegistry.lookup(worker_uri) do
      {:ok, ^workspace_uri} -> []
      :error -> []
      {:ok, other_workspace} -> [{:workspace_changed, worker_uri, other_workspace}]
    end
  end

  defp lineage_errors(worker_uri, receipts) do
    roots =
      for {:lineage_fact, ^worker_uri, %URI{} = root_uri} <- receipts,
          do: root_uri

    case {roots, Ezagent.AgentLineage.lookup(worker_uri)} do
      {[], _current} -> []
      {[_root_uri], :error} -> []
      {[root_uri], {:ok, current_root}} when root_uri == current_root -> []
      {[_root_uri], {:ok, other_root}} -> [{:lineage_changed, worker_uri, other_root}]
      {_multiple, current} -> [{:invalid_lineage_receipts, worker_uri, current}]
    end
  end

  defp terminate_workers(workers) do
    errors =
      Enum.flat_map(workers, fn worker_uri ->
        :ok = Ezagent.Kind.terminate!(worker_uri)

        if await_kind_absent(worker_uri),
          do: [],
          else: [{:kind_still_alive, worker_uri}]
      end)

    case errors do
      [] -> :ok
      errors -> {:error, {:fresh_spawn_termination_failed, errors}}
    end
  end

  defp await_kind_absent(worker_uri, attempts \\ 100)

  defp await_kind_absent(worker_uri, 0), do: not Ezagent.Kind.alive?(worker_uri)

  defp await_kind_absent(worker_uri, attempts) do
    if Ezagent.Kind.alive?(worker_uri) do
      Process.sleep(10)
      await_kind_absent(worker_uri, attempts - 1)
    else
      true
    end
  end

  defp unbind_workers(workers) do
    Enum.flat_map(workers, fn worker_uri ->
      case checked(fn -> Ezagent.WorkspaceRegistry.unbind(worker_uri) end) do
        :ok ->
          case Ezagent.WorkspaceRegistry.lookup(worker_uri) do
            :error -> []
            {:ok, workspace_uri} -> [{:workspace_still_bound, worker_uri, workspace_uri}]
          end

        {:error, reason} ->
          [{:workspace_unbind_failed, worker_uri, reason}]
      end
    end)
  end

  defp rollback_receipts(receipts, preserve_creation_receipts?) do
    Enum.flat_map(receipts, fn
      {:agent_display_profile, :inserted, agent_uri} ->
        case checked(fn ->
               Ezagent.Entity.Profile.rollback_agent_display_name(agent_uri, :inserted)
             end) do
          :ok ->
            if is_nil(Ezagent.Entity.Profile.get(agent_uri)),
              do: [],
              else: [{:agent_display_profile_still_present, agent_uri}]

          {:error, reason} ->
            [{:agent_display_profile_rollback_failed, agent_uri, reason}]
        end

      {:creation_inventory, _attempt_id, _worker_uri, _root_uri, _workspace_uri}
      when preserve_creation_receipts? ->
        []

      {:creation_inventory, attempt_id, worker_uri, root_uri, workspace_uri} ->
        case checked(fn ->
               Ezagent.Agent.CreationInventory.rollback_record(
                 attempt_id,
                 worker_uri,
                 root_uri,
                 workspace_uri
               )
             end) do
          :ok ->
            case Ezagent.Agent.CreationInventory.exact(
                   attempt_id,
                   worker_uri,
                   root_uri,
                   workspace_uri
                 ) do
              {:error, :creation_attempt_not_found} -> []
              other -> [{:creation_inventory_still_present, worker_uri, other}]
            end

          {:error, reason} ->
            [{:creation_inventory_rollback_failed, worker_uri, reason}]
        end

      {:spawned_by_edge, _worker_uri, _root_uri} ->
        # Provenance is append-only audit history, including failed attempts.
        []

      {:lineage_fact, worker_uri, root_uri} ->
        case checked(fn ->
               Ezagent.AgentLineage.rollback_lineage_fact(worker_uri, root_uri)
             end) do
          :ok ->
            case Ezagent.AgentLineage.lookup(worker_uri) do
              :error -> []
              other -> [{:lineage_fact_still_present, worker_uri, other}]
            end

          {:error, reason} ->
            [{:lineage_rollback_failed, worker_uri, reason}]
        end
    end)
  end

  defp cleanup_config_dirs(config_dirs, template_class) do
    cond do
      config_dirs == [] ->
        []

      not function_exported?(template_class, :destroy_config_dir, 2) ->
        [{:config_dir_destroy_unsupported, template_class}]

      true ->
        Enum.flat_map(config_dirs, fn %{worker_uri: worker_uri, path: path} ->
          result = checked(fn -> template_class.destroy_config_dir(worker_uri, path) end)

          # SSH 凭据 1b (Task 5 复审 J1) — this rollback path terminates the
          # worker via `terminate_workers/1` above, which calls
          # `Ezagent.Kind.terminate!/1` ("This terminates ONLY the Kind
          # process" — kind.ex). It never runs the Sandbox `:destroy` action
          # or the Lifecycle `destroy/2` hook, so `Sandbox`'s own git-identity
          # wipe (behavior/sandbox.ex) never fires on this path. Git identity
          # lives in a directory OUTSIDE config_dir (see
          # `Ezagent.Sandbox.GitIdentityDir` moduledoc), so it must be wiped
          # here too, independently. Idempotent, best-effort, never raises —
          # unconditional (not gated on `result`) so a config_dir cleanup
          # failure never leaves a stale private key behind.
          _ = Ezagent.Credential.GitIdentityRuntime.wipe(worker_uri)

          case result do
            :ok ->
              if File.exists?(path), do: [{:config_dir_still_present, worker_uri, path}], else: []

            {:error, reason} ->
              [{:config_dir_destroy_failed, worker_uri, path, reason}]
          end
        end)
    end
  end

  defp cleanup_launch_attributes(instance_uri) do
    errors =
      []
      |> append_errors(
        checked_cleanup(
          :agent_flavor_attribute,
          fn -> Ezagent.AgentFlavorAttributes.delete(instance_uri) end,
          fn -> Ezagent.AgentFlavorAttributes.get(instance_uri) == :none end
        )
      )
      |> append_errors(
        checked_cleanup(
          :agent_recipe_attribute,
          fn -> Ezagent.Agent.RecipeAttributes.delete(instance_uri) end,
          fn -> Ezagent.Agent.RecipeAttributes.fetch(instance_uri) == :none end
        )
      )
      |> append_errors(
        checked_cleanup(
          :agent_passive_attribute,
          fn -> Ezagent.AgentPassiveAttributes.delete(instance_uri) end,
          fn -> Ezagent.AgentPassiveAttributes.fetch(instance_uri) == :none end
        )
      )

    errors
  end

  # Credential grants are incarnation-bound. Never delete by URI here: a
  # concurrent reapproval may have installed a newer incarnation.
  defp compensate_grant(_instance_uri, nil), do: []

  defp compensate_grant(instance_uri, incarnation_id) when is_binary(incarnation_id) do
    case Ezagent.Credential.GrantMint.compensate(URI.to_string(instance_uri), incarnation_id) do
      :ok -> []
      {:error, reason} -> [{:grant_compensation_failed, instance_uri, reason}]
      other -> [{:grant_compensation_failed, instance_uri, {:unexpected_result, other}}]
    end
  rescue
    error -> [{:grant_compensation_failed, instance_uri, {:exception, error}}]
  catch
    kind, reason -> [{:grant_compensation_failed, instance_uri, {kind, reason}}]
  end

  defp checked_cleanup(label, delete, absent?) do
    with :ok <- checked(delete),
         true <- absent?.() do
      []
    else
      false -> [{:launch_attribute_still_present, label}]
      {:error, reason} -> [{:launch_attribute_cleanup_failed, label, reason}]
    end
  rescue
    error -> [{:launch_attribute_cleanup_failed, label, {:exception, error}}]
  catch
    kind, reason -> [{:launch_attribute_cleanup_failed, label, {kind, reason}}]
  end

  defp checked(operation) do
    case operation.() do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_cleanup_result, other}}
    end
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp append_errors(errors, more_errors), do: errors ++ more_errors

  defp config_dir_receipts(workers, instantiate_meta) do
    case Map.fetch(instantiate_meta, :config_dir_path) do
      {:ok, path} when is_binary(path) and path != "" ->
        Enum.map(workers, &%{worker_uri: &1, path: path})

      _ ->
        []
    end
  end
end
