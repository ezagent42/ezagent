defmodule Ezagent.Workspace.LoaderFlavorSealTest do
  use ExUnit.Case, async: false

  test "cold-restart load_all skips agent instantiation until flavor registry is sealed" do
    :ok = Ezagent.AgentFlavorRegistry.reset_seal_for_test!()
    on_exit(fn -> Ezagent.AgentFlavorRegistry.seal!() end)

    assert Ezagent.Workspace.Loader.load_all() == []
  end
end
