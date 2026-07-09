defmodule Ezagent.ActionSet.ConfigGovernanceTest do
  @moduledoc """
  Minimal CR (change-request) config governance (SPEC
  `docs/together/2026-06-26/specs/cr-config-governance.md`, rev 3 §9 test plan).

  Drives `Ezagent.ActionSet.ConfigGovernance` in isolation by dispatching the CR
  actions to a spawned Agent Kind, mirroring `config_evolve_test.exs`. Covers the
  lifecycle round-trip (stage → preview → publish → rollback), publish
  idempotency (status-gated), reserved-prefix guard, scope guard, base-drift,
  manage-cap gate, CE-1 self-binding, one-open-CR-per-subject, reject-is-free,
  and the sandbox materialization on publish.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{CreatorGrant, Invocation}
  alias Ezagent.Entity.{Agent, User}
  alias Ezagent.Socialware.{ConfigObject, ConfigProjection, ConfigStore}

  @cascade_key "agent.soul"

  setup do
    name = "cg-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    workspace = Ezagent.Capability.workspace_of(agent)

    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(agent, workspace)

    %{agent: agent, workspace: workspace}
  end

  # ---- §9.11 one active CR per subject + §9.9 manage-cap gate (open) --------

  test "open_cr requires the agent's manage-cap (stranger denied)", %{agent: agent} do
    assert {:error, :unauthorized} =
             dispatch(agent, :open_cr, %{}, stranger())
  end

  test "open_cr succeeds for a manage-cap holder; a SECOND open CR is rejected (one active per subject)",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)

    assert {:ok, %{cr_id: _cr_id, status: "open"}} = dispatch(agent, :open_cr, %{}, manager)

    assert {:error, reason} = dispatch(agent, :open_cr, %{}, manager)
    assert match?(%Ecto.Changeset{}, reason) or match?({:cr_status, _}, reason)
  end

  # ---- §9.1 stage writes an inert object (no pointer moved) -----------------

  test "stage_item writes an immutable object but moves NO pointer", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    assert {:ok, %{staged_object_id: oid}} =
             dispatch(
               agent,
               :stage_item,
               %{change_request_id: cr_id, patch: %{"tone" => "bold"}},
               manager
             )

    # Object exists...
    assert {:ok, _object} = ConfigStore.fetch_object(oid)
    # ...but the slot's resolve/4 is UNCHANGED (no pointer moved).
    assert :none = ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §9.2 idempotency namespace fence ------------------------------------

  test "a staged object's source_turn_id is cr-stage: and does NOT pollute real-turn idempotency",
       ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: oid}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, patch: %{"tone" => "bold"}},
        manager
      )

    {:ok, object} = ConfigStore.fetch_object(oid)
    assert String.starts_with?(object.source_turn_id, "cr-stage:")

    # A real turn id is unaffected by the staged object.
    refute ConfigStore.applied_for_turn?("real-turn-xyz")
    assert :none = ConfigStore.object_for_turn("real-turn-xyz")
  end

  # ---- §9.3 reserved-prefix guard (non-CR write entry) ---------------------

  test "ConfigEvolve.apply_config_delta REJECTS a caller-supplied cr-stage:/cr-publish: turn_id",
       %{agent: agent, workspace: workspace} do
    manager = grant_manage_cap(agent, workspace)

    for bad <- ["cr-stage:abc:def", "cr-publish:abc"] do
      assert {:error, {:reserved_turn_id_prefix, ^bad}} =
               Invocation.dispatch(%Invocation{
                 target: ce_action_uri(agent, :apply_config_delta),
                 mode: :call,
                 args: %{turn_id: bad, patch: %{"tone" => "spoof"}},
                 ctx: %{caller: manager.uri, caps: manager.caps, reply: {:caller_inbox, self()}}
               })

      # Nothing applied — the guard fired BEFORE any object-existence early-return.
      refute ConfigStore.applied_for_turn?(bad)
    end
  end

  test "Agent.Config.apply_delta REJECTS a caller-supplied reserved turn_id", %{
    agent: agent,
    workspace: workspace
  } do
    manager = grant_manage_cap(agent, workspace)

    assert {:error, {:reserved_turn_id_prefix, "cr-stage:x"}} =
             Ezagent.Agent.Config.apply_delta(agent, manager.uri, manager.caps, %{
               turn_id: "cr-stage:x",
               patch: %{"tone" => "spoof"}
             })
  end

  test "ConfigStore.write_object_staged rejects a non cr-stage: turn_id", %{
    agent: agent,
    workspace: workspace
  } do
    assert {:error, {:not_cr_stage_turn_id, _}} =
             ConfigStore.write_object_staged(%{
               workspace_uri: workspace,
               subject_uri: agent,
               key: @cascade_key,
               body: %{"tone" => "x"},
               actor_uri: agent,
               source_turn_id: "real-turn"
             })
  end

  # ---- §9.4 publish flips pointers + records published_prev_object_id ------

  test "publish_cr flips the staged pointer; the slot resolves to the staged object", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: oid}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, patch: %{"tone" => "bold"}},
        manager
      )

    assert {:ok, %{status: "published"}} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    assert {:ok, %ConfigObject{id: ^oid}} =
             ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §4.3.1 multi-slot publish (the headline feature: N deltas, one unit) -

  test "publish_cr flips MULTIPLE staged slots in one unit; both resolve + record prev", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)

    # Establish a prior object on the second key so its published_prev is non-nil.
    {:ok, %{config_id: prior_b}} =
      Ezagent.Agent.Config.apply_delta(agent, manager.uri, manager.caps, %{
        key: "behavior.b",
        patch: %{"v" => 1}
      })

    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: oid_a}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, key: @cascade_key, patch: %{"tone" => "bold"}},
        manager
      )

    {:ok, %{staged_object_id: oid_b}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, key: "behavior.b", patch: %{"v" => 2}},
        manager
      )

    assert oid_a != oid_b

    assert {:ok, %{status: "published"}} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    # BOTH slots flipped to their staged objects (one-unit publish).
    assert {:ok, %ConfigObject{id: ^oid_a}} =
             ConfigStore.resolve(:user, workspace, agent, @cascade_key)

    assert {:ok, %ConfigObject{id: ^oid_b}} =
             ConfigStore.resolve(:user, workspace, agent, "behavior.b")

    # Both items recorded published_prev_object_id (key A had none → nil; key B
    # had a prior → prior_b).
    items = Ezagent.ConfigGovernance.Store.items(cr_id)
    prevs = Map.new(items, &{&1.key, &1.published_prev_object_id})
    assert prevs[@cascade_key] == nil
    assert prevs["behavior.b"] == prior_b
  end

  test "multi-slot publish is all-or-nothing: if the 2nd slot drifts, the 1st is NOT flipped",
       ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)

    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: _oid_a}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, key: @cascade_key, patch: %{"tone" => "bold"}},
        manager
      )

    {:ok, %{staged_object_id: _oid_b}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, key: "behavior.b", patch: %{"v" => 1}},
        manager
      )

    # Drift ONLY the second slot's base AFTER staging (apply to behavior.b).
    {:ok, _} =
      Ezagent.Agent.Config.apply_delta(agent, manager.uri, manager.caps, %{
        key: "behavior.b",
        patch: %{"v" => 99}
      })

    assert {:error, {:cr_base_drift, _}} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    # The FIRST slot (key A) must NOT have been flipped — the whole Multi rolled
    # back (cross-item atomicity, §4.3.1).
    assert :none = ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §4.5 multi-slot rollback (reuses ConfigEvolve.repoint_config) --------

  test "rollback_cr reverts EVERY published slot to its prior object", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)

    {:ok, %{config_id: prior_a}} =
      Ezagent.Agent.Config.apply_delta(agent, manager.uri, manager.caps, %{
        key: @cascade_key,
        patch: %{"x" => 1}
      })

    {:ok, %{config_id: prior_b}} =
      Ezagent.Agent.Config.apply_delta(agent, manager.uri, manager.caps, %{
        key: "behavior.b",
        patch: %{"y" => 1}
      })

    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, _} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, key: @cascade_key, patch: %{"x" => 2}},
        manager
      )

    {:ok, _} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, key: "behavior.b", patch: %{"y" => 2}},
        manager
      )

    {:ok, %{status: "published"}} =
      dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    assert {:ok, %{status: "rolled_back"}} =
             dispatch(agent, :rollback_cr, %{change_request_id: cr_id}, manager)

    assert {:ok, %ConfigObject{id: ^prior_a}} =
             ConfigStore.resolve(:user, workspace, agent, @cascade_key)

    assert {:ok, %ConfigObject{id: ^prior_b}} =
             ConfigStore.resolve(:user, workspace, agent, "behavior.b")
  end

  # ---- §9.5 publish idempotency is STATUS-gated ----------------------------

  test "re-publish on a published CR is rejected (status gate), no second flip", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, _} =
      dispatch(agent, :stage_item, %{change_request_id: cr_id, patch: %{"a" => 1}}, manager)

    {:ok, %{status: "published"}} =
      dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    assert {:error, {:cr_status, %{want: "open", got: "published"}}} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)
  end

  # ---- §9.6 publish scope guard (fetch_matching_object) --------------------

  test "publish rejects a staged item whose object belongs to another subject; nothing flips",
       ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: oid}} =
      dispatch(agent, :stage_item, %{change_request_id: cr_id, patch: %{"a" => 1}}, manager)

    # Tamper: rewrite the staged item to point at a FOREIGN object (another
    # subject). The publish scope guard (fetch_matching_object) must reject it.
    other =
      Ezagent.URI.entity(:team_alpha, :agent, "foreign-#{System.unique_integer([:positive])}")

    {:ok, foreign} =
      %{
        id: Ecto.UUID.generate(),
        workspace_uri: URI.to_string(workspace),
        subject_uri: URI.to_string(other),
        key: @cascade_key,
        body: %{"x" => 1},
        created_by: URI.to_string(other),
        source_turn_id: "cr-stage:#{cr_id}:foreign"
      }
      |> ConfigObject.changeset()
      |> EzagentCore.Repo.insert()

    EzagentCore.Repo.update_all(
      Ecto.Query.from(i in Ezagent.Socialware.ConfigChangeItem,
        where: i.staged_object_id == ^oid
      ),
      set: [staged_object_id: foreign.id]
    )

    assert {:error, {:cross_tenant_target, _}} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    assert :none = ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §9.7 base-drift conflict --------------------------------------------

  test "publish aborts with cr_base_drift if live config moved under the open CR; nothing flips",
       ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    # base = empty (no pointer yet). Stage records base_object_id = nil.
    {:ok, _} =
      dispatch(agent, :stage_item, %{change_request_id: cr_id, patch: %{"a" => 1}}, manager)

    # Now move the live config underneath the CR (a normal apply).
    {:ok, %{config_id: drift_cid}} =
      Ezagent.Agent.Config.apply_delta(agent, manager.uri, manager.caps, %{patch: %{"b" => 2}})

    assert {:ok, %ConfigObject{id: ^drift_cid}} =
             ConfigStore.resolve(:user, workspace, agent, @cascade_key)

    assert {:error, {:cr_base_drift, _}} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    # The slot still resolves to the drift object — the staged flip never landed.
    assert {:ok, %ConfigObject{id: ^drift_cid}} =
             ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §9.8 rollback = repoint prior ---------------------------------------

  test "rollback_cr repoints the slot back to published_prev_object_id", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)

    # Establish a prior live object so the rollback target is non-nil.
    {:ok, %{config_id: prior_cid}} =
      Ezagent.Agent.Config.apply_delta(agent, manager.uri, manager.caps, %{patch: %{"v" => 1}})

    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: new_oid}} =
      dispatch(agent, :stage_item, %{change_request_id: cr_id, patch: %{"v" => 2}}, manager)

    {:ok, %{status: "published"}} =
      dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    assert {:ok, %ConfigObject{id: ^new_oid}} =
             ConfigStore.resolve(:user, workspace, agent, @cascade_key)

    assert {:ok, %{status: "rolled_back"}} =
             dispatch(agent, :rollback_cr, %{change_request_id: cr_id}, manager)

    assert {:ok, %ConfigObject{id: ^prior_cid}} =
             ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §9.9 cap = manage cap (publish gated) -------------------------------

  test "publish_cr is denied without the agent's manage-cap", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, _} =
      dispatch(agent, :stage_item, %{change_request_id: cr_id, patch: %{"a" => 1}}, manager)

    assert {:error, :unauthorized} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, stranger())
  end

  # ---- §9.10 CE-1 self-binding ---------------------------------------------

  test "a CR whose subject is agent B cannot be published by dispatching to agent A (CE-1)",
       ctx do
    %{agent: agent_a, workspace: workspace} = ctx

    name_b = "cg-victim-#{System.unique_integer([:positive])}"
    agent_b = Ezagent.URI.entity(:team_alpha, :agent, name_b)
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent_b, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(agent_b, workspace)

    mgr_b = grant_manage_cap(agent_b, workspace)
    {:ok, %{cr_id: cr_b}} = dispatch(agent_b, :open_cr, %{}, mgr_b)

    {:ok, _} =
      dispatch(agent_b, :stage_item, %{change_request_id: cr_b, patch: %{"a" => 1}}, mgr_b)

    # Caller manages A; dispatch B's CR id TO agent A. A's gate passes (mgr_a) but
    # the CR subject is B → :subject_not_self.
    mgr_a = grant_manage_cap(agent_a, workspace)

    assert {:error, :subject_not_self} =
             dispatch(agent_a, :publish_cr, %{change_request_id: cr_b}, mgr_a)

    # B's config is untouched.
    assert :none = ConfigStore.resolve(:user, workspace, agent_b, @cascade_key)
  end

  # ---- §9.12 reject is free ------------------------------------------------

  test "reject_cr from open leaves resolve/4 unchanged", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, _} =
      dispatch(agent, :stage_item, %{change_request_id: cr_id, patch: %{"a" => 1}}, manager)

    assert {:ok, %{status: "rejected"}} =
             dispatch(agent, :reject_cr, %{change_request_id: cr_id}, manager)

    assert :none = ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §9.13 sandbox materialization on publish ----------------------------

  test "publish_cr refreshes the sandbox cascade_resolution.user_layer_uri to the published object",
       ctx do
    %{agent: agent, workspace: workspace} = ctx
    seed_sandbox_cascade(agent, workspace)
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: oid}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, patch: %{"tone" => "bold"}},
        manager
      )

    {:ok, %{status: "published"}} =
      dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    want = URI.to_string(ConfigProjection.object_uri(workspace, oid))

    assert wait_until(fn -> sandbox_user_layer_uri(agent) == want end),
           "publish_cr never materialized user_layer_uri to #{want}; got #{inspect(sandbox_user_layer_uri(agent))}"
  end

  # ---- LOW-1: non-user-layer materialization (pins the user-layer-only seam)
  #
  # Every other CR test stages at the :user layer. This pins the behavior for a
  # NON-user layer (:workspace). Two distinct seams behave differently by layer:
  #
  #   1. The POINTER FLIP is layer-correct — `flip_item` passes `layer:
  #      item.layer` to `put_pointer`, so the :workspace slot resolves to the
  #      staged object after publish.
  #   2. The SANDBOX MATERIALIZATION is USER-LAYER-ONLY — the reuse seam
  #      (`ConfigEvolve.sandbox_refresh_effects` → `ConfigStore.current_user_object`,
  #      which calls `resolve(:user, ...)`) reads the USER cascade layer
  #      regardless of the published item's layer. With no user-layer pointer for
  #      the key, that read is `:none`, the effect list is empty, and the sandbox
  #      cache's `user_layer_uri` is left UNCHANGED — a pure workspace-layer
  #      publish does NOT project into the sandbox cascade cache.
  #
  # This is the intended v1 behavior (the sandbox mirrors only the user cascade
  # layer); asserted explicitly here so the seam's layer scope is PINNED, not
  # silently wrong.
  test "publish_cr at the :workspace layer flips the workspace pointer but does NOT materialize the sandbox (user-layer-only seam)",
       ctx do
    %{agent: agent, workspace: workspace} = ctx
    seed_sandbox_cascade(agent, workspace)
    baseline_user_layer = sandbox_user_layer_uri(agent)
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, %{staged_object_id: oid}} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, layer: :workspace, patch: %{"tone" => "bold"}},
        manager
      )

    assert {:ok, %{status: "published"}} =
             dispatch(agent, :publish_cr, %{change_request_id: cr_id}, manager)

    # (1) Pointer flip IS layer-correct: the :workspace slot resolves to the
    # staged object.
    assert {:ok, %ConfigObject{id: ^oid}} =
             ConfigStore.resolve(:workspace, workspace, agent, @cascade_key)

    # The :user layer was never touched (no user-layer object for this key).
    assert :none = ConfigStore.resolve(:user, workspace, agent, @cascade_key)

    # (2) Materialization is USER-LAYER-ONLY: no user-layer pointer ⇒ the seam
    # emits no sandbox.update_config, so the cache's user_layer_uri stays at its
    # seed. Sleep to give any (erroneous) async update_config effect time to land —
    # the assertion would catch a regression where a workspace publish starts
    # projecting into the sandbox cache.
    Process.sleep(100)
    assert sandbox_user_layer_uri(agent) == baseline_user_layer

    # And the baseline is the seeded user-layer uri (NOT the workspace-staged
    # object), proving the workspace publish did not overwrite it.
    assert baseline_user_layer == URI.to_string(User.admin_uri())
  end

  # ---- §9.14 preview is a pure, deterministic read -------------------------

  test "preview_cr changes nothing and is byte-identical across calls", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, _} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: cr_id, replace_body: %{"soul_md" => "Be bold."}},
        manager
      )

    {:ok, %{items: items1}} = dispatch(agent, :preview_cr, %{change_request_id: cr_id}, manager)
    {:ok, %{items: items2}} = dispatch(agent, :preview_cr, %{change_request_id: cr_id}, manager)

    assert items1 == items2

    assert [
             %{
               proposed_soul: "Be bold.",
               current_body: %{},
               proposed_body: %{"soul_md" => "Be bold."}
             }
           ] =
             items1

    # Pure read — no pointer moved.
    assert :none = ConfigStore.resolve(:user, workspace, agent, @cascade_key)
  end

  # ---- §9.15 v1 agent-subject only -----------------------------------------
  #
  # The behavior lives ONLY on the Agent Kind and self-binds the subject to the
  # dispatched-to agent, so a non-agent subject is structurally impossible to
  # reach via dispatch. The store's open/0 accepts any subject_uri; the behavior
  # is the agent-subject fence. We assert the handler's agent-subject guard.

  test "open_cr self-binds to the agent subject (agent-subject only, v1)", ctx do
    %{agent: agent, workspace: workspace} = ctx
    manager = grant_manage_cap(agent, workspace)

    {:ok, %{cr_id: cr_id}} = dispatch(agent, :open_cr, %{}, manager)
    {:ok, cr} = Ezagent.ConfigGovernance.Store.fetch(cr_id)
    assert cr.subject_uri == URI.to_string(agent)
  end

  # ========================================================================
  # Helpers
  # ========================================================================

  defp dispatch(agent, action, args, principal) do
    Invocation.dispatch(%Invocation{
      target: cg_action_uri(agent, action),
      mode: :call,
      args: args,
      ctx: %{caller: principal.uri, caps: principal.caps, reply: {:caller_inbox, self()}}
    })
  end

  defp cg_action_uri(agent, action) do
    Ezagent.URI.new!("#{URI.to_string(agent)}?action=config_governance.#{action}")
  end

  defp ce_action_uri(agent, action) do
    Ezagent.URI.new!("#{URI.to_string(agent)}?action=config_evolve.#{action}")
  end

  defp grant_manage_cap(agent, workspace) do
    manager = Ezagent.URI.entity(:team_alpha, :user, "mgr-#{System.unique_integer([:positive])}")
    cap = CreatorGrant.manage_cap(:agent, agent, workspace, manager)
    %{uri: manager, caps: MapSet.new([cap])}
  end

  defp stranger do
    %{uri: Ezagent.URI.entity(:team_alpha, :user, "stranger"), caps: MapSet.new()}
  end

  defp seed_sandbox_cascade(agent, workspace) do
    {:ok, _} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.update_config"),
        mode: :call,
        args: %{
          config_dir_path: "/tmp/agent-cg-#{System.unique_integer([:positive])}",
          template_class: nil,
          respawn_template_data: %{
            "flavor" => "cc",
            "cascade_resolution" => %{
              "owner_uri" => URI.to_string(User.admin_uri()),
              "workspace_uri" => URI.to_string(workspace),
              "user_layer_uri" => URI.to_string(User.admin_uri())
            }
          }
        },
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      })

    :ok
  end

  defp sandbox_user_layer_uri(agent) do
    {:ok, sandbox} =
      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=sandbox.read"),
        mode: :call,
        args: %{},
        ctx: %{
          caller: User.admin_uri(),
          caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
          reply: {:caller_inbox, self()}
        }
      })

    case Map.get(sandbox, :respawn_template_data) do
      %{} = rtd ->
        case rtd["cascade_resolution"] || rtd[:cascade_resolution] do
          %{} = res -> res["user_layer_uri"] || res[:user_layer_uri]
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          wait_until(fun, attempts - 1)
        )
  end
end
