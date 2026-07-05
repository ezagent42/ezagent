# Fixture plugin modules for the init-time discovery-replay tests (Bug B). Each
# stands in for a real plugin's `:ezagent_plugin` contract module exposing
# `resource_types/0`; the tests point a loaded app's `:ezagent_plugin` env at one.
defmodule Ezagent.Resource.FsResolverTest.ReplayFixturePlugin do
  @moduledoc false
  def resource_types,
    do: [
      {"test-replay-type",
       %{backend_component: "test-replay-backend", authority: fn _uri, _scope -> :ok end}}
    ]
end

defmodule Ezagent.Resource.FsResolverTest.ReplayAliasAttackPlugin do
  @moduledoc false
  # A plugin trying to alias a CORE backend ("uploads") under a new type — must be
  # rejected by write-once-on-backend even through the init-discovery path.
  def resource_types,
    do: [
      {"test-replay-alias",
       %{backend_component: "uploads", authority: fn _uri, _scope -> :ok end}}
    ]
end

defmodule Ezagent.Resource.FsResolverTest.ReplayThrowingPlugin do
  @moduledoc false
  # A buggy plugin whose `resource_types/0` THROWS (not an :error-class raise) —
  # `init/1`'s replay must isolate it via the `catch` arm (codex MED-1), never
  # letting it abort the Registry start.
  def resource_types, do: throw(:boom_from_plugin)
