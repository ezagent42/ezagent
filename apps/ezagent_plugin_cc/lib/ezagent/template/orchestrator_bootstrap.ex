defmodule Ezagent.PluginCc.Template.OrchestratorBootstrap do
  @moduledoc false

  require Logger

  @orchestrator_skill_relpath ".claude/skills/ezagent-session-orchestrator"
  @orchestrator_skill_marker_relpath "SKILL.md"
  @orchestrator_hint_line "## Use the ezagent-session-orchestrator skill for all session coordination work."

  @spec bootstrap(map(), String.t() | nil) :: :ok | {:error, term()}
  def bootstrap(_tmpl, nil), do: :ok

  def bootstrap(tmpl, config_dir) when is_map(tmpl) and is_binary(config_dir) do
    if orchestrator_role?(tmpl) do
      with {:ok, source} <- resolve_orchestrator_skill_source(),
           :ok <- copy_orchestrator_skill(source, config_dir),
           :ok <- append_orchestrator_claude_md_hint(config_dir) do
        :ok
      end
    else
      :ok
    end
  end

  @spec try_apply(map(), String.t() | nil, URI.t()) :: {:ok, map()}
  def try_apply(tmpl, config_dir, %URI{} = agent_uri) do
    case bootstrap(tmpl, config_dir) do
      :ok ->
        {:ok, %{}}

      {:error, reason} ->
        Logger.warning(
          "cc.agent: orchestrator role-bootstrap failed for " <>
            "#{URI.to_string(agent_uri)}: #{inspect(reason)} — " <>
            "the agent will spawn as a plain cc agent (best-effort UX, " <>
            "SPEC 2026-05-26-session-create-orchestrator-unified Gap B); " <>
            "caller MUST surface the degraded status to the owner."
        )

        :telemetry.execute(
          [:ezagent, :cc, :role_bootstrap, :failed],
          %{count: 1},
          %{agent_uri: agent_uri, reason: reason, config_dir: config_dir}
        )

        {:ok, %{role_degraded: true, role_degraded_reason: reason}}
    end
  end

  @spec orchestrator_role?(map()) :: boolean()
  def orchestrator_role?(tmpl) when is_map(tmpl) do
    case Map.get(tmpl, "role") do
      "orchestrator" -> true
      :orchestrator -> true
      _ -> false
    end
  end

  def orchestrator_role?(_), do: false

  @spec resolve_orchestrator_skill_source() :: {:ok, String.t()} | {:error, term()}
  def resolve_orchestrator_skill_source do
    override = Application.get_env(:ezagent_plugin_cc, :orchestrator_skill_source)

    cond do
      is_binary(override) and override != "" ->
        if File.dir?(override),
          do: {:ok, override},
          else: {:error, {:skill_source_missing, override}}

      true ->
        search_orchestrator_skill_source()
    end
  end

  @spec search_orchestrator_skill_source_from(String.t()) ::
          {:ok, String.t()} | {:error, {:skill_source_not_found, [String.t()]}}
  def search_orchestrator_skill_source_from(start_dir) when is_binary(start_dir) do
    walk_for_skill(start_dir, [])
  end

  @spec hint_line() :: String.t()
  def hint_line, do: @orchestrator_hint_line

  defp search_orchestrator_skill_source do
    case :code.priv_dir(:ezagent_plugin_cc) do
      priv when is_list(priv) ->
        priv
        |> to_string()
        |> Path.expand()
        |> search_orchestrator_skill_source_from()

      _ ->
        {:error, {:skill_source_not_found, []}}
    end
  end

  defp walk_for_skill(dir, attempted) do
    candidate = Path.join(dir, @orchestrator_skill_relpath)
    marker = Path.join(candidate, @orchestrator_skill_marker_relpath)
    attempted = [candidate | attempted]

    cond do
      File.regular?(marker) ->
        {:ok, candidate}

      Path.dirname(dir) == dir ->
        {:error, {:skill_source_not_found, Enum.reverse(attempted)}}

      true ->
        walk_for_skill(Path.dirname(dir), attempted)
    end
  end

  defp copy_orchestrator_skill(source_dir, config_dir) do
    skills_root = Path.join(config_dir, "skills")
    dest_dir = Path.join(skills_root, "ezagent-session-orchestrator")

    cond do
      File.dir?(dest_dir) ->
        :ok

      true ->
        with :ok <- File.mkdir_p(skills_root),
             {:ok, _} <- File.cp_r(source_dir, dest_dir) do
          :ok
        else
          {:error, reason} -> {:error, {:skill_copy_failed, reason}}
          err -> {:error, {:skill_copy_failed, err}}
        end
    end
  end

  defp append_orchestrator_claude_md_hint(config_dir) do
    claude_md = Path.join(config_dir, "CLAUDE.md")

    existing =
      case File.read(claude_md) do
        {:ok, content} -> content
        {:error, :enoent} -> ""
        {:error, reason} -> {:error, reason}
      end

    case existing do
      {:error, reason} ->
        {:error, {:claude_md_hint_failed, reason}}

      content when is_binary(content) ->
        write_orchestrator_hint_if_missing(claude_md, content)
    end
  end

  defp write_orchestrator_hint_if_missing(claude_md, content) do
    if String.contains?(content, @orchestrator_hint_line) do
      :ok
    else
      new_content =
        if content == "" or String.ends_with?(content, "\n") do
          content <> @orchestrator_hint_line <> "\n"
        else
          content <> "\n" <> @orchestrator_hint_line <> "\n"
        end

      case File.write(claude_md, new_content) do
        :ok -> :ok
        {:error, reason} -> {:error, {:claude_md_hint_failed, reason}}
      end
    end
  end
end
