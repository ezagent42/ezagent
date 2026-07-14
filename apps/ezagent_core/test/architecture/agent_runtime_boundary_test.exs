defmodule EzagentCore.AgentRuntimeBoundaryTest do
  use ExUnit.Case, async: true

  alias EzagentCore.AgentRuntimeBoundaryScanner, as: Scanner

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
end
