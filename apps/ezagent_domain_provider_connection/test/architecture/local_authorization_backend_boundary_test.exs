defmodule Ezagent.ProviderConnection.LocalAuthorizationBackendBoundaryTest do
  use ExUnit.Case, async: true

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Exchange
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Lifecycle
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Reconciliation
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support

  @facade_path Path.expand(
                 "../../lib/ezagent/provider_connection/local_authorization_backend.ex",
                 __DIR__
               )

  test "internal backend selectors are not exported" do
    Code.ensure_loaded!(Lifecycle)

    for {name, arity} <- [
          configured_driver: 2,
          frozen_driver: 1,
          registered_credential_backend: 1,
          locked_record: 1,
          locked_command: 3,
          maybe_command: 3,
          command: 3
        ] do
      refute function_exported?(Lifecycle, name, arity)
    end
  end

  test "effectful orchestrators expose only complete commands" do
    Code.ensure_loaded!(Exchange)
    Code.ensure_loaded!(Reconciliation)

    assert Reconciliation.__info__(:functions) == [reconcile: 2]

    assert Exchange.__info__(:functions) ==
             [
               begin_authorization: 1,
               consume_callback: 1,
               handoff_reconciled_to_registered_credential: 2,
               handoff_to_registered_credential: 2,
               stage_callback: 5,
               state_digest: 1
             ]

    assert Lifecycle.__info__(:functions) ==
             [cancel_authorization: 1, configured_pair: 2, reauthenticate: 1]
  end

  test "internal persistence mutators are not exported" do
    Code.ensure_loaded!(Support)

    refute function_exported?(Lifecycle, :persist_begin_record!, 7)
    refute function_exported?(Support, :terminalize_reconciled_absence, 1)
    refute function_exported?(Support, :persist_reconciled_callback, 4)
  end

  test "support is pure and has no repository effects" do
    support_path =
      Path.expand(
        "../../lib/ezagent/provider_connection/local_authorization_backend/support.ex",
        __DIR__
      )

    source = File.read!(support_path)

    refute source =~ "EzagentCore.Repo"
    refute source =~ "Ecto.Query"
    refute source =~ "Ecto.Changeset"
  end

  test "authorization facade uses explicit module calls instead of helper imports" do
    Code.ensure_loaded!(LocalAuthorizationBackend)
    source = File.read!(@facade_path)

    refute source =~ "import Ezagent.ProviderConnection.LocalAuthorizationBackend.Lifecycle"
    refute source =~ "import Ezagent.ProviderConnection.LocalAuthorizationBackend.Support"
    assert source =~ "alias Ezagent.ProviderConnection.LocalAuthorizationBackend."
    assert function_exported?(LocalAuthorizationBackend, :begin_authorization, 1)
  end
end