end

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
      pid when is_pid(pid) and pid != old_pid ->
        # #108 readiness barrier: a GenServer's registered name is bound in
        # `:gen.init_it` BEFORE `init/1` runs, but `init/1` is where the
        # `:protected` ETS table is created AND populated
        # (`batch_register(boot_registrations())`). Returning on mere pid
        # existence races an empty/absent table → transient `:none` and a flaky
        # failure under a loaded CI runner. A sync call is served only AFTER
        # `init/1` returns, so this guarantees the boot types are registered
        # before the caller asserts `resolve/2`.
        _ = :sys.get_state(pid)
        pid

      _ ->
        Process.sleep(20) && wait_for_restart(name, old_pid, attempts - 1)
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
    test "P1 boot allowlist: config-dir <ns>-agents types registered (was P0-dormant)" do
      # P0 shipped dormant (empty); P1 registers the per-agent config-dir families
      # from Registry.boot_registrations/0. Each <ns>-agents type's backend equals
      # its own name → byte-identical Home.path("<ns>-agents")/<ws>/<name>.
      types = Map.new(registered_types())

      for ns <- ["cc", "codex"] do
        type = "#{ns}-agents"
        assert %{backend_component: ^type, authority: authority} = types[type]
        assert is_function(authority, 2)
      end
    end

    test "config_dir_type?/1 is true for the registered <ns>-agents family, false otherwise" do
      # Keyed on authority IDENTITY (config_dir_authority/2), not a string suffix —
      # so it claims the real config-dir family but NOT a future non-config type
      # (e.g. uploads) nor an unregistered type. This is what scopes the
      # :config_dir attr's fail-loud behavior so unrelated resource layers fall
      # through to :none (codex P1 round-5 HIGH).
      assert FsResolver.config_dir_type?("cc-agents")
      assert FsResolver.config_dir_type?("codex-agents")
      assert FsResolver.config_dir_type?("codex-remote-agents")
      refute FsResolver.config_dir_type?("uploads")
      refute FsResolver.config_dir_type?("never-registered")

      # A registered type with a DIFFERENT authority is NOT a config-dir type.
      type_spec = %{backend_component: "t-uploads", authority: &ok_authority/2}

      with_type("t-uploads", type_spec, fn ->
        refute FsResolver.config_dir_type?("t-uploads")
      end)
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

    test "a restarted Registry rebuilds PURELY from source — core self-heals, a forged type is gone (codex round-4)" do
      # The reopen class is killed by construction: a Registry crash + supervised
      # restart re-runs init/1, which rebuilds the table PURELY from source —
      # core `boot_registrations/0` PLUS the discovery-replay of each loaded
      # plugin's `resource_types/0` (Bug B). Nothing externally-mutated survives:
      # a type forged into the live table by a test (standing in for any non-source
      # mutation) is GONE after the restart, while core boot types self-heal. (The
      # plugin-types-self-heal arm is covered by the dedicated init-replay tests.)
      alias Ezagent.Resource.FsResolver.Registry

      forged = "t-forged-#{System.unique_integer([:positive])}"

      Registry.register_for_test(forged, %{
        backend_component: forged,
        authority: &ok_authority/2
      })

      assert MapSet.member?(MapSet.new(registered_types(), fn {t, _} -> t end), forged)

      pid = Process.whereis(Registry)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      new_pid = wait_for_restart(Registry, pid)
      assert new_pid != pid

      types = MapSet.new(registered_types(), fn {t, _} -> t end)
      # Core boot types self-heal (rebuilt from `boot_registrations/0`).
      assert MapSet.subset?(MapSet.new(["cc-agents", "codex-agents", "uploads"]), types)
      # The forged (non-source) type is GONE — the table is rebuilt only from source.
      refute MapSet.member?(types, forged)

      # …and a never-registered forged type still does not resolve.
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

  describe "register_all/1 — owner-only write-once on type AND backend, all-or-nothing (plugin-resource SPEC §4.3 / §6)" do
    alias Ezagent.Resource.FsResolver.Registry

    # Cleanup helper — register_all/1 has no production unregister; in :test we
    # reach through the test-only unregister to scrub anything a case inserted.
    defp scrub(types), do: Enum.each(types, &FsResolver.unregister_type/1)

    test "register_all/1 succeeds for fresh distinct types and they then resolve" do
      a = "ra-#{System.unique_integer([:positive])}"
      b = "ra-#{System.unique_integer([:positive])}"

      decls = [
        {a, %{backend_component: a, authority: &ok_authority/2}},
        {b, %{backend_component: b, authority: &ok_authority/2}}
      ]

      try do
        assert :ok = Registry.register_all(decls)

        assert {:ok, _} = FsResolver.resolve(EzURI.resource("acme", a, "f"), scope("acme"))
        assert {:ok, _} = FsResolver.resolve(EzURI.resource("acme", b, "f"), scope("acme"))
      after
        scrub([a, b])
      end
    end

    test "a malformed decl is rejected as an error, does NOT crash the Registry (codex MEDIUM)" do
      # A plugin returning e.g. [:bad] from resource_types/0 must NOT
      # FunctionClauseError the owner GenServer (which would, on the supervised
      # restart, drop every other plugin's already-registered types).
      assert {:error, {:invalid_resource_type_decl, :bad}} = Registry.register_all([:bad])

      assert {:error, {:invalid_resource_type_decl, _}} =
               Registry.register_all([{"only-a-type-no-spec"}])

      # The Registry is still alive + functional after the rejected malformed batch.
      t = "ra-#{System.unique_integer([:positive])}"

      try do
        assert :ok =
                 Registry.register_all([{t, %{backend_component: t, authority: &ok_authority/2}}])
      after
        scrub([t])
      end
    end

    test "a second register_all of an existing <type> → {:error, {:duplicate_type, _}} (write-once on type)" do
      t = "ra-#{System.unique_integer([:positive])}"
      decl = [{t, %{backend_component: t, authority: &ok_authority/2}}]

      try do
        assert :ok = Registry.register_all(decl)

        assert {:error, {:duplicate_type, ^t}} =
                 Registry.register_all([
                   {t, %{backend_component: "ra-other", authority: &ok_authority/2}}
                 ])
      after
        scrub([t])
      end
    end

    test "an IDENTICAL re-registration (same <type> + same backend) is idempotent → :ok (Bug B: release first-boot replay + Phase-2 double call)" do
      # In an OTP release the boot script loads every app before starting any, so
      # the Registry's init-time discovery-replay registers a plugin's types AND
      # then that plugin's own Phase-2 `register_all/1` re-presents the SAME decls.
      # That second call MUST be a no-op `:ok`, not `{:duplicate_type, _}` —
      # `Ezagent.Plugin.boot/2` RAISES on a register_all error, so a non-idempotent
      # path would turn a silent restart bug into a first-boot crash.
      t = "ra-#{System.unique_integer([:positive])}"
      decl = [{t, %{backend_component: t, authority: &ok_authority/2}}]

      try do
        assert :ok = Registry.register_all(decl)
        # Identical decl again → idempotent no-op, NOT an error.
        assert :ok = Registry.register_all(decl)
        # Still resolves (kept, not dropped).
        assert {:ok, _} = FsResolver.resolve(EzURI.resource("acme", t, "f"), scope("acme"))
      after
        scrub([t])
      end
    end

    test "idempotency is first-writer-wins: a re-register with the SAME backend keeps the ORIGINAL spec (no overwrite)" do
      # The idempotent no-op must NOT let a re-registration swap the authority fn
      # (which would be an authority-downgrade vector). Register a strict authority,
      # re-register the same type+backend with a permissive one, and prove the
      # ORIGINAL strict authority still governs (foreign workspace still denied).
      t = "ra-#{System.unique_integer([:positive])}"
      strict = [{t, %{backend_component: t, authority: &FsResolver.uploads_authority/2}}]
      permissive = [{t, %{backend_component: t, authority: fn _uri, _scope -> :ok end}}]

      try do
        assert :ok = Registry.register_all(strict)
        assert :ok = Registry.register_all(permissive)
        # Original (strict, workspace-scoped) authority kept: foreign ws denied.
        assert {:error, {:foreign_workspace, _}} =
                 FsResolver.resolve(EzURI.resource("victim", t, "f"), scope("acme"))
      after
        scrub([t])
      end
    end

    test "backend-aliasing attack: a FRESH type whose backend_component is a registered backend is rejected (codex HIGH-1)" do
      # The exact escalation: register a brand-new <type> that aliases the core
      # "uploads" backend with a WEAKER authority. Backend-uniqueness must reject
      # it, so a plugin can never reach a core backend's bytes through an alias.
      weak = "ra-alias-#{System.unique_integer([:positive])}"

      decl = [{weak, %{backend_component: "uploads", authority: fn _uri, _scope -> :ok end}}]

      assert {:error, {:duplicate_backend, "uploads"}} = Registry.register_all(decl)

      # NOTHING inserted — the alias type does not resolve.
      assert FsResolver.resolve(EzURI.resource("victim", weak, "secret"), scope("victim")) ==
               :none
    end

    test "batch all-or-nothing: a batch whose 2nd decl is a dup inserts NEITHER (codex HIGH-5)" do
      good = "ra-#{System.unique_integer([:positive])}"

      batch = [
        {good, %{backend_component: good, authority: &ok_authority/2}},
        # 2nd decl aliases the core "uploads" backend → whole batch rejected.
        {"ra-bad-#{System.unique_integer([:positive])}",
         %{backend_component: "uploads", authority: &ok_authority/2}}
      ]

      try do
        assert {:error, {:duplicate_backend, "uploads"}} = Registry.register_all(batch)

        # The 1st (valid) decl must NOT be left dangling.
        assert FsResolver.resolve(EzURI.resource("acme", good, "f"), scope("acme")) == :none
      after
        scrub([good])
      end
    end

    test "intra-batch uniqueness: two decls sharing a backend in ONE batch are rejected (insert_new keys only on type)" do
      a = "ra-#{System.unique_integer([:positive])}"
      b = "ra-#{System.unique_integer([:positive])}"
      shared = "ra-backend-#{System.unique_integer([:positive])}"

      batch = [
        {a, %{backend_component: shared, authority: &ok_authority/2}},
        {b, %{backend_component: shared, authority: &ok_authority/2}}
      ]

      try do
        assert {:error, {:duplicate_backend, ^shared}} = Registry.register_all(batch)
        # Neither inserted.
        assert FsResolver.resolve(EzURI.resource("acme", a, "f"), scope("acme")) == :none
        assert FsResolver.resolve(EzURI.resource("acme", b, "f"), scope("acme")) == :none
      after
        scrub([a, b])
      end
    end

    test "register_all/1 rejects a malformed spec and inserts nothing" do
      t = "ra-#{System.unique_integer([:positive])}"
      # 1-arity authority is malformed; validate_spec/2 rejects it.
      bad = [{t, %{backend_component: t, authority: fn _ -> :ok end}}]

      assert {:error, {:invalid_type_spec, _}} = Registry.register_all(bad)
      assert FsResolver.resolve(EzURI.resource("acme", t, "f"), scope("acme")) == :none
    end

    test "core boot types (cc-agents/codex-agents/codex-remote-agents/uploads) still register through the same precheck" do
      types = MapSet.new(registered_types(), fn {t, _} -> t end)

      assert MapSet.subset?(
               MapSet.new(["cc-agents", "codex-agents", "codex-remote-agents", "uploads"]),
               types
             )
    end

    # ── Bug B: init-time discovery-replay of plugin resource_types/0 (restart self-heal) ──

    # Point a loaded app's `:ezagent_plugin` env at `mod`, run the body, restore.
    defp with_plugin_env(mod, fun) do
      prior = Application.get_env(:ezagent_core, :ezagent_plugin)
      Application.put_env(:ezagent_core, :ezagent_plugin, mod)

      try do
        fun.()
      after
        if prior,
          do: Application.put_env(:ezagent_core, :ezagent_plugin, prior),
          else: Application.delete_env(:ezagent_core, :ezagent_plugin)
      end
    end

    test "init-replay discovers a loaded plugin's resource_types/0 and re-registers it (restart self-heal)" do
      alias Ezagent.Resource.FsResolverTest.ReplayFixturePlugin
      uri = EzURI.resource("acme", "test-replay-type", "f")

      with_plugin_env(ReplayFixturePlugin, fn ->
        try do
          # Not present yet (simulates the post-restart fresh table before replay).
          assert FsResolver.resolve(uri, scope("acme")) == :none

          # This is the SAME discovery+replay `init/1` runs on EVERY start.
          assert :ok = Registry.replay_plugins_for_test()

          # The plugin type is restored — proving a restart re-registers it.
          assert {:ok, _path} = FsResolver.resolve(uri, scope("acme"))

          # Idempotent: a second replay (type already present) does NOT crash.
          assert :ok = Registry.replay_plugins_for_test()
          assert {:ok, _path} = FsResolver.resolve(uri, scope("acme"))
        after
          FsResolver.unregister_type("test-replay-type")
        end
      end)
    end

    test "init-replay still enforces write-once: a plugin aliasing a core backend is skipped, not registered" do
      alias Ezagent.Resource.FsResolverTest.ReplayAliasAttackPlugin
      uri = EzURI.resource("acme", "test-replay-alias", "f")

      with_plugin_env(ReplayAliasAttackPlugin, fn ->
        # Replay does not crash (per-plugin skip-on-error)...
        assert :ok = Registry.replay_plugins_for_test()
        # ...and the aliasing type was NOT registered (backend "uploads" already
        # claimed by core → write-once-on-backend rejects it).
        assert FsResolver.resolve(uri, scope("acme")) == :none
        # The core "uploads" type is intact (still its own authority).
        assert MapSet.member?(MapSet.new(registered_types(), fn {t, _} -> t end), "uploads")
      end)
    end

    test "init-replay isolates a plugin whose resource_types/0 THROWS (codex MED-1: catch arm, not just rescue)" do
      alias Ezagent.Resource.FsResolverTest.ReplayThrowingPlugin

      with_plugin_env(ReplayThrowingPlugin, fn ->
        # A `throw` from the plugin callback is NOT an :error-class exception, so a
        # bare `rescue` would let it escape and abort the Registry start. The
        # `catch` arm must isolate it: replay completes :ok, Registry stays alive.
        assert :ok = Registry.replay_plugins_for_test()

        # Registry is still alive + functional after the throwing plugin was skipped
        # (core types still resolve, and a fresh register still works).
        assert {:ok, _} =
                 FsResolver.resolve(EzURI.resource("acme", "uploads", "f.pdf"), scope("acme"))

        t = "ra-#{System.unique_integer([:positive])}"

        try do
          assert :ok =
                   Registry.register_all([
                     {t, %{backend_component: t, authority: &ok_authority/2}}
                   ])
        after
          FsResolver.unregister_type(t)
        end
      end)
    end
  end

  describe "restart resilience (codex HIGH-2) — core types self-heal, never silently missing" do
    alias Ezagent.Resource.FsResolver.Registry

    test "self-heal: after kill+restart a CORE boot type resolves again (present again)" do
      # init/1 re-applies boot_registrations/0 on restart, so a core boot type
      # self-heals once the supervised restart completes. (The "reproduces ONLY
      # the boot allowlist" axis is covered by the round-4 restart test above.)
      uri = EzURI.resource("acme", "uploads", "f.pdf")

      pid = Process.whereis(Registry)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      new_pid = wait_for_restart(Registry, pid)
      assert new_pid != pid
      assert {:ok, _} = FsResolver.resolve(uri, scope("acme"))
    end

    test "loud-when-absent: with the Registry terminated, resolve/2 RAISES — never a silent :none" do
      # Deterministically hold the Registry DOWN via the supervisor (no kill-race:
      # terminate_child does NOT auto-restart and does NOT count against the
      # :one_for_one max-restart intensity, so this neither flakes nor cascades).
      # While the ETS table is GONE, resolve/2's lookup rescue raises loud rather
      # than treating every type as unregistered (a silent :none would be a
      # security-relevant lie). NOTE: this covers the table-ABSENT case; a
      # sub-millisecond restart window where the table exists but is not yet
      # populated can still return a transient (retryable) :none — strictly
      # narrower than the EtsOwner siblings' empty-table window, never an authority
      # bypass (see the Registry moduledoc).
      uri = EzURI.resource("acme", "uploads", "f.pdf")

      :ok = Supervisor.terminate_child(EzagentCore.Supervisor, Registry)

      try do
        assert_raise RuntimeError, ~r/not running/, fn ->
          FsResolver.resolve(uri, scope("acme"))
        end
      after
        {:ok, _} = Supervisor.restart_child(EzagentCore.Supervisor, Registry)
      end

      # Restored — resolves again.
      assert {:ok, _} = FsResolver.resolve(uri, scope("acme"))
    end
  end

  describe "slug-prefix lint (codex HIGH-6 / D7) — advisory, core's bare names exempt" do
    # D7: a plugin-contributed <type> SHOULD be slug-prefixed (`world-layouts`),
    # so two plugins never collide. The lint is a TEST (not a runtime warning in
    # register_all, which now also carries core's bare names). Core types keep
    # their bare names by design and are exempt.
    @core_bare_types ["cc-agents", "codex-agents", "codex-remote-agents", "uploads"]

    test "core's bare types are the only un-prefixed types declared in-tree" do
      # Enumerate every plugin's resource_types/0 in the umbrella and assert each
      # is slug-prefixed with that plugin's slug. Standalone ezagent_core has no
      # plugins on the path; this is the umbrella gate.
      plugin_modules =
        for {app, _, _} <- Application.loaded_applications(),
            app_str = Atom.to_string(app),
            String.starts_with?(app_str, "ezagent_plugin_"),
            mod = plugin_module_for(app),
            not is_nil(mod),
            function_exported?(mod, :resource_types, 0),
            do: mod

      offenders =
        for mod <- plugin_modules,
            {type, _spec} <- mod.resource_types(),
            slug = mod.plugin_info().slug,
            not String.starts_with?(type, slug <> "-"),
            do: {mod, type, slug}

      assert offenders == [],
             "plugin-contributed resource <type>s must be slug-prefixed (D7): #{inspect(offenders)}"
    end

    # Resolve a plugin's `EzagentPlugin*` module from its app name. Best-effort;
    # returns nil if the app's top module isn't a plugin module.
    defp plugin_module_for(app) do
      mod = app |> Atom.to_string() |> Macro.camelize() |> List.wrap() |> Module.concat()
      if Code.ensure_loaded?(mod) and function_exported?(mod, :plugin_info, 0), do: mod, else: nil
    rescue
      _ -> nil
    end

    test "a non-prefixed plugin type would be flagged by the lint predicate" do
      # Pure predicate check (no registration) — proves the lint logic catches a
      # bare plugin type. `_core_bare_types` documents the exemption set.
      assert "layouts" not in @core_bare_types
      slug = "world"
      bare = "layouts"
      prefixed = "world-layouts"
      refute String.starts_with?(bare, slug <> "-")
      assert String.starts_with?(prefixed, slug <> "-")
    end
  end

  describe "uploads type (Resource-unification P2b)" do
    test "the `uploads` type is registered at boot with backend \"uploads\"" do
      types = Map.new(registered_types())
      assert %{backend_component: "uploads", authority: authority} = types["uploads"]
      assert is_function(authority, 2)
    end

    test "uploads is NOT a config-dir type (distinct authority)" do
      refute FsResolver.config_dir_type?("uploads")
    end

    test "resolve of a same-workspace uploads URI joins …/uploads/<ws>/<name>" do
      uri = EzURI.resource("acme", "uploads", "f.pdf")
      assert {:ok, path} = FsResolver.resolve(uri, scope("acme"))
      assert path == Path.join([Ezagent.Home.path("uploads"), "acme", "f.pdf"])
    end

    test "resolve of a FOREIGN-workspace uploads URI is denied (authority/2)" do
      uri = EzURI.resource("victim", "uploads", "f.pdf")
      assert {:error, {:foreign_workspace, _}} = FsResolver.resolve(uri, scope("acme"))
    end

    test "uploads_authority/2 enforces uri.<ws> == scope.workspace" do
      uri = EzURI.resource("acme", "uploads", "f.pdf")
      assert :ok = FsResolver.uploads_authority(uri, scope("acme"))
      assert {:error, {:foreign_workspace, _}} = FsResolver.uploads_authority(uri, scope("beta"))
    end
  end
end
