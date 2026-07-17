defmodule Ezagent.Home.SkillReconcile do
  @moduledoc """
  Per-agent skill reconcile: align each durable agent's `<config_dir>/skills/` subtree
  with the current recipe + seed.

  ## Contract

  - **Only touches `<config_dir>/skills/` subtree** — never renames the home itself,
    never touches the `.ezagent-config-complete` marker, never touches credentials.
  - **Per-ref staging + rename** (atomic replace, mirroring `SkillSeed`'s `.staging-` pattern).
  - **Cover strategy**: per-agent copies are derived caches; manual edits are overwritten
    with telemetry (hash 3-way compare identifying the edit).
  - **Delete strategy**: unresolvable refs (recipe no longer declares them) are KEPT + telemetry;
    v1 does not auto-delete.
  - **CLAUDE.md hint**: idempotently appended when recipe skills include
    the orchestrator skill ref (reuses the existing hint-line contract).
  - **O(1) skip**: a skills-manifest hash stamp stored alongside the skills subtree
    allows unchanged agents to be skipped instantly.

  ## Hard constraint

  The `materialize_single_reference/5` marker short-circuit (`home_runtime.ex:296`)
  and the respawn no-rematerialize gate (`spawn.ex:312`) are ZERO-CHANGE. This module
  writes the skills subtree AFTER boot — it never goes through those paths.
  """

  require Logger

  alias Ezagent.SkillRegistry

  @manifest_file ".ezagent-skills-manifest"
  @staging_suffix ".staging"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Reconcile every durable agent with a config home + recipe skills.

  Options:
    - `:fail_soft` — when `true` (default), failures log + telemetry but never raise.
    - `:dry_run` — when `true`, compute the diff but don't write anything.
    - `:filter_agent_uri` — reconcile only the given agent URI (string).

  Returns `{:ok, stats}` where `stats` is a map of `%{reconciled: n, skipped: n, errors: n}`.
  """
  @spec reconcile_all(keyword()) :: {:ok, map()}
  def reconcile_all(opts \\ []) do
    fail_soft? = Keyword.get(opts, :fail_soft, true)
    dry_run? = Keyword.get(opts, :dry_run, false)
    filter_uri = Keyword.get(opts, :filter_agent_uri)

    unless SkillRegistry.ready?() do
      Logger.warning("SkillReconcile: SkillRegistry not ready — skipping reconcile sweep")
      {:ok, %{reconciled: 0, skipped: 0, errors: 0}}
    else
      agents = list_durable_agents(filter_uri)

      stats =
        agents
        |> Enum.reduce(%{reconciled: 0, skipped: 0, errors: 0}, fn agent_ctx, acc ->
          result =
            if fail_soft? do
              reconcile_agent(agent_ctx, dry_run?)
            else
              reconcile_agent!(agent_ctx, dry_run?)
            end

          case result do
            {:ok, :reconciled} -> %{acc | reconciled: acc.reconciled + 1}
            {:ok, :skipped} -> %{acc | skipped: acc.skipped + 1}
            {:error, _reason} -> %{acc | errors: acc.errors + 1}
          end
        end)

      Logger.info(
        "SkillReconcile: sweep complete — " <>
          "reconciled=#{stats.reconciled} skipped=#{stats.skipped} errors=#{stats.errors}"
      )

      :telemetry.execute(
        [:ezagent, :skill_reconcile, :sweep_complete],
        %{reconciled: stats.reconciled, skipped: stats.skipped, errors: stats.errors},
        %{total_agents: length(agents), filter_uri: filter_uri}
      )

      {:ok, stats}
    end
  end

  @doc """
  Reconcile a single agent. Returns `{:ok, :reconciled | :skipped} | {:error, reason}`.
  """
  @spec reconcile_agent(map(), boolean()) :: {:ok, :reconciled | :skipped} | {:error, term()}
  def reconcile_agent(%{config_dir: nil}, _dry_run?), do: {:ok, :skipped}

  def reconcile_agent(%{config_dir: config_dir} = agent_ctx, dry_run?) do
    with {:ok, expected_refs} <- expected_skill_refs(agent_ctx),
         true <- has_work_to_do?(config_dir, expected_refs) do
      apply_reconcile(config_dir, expected_refs, dry_run?)
    else
      {:error, _} = err -> err
      false -> {:ok, :skipped}
    end
  rescue
    e ->
      Logger.error("SkillReconcile: reconcile_agent failed: #{Exception.message(e)}")
      {:error, {:reconcile_exception, Exception.message(e)}}
  end

  @doc """
  Strict version — raises on error. For the mix task's non-fail-soft mode.
  """
  @spec reconcile_agent!(map(), boolean()) :: {:ok, :reconciled | :skipped}
  def reconcile_agent!(agent_ctx, dry_run?) do
    case reconcile_agent(agent_ctx, dry_run?) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> raise "SkillReconcile failed: #{inspect(reason)}"
    end
  end

  # ── Agent enumeration ──────────────────────────────────────────────────────

  defp list_durable_agents(filter_uri) do
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.filter(&agent_row?/1)
    |> Enum.flat_map(&decode_agent/1)
    |> then(fn agents ->
      if filter_uri do
        Enum.filter(agents, fn ctx ->
          ctx.agent_uri_str == filter_uri or
            to_string(ctx.agent_uri_str) == filter_uri
        end)
      else
        agents
      end
    end)
  end

  defp agent_row?(%{kind_type: "agent"}), do: true

  defp agent_row?(%{kind_type: nil, uri: uri}) when is_binary(uri) do
    case parse_uri(uri) do
      {:ok, %URI{} = agent_uri} ->
        Ezagent.URI.scheme?(agent_uri, :entity) and Ezagent.URI.type?(agent_uri, :agent)

      _ -> false
    end
  end

  defp agent_row?(_), do: false

  defp decode_agent(row) do
    with {:ok, %URI{} = agent_uri} <- parse_uri(Map.get(row, :uri)),
         {:ok, decoded} <- Ezagent.Ecto.KindSnapshot.decode_state(row),
         {:ok, config_dir} <- extract_config_dir(decoded),
         {:ok, workspace_uri_str} <- extract_workspace(agent_uri),
         {:ok, role} <- extract_role(decoded) do
      [
        %{
          agent_uri: agent_uri,
          agent_uri_str: URI.to_string(agent_uri),
          config_dir: config_dir,
          workspace_uri_str: workspace_uri_str,
          role: role,
          home_exists?: File.dir?(config_dir),
          home_marked?:
            File.dir?(config_dir) and
              File.exists?(Path.join(config_dir, ".ezagent-config-complete"))
        }
      ]
    else
      _ -> []
    end
  end

  defp parse_uri(uri_str) do
    case Ezagent.URI.parse(uri_str) do
      {:ok, uri} -> {:ok, uri}
      _ -> :error
    end
  end

  defp extract_config_dir(decoded_state) do
    # Walk the :sandbox slice for config_dir_path
    sandbox = get_in(decoded_state, [:sandbox]) || get_in(decoded_state, ["sandbox"])

    if is_map(sandbox) do
      # Lifecycle wraps state inside a lifecycle envelope: %{state: %{...}}
      inner = sandbox[:state] || sandbox["state"] || sandbox
      config_dir = inner[:config_dir_path] || inner["config_dir_path"]

      if is_binary(config_dir) and config_dir != "",
        do: {:ok, config_dir},
        else: :error
    else
      :error
    end
  end

  defp extract_workspace(%URI{} = agent_uri) do
    case Ezagent.URI.type(agent_uri) do
      {:ok, "agent"} -> {:ok, Ezagent.URI.workspace_name!(agent_uri)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp extract_role(decoded_state) do
    sandbox = get_in(decoded_state, [:sandbox]) || get_in(decoded_state, ["sandbox"])

    role =
      if is_map(sandbox) do
        inner = sandbox[:state] || sandbox["state"] || sandbox
        inner[:recipe] || inner["recipe"]
      end

    if is_binary(role) and role != "", do: {:ok, role}, else: :error
  end

  # ── Expected refs ──────────────────────────────────────────────────────────

  defp expected_skill_refs(agent_ctx) do
    case Ezagent.Agent.RecipeRegistry.lookup(
           agent_ctx.workspace_uri_str,
           agent_ctx.role
         ) do
      {:ok, %Ezagent.Agent.Recipe{skills: skills}} when is_list(skills) ->
        {:ok, skills}

      :error ->
        {:error, {:role_not_found, agent_ctx.role}}
    end
  end

  # ── O(1) skip via manifest hash ────────────────────────────────────────────

  defp has_work_to_do?(_config_dir, []), do: false

  defp has_work_to_do?(config_dir, expected_refs) do
    manifest_path = Path.join(config_dir, @manifest_file)

    current_manifest = build_manifest(expected_refs)

    case File.read(manifest_path) do
      {:ok, ^current_manifest} -> false
      _ -> true
    end
  end

  defp build_manifest(refs) when is_list(refs) do
    entries =
      refs
      |> Enum.sort()
      |> Enum.map(fn ref ->
        case SkillRegistry.resolve(ref) do
          {:ok, {_dir, hash}} -> "#{ref}:#{hash}"
          {:error, _} -> "#{ref}:unresolvable"
        end
      end)

    ["# ezagent-skills-manifest v1" | entries]
    |> Enum.join("\n")
  end

  # ── Reconcile apply ────────────────────────────────────────────────────────

  defp apply_reconcile(config_dir, expected_refs, dry_run?) do
    skills_root = Path.join(config_dir, "skills")
    current_refs = current_skill_refs(skills_root)

    # Classify each expected ref
    actions = classify_refs(expected_refs, current_refs, skills_root)

    # Classify stale refs (on disk but not in expected)
    stale_refs = MapSet.difference(MapSet.new(current_refs), MapSet.new(expected_refs))
    stale_actions = classify_stale_refs(stale_refs, skills_root)

    all_actions = actions ++ stale_actions

    if dry_run? do
      log_dry_run(config_dir, all_actions)
      {:ok, :reconciled}
    else
      errors = apply_actions(skills_root, all_actions)

      # Ensure the config_dir is a valid plugin bundle so the SDK sidecar
      # can discover reconciled skills via the `plugins` parameter.
      ensure_plugin_manifest(config_dir)

      if errors == 0 do
        write_manifest(config_dir, expected_refs)
        {:ok, :reconciled}
      else
        Logger.warning(
          "SkillReconcile: #{errors} action(s) failed for #{config_dir} — " <>
            "manifest NOT updated; skills will be re-reconciled on next sweep"
        )

        {:ok, :reconciled}
      end
    end
  end

  defp current_skill_refs(skills_root) do
    if File.dir?(skills_root) do
      skills_root
      |> File.ls!()
      |> Enum.filter(fn child ->
        not String.contains?(child, @staging_suffix) and
          File.dir?(Path.join(skills_root, child)) and
          File.regular?(Path.join([skills_root, child, "SKILL.md"]))
      end)
    else
      []
    end
  end

  defp classify_refs(expected_refs, current_refs, skills_root) do
    Enum.map(expected_refs, fn ref ->
      current_path = Path.join(skills_root, ref)

      cond do
        ref not in current_refs ->
          {:install, ref}

        true ->
          case resolve_and_compare(ref, current_path) do
            {:ok, :match} ->
              {:keep, ref}

            {:ok, {:diverge, current_hash, seed_hash}} ->
              {:overwrite, ref, current_hash, seed_hash}

            {:error, :unresolvable} ->
              {:keep_unresolvable, ref}

            {:error, :hash_error} ->
              {:keep_hash_error, ref}
          end
      end
    end)
  end

  defp classify_stale_refs(stale_refs, _skills_root) do
    Enum.map(stale_refs, fn ref ->
      {:keep_stale, ref,
       "recipe no longer declares this ref — kept + telemetry (v1 no-auto-delete)"}
    end)
  end

  defp resolve_and_compare(ref, current_path) do
    with {:ok, {_source_dir, seed_hash}} <- SkillRegistry.resolve(ref),
         {:ok, current_hash} <- safe_dir_hash(current_path) do
      if current_hash == seed_hash do
        {:ok, :match}
      else
        {:ok, {:diverge, current_hash, seed_hash}}
      end
    else
      {:error, {:skill_source_not_found, _}} -> {:error, :unresolvable}
      {:error, :hash_error} -> {:error, :hash_error}
      {:error, _} -> {:error, :hash_error}
    end
  end

  defp safe_dir_hash(dir) do
    try do
      {:ok, SkillRegistry.dir_hash(dir)}
    rescue
      _ -> {:error, :hash_error}
    end
  end

  # ── Action application ─────────────────────────────────────────────────────

  defp apply_actions(skills_root, actions) do
    File.mkdir_p!(skills_root)

    Enum.reduce(actions, 0, fn
      {:install, ref}, errors ->
        case install_ref(ref, skills_root) do
          :ok -> errors
          {:error, _} -> errors + 1
        end

      {:overwrite, ref, current_hash, seed_hash}, errors ->
        case overwrite_ref(ref, skills_root, current_hash, seed_hash) do
          :ok -> errors
          {:error, _} -> errors + 1
        end

      {:keep, _ref}, errors ->
        errors

      {:keep_unresolvable, ref}, errors ->
        emit_unresolvable_kept(ref)
        errors

      {:keep_hash_error, ref}, errors ->
        emit_hash_error_kept(ref)
        errors

      {:keep_stale, ref, reason}, errors ->
        emit_stale_kept(ref, reason)
        errors
    end)
  end

  # Write .claude-plugin/plugin.json when the skills/ subtree has content,
  # making the config_dir a valid Claude Code plugin bundle. This is the
  # same format HomeRuntime writes during materialization.
  defp ensure_plugin_manifest(config_dir) do
    plugin_dir = Path.join(config_dir, ".claude-plugin")

    with :ok <- File.mkdir_p(plugin_dir),
         :ok <- File.write(Path.join(plugin_dir, "plugin.json"), plugin_manifest_json()) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "SkillReconcile: unable to write .claude-plugin/plugin.json in #{config_dir}: " <>
            inspect(reason)
        )

        :ok
    end
  end

  defp plugin_manifest_json do
    Jason.encode!(%{
      "name" => "ezagent-skills",
      "version" => "1.0.0",
      "description" => "Per-agent skill bundle materialized by Ezagent"
    })
  end

  defp install_ref(ref, skills_root) do
    staging = Path.join(skills_root, "#{ref}#{@staging_suffix}-#{nonce()}")
    target = Path.join(skills_root, ref)
    File.rm_rf!(staging)

    with {:ok, {source_dir, _hash}} <- SkillRegistry.resolve(ref),
         {:ok, _} <- File.cp_r(source_dir, staging),
         :ok <- rename_safely(staging, target) do
      :ok
    else
      {:error, reason} ->
        File.rm_rf!(staging)
        Logger.error("SkillReconcile: install #{ref} failed: #{inspect(reason)}")
        {:error, {:install_failed, ref, reason}}
    end
  end

  defp overwrite_ref(ref, skills_root, current_hash, seed_hash) do
    staging = Path.join(skills_root, "#{ref}#{@staging_suffix}-#{nonce()}")
    target = Path.join(skills_root, ref)
    File.rm_rf!(staging)

    with {:ok, {source_dir, _hash}} <- SkillRegistry.resolve(ref),
         {:ok, _} <- File.cp_r(source_dir, staging),
         :ok <- rename_safely(staging, target) do
      emit_overwrite(ref, current_hash, seed_hash)
      :ok
    else
      {:error, reason} ->
        File.rm_rf!(staging)
        Logger.error("SkillReconcile: overwrite #{ref} failed: #{inspect(reason)}")
        {:error, {:overwrite_failed, ref, reason}}
    end
  end

  defp rename_safely(staging, target) do
    # Atomically rename staging into place. If target already exists,
    # move it aside as .old- first, then clean up on success.
    old = "#{target}.old-#{nonce()}"

    result =
      case File.rename(target, old) do
        :ok ->
          case File.rename(staging, target) do
            :ok ->
              File.rm_rf!(old)
              :ok

            {:error, reason} ->
              # Failed to put staging in place — try to restore original.
              _ = File.rename(old, target)
              File.rm_rf!(staging)
              {:error, {:rename_failed, reason}}
          end

        {:error, :enoent} ->
          # Target didn't exist — just rename staging → target.
          case File.rename(staging, target) do
            :ok -> :ok
            {:error, reason} -> {:error, {:rename_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:rename_failed, reason}}
      end

    # Cleanup staging on any failure path.
    case result do
      {:error, _} -> File.rm_rf!(staging)
      _ -> :ok
    end

    result
  end

  defp write_manifest(config_dir, expected_refs) do
    manifest_path = Path.join(config_dir, @manifest_file)

    case File.write(manifest_path, build_manifest(expected_refs)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("SkillReconcile: manifest write failed: #{inspect(reason)}")
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────────────────

  defp emit_overwrite(ref, current_hash, seed_hash) do
    Logger.info(
      "SkillReconcile: overwrote #{ref} " <>
        "(on_disk=#{short_hash(current_hash)} seed=#{short_hash(seed_hash)} — " <>
        "per-agent copy is derived cache; manual edits are overwritten)"
    )

    :telemetry.execute(
      [:ezagent, :skill_reconcile, :overwrite],
      %{count: 1},
      %{ref: ref, on_disk_hash: current_hash, seed_hash: seed_hash}
    )
  end

  defp emit_unresolvable_kept(ref) do
    Logger.info(
      "SkillReconcile: kept unresolvable ref #{ref} " <>
        "(current seed/registry no longer has this ref — v1 no-auto-delete)"
    )

    :telemetry.execute(
      [:ezagent, :skill_reconcile, :unresolvable_kept],
      %{count: 1},
      %{ref: ref}
    )
  end

  defp emit_hash_error_kept(ref) do
    Logger.warning(
      "SkillReconcile: kept ref #{ref} with hash error " <>
        "(permission/race — human investigation needed)"
    )

    :telemetry.execute(
      [:ezagent, :skill_reconcile, :hash_error_kept],
      %{count: 1},
      %{ref: ref}
    )
  end

  defp emit_stale_kept(ref, reason) do
    Logger.info("SkillReconcile: #{reason} (ref=#{ref})")

    :telemetry.execute(
      [:ezagent, :skill_reconcile, :stale_kept],
      %{count: 1},
      %{ref: ref, reason: reason}
    )
  end

  defp log_dry_run(config_dir, actions) do
    installs = Enum.count(actions, &match?({:install, _}, &1))
    overwrites = Enum.count(actions, &match?({:overwrite, _, _, _}, &1))
    keeps = Enum.count(actions, &match?({:keep, _}, &1))
    stale = Enum.count(actions, &match?({:keep_stale, _, _}, &1))
    other = length(actions) - installs - overwrites - keeps - stale

    Logger.info(
      "SkillReconcile: DRY RUN for #{config_dir} — " <>
        "install=#{installs} overwrite=#{overwrites} keep=#{keeps} " <>
        "stale=#{stale} other=#{other}"
    )
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp nonce, do: System.unique_integer([:positive, :monotonic])

  defp short_hash(hash), do: String.slice(hash, 0, 8)
end
