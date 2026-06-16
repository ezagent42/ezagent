defmodule Ezagent.Entity.Agent.TemplateSpawn.RoleCapsMechanismTest do
  @moduledoc """
  #54 deferral (1) — EVIDENCE for the role-caps fail-closed authorization+mint
  mechanism (`Ezagent.Entity.Agent.TemplateSpawn.grant_role_caps/5`).

  **The mechanism is NOT wired into the live spawn path** — DELIVERY of a minted
  CONCRETE cap whose behavior's `data_owner` is the AGENT ITSELF (Identity-family)
  onto a fresh agent identity is blocked on an architecture Decision (the
  `identity.grant_cap` data-owner chokepoint → `:grant_not_owner`; no reachable
  materialization principal holds the bootstrap wildcard). Delivery is asymmetric
  by `data_owner` — `data_owner -> :any` behaviors already grant via the
  workspace-admin path (codex adversarial-review corrected an earlier "always
  blocked" overstatement). See the function's `NOT WIRED` note +
  `docs/notes/54-d1-caps-behaviors-spawn.md`.

  These tests prove the two properties that ARE complete + correct:

  1. **Fail-closed authorization (the #54 gate):** a requested cap the GRANTER
     does NOT hold is rejected by CapMint BEFORE any grant — never granted, never
     widened to a wildcard. The new logic (beyond already-tested core CapMint /
     Materialize #800) is the **granter-delegation policy** read from the
     granter's LITERAL `:identity` caps (it does NOT honor Kind-specific
     `holds_cap?` overrides — granter-delegation by held caps).
  2. **Delivery blocker for `data_owner=self` caps (the Decision, proven
     empirically):** an AUTHORIZED Identity-family cap (granter holds the
     wildcard) is correctly MINTED but its grant is REFUSED by the chokepoint
     (`:grant_not_owner`) → `role_degraded`. This is why the mechanism is not
     wired — it is the Decision Allen must resolve. (Delivery is NOT universally
     blocked: `data_owner -> :any` caps grant via the workspace-admin path; the
     mechanism is also non-atomic across a multi-cap list — both are option-(b)
     constraints documented in the notes, not tested here.)

  Run against a real `Entity.Agent` worker (carries `Behavior.Identity`, so the
  `:identity` slice exists + is grantable) and the real `cc` flavor (resolves
  `kind: :agent` via `Entity.Agent.type_name/0`).
  """

  use ExUnit.Case, async: false

  alias Ezagent.Entity.Agent.TemplateSpawn
  alias Ezagent.Entity.User

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Admin User Kind alive — its LITERAL :identity slice carries the
    # `[:any, :any, :any, :any]` bootstrap wildcard cap (User.initial_caps_for_spawn),
    # so admin is the authorized (wildcard-holding) granter for the positive case.
    {:ok, _} = ensure_alive(User.admin_uri())

    workspace_uri = URI.new!("workspace://system")

    {:ok, workspace_uri: workspace_uri}
  end

  defp ensure_alive(%URI{} = uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # A fresh bare worker Agent Kind (Entity.Agent — has Behavior.Identity).
  defp spawn_worker(workspace_uri) do
    name = "role-caps-worker-#{System.unique_integer([:positive])}"
    ws_name = Ezagent.URI.workspace_name!(workspace_uri)
    uri = Ezagent.URI.agent(ws_name, "cc_#{name}")
    # The agent-scheme spawn fn resolves the Kind module from the STORED flavor
    # attribute (AgentModuleResolver), so seed it before spawning — exactly what
    # a flavor's `instantiate/3` does (`AgentFlavorAttributes.put/2`).
    :ok = Ezagent.AgentFlavorAttributes.put(uri, "cc")
    {:ok, _pid} = ensure_alive(uri)
    _ = Ezagent.ReadyGate.await(uri, 5_000)
    uri
  end

  # A fresh NON-admin user with no caps_json row → empty literal :identity caps
  # (only the structural self-Identity cap) → the unauthorized granter.
  defp spawn_bare_granter(workspace_uri) do
    ws_name = Ezagent.URI.workspace_name!(workspace_uri)
    uri = Ezagent.URI.user(ws_name, "role-caps-granter-#{System.unique_integer([:positive])}")
    {:ok, _pid} = ensure_alive(uri)
    _ = Ezagent.ReadyGate.await(uri, 5_000)
    uri
  end

  defp worker_caps(%URI{} = worker_uri) do
    case Ezagent.Kind.get_slice(worker_uri, :identity) do
      {:ok, %{caps: %MapSet{} = caps}} -> caps
      _ -> MapSet.new()
    end
  end

  # A well-formed requested cap template: real new-style Behavior MODULE + atom
  # action (the shape CapMint requires to survive `well_formed?`).
  defp requested_real_cap do
    %{behavior: Ezagent.Behavior.Identity, action: :grant_cap}
  end

  describe "fail-closed authorization (the #54 gate)" do
    test "a requested cap the granter does NOT hold is rejected, never granted",
         %{workspace_uri: workspace_uri} do
      worker = spawn_worker(workspace_uri)
      granter = spawn_bare_granter(workspace_uri)

      before = worker_caps(worker)

      meta =
        TemplateSpawn.grant_role_caps(
          %{role_requested_caps: [requested_real_cap()]},
          [worker],
          granter,
          workspace_uri,
          "cc"
        )

      after_caps = worker_caps(worker)

      # The requested cap was NOT granted — the granter held no matching cap.
      refute Enum.any?(after_caps, fn c ->
               c.behavior == Ezagent.Behavior.Identity and
                 Ezagent.Capability.action_of(c) == :grant_cap
             end),
             "fail-closed: a degraded/unauthorized role must NOT grant a cap the granter lacks"

      # No NEW cap landed at all (worker keeps exactly its structural self-caps).
      assert MapSet.equal?(before, after_caps),
             "no cap should be added when the granter is unauthorized"

      # Correct REJECTION is not a degradation — the role was authorized to
      # request; the grant was correctly denied. `role_degraded` stays unset.
      refute Map.has_key?(meta, :role_degraded),
             "an authorization rejection is not a role degradation"
    end

    test "a wildcard request (behavior: :any / action: :any) is dropped by CapMint, never granted",
         %{workspace_uri: workspace_uri} do
      worker = spawn_worker(workspace_uri)
      # Even with the ALL-POWERFUL admin (wildcard-holding) granter, a malformed
      # `:any` cap request is dropped by CapMint's `well_formed?` (a wildcard
      # `:any` is not a real Behavior module) BEFORE the policy ever sees it.
      granter = User.admin_uri()

      before = worker_caps(worker)

      meta =
        TemplateSpawn.grant_role_caps(
          %{role_requested_caps: [%{behavior: :any, action: :any}]},
          [worker],
          granter,
          workspace_uri,
          "cc"
        )

      after_caps = worker_caps(worker)

      assert MapSet.equal?(before, after_caps),
             "a degraded role never grants a wildcard cap — the :any request is dropped"

      refute Map.has_key?(meta, :role_degraded)
    end
  end

  describe "delivery blocker for data_owner=self caps (the Decision — proven empirically)" do
    test "an AUTHORIZED Identity-family cap is MINTED but its grant is REFUSED by the data-owner chokepoint",
         %{workspace_uri: workspace_uri} do
      worker = spawn_worker(workspace_uri)
      # Admin's literal :identity slice carries the bootstrap wildcard cap, which
      # matches any well-formed needed cap → the cap IS authorized + minted
      # (kind=:agent, behavior=Identity, action=:grant_cap). `Identity` is a
      # `data_owner = self` behavior (`Identity.data_owner(uri) = uri`).
      granter = User.admin_uri()

      before = worker_caps(worker)

      meta =
        TemplateSpawn.grant_role_caps(
          %{role_requested_caps: [requested_real_cap()]},
          [worker],
          granter,
          workspace_uri,
          "cc"
        )

      # DELIVERY IS BLOCKED for this Identity-family (data_owner=self) cap: its
      # grant hits the `identity.grant_cap` data-owner clause — the agent owns its
      # own identity, the granter (admin) is NOT the agent, and the grant ctx
      # principal (`system://template-materialize`) is not a bootstrap-wildcard
      # holder → `:grant_not_owner`. (Delivery is asymmetric: `data_owner -> :any`
      # caps grant via the workspace-admin path — codex corrected an earlier
      # "always blocked" claim. Born-with `initial_caps` is the correct uniform
      # home, but it needs the same arity-1 `SpawnRegistry.spawn_detailed/1`
      # contract change that blocks role BEHAVIORS — caps + behaviors share one
      # blocker.)
      assert %{role_degraded: true, role_degraded_reason: {:role_cap_grant_failed, :grant_not_owner}} =
               meta,
             "authorized cap is minted but delivery is refused by the grant chokepoint — " <>
               "the #54 deferral (1) Decision blocker"

      # Nothing from this role landed (no concrete grant_cap cap on the worker).
      refute Enum.any?(MapSet.difference(worker_caps(worker), before), fn c ->
               c.behavior == Ezagent.Behavior.Identity and
                 Ezagent.Capability.action_of(c) == :grant_cap
             end),
             "the refused grant must leave no role-requested cap on the worker"
    end
  end

  describe "no role caps" do
    test "absent role_requested_caps is a no-op (no degradation, no grant)",
         %{workspace_uri: workspace_uri} do
      worker = spawn_worker(workspace_uri)
      before = worker_caps(worker)

      meta = TemplateSpawn.grant_role_caps(%{}, [worker], User.admin_uri(), workspace_uri, "cc")

      assert meta == %{}
      assert MapSet.equal?(before, worker_caps(worker))
    end

    test "an unknown flavor degrades best-effort (does not crash, does not grant)",
         %{workspace_uri: workspace_uri} do
      worker = spawn_worker(workspace_uri)
      before = worker_caps(worker)

      meta =
        TemplateSpawn.grant_role_caps(
          %{role_requested_caps: [requested_real_cap()]},
          [worker],
          User.admin_uri(),
          workspace_uri,
          "no_such_flavor"
        )

      assert %{role_degraded: true, role_degraded_reason: {:unknown_flavor, "no_such_flavor"}} =
               meta

      assert MapSet.equal?(before, worker_caps(worker)),
             "a degraded (unknown-flavor) role grants nothing"
    end
  end
end
