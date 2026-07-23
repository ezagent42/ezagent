defmodule Ezagent.ActionSet.SessionParticipationCapsTest do
  @moduledoc """
  no-unowned-caps north star PR-甲-2 (Decision #154 / capbac.md §6 / spec
  `2026-06-19-membership-mount-anon-model-design.md` §3.1) — per-CLASS
  participation cap MOUNT at join.

  Ported + adapted from the prior `feat/per-session-default-caps@e5b51888`
  integration test. The KEY DIFFERENCE from that branch: participation is no
  longer granted INSIDE `handle_join` — it is MOUNTED CALLER-SIDE by the trusted
  access points via `Ezagent.ActionSet.Session.Membership.mount_participation_caps/2`
  AFTER a successful join. So these tests drive the REAL access-point flow
  (provision join authority → dispatch join → mount the tier), not a raw
  `chat.join` dispatch (which fires neither and would green a fiction).

  This gate pins spec §3.1's tiers (scoped to the concrete session instance):

    * UNCONFIRMED user (anon)  → EXACTLY `Publisher.SessionImpl.:subscribe_from`
      (read-only — NO `:send`, NO `:leave`).
    * CONFIRMED user           → the above PLUS `Session.:send` + `Session.:leave`.
    * AGENT member             → NO participation mount (agents carry their own
      caps, provisioned at spawn — 甲-3).

  Plus Decision #154: the mounted caps' `granted_by` is the session OWNER entity
  (never a `system://` principal), and the cap is concrete-instance (no `:any`
  leak to a session the member never joined).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.ActionSet.Session.Membership

  # NOTE: spawned Session / User Kinds run in their own processes and read the
  # rows this test inserts (the 甲-1 lesson — the mount runs CALLER-SIDE).
  # `use EzagentCore.DataCase, async: false` already shares the sandbox via a
  # drainable Agent owner (DataCase.start_owner_stable!), so those cross-process
  # reads work WITHOUT a redundant `Sandbox.mode({:shared, self()})` — that
  # re-globalized the connection onto the test pid, which dies at test exit and
  # clobbered concurrent suites with "owner exited" errors (#92).

  defp uniq, do: System.unique_integer([:positive])

  # Create a real session owned by `owner` via the production create path, so
  # the owner is the session OWNER (the participation granter) and a member.
  defp new_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  # Create + spawn a CONFIRMED user (the `Ezagent.Users.create/3` path sets
  # confirmed:true — 甲-1) and hydrate its caps slice. Returns the URI.
  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  # Create + spawn an UNCONFIRMED (anon) user via the read-only path
  # (confirmed:false — 甲-1).
  defp unconfirmed_user(prefix) do
    uri = URI.new!("entity://system/user/anon-#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create_read_only(uri)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  defp confirmed_user_with_caps(uri, caps) do
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", caps)
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  # The REAL trusted-access-point join flow: provision the per-session join
  # authority (owner-rooted §B), dispatch the join under the joiner's OWN
  # authority (so step-5.5 authorizes via the live slice read), then mount the
  # per-class participation tier (§A). This is exactly what
  # `SessionContext.do_maybe_self_join` does for a self-joining member.
  defp access_point_join(session_uri, member_uri) do
    {:ok, owner} = Ezagent.Entity.Session.owner(session_uri)
    :ok = Membership.provision_invited_join_authority(session_uri, member_uri, owner)

    result =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        origin: :trusted_internal,
        target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: member_uri,
          authenticated_principal: member_uri,
          caps: Ezagent.Identity.list_caps_for(member_uri),
          reply: :ignore
        }
      })

    case result do
      :ok -> :ok
      {:ok, _} -> :ok
      other -> other
    end

    Membership.mount_participation_caps(session_uri, member_uri)
  end

  defp has_cap?(entity_uri, behavior, action, instance) do
    Enum.any?(Ezagent.Identity.list_caps_for(entity_uri), fn cap ->
      match?(%Capability{}, cap) and
        cap.kind == :session and
        cap.behavior == behavior and
        Capability.action_of(cap) == action and
        cap.instance == instance
    end)
  end

  defp wait_cap(entity_uri, behavior, action, instance, retries \\ 100) do
    if has_cap?(entity_uri, behavior, action, instance) do
      true
    else
      if retries > 0 do
        Process.sleep(10)
        wait_cap(entity_uri, behavior, action, instance, retries - 1)
      else
        false
      end
    end
  end

  describe "per-class participation tier (spec §3.1)" do
    test "an UNCONFIRMED member ends with EXACTLY :subscribe_from (no :send, no :leave)" do
      owner = confirmed_user("owner")
      session_uri = new_session("pc-unconf", owner)
      anon = unconfirmed_user("viewer")

      :ok = access_point_join(session_uri, anon)

      assert wait_cap(
               anon,
               Ezagent.ActionSet.Publisher.SessionImpl,
               :subscribe_from,
               session_uri
             ),
             "an unconfirmed member must hold the read-only :subscribe_from tier"

      refute has_cap?(anon, Ezagent.ActionSet.Session, :send, session_uri),
             "an unconfirmed (anon) member must NOT hold :send"

      refute has_cap?(anon, Ezagent.ActionSet.Session, :leave, session_uri),
             "an unconfirmed (anon) member must NOT hold :leave"
    end

    test "a CONFIRMED member holds :send + :leave + :subscribe_from" do
      owner = confirmed_user("owner")
      session_uri = new_session("pc-conf", owner)
      member = confirmed_user("member")

      :ok = access_point_join(session_uri, member)

      assert wait_cap(member, Ezagent.ActionSet.Session, :send, session_uri),
             "a confirmed member must hold :send"

      assert has_cap?(member, Ezagent.ActionSet.Session, :leave, session_uri),
             "a confirmed member must hold :leave"

      assert has_cap?(
               member,
               Ezagent.ActionSet.Publisher.SessionImpl,
               :subscribe_from,
               session_uri
             ),
             "a confirmed member must hold :subscribe_from"
    end

    test "an invalid current-identity :send artifact is replaced during participation mount" do
      owner = confirmed_user("owner-stale-send")
      session_uri = new_session("pc-stale-send", owner)

      requested =
        Capability.cap(
          :session,
          Ezagent.ActionSet.Session,
          :send,
          session_uri,
          Capability.workspace_of(session_uri)
        )

      receiver = URI.new!("entity://system/user/member-stale-send-#{uniq()}")

      {:ok, valid} =
        Ezagent.Cap.issue({:admin, Ezagent.Entity.User.admin_uri()}, receiver, requested)

      invalid = %{valid | signature: :binary.copy(<<0>>, byte_size(valid.signature))}
      member = confirmed_user_with_caps(receiver, [invalid])

      assert Capability.identity_key(invalid) == Capability.identity_key(requested)
      :ok = access_point_join(session_uri, member)

      stored =
        member
        |> Ezagent.Identity.list_caps_for()
        |> Enum.find(&(Capability.identity_key(&1) == Capability.identity_key(requested)))

      assert %Capability{} = stored

      refute stored.signature == invalid.signature,
             "a structurally matching artifact with an invalid signature must not suppress reissue"
    end

    test "a valid current-identity artifact makes repeated participation mount idempotent" do
      owner = confirmed_user("owner-idempotent")
      session_uri = new_session("pc-idempotent", owner)
      member = confirmed_user("member-idempotent")

      :ok = access_point_join(session_uri, member)

      first =
        member
        |> Ezagent.Identity.list_caps_for()
        |> Enum.find(
          &(match?(%Capability{}, &1) and &1.behavior == Ezagent.ActionSet.Session and
              Capability.action_of(&1) == :send and &1.instance == session_uri)
        )

      assert %Capability{} = first
      :ok = Membership.mount_participation_caps(session_uri, member)

      second =
        member
        |> Ezagent.Identity.list_caps_for()
        |> Enum.find(&(Capability.identity_key(&1) == Capability.identity_key(first)))

      assert second.signature == first.signature
      assert second.granted_at == first.granted_at
    end

    test "the participation tier does NOT leak to a DIFFERENT session (no :any instance)" do
      owner = confirmed_user("owner")
      session_uri = new_session("pc-scope", owner)
      other_session = new_session("pc-other", owner)
      member = confirmed_user("member")

      :ok = access_point_join(session_uri, member)
      assert wait_cap(member, Ezagent.ActionSet.Session, :send, session_uri)

      refute has_cap?(member, Ezagent.ActionSet.Session, :send, other_session),
             "the per-session tier must not authorize a session the member never joined"
    end

    test "the mounted caps' granted_by is the session OWNER entity (Decision #154)" do
      owner = confirmed_user("owner")
      session_uri = new_session("pc-granter", owner)
      member = confirmed_user("member")

      :ok = access_point_join(session_uri, member)
      assert wait_cap(member, Ezagent.ActionSet.Session, :send, session_uri)

      send_cap =
        member
        |> Ezagent.Identity.list_caps_for()
        |> Enum.find(fn cap ->
          match?(%Capability{}, cap) and cap.behavior == Ezagent.ActionSet.Session and
            Capability.action_of(cap) == :send and cap.instance == session_uri
        end)

      assert %URI{scheme: "entity"} = send_cap.granted_by,
             "participation granted_by must be a real entity, got #{inspect(send_cap.granted_by)}"

      assert send_cap.granted_by == owner,
             "participation granted_by must be the session owner, got #{inspect(send_cap.granted_by)}"
    end

    test "an AGENT member receives NO participation mount (users only)" do
      owner = confirmed_user("owner")
      session_uri = new_session("pc-agent", owner)

      # An agent URI — the helper short-circuits on `user_uri?/1` (no live Kind
      # needed; the mount no-ops for any non-user member by construction).
      agent_uri = URI.new!("entity://system/agent/echo-#{uniq()}")

      assert :ok = Membership.mount_participation_caps(session_uri, agent_uri)
      Process.sleep(50)

      refute has_cap?(agent_uri, Ezagent.ActionSet.Session, :send, session_uri),
             "agents carry their own caps — the per-session USER mount must not fire"

      refute has_cap?(
               agent_uri,
               Ezagent.ActionSet.Publisher.SessionImpl,
               :subscribe_from,
               session_uri
             ),
             "agents receive no user participation tier"
    end
  end
end
