defmodule Ezagent.Integration.CreateRoleAgentTest do
  @moduledoc """
  RF-5a acceptance — role-driven agent create on the DIRECT-SPAWN path
  (role × native), the role-foundation integration keystone.

  Proves the four wired seams + the RF-6 fail-open fix:

    1. a recipe-loaded UNDECLARED behavior (`RoleTestBehavior`) materializes its
       slice on a generic `Entity.Agent` host (RF-1 generalized init_set), AND
       the flavor BASE behaviors (Sandbox/Identity/ApiKeys) survive the
       `:behaviors` override (HIGH-1 — the override must carry the flavor base or
       the agent is structurally broken);
    2. the recipe's `requested_caps` are minted fail-closed (CapMint × the
       flavor cap-policy) and granted to the agent — minted == recipe;
    3. the durable `passive` marker is stored;
    4. **cold restart**: passive survives a snapshot reload — `resolve_passive`
       returns `true` from the persisted `:sandbox` slice AFTER the ETS fast path
       and the live Kind are both gone (NOT fail-open to principal). This is the
       RF-6 security requirement RF-5a owns.
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Cap.Delivery
  alias Ezagent.Workspace
  alias Ezagent.Entity.User
  alias Ezagent.Workspace.RoleTestBehavior
  alias Ezagent.Workspace.TransportGatedRoleBehavior
  alias Ezagent.{AgentFlavorRegistry, AgentPassiveAttributes, Agent.RecipeRegistry, UriQuery}

  @flavor "rf5a-native"
  @role_name "rf5a-test-role"

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    ws_name = "rf5a-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = %{
      caller: User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
    }

    # Register a `native`-style direct-spawn flavor: the UNIFIED Agent Kind, NO
    # `instance_behaviors` thunk (so a roleless spawn captures the base set), and
    # a fail-closed CapMint policy that grants exactly the recipe's requested
    # caps (RF-8 shape; inline so this test does not depend on the native plugin).
    :ok =
      AgentFlavorRegistry.register(%{
        flavor: @flavor,
        kind: Ezagent.Entity.Agent,
        template_class: nil,
        cap_policy: &cap_policy/1
      })

    # Register a role recipe: one UNDECLARED behavior + one requested cap on it +
    # passive: true.
    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: @role_name,
        passive: true,
        behaviors: [RoleTestBehavior],
        requested_caps: [%{behavior: RoleTestBehavior, action: :ping}]
      })

    RecipeRegistry.flush_cache()

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx}
  end

  # Fail-closed: grant exactly the recipe's {behavior, action} pairs.
  defp cap_policy(requested_caps) do
    allowed =
      requested_caps
      |> Enum.map(fn c -> {Map.get(c, :behavior), Map.get(c, :action)} end)
      |> MapSet.new()

    fn needed ->
      MapSet.member?(allowed, {Map.get(needed, :behavior), Map.get(needed, :action)})
    end
  end

  @tag :integration
  test "role × native — behaviors dispatch (RF-1) + minted caps == recipe + passive stored",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "role-agent-#{System.unique_integer([:positive])}"
      expected_uri = Ezagent.URI.agent(ws_name, name)

      assert {:ok, %{agent_uri: agent_uri, template_name: nil}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: name, role: @role_name, cwd: "", with_pty: false},
                 admin_ctx
               )

      assert agent_uri == expected_uri
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)

      # (1a) The recipe-loaded UNDECLARED behavior materialized its slice — proves
      # it is in this instance's effective set (RF-1 generalized init_set kept an
      # Entity.Agent-undeclared, validated real Behavior).
      assert {:ok, role_slice} = Ezagent.Kind.get_slice(agent_uri, :role_test),
             "the role's recipe-loaded behavior did NOT materialize its slice — " <>
               "the :behaviors override did not reach :kind_base (RF-1/HIGH-1)"

      assert role_slice.pinged == false

      # (1b) The flavor BASE behaviors SURVIVED the override (HIGH-1): without
      # them there is no :sandbox slice to store passive / config_dir and no
      # :identity slice to grant caps into.
      assert {:ok, _sandbox} = Ezagent.Kind.get_slice(agent_uri, :sandbox),
             "base :sandbox slice missing — the role :behaviors override stripped the flavor base"

      assert {:ok, _identity} = Ezagent.Kind.get_slice(agent_uri, :identity),
             "base :identity slice missing — the role :behaviors override stripped the flavor base"

      # (1c) The undeclared behavior dispatches via per-instance resolution (RF-1)
      # and is STILL cap-gated — the agent holds the minted :ping cap so its own
      # self-dispatch authorizes.
      ping_cmd =
        Ezagent.Cmd.new(
          Ezagent.URI.with_action(agent_uri, :role_test, :ping),
          :ping,
          %{},
          %{
            mode: :call,
            caller: agent_uri,
            caps: Ezagent.Identity.list_caps_for(agent_uri),
            reply: {:caller_inbox, self()}
          }
        )

      assert {:ok, %{pong: true}} = Ezagent.Router.dispatch(ping_cmd),
             "the recipe-loaded :ping action did not dispatch via per-instance resolution (RF-1)"

      # (2) Minted caps == the recipe's requested caps, fail-closed. The agent
      # holds exactly one cap for {RoleTestBehavior, :ping}.
      held = Ezagent.Identity.list_caps_for(agent_uri)

      ping_caps =
        held
        |> Enum.filter(fn c -> c.behavior == RoleTestBehavior and c.action == :ping end)

      assert length(ping_caps) == 1,
             "expected exactly the recipe's minted {RoleTestBehavior, :ping} cap, got: " <>
               inspect(Enum.to_list(held))

      # (3) The durable passive marker is stored (both the ETS fast path AND the
      # snapshot-backed slice — verified for cold-restart by the next test).
      assert {:ok, true} = UriQuery.resolve(:passive, agent_uri)
      assert {:ok, true} = AgentPassiveAttributes.fetch(agent_uri)
    end)
  end

  @tag :integration
  test "I3 full create lane returns with a never-joined child, persists its role artifact, and keeps the workspace usable",
       %{ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      unique = System.unique_integer([:positive])
      flavor = "s7-transport-gated-#{unique}"
      recipe = "s7-transport-gated-role-#{unique}"
      name = "never-joined-#{unique}"

      # test.exs widens the generic Kind.spawn ready-observation budget to the
      # same 5 s as Invocation's outer call deadline. This fixture is
      # intentionally never ready, so pin the production-like bounded budget
      # locally; the assertion is that the 30 s transport gate does not become
      # a second blocking grant wait. Restore the application env after the
      # non-async test so no neighboring test inherits the override.
      previous_spawn_budget = Application.get_env(:ezagent_core, :spawn_await_ready_ms)
      Application.put_env(:ezagent_core, :spawn_await_ready_ms, 200)

      on_exit(fn ->
        if is_nil(previous_spawn_budget) do
          Application.delete_env(:ezagent_core, :spawn_await_ready_ms)
        else
          Application.put_env(:ezagent_core, :spawn_await_ready_ms, previous_spawn_budget)
        end
      end)

      :ok =
        AgentFlavorRegistry.register(%{
          flavor: flavor,
          kind: Ezagent.Entity.Agent,
          template_class: nil,
          cap_policy: &cap_policy/1
        })

      {:ok, _} =
        RecipeRegistry.seed_role_if_absent(%{
          name: recipe,
          passive: true,
          behaviors: [TransportGatedRoleBehavior],
          requested_caps: [%{behavior: TransportGatedRoleBehavior, action: :ping}]
        })

      RecipeRegistry.flush_cache()

      create_task =
        Task.async(fn ->
          receive do
            :run_create ->
              Workspace.create_agent(
                workspace_uri,
                %{flavor: flavor, name: name, role: recipe, cwd: "", with_pty: false},
                admin_ctx
              )
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(EzagentCore.Repo, self(), create_task.pid)
      send(create_task.pid, :run_create)

      assert {:ok, {:ok, %{agent_uri: agent_uri, template_name: nil}}} =
               Task.yield(create_task, 5_000) || Task.shutdown(create_task, :brutal_kill)

      assert agent_uri == Ezagent.URI.agent(ws_name, name)
      assert {:ok, agent_pid} = Ezagent.KindRegistry.lookup(agent_uri)
      assert Process.alive?(agent_pid)
      assert Ezagent.ReadyGate.status(agent_uri) == :not_ready

      assert [artifact] = pending_absorb_artifacts(agent_uri)
      assert artifact.behavior == TransportGatedRoleBehavior
      assert Ezagent.Capability.action_of(artifact) == :ping

      refute Enum.any?(Ezagent.Identity.read_entity_caps(agent_uri), fn cap ->
               cap.behavior == TransportGatedRoleBehavior and
                 Ezagent.Capability.action_of(cap) == :ping
             end)

      # The parent Workspace Kind remains live and continues serving a real
      # cap-gated action while the child transport never joins.
      list_cmd =
        Ezagent.Cmd.new(
          Ezagent.URI.with_action(workspace_uri, :workspace, :list_members),
          :list_members,
          %{},
          %{
            mode: :call,
            caller: User.admin_uri(),
            caps: admin_ctx.caps,
            reply: {:caller_inbox, self()}
          }
        )

      # Agent provisioning does not implicitly create a workspace-membership
      # edge. A successful list dispatch is the liveness assertion here; the
      # empty result is the setup's unchanged, semantically correct slice.
      assert {:ok, %{members: []}} = Ezagent.Router.dispatch(list_cmd)

      # A definitive never-ready failure drains only the legacy ETS transport.
      # Capability authority remains durably pending for retry; it is never
      # converted into a diagnostic-only DLQ drop.
      assert :ok = Ezagent.Kind.ReadyTransition.mark_failed(agent_uri)
      assert Ezagent.PendingDelivery.buffer_size(agent_uri) == 0
      assert [^artifact] = pending_absorb_artifacts(agent_uri)

      assert 1 ==
               EzagentCore.Repo.aggregate(
                 from(delivery in Delivery,
                   where: delivery.target_uri == ^URI.to_string(agent_uri),
                   where: delivery.op == :absorb_cap,
                   where: delivery.status == :pending
                 ),
                 :count
               )

      :ok = Ezagent.Agent.TransportReadiness.clear(agent_uri)
      _ = Ezagent.Kind.terminate(agent_uri)
    end)
  end

  @tag :integration
  test "COLD RESTART — passive survives a snapshot reload (NOT fail-open to principal)",
       %{workspace_uri: workspace_uri, admin_ctx: admin_ctx} do
    skip_if_no_entity_spawn(fn ->
      name = "passive-restart-#{System.unique_integer([:positive])}"

      assert {:ok, %{agent_uri: agent_uri}} =
               Workspace.create_agent(
                 workspace_uri,
                 %{flavor: @flavor, name: name, role: @role_name, cwd: "", with_pty: false},
                 admin_ctx
               )

      assert {:ok, true} = UriQuery.resolve(:passive, agent_uri)

      # Simulate a COLD restart: clear the volatile ETS fast path AND terminate
      # the live Kind (its in-memory slice is gone). The ONLY surviving record of
      # `passive` is now the persisted snapshot of the :sandbox slice.
      :ok = AgentPassiveAttributes.delete(agent_uri)
      assert :none = AgentPassiveAttributes.fetch(agent_uri)

      _ = Ezagent.Kind.terminate(agent_uri)

      assert wait_until_deregistered(agent_uri),
             "Kind did not deregister after terminate — cannot prove SNAPSHOT-only resolution"

      # SECURITY ASSERTION: with ETS empty and the Kind not demand-spawned, the
      # passive verdict MUST still be `true` — recovered from the durable
      # snapshot of the :sandbox slice. A fail-open bug returns `false` here
      # (the data-actor reverts to a chat principal across a restart).
      assert {:ok, true} = UriQuery.resolve(:passive, agent_uri),
             "passive FAILED OPEN across a cold restart — resolve_passive did not " <>
               "fall through to the durable :sandbox snapshot (RF-6 fail-open fix)"
    end)
  end

  # KindRegistry deregistration is monitor-driven (async) after terminate;
  # poll until the URI is gone so the cold-restart assertion truly reads the
  # snapshot, not the still-live Kind slice.
  defp wait_until_deregistered(uri, attempts \\ 50)
  defp wait_until_deregistered(_uri, 0), do: false

  defp wait_until_deregistered(uri, attempts) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error ->
        true

      {:ok, _pid} ->
        Process.sleep(10)
        wait_until_deregistered(uri, attempts - 1)
    end
  end

  defp pending_absorb_artifacts(uri) do
    from(delivery in Delivery,
      where: delivery.target_uri == ^URI.to_string(uri),
      where: delivery.op == :absorb_cap,
      where: delivery.status == :pending,
      order_by: [asc: delivery.id],
      select: delivery.payload
    )
    |> EzagentCore.Repo.all()
    |> Enum.map(fn payload ->
      %{version: 1, op: :absorb_cap, cap: artifact} =
        :erlang.binary_to_term(payload, [:safe])

      artifact
    end)
  end

  defp skip_if_no_entity_spawn(body) do
    if not function_exported?(Ezagent.SpawnRegistry, :registered_schemes, 0) or
         "entity" not in Ezagent.SpawnRegistry.registered_schemes() do
      IO.puts(:stderr, "SKIP: entity spawn fn not registered (test bootstrap incomplete)")
      :ok
    else
      body.()
    end
  end
end
