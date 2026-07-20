Code.require_file(Path.expand("../support/fake_driver_alpha.ex", __DIR__))
Code.require_file(Path.expand("../support/fake_driver_beta.ex", __DIR__))
Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/fake_backend_pairs.ex", __DIR__))

defmodule Ezagent.ProviderConnection.DriverResultOwnershipTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ProviderConnection.{
    BackendPair,
    BackendPairRegistry,
    Connection,
    CredentialRefreshExchange,
    Driver,
    DriverRegistry,
    Operation,
    RuntimeBindings
  }
  alias EzagentCore.Repo

  alias Ezagent.ProviderConnection.Test.{
    FakeDriverAlpha,
    FakeDriverBeta,
    FakeCredentialAlpha,
    FakeCredentialBeta,
    Task8Driver,
    Task8CredentialBackend,
    Task8Fixtures
  }

  @callbacks [
    begin_authorization: 1,
    consume_callback: 1,
    reconcile_callback: 1,
    refresh: 1,
    reconcile_refresh: 1,
    discard_callback_result: 1,
    discard_refresh_result: 1,
    revoke: 1
  ]

  test "Driver exposes exactly eight function-fixed result ownership callbacks" do
    assert Enum.sort(Driver.behaviour_info(:callbacks)) == Enum.sort(@callbacks)
  end

  test "the provider-connection runtime has no generic result port or result-level revoke path" do
    root = Path.expand("../..", __DIR__)

    production_files =
      root
      |> Path.join("lib/**/*.ex")
      |> Path.wildcard()

    production_source = Enum.map_join(production_files, "\n", &File.read!/1)

    refute production_source =~ "ProviderResultBackend"
    refute production_source =~ ~r/def\s+(reconcile_result|discard_result)\s*\(/
    refute production_source =~ "backend_commit_changeset"
    refute production_source =~ "cleanup_pending_changeset"

    assert [] ==
             for(
               path <- production_files,
               not String.ends_with?(path, "/termination.ex"),
               call <- result_level_driver_revoke_calls(File.read!(path)),
               do: {path, call}
             )
  end

  test "callback credential effects are purpose-fixed and cleanup uses a claimed snapshot" do
    root = Path.expand("../..", __DIR__)

    exchange =
      File.read!(
        Path.join(root, "lib/ezagent/provider_connection/local_authorization_backend/exchange.ex")
      )

    replacement =
      File.read!(Path.join(root, "lib/ezagent/provider_connection/credential_replacement.ex"))

    assert {:store, 1} in remote_calls(exchange)
    assert {:replace, 1} in remote_calls(exchange)
    assert replacement =~ "defp claim_cleanup_obligation"
    assert replacement =~ "defp cleanup_snapshot"

    refute replacement =~
             "operation = lock_operation(operation_id)\n      attempt = lock_attempt(attempt_ref)"
  end

  test "discard contexts are exact closed callback and refresh products" do
    callback = discard_context()

    assert :ok = Driver.validate_discard_context(:callback, callback)

    assert {:error, :correlation_conflict} =
             Driver.validate_discard_context(:callback, Map.put(callback, :lease_token, "worker"))

    assert {:error, :correlation_conflict} =
             Driver.validate_discard_context(
               :callback,
               Map.delete(callback, :provider_result_ref)
             )

    refresh = Map.delete(callback, :attempt_ref)
    assert :ok = Driver.validate_discard_context(:refresh, refresh)
    assert {:error, :correlation_conflict} = Driver.validate_discard_context(:refresh, callback)
  end

  test "result-level Driver revoke gate recognizes aliases captures apply and indirection" do
    bypasses = [
      "alias Ezagent.ProviderConnection.Driver, as: D; D.revoke(result)",
      "alias Ezagent.ProviderConnection.Driver; &Driver.revoke/1",
      "apply(Ezagent.ProviderConnection.Driver, :revoke, [result])",
      "driver = Ezagent.ProviderConnection.Driver; apply(driver, :revoke, [result])",
      "import Ezagent.ProviderConnection.Driver; revoke(result)",
      "implementation = snapshot.driver; apply(implementation, :revoke, [result_context])",
      "driver.implementation.revoke(result_context)",
      "implementation = driver.implementation; implementation.revoke(result_context)",
      "impl = snapshot.driver; target = impl; apply(target, :revoke, [result_context])",
      "impl = snapshot.driver; middle = impl; target = middle; apply(target, :revoke, [result_context])"
    ]

    assert Enum.all?(bypasses, &(result_level_driver_revoke_calls(&1) != []))
  end

  test "registered in-process and remote-shaped Drivers isolate exact result discard" do
    task8_state = start_supervised!({Agent, fn -> Task8Fixtures.effect_state() end})
    Application.put_env(:ezagent_domain_provider_connection, :task8_effect_state, task8_state)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :task8_effect_state)
    end)

    Enum.each([FakeDriverAlpha, FakeDriverBeta, Task8Driver], fn implementation ->
      if function_exported?(implementation, :reset, 0), do: implementation.reset()

      driver =
        Driver.new!(%{
          provider_id: "discard-provider",
          acquisition_method: "oauth_user",
          provider_fingerprint: "discard-fingerprint",
          implementation: implementation,
          backend_pair_ids: ["discard-pair"],
          metadata: declaration_metadata(implementation)
        })

      context = callback_context()
      assert {:ok, result} = driver.implementation.consume_callback(context)

      discard =
        context
        |> Map.drop([:exchange, :callback_envelope_digest])
        |> Map.merge(%{
          provider_result_ref: result.provider_result_ref,
          discard_idempotency_key: context.correlation_id <> ":provider-discard"
        })

      assert :ok = driver.implementation.discard_callback_result(discard)
      assert :ok = driver.implementation.discard_callback_result(discard)

      assert {:error, :correlation_conflict} =
               driver.implementation.discard_callback_result(%{
                 discard
                 | provider_result_ref: "cross-result"
               })

      assert provider_discard_effect_count(implementation, task8_state) == 1
      assert whole_connection_revoke_count(implementation, task8_state) == 0
    end)
  end

  test "registered Drivers return and discard exact refresh results without whole-connection revoke" do
    task8_state = start_supervised!({Agent, fn -> Task8Fixtures.effect_state() end})
    Application.put_env(:ezagent_domain_provider_connection, :task8_effect_state, task8_state)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :task8_effect_state)
    end)

    owner = {__MODULE__, self()}

    previous =
      Application.get_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations
      )

    on_exit(fn ->
      DriverRegistry.unregister_owner(owner)
      BackendPairRegistry.unregister_owner(owner)

      if previous,
        do:
          Application.put_env(
            :ezagent_domain_provider_connection,
            :credential_backend_implementations,
            previous
          ),
        else:
          Application.delete_env(
            :ezagent_domain_provider_connection,
            :credential_backend_implementations
          )
    end)

    Enum.each([FakeDriverAlpha, FakeDriverBeta, Task8Driver], fn implementation ->
      if function_exported?(implementation, :reset, 0), do: implementation.reset()

      suffix = implementation |> Module.split() |> List.last() |> Macro.underscore()
      provider_id = "refresh-provider-#{suffix}"
      pair_id = "refresh-pair-#{suffix}"
      credential_id = "refresh-credential-#{suffix}"

      backend =
        case implementation do
          Task8Driver -> Task8CredentialBackend
          FakeDriverBeta -> FakeCredentialBeta
          _other -> FakeCredentialAlpha
        end

      pair =
        BackendPair.new!(%{
          pair_id: pair_id,
          authorization_backend: %{id: "refresh-authorization-#{suffix}", fingerprint: "auth-v1"},
          credential_backend: %{id: credential_id, fingerprint: "credential-v1"}
        })

      driver =
        Driver.new!(%{
          provider_id: provider_id,
          acquisition_method: "oauth_user",
          provider_fingerprint: "provider-v1",
          implementation: implementation,
          backend_pair_ids: [pair_id],
          metadata: declaration_metadata(implementation)
        })

      :acquired = BackendPairRegistry.register(owner, pair)
      :acquired = DriverRegistry.register(owner, driver)

      Application.put_env(
        :ezagent_domain_provider_connection,
        :credential_backend_implementations,
        %{credential_id => backend}
      )

      connection = refresh_connection(provider_id, pair)
      operation = refresh_operation(connection)

      assert {:ok, ^pair, ^driver, ^backend} = RuntimeBindings.resolve(connection, operation)

      assert {:ok, first} = CredentialRefreshExchange.invoke(:refresh, connection, operation)
      assert {:ok, ^first} = CredentialRefreshExchange.invoke(:refresh, connection, operation)

      assert MapSet.new(Map.keys(first)) ==
               MapSet.new([
                 :provider_result_ref,
                 :credential_material,
                 :granted_permissions_digest,
                 :expires_at
               ])

      assert match?(
               {:write_only_handoff, ref} when is_binary(ref) and ref != "",
               first.credential_material
             )

      discard =
        refresh_discard_context(connection, operation)
        |> Map.merge(%{
          provider_result_ref: first.provider_result_ref,
          discard_idempotency_key: operation.correlation_id <> ":provider-discard"
        })

      assert :ok = implementation.discard_refresh_result(discard)
      assert :ok = implementation.discard_refresh_result(discard)

      assert {:error, :correlation_conflict} =
               implementation.discard_refresh_result(%{
                 discard
                 | provider_result_ref: "cross-result"
               })

      assert whole_connection_revoke_count(implementation, task8_state) == 0
    end)
  end

  defp declaration_metadata(Task8Driver), do: Task8Fixtures.driver().metadata
  defp declaration_metadata(implementation), do: implementation.declaration_metadata()

  defp provider_discard_effect_count(Task8Driver, state) do
    Agent.get(state, &Map.get(&1.counts, :discard_callback_result, 0))
  end

  defp provider_discard_effect_count(implementation, _state),
    do: implementation.provider_discard_effect_count()

  defp whole_connection_revoke_count(Task8Driver, state) do
    Agent.get(state, &Map.get(&1.counts, :provider_revoke, 0))
  end

  defp whole_connection_revoke_count(implementation, _state),
    do: implementation.whole_connection_revoke_count()

  defp remote_calls(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_receiver, function]}, _, args} = node, calls
        when is_atom(function) and is_list(args) ->
          {node, [{function, length(args)} | calls]}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp result_level_driver_revoke_calls(source) do
    {:ok, ast} = Code.string_to_quoted(source)

    aliases = driver_aliases(ast)
    imported? = imports_driver?(ast)
    driver_vars = driver_module_variables(ast, aliases)

    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [receiver, :revoke]}, _, args} = node, calls when is_list(args) ->
          if driver_receiver?(receiver, aliases, driver_vars) or
               dynamic_driver_receiver?(receiver),
             do: {node, [Macro.to_string(node) | calls]},
             else: {node, calls}

        {:apply, _, [receiver, :revoke, args]} = node, calls when is_list(args) ->
          if driver_receiver?(receiver, aliases, driver_vars) or
               dynamic_driver_receiver?(receiver),
             do: {node, [Macro.to_string(node) | calls]},
             else: {node, calls}

        {:revoke, _, args} = node, calls when is_list(args) and imported? ->
          {node, [Macro.to_string(node) | calls]}

        node, calls ->
          {node, calls}
      end)

    Enum.uniq(calls)
  end

  defp driver_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, MapSet.new([:Driver]), fn
        {:alias, _, [target, options]} = node, aliases when is_list(options) ->
          if target_driver?(target) do
            alias_name =
              case Keyword.get(options, :as) do
                {:__aliases__, _, [name]} -> name
                _other -> :Driver
              end

            {node, MapSet.put(aliases, alias_name)}
          else
            {node, aliases}
          end

        {:alias, _, [target]} = node, aliases ->
          if target_driver?(target),
            do: {node, MapSet.put(aliases, :Driver)},
            else: {node, aliases}

        node, aliases ->
          {node, aliases}
      end)

    aliases
  end

  defp imports_driver?(ast) do
    {_ast, imported?} =
      Macro.prewalk(ast, false, fn
        {:import, _, [target | _options]} = node, imported? ->
          {node, imported? or target_driver?(target)}

        node, imported? ->
          {node, imported?}
      end)

    imported?
  end

  defp driver_module_variables(ast, aliases) do
    {_ast, assignments} =
      Macro.prewalk(ast, [], fn
        {:=, _, [{name, _, context}, receiver]} = node, variables
        when is_atom(name) and is_atom(context) ->
          {node, [{name, receiver} | variables]}

        node, variables ->
          {node, variables}
      end)

    propagate_driver_variables(assignments, aliases, MapSet.new())
  end

  defp propagate_driver_variables(assignments, aliases, variables) do
    next =
      Enum.reduce(assignments, variables, fn {name, receiver}, accumulated ->
        if driver_receiver?(receiver, aliases, accumulated) or dynamic_driver_receiver?(receiver),
          do: MapSet.put(accumulated, name),
          else: accumulated
      end)

    if MapSet.equal?(next, variables),
      do: next,
      else: propagate_driver_variables(assignments, aliases, next)
  end

  defp driver_receiver?({:__aliases__, _, parts}, aliases, _variables) do
    parts == [:Ezagent, :ProviderConnection, :Driver] or
      (length(parts) == 1 and MapSet.member?(aliases, hd(parts)))
  end

  defp driver_receiver?({name, _, context}, _aliases, variables)
       when is_atom(name) and is_atom(context),
       do: MapSet.member?(variables, name) or name in [:driver, :implementation]

  defp driver_receiver?(_receiver, _aliases, _variables), do: false

  defp dynamic_driver_receiver?({{:., _, [_owner, field]}, _, []})
       when field in [:driver, :implementation],
       do: true

  defp dynamic_driver_receiver?(_receiver), do: false

  defp target_driver?(target) do
    Macro.to_string(target) == "Ezagent.ProviderConnection.Driver"
  end

  defp callback_context do
    %{
      owner_uri: "entity://acme/user/alice",
      workspace_uri: "workspace://acme",
      provider_id: "discard-provider",
      acquisition_method: "oauth_user",
      governed_host: "git.example",
      backend_pair_id: "discard-pair",
      operation_id: Ecto.UUID.generate(),
      connection_id: Ecto.UUID.generate(),
      attempt_ref: Ecto.UUID.generate(),
      authorization_ref: "authorization-ref",
      expected_connection_version: 1,
      expected_authorization_version: 2,
      expected_credential_version: 3,
      correlation_id: "store:callback",
      command_digest: "command-digest",
      callback_envelope_digest: "callback-digest",
      exchange: fn effect -> effect.(%{state: "state", pkce_verifier: "verifier"}) end
    }
  end

  defp discard_context do
    %{
      owner_uri: "entity://acme/user/alice",
      workspace_uri: "workspace://acme",
      provider_id: "provider",
      acquisition_method: "oauth_user",
      governed_host: "git.example",
      backend_pair_id: "pair-v1",
      operation_id: Ecto.UUID.generate(),
      connection_id: Ecto.UUID.generate(),
      expected_connection_version: 1,
      attempt_ref: Ecto.UUID.generate(),
      authorization_ref: "authorization-ref",
      expected_authorization_version: 2,
      correlation_id: "store:callback",
      command_digest: "digest",
      expected_credential_version: 3,
      provider_result_ref: "provider-result",
      discard_idempotency_key: "store:callback:provider-discard"
    }
  end

  defp refresh_connection(provider_id, pair) do
    now = DateTime.utc_now()

    %Connection{}
    |> Ecto.Changeset.change(%{
      connection_id: Ecto.UUID.generate(),
      owner_uri: "entity://acme/user/alice",
      workspace_uri: "workspace://acme",
      provider_id: provider_id,
      acquisition_method: "oauth_user",
      governed_host: "git.example",
      backend_pair_id: pair.pair_id,
      authorization_backend_id: pair.authorization_backend.id,
      credential_backend_id: pair.credential_backend.id,
      authorization_backend_ref: "authorization-ref",
      authorization_version: 2,
      credential_backend_ref: "credential-ref",
      credential_version: 3,
      connection_version: 2,
      external_account_id: "account-#{System.unique_integer([:positive])}",
      display_login: "alice",
      execution_identity: "connected_user",
      requested_execution_identity_class: "connected_user",
      permission_digest: "permissions-v1",
      status: "refreshing",
      refresh_lease_token: "lease-token",
      refresh_lease_version: 1,
      refresh_lease_until: DateTime.add(now, 60, :second)
    })
    |> Repo.insert!()
  end

  defp refresh_operation(connection) do
    %Operation{}
    |> Ecto.Changeset.change(%{
      id: Ecto.UUID.generate(),
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      backend_pair_id: connection.backend_pair_id,
      operation_class: "refresh",
      correlation_id: "refresh:" <> connection.provider_id,
      bound_input_digest: "command-digest",
      expected_connection_version: 1,
      expected_authorization_ref: connection.authorization_backend_ref,
      expected_authorization_version: connection.authorization_version,
      expected_credential_version: connection.credential_version,
      prior_credential_ref: connection.credential_backend_ref,
      prior_credential_version: connection.credential_version,
      attempt_version: connection.refresh_lease_version,
      lease_token: connection.refresh_lease_token,
      lease_until: connection.refresh_lease_until,
      next_recovery_at: DateTime.utc_now(),
      status: "prepared"
    })
    |> Repo.insert!()
  end

  defp refresh_discard_context(connection, operation) do
    %{
      owner_uri: connection.owner_uri,
      workspace_uri: connection.workspace_uri,
      provider_id: connection.provider_id,
      acquisition_method: connection.acquisition_method,
      governed_host: connection.governed_host,
      backend_pair_id: operation.backend_pair_id,
      operation_id: operation.id,
      connection_id: operation.connection_id,
      expected_connection_version: operation.expected_connection_version,
      authorization_ref: operation.expected_authorization_ref,
      expected_authorization_version: operation.expected_authorization_version,
      correlation_id: operation.correlation_id,
      command_digest: operation.bound_input_digest,
      expected_credential_version: operation.expected_credential_version
    }
  end
end
