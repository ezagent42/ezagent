defmodule Ezagent.ActionSet.RemoveParticipantTest do
  @moduledoc """
  F7 PR-A — `session.remove_participant` (the isomorphic Session primitive),
  NON-spawned slice only. Direct handler invoke tests (no live dispatch
  chokepoint) using `BehaviorInvoker`, so the handler's own authorization gate
  + provenance branch are exercised in isolation.

  Spec: docs/together/2026-06-27/specs/f7-operator-remove-delete-session.md
  §3.2 / §3.3 / §5.1. PR-A lands the membership-only LEAVE for USER + INVITED
  (non-spawned) participants; the spawned-agent worker-teardown branch is a
  documented PR-B stub.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

  setup do
    :ok = EzagentDomainInstanceMessage.AgentBridgeTestAdapter.ensure_registered()
    :ok
  end

  defp bind_to_default(session_uri) do
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://team-alpha"))
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    :ok
  end

  defp session_uri(prefix),
    do: Ezagent.URI.new!("session://team-alpha/default/#{prefix}-#{uniq()}")

  defp user_uri(prefix),
    do: Ezagent.URI.new!("entity://team-alpha/user/#{prefix}-#{uniq()}")

  defp agent_uri(prefix),
    do: Ezagent.URI.new!("entity://team-alpha/agent/#{prefix}-#{uniq()}")

  defp uniq, do: System.unique_integer([:positive])

  # A members slice with `member` (USER, no spawn facet) + `owner` both present.
  defp slice_with_user(owner, member, member_meta \\ %{online: true}) do
    %{
      members: %{owner => %{online: true}, member => member_meta},
      owner_uri: owner,
      monitors: %{},
      last_seen: %{}
    }
  end

  defp ctx(session_uri, caller) do
    requested =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    {:ok, authority} =
      Ezagent.Cap.Authority.open(Ezagent.URI.instance(session_uri), :session, :created)

    {:ok, issued} =
      Ezagent.Cap.prepare_provenance(
        {:admin, Ezagent.Entity.User.admin_uri()},
        caller,
        requested
      )

    cap =
      Ezagent.Cap.Authority.sign(authority, %{issued | grant_id: Ecto.UUID.generate()})

    case Ezagent.KindRegistry.lookup(caller) do
      {:ok, _pid} ->
        :ok

      :error ->
        {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: caller, initial_caps: [cap]})
        on_exit(fn -> Ezagent.Kind.terminate(caller) end)
    end

    %{
      self_uri: session_uri,
      kind_module: Ezagent.Entity.Session,
      caller: caller,
      authenticated_principal: caller
    }
  end

  defp seed_member_cap(session_uri, member) do
    kind = if Ezagent.URI.type?(member, :agent), do: :agent, else: :user

    requested =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    {:ok, authority} =
      Ezagent.Cap.Authority.open(Ezagent.URI.instance(session_uri), :session, :created)

    {:ok, issued} =
      Ezagent.Cap.prepare_provenance(
        {:admin, Ezagent.Entity.User.admin_uri()},
        member,
        requested
      )

    member_cap =
      Ezagent.Cap.Authority.sign(authority, %{issued | grant_id: Ecto.UUID.generate()})

    self_license = self_license_cap!(member, kind)
    :ok = Ezagent.IdentityCaps.Store.persist(member, [self_license, member_cap])
  end

  describe "USER participant removal (the §5.1 gap this PR closes)" do
    test "owner removes a user participant → membership gone, torn_down: :membership_only" do
      session = session_uri("user-remove")
      bind_to_default(session)
      owner = user_uri("owner")
      member = user_uri("member")
      seed_member_cap(session, member)

      slice = slice_with_user(owner, member)

      assert {:ok, new_slice, result} =
               Invoker.invoke(
                 SessionBehavior,
                 :remove_participant,
                 slice,
                 %{participant: member},
                 ctx(session, owner)
               )

      refute Map.has_key?(new_slice.members, member)
      assert Map.has_key?(new_slice.members, owner)
      assert result.status == :removed
      assert result.torn_down == :membership_only
    end

    test "removing a user participant NEVER destroys the User entity (membership-only)" do
      session = session_uri("user-intact")
      bind_to_default(session)
      owner = user_uri("owner")
      member = user_uri("member")
      seed_member_cap(session, member)

      slice = slice_with_user(owner, member)

      assert {:ok, _new_slice, result, effects} =
               Invoker.invoke_with_effects(
                 SessionBehavior,
                 :remove_participant,
                 slice,
                 %{participant: member},
                 ctx(session, owner)
               )

      assert result.torn_down == :membership_only

      # No worker-teardown / sandbox.destroy / lifecycle.terminate effect — the
      # only mutations are membership-slice + the membership broadcast.
      refute Enum.any?(effects, fn
               {:dispatch, _} -> true
               _ -> false
             end)
    end
  end

  describe "INVITED (non-spawned) agent removal" do
    test "owner removes an invited agent → membership-only, agent NOT terminated" do
      session = session_uri("invited-agent")
      bind_to_default(session)
      owner = user_uri("owner")
      agent = agent_uri("invited")
      seed_member_cap(session, agent)

      # Invited agent: a member with NO :source_template_uri facet.
      slice = slice_with_user(owner, agent, %{online: true})

      assert {:ok, new_slice, result, effects} =
               Invoker.invoke_with_effects(
                 SessionBehavior,
                 :remove_participant,
                 slice,
                 %{participant: agent},
                 ctx(session, owner)
               )

      refute Map.has_key?(new_slice.members, agent)
      assert result.torn_down == :membership_only

      refute Enum.any?(effects, fn
               {:dispatch, _} -> true
               _ -> false
             end)
    end
  end

  describe "owner gating" do
    test "a non-owner, non-participant caller is denied (:unauthorized)" do
      session = session_uri("gate")
      bind_to_default(session)
      owner = user_uri("owner")
      member = user_uri("member")
      stranger = user_uri("stranger")

      slice = slice_with_user(owner, member)

      assert {:error, :unauthorized} =
               Invoker.invoke(
                 SessionBehavior,
                 :remove_participant,
                 slice,
                 %{participant: member},
                 ctx(session, stranger)
               )
    end
  end

  describe "self-leave (§3.3) — same action, only own membership" do
    test "a participant removing ITSELF is authorized without the owner cap" do
      session = session_uri("self-leave")
      bind_to_default(session)
      owner = user_uri("owner")
      member = user_uri("member")

      slice = slice_with_user(owner, member)

      # caller == participant == member (NOT the owner)
      assert {:ok, new_slice, result} =
               Invoker.invoke(
                 SessionBehavior,
                 :remove_participant,
                 slice,
                 %{participant: member},
                 ctx(session, member)
               )

      refute Map.has_key?(new_slice.members, member)
      assert result.status == :removed
    end
  end

  describe "leave-FIRST convergence broadcast (§5.4)" do
    test "removal emits the {:member_left} membership broadcast (drives UI refresh)" do
      session = session_uri("broadcast")
      bind_to_default(session)
      owner = user_uri("owner")
      member = user_uri("member")
      seed_member_cap(session, member)

      slice = slice_with_user(owner, member)

      assert {:ok, _new_slice, _result, effects} =
               Invoker.invoke_with_effects(
                 SessionBehavior,
                 :remove_participant,
                 slice,
                 %{participant: member},
                 ctx(session, owner)
               )

      # The membership-changes notify carrying {:member_left, member} — the
      # surface-agnostic convergence signal world_live.ex subscribes to.
      assert Enum.any?(effects, fn
               {:notify, "esr:session_membership:changes",
                {:session_membership_change, ^session, {:member_left, ^member}}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  describe "provenance gate (F7 PR-B, SPEC §3.2 / §7) — facet AND lineage" do
    test "facet present but NOT in the owner's lineage → membership_only (never reaped)" do
      # SECURITY gate: a member carrying a `:source_template_uri` facet but NOT
      # in the owner's spawn lineage (an invited agent that happens to carry one,
      # or any agent the session did not spawn) is membership-only — the session
      # must NEVER terminate an agent it did not spawn. No `AgentLineage.record`
      # was done here, so `spawned_in_lineage?/2` is false → the worker-reap
      # branch is skipped — provable via a direct handler invoke (no live worker).
      session = session_uri("facet-no-lineage")
      bind_to_default(session)
      owner = user_uri("owner")
      worker = agent_uri("worker")
      seed_member_cap(session, worker)

      tmpl = Ezagent.URI.new!("template://team-alpha/agent/some-role")

      slice =
        slice_with_user(owner, worker, %{online: true, source_template_uri: tmpl})

      assert {:ok, new_slice, result, effects} =
               Invoker.invoke_with_effects(
                 SessionBehavior,
                 :remove_participant,
                 slice,
                 %{participant: worker},
                 ctx(session, owner)
               )

      refute Map.has_key?(new_slice.members, worker)
      assert result.torn_down == :membership_only

      # No worker reap dispatched (the reap is an imperative dispatch, never a
      # returned effect; absence of any teardown effect confirms membership-only).
      refute Enum.any?(effects, fn
               {:dispatch, _} -> true
               _ -> false
             end)
    end
  end
end
