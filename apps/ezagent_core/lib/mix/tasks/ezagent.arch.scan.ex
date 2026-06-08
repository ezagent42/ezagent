defmodule Mix.Tasks.Ezagent.Arch.Scan do
  @shortdoc "Scan architecture fitness-function counters"

  @moduledoc """
  > **Architecture deepening Phase 2 — Category A dev-loop tool.**
  > Like `mix ezagent.check_invariants`, this is a source-tree scan
  > that runs without relying on the runtime BEAM. It intentionally
  > stays under `mix ezagent.arch.*`.

  Prints each architecture fitness function, the measured count, the
  baseline cap from `test/architecture/arch_baseline_manifest.exs`, and
  PASS/FAIL. Architecture tests reuse `measure/0` and assert the
  green-at-baseline ratchet: measured count <= manifest cap.

  Suppression: a source line containing `# arch-allow:` is excluded from
  line-based counters. Manifest cap raises must carry
  `# arch-cap-bump: <reason>` and are checked by the ExUnit suite.
  """
  use Mix.Task

  @scanner_path "apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex"
  @manifest_path "apps/ezagent_core/test/architecture/arch_baseline_manifest.exs"

  @def_count_files %{
    def_count_admin_live:
      "apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex",
    def_count_cc_agent: "apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex",
    def_count_orchestrator_tools:
      "apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools.ex",
    def_count_session_creator:
      "apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex",
    def_count_capability: "apps/ezagent_core/lib/ezagent/capability.ex"
  }

  @template_class_files [
    "apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex",
    "apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex"
  ]

  @spawn_registry_sanctioned_files [
    "apps/ezagent_core/lib/ezagent/spawn_registry.ex",
    "apps/ezagent_core/lib/ezagent/invocation.ex",
    "apps/ezagent_core/lib/ezagent_core/application.ex",
    "apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex",
    "apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex",
    "apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex",
    "apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex"
  ]

  @spawn_fresh_sanctioned [
    {"apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex", 182},
    {"apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex", 221},
    {"apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex", 223},
    {"apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools.ex", 281},
    {"apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools.ex", 552}
  ]

  @all_slices_sanctioned [
    {"apps/ezagent_core/lib/ezagent/kind/runtime.ex", 182},
    {"apps/ezagent_core/lib/ezagent/behavior.ex", 454},
    {"apps/ezagent_core/lib/ezagent/system_principal/catalog.ex", 271}
  ]

  @runtime_file "apps/ezagent_core/lib/ezagent/kind/runtime.ex"
  @measure_cache_key {__MODULE__, :measure}

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("ezagent.arch.scan — architecture fitness functions")

    manifest = manifest()

    results =
      measure()
      |> Enum.map(fn {name, count} ->
        cap = Map.fetch!(manifest, name)
        status = if count <= cap, do: "PASS", else: "FAIL"
        {status, name, count, cap}
      end)

    Enum.each(results, fn {status, name, count, cap} ->
      Mix.shell().info("  #{status} #{name}: count=#{count} cap=#{cap}")
    end)

    failures = Enum.reject(results, fn {status, _name, _count, _cap} -> status == "PASS" end)

    if failures == [] do
      :ok
    else
      Mix.raise("ezagent.arch.scan: #{length(failures)} architecture counter(s) above cap")
    end
  end

  @doc false
  def count(name) when is_atom(name) do
    measure()
    |> Map.new()
    |> Map.fetch!(name)
  end

  @doc false
  def measure do
    case :persistent_term.get(@measure_cache_key, :missing) do
      :missing ->
        results = do_measure()
        :persistent_term.put(@measure_cache_key, results)
        results

      results ->
        results
    end
  end

  defp do_measure do
    oversized = oversized_modules()
    spawn_hits = grep(~r/SpawnRegistry\.spawn(?:_detailed)?\(/)
    create_session_hits = grep(~r/\.create_session\(/)
    spawn_fresh_hits = grep(~r/spawn_fresh(?:_member)?\(/, skip_comment_lines?: true)
    all_slices_hits = grep(~r/:all_slices/)
    set_effect_hits = grep(~r/\{:set,\s*:[a-z_]+,/)

    [
      oversized_modules_gt_1500: count_oversized(oversized, 1500),
      oversized_modules_gt_1000: count_oversized(oversized, 1000),
      def_count_admin_live: def_count(:def_count_admin_live),
      def_count_cc_agent: def_count(:def_count_cc_agent),
      def_count_orchestrator_tools: def_count(:def_count_orchestrator_tools),
      def_count_session_creator: def_count(:def_count_session_creator),
      def_count_capability: def_count(:def_count_capability),
      spawn_registry_call_sites: length(spawn_hits),
      spawn_registry_modules: spawn_hits |> unique_files() |> length(),
      spawn_registry_off_chokepoint_modules:
        spawn_hits
        |> unique_files()
        |> Enum.reject(&(&1 in @spawn_registry_sanctioned_files))
        |> length(),
      create_session_call_sites: length(create_session_hits),
      create_session_modules: create_session_hits |> unique_files() |> length(),
      duplicated_resolve_template_class: duplicated_resolve_template_class(),
      cc_codex_template_class_combined_loc:
        @template_class_files |> Enum.map(&line_count/1) |> Enum.sum(),
      raw_home_path_outside_core: raw_home_path_outside_core(),
      path_expand_home: length(grep(~r/Path\.expand\("~/)),
      spawn_fresh_audit_references: length(spawn_fresh_hits),
      spawn_fresh_unsanctioned: unsanctioned_count(spawn_fresh_hits, @spawn_fresh_sanctioned),
      all_slices_occurrences: length(all_slices_hits),
      all_slices_unsanctioned: unsanctioned_count(all_slices_hits, @all_slices_sanctioned),
      set_effect_sites: length(set_effect_hits),
      cross_slice_set_violations: cross_slice_set_violations(set_effect_hits),
      missing_cap_check_mutating_actions: missing_cap_check_mutating_actions(),
      kind_runtime_ordering_violations: kind_runtime_ordering_violations(),
      kind_runtime_reentry_violations: kind_runtime_reentry_violations(),
      cold_restart_respawn_round_trip_drift: cold_restart_respawn_round_trip_drift()
    ]
  end

  defp manifest do
    @manifest_path
    |> Code.eval_file()
    |> elem(0)
  end

  defp repo_root do
    cwd = File.cwd!()
    if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
  end

  defp lib_files do
    repo_root()
    |> Path.join("apps/*/lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&relative/1)
    |> Enum.reject(&excluded_file?/1)
    |> Enum.sort()
  end

  defp excluded_file?(path) do
    path == @scanner_path or String.contains?(path, "/test/")
  end

  defp relative(path), do: Path.relative_to(path, repo_root())

  defp absolute(path), do: Path.join(repo_root(), path)

  defp grep(regex, opts \\ []) do
    skip_comment_lines? = Keyword.get(opts, :skip_comment_lines?, false)

    for file <- lib_files(),
        {line, line_no} <- file_lines(file),
        not String.contains?(line, "# arch-allow:"),
        not (skip_comment_lines? and comment_line?(line)),
        Regex.match?(regex, line) do
      {file, line_no, String.trim(line)}
    end
  end

  defp file_lines(file) do
    file
    |> absolute()
    |> File.stream!()
    |> Enum.with_index(1)
  end

  defp comment_line?(line), do: line |> String.trim_leading() |> String.starts_with?("#")

  defp unique_files(hits) do
    hits
    |> Enum.map(fn {file, _line_no, _line} -> file end)
    |> Enum.uniq()
  end

  defp line_count(file) do
    file
    |> absolute()
    |> File.stream!()
    |> Enum.count()
  end

  defp oversized_modules do
    lib_files()
    |> Enum.map(fn file -> {file, line_count(file)} end)
  end

  defp count_oversized(files, threshold) do
    Enum.count(files, fn {_file, count} -> count > threshold end)
  end

  defp def_count(name) do
    @def_count_files
    |> Map.fetch!(name)
    |> file_lines()
    |> Enum.count(fn {line, _line_no} ->
      Regex.match?(~r/^\s*(def|defp)\s+/, line)
    end)
  end

  defp duplicated_resolve_template_class do
    grep(~r/^\s*defp?\s+resolve_template_class/)
    |> Enum.reject(fn {_file, _line_no, line} ->
      Regex.match?(~r/resolve_template_class\(_\)/, line)
    end)
    |> length()
  end

  defp raw_home_path_outside_core do
    grep(~r/Home\.path\(/)
    |> Enum.reject(fn {file, _line_no, _line} ->
      String.starts_with?(file, "apps/ezagent_core/")
    end)
    |> length()
  end

  defp unsanctioned_count(hits, sanctioned) do
    sanctioned = MapSet.new(sanctioned)

    hits
    |> Enum.reject(fn {file, line_no, _line} -> MapSet.member?(sanctioned, {file, line_no}) end)
    |> length()
  end

  defp cross_slice_set_violations(set_effect_hits) do
    known_slices = known_state_slices()

    set_effect_hits
    |> Enum.filter(fn {file, _line_no, line} ->
      case set_effect_key(line) do
        nil ->
          false

        key ->
          owner = file_state_slice(file)
          MapSet.member?(known_slices, key) and owner != key
      end
    end)
    |> length()
  end

  defp known_state_slices do
    lib_files()
    |> Enum.flat_map(fn file ->
      file
      |> file_lines()
      |> Enum.flat_map(fn {line, _line_no} ->
        cond do
          match = Regex.run(~r/state_slice:\s*:([a-z_]+)/, line) ->
            [String.to_atom(Enum.at(match, 1))]

          match = Regex.run(~r/def\s+state_slice,\s*do:\s*:([a-z_]+)/, line) ->
            [String.to_atom(Enum.at(match, 1))]

          true ->
            []
        end
      end)
    end)
    |> MapSet.new()
  end

  defp file_state_slice(file) do
    file
    |> file_lines()
    |> Enum.find_value(fn {line, _line_no} ->
      cond do
        match = Regex.run(~r/state_slice:\s*:([a-z_]+)/, line) ->
          String.to_atom(Enum.at(match, 1))

        match = Regex.run(~r/def\s+state_slice,\s*do:\s*:([a-z_]+)/, line) ->
          String.to_atom(Enum.at(match, 1))

        true ->
          nil
      end
    end)
  end

  defp set_effect_key(line) do
    case Regex.run(~r/\{:set,\s*:([a-z_]+),/, line) do
      [_, key] -> String.to_atom(key)
      _ -> nil
    end
  end

  defp missing_cap_check_mutating_actions do
    invariant_test =
      "apps/ezagent_core/test/ezagent/behavior_required_caps_action_invariant_test.exs"

    runtime = read!(@runtime_file)

    cond do
      not File.exists?(absolute(invariant_test)) ->
        1

      not String.contains?(runtime, "behavior_module.required_caps()") ->
        1

      not String.contains?(runtime, "Capability.matches?") ->
        1

      true ->
        0
    end
  end

  defp kind_runtime_ordering_violations do
    runtime = read!(@runtime_file)

    authz = index_of(runtime, "authz_check(")
    workspace = index_of(runtime, "workspace_isolation_check(")
    invoke = index_of(runtime, "invoke_behavior(")

    if ordered?([authz, workspace, invoke]), do: 0, else: 1
  end

  defp kind_runtime_reentry_violations do
    runtime = read!(@runtime_file)
    target_ownership = function_body(runtime, "target_ownership_check")
    event_to_payload = function_body(runtime, "event_to_payload")

    [target_ownership, event_to_payload]
    |> Enum.count(fn body ->
      String.contains?(body, "Invocation.dispatch(") or String.contains?(body, "Router.dispatch(")
    end)
  end

  defp cold_restart_respawn_round_trip_drift do
    required_gates = [
      {"apps/ezagent_core/test/e2e/scenario_25_phx_restart_rebuild_test.exs",
       ["snapshot", "restart"]},
      {"apps/ezagent_core/test/integration/snapshot_restart_test.exs", ["caps", "restart"]},
      {"apps/ezagent_core/test/ezagent/behavior/sandbox_cold_restart_test.exs",
       ["respawn_template_data", "cold"]}
    ]

    Enum.count(required_gates, fn {file, needles} ->
      not File.exists?(absolute(file)) or
        not Enum.all?(needles, &String.contains?(read!(file), &1))
    end)
  end

  defp ordered?(indexes) do
    Enum.all?(indexes, &is_integer/1) and indexes == Enum.sort(indexes)
  end

  defp index_of(contents, needle) do
    case :binary.match(contents, needle) do
      {idx, _len} -> idx
      :nomatch -> nil
    end
  end

  defp function_body(contents, name) do
    case Regex.run(~r/defp?\s+#{Regex.escape(name)}\b[\s\S]*?(?=\n\s*defp?\s|\z)/, contents) do
      [body] -> body
      _ -> ""
    end
  end

  defp read!(file), do: file |> absolute() |> File.read!()
end
