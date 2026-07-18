defmodule Ezagent.ActionSet.ConfigEvolveTest do
  @moduledoc """
  PR-2 — `Ezagent.ActionSet.ConfigEvolve` on the Agent (spec 2026-06-11 rev 4,
  §7 tests). The behavior is NOT yet wired into Turn (PR-3); the old
  `ConfigUpdate` path still runs. These tests drive ConfigEvolve in isolation
  by dispatching `config_evolve.apply_config_delta` directly to a spawned
  Agent Kind.

  Covers §7:
   1. authority gate — manager (manage-cap) CAN apply; stranger denied.
   2. durable apply — object + pointer written, applied marker set, idempotent.
   3. step-2 projection — deferred sandbox.update_config refreshes the cache.
   4. no cross-entity escalation — write fails (logged, non-fatal) without the
      self-cap (proves it is genuinely self-cap-gated).
   5. boot reconciliation — divergence (apply but drop the deferred dispatch)
      is healed on restart (`activate` → reconcile re-projects).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_ctx!: 3, signed_invocation!: 2]

  alias Ezagent.{Invocation, CreatorGrant}
  alias Ezagent.Entity.{Agent, User}
  alias Ezagent.Socialware.{ConfigObject, ConfigProjection, ConfigStore}

  @cascade_key "agent.soul"

  setup do
    name = "ce-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    workspace = Ezagent.Capability.workspace_of(agent)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: MapSet.new()})
    # Workspace-bind so manage-cap workspace matching resolves.
    :ok = Ezagent.WorkspaceRegistry.bind(agent, workspace)

    %{agent: agent, workspace: workspace}
  end

  # ---- §7.1 authority gate -------------------------------------------------

  test "apply_config_delta is DENIED without the agent's manage-cap", %{agent: agent} do
    target = action_uri(agent, :apply_config_delta)

    assert {:error, :missing_cap} =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: target,
               mode: :call,
               args: %{turn_id: "t1", patch: %{"tone" => "decisive"}},
               ctx: %{
                 caller: Ezagent.URI.entity(:team_alpha, :user, "stranger"),
                 caps: MapSet.new(),
                 reply: {:caller_inbox, self()}
               }
             })
  end

  # ---- §7.2 durable apply --------------------------------------------------

  test "apply_config_delta writes the immutable object + pointer (manager authorized)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-apply-#{System.unique_integer([:positive])}"

    assert {:ok, %{config_id: cid}} =
             apply_delta(agent, manager, turn_id, %{"tone" => "decisive"})

    assert {:ok, _object} = ConfigStore.fetch_object(cid)
    assert ConfigStore.applied_for_turn?(turn_id)

    # The pointer resolves the new object on the agent's own user layer.
    assert {:ok, ^cid} = ConfigStore.current_user_object(agent, @cascade_key)
  end

  test "apply_config_delta is idempotent-stamped by source_turn_id (replay marker)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-replay-#{System.unique_integer([:positive])}"

    refute ConfigStore.applied_for_turn?(turn_id)
    assert {:ok, %{config_id: _}} = apply_delta(agent, manager, turn_id, %{"tone" => "v2"})
    assert ConfigStore.applied_for_turn?(turn_id)
  end

  # ---- §7.3 step-2 projection ---------------------------------------------

  test "after apply, the deferred sandbox.update_config refreshes cascade_resolution.user_layer_uri",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-proj-#{System.unique_integer([:positive])}"

    {:ok, %{config_id: cid}} = apply_delta(agent, manager, turn_id, %{"tone" => "decisive"})

    want = URI.to_string(ConfigProjection.object_uri(workspace, cid))

    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want end),
           "deferred sandbox.update_config never refreshed user_layer_uri to #{want}; " <>
             "got #{inspect(sandbox_user_layer_uri(agent))}"
  end

  # ---- §7.4 no cross-entity escalation (self-cap gated) --------------------

  # The sandbox write is genuinely cap-gated: a caller WITHOUT the agent's
  # self-scoped `cap(:agent, Sandbox, :update_config)` is denied. The step-2
  # projection succeeds (§7.3) precisely because it carries the agent's OWN
  # caps (read from its :identity sibling), not the step-1 manager's caps —
  # the manager holds only the manage-cap, which does NOT authorize
  # sandbox.update_config. This pair (this test + §7.3) proves the write is
  # authorized by the self-cap and nothing weaker.
  test "sandbox.update_config is denied to a caller lacking the agent's self-cap",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    # The manager holds ONLY the manage-cap — NOT Sandbox.update_config.
    manager = grant_manage_cap(agent, workspace)

    assert {:error, :missing_cap} =
             Invocation.dispatch(%Invocation{
               origin: :trusted_internal,
               target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.update_config"),
               mode: :call,
               args: %{
                 config_dir_path: "/tmp/x",
                 template_class: nil,
                 respawn_template_data: %{"flavor" => "cc"}
               },
               ctx: %{caller: manager.uri, caps: manager.caps, reply: {:caller_inbox, self()}}
             })
  end

  # ---- §7.5 boot reconciliation -------------------------------------------

  test "boot reconciliation re-projects when the Sandbox cache diverges from ConfigStore",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-recon-#{System.unique_integer([:positive])}"

    # Apply durably, but write a STALE cascade pointer directly into the
    # sandbox to simulate "step 1 committed, step 2 (the deferred dispatch)
    # never ran / was lost" — the crash window.
    {:ok, %{config_id: cid}} = apply_delta(agent, manager, turn_id, %{"tone" => "decisive"})
    force_sandbox_user_layer(agent, workspace, "stale://layer")
    assert sandbox_user_layer_uri(agent) == "stale://layer"

    want = URI.to_string(ConfigProjection.object_uri(workspace, cid))

    # Restart the agent → activate/2 self-defers reconcile_cascade → it
    # re-projects the durable pointer into the Sandbox cache.
    restart_agent(agent)

    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want end),
           "boot reconciliation never re-projected user_layer_uri to #{want}; " <>
             "got #{inspect(sandbox_user_layer_uri(agent))}"
  end

  # ---- CE-1 cross-agent confused-deputy (security) -------------------------

  # A caller holding agent A's manage-cap dispatches apply_config_delta TO A
  # but with `subject_uri` = agent B. The agent must ONLY ever apply config to
  # ITSELF: the dispatch is denied/errors and B's config is unchanged.
  test "apply_config_delta refuses a subject_uri that is not the receiving agent (CE-1)",
       %{agent: agent_a, workspace: workspace} do
    # A second agent B in the same workspace — the confused-deputy victim.
    name_b = "ce-victim-#{System.unique_integer([:positive])}"
    agent_b = Ezagent.URI.entity(:team_alpha, :agent, name_b)
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent_b, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(agent_b, workspace)

    # Caller manages A (NOT B). The dispatch lands on A (A's manage-cap gate
    # passes) but names B as the subject.
    manager = grant_manage_cap(agent_a, workspace)
    turn_id = "t-deputy-#{System.unique_integer([:positive])}"

    assert :none = ConfigStore.current_user_object(agent_b, @cascade_key)

    assert {:error, :subject_not_self} =
             apply_delta_with(agent_a, manager, turn_id, %{
               subject_uri: agent_b,
               patch: %{"tone" => "hijacked"}
             })

    # B's config was NOT mutated, and no object was minted for it.
    assert :none = ConfigStore.current_user_object(agent_b, @cascade_key)
    refute ConfigStore.applied_for_turn?(turn_id)
  end

  test "apply_config_delta accepts a subject_uri that matches self (CE-1 positive)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-self-#{System.unique_integer([:positive])}"

    assert {:ok, %{config_id: cid}} =
             apply_delta_with(agent, manager, turn_id, %{
               subject_uri: agent,
               patch: %{"tone" => "decisive"}
             })

    assert {:ok, ^cid} = ConfigStore.current_user_object(agent, @cascade_key)
  end

  # ---- CE-2 idempotency (no new object on replay of a settled turn) --------

  test "re-dispatching the same turn_id after a successful apply mints NO new object (CE-2)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-idem-#{System.unique_integer([:positive])}"

    {:ok, %{config_id: cid1}} = apply_delta(agent, manager, turn_id, %{"tone" => "v1"})
    count_after_first = config_object_count()

    # Re-dispatch the SAME turn_id (a settlement replay). It must return the
    # original config_id and NOT mint a second object.
    {:ok, %{config_id: cid2}} = apply_delta(agent, manager, turn_id, %{"tone" => "v2"})

    assert cid2 == cid1
    assert config_object_count() == count_after_first
    assert {:ok, ^cid1} = ConfigStore.current_user_object(agent, @cascade_key)
  end

  # ---- PR-6 ITEM 1 — superseded turn STAYS applied (object-existence) ------

  # The PR-5 pointer-aware `applied_for_turn?/1` regressed: applying turn B on
  # top of turn A (same agent/layer/key) advanced the pointer off A's object,
  # so `applied_for_turn?("A")` flipped back to FALSE — recovery would REPLAY
  # an already-applied, merely-superseded turn (a lost-then-double-applied
  # update). Because `write_and_point/1` is atomic (no orphan object can
  # exist), "an object for turn T exists" ⟺ "turn T was applied", so the check
  # is reverted to OBJECT-EXISTENCE: a superseded turn is STILL applied.
  test "a superseded turn is STILL applied_for_turn? (object-existence — no replay) (PR-6)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_a = "t-supersede-A-#{System.unique_integer([:positive])}"
    turn_b = "t-supersede-B-#{System.unique_integer([:positive])}"

    {:ok, %{config_id: cid_a}} = apply_delta(agent, manager, turn_a, %{"tone" => "A"})
    assert ConfigStore.applied_for_turn?(turn_a)

    # Apply turn B to the SAME agent/layer/key → pointer advances off A onto B.
    {:ok, %{config_id: cid_b}} = apply_delta(agent, manager, turn_b, %{"tone" => "B"})
    assert cid_b != cid_a
    assert {:ok, ^cid_b} = ConfigStore.current_user_object(agent, @cascade_key)

    # A was applied (even though superseded) → recovery must NOT replay it.
    assert ConfigStore.applied_for_turn?(turn_a),
           "superseded turn A wrongly reported as NOT applied — recovery would replay an applied turn"

    assert ConfigStore.applied_for_turn?(turn_b)
  end

  # ---- CE-3 atomicity keeps the lost-update class closed ------------------

  # `write_and_point/1` writes the object AND advances the pointer in ONE
  # Repo.transaction, so a partial write (object without pointer = an orphan)
  # is impossible. ITEM 1: prove the do_apply handler routes through the
  # atomic `write_and_point/1` and never calls the object-only `write_config/1`
  # separately (which would re-open the orphan window object-existence relies
  # on being closed).
  test "do_apply uses the atomic write_and_point, not a separate object write (CE-3)" do
    source = File.read!("lib/ezagent/behavior/config_evolve.ex")

    do_apply =
      source
      |> String.split("defp do_apply_config_delta(")
      |> Enum.at(1)
      |> String.split("\n  defp ", parts: 2)
      |> List.first()

    assert do_apply =~ "ConfigStore.write_and_point(",
           "do_apply_config_delta must persist via the atomic write_and_point/1"

    refute do_apply =~ "ConfigStore.write_config(",
           "do_apply_config_delta must NOT call the non-atomic object-only write_config/1 " <>
             "(that re-opens the orphan window object-existence assumes closed)"
  end

  # A genuinely-interrupted apply (the atomic transaction never committed)
  # leaves NEITHER object NOR pointer, so `applied_for_turn?` is false and
  # recovery correctly replays.
  test "an aborted write_and_point leaves no object and is NOT applied_for_turn? (CE-3)",
       %{agent: agent, workspace: workspace} do
    turn_id = "t-aborted-#{System.unique_integer([:positive])}"
    before = config_object_count()

    # No write happened (the apply was interrupted before write_and_point).
    refute ConfigStore.applied_for_turn?(turn_id)
    assert config_object_count() == before

    # And a fresh, complete apply for the same turn then succeeds (replay).
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{config_id: cid}} = apply_delta(agent, manager, turn_id, %{"tone" => "recovered"})
    assert ConfigStore.applied_for_turn?(turn_id)
    assert {:ok, ^cid} = ConfigStore.current_user_object(agent, @cascade_key)
  end

  # ---- CE-2 concurrent duplicate dispatch — DB unique constraint -----------

  # The handler's serial early-return (pointer_object_for_turn /
  # applied_for_turn?) only catches RE-dispatch after the first apply
  # committed. Two CONCURRENT dispatches can both observe "not applied" and
  # both reach write_and_point. A partial unique index on
  # (workspace_uri, subject_uri, key, source_turn_id) makes the DB reject the
  # second object so only one delta per turn ever lands. This test asserts the
  # constraint exists by inserting two objects with the same identifying
  # tuple — the second must be rejected (changeset error, not a raw raise).
  test "two ConfigObjects with the same (workspace,subject,key,source_turn_id) are rejected (CE-2)",
       %{agent: agent, workspace: workspace} do
    turn_id = "t-dup-#{System.unique_integer([:positive])}"

    # PR-7 — `ConfigStore.write_config/1` (the public object-only insert) was
    # removed (the only public durable-write path is now the atomic
    # `write_and_point/1`). This test genuinely needs to drive the OBJECT-level
    # unique index directly (object without pointer), so it inserts via the
    # `ConfigObject` schema changeset — the clearly-named test-only seam. (No
    # production code can mint an orphan object.)
    object_attrs = fn ->
      %{
        id: Ecto.UUID.generate(),
        workspace_uri: URI.to_string(workspace),
        subject_uri: URI.to_string(agent),
        key: @cascade_key,
        body: %{"tone" => "x"},
        created_by: URI.to_string(agent),
        source_turn_id: turn_id
      }
    end

    insert_object = fn ->
      object_attrs.() |> ConfigObject.changeset() |> EzagentCore.Repo.insert()
    end

    assert {:ok, _first} = insert_object.()

    assert {:error, %Ecto.Changeset{} = changeset} = insert_object.()

    assert {"already applied for this turn", _} =
             changeset.errors[:source_turn_id] || changeset.errors[:id],
           "second object for the same turn was not rejected by the unique constraint: " <>
             inspect(changeset.errors)
  end

  # The handler turns a concurrent-loss constraint collision into an
  # idempotent success (it returns the already-applied object id), never a
  # crash. We drive this through the public apply path: the SECOND apply of the
  # same turn returns the first object id with no new object (the serial gate
  # OR the constraint handling both land here).
  test "concurrent-style re-apply of a turn returns the existing object, no crash (CE-2)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-conc-#{System.unique_integer([:positive])}"

    {:ok, %{config_id: cid1}} = apply_delta(agent, manager, turn_id, %{"tone" => "v1"})
    count = config_object_count()

    {:ok, %{config_id: cid2}} = apply_delta(agent, manager, turn_id, %{"tone" => "v2"})

    assert cid2 == cid1
    assert config_object_count() == count
  end

  # ---- PR-6 ITEM 3 — idempotent re-apply REFRESHES a stale sandbox ---------

  # The already-applied early-return used to emit `[]` effects, so a redelivery
  # after a lost step-2 (deferred sandbox.update_config) left the Sandbox cache
  # stale until the next boot reconcile. ITEM 3: the idempotent path must emit
  # the SAME sandbox projection (computed from the CURRENT pointer) so a
  # redelivery self-heals the cache — WITHOUT minting a new object.
  test "re-applying an already-applied turn refreshes a stale sandbox cache, mints no object (PR-6)",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    manager = grant_manage_cap(agent, workspace)
    turn_id = "t-stale-#{System.unique_integer([:positive])}"

    {:ok, %{config_id: cid}} = apply_delta(agent, manager, turn_id, %{"tone" => "decisive"})
    want = URI.to_string(ConfigProjection.object_uri(workspace, cid))
    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want end)

    # Simulate a lost step-2 / stale cache AFTER the durable apply.
    force_sandbox_user_layer(agent, workspace, "stale://layer")
    assert sandbox_user_layer_uri(agent) == "stale://layer"

    count = config_object_count()

    # Re-dispatch the SAME turn (settlement redelivery). It must NOT mint a new
    # object, but it MUST re-emit the sandbox projection that refreshes the
    # cache back to the durable pointer.
    {:ok, %{config_id: cid2}} = apply_delta(agent, manager, turn_id, %{"tone" => "ignored"})
    assert cid2 == cid
    assert config_object_count() == count

    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want end),
           "idempotent re-apply did NOT refresh the stale sandbox cache (got " <>
             "#{inspect(sandbox_user_layer_uri(agent))}, want #{want})"
  end

  # ---- PR-7 — redelivery of a SUPERSEDED turn (object-existence idempotency) -

  # The MED blocker: handler idempotency was POINTER-aware
  # (`pointer_object_for_turn`), inconsistent with the object-existence
  # `applied_for_turn?/1`. When turn A is superseded by turn B, a REDELIVERY of
  # A found `pointer_object_for_turn(A) == :none` (the pointer is now B), so it
  # proceeded to `write_and_point`, hit the unique index, and the conflict path
  # returned `%{config_id: nil}` + `[]` — violating the `config_id: :string`
  # contract and skipping the sandbox refresh.
  #
  # PR-7 makes the pre-check OBJECT-EXISTENCE-consistent: A's historical object
  # still exists, so redelivering A returns A's object id (a string) WITHOUT
  # minting/repointing, and the sandbox refresh targets the CURRENT pointer (B)
  # — so redelivering a superseded turn does NOT revert the cache to A.
  test "redelivery of a SUPERSEDED turn returns its historical config_id (string) and does NOT revert the pointer/sandbox (PR-7)",
       %{agent: agent, workspace: workspace} do
    seed_sandbox_cascade(agent, workspace)
    manager = grant_manage_cap(agent, workspace)
    turn_a = "t-sup-redeliver-A-#{System.unique_integer([:positive])}"
    turn_b = "t-sup-redeliver-B-#{System.unique_integer([:positive])}"

    {:ok, %{config_id: cid_a}} = apply_delta(agent, manager, turn_a, %{"tone" => "A"})
    {:ok, %{config_id: cid_b}} = apply_delta(agent, manager, turn_b, %{"tone" => "B"})
    assert cid_b != cid_a
    assert {:ok, ^cid_b} = ConfigStore.current_user_object(agent, @cascade_key)

    want_b = URI.to_string(ConfigProjection.object_uri(workspace, cid_b))
    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want_b end)

    count = config_object_count()

    # Redeliver the SUPERSEDED turn A. It must return A's HISTORICAL object id
    # (a string, NOT nil), mint no new object, and leave the pointer on B.
    {:ok, reply} = apply_delta(agent, manager, turn_a, %{"tone" => "ignored"})
    assert is_binary(reply.config_id)
    assert reply.config_id == cid_a
    assert config_object_count() == count
    assert {:ok, ^cid_b} = ConfigStore.current_user_object(agent, @cascade_key)

    # The sandbox refresh on the idempotent path targets the CURRENT pointer (B),
    # NOT the redelivered superseded turn A — it never reverts to A.
    want_a = URI.to_string(ConfigProjection.object_uri(workspace, cid_a))
    assert sandbox_user_layer_uri(agent) != want_a

    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want_b end),
           "idempotent redelivery of superseded turn A reverted/failed to keep the sandbox on B " <>
             "(got #{inspect(sandbox_user_layer_uri(agent))}, want #{want_b})"
  end

  # ========================================================================
  # Fixtures / helpers (ported from config_update_test.exs)
  # ========================================================================

  defp config_object_count do
    EzagentCore.Repo.aggregate(Ezagent.Socialware.ConfigObject, :count, :id)
  end

  # apply_config_delta carrying explicit delta fields (subject_uri etc.) in
  # args — used by the CE-1 confused-deputy + positive self tests.
  defp apply_delta_with(agent, manager, turn_id, fields) do
    %Invocation{
      origin: :trusted_internal,
      target: action_uri(agent, :apply_config_delta),
      mode: :call,
      args: Map.put(fields, :turn_id, turn_id),
      ctx: %{caller: manager.uri, caps: manager.caps, reply: {:caller_inbox, self()}}
    }
    |> signed_invocation!(:agent)
    |> Invocation.dispatch()
  end

  defp action_uri(agent, action) do
    Ezagent.URI.new!("#{URI.to_string(agent)}?action=config_evolve.#{action}")
  end

  # Mint the agent's manage-cap to a fresh manager principal and return
  # `%{uri, caps}` (the caps that authorize step-1 apply/repoint).
  defp grant_manage_cap(agent, workspace) do
    manager = Ezagent.URI.entity(:team_alpha, :user, "mgr-#{System.unique_integer([:positive])}")
    cap = CreatorGrant.manage_cap(:agent, agent, workspace, manager)

    ctx = signed_ctx!(agent, %{caller: manager, caps: MapSet.new([cap])}, :agent)
    %{uri: manager, caps: ctx.caps}
  end

  # Dispatch step-1 apply carrying the delta in args (the agent has no turn
  # slice — PR-3's Turn rewire forwards the settled delta's fields the same
  # way). `subject_uri`/`workspace_uri`/`key`/`layer` default to the agent's
  # own user layer.
  defp apply_delta(agent, manager, turn_id, patch) do
    %Invocation{
      origin: :trusted_internal,
      target: action_uri(agent, :apply_config_delta),
      mode: :call,
      args: %{turn_id: turn_id, patch: patch},
      ctx: %{caller: manager.uri, caps: manager.caps, reply: {:caller_inbox, self()}}
    }
    |> signed_invocation!(:agent)
    |> Invocation.dispatch()
  end

  # Seed the agent's sandbox with a cascade_resolution (the shape #17 stores
  # at create) so the step-2 projection has a cache to refresh.
  defp seed_sandbox_cascade(agent, workspace) do
    write_sandbox(agent, %{
      "flavor" => "cc",
      "cascade_resolution" => %{
        "owner_uri" => URI.to_string(User.admin_uri()),
        "workspace_uri" => URI.to_string(workspace),
        "user_layer_uri" => URI.to_string(User.admin_uri())
      }
    })
  end

  defp force_sandbox_user_layer(agent, workspace, layer_uri) do
    write_sandbox(agent, %{
      "flavor" => "cc",
      "cascade_resolution" => %{
        "owner_uri" => URI.to_string(User.admin_uri()),
        "workspace_uri" => URI.to_string(workspace),
        "user_layer_uri" => layer_uri
      }
    })
  end

  defp write_sandbox(agent, respawn_template_data) do
    {:ok, _} =
      %Invocation{
        origin: :trusted_internal,
        target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.update_config"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-ce-#{System.unique_integer([:positive])}",
          template_class: nil,
          respawn_template_data: respawn_template_data
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      }
      |> signed_invocation!(:agent)
      |> Invocation.dispatch()

    :ok
  end

  defp sandbox_user_layer_uri(agent) do
    {:ok, sandbox} =
      %Invocation{
        origin: :trusted_internal,
        target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.read"),
        mode: :call,
        args: %{},
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      }
      |> signed_invocation!(:agent)
      |> Invocation.dispatch()

    resolution =
      case Map.get(sandbox, :respawn_template_data) do
        %{} = rtd -> rtd["cascade_resolution"] || rtd[:cascade_resolution]
        _ -> nil
      end

    case resolution do
      %{} = res -> res["user_layer_uri"] || res[:user_layer_uri]
      _ -> nil
    end
  end

  defp restart_agent(agent) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(agent)

    :ok =
      DynamicSupervisor.terminate_child(
        EzagentDomainInstanceMessage.AgentSupervisor,
        pid
      )

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent})
    :ok
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
