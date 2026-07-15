defmodule Ezagent.Invariants.PredicateARootCheckTest do
  @moduledoc """
  #154 genesis collapse — predicate A, the standing prevention gate.

  Proves the central root-check actually HOLDS: an authorizing cap whose
  `granted_by` is a `system://` principal does NOT authorize a dispatch, even
  though it is structurally a 5-axis wildcard that `Capability.matches?/2` would
  otherwise accept (matches?/2 ignores granted_by). The ONLY difference between
  the denied and granted cases here is the `granted_by` scheme — so if
  `Ezagent.Capability.granted_by_entity?/1` were removed from dispatch step 5.5
  (`Kind.Runtime.authorizes?/2` for inline `ctx.caps`,
  `Kind.default_holds_cap?/2` for slice-held caps), the denial assertions would
  flip to authorized and this test fails. That is the gate Allen's "reject all
  permissions not granted by an entity" requires.

  Both authorizer sets are covered:
  - inline `ctx.caps` (the forged-cap vector) remains guarded at consumption;
  - slice-held caps (the stale-pre-collapse-snapshot vector) are now rejected
    earlier by Phase 3 S4's `Cap.verify` load boundary, with predicate A kept as
    defense in depth.

  Per `feedback_completion_requires_invariant_test`.
  """

  # #92: was `use ExUnit.Case` + a hand-rolled `checkout` + `{:shared, self()}`
  # in `setup`, which made the dying test process the global shared owner and
  # clobbered concurrent suites on exit. DataCase shares via a drainable Agent
  # owner + drain teardown, so spawned Kinds share the sandbox safely.
  use EzagentCore.DataCase, async: false

  @moduletag :umbrella_only

  alias Ezagent.{Capability, Invocation, Message, Users}
  alias EzagentCore.Repo

  # A 5-axis wildcard cap (the genesis shape) with the given granter. matches?/2
  # accepts it for ANY needed cap — so authorization hinges purely on predicate A.
  defp wildcard_cap(granted_by) do
    %Capability{
      kind: :any,
      behavior: :any,
      action: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: granted_by,
      granted_at: ~U[2026-01-01 00:00:00Z]
    }
  end

  defp system_granter, do: Ezagent.URI.new!("system://bootstrap/default")
  defp entity_granter, do: Ezagent.Entity.User.admin_uri()

  defp session do
    short = "preda_#{System.unique_integer([:positive])}"

    {:ok, uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        short,
        Ezagent.Entity.User.admin_uri(),
        template_name: "default"
      )

    uri
  end

  defp send_target(session_uri),
    do: URI.new!("#{URI.to_string(session_uri)}?action=session.send")

  defp dispatch_send(caller_uri, caps, session_uri) do
    msg = Message.new(caller_uri, %{text: "x", attachments: []}, mentions: [], ref_id: nil)

    Invocation.dispatch(%Invocation{
      target: send_target(session_uri),
      mode: :call,
      args: %{message: msg},
      ctx: %{caller: caller_uri, caps: caps, reply: :inline}
    })
  end

  defp create_legacy_user!(uri_str, cap) do
    {:ok, _} = Users.create(uri_str, nil, [])
    row = Repo.get_by!(Users, uri: uri_str)
    caps_json = Jason.encode!([Capability.to_map(cap)])

    row
    |> Ecto.Changeset.change(%{caps_json: caps_json})
    |> Repo.update!()
  end

  describe "inline ctx.caps authorizer set" do
    test "a system://-granted wildcard cap does NOT authorize (predicate A rejects)" do
      caller = Ezagent.URI.new!("entity://team-alpha/user/preda_inline_sys")
      session_uri = session()

      assert {:error, :unauthorized} =
               dispatch_send(caller, MapSet.new([wildcard_cap(system_granter())]), session_uri),
             "a system://-granted wildcard cap MUST NOT authorize — predicate A is the gate"
    end

    test "the SAME wildcard cap granted by a real entity DOES authorize (control)" do
      caller = Ezagent.URI.new!("entity://team-alpha/user/preda_inline_ent")
      session_uri = session()

      refute match?(
               {:error, :unauthorized},
               dispatch_send(caller, MapSet.new([wildcard_cap(entity_granter())]), session_uri)
             ),
             "the only difference from the denied case is granted_by — entity-granted MUST pass"
    end
  end

  describe "slice-held authorizer set (stale-snapshot vector)" do
    test "a system://-granted wildcard never enters the live slice and cannot authorize" do
      uri_str = "entity://team-alpha/user/preda_held_sys_#{System.unique_integer([:positive])}"
      _row = create_legacy_user!(uri_str, wildcard_cap(system_granter()))
      uri = Ezagent.URI.new!(uri_str)
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
      session_uri = session()

      refute Enum.any?(Ezagent.Identity.read_held_caps(uri), fn cap ->
               cap.granted_by == system_granter()
             end)

      # No inline caps — any authorization would have to come from the slice.
      assert {:error, :unauthorized} = dispatch_send(uri, MapSet.new(), session_uri),
             "an unverified system://-granted wildcard MUST NOT reach or authorize via the held path"
    end

    test "an entity holding an ENTITY-granted wildcard in its slice IS authorized (control)" do
      uri_str = "entity://team-alpha/user/preda_held_ent_#{System.unique_integer([:positive])}"
      _row = create_legacy_user!(uri_str, wildcard_cap(entity_granter()))
      uri = Ezagent.URI.new!(uri_str)
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
      session_uri = session()

      refute match?({:error, :unauthorized}, dispatch_send(uri, MapSet.new(), session_uri)),
             "the entity-granted held wildcard MUST authorize — proves the held-path gate is granted_by-specific"
    end
  end

  describe "the predicate itself" do
    test "granted_by_entity?/1 rejects EXACTLY system://; accepts entity/session/workspace + sentinels" do
      refute Capability.granted_by_entity?(wildcard_cap(system_granter()))
      assert Capability.granted_by_entity?(wildcard_cap(entity_granter()))

      assert Capability.granted_by_entity?(
               wildcard_cap(Ezagent.URI.new!("session://team-alpha/default/x"))
             )

      assert Capability.granted_by_entity?(
               wildcard_cap(Ezagent.URI.new!("workspace://team-alpha"))
             )

      # Non-system sentinels pass — `cap/5` stamps `:plugin_declared`/nil on
      # legitimate authorizer caps; the GRANT chokepoint enforces entity granters.
      assert Capability.granted_by_entity?(wildcard_cap(:plugin_declared))
      assert Capability.granted_by_entity?(wildcard_cap(nil))
    end
  end
end
