defmodule EzagentPluginForgejo.ApplicationTest do
  use ExUnit.Case, async: true

  alias EzagentPluginForgejo.Application, as: Plugin

  test "declares itself as the forgejo plugin" do
    assert %{slug: "forgejo", name: name, version: version} = Plugin.plugin_info()
    assert is_binary(name)
    assert is_binary(version)
  end

  test "supervises the credential backend that owns the PAT table" do
    assert EzagentPluginForgejo.ForgejoCredentialBackend in Plugin.children()
  end

  # Slice F1 deliberately registers no DomainGit adapter: `AdapterRegistry`
  # validates all five callbacks and `ForgejoAdapter` does not exist yet, so a
  # declaration here could only point at a stub. When F2 adds the real adapter
  # this test must be updated -- which is the point. It records that the
  # absence is a decision, not an oversight.
  test "declares no DomainGit adapter yet (F1 boundary)" do
    refute Enum.any?(Plugin.children(), fn
             {Ezagent.DomainGit.AdapterDeclarationOwner, _opts} -> true
             _ -> false
           end)
  end
end
