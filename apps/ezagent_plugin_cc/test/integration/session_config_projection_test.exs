defmodule EzagentPluginCc.Integration.SessionConfigProjectionTest do
  use ExUnit.Case, async: false

  alias Ezagent.Session.Config.{Catalog, ExtensionRegistry}

  setup do
    ExtensionRegistry.reset_for_test!()

    on_exit(fn ->
      ExtensionRegistry.reset_for_test!()
      ExtensionRegistry.assemble!(ExtensionRegistry.discover_loaded_extensions())
    end)

    :ok
  end

  test "MCP schemas are a thin projection of the assembled domain catalog" do
    :ok = ExtensionRegistry.assemble!([])
    assert Ezagent.Orchestrator.McpServer.tool_schemas() == Catalog.schemas()
  end

  test "SessionManager delegates executable ownership to SessionConfig.execute/4" do
    source =
      File.read!(
        Path.expand(
          "../../../ezagent_domain_session/lib/ezagent/session/session_manager.ex",
          __DIR__
        )
      )

    assert source =~ "SessionConfig.execute("
    refute source =~ "defp run_tool_op("
    refute source =~ "defp arg_string("
  end
end
