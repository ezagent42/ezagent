Code.require_file(Path.expand("../../support/fake_driver_alpha.ex", __DIR__))
Code.require_file(Path.expand("../../support/fake_driver_beta.ex", __DIR__))
Code.require_file(Path.expand("../../support/fake_backend_pairs.ex", __DIR__))

defmodule Ezagent.ProviderConnection.RegistryTest do
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.BackendPair
  alias Ezagent.ProviderConnection.BackendPairRegistry
  alias Ezagent.ProviderConnection.DeclarationOwner
  alias Ezagent.ProviderConnection.Driver
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.ProviderAuthorizationBackend
  alias Ezagent.ProviderConnection.CredentialBackend
  alias Ezagent.ProviderConnection.Test.FakeBackendPairs
  alias Ezagent.ProviderConnection.Test.FakeDriverAlpha
  alias Ezagent.ProviderConnection.Test.FakeDriverBeta

  defmodule DriverWithoutReconciliation do
    def begin_authorization(context), do: {:ok, context}
    def consume_callback(context), do: {:ok, context}
    def refresh(context), do: {:ok, context}
    def revoke(context), do: {:ok, context}
  end

  @driver_callbacks [
    begin_authorization: 1,
    consume_callback: 1,
    reconcile_callback: 1,
    discard_callback_result: 1,
    discard_refresh_result: 1,
    refresh: 1,
    reconcile_refresh: 1,
    revoke: 1
  ]
  @authorization_callbacks [
    begin_authorization: 1,
    cancel_authorization: 1,
    consume_callback: 1,
    reauthenticate: 1
  ]
  @credential_callbacks [
    consume_lease: 1,
    lease_for_operation: 1,
    replace: 1,
    revoke: 1,
    status: 1,
    store: 1
  ]

  setup do
    owner = {:registry_test, make_ref()}

    on_exit(fn ->
      DriverRegistry.unregister_owner(owner)
      BackendPairRegistry.unregister_owner(owner)
    end)

    %{owner: owner}
  end

  test "contracts expose exactly the frozen D1 and D0 callback lists" do
    assert Enum.sort(Driver.behaviour_info(:callbacks)) == Enum.sort(@driver_callbacks)

    assert Enum.sort(ProviderAuthorizationBackend.behaviour_info(:callbacks)) ==
             Enum.sort(@authorization_callbacks)

    assert Enum.sort(CredentialBackend.behaviour_info(:callbacks)) ==
             Enum.sort(@credential_callbacks)
  end

  test "driver declaration rejects an implementation without reconciliation" do
    assert_raise ArgumentError,
                 "driver implementation does not implement the exact contract",
                 fn ->
                   Driver.new!(%{
                     provider_id: "legacy-driver",
                     acquisition_method: "legacy-method",
                     provider_fingerprint: "legacy-v1",
                     implementation: DriverWithoutReconciliation,
                     backend_pair_ids: ["pair-alpha-v1"],
                     metadata: FakeDriverAlpha.declaration_metadata()
                   })
                 end
  end

  test "fake drivers materially differ without common provider vendor names" do
    alpha_callback = FakeDriverAlpha.consume_callback(%{})
    beta_callback = FakeDriverBeta.consume_callback(%{})
    alpha_refresh = FakeDriverAlpha.refresh(%{})
    beta_refresh = FakeDriverBeta.refresh(%{})
    alpha_revoke = FakeDriverAlpha.revoke(%{})
    beta_revoke = FakeDriverBeta.revoke(%{})

    refute alpha_callback == beta_callback
    refute alpha_refresh == beta_refresh
    refute alpha_revoke == beta_revoke

    common_source =
      [
        "../../support/fake_driver_alpha.ex",
        "../../support/fake_driver_beta.ex",
        "../../../lib/ezagent/provider_connection/driver.ex",
        "../../../lib/ezagent/provider_connection/driver_registry.ex"
      ]
      |> Enum.map(&Path.expand(&1, __DIR__))
      |> Enum.map_join("\n", &File.read!/1)

    refute common_source =~ ~r/github|gitlab|bitbucket/i
  end

  test "fake drivers reconcile exact callback correlations and reject changed private input" do
    for driver <- [FakeDriverAlpha, FakeDriverBeta] do
      if function_exported?(driver, :reset, 0), do: driver.reset()

      correlation = "reconcile-#{inspect(driver)}"
      frame = %{state: "stable", callback_envelope: %{code: "one"}}
      context = reconciliation_context(correlation, frame)

      assert {:ok, consumed} = driver.consume_callback(context)
      assert {:ok, ^consumed} = driver.reconcile_callback(context)

      assert {:error, :provider_protocol_error} =
               driver.reconcile_callback(
                 reconciliation_context(correlation, %{frame | state: "changed"})
               )

      assert {:error, :provider_protocol_error} =
               driver.reconcile_callback(%{context | command_digest: "changed-durable-digest"})

      assert {:ok, :not_completed} =
               driver.reconcile_callback(reconciliation_context(correlation <> "-absent", frame))
    end
  end

  test "driver lookup uses exact extensible string provider and acquisition ids", %{owner: owner} do
    alpha = alpha_driver()
    assert :acquired = DriverRegistry.register(owner, alpha)

    assert {:ok, ^alpha} = DriverRegistry.lookup("forge-alpha", "browser-exchange")
    assert :error = DriverRegistry.lookup("FORGE-ALPHA", "browser-exchange")
    assert :error = DriverRegistry.lookup("forge-alpha", "device-exchange")

    assert is_binary(alpha.provider_id)
    assert is_binary(alpha.acquisition_method)
  end

  test "driver declarations reject atom-valued persistence schemas" do
    metadata =
      FakeDriverAlpha.declaration_metadata()
      |> Map.put(:provider_metadata_schema, %{
        type: :map,
        fields: %{"mode" => %{type: :atom}}
      })

    assert_raise ArgumentError,
                 "driver metadata must declare closed authorization redirect and provider metadata schemas",
                 fn ->
                   Driver.new!(%{
                     provider_id: "forge-atom-schema",
                     acquisition_method: "browser-exchange",
                     provider_fingerprint: "forge-atom-schema-v1",
                     implementation: FakeDriverAlpha,
                     backend_pair_ids: ["pair-alpha-v1"],
                     metadata: metadata
                   })
                 end
  end

  test "schema matching rejects canonical key collisions at every map depth" do
    top_level_schema = %{type: :map, fields: %{"tier" => %{type: :string}}}

    nested_schema = %{
      type: :map,
      fields: %{
        "details" => %{
          type: :map,
          fields: %{"tier" => %{type: :string}}
        }
      }
    }

    refute Driver.matches_schema?(%{"tier" => "B", tier: "A"}, top_level_schema)

    refute Driver.matches_schema?(
             %{details: %{"tier" => "B", tier: "A"}},
             nested_schema
           )
  end

  test "identical fingerprints are idempotent while declaration drift fails loudly", %{
    owner: owner
  } do
    alpha = alpha_driver()
    assert :acquired = DriverRegistry.register(owner, alpha)
    assert :existing_identical = DriverRegistry.register(owner, alpha)

    drift = Driver.new!(%{alpha | metadata: Map.put(alpha.metadata, :account_shape, "changed")})

    assert {:error, {:declaration_drift, fingerprint, drift_fingerprint}} =
             DriverRegistry.register(owner, drift)

    assert fingerprint == alpha.fingerprint
    assert drift_fingerprint == drift.fingerprint
    assert {:ok, ^alpha} = DriverRegistry.lookup("forge-alpha", "browser-exchange")
  end

  test "declaration ownership preserves another owner's identical row", %{owner: owner} do
    other_owner = {:other_registry_test, make_ref()}
    alpha = alpha_driver()

    assert :acquired = DriverRegistry.register(owner, alpha)
    assert :existing_identical = DriverRegistry.register(other_owner, alpha)
    assert :ok = DriverRegistry.unregister_owner(owner)
    assert {:ok, ^alpha} = DriverRegistry.lookup("forge-alpha", "browser-exchange")
    assert :ok = DriverRegistry.unregister_owner(other_owner)
    assert :error = DriverRegistry.lookup("forge-alpha", "browser-exchange")
  end

  test "backend pair lookup is by stable pair id and rejects an untested cross-pair", %{
    owner: owner
  } do
    alpha = FakeBackendPairs.alpha()
    beta = FakeBackendPairs.beta()

    assert :acquired = BackendPairRegistry.register(owner, alpha)
    assert :acquired = BackendPairRegistry.register(owner, beta)
    assert {:ok, ^alpha} = BackendPairRegistry.lookup("pair-alpha-v1")
    assert :error = BackendPairRegistry.lookup("PAIR-ALPHA-V1")

    assert :ok =
             BackendPairRegistry.ensure_compatible(
               "pair-alpha-v1",
               "authorization-alpha-v1",
               "credential-alpha-v1"
             )

    assert {:error, :untested_backend_pair} =
             BackendPairRegistry.ensure_compatible(
               "pair-alpha-v1",
               "authorization-alpha-v1",
               "credential-beta-v1"
             )
  end

  test "backend pair declarations contain only stable backend ids and fingerprints" do
    pair = FakeBackendPairs.alpha()

    assert Map.keys(pair.authorization_backend) |> Enum.sort() == [:fingerprint, :id]
    assert Map.keys(pair.credential_backend) |> Enum.sort() == [:fingerprint, :id]

    assert pair.authorization_backend == %{
             id: "authorization-alpha-v1",
             fingerprint: "authorization-alpha-contract-v1"
           }

    assert pair.credential_backend == %{
             id: "credential-alpha-v1",
             fingerprint: "credential-alpha-contract-v1"
           }
  end

  test "registries reject declarations whose caller-supplied fingerprints are stale", %{
    owner: owner
  } do
    driver = alpha_driver()
    pair = FakeBackendPairs.alpha()
    stale_driver = %{driver | metadata: %{account_shape: "tampered"}}

    stale_pair = %{
      pair
      | credential_backend: %{
          id: "credential-tampered-v1",
          fingerprint: "credential-tampered-contract-v1"
        }
    }

    assert {:error, {:declaration_drift, _, _}} = DriverRegistry.register(owner, stale_driver)
    assert {:error, {:declaration_drift, _, _}} = BackendPairRegistry.register(owner, stale_pair)
    assert :error = DriverRegistry.lookup(driver.provider_id, driver.acquisition_method)
    assert :error = BackendPairRegistry.lookup(pair.pair_id)
  end

  test "backend pair drift fails loudly and a failed batch rolls back only its owner", %{
    owner: owner
  } do
    alpha = FakeBackendPairs.alpha()
    beta = FakeBackendPairs.beta()
    incumbent = {:backend_pair_incumbent, make_ref()}

    drift =
      BackendPair.new!(%{
        pair_id: beta.pair_id,
        authorization_backend: beta.authorization_backend,
        credential_backend: %{
          id: "credential-beta-drift-v1",
          fingerprint: "credential-beta-drift-contract-v1"
        }
      })

    assert :acquired = BackendPairRegistry.register(incumbent, beta)

    assert {:error, {:declaration_drift, _, _}} =
             BackendPairRegistry.register_all(owner, [alpha, drift])

    assert :error = BackendPairRegistry.lookup(alpha.pair_id)
    assert {:ok, ^beta} = BackendPairRegistry.lookup(beta.pair_id)
    assert :ok = BackendPairRegistry.unregister_owner(incumbent)
  end

  test "provider availability explicitly reports each partial declaration", %{owner: owner} do
    alpha_driver = alpha_driver()
    alpha_pair = FakeBackendPairs.alpha()
    git_declaration = git_declaration(alpha_driver)

    assert :acquired = BackendPairRegistry.register(owner, alpha_pair)

    assert {:unavailable, %{driver: :missing, backend_pair: :available, git_adapter: :available}} =
             DriverRegistry.availability(
               "forge-alpha",
               "browser-exchange",
               "pair-alpha-v1",
               git_declaration
             )

    assert :ok = BackendPairRegistry.unregister_owner(owner)
    assert :acquired = DriverRegistry.register(owner, alpha_driver)

    assert {:unavailable, %{driver: :available, backend_pair: :missing, git_adapter: :available}} =
             DriverRegistry.availability(
               "forge-alpha",
               "browser-exchange",
               "pair-alpha-v1",
               git_declaration
             )

    assert {:unavailable, %{driver: :available, backend_pair: :missing, git_adapter: :missing}} =
             DriverRegistry.availability(
               "forge-alpha",
               "browser-exchange",
               "pair-alpha-v1",
               :unavailable
             )
  end

  test "D0 parity and tested pair membership are required for availability", %{owner: owner} do
    alpha_driver = alpha_driver()
    alpha_pair = FakeBackendPairs.alpha()
    assert :acquired = DriverRegistry.register(owner, alpha_driver)
    assert :acquired = BackendPairRegistry.register(owner, alpha_pair)

    assert {:available, %{driver: ^alpha_driver, backend_pair: ^alpha_pair}} =
             DriverRegistry.availability(
               "forge-alpha",
               "browser-exchange",
               "pair-alpha-v1",
               git_declaration(alpha_driver)
             )

    assert {:error, :provider_declaration_drift} =
             DriverRegistry.availability(
               "forge-alpha",
               "browser-exchange",
               "pair-alpha-v1",
               %{provider_id: "forge-alpha", provider_fingerprint: "different"}
             )

    assert {:error, :provider_declaration_drift} =
             DriverRegistry.availability(
               "forge-alpha",
               "browser-exchange",
               "pair-alpha-v1",
               %{
                 provider_id: "forge-beta",
                 provider_fingerprint: alpha_driver.provider_fingerprint
               }
             )

    assert {:error, :untested_backend_pair} =
             DriverRegistry.availability(
               "forge-alpha",
               "browser-exchange",
               "pair-beta-v1",
               git_declaration(alpha_driver)
             )
  end

  test "malformed Domain Git declarations fail closed even when the driver is absent" do
    assert {:error, :provider_declaration_drift} =
             DriverRegistry.availability(
               "missing-provider",
               "missing-method",
               "missing-pair",
               %{}
             )

    assert {:error, :provider_declaration_drift} =
             DriverRegistry.availability(
               "missing-provider",
               "missing-method",
               "missing-pair",
               %{provider_id: "missing-provider", provider_fingerprint: ""}
             )
  end

  test "a failed declaration batch rolls back only rows acquired by that owner", %{owner: owner} do
    incumbent = {:incumbent, make_ref()}
    alpha = alpha_driver()
    beta = beta_driver()
    drift = Driver.new!(%{beta | metadata: Map.put(beta.metadata, :account_shape, "drift")})

    assert :acquired = DriverRegistry.register(incumbent, beta)

    assert {:error, {:declaration_drift, _, _}} =
             DriverRegistry.register_all(owner, [alpha, drift])

    assert :error = DriverRegistry.lookup(alpha.provider_id, alpha.acquisition_method)
    assert {:ok, ^beta} = DriverRegistry.lookup(beta.provider_id, beta.acquisition_method)

    DriverRegistry.unregister_owner(incumbent)
  end

  test "a declaration owner cleans its driver rows when backend-pair reconciliation fails", %{
    owner: owner
  } do
    alpha_driver = alpha_driver()
    alpha_pair = FakeBackendPairs.alpha()
    incumbent = {:cross_registry_incumbent, make_ref()}

    drift_pair =
      BackendPair.new!(%{
        pair_id: alpha_pair.pair_id,
        authorization_backend: alpha_pair.authorization_backend,
        credential_backend: %{
          id: "credential-alpha-drift-v1",
          fingerprint: "credential-alpha-drift-contract-v1"
        }
      })

    assert :acquired = BackendPairRegistry.register(incumbent, alpha_pair)

    assert {:error, _reason} =
             start_supervised(
               {DeclarationOwner,
                owner: owner, drivers: [alpha_driver], backend_pairs: [drift_pair], name: nil}
             )

    assert :error =
             DriverRegistry.lookup(alpha_driver.provider_id, alpha_driver.acquisition_method)

    assert {:ok, ^alpha_pair} = BackendPairRegistry.lookup(alpha_pair.pair_id)
    assert :ok = BackendPairRegistry.unregister_owner(incumbent)
  end

  test "a supervised declaration owner restores exact rows after registry restart", %{
    owner: owner
  } do
    alpha_driver = alpha_driver()
    alpha_pair = FakeBackendPairs.alpha()

    owner_pid =
      start_supervised!(
        {DeclarationOwner,
         owner: owner, drivers: [alpha_driver], backend_pairs: [alpha_pair], name: nil}
      )

    generations = DeclarationOwner.generation(owner_pid)
    old_registry = Process.whereis(DriverRegistry)
    Process.exit(old_registry, :kill)

    assert :ok =
             DeclarationOwner.await_generation(owner_pid, %{
               generations
               | driver: generations.driver + 1
             })

    new_registry = Process.whereis(DriverRegistry)
    assert new_registry != old_registry
    assert {:ok, ^alpha_driver} = DriverRegistry.lookup("forge-alpha", "browser-exchange")
    assert {:ok, ^alpha_pair} = BackendPairRegistry.lookup("pair-alpha-v1")
  end

  test "a declaration owner survives readiness restart and restores both registries", %{
    owner: owner
  } do
    alpha_driver = alpha_driver()
    alpha_pair = FakeBackendPairs.alpha()

    owner_pid =
      start_supervised!(
        {DeclarationOwner,
         owner: owner, drivers: [alpha_driver], backend_pairs: [alpha_pair], name: nil}
      )

    generations = DeclarationOwner.generation(owner_pid)
    old_readiness = Process.whereis(Ezagent.ProviderConnection.RegistryReadiness)
    old_driver_registry = Process.whereis(DriverRegistry)
    old_pair_registry = Process.whereis(BackendPairRegistry)
    Process.exit(old_readiness, :kill)

    waiter =
      Task.async(fn ->
        DeclarationOwner.await_generation(owner_pid, %{
          driver: generations.driver + 1,
          backend_pair: generations.backend_pair + 1
        })
      end)

    assert {:ok, :ok} = Task.yield(waiter, 2_000) || Task.shutdown(waiter, :brutal_kill)
    assert Process.whereis(Ezagent.ProviderConnection.RegistryReadiness) != old_readiness
    assert Process.whereis(DriverRegistry) != old_driver_registry
    assert Process.whereis(BackendPairRegistry) != old_pair_registry
    assert {:ok, ^alpha_driver} = DriverRegistry.lookup("forge-alpha", "browser-exchange")
    assert {:ok, ^alpha_pair} = BackendPairRegistry.lookup("pair-alpha-v1")
  end

  defp alpha_driver do
    Driver.new!(%{
      provider_id: "forge-alpha",
      acquisition_method: "browser-exchange",
      provider_fingerprint: "forge-alpha-contract-v1",
      implementation: FakeDriverAlpha,
      backend_pair_ids: ["pair-alpha-v1"],
      metadata:
        FakeDriverAlpha.declaration_metadata(%{
          account_shape: "single-subject",
          refresh: "rotating",
          revoke: "provider-first"
        })
    })
  end

  defp beta_driver do
    Driver.new!(%{
      provider_id: "forge-beta",
      acquisition_method: "device-exchange",
      provider_fingerprint: "forge-beta-contract-v1",
      implementation: FakeDriverBeta,
      backend_pair_ids: ["pair-beta-v1"],
      metadata:
        FakeDriverBeta.declaration_metadata(%{
          account_shape: "tenant-member",
          refresh: "conditional",
          revoke: "credential-first"
        })
    })
  end

  defp git_declaration(driver) do
    %{provider_id: driver.provider_id, provider_fingerprint: driver.provider_fingerprint}
  end

  defp reconciliation_context(correlation, private_frame) do
    %{
      owner_uri: "entity://acme/user/registry-test",
      workspace_uri: "workspace://acme",
      provider_id: "registry-provider",
      acquisition_method: "oauth_user",
      governed_host: "example.test",
      backend_pair_id: "pair-alpha-v1",
      operation_id: "operation-reconciliation-1",
      connection_id: "connection-reconciliation-1",
      correlation_id: correlation,
      attempt_ref: "attempt-reconciliation-1",
      authorization_ref: "authorization-reconciliation-1",
      expected_connection_version: 11,
      expected_authorization_version: 4,
      expected_credential_version: 3,
      command_digest: "durable-command-digest",
      callback_envelope_digest: "server-owned",
      exchange: fn provider_exchange -> provider_exchange.(private_frame) end
    }
  end
end
