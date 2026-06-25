defmodule Ezagent.Agent.ConfigApiTest do
  use ExUnit.Case, async: true

  test "domain.agent exposes the cap-gated agent config API" do
    Code.ensure_loaded!(Ezagent.Agent.Config)

    assert function_exported?(Ezagent.Agent.Config, :read_cascade, 3)
    assert function_exported?(Ezagent.Agent.Config, :read_cascade, 4)
    assert function_exported?(Ezagent.Agent.Config, :read_key, 4)
    assert function_exported?(Ezagent.Agent.Config, :read_key, 5)
    assert function_exported?(Ezagent.Agent.Config, :apply_delta, 4)
    assert function_exported?(Ezagent.Agent.Config, :delete_path, 4)
    assert function_exported?(Ezagent.Agent.Config, :repoint, 4)
  end
end
