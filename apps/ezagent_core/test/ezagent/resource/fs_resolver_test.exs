defmodule Ezagent.Resource.FsResolverTest do
  @moduledoc """
  R-1..R-4 invariant tests for the hardened, registration-only generic
  `resource://<ws>/<type>/<name>` FS resolver (Resource-unification SPEC §5.1).

  `async: false` — these register/unregister test-only types in the shared
  `:protected` registry table owned by `Ezagent.Resource.FsResolver.Registry`,
  so they must serialise.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Resource.FsResolver
  alias Ezagent.URI, as: EzURI

  @table :ezagent_resource_fs_types

  # A test-only type spec registered per-test so P0 ships dormant (zero real types).
  defp scope(ws), do: %{workspace: ws}

  defp with_type(type, type_spec, fun) do
    :ok = FsResolver.register_type(type, type_spec)

    try do
      fun.()
    after
      FsResolver.unregister_type(type)
    end
  end

  defp ok_authority(uri, scope) do
    {:ok, ws} = EzURI.workspace_name(uri)
    if ws == scope.workspace, do: :ok, else: {:error, {:foreign_workspace, ws}}
  end

  # The registry's `:protected` table also holds the seal row ({:__sealed__,…});
  # type-iterating assertions look only at binary-keyed type rows.
  defp registered_types, do: Enum.filter(:ets.tab2list(@table), fn {k, _} -> is_binary(k) end)

  defp wait_for_restart(name, old_pid, attempts \\ 50)

  defp wait_for_restart(name, _old_pid, 0), do: flunk("#{inspect(name)} did not restart")

  defp wait_for_restart(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ -> Process.sleep(20) && wait_for_restart(name, old_pid, attempts - 1)
    end
  end

  describe "R-1 — closed allowlist (no implicit Home catch-all)" do
    test "unregistered <type> returns :none" do
      uri = EzURI.resource("acme", "never-registered", "x")
      assert FsResolver.resolve(uri, scope("acme")) == :none
    end

    test "a non-resource URI is :none (not ours)" do
      uri = EzURI.entity("acme", "agent", "worker-1")
      assert FsResolver.resolve(uri, scope("acme")) == :none
    end

    test "a structurally-resource URI missing a segment is malformed, not :none" do
      # resource://acme with no /type/name path.
      uri = %URI{scheme: "resource", host: "acme", path: nil, port: nil}
      assert {:error, {:malformed_resource_uri, _}} = FsResolver.resolve(uri, scope("acme"))
    end
  end

  describe "R-2 — unsafe-segment rejection BEFORE any Path.join" do
    test ".., ., separator, NUL name segments fail before Path.join" do
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        uri = %URI{scheme: "resource", host: "acme", path: "/t-uploads/..", port: nil}
        assert {:error, {:unsafe_segment, ".."}} = FsResolver.resolve(uri, scope("acme"))

        uri2 = %URI{scheme: "resource", host: "acme", path: "/t-uploads/.", port: nil}
        assert {:error, {:unsafe_segment, "."}} = FsResolver.resolve(uri2, scope("acme"))

        uri3 = %URI{
          scheme: "resource",
          host: "acme",
          path: "/t-uploads/a" <> <<0>> <> "b",
          port: nil
        }

        assert {:error, {:unsafe_segment, _}} = FsResolver.resolve(uri3, scope("acme"))
      end)
    end

    test "table-driven malicious <name> strings never reach FS" do
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        # Single-segment traversal/separator/NUL names are caught by the
        # unsafe-segment guard. Multi-`/` names (e.g. "../../etc/passwd") split
        # into >3 URI path segments, so `Ezagent.URI.name/1` returns `:error` and
        # the resolver returns `{:malformed_resource_uri, _}`. EITHER way the
        # security invariant holds: the input NEVER resolves to a filesystem path.
        for bad <- ["..", ".", "../../etc/passwd", "a/b", "a\\b", "..\\victim", "x" <> <<0>>] do
          uri = %URI{scheme: "resource", host: "acme", path: "/t-uploads/" <> bad, port: nil}
          result = FsResolver.resolve(uri, scope("acme"))

          assert match?({:error, {:unsafe_segment, _}}, result) or
                   match?({:error, {:malformed_resource_uri, _}}, result),
                 "expected rejection (never a path) for #{inspect(bad)}, got #{inspect(result)}"

          refute match?({:ok, _}, result)
        end
      end)
    end

    test "an unsafe <ws> segment is rejected before Path.join" do
      type_spec = %{backend_component: "t-uploads", authority: fn _uri, _scope -> :ok end}

      with_type("t-uploads", type_spec, fn ->
        uri = %URI{scheme: "resource", host: "..", path: "/t-uploads/file", port: nil}
        assert {:error, {:unsafe_segment, ".."}} = FsResolver.resolve(uri, scope(".."))
      end)
    end

    test "a Windows-separator (backslash) <name> is rejected (codex round-3 HIGH)" do
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        uri = %URI{scheme: "resource", host: "acme", path: "/t-uploads/..\\victim", port: nil}
        assert {:error, {:unsafe_segment, "..\\victim"}} = FsResolver.resolve(uri, scope("acme"))
      end)
    end
  end

  describe "R-3 — authority-bearing resolution (no resolve/1)" do
    test "authority mismatch (uri.<ws> != scope.workspace) fails loud, not :none" do
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        uri = EzURI.resource("victim", "t-uploads", "secret.pdf")

        assert {:error, {:foreign_workspace, "victim"}} =
                 FsResolver.resolve(uri, scope("attacker"))
      end)
    end

    test "there is no resolve/1 bypassing authority" do
      refute function_exported?(FsResolver, :resolve, 1)
    end

    test "authority runs only after R-1 (unregistered type never reaches authority)" do
      # An unregistered type with a cross-ws URI must be :none, not an authority error —
      # proving the allowlist check precedes authority.
      uri = EzURI.resource("victim", "never-registered", "x")
      assert FsResolver.resolve(uri, scope("attacker")) == :none
    end
  end

  describe "R-4 — Home backend reached only on the success path" do
    test "success path joins Home.path(component)/<ws>/<name>" do
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        uri = EzURI.resource("acme", "t-uploads", "file.pdf")
        assert {:ok, path} = FsResolver.resolve(uri, scope("acme"))
        assert path == Path.join([Ezagent.Home.path("t-uploads"), "acme", "file.pdf"])
      end)
    end
  end

  describe "registry — dormant + immutable-after-boot allowlist (codex HIGH/CRITICAL)" do
    test "P0 ships dormant: boot_registrations is empty (zero real types)" do
      assert registered_types() == []
    end

    test "completeness invariant: every registered type has authority/2 + binary backend" do
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        for {_type, spec} <- registered_types() do
          assert is_function(spec.authority, 2)
          assert is_binary(spec.backend_component)
        end
      end)
    end

    test "registry table is :protected — arbitrary (non-owner) code cannot write it" do
      info = :ets.info(@table)
      assert info[:protection] == :protected

      assert_raise ArgumentError, fn ->
        :ets.insert(@table, {"forged", %{backend_component: "x", authority: &ok_authority/2}})
      end
    end

    test "no production runtime registration path: insert_new/seal/unseal are not exported" do
      # The allowlist is a pure function of Registry.boot_registrations/0 applied
      # at init/1; there is NO post-init write message. The only registration API
      # is the :test-only register_for_test/2 (compiled out of :prod).
      refute function_exported?(Ezagent.Resource.FsResolver.Registry, :insert_new, 2)
      refute function_exported?(Ezagent.Resource.FsResolver.Registry, :seal, 0)
      refute function_exported?(Ezagent.Resource.FsResolver.Registry, :unseal, 0)
    end

    test "a restarted Registry reproduces ONLY the (empty) boot allowlist (codex round-4)" do
      # The reopen class is killed by construction: a Registry crash + supervised
      # restart re-runs init/1, which re-applies the SAME boot source — for P0 that
      # is empty, so a restart cannot leave a forged type registered. No
      # externally-mutable flag participates.
      alias Ezagent.Resource.FsResolver.Registry

      pid = Process.whereis(Registry)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      new_pid = wait_for_restart(Registry, pid)
      assert new_pid != pid

      assert registered_types() == [],
             "a restarted Registry must reproduce only the boot allowlist"

      # …and a forged type still does not resolve.
      uri = EzURI.resource("victim", "t-forged", "secret.pdf")
      assert FsResolver.resolve(uri, scope("attacker")) == :none
    end

    test "duplicate registration of the same type fails loud (one-owner-per-type)" do
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        assert {:error, {:already_registered, "t-uploads"}} =
                 FsResolver.register_type("t-uploads", type_spec)
      end)
    end

    test "register_type/2 rejects a malformed spec" do
      assert_raise FunctionClauseError, fn ->
        FsResolver.register_type("", %{backend_component: "x", authority: &ok_authority/2})
      end

      assert_raise FunctionClauseError, fn ->
        FsResolver.register_type("t-bad", %{backend_component: "x", authority: fn _ -> :ok end})
      end
    end

    test "Registry re-validates a malformed spec sent straight to the mailbox" do
      # A 1-arity authority bypasses the facade guard clause but must be rejected
      # by the Registry's own re-validation at the trust boundary.
      bad = %{backend_component: "t-bad", authority: fn _ -> :ok end}

      assert {:error, {:invalid_type_spec, _}} =
               Ezagent.Resource.FsResolver.Registry.register_for_test("t-bad", bad)
    end

    test "a path-shaped backend_component is rejected at registration (codex round-5 HIGH)" do
      # A registered type whose backend escapes its intended Home component (e.g.
      # "../credentials") must be rejected BEFORE it can ever resolve, so no
      # registered resource:// type points outside the resource backend.
      alias Ezagent.Resource.FsResolver.Registry

      for bad_backend <- ["../credentials", "a/b", "a\\b", ".", "..", "x" <> <<0>>, ""] do
        spec = %{backend_component: bad_backend, authority: &ok_authority/2}

        assert {:error, {:invalid_type_spec, _}} =
                 Registry.register_for_test("t-#{System.unique_integer([:positive])}", spec),
               "expected rejection for backend_component #{inspect(bad_backend)}"
      end
    end

    test "an unsafe registered <type> is rejected at registration" do
      alias Ezagent.Resource.FsResolver.Registry
      spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      assert {:error, {:invalid_type_spec, {:unsafe_type, _}}} =
               Registry.register_for_test("a/b", spec)
    end
  end
end
