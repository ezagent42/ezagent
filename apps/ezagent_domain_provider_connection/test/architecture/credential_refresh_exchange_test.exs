Code.require_file(Path.expand("../support/refresh_exchange_backend_support.ex", __DIR__))
Code.require_file(Path.expand("../support/fake_backend_pairs.ex", __DIR__))
Code.require_file(Path.expand("../support/d1_idempotent_credential_backend.ex", __DIR__))
Code.require_file(Path.expand("../support/task8_backends.ex", __DIR__))
Code.require_file(Path.expand("../support/callback_recovery_credential_sink.ex", __DIR__))
Code.require_file(Path.expand("../support/credential_refresh_exchange_call_scanner.ex", __DIR__))

defmodule Ezagent.ProviderConnection.CredentialRefreshExchangeTest do
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.CredentialBackend.RefreshUse
  alias Ezagent.ProviderConnection.CredentialRefreshExchange.ScopeAuthority
  alias Ezagent.ProviderConnection.Test.CredentialRefreshExchangeCallScanner
  alias Ezagent.ProviderConnection.Test.RefreshExchangeBackendSupport
  alias Ezagent.ProviderConnection.{Driver, LocalAuthorizationBackend.Support, Operation, Refresh}

  alias Ezagent.ProviderConnection.Test.{
    D1IdempotentCredentialBackend,
    FakeCredentialAlpha,
    FakeCredentialBeta,
    CallbackRecoveryCredentialSink,
    Task8CredentialBackend
  }

  @callbacks [
    begin_refresh_exchange: 1,
    consume_lease: 1,
    consume_refresh_exchange: 1,
    lease_for_operation: 1,
    replace: 1,
    revoke: 1,
    status: 1,
    store: 1
  ]

  test "all compiled credential backends implement the exact private refresh exchange contract" do
    assert Enum.sort(Ezagent.ProviderConnection.CredentialBackend.behaviour_info(:callbacks)) ==
             Enum.sort(@callbacks)

    Enum.each(
      [
        FakeCredentialAlpha,
        FakeCredentialBeta,
        D1IdempotentCredentialBackend,
        CallbackRecoveryCredentialSink,
        Task8CredentialBackend
      ],
      fn implementation ->
        assert Enum.all?(@callbacks, fn {name, arity} ->
                 function_exported?(implementation, name, arity)
               end)
      end
    )
  end

  test "repository inventory pins all five compiled implementations and both detector fixtures" do
    root = Path.expand("../../../..", __DIR__)

    matches =
      root
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _index} ->
          Regex.match?(
            ~r/@behaviour\s+(?:Ezagent\.ProviderConnection\.)?CredentialBackend\b/,
            line
          )
        end)
        |> Enum.map(fn {_line, index} -> {path, index} end)
      end)

    assert length(matches) == 7

    assert Enum.count(matches, fn {path, _line} ->
             String.ends_with?(path, "/fake_backend_pairs.ex")
           end) == 2

    Enum.each(
      [
        "/d1_idempotent_credential_backend.ex",
        "/callback_recovery_credential_sink.ex",
        "/task8_backends.ex"
      ],
      fn suffix -> assert Enum.any?(matches, &String.ends_with?(elem(&1, 0), suffix)) end
    )

    assert Enum.count(matches, fn {path, _line} ->
             String.ends_with?(path, "/secret_boundary_test.exs")
           end) == 2
  end

  test "RefreshUse is opaque in inspection and the scope claim is one-shot" do
    digest = :crypto.strong_rand_bytes(32)
    {:ok, authority} = ScopeAuthority.start(self(), digest)
    {:ok, token} = ScopeAuthority.open(authority)

    use = RefreshUse.new(authority, token, digest, FakeCredentialAlpha, %{secret: "hidden"})
    assert inspect(use) == "#CredentialBackend.RefreshUse<redacted>"
    refute inspect(use) =~ "hidden"

    assert {:ok, proof} = ScopeAuthority.claim(authority, token, digest)
    assert is_reference(proof)
    assert {:error, :correlation_conflict} = ScopeAuthority.claim(authority, token, digest)
    assert {:error, :correlation_conflict} = ScopeAuthority.claim(authority, make_ref(), digest)
  end

  test "private refresh frames fail closed at known durable operation, recovery, digest, and receipt sinks" do
    digest = :crypto.strong_rand_bytes(32)
    {:ok, authority} = ScopeAuthority.start(self(), digest)
    {:ok, token} = ScopeAuthority.open(authority)
    use = RefreshUse.new(authority, token, digest, FakeCredentialAlpha, %{secret: "hidden"})
    {:ok, proof} = ScopeAuthority.claim(authority, token, digest)

    private_operation_changeset =
      Operation.create_changeset(%{
        workspace_uri: "workspace://acme",
        connection_id: Ecto.UUID.generate(),
        backend_pair_id: "pair-alpha-v1",
        operation_class: "refresh",
        correlation_id: "private-operation-sink",
        bound_input_digest: use,
        expected_connection_version: 0,
        status: "prepared"
      })

    refute private_operation_changeset.valid?
    assert {:base, _error} = List.keyfind(private_operation_changeset.errors, :base, 0)

    assert_raise FunctionClauseError, fn -> Refresh.recover(use) end

    assert_raise ArgumentError, fn ->
      Driver.new!(%{
        provider_id: "private-frame-provider",
        acquisition_method: "oauth_user",
        provider_fingerprint: "private-frame-driver-v1",
        implementation: Ezagent.ProviderConnection.Test.FakeDriverAlpha,
        backend_pair_ids: ["pair-alpha-v1"],
        metadata: %{reachable_private_frame: %{refresh_use: use, claim_proof: proof}}
      })
    end

    encoded =
      Support.encode_consume_result(%{
        provider_result_ref: "provider-result-ref",
        external_account_id: "account-1",
        display_login: "alice",
        execution_identity: %{kind: :connected_user, external_account_id: "account-1"},
        authorization_ref: "authorization-ref",
        authorization_version: 1,
        credential_material: {:write_only_handoff, "handoff-ref"},
        granted_permissions_digest: "permissions",
        expires_at: nil,
        refresh_use: use,
        claim_proof: proof,
        reachable_private_frame: %{refresh_use: use}
      })

    refute inspect(encoded) =~ "RefreshUse"
    refute inspect(encoded) =~ inspect(proof)
    refute inspect(encoded) =~ "hidden"
  end

  test "owner death invalidates an unused scope without executing domain work" do
    parent = self()

    owner =
      spawn(fn ->
        digest = :crypto.strong_rand_bytes(32)
        {:ok, authority} = ScopeAuthority.start(self(), digest)
        {:ok, token} = ScopeAuthority.open(authority)
        send(parent, {:scope, authority, token, digest})
      end)

    monitor = Process.monitor(owner)
    assert_receive {:scope, authority, token, digest}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    eventually(fn -> refute Process.alive?(authority) end)
    assert {:error, :correlation_conflict} = ScopeAuthority.claim(authority, token, digest)
  end

  test "a pre-claim RefreshUse cannot be consumed directly by its backend" do
    digest = :crypto.strong_rand_bytes(32)
    {:ok, authority} = ScopeAuthority.start(self(), digest)
    {:ok, token} = ScopeAuthority.open(authority)

    use =
      RefreshUse.new(authority, token, digest, FakeCredentialAlpha, %{
        current_credential: {:protected_credential, "credential-ref"},
        binding: %{}
      })

    assert {:error, :correlation_conflict} =
             RefreshExchangeBackendSupport.consume(FakeCredentialAlpha, %{
               refresh_use: use,
               provider_exchange: fn _frame ->
                 flunk("direct backend consume reached the provider effect")
               end
             })
  end

  test "facade is the unique production caller and runtime binding stays out of declarations" do
    root = Path.expand("../../../..", __DIR__)
    production = Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex"))

    scan = CredentialRefreshExchangeCallScanner.scan_files(production)
    facade_module = Ezagent.ProviderConnection.CredentialRefreshExchange

    assert Enum.all?(scan.direct_sites, &(&1.module == facade_module)),
           "private refresh callback escaped the facade: #{inspect(scan.direct_sites)}"

    assert Enum.all?(scan.reachable_functions, &(&1.module == facade_module)),
           "a production wrapper outside the facade reaches a private callback: #{inspect(scan.reachable_functions)}"

    begin_calls = Enum.filter(scan.direct_sites, &(&1.callback == :begin_refresh_exchange))
    consume_calls = Enum.filter(scan.direct_sites, &(&1.callback == :consume_refresh_exchange))

    assert [%{path: path}] = begin_calls
    assert String.ends_with?(path, "/credential_refresh_exchange.ex")
    assert [%{path: ^path}] = consume_calls

    facade = File.read!(path)
    refute facade =~ "Application.get_env"
    refute facade =~ "BackendPairRegistry"
    refute facade =~ "DriverRegistry"
    assert facade =~ "try do"
    assert facade =~ "ScopeAuthority.invalidate(authority)"

    Enum.each(["backend_pair.ex", "backend_pair_registry.ex"], fn file ->
      source =
        File.read!(
          Path.join(
            root,
            "apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/#{file}"
          )
        )

      refute source =~ "RefreshUse"
      refute source =~ "ScopeAuthority"
      refute source =~ "credential_backend_implementations"
    end)
  end

  test "the unique-caller detector sees every supported callback spelling and local wrapper" do
    fixtures = [
      {"direct", "def run(backend, request), do: backend.begin_refresh_exchange(request)"},
      {"pipe", "def run(backend, request), do: request |> backend.begin_refresh_exchange()"},
      {"alias",
       "alias Ezagent.ProviderConnection.Test.FakeCredentialAlpha, as: Backend\ndef run(request), do: Backend.begin_refresh_exchange(request)"},
      {"import",
       "import Ezagent.ProviderConnection.Test.FakeCredentialAlpha\ndef run(request), do: begin_refresh_exchange(request)"},
      {"module attribute",
       "@backend Ezagent.ProviderConnection.Test.FakeCredentialAlpha\ndef run(request), do: @backend.begin_refresh_exchange(request)"},
      {"capture", "def run(backend), do: &backend.begin_refresh_exchange/1"},
      {"function capture",
       "def run(backend), do: Function.capture(backend, :begin_refresh_exchange, 1)"},
      {"bare apply", "def run(backend, args), do: apply(backend, :begin_refresh_exchange, args)"},
      {"Kernel.apply",
       "def run(backend, args), do: Kernel.apply(backend, :begin_refresh_exchange, args)"},
      {":erlang.apply",
       "def run(backend, args), do: :erlang.apply(backend, :begin_refresh_exchange, args)"},
      {"defdelegate",
       "defdelegate begin_refresh_exchange(request), to: Ezagent.ProviderConnection.Test.FakeCredentialAlpha"},
      {"two-level wrapper",
       "def run(backend, request), do: first(backend, request)\ndefp first(backend, request), do: backend.begin_refresh_exchange(request)"},
      {"three-level wrapper",
       "def run(backend, request), do: first(backend, request)\ndefp first(backend, request), do: second(backend, request)\ndefp second(backend, request), do: backend.begin_refresh_exchange(request)"},
      {"dynamic backend variable",
       "def run(module, request) do\n  backend = module\n  backend.begin_refresh_exchange(request)\nend"}
    ]

    Enum.each(fixtures, fn {name, body} ->
      source = "defmodule DetectorFixture do\n#{body}\nend\n"
      findings = fixture_findings(source)

      assert Enum.any?(findings, &(&1.callback == :begin_refresh_exchange)),
             "detector missed #{name}: #{inspect(findings)}"

      assert Enum.any?(findings, &(&1.function == :run)) or name == "defdelegate",
             "detector did not propagate #{name} to its public wrapper: #{inspect(findings)}"
    end)
  end

  test "the detector keeps same-line sinks distinct and fails closed for a tainted dynamic apply" do
    same_line =
      CredentialRefreshExchangeCallScanner.scan_source("""
      defmodule SameLineFixture do
        def run(first_backend, second_backend, request), do: {first_backend.begin_refresh_exchange(request), second_backend.begin_refresh_exchange(request)}
      end
      """)

    assert Enum.count(same_line.direct_sites, &(&1.callback == :begin_refresh_exchange)) == 2

    dynamic =
      CredentialRefreshExchangeCallScanner.scan_source("""
      defmodule DynamicApplyFixture do
        def run(backend, callback, args) do
          receiver = backend
          apply(receiver, callback, args)
        end
      end
      """)

    assert Enum.any?(dynamic.direct_sites, &(&1.callback == :dynamic))
    assert Enum.any?(dynamic.reachable_functions, &(&1.function == :run))
  end

  defp fixture_findings(source) do
    scan = CredentialRefreshExchangeCallScanner.scan_source(source)
    scan.direct_sites ++ scan.reachable_functions
  end

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(5)
      eventually(assertion, attempts - 1)
  end
end
