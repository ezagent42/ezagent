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

  # F0 wires the OAuth acquisition path. The DomainGit adapter is still absent
  # on purpose: `AdapterRegistry` validates all five callbacks and
  # `ForgejoAdapter` arrives in F2, so a declaration here could only point at a
  # stub. This records that the absence is a decision -- F2 must update it.
  test "declares no DomainGit adapter yet (F2 boundary)" do
    refute Enum.any?(Plugin.children(), fn
             {Ezagent.DomainGit.AdapterDeclarationOwner, _opts} -> true
             _ -> false
           end)
  end

  describe "provider-connection declarations" do
    test "declares the OAuth driver and its backend pair through the domain owner" do
      assert {Ezagent.ProviderConnection.DeclarationOwner, opts} =
               Enum.find(Plugin.children(), fn
                 {Ezagent.ProviderConnection.DeclarationOwner, _opts} -> true
                 _ -> false
               end)

      assert [driver] = opts[:drivers]
      assert driver.provider_id == "forgejo"
      assert driver.acquisition_method == "oauth_user"
      assert driver.implementation == EzagentPluginForgejo.ForgejoDriver

      assert [pair] = opts[:backend_pairs]
      assert pair.pair_id in driver.backend_pair_ids
      assert pair.credential_backend.id == "forgejo-credential-v1"
    end

    # `Driver.new!/1` refuses secrets in a declaration, but the check that
    # matters is that no tenant-specific value leaked in either: the client_id
    # is per-instance and belongs in the OAuthApp table, not in a single
    # process-wide declaration.
    test "the driver declaration carries no tenant or instance data" do
      {_, opts} =
        Enum.find(Plugin.children(), fn
          {Ezagent.ProviderConnection.DeclarationOwner, _opts} -> true
          _ -> false
        end)

      serialized = opts[:drivers] |> hd() |> :erlang.term_to_binary() |> inspect()

      refute serialized =~ "client_id"
      refute serialized =~ "hyprial"
    end
  end
end
