defmodule Ezagent.DomainGit.AdapterRegistryTest do
  use ExUnit.Case, async: false

  alias Ezagent.DomainGit.AdapterRegistry
  alias Ezagent.DomainGit.Diagnostics
  alias Ezagent.DomainGit.TestSupport.{FakeGitAdapterA, FakeGitAdapterB}

  import ExUnit.CaptureIO

  setup do
    assert {:module, FakeGitAdapterA} = Code.ensure_loaded(FakeGitAdapterA)
    assert {:module, FakeGitAdapterB} = Code.ensure_loaded(FakeGitAdapterB)
    :ok
  end

  defmodule MissingBehaviour do
    def resolve_repository(_, _), do: raise("must not execute")
    def create_change_request(_, _, _, _), do: raise("must not execute")
    def read_change_request(_, _, _), do: raise("must not execute")
    def list_checks(_, _, _), do: raise("must not execute")
    def list_reviews(_, _, _), do: raise("must not execute")
  end

  defmodule CallbackBomb do
    @behaviour Ezagent.DomainGit.Adapter

    for {name, arity} <- Ezagent.DomainGit.Adapter.behaviour_info(:callbacks) do
      args = Macro.generate_arguments(arity, __MODULE__)

      @impl true
      def unquote(name)(unquote_splicing(args)), do: raise("adapter callback executed")
    end
  end

  describe "register/2 and lookup/1" do
    test "registers and resolves a validated provider adapter" do
      id = unique_id("registered")

      assert :ok = AdapterRegistry.register(id, FakeGitAdapterA)
      assert {:ok, FakeGitAdapterA} = AdapterRegistry.lookup_for_action_set(id)
    end

    test "returns :error for an unknown provider" do
      assert :error = AdapterRegistry.lookup_for_action_set(unique_id("unknown"))
    end

    test "rejects invalid provider ids" do
      for id <- ["", "GitHub", "github_api", "-github", "github-", "github/enterprise", :github] do
        assert {:error, {:invalid_provider_id, ^id}} =
                 AdapterRegistry.register(id, FakeGitAdapterA)
      end
    end

    test "requires the exact adapter behaviour declaration" do
      id = unique_id("no-behaviour")

      assert {:error, {:missing_behaviour, MissingBehaviour}} =
               AdapterRegistry.register(id, MissingBehaviour)

      assert :error = AdapterRegistry.lookup_for_action_set(id)
    end

    test "requires every exact adapter callback" do
      id = unique_id("missing-callback")
      missing_callback = compile_missing_callback()

      assert {:error, {:missing_callbacks, [list_reviews: 3]}} =
               AdapterRegistry.register(id, missing_callback)

      assert :error = AdapterRegistry.lookup_for_action_set(id)
    end

    test "same provider and module registration is idempotent" do
      id = unique_id("idempotent")

      assert :ok = AdapterRegistry.register(id, FakeGitAdapterA)
      assert {:ok, :already_registered} = AdapterRegistry.register(id, FakeGitAdapterA)
      assert {:ok, FakeGitAdapterA} = AdapterRegistry.lookup_for_action_set(id)
    end

    test "a conflicting duplicate is rejected without replacing the winner" do
      id = unique_id("conflict")

      assert :ok = AdapterRegistry.register(id, FakeGitAdapterA)

      assert {:error, {:provider_conflict, ^id, FakeGitAdapterA, FakeGitAdapterB}} =
               AdapterRegistry.register(id, FakeGitAdapterB)

      assert {:ok, FakeGitAdapterA} = AdapterRegistry.lookup_for_action_set(id)
    end

    test "registration performs no adapter callback" do
      id = unique_id("callback-bomb")

      assert :ok = AdapterRegistry.register(id, CallbackBomb)
      assert {:ok, CallbackBomb} = AdapterRegistry.lookup_for_action_set(id)
    end

    test "concurrent conflicts produce exactly one winner and no corrupt entry" do
      id = unique_id("race")

      results =
        [FakeGitAdapterA, FakeGitAdapterB]
        |> Task.async_stream(&AdapterRegistry.register(id, &1),
          ordered: false,
          max_concurrency: 2,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert [{:error, {:provider_conflict, ^id, winner, loser}}] = results -- [:ok]
      assert winner in [FakeGitAdapterA, FakeGitAdapterB]
      assert loser in [FakeGitAdapterA, FakeGitAdapterB]
      refute winner == loser
      assert {:ok, ^winner} = AdapterRegistry.lookup_for_action_set(id)
    end

    test "does not load an unloaded adapter module" do
      {module, cleanup} = unloaded_adapter_fixture()
      on_exit(cleanup)

      assert :code.is_loaded(module) == false

      assert {:error, {:invalid_adapter_module, ^module}} =
               AdapterRegistry.register(unique_id("unloaded"), module)

      assert :code.is_loaded(module) == false
      refute_receive {:adapter_on_load, ^module}
    end
  end

  describe "Diagnostics.list_adapters/0" do
    test "returns deterministic non-effectful diagnostics without credentials" do
      id_b = unique_id("list-b")
      id_a = unique_id("list-a")

      assert :ok = AdapterRegistry.register(id_b, FakeGitAdapterB)
      assert :ok = AdapterRegistry.register(id_a, FakeGitAdapterA)

      assert {:ok, diagnostics} = Diagnostics.list_adapters()

      assert Enum.any?(diagnostics, &match?(%{provider_id: ^id_a, module: FakeGitAdapterA}, &1))
      assert Enum.any?(diagnostics, &match?(%{provider_id: ^id_b, module: FakeGitAdapterB}, &1))
      assert diagnostics == Enum.sort_by(diagnostics, & &1.provider_id)

      refute Enum.any?(diagnostics, fn diagnostic ->
               Enum.any?(
                 Map.keys(diagnostic),
                 &(&1 in [:credential, :credentials, :token, :auth])
               )
             end)
    end
  end

  describe "registry lifecycle" do
    test "is a fixed singleton even when callers pass a name option" do
      existing = Process.whereis(AdapterRegistry)

      assert {:error, {:already_started, ^existing}} =
               AdapterRegistry.start_link(name: unique_id("ignored-name"))
    end

    test "reads fail closed while unavailable and restart begins empty" do
      id = unique_id("restart")
      assert :ok = AdapterRegistry.register(id, FakeGitAdapterA)

      assert :ok = Supervisor.terminate_child(EzagentDomainGit.Application, AdapterRegistry)

      on_exit(fn ->
        case Supervisor.restart_child(EzagentDomainGit.Application, AdapterRegistry) do
          {:ok, _pid} -> :ok
          {:error, :running} -> :ok
        end
      end)

      assert {:error, :registry_unavailable} = AdapterRegistry.lookup_for_action_set(id)
      assert {:error, :registry_unavailable} = Diagnostics.list_adapters()
      assert :undefined = :ets.whereis(:ezagent_domain_git_adapter_registry)

      assert {:ok, _pid} =
               Supervisor.restart_child(EzagentDomainGit.Application, AdapterRegistry)

      assert :error = AdapterRegistry.lookup_for_action_set(id)
      assert {:ok, []} = Diagnostics.list_adapters()
      assert :ok = AdapterRegistry.register(id, FakeGitAdapterA)
      assert {:ok, FakeGitAdapterA} = AdapterRegistry.lookup_for_action_set(id)
    end
  end

  defp unique_id(prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{prefix}-#{suffix}"
  end

  defp compile_missing_callback do
    module = Module.concat(__MODULE__, "MissingCallback#{System.unique_integer([:positive])}")

    source = """
    defmodule #{inspect(module)} do
      @behaviour Ezagent.DomainGit.Adapter
      def resolve_repository(_, _), do: raise("must not execute")
      def create_change_request(_, _, _, _), do: raise("must not execute")
      def read_change_request(_, _, _), do: raise("must not execute")
      def list_checks(_, _, _), do: raise("must not execute")
    end
    """

    capture_io(:stderr, fn -> Code.compile_string(source) end)
    module
  end

  defp unloaded_adapter_fixture do
    module = Module.concat(__MODULE__, "Unloaded#{System.unique_integer([:positive])}")
    probe_key = {__MODULE__, module}
    tmp_dir = Path.join(System.tmp_dir!(), "git-adapter-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    source = """
    defmodule #{inspect(module)} do
      @behaviour Ezagent.DomainGit.Adapter
      @on_load :observable_on_load
      def observable_on_load do
        if pid = :persistent_term.get(#{inspect(probe_key)}, nil),
          do: send(pid, {:adapter_on_load, __MODULE__})
        :ok
      end
      def resolve_repository(_, _), do: raise("must not execute")
      def create_change_request(_, _, _, _), do: raise("must not execute")
      def read_change_request(_, _, _), do: raise("must not execute")
      def list_checks(_, _, _), do: raise("must not execute")
      def list_reviews(_, _, _), do: raise("must not execute")
    end
    """

    [{^module, beam}] = Code.compile_string(source)
    :code.purge(module)
    true = :code.delete(module)
    File.write!(Path.join(tmp_dir, Atom.to_string(module) <> ".beam"), beam)
    true = :code.add_patha(String.to_charlist(tmp_dir))
    :persistent_term.put(probe_key, self())

    cleanup = fn ->
      :persistent_term.erase(probe_key)
      :code.del_path(String.to_charlist(tmp_dir))
      :code.purge(module)
      :code.delete(module)
      File.rm_rf!(tmp_dir)
    end

    {module, cleanup}
  end
end
