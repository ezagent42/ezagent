defmodule Ezagent.ActionSet.PtyMigrationParityTest do
  @moduledoc """
  Phase 2.5 migration parity test for `Ezagent.ActionSet.Pty` per
  SPEC `2026-05-28-router-behavior-kind-architecture.md` §7.3 Level 1
  (dispatch parity).

  Validates that the migrated `Ezagent.ActionSet.Pty` produces the
  same dispatch-visible outcome via the new-contract path
  (`Kind.Runtime.handle_dispatch/4` → `handle_write/2` →
  `apply_effects/2`) as the legacy `invoke/4` shape did pre-migration.

  ## Codex r3 P2-g coverage — full dispatch path

  The `:write` dispatch-path test exercises the WHOLE pipeline:

      Invocation → BehaviorRegistry → CapBAC → handle_write/2 →
      Server.write_input/2 (URI-addressed) → {:set, :write_calls, ...} +
      {:set, :total_bytes, ...} effects → state writeback

  Reuses the same test_mode PtyServer pattern as the pre-migration
  `pty_test.exs` so the comparison is direct.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{BehaviorRegistry, Invocation}
  alias Ezagent.ActionSet.Pty

  defmodule StubAgentKind do
    @moduledoc false
    @behaviour Ezagent.Kind

    @impl true
    def type_name, do: :pty_parity_stub
    @impl true
    def behaviors, do: [Ezagent.ActionSet.Pty]
    @impl true
    def persistence, do: :ephemeral
  end

  setup do
    :ok = BehaviorRegistry.register(StubAgentKind, :write, Pty)

    # Stable agent name per test to ensure isolation (the live Agent
    # Kind + PtyServer are looked up by URI; collisions would mask bugs).
    name = "cc_pty-parity-#{System.unique_integer([:positive])}"
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/#{name}")

    # Live PTY-capable test Kind + PtyServer setup — mirrors `pty_test.exs`.
    {:ok, _kind_pid} = EzagentDomainPty.Test.PtyAgentFixture.spawn(agent_uri)

    {:ok, pty_pid} =
      Ezagent.Domain.Pty.start(agent_uri, %{
        cwd: File.cwd!(),
        test_mode: true
      })

    on_exit(fn ->
      if Process.alive?(pty_pid), do: Process.exit(pty_pid, :shutdown)
    end)

    admin_caps = MapSet.new([Ezagent.Capability.admin_genesis_cap()])

    {:ok, agent_uri: agent_uri, admin_caps: admin_caps}
  end

  defp build_invocation(agent_uri, bytes, caps) do
    target = Ezagent.URI.new!("#{URI.to_string(agent_uri)}?action=pty.write")

    %Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{bytes: bytes},
      ctx: %{caller: Ezagent.URI.new!("entity://system/user/admin"), caps: caps, reply: :sync}
    }
    |> signed_invocation!(:pty_parity_stub)
  end

  describe "new-contract markers (SPEC §2.2)" do
    test "new_style?/1 returns true" do
      assert Ezagent.ActionSet.new_style?(Pty)
    end

    test "__action_names__/0 lists [:write, :restart]" do
      assert Pty.__action_names__() == [:write, :restart]
    end

    test "handle_write/2 is exported (macro invariant)" do
      assert function_exported?(Pty, :handle_write, 2)
    end
  end

  describe "Level 1 — dispatch parity through Kind.Runtime" do
    test ":write via Kind.Runtime.handle_dispatch/4 — full dispatch path",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # FULL dispatch-path coverage (codex r3 P2-g). Exercises:
      #   - BehaviorRegistry lookup
      #   - CapBAC (admin caps satisfy the :agent/:write gate)
      #   - handle_write/2 invocation
      #   - Server.write_input/2 (URI-addressed; real test_mode
      #     PtyServer writes)
      #   - {:set, :write_calls, +1} + {:set, :total_bytes, +N} effects
      #   - State writeback to the live Agent Kind
      bytes = "hello-parity"

      # Use the same kind-server state pattern as Kind.Runtime would
      # see — fresh slice (empty %{}; the lazy-init in the handler
      # seeds counters).
      state = %{pty: %{write_calls: 0, total_bytes: 0}}

      inv = build_invocation(agent_uri, bytes, admin_caps)

      assert {:ok, new_state, %{bytes_written: bytes_written}, _slice_change_event, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      assert bytes_written == byte_size(bytes)

      # Slice counters bumped via :set effects.
      assert new_state.pty.write_calls == 1
      assert new_state.pty.total_bytes == byte_size(bytes)
    end

    test ":write accumulates counters across multiple dispatches",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # Three writes — counters must accumulate, not reset.
      payloads = ["a", "bb", "ccc"]

      Enum.reduce(payloads, %{pty: %{write_calls: 0, total_bytes: 0}}, fn payload, state ->
        inv = build_invocation(agent_uri, payload, admin_caps)

        assert {:ok, new_state, _result, _evt, _deferred} =
                 Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

        assert new_state.pty.write_calls == state.pty.write_calls + 1
        assert new_state.pty.total_bytes == state.pty.total_bytes + byte_size(payload)

        new_state
      end)
    end

    test ":write lazy-seeds counters from empty slice (Behavior registered after-the-fact)",
         %{agent_uri: agent_uri, admin_caps: admin_caps} do
      # Per the moduledoc: Pty is registered on Agent Kind via
      # BehaviorRegistry.register at boot (NOT statically declared in
      # Agent.behaviors/0), so the runtime may hand the handler an
      # empty %{} slice on first dispatch.
      state = %{pty: %{}}

      inv = build_invocation(agent_uri, "x", admin_caps)

      assert {:ok, new_state, _result, _evt, _deferred} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, agent_uri)

      # Counter lazy-seeded to base + 1.
      assert new_state.pty.write_calls == 1
      assert new_state.pty.total_bytes == 1
    end
  end

  describe "error paths" do
    test ":write — agent with no PtyServer → :no_pty_server",
         %{admin_caps: admin_caps} do
      # Spawn a fresh PTY-capable test Kind without a PtyServer.
      bare_uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_pty-parity-no-pty-#{System.unique_integer([:positive])}"
        )

      {:ok, _kind_pid} = EzagentDomainPty.Test.PtyAgentFixture.spawn(bare_uri)

      state = %{pty: %{write_calls: 0, total_bytes: 0}}
      inv = build_invocation(bare_uri, "x", admin_caps)

      assert {:error, :no_pty_server} =
               Ezagent.Kind.Runtime.handle_dispatch(inv, state, StubAgentKind, bare_uri)
    end
  end

  describe "legacy callbacks remain available (framework wiring)" do
    test "actions/0, interface/0, cap_subjects/0 all defined" do
      assert Pty.actions() == [:write, :restart]
      assert Map.has_key?(Pty.interface(), :write)
      assert [{:write, desc}, {:restart, restart_desc}] = Pty.cap_subjects()
      assert is_binary(desc) and desc != ""
      assert is_binary(restart_desc) and restart_desc != ""
    end

    # CONTRACT CHANGE (Allen, 2026-07-14 — "the terminal belongs to the
    # creator"). This test previously pinned `behavior: Pty, action: :write`.
    # Both PTY actions are now gated on the agent's MANAGE cap — the authority
    # the creator already holds from creation — because nothing in the repo ever
    # minted a Pty cap, so the creator could neither type into nor watch the
    # terminal of the agent they had just created. The `:agent` kind axis, which
    # is what this test is really about, is unchanged.
    test "required_caps/0 uses the :agent axis (now on the MANAGE authority)" do
      caps = Pty.required_caps()

      for action <- [:write, :restart] do
        assert %Ezagent.Capability{
                 kind: :agent,
                 behavior: Ezagent.ActionSet.Manage,
                 action: :any
               } = caps[action]
      end
    end

    test "state_slice/0 unchanged; init_slice/1 builds the two-container shape" do
      # state_slice is auto-derived by the Lifecycle macro from the
      # module's last segment (`Pty` → `:pty`) — the SAME key the
      # pre-Lifecycle module declared, so snapshot compatibility holds
      # with no explicit override (SPEC §3 / §7 OQ-7).
      assert Pty.state_slice() == :pty

      # Lifecycle migration (SPEC 2026-05-29 §2.1): `init_slice/1` is now
      # macro-emitted and returns the two-container `%{state: ...,
      # transients: %{}}` shape. The durable counters `create/1` builds
      # live under `:state`; `transients` is empty (no PtyServer handle is
      # held — it's resolved per-write through the resolver seam).
      assert Pty.init_slice(%{}) == %{state: %{write_calls: 0, total_bytes: 0}, transients: %{}}
    end

    test "interface declares both :call AND :cast modes" do
      iface = Pty.interface()
      assert :call in iface[:write].modes
      assert :cast in iface[:write].modes
    end

    test "data_owner/1 — entity URI returns the canonical instance URI" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_x")
      assert %URI{} = Pty.data_owner(uri)
    end
  end
end
