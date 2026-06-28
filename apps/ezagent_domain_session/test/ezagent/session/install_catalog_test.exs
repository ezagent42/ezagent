defmodule Ezagent.Session.InstallCatalogTest do
  use ExUnit.Case, async: true

  alias Ezagent.Entity.Session
  alias Ezagent.Session.InstallCatalog

  test "defaults absent template installs to the chat behavior set" do
    assert InstallCatalog.installs_from_template(%{}) == ["chat"]
    assert {:ok, behaviors} = InstallCatalog.behavior_set_for_template(%{})
    assert behaviors == Session.chat_behaviors()
  end

  test "resolves the temporary built-in socialware install" do
    assert {:ok, behaviors} =
             InstallCatalog.behavior_set_for_template(%{installs: ["socialware"]})

    assert behaviors == Session.socialware_behaviors()
  end

  test "rejects unknown installs fail-loud" do
    assert {:error, {:unknown_install, "bogus"}} =
             InstallCatalog.behavior_set_for_template(%{installs: ["bogus"]})
  end
end
