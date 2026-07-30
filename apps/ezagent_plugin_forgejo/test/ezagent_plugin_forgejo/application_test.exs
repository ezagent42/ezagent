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

  # F1 and F0 deliberately left this absent (`AdapterRegistry` validates all
  # five callbacks, and the adapter did not exist yet). F2 delivers the read
  # path, so the declaration lands here — the earlier "declares no adapter yet"
  # test turning red is what marked the boundary being crossed on purpose.
  describe "DomainGit adapter declaration" do
    test "declares the Forgejo adapter through the domain owner" do
      assert {Ezagent.DomainGit.AdapterDeclarationOwner, opts} =
               Enum.find(Plugin.children(), fn
                 {Ezagent.DomainGit.AdapterDeclarationOwner, _opts} -> true
                 _ -> false
               end)

      assert opts[:adapters] == [{"forgejo", EzagentPluginForgejo.ForgejoAdapter}]
    end

    # The registry checks this at registration; asserting it here means a
    # missing callback fails in this plugin's own suite rather than at boot.
    test "the adapter implements every DomainGit.Adapter callback" do
      for {fun, arity} <- [
            resolve_repository: 2,
            create_change_request: 4,
            read_change_request: 3,
            list_checks: 3,
            list_reviews: 3
          ] do
        assert function_exported?(EzagentPluginForgejo.ForgejoAdapter, fun, arity),
               "missing #{fun}/#{arity}"
      end
    end
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
