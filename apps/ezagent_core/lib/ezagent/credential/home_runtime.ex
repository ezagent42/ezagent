defmodule Ezagent.Credential.HomeRuntime do
  @moduledoc """
  Shared per-agent config-home runtime for file-backed agent flavors.

  The cc and codex Template Classes keep their flavor-specific public entrypoints
  and pass their module here for namespace and credential callback data.
  """

  require Logger

  @config_complete_marker ".ezagent-config-complete"

  @type grant_ctx :: {:grant, String.t(), non_neg_integer()} | nil
  @type create_result ::
          {:ok, String.t() | nil}
          | {:ok, String.t(), {:grant, String.t(), non_neg_integer()}}
          | {:error, term()}

  # #1201 A② — the SHARED host-login-home derivation for file-backed flavors
  # (cc/codex delegate here with their env var + default dirname, mirroring the
  # CLIs' own resolution order: env override, else `~/<dirname>`). Lives here —
  # not per-flavor — per the FF-1 `cross_file_duplicate_fn_groups` gate.
  @doc false
  @spec host_login_dir(String.t(), String.t()) :: String.t() | nil
  def host_login_dir(env_var, home_dirname)
      when is_binary(env_var) and is_binary(home_dirname) do
    case System.get_env(env_var) do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        case System.user_home() do
          home when is_binary(home) -> Path.join(home, home_dirname)
          _ -> nil
        end
    end
  end

  @doc false
  @spec put_agent_config_dir(map(), String.t() | nil) :: map()
  def put_agent_config_dir(tmpl, nil) when is_map(tmpl), do: tmpl

  def put_agent_config_dir(tmpl, dir) when is_map(tmpl),
    do: Map.put(tmpl, "agent_config_dir", dir)

  @doc false
  @spec resolve_config_home(URI.t(), map(), module(), keyword()) :: String.t() | nil
  def resolve_config_home(%URI{} = agent_uri, tmpl, template_module, opts \\ [])
      when is_map(tmpl) do
    cond do
      valid_dir?(Map.get(tmpl, "agent_config_dir")) ->
        Map.get(tmpl, "agent_config_dir")

      valid_dir?(Map.get(tmpl, "allocated_config_dir")) ->
        Map.get(tmpl, "allocated_config_dir")

      valid_dir?(Map.get(tmpl, "config_dir")) ->
        agent_config_dir(agent_uri, template_module)

      config_dir_present_but_malformed?(tmpl) ->
        case Keyword.get(opts, :on_malformed, nil) do
          {:raise, message_fun} when is_function(message_fun, 1) ->
            raise ArgumentError, message_fun.(Map.get(tmpl, "config_dir"))

          nil ->
            nil
        end

      true ->
        nil
    end
  end

  @doc false
  @spec valid_dir?(term()) :: boolean()
  def valid_dir?(dir) when is_binary(dir) and dir != "", do: true
  def valid_dir?(_), do: false

  @doc false
  @spec config_dir_present_but_malformed?(map()) :: boolean()
  def config_dir_present_but_malformed?(tmpl) when is_map(tmpl) do
    case Map.fetch(tmpl, "config_dir") do
      :error -> false
      {:ok, value} -> not valid_dir?(value)
    end
  end

  @doc false
  @spec agent_config_dir(URI.t(), module()) :: String.t()
  def agent_config_dir(%URI{} = agent_uri, template_module) when is_atom(template_module) do
    Ezagent.Sandbox.ConfigDir.path(
      agent_uri,
      Ezagent.Kind.Template.namespace_of(template_module)
    )
  end

  @doc false
  @spec create_agent_config_dir(URI.t(), map(), module(), keyword()) :: create_result()
  def create_agent_config_dir(%URI{} = agent_uri, tmpl, template_module, opts \\ [])
      when is_map(tmpl) and is_atom(template_module) do
    case Map.fetch(tmpl, "config_dir") do
      :error ->
        {:ok, nil}

      {:ok, ref} when is_binary(ref) and ref != "" ->
        case Map.fetch(tmpl, "allocated_config_dir") do
          {:ok, target} when is_binary(target) and target != "" ->
            materialize_config_dir(agent_uri, target, ref, tmpl, template_module, opts)

          _ ->
            {:error, :config_dir_not_allocated}
        end

      {:ok, bad} ->
        {:error, {:invalid_config_dir, bad}}
    end
  end

  @doc false
  @spec create_agent_config_dir_with_grant(URI.t(), map(), module(), keyword()) ::
          {:ok, String.t() | nil, grant_ctx()} | {:error, term()}
  def create_agent_config_dir_with_grant(%URI{} = agent_uri, tmpl, template_module, opts \\ [])
      when is_map(tmpl) and is_atom(template_module) do
    case create_agent_config_dir(agent_uri, tmpl, template_module, opts) do
      {:ok, dir, grant_ctx} -> {:ok, dir, grant_ctx}
      {:ok, dir} -> {:ok, dir, nil}
      {:error, _} = err -> err
    end
  end

  @doc """
  True iff a subprocess may be launched against the per-agent config home `dir`.

  Launchable means EITHER:

    * `stage_and_swap/7` committed the home and wrote `#{@config_complete_marker}`
      (a freshly materialized home), OR
    * the home already carries one of `template_module.credential_relpaths/0`
      (a home materialized before the marker existed, or provisioned by an
      operator's interactive login) — the same signal `materialize_single_reference/5`
      uses to decide a target is a real user home worth overlaying.

  A directory that merely EXISTS is neither: `OnboardingBootstrap` `mkdir_p`s the
  config home before the copy, so an un-marked, credential-less dir can hold a
  `.claude.json` and nothing else. Launching against THAT produces an agent that
  can never authenticate, and the subsequent `atomic_replace` renames the
  directory out from under the running process (chain B / #1096). Callers MUST
  gate the subprocess launch on this.
  """
  @spec config_dir_launchable?(String.t() | nil, module()) :: boolean()
  def config_dir_launchable?(nil, _template_module), do: false

  def config_dir_launchable?(dir, template_module)
      when is_binary(dir) and is_atom(template_module) do
    File.dir?(dir) and
      (File.exists?(Path.join(dir, @config_complete_marker)) or
         has_user_credentials?(dir, template_module))
  end

  @doc "The sentinel file `stage_and_swap/7` writes last, marking a config home complete."
  @spec config_complete_marker() :: String.t()
  def config_complete_marker, do: @config_complete_marker

  @doc false
  @spec revalidate_grant_before_launch(grant_ctx()) :: :ok | {:error, term()}
  def revalidate_grant_before_launch(nil), do: :ok

  def revalidate_grant_before_launch({:grant, agent_uri_str, version}) do
    case Ezagent.Credential.GrantRow.revalidate_version!(agent_uri_str, version) do
      :ok -> :ok
      {:error, :grant_changed} -> {:error, {:grant_changed_before_launch, agent_uri_str}}
    end
  end

  @doc false
  @spec handle_spawn_failure(URI.t(), term(), module(), String.t()) :: {:error, term()}
  def handle_spawn_failure(
        %URI{} = agent_uri,
        {:grant_changed_before_launch, _} = reason,
        template_module,
        log_prefix
      ) do
    case rollback_agent_config_dir(agent_uri, template_module, log_prefix) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:grant_revoked_cleanup_failed, agent_uri, cleanup_reason}}
    end
  end

  def handle_spawn_failure(%URI{} = agent_uri, reason, template_module, log_prefix) do
    case rollback_agent_config_dir(agent_uri, template_module, log_prefix) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:config_dir_cleanup_failed, agent_uri, reason, cleanup_reason}}
    end
  end

  @doc false
  @spec grant_revoked_for_restart?(URI.t()) :: boolean()
  def grant_revoked_for_restart?(%URI{} = agent_uri) do
    case Ezagent.Credential.GrantRow.get_for_agent(URI.to_string(agent_uri)) do
      %Ezagent.Credential.GrantRow{revoked_at: nil} -> false
      %Ezagent.Credential.GrantRow{} -> true
      nil -> false
    end
  rescue
    _ -> false
  end

  defp rollback_agent_config_dir(agent_uri, template_module, log_prefix) do
    dir = agent_config_dir(agent_uri, template_module)

    case File.rm_rf(dir) do
      {:ok, _} ->
        :ok

      {:error, reason, _path} ->
        Logger.warning(
          "#{log_prefix}: rollback of #{dir} failed: #{inspect(reason)} " <>
            "(agent_uri=#{URI.to_string(agent_uri)})"
        )

        {:error, reason}
    end
  end

  defp materialize_config_dir(
         %URI{} = agent_uri,
         target,
         reference_dir,
         tmpl,
         template_module,
         opts
       )
       when is_map(tmpl) do
    with :ok <- recover_orphaned_or_fail(target) do
      case Map.get(tmpl, "cascade") do
        %{} = cascade ->
          materialize_cascade(agent_uri, target, cascade, tmpl, template_module, opts)

        _ ->
          materialize_single_reference(target, reference_dir, tmpl, template_module, opts)
      end
    end
  end

  defp recover_orphaned_or_fail(target) do
    case Ezagent.Agent.Materializer.recover_orphaned(target) do
      :ok -> :ok
      {:recovered, _} -> :ok
      {:error, reason} -> {:error, {:config_dir_recover_failed, reason}}
    end
  end

  defp materialize_cascade(%URI{} = agent_uri, target, cascade, tmpl, template_module, opts) do
    marker = Path.join(target, @config_complete_marker)
    staging = "#{target}.staging-#{System.unique_integer([:positive])}"
    _ = File.rm_rf(staging)

    layer_dirs = Map.fetch!(cascade, :layer_dirs)
    source_dir_for = Map.fetch!(cascade, :source_dir_for)

    result =
      with :ok <- Ezagent.Agent.Materializer.merge_layers(staging, layer_dirs),
           :ok <- materialize_sandbox_skills(staging, tmpl),
           :ok <- materialize_plugin_manifest(staging, tmpl),
           :ok <- File.chmod(staging, 0o700),
           :ok <- File.write(Path.join(staging, Path.basename(marker)), "ok\n") do
        Ezagent.Agent.Materializer.materialize_with_grant(%{
          agent_uri: URI.to_string(agent_uri),
          staging: staging,
          secret_relpaths: template_module.secret_relpaths(),
          source_dir_for: source_dir_for,
          commit: fn version ->
            with :ok <- chmod_credential_files(staging, template_module, opts),
                 :ok <- swap_into_place(staging, target) do
              {:ok, {target, version}}
            end
          end
        })
      end

    case result do
      {:ok, {^target, version}} ->
        {:ok, target, {:grant, URI.to_string(agent_uri), version}}

      {:error, reason} ->
        _ = File.rm_rf(staging)
        {:error, {:cascade_materialize_failed, reason}}
    end
  end

  defp materialize_single_reference(target, reference_dir, tmpl, template_module, opts) do
    marker = Path.join(target, @config_complete_marker)

    cond do
      not File.dir?(reference_dir) ->
        {:error, {:reference_dir_missing, reference_dir}}

      File.dir?(target) and File.exists?(marker) ->
        {:ok, target}

      File.dir?(target) and has_user_credentials?(target, template_module) ->
        stage_and_swap(reference_dir, target, marker, template_module, tmpl, opts,
          overlay: target
        )

      true ->
        stage_and_swap(reference_dir, target, marker, template_module, tmpl, opts)
    end
  end

  defp stage_and_swap(reference_dir, target, marker, template_module, tmpl, opts, swap_opts \\ []) do
    staging = "#{target}.staging-#{System.unique_integer([:positive])}"
    marker_name = Path.basename(marker)
    _ = File.rm_rf(staging)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, _} <- File.cp_r(reference_dir, staging),
         :ok <- maybe_overlay(Keyword.get(swap_opts, :overlay), staging),
         :ok <- apply_derived_config(staging, tmpl),
         :ok <- materialize_sandbox_skills(staging, tmpl),
         :ok <- materialize_plugin_manifest(staging, tmpl),
         :ok <- File.chmod(staging, 0o700),
         :ok <- chmod_credential_files(staging, template_module, opts),
         :ok <- File.write(Path.join(staging, marker_name), "ok\n"),
         :ok <- swap_into_place(staging, target) do
      {:ok, target}
    else
      {:error, reason} ->
        _ = File.rm_rf(staging)
        {:error, {stage_error_tag(opts), reason}}

      err ->
        _ = File.rm_rf(staging)
        {:error, {stage_error_tag(opts), err}}
    end
  end

  defp maybe_overlay(nil, _staging), do: :ok

  defp maybe_overlay(src, staging) when is_binary(src) do
    case File.cp_r(src, staging) do
      {:ok, _} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp apply_derived_config(staging, tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "claude_md") do
      body when is_binary(body) -> File.write(Path.join(staging, "CLAUDE.md"), body)
      _ -> :ok
    end
  end

  defp materialize_sandbox_skills(staging, tmpl) when is_map(tmpl) do
    case sandbox_skill_refs(tmpl) do
      :absent ->
        :ok

      {:ok, skills} ->
        skills_root = Path.join(staging, "skills")

        with {:ok, _} <- File.rm_rf(skills_root),
             :ok <- maybe_mkdir_skills_root(skills_root, skills) do
          copy_sandbox_skills(skills, skills_root)
        end

      {:error, _} = error ->
        error
    end
  end

  defp sandbox_skill_refs(tmpl) do
    cond do
      Map.has_key?(tmpl, "sandbox_content") ->
        skill_refs_from_sandbox_content(Map.get(tmpl, "sandbox_content"))

      Map.has_key?(tmpl, :sandbox_content) ->
        skill_refs_from_sandbox_content(Map.get(tmpl, :sandbox_content))

      true ->
        :absent
    end
  end

  defp skill_refs_from_sandbox_content(%{} = sandbox_content) do
    case Map.fetch(sandbox_content, :skills) do
      {:ok, skills} -> normalize_skill_refs(skills)
      :error -> sandbox_content |> Map.get("skills", :absent) |> normalize_skill_refs()
    end
  end

  defp skill_refs_from_sandbox_content(other), do: {:error, {:invalid_sandbox_content, other}}

  defp normalize_skill_refs(:absent), do: :absent

  defp normalize_skill_refs(skills) when is_list(skills) do
    if Enum.all?(skills, &is_binary/1) do
      {:ok, Enum.uniq(skills)}
    else
      {:error, {:invalid_sandbox_skills, skills}}
    end
  end

  defp normalize_skill_refs(other), do: {:error, {:invalid_sandbox_skills, other}}

  defp maybe_mkdir_skills_root(_skills_root, []), do: :ok
  defp maybe_mkdir_skills_root(skills_root, _skills), do: File.mkdir_p(skills_root)

  defp copy_sandbox_skills(skills, skills_root) do
    Enum.reduce_while(skills, :ok, fn ref, :ok ->
      case copy_sandbox_skill(ref, skills_root) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp copy_sandbox_skill(ref, skills_root) do
    with {:ok, {source_dir, _hash}} <- Ezagent.SkillRegistry.resolve(ref),
         {:ok, _} <- File.cp_r(source_dir, Path.join(skills_root, ref)) do
      :ok
    else
      {:error, {:skill_source_not_found, ^ref}} = error ->
        error

      {:error, reason, path} ->
        {:error, {:skill_copy_failed, ref, path, reason}}

      {:error, reason} ->
        {:error, {:skill_copy_failed, ref, reason}}
    end
  end

  # Writes .claude-plugin/plugin.json into the staging directory so the
  # per-agent config_dir is a valid Claude Code plugin bundle. Headless
  # flavors (cc-headless) load skills via the SDK's `plugins` parameter
  # (bypassing `setting_sources=[]`); PTY flavors are unaffected by the
  # extra file. Only materialized when sandbox skills are present.
  defp materialize_plugin_manifest(staging, tmpl) when is_map(tmpl) do
    case sandbox_skill_refs(tmpl) do
      {:ok, []} -> :ok
      :absent -> :ok
      {:ok, _skills} -> write_plugin_manifest(staging)
      {:error, _} = error -> error
    end
  end

  defp write_plugin_manifest(staging) do
    plugin_dir = Path.join(staging, ".claude-plugin")

    with :ok <- File.mkdir_p(plugin_dir) do
      File.write(Path.join(plugin_dir, "plugin.json"), plugin_manifest_json())
    end
  end

  defp plugin_manifest_json do
    Jason.encode!(%{
      "name" => "ezagent-skills",
      "version" => "1.0.0",
      "description" => "Per-agent skill bundle materialized by Ezagent"
    })
  end

  defp swap_into_place(staging, target) do
    case Ezagent.Agent.Materializer.atomic_replace(staging, target) do
      {:ok, _target} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_credential_files(dir, template_module, opts) do
    template_module.credential_relpaths()
    |> Enum.reduce_while(:ok, fn relpath, :ok ->
      path = Path.join(dir, relpath)

      if File.exists?(path) do
        case File.chmod(path, 0o600) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, chmod_error(relpath, reason, opts)}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp chmod_error(relpath, reason, opts) do
    case Keyword.get(opts, :chmod_error, :tagged) do
      :bare -> {:error, reason}
      :tagged -> {:error, {:chmod_failed, relpath, reason}}
    end
  end

  defp has_user_credentials?(dir, template_module) do
    Enum.any?(template_module.credential_relpaths(), fn relpath ->
      File.exists?(Path.join(dir, relpath))
    end)
  end

  defp stage_error_tag(opts), do: Keyword.fetch!(opts, :stage_error_tag)
end
