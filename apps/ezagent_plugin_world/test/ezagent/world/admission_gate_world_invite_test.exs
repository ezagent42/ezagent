defmodule Ezagent.World.AdmissionGateWorldInviteTest do
  @moduledoc """
  §14 test 33 (spec §C.1 bypass 1) — the World-UI invite-button regression.

  `Ezagent.World.ConversationActions.invite_member/3` dispatches `session.join`
  DIRECTLY with the inviter's caps (it does NOT route through
  `provision_invited_join_authority/3`), so an admission trigger scoped to one
  invite function would MISS the world-UI path — the exact bypass a completeness
  review caught. This drives the REAL `invite_member/3` (NOT a hand-built
  `session.join` dispatch, which is already covered by the §14.5(A) acceptance) and
  asserts a cross-owner invite goes PENDING at the common `handle_join` chokepoint:
  no member-cap, not mounted. A future regression re-scoping the trigger to one
  entry path fails this test.

  Entities live in a UNIQUE NON-system workspace: the `system` workspace is the
  admin workspace, so a `entity://system/user/…` inviter would be a workspace-admin
  (`manages?` true) and never pend. A plain team workspace makes B a genuine
  non-manager co-tenant.
  """

  use EzagentCore.DataCase, async: false

  import Phoenix.Component, only: [assign: 3]

  alias Ezagent.Capability
  alias Ezagent.Entity.User
  alias Ezagent.Identity.Authority
  alias Ezagent.World.ConversationActions

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    assert "entity" in Ezagent.SpawnRegistry.registered_schemes(),
           "entity spawn scheme not registered — test environment bootstrap is incomplete"

    :ok
  end

  defp uniq, do: System.unique_integer([:positive])
  defp new_ws, do: "wadm-#{uniq()}"

  defp confirmed_user(ws, prefix) do
    uri = URI.new!("entity://#{ws}/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp new_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  defp agent_member(ws, prefix) do
    uri = URI.new!("entity://#{ws}/agent/#{prefix}-#{uniq()}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()})

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Capability.workspace_of(uri))
    uri
  end

  # Grant `granter` durable manage-authority over `target` so `manages?/2` is true.
  defp grant_manage(granter, target) do
    cap =
      Ezagent.CreatorGrant.manage_cap(:agent, target, Capability.workspace_of(target), granter)

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        granter,
        cap,
        {:admin, User.admin_uri()},
        :sync
      )
  end

  defp session_state(session_uri) do
    case Ezagent.Kind.read(session_uri, :session, spawn: :never) do
      {:ok, %{state: state}} when is_map(state) -> state
      {:ok, state} when is_map(state) -> state
      _ -> %{}
    end
  end

  defp read_pending(s), do: session_state(s) |> Map.get(:pending_members, %{})
  defp read_members(s), do: session_state(s) |> Map.get(:members, %{})

  defp member_cap(entity_uri, session_uri) do
    entity_uri
    |> Ezagent.Identity.list_caps_for()
    |> Enum.find(fn
      %Capability{kind: :session} = c ->
        Capability.action_of(c) == :receive and c.instance == session_uri

      _ ->
        false
    end)
  end

  # The minimal WorldLive socket `invite_member/3` reads: the inviter identity,
  # selected workspace, and caps. `current_caps` carries the admin genesis
  # wildcard ONLY to clear the `:join` CapBAC gate — the admission decision reads
  # the INVITER's DURABLE identity caps (`manages?/2`), NOT `current_caps`, so
  # this never suppresses the gate (a STRONGER proof: even a genesis socket cap
  # does not let B's cross-owner invite mount).
  defp invite_socket(inviter, session_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, inviter)

    # Actor-extraction C1: invite_member re-derives caps FRESH via
    # PresenterCaps.load → IdentityCaps.load(inviter) (no mount snapshot). A
    # confirmed user already holds a self-license; durably grant it the signed
    # join cap so it clears the `:join` CapBAC gate — the admission decision
    # still reads the inviter's DURABLE `manages?/2`, not this cap.
    :ok = Ezagent.IdentityCaps.grant(inviter, cap)

    %Phoenix.LiveView.Socket{}
    |> assign(:current_entity_uri, inviter)
    |> assign(:current_workspace_uri, Capability.workspace_of(inviter))
    |> assign(:current_caps, MapSet.new([cap]))
    |> assign(:last_dispatch_status, "idle")
    |> assign(:world_state, %{"layout" => %{}})
    |> assign(:world_state_json, "{}")
  end

  test "World invite_member/3 of a cross-owner agent goes PENDING, no member-cap, not mounted (test 33)" do
    ws = new_ws()
    a = confirmed_user(ws, "owner-a")
    b = confirmed_user(ws, "cotenant-b")
    b_session = new_session("b-conv", b)
    a_agent = agent_member(ws, "a-agent")
    grant_manage(a, a_agent)

    refute Authority.manages?(b, a_agent),
           "precondition: B (the inviter) must NOT manage A's agent"

    # Drive the REAL world-UI invite-button entry point.
    {:noreply, _socket} =
      ConversationActions.invite_member(
        invite_socket(b, b_session),
        b_session,
        URI.to_string(a_agent)
      )

    assert Map.has_key?(read_pending(b_session), a_agent),
           "world invite of a cross-owner agent must go PENDING at the handle_join chokepoint"

    refute Map.has_key?(read_members(b_session), a_agent),
           "a pending member must NOT be mounted into :members"

    refute member_cap(a_agent, b_session),
           "a pending member must hold NO member-cap (R1.1 ⇒ receive denied ⇒ cred not spent)"
  end
end
