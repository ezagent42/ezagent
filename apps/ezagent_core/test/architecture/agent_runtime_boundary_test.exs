defmodule EzagentCore.AgentRuntimeBoundaryTest do
  use ExUnit.Case, async: true

  alias EzagentCore.AgentRuntimeBoundaryScanner, as: Scanner

  @repo_root Path.expand("../../../..", __DIR__)
  @session_glob Path.join([
                  @repo_root,
                  "apps",
                  "ezagent_domain_session",
                  "lib",
                  "**",
                  "*.ex"
                ])

  @session_agent_facade Path.join([
                          @repo_root,
                          "apps",
                          "ezagent_domain_session",
                          "lib",
                          "ezagent",
                          "domain",
                          "agent.ex"
                        ])
  @owned_agent_facade Path.join([
                        @repo_root,
                        "apps",
                        "ezagent_domain_agent",
                        "lib",
                        "ezagent",
                        "domain",
                        "agent.ex"
                      ])
  @agent_mix Path.join([@repo_root, "apps", "ezagent_domain_agent", "mix.exs"])

  @allowlist []

  test "repository Agent runtime crossings are exactly allowlisted" do
    paths = Path.wildcard(@session_glob)
    assert paths != []

    result =
      paths
      |> Scanner.scan_paths()
      |> Scanner.validate_allowlist(@allowlist, @repo_root)

    assert result.unmatched_allowances == []
    assert result.multiply_matched_allowances == []
    assert result.unallowlisted_offenders == []
    assert result.invalid_allowances == []
  end

  test "Agent lifecycle facade is owned by domain-agent without a reverse session or plugin dependency" do
    refute File.exists?(@session_agent_facade)
    assert File.exists?(@owned_agent_facade)

    facade_source = File.read!(@owned_agent_facade)
    assert facade_source =~ "defmodule Ezagent.Domain.Agent do"

    dependency_source = File.read!(@agent_mix)
    refute dependency_source =~ "{:ezagent_domain_session,"
    refute dependency_source =~ ~r/{:ezagent_plugin_[a-z0-9_]+,/
  end

  test "validator reports a stale exact allowance" do
    allowance = %{
      path: "lib/session.ex",
      class: :agent_materialization,
      source_anchor: "Ezagent.Entity.Agent.spawn_from_manifest(",
      reason: "ARB-3 fixture"
    }

    assert %{unmatched_allowances: [^allowance]} =
             Scanner.validate_allowlist([], [allowance], "/repo")
  end

  test "validator reports an allowance that matches multiple offenders" do
    offenders = [
      fixture_offender(2, "Ezagent.Entity.Agent.spawn_from_manifest("),
      fixture_offender(7, "Ezagent.Entity.Agent.spawn_from_manifest(")
    ]

    allowance = %{
      path: "lib/session.ex",
      class: :agent_materialization,
      source_anchor: "Ezagent.Entity.Agent.spawn_from_manifest(",
      reason: "ARB-3 fixture"
    }

    assert %{multiply_matched_allowances: [^allowance]} =
             Scanner.validate_allowlist(offenders, [allowance], "/repo")
  end

  test "validator rejects two allowances matching the same offender" do
    offender = fixture_offender(2, "Ezagent.Entity.Agent.spawn_from_manifest(")

    allowance = %{
      path: "lib/session.ex",
      class: :agent_materialization,
      source_anchor: "Ezagent.Entity.Agent.spawn_from_manifest(",
      reason: "ARB-3 fixture"
    }

    assert %{multiply_matched_allowances: [^allowance, ^allowance]} =
             Scanner.validate_allowlist([offender], [allowance, allowance], "/repo")
  end

  test "validator rejects allowances with missing, extra, or blank schema fields" do
    invalid_allowances = [
      %{path: "lib/session.ex", class: :agent_materialization, source_anchor: "anchor"},
      %{
        path: "lib/session.ex",
        class: :agent_materialization,
        source_anchor: "anchor",
        reason: "   "
      },
      %{
        path: "lib/session.ex",
        class: :agent_materialization,
        source_anchor: "anchor",
        reason: "ARB-3 fixture",
        broad: true
      },
      %{
        path: "lib/session.ex",
        class: :unknown_boundary_class,
        source_anchor: "anchor",
        reason: "ARB-3 fixture"
      }
    ]

    assert %{invalid_allowances: ^invalid_allowances} =
             Scanner.validate_allowlist([], invalid_allowances, "/repo")
  end

  test "an allowance cannot transfer to the same primitive in another definition" do
    original = """
    defmodule Session do
      def original(agent_uri), do: Ezagent.SpawnRegistry.ensure_live(agent_uri)
    end
    """

    moved = """
    defmodule Session do
      def replacement(agent_uri), do: Ezagent.SpawnRegistry.ensure_live(agent_uri)
    end
    """

    [original_offender] = Scanner.scan_source("/repo/lib/session.ex", original)
    [moved_offender] = Scanner.scan_source("/repo/lib/session.ex", moved)

    allowance = %{
      path: "lib/session.ex",
      class: :agent_ensure_live,
      source_anchor: original_offender.source_anchor,
      reason: "ARB-3 fixture"
    }

    assert %{
             unmatched_allowances: [^allowance],
             unallowlisted_offenders: [^moved_offender]
           } = Scanner.validate_allowlist([moved_offender], [allowance], "/repo")
  end

  test "scanner catches qualified Agent materialization" do
    source = """
    defmodule BadSession do
      def run(content), do: Ezagent.Entity.Agent.spawn_from_template_content(content)
    end
    """

    assert [
             %{
               path: "bad.ex",
               line: 2,
               module: Ezagent.Entity.Agent,
               function: :spawn_from_template_content,
               arity: 1,
               class: :agent_materialization
             }
           ] = Scanner.scan_source("bad.ex", source)
  end

  test "scanner catches aliased Agent materialization" do
    source = """
    defmodule BadSession do
      alias Ezagent.Entity.Agent
      def run(content), do: Agent.spawn_from_template_content(content)
    end
    """

    assert [%{class: :agent_materialization, module: Ezagent.Entity.Agent, line: 3}] =
             Scanner.scan_source("bad.ex", source)
  end

  test "scanner catches Agent materialization through a grouped alias" do
    source = """
    defmodule BadSession do
      alias Ezagent.Entity.{Agent, User}
      def run(manifest), do: Agent.spawn_from_manifest(manifest)
    end
    """

    assert [%{class: :agent_materialization, module: Ezagent.Entity.Agent, line: 3}] =
             Scanner.scan_source("grouped_alias.ex", source)
  end

  test "scanner catches grouped Agent alias with keyword options" do
    source = """
    defmodule BadSession do
      alias Ezagent.Entity.{Agent, User}, warn: false
      def run(manifest), do: Agent.spawn_from_manifest(manifest)
    end
    """

    assert [%{class: :agent_materialization, module: Ezagent.Entity.Agent, line: 3}] =
             Scanner.scan_source("grouped_alias_options.ex", source)
  end

  test "scanner catches Agent materialization through an imported local call" do
    source = """
    defmodule BadSession do
      import Ezagent.Entity.Agent
      def run(manifest), do: spawn_from_manifest(manifest)
    end
    """

    assert [%{class: :agent_materialization, module: Ezagent.Entity.Agent, line: 3}] =
             Scanner.scan_source("imported_agent.ex", source)
  end

  test "scanner leaves legal lifecycle and conversation calls alone" do
    legal_sources = [
      "Ezagent.Lifecycle.destroy(session_uri, :session_delete)",
      "Ezagent.SpawnRegistry.ensure_live(session_template_uri)",
      "Ezagent.Invocation.dispatch(member_invocation)",
      "Ezagent.KindRegistry.lookup(member_uri)"
    ]

    for source <- legal_sources do
      assert Scanner.scan_source("legal.ex", source) == []
    end
  end

  test "scanner catches syntactically proven Agent lifecycle targets" do
    source = """
    Ezagent.SpawnRegistry.ensure_live(agent_uri)
    Ezagent.Lifecycle.destroy(agent_uri, :rollback)
    Ezagent.Lifecycle.destroy(member_uri, :rollback)
    Ezagent.Lifecycle.destroy(orchestrator_uri, :rollback)
    Ezagent.Lifecycle.destroy(worker_uri, :rollback)
    """

    assert [
             %{class: :agent_ensure_live, line: 1},
             %{class: :agent_destroy, line: 2},
             %{class: :agent_destroy, line: 3},
             %{class: :agent_destroy, line: 4},
             %{class: :agent_destroy, line: 5}
           ] = Scanner.scan_source("direct_agent_seams.ex", source)
  end

  test "scanner leaves Session lifecycle targets legal even in teardown-like paths" do
    source = """
    Ezagent.Lifecycle.destroy(session_uri, :session_delete)
    Ezagent.Session.SessionManager.stop(session_uri)
    """

    assert Scanner.scan_source(
             "apps/ezagent_domain_session/lib/ezagent/behavior/session/teardown.ex",
             source
           ) == []
  end

  test "scanner treats SessionManager as the legal Session-owned conversation executor" do
    source = """
    Ezagent.Session.SessionManager.stop(orchestrator_uri)
    Ezagent.Session.SessionManager.stop(worker_uri)
    Ezagent.Session.SessionManager.ensure_started(orchestrator_uri: orchestrator_uri)
    Ezagent.Session.SessionManager.ensure_started(session_uri: session_uri)
    """

    assert Scanner.scan_source("session_manager_precision.ex", source) == []
  end

  test "inventory-only generic target seams do not transfer to another Session path" do
    sources = [
      {"def compensate_spawned_members(items), do: Ezagent.Lifecycle.destroy(uri, :rollback)",
       "apps/ezagent_domain_session/lib/sabotage/rollback.ex"},
      {"defp evict_orchestrator_runtime(uri), do: Ezagent.Session.SessionManager.stop(uri)",
       "apps/ezagent_domain_session/lib/sabotage/materializer.ex"},
      {"def lifecycle_status(agent_uri), do: Ezagent.KindRegistry.lookup(agent_uri)",
       "apps/ezagent_domain_session/lib/sabotage/agent.ex"}
    ]

    for {source, path} <- sources do
      assert Scanner.scan_source(path, source) == []
    end
  end

  test "scanner classifies only the verified Agent invocation edges of mixed demand spawn" do
    agent_edge = """
    EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(member_uri)
    """

    session_edge = """
    EzagentDomainInstanceMessage.SessionCreator.demand_spawn_member(session_uri)
    """

    assert [%{class: :agent_materialization}] =
             Scanner.scan_source(
               "apps/ezagent_domain_session/lib/new_session_member_path.ex",
               agent_edge
             )

    assert Scanner.scan_source(
             "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/materializer.ex",
             session_edge
           ) == []
  end

  test "aliases are lexical to each module" do
    source = """
    defmodule LegalSession do
      alias Legal.Entity.Agent
      def run(content), do: Agent.spawn_from_template_content(content)
    end

    defmodule BadSession do
      alias Ezagent.Entity.Agent
      def run(content), do: Agent.spawn_from_template_content(content)
    end
    """

    assert [%{class: :agent_materialization, line: 8}] = Scanner.scan_source("mixed.ex", source)
  end

  test "an alias does not resolve a call before its declaration" do
    source = """
    defmodule Session do
      def before(content), do: Agent.spawn_from_template_content(content)
      alias Ezagent.Entity.Agent
    end
    """

    assert Scanner.scan_source("ordered.ex", source) == []
  end

  test "nested block aliases shadow without leaking" do
    source = """
    defmodule Outer do
      alias Legal.Entity.Agent

      if enabled?() do
        alias Ezagent.Entity.Agent
        Agent.spawn_from_template_content(content)
      end

      def run(content), do: Agent.spawn_from_template_content(content)
    end
    """

    assert [%{class: :agent_materialization, line: 6}] = Scanner.scan_source("nested.ex", source)
  end

  test "a parent alias expands the first segment of a multi-part module" do
    source = """
    defmodule BadSession do
      alias Ezagent.Entity
      def run(content), do: Entity.Agent.spawn_from_template_content(content)
    end
    """

    assert [%{class: :agent_materialization, line: 3}] = Scanner.scan_source("parent.ex", source)
  end

  test "aliases do not leak between sibling case clauses" do
    source = """
    case target do
      :agent ->
        alias Ezagent.Entity.Agent
        Agent.spawn_from_template_content(content)

      :session ->
        Agent.spawn_from_template_content(content)
    end
    """

    assert [%{class: :agent_materialization, line: 4}] = Scanner.scan_source("clauses.ex", source)
  end

  @tag :tmp_dir
  test "scan_paths reads and combines source files", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "bad_session.ex")

    File.write!(path, "Ezagent.Entity.Agent.spawn_from_manifest(manifest)")

    assert [%{path: ^path, class: :agent_materialization, function: :spawn_from_manifest}] =
             Scanner.scan_paths([path])
  end

  defp fixture_offender(line, source_anchor) do
    %{
      path: "/repo/lib/session.ex",
      line: line,
      module: Ezagent.Entity.Agent,
      function: :spawn_from_manifest,
      arity: 1,
      class: :agent_materialization,
      source_anchor: source_anchor
    }
  end
end
