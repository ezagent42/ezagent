defmodule Ezagent.Architecture.ImSessionAgentAcyclicTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Arch-fitness invariant for the **im → session → agent** 3-domain split (#53,
  the socialware 基座化 milestone).

  A behavioral test can NOT prove the split: the pre-split monolith passes the
  same send/receive/route scenarios. So this STRUCTURAL invariant — the app
  dependency graph + cross-layer symbol references — is the completion gate
  (memory `feedback_completion_requires_invariant_test`).

  It is **compile-dependency based**: app edges come from each `mix.exs`'s
  `in_umbrella` deps, and symbol references are collected from the **AST**
  (`Code.string_to_quoted` + `__aliases__` walk), so a module named only inside
  a comment or `@doc`/`@moduledoc` string is NOT counted — only real
  `alias`/qualified-call/`%struct{}` references are.

  The `@allowlist_*` lists hold the cross-layer references that still exist while
  the split lands incrementally (PR-9a→9c). **The completion invariant (handoff
  §8) is every allowlist EMPTY** — the gate PR-9c must reach. The
  `scripts/socialware_substrate_gate.sh` milestone script keys on this test.

  ## agent → plugin edge (PR-9c)

  The `in_umbrella` leaf test below proves the agent app declares no COMPILE
  dep on a plugin. But several plugin modules live in the SHARED `Ezagent.*`
  namespace (`Ezagent.ActionSet.CurlAgent`, `Ezagent.ActionSet.PyAgent`,
  `Ezagent.Orchestrator.McpChannel`, …), so a bare-atom runtime reference to
  one — exactly the shape `Entity.Agent.behaviors/0` used to have for the curl
  state behavior — slips past the dep-graph test. The "agent domain has NO
  compile reference to a plugin-defined module" test closes that blind spot: it
  builds a `module → defining-app` index from every app's `defmodule`
  declarations (so detection is by DEFINING APP, not naming convention) and
  asserts no agent-domain symbol resolves to a module a plugin app defines.
  PR-9c reparented `Behavior.CurlAgent` into this domain, so the allowlist is [].
  """

  @moduletag :umbrella_only

  @repo_root Path.expand("../../../..", __DIR__)

  @agent_app :ezagent_domain_agent
  @session_app :ezagent_domain_session
  @im_apps [:ezagent_plugin_feishu]

  # The agent Kind's two DynamicSupervisors keep their PRE-SPLIT name atoms
  # (brief D1a freeze — `routing_rules`/call-site stability). They live in the
  # `EzagentDomainInstanceMessage.*` namespace but are process-NAME atoms, not a
  # dependency on the session app's code. Sanctioned exception.
  @frozen_supervisor_names [
    EzagentDomainInstanceMessage.AgentSupervisor,
    EzagentDomainInstanceMessage.AgentTemplateSupervisor
  ]

  # ── Allowlists (shrink to [] by PR-9c — handoff §8 completion invariant) ──
  @allowlist_im_to_agent []
  @allowlist_session_to_mcp []
  @allowlist_agent_to_plugin []

  describe "im → session → agent acyclic dependency graph" do
    test "ezagent_domain_agent is a LEAF: in_umbrella deps ⊆ {core, agent_bridge, identity}" do
      deps = umbrella_dep_graph() |> Map.fetch!(@agent_app) |> MapSet.new()

      allowed =
        MapSet.new([:ezagent_core, :ezagent_domain_agent_bridge, :ezagent_domain_identity])

      extra = MapSet.difference(deps, allowed)

      assert MapSet.size(extra) == 0,
             "ezagent_domain_agent must depend ONLY on core + agent_bridge + identity " <>
               "(im → session → agent leaf); forbidden deps: #{inspect(MapSet.to_list(extra))}"
    end

    test "layering is acyclic: agent ⊅ session/im, session ⊅ im (in_umbrella deps)" do
      graph = umbrella_dep_graph()
      agent_deps = MapSet.new(Map.fetch!(graph, @agent_app))
      session_deps = MapSet.new(Map.fetch!(graph, @session_app))

      up_from_agent = MapSet.intersection(agent_deps, MapSet.new([@session_app | @im_apps]))
      up_from_session = MapSet.intersection(session_deps, MapSet.new(@im_apps))

      assert MapSet.size(up_from_agent) == 0,
             "agent must not depend on session/im: #{inspect(MapSet.to_list(up_from_agent))}"

      assert MapSet.size(up_from_session) == 0,
             "session must not depend on im: #{inspect(MapSet.to_list(up_from_session))}"
    end

    test "the agent domain has NO compile reference to a session symbol" do
      offenders =
        app_modules_refs(@agent_app)
        |> filter_refs(fn m -> session_symbol?(m) and m not in @frozen_supervisor_names end)

      assert offenders == [],
             "agent-domain modules must not reference session symbols " <>
               "(im → session → agent acyclic). Offenders:\n" <> format(offenders)
    end

    test "im (feishu) has NO compile reference to an agent Kind / agent.receive" do
      offenders =
        Enum.flat_map(@im_apps, &app_modules_refs/1)
        |> filter_refs(&agent_symbol?/1)
        |> reject_allowlisted(@allowlist_im_to_agent)

      assert offenders == [],
             "im (feishu) must address only the session — no agent Kind / " <>
               "agent.receive symbol (goal #1). Offenders:\n" <> format(offenders)
    end

    test "session has NO compile reference to the orchestrator-MCP transport" do
      offenders =
        app_modules_refs(@session_app)
        |> filter_refs(&mcp_transport_symbol?/1)
        |> reject_allowlisted(@allowlist_session_to_mcp)

      assert offenders == [],
             "session must not name the MCP transport (relocated to cc in PR-8; " <>
               "driven via OrchestratorContextPort). Offenders:\n" <> format(offenders)
    end

    test "the agent domain has NO compile reference to a plugin-defined module" do
      index = defmodule_app_index()

      offenders =
        app_modules_refs(@agent_app)
        |> Enum.filter(fn {_rel, m} ->
          case Map.get(index, m) do
            nil -> false
            app -> plugin_app?(app)
          end
        end)
        |> reject_allowlisted(@allowlist_agent_to_plugin)

      assert offenders == [],
             "agent domain must reference NO plugin-defined module — it is the " <>
               "im → session → agent LEAF (the curl STATE behavior was reparented " <>
               "into this domain in PR-9c; flavor WIRING stays in the plugin, which " <>
               "depends on the domain, not the reverse). Offenders:\n" <> format(offenders)
    end
  end

  # ── symbol predicates ────────────────────────────────────────────────────

  defp session_symbol?(m) do
    s = inspect(m)

    String.starts_with?(s, "Ezagent.ActionSet.Session") or
      String.starts_with?(s, "Ezagent.Entity.Session") or
      String.starts_with?(s, "Ezagent.ActionSet.Chat") or
      String.contains?(s, "SessionCreator")
  end

  defp agent_symbol?(m) do
    s = inspect(m)
    s == "Ezagent.Entity.Agent" or String.starts_with?(s, "Ezagent.ActionSet.Agent.")
  end

  defp mcp_transport_symbol?(m) do
    s = inspect(m)

    s in [
      "Ezagent.Orchestrator.McpChannel",
      "Ezagent.Orchestrator.McpSocket",
      "Ezagent.Orchestrator.McpRegistry",
      "Ezagent.Orchestrator.LiveJoinRegistry"
    ]
  end

  # A plugin app by umbrella convention (`Ezagent.<Category>` §13): every
  # plugin OTP app atom is `:ezagent_plugin_<name>`.
  defp plugin_app?(app), do: app |> Atom.to_string() |> String.starts_with?("ezagent_plugin_")

  # ── AST-based module-reference collection ─────────────────────────────────

  # [{relative_path, module_atom}] for every `__aliases__` node in the app's lib.
  defp app_modules_refs(app) do
    Path.wildcard(Path.join(@repo_root, "apps/#{app}/lib/**/*.ex"))
    |> Enum.flat_map(fn file ->
      rel = Path.relative_to(file, @repo_root)

      file
      |> File.read!()
      |> Code.string_to_quoted!(
        warn_on_unnecessary_quotes: false,
        emit_warnings: false
      )
      |> collect_aliases()
      |> Enum.map(&{rel, &1})
    end)
  rescue
    e -> flunk("AST parse failed: #{Exception.message(e)}")
  end

  defp collect_aliases(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:__aliases__, _, parts} = node, acc when is_list(parts) ->
          if Enum.all?(parts, &is_atom/1) do
            {node, [Module.concat(parts) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(acc)
  end

  # `%{defined_module => owning_app}` for EVERY app's lib — the source of
  # truth for "which app DEFINES this module" (PR-9c agent → plugin test).
  # Resolution is by `defmodule`, NOT naming convention, because plugin
  # modules live in the shared `Ezagent.*` namespace just as much as domain
  # ones do (`Ezagent.ActionSet.CurlAgent` vs `Ezagent.ActionSet.Agent.Receive`).
  defp defmodule_app_index do
    Path.wildcard(Path.join(@repo_root, "apps/*/lib/**/*.ex"))
    |> Enum.flat_map(fn file ->
      app =
        file
        |> Path.relative_to(@repo_root)
        |> Path.split()
        |> Enum.at(1)
        |> String.to_atom()

      file
      |> File.read!()
      |> Code.string_to_quoted!(warn_on_unnecessary_quotes: false, emit_warnings: false)
      |> collect_defmodules()
      |> Enum.map(&{&1, app})
    end)
    |> Map.new()
  rescue
    e -> flunk("defmodule index parse failed: #{Exception.message(e)}")
  end

  defp collect_defmodules(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, _body]} = node, acc
        when is_list(parts) ->
          if Enum.all?(parts, &is_atom/1) do
            {node, [Module.concat(parts) | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.uniq(acc)
  end

  defp filter_refs(refs, pred), do: Enum.filter(refs, fn {_rel, m} -> pred.(m) end)

  defp reject_allowlisted(offenders, allowlist) do
    Enum.reject(offenders, fn {rel, m} -> {rel, m} in allowlist end)
  end

  # ── umbrella dep graph (app → [in_umbrella dep apps]) ─────────────────────

  defp umbrella_dep_graph do
    Path.wildcard(Path.join(@repo_root, "apps/*/mix.exs"))
    |> Map.new(fn mix_exs ->
      app = mix_exs |> Path.dirname() |> Path.basename() |> String.to_atom()

      deps =
        Regex.scan(~r/\{:(\w+),\s*in_umbrella:\s*true/, File.read!(mix_exs))
        |> Enum.map(fn [_, dep] -> String.to_atom(dep) end)
        |> Enum.uniq()

      {app, deps}
    end)
  end

  defp format(offenders) do
    offenders
    |> Enum.map(fn {rel, m} -> "  #{rel}: #{inspect(m)}" end)
    |> Enum.uniq()
    |> Enum.join("\n")
  end
end
