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
    # PR-2 config-evolve — shifted +6 by adding `Ezagent.Behavior.ConfigEvolve`
    # (+ its comment block) to `Agent.behaviors/0`; same sanctioned defs/call.
    # PR-6 (im/session/agent decomposition) — shifted +41/+40 by splitting
    # `Agent.behaviors/0` into `base_behaviors/0` + `curl_behaviors/0` +
    # `nil_capture_behavior_set/0` (the curl flavor fold); SAME sanctioned
    # `spawn/4` shim + `spawn_fresh/4` def + its single call site, lower lines.
    {"apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex", 229},
    {"apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex", 268},
    {"apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex", 270},
    # PR-3S — `spawn_fresh_member/8` (def) + its single call site moved VERBATIM
    # from `Orchestrator.Tools` to `Orchestrator.Tools.MemberTemplate` along with
    # the `update_member_template` regenerate cluster (gt_1000 4→3 extraction).
    {"apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools/member_template.ex",
     190},
    {"apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools/member_template.ex",
     223}
  ]

  @all_slices_sanctioned [
    # P1 (socialware substrate) — shifted 182→183 by the `instance_set_gate`
    # insertion into `handle_dispatch`'s `with` chain (runtime.ex E9). Same
    # sanctioned `:all_slices` comment, one line lower.
    # P2.5c — shifted 183→180: net comment trim in `handle_dispatch` (the
    # `deferred` 4-tuple bind added, but verbose @type/comment blocks
    # condensed to keep runtime.ex under the gt_1000 LOC gate).
    # P5-1b — shifted 180→168: condensed the PR-N3 cursor comment to absorb the
    # `instance_set_gate` denial-telemetry caller/target enrichment (audit
    # handler no longer detaches on a per-instance denial) under the LOC gate.
    {"apps/ezagent_core/lib/ezagent/kind/runtime.ex", 168},
    {"apps/ezagent_core/lib/ezagent/behavior.ex", 454},
    # PR-4 (agent-owned config-evolve) — shifted 271→272 when the #607
    # `system://agent-internal` Sandbox:read drop replaced the old #607 comment
    # block with a (one-line-longer) note above this ApiKeys-flip comment. Same
    # sanctioned `ctx[:all_slices][:api_keys]` mention, one line lower.
    {"apps/ezagent_core/lib/ezagent/system_principal/catalog.ex", 272}
  ]

  @runtime_file "apps/ezagent_core/lib/ezagent/kind/runtime.ex"
  @measure_cache_key {__MODULE__, :measure}

  # FF-1 — cross_file_duplicate_fn_groups.
  #
  # A function body is NOT counted as a fork when its `{name, arity}` is a
  # framework behaviour callback AND the *enclosing module* actually declares the
  # owning behaviour (via `use` / `@behaviour`). An identical callback body across
  # two modules that both `use GenServer` is a contract obligation, not a
  # copy-paste fork. Crucially the exemption is behaviour-SCOPED (codex r1 HIGH):
  # a plain production helper coincidentally named `update`/`render`/`init`/
  # `changeset` in a module that does NOT use the owning behaviour is still
  # counted, so a new fork cannot hide behind a callback-shaped name.
  #
  # `@dup_callback_owners` maps an owner's LAST module segment (matched exactly,
  # not as a substring — codex r2: a `use My.FancyComponents` must NOT match the
  # `Component` owner) against the `{name, arity}` callbacks that behaviour owns.
  # The marker must come from a `use X` / `@behaviour X` declared in the same
  # enclosing module.
  @dup_callback_owners %{
    "GenServer" => [
      {:init, 1},
      {:terminate, 2},
      {:handle_call, 3},
      {:handle_cast, 2},
      {:handle_info, 2},
      {:handle_continue, 2},
      {:code_change, 3},
      {:format_status, 1},
      {:format_status, 2}
    ],
    "Supervisor" => [{:init, 1}],
    "Application" => [{:start, 2}, {:stop, 1}],
    "LiveView" => [
      {:mount, 3},
      {:render, 1},
      {:handle_event, 3},
      {:handle_params, 3},
      {:handle_info, 2},
      {:terminate, 2}
    ],
    "LiveComponent" => [{:mount, 1}, {:render, 1}, {:update, 2}, {:handle_event, 3}],
    "Component" => [{:render, 1}],
    "Channel" => [{:join, 3}, {:handle_in, 3}, {:handle_info, 2}, {:terminate, 2}],
    "Schema" => [{:changeset, 2}],
    "Ecto" => [{:changeset, 2}],
    "Lifecycle" => [{:create, 1}, {:activate, 2}, {:deactivate, 2}, {:destroy, 1}],
    "Behavior" => [{:required_caps, 0}]
  }

  # `{name, arity}` exempt in EVERY module — universal OTP child-spec boilerplate
  # that is mechanically identical by design and not behaviour-gated.
  @dup_always_exempt MapSet.new([{:child_spec, 1}, {:start_link, 1}])

  # FF-1 — only bodies at least this many normalized chars are considered, so a
  # one-liner shared by coincidence (`do: :ok`) is not a "fork".
  @dup_fn_min_body_chars 120

  # FF-4 — the `/cc_socket` deprecation shim modules (promoted to the
  # `ezagent_domain_agent_bridge` domain). A non-`agent_bridge`/non-test lib file
  # that still references one — fully-qualified, via a grouped `alias` (codex r1
  # MEDIUM), or a renamed `alias ..., as: X` — is a caller of the shim. Cleanup-3
  # migrates these to the `Ezagent.AgentBridge.*` modules + deletes the shims,
  # ratcheting this to 0.
  @cc_bridge_shim_modules [
    [:EzagentPluginCc, :BridgeRegistry],
    [:EzagentPluginCc, :Socket],
    [:EzagentPluginCc, :Channel],
    [:EzagentPluginCc, :TokenStore]
  ]

  # The shim DEFINITION files themselves — a shim module referencing its own name
  # (its `defmodule`) is not a "caller".
  @cc_bridge_shim_files [
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/bridge_registry.ex",
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/socket.ex",
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/channel.ex",
    "apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/token_store.ex"
  ]

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
      # FF-1: generalizes duplicated_resolve_template_class (which counts ONE
      # known forked function by name) to the whole tree — every group of ≥2 lib
      # files sharing a byte-identical (whitespace-normalized) function body.
      # `duplicated_resolve_template_class` stays as the targeted ratchet for that
      # specific fork; FF-1 is the broad fitness function for fork accretion.
      cross_file_duplicate_fn_groups: cross_file_duplicate_fn_groups(),
      cc_bridge_shim_callers: cc_bridge_shim_callers(),
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

  # FF-1 — count groups of cross-file duplicate function bodies.
  #
  # A "group" is a set of ≥2 DISTINCT lib files that each define a `def`/`defp`
  # whose body — extracted via the real Elixir parser (so brace/`do`/`end`
  # nesting is exact, not a line heuristic) and whitespace-normalized — is
  # byte-identical and at least `@dup_fn_min_body_chars` chars. A
  # behaviour-callback `{name, arity}` is excluded ONLY when its enclosing module
  # declares the owning behaviour (codex r1 HIGH — name-only exemption let a new
  # fork hide behind a callback-shaped name); `# arch-allow:` on the `def`/`defp`
  # line suppresses one specific leg.
  defp cross_file_duplicate_fn_groups do
    lib_files()
    |> Enum.flat_map(&duplicate_candidate_functions/1)
    |> Enum.group_by(fn {_key, norm, _file} -> norm end)
    |> Enum.count(fn {_norm, occurrences} ->
      occurrences
      |> Enum.map(fn {_key, _norm, file} -> file end)
      |> Enum.uniq()
      |> length() >= 2
    end)
  end

  # Countable functions in `file` as `[{{name, arity}, normalized_fn, file}]`.
  #
  # Per ENCLOSING module (codex r2 MEDIUM — exemptions/markers are scoped to the
  # module that owns the function, never file-wide), with all clauses of a
  # `{name, arity}` AGGREGATED into one normalized representation BEFORE the
  # length threshold (codex r2 MEDIUM — a copied multi-clause fork whose
  # individual clauses are each <120 chars is still counted on its aggregate).
  defp duplicate_candidate_functions(file) do
    case Code.string_to_quoted(read!(file)) do
      {:ok, ast} ->
        allowed_lines = arch_allowed_lines(file)

        ast
        |> modules_with_functions()
        |> Enum.flat_map(fn {markers, clauses} ->
          exempt = exempt_callbacks(markers)

          clauses
          # aggregate clauses by {name, arity} → one normalized fn + its min line
          |> Enum.group_by(fn {key, _norm, _line} -> key end)
          |> Enum.map(fn {key, group} ->
            agg = group |> Enum.map(fn {_k, norm, _l} -> norm end) |> Enum.join(" ; ")

            all_allowed? =
              Enum.all?(group, fn {_k, _n, line} -> MapSet.member?(allowed_lines, line) end)

            {key, agg, all_allowed?}
          end)
          |> Enum.reject(fn {key, agg, all_allowed?} ->
            MapSet.member?(@dup_always_exempt, key) or
              MapSet.member?(exempt, key) or
              String.length(agg) < @dup_fn_min_body_chars or
              all_allowed?
          end)
          |> Enum.map(fn {key, agg, _allowed?} -> {key, agg, file} end)
        end)

      {:error, _} ->
        []
    end
  end

  # Each `defmodule` in the AST as `{behaviour_markers, [{key, norm, line}]}` —
  # the module's OWN `use`/`@behaviour` markers paired with the `def`/`defp`
  # clauses lexically inside THAT module's body (nested modules are returned as
  # their own entries via the recursive walk). A non-`defmodule` top form
  # (rare in lib) contributes its bare functions under empty markers.
  defp modules_with_functions(ast) do
    Macro.prewalk(ast, [], fn node, acc ->
      case node do
        {:defmodule, _meta, [_name, [{:do, body} | _]]} ->
          {node, [{module_own_markers(body), module_own_clauses(body)} | acc]}

        _ ->
          {node, acc}
      end
    end)
    |> elem(1)
  end

  # `use X` / `@behaviour X` markers declared DIRECTLY in this module body
  # (stops at a nested `defmodule`, whose markers belong to it, not the parent).
  defp module_own_markers(body) do
    body
    |> top_level_forms()
    |> Enum.flat_map(fn
      {:use, _m, [{:__aliases__, _, mods} | _]} when is_list(mods) -> [dotted(mods)]
      {:@, _m, [{:behaviour, _, [{:__aliases__, _, mods}]}]} when is_list(mods) -> [dotted(mods)]
      _ -> []
    end)
  end

  # `def`/`defp` clauses declared DIRECTLY in this module body (not inside a
  # nested defmodule) as `[{{name, arity}, normalized_body, line}]`.
  defp module_own_clauses(body) do
    body
    |> top_level_forms()
    |> Enum.flat_map(fn
      {kw, meta, [head, [{:do, fbody} | _]]} when kw in [:def, :defp] ->
        case fn_key(head) do
          nil -> []
          key -> [{key, normalize_body(fbody), Keyword.get(meta, :line, 0)}]
        end

      _ ->
        []
    end)
  end

  # The direct child forms of a module/`do` body: a `{:__block__, _, forms}`
  # holds many; a single-statement body is the lone form.
  defp top_level_forms({:__block__, _meta, forms}) when is_list(forms), do: forms
  defp top_level_forms(form), do: [form]

  # The `{name, arity}` callbacks exempt in a module with these markers: the
  # union of callback sets whose owning behaviour's LAST module segment matches a
  # marker's last segment (exact-segment, not substring — codex r2 MEDIUM: a
  # `*Components` use must not match the `Component` owner). A module that does
  # not declare the owner does NOT get its callbacks exempted.
  defp exempt_callbacks(markers) do
    marker_segments = MapSet.new(markers, &last_segment/1)

    @dup_callback_owners
    |> Enum.flat_map(fn {owner, callbacks} ->
      if MapSet.member?(marker_segments, owner), do: callbacks, else: []
    end)
    |> MapSet.new()
  end

  defp last_segment(dotted), do: dotted |> String.split(".") |> List.last()

  defp dotted(mods), do: Enum.map_join(mods, ".", &Atom.to_string/1)

  defp fn_key({:when, _meta, [head | _]}), do: fn_key(head)
  defp fn_key({name, _meta, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp fn_key({name, _meta, nil}) when is_atom(name), do: {name, 0}
  defp fn_key(_), do: nil

  defp normalize_body(body) do
    body
    |> Macro.to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # FF-4 — count distinct non-`agent_bridge`/non-test lib files that still
  # reference a `/cc_socket` deprecation-shim module. Counts caller FILES (the
  # goal is "how many modules are coupled to the shim", which Cleanup-3 ratchets
  # to 0). AST-based so a grouped `alias EzagentPluginCc.{BridgeRegistry, ...}` or
  # a renamed `alias EzagentPluginCc.BridgeRegistry, as: X` is caught too (codex
  # r1 MEDIUM) — a raw fully-qualified-string regex misses both.
  defp cc_bridge_shim_callers do
    shim_set = MapSet.new(@cc_bridge_shim_modules)

    lib_files()
    |> Enum.reject(fn file ->
      file in @cc_bridge_shim_files or String.contains?(file, "/ezagent_domain_agent_bridge/")
    end)
    |> Enum.count(&file_references_shim?(&1, shim_set))
  end

  # True iff `file` references any shim module, whether fully-qualified, via a
  # plain/grouped `alias`, or a renamed `alias ..., as: X` whose alias is then
  # used as a remote-call/reference target. `# arch-allow:` on the line suppresses.
  defp file_references_shim?(file, shim_set) do
    case Code.string_to_quoted(read!(file)) do
      {:ok, ast} ->
        allowed_lines = arch_allowed_lines(file)
        aliases = shim_alias_names(ast, shim_set)
        shim_reference?(ast, shim_set, aliases, allowed_lines)

      {:error, _} ->
        # Parse failure: fall back to a conservative fully-qualified text scan so
        # an unparseable file still can't silently hide a shim caller.
        regex = cc_bridge_shim_fqn_regex()

        file
        |> file_lines()
        |> Enum.any?(fn {line, _no} ->
          not String.contains?(line, "# arch-allow:") and Regex.match?(regex, line)
        end)
    end
  end

  # Set of single-segment alias atoms that resolve to a shim module:
  # `alias EzagentPluginCc.BridgeRegistry` → :BridgeRegistry;
  # `alias EzagentPluginCc.{Socket, Channel}` → :Socket, :Channel;
  # `alias EzagentPluginCc.TokenStore, as: TS` → :TS.
  defp shim_alias_names(ast, shim_set) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # alias A.B.C, as: X
          {:alias, _m, [{:__aliases__, _, mods}, opts]} when is_list(mods) and is_list(opts) ->
            if MapSet.member?(shim_set, mods) do
              case Keyword.get(opts, :as) do
                {:__aliases__, _, [as_atom]} -> {node, [as_atom | acc]}
                _ -> {node, [List.last(mods) | acc]}
              end
            else
              {node, acc}
            end

          # alias A.B.C  (plain)
          {:alias, _m, [{:__aliases__, _, mods}]} when is_list(mods) ->
            if MapSet.member?(shim_set, mods),
              do: {node, [List.last(mods) | acc]},
              else: {node, acc}

          # alias A.B.{C, D}  (grouped)
          {:alias, _m, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} ->
            grouped =
              for {:__aliases__, _, child_mods} <- children,
                  MapSet.member?(shim_set, base ++ child_mods),
                  do: List.last(child_mods)

            {node, grouped ++ acc}

          _ ->
            {node, acc}
        end
      end)

    MapSet.new(names)
  end

  # True iff the AST contains a fully-qualified shim module reference OR a use of
  # one of the resolved single-segment shim aliases.
  defp shim_reference?(ast, shim_set, aliases, allowed_lines) do
    {_ast, hit?} =
      Macro.prewalk(ast, false, fn node, acc ->
        if acc do
          {node, acc}
        else
          {node, acc or shim_node?(node, shim_set, aliases, allowed_lines)}
        end
      end)

    hit?
  end

  defp shim_node?({:__aliases__, meta, mods}, shim_set, aliases, allowed_lines)
       when is_list(mods) do
    not line_allowed?(meta, allowed_lines) and
      (MapSet.member?(shim_set, mods) or
         (match?([_single], mods) and MapSet.member?(aliases, List.first(mods))))
  end

  defp shim_node?(_node, _shim_set, _aliases, _allowed_lines), do: false

  defp line_allowed?(meta, allowed_lines) do
    MapSet.member?(allowed_lines, Keyword.get(meta, :line, 0))
  end

  defp arch_allowed_lines(file) do
    file
    |> file_lines()
    |> Enum.filter(fn {line, _no} -> String.contains?(line, "# arch-allow:") end)
    |> Enum.map(fn {_line, no} -> no end)
    |> MapSet.new()
  end

  # Conservative fully-qualified fallback regex (parse-failure path only).
  defp cc_bridge_shim_fqn_regex do
    alternation = Enum.map_join(@cc_bridge_shim_modules, "|", &dotted/1)
    Regex.compile!("(#{alternation})(?![A-Za-z0-9_])")
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
