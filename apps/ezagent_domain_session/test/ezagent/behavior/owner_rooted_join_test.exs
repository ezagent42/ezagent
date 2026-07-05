defmodule Ezagent.ActionSet.OwnerRootedJoinTest do
  @moduledoc """
  THE PR-甲-2 acceptance invariant (spec
  `2026-06-19-membership-mount-anon-model-design.md` §8 / plan Step 7b / Allen
  2026-06-19) — join authority is ROOTED AT THE SESSION OWNER, never an
  ambient/universal baseline.

  This is the correctness gate proving the chicken-and-egg fix: with
  `User.default_caps` narrowed to `[]` (no broad `cap(:session,:any,:any)`
  baseline), a legitimate self-join is authorized by SESSION POLICY
  (`Membership.provision_join_authority/2`, owner-rooted), and an illegitimate
  one degrades to observe. Concretely:

    * (g1) a user holding NO broad baseline CANNOT self-join a PRIVATE session it
      neither owns nor is a member of → `{:error, :unauthorized}` (→ the access
      point's "observe" flash).
    * (g2) when a join IS authorized, the authorizing grant's `granted_by` ==
      the session OWNER, except the documented exceptions (first-non-anon-join
      owner-claim / ownerless→admin fallback / system-boot).
    * (g3) a `public_view` session admits a join via the public-view RULE
      (configurer = owner) — modeled here by the anon's own minted join cap
      (`anon_user.mint_for_public_session/1`, exercised in the socialware suite);
      this file pins the OWNER-rooted granter of that cap.

  This test FAILS if join authority ever comes from a universal baseline — it is
  the proof that "removing the baseline" is correct AND authority is owner-rooted
  ([[feedback_completion_requires_invariant_test]]). MUST run from the umbrella
  ROOT (cross-app deps), never `cd app`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.Socialware.{DefinitionRegistry, Installation}

  # NOTE: spawned Session / User Kinds run in their own processes and read the
  # rows this test inserts (the 甲-1 lesson — the mount runs CALLER-SIDE here).
  # `use EzagentCore.DataCase, async: false` already shares the sandbox via a
  # drainable Agent owner (DataCase.start_owner_stable!), so those cross-process
  # reads work WITHOUT a redundant `Sandbox.mode({:shared, self()})` — that
  # re-globalized the connection onto the test pid, which dies at test exit and
  # clobbered concurrent suites with "owner exited" errors (#92).

  defp uniq, do: System.unique_integer([:positive])

  defp confirmed_user(prefix) do
    uri = URI.new!("entity://system/user/#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(uri)
    uri
  end

  # A private session owned by `owner` (the production create path makes the
  # creator the owner + a member).
  defp private_session(prefix, owner) do
    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        "#{prefix}-#{uniq()}",
        owner,
        template_name: "default"
      )

    session_uri
  end

  # The trusted access-point flow's authorization step: provision per policy,
  # then dispatch the join under the joiner's OWN caps (so step-5.5 reads the
  # live slice). Returns the raw dispatch result so g1 can assert :unauthorized.
  defp self_join(session_uri, joiner) do
    _ = Membership.provision_join_authority(session_uri, joiner)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: %{member: joiner},
      ctx: %{caller: joiner, caps: Ezagent.Identity.list_caps_for(joiner), reply: :ignore}
    })
  end

  describe "g1: no-baseline user cannot self-join a PRIVATE session" do
    test "a non-owner, non-member user is rejected :unauthorized (degrades to observe)" do
      owner = confirmed_user("g1-owner")
      session_uri = private_session("g1-priv", owner)

      # A DIFFERENT confirmed user with NO broad baseline (default_caps == []),
      # not the owner, not a member, not invited.
      stranger = confirmed_user("g1-stranger")

      # Guard: the stranger genuinely holds no session :join cap from a baseline.
      refute Enum.any?(Ezagent.Identity.list_caps_for(stranger), fn cap ->
               match?(%Capability{}, cap) and cap.kind == :session and
                 Capability.action_of(cap) == :join
             end),
             "the stranger must not start with any session :join cap (baseline removed)"

      assert {:error, :unauthorized} = self_join(session_uri, stranger),
             "a no-baseline non-owner/non-member must be REJECTED self-joining a private session"
    end
  end

  describe "g2: an authorized join's grant is granted_by the OWNER" do
    test "an existing member's provisioned join cap is granted_by the session owner" do
      owner = confirmed_user("g2-owner")
      session_uri = private_session("g2-priv", owner)

      # The owner adds a member under the owner's authority (invite path:
      # owner-authorized join), making them an existing member.
      member = confirmed_user("g2-member")

      # Owner self-join provisions the owner's join cap (owner-rooted), then the
      # owner invites the member (join dispatched under the owner's authority).
      {:ok, _} = self_join(session_uri, owner)

      {:ok, _} =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
          mode: :call,
          args: %{member: member},
          ctx: %{caller: owner, caps: Ezagent.Identity.list_caps_for(owner), reply: :ignore}
        })

      # Now the member self-joins on a later navigation: provision_join_authority
      # sees them as an existing member → provisions an owner-rooted join cap.
      _ = Membership.provision_join_authority(session_uri, member)

      join_cap =
        member
        |> Ezagent.Identity.list_caps_for()
        |> Enum.find(fn cap ->
          match?(%Capability{}, cap) and cap.kind == :session and
            cap.behavior == Ezagent.ActionSet.Session and
            Capability.action_of(cap) == :join and cap.instance == session_uri
        end)

      assert %Capability{} = join_cap,
             "an existing member must be provisioned a per-session :join cap"

      assert join_cap.granted_by == owner,
             "the provisioned join cap must be granted_by the session OWNER (g2), got " <>
               inspect(join_cap.granted_by)
    end

    test "the owner's own provisioned join cap is granted_by the owner (self-rooted)" do
      owner = confirmed_user("g2b-owner")
      session_uri = private_session("g2b-priv", owner)

      _ = Membership.provision_join_authority(session_uri, owner)

      join_cap =
        owner
        |> Ezagent.Identity.list_caps_for()
        |> Enum.find(fn cap ->
          match?(%Capability{}, cap) and cap.kind == :session and
            cap.behavior == Ezagent.ActionSet.Session and
            Capability.action_of(cap) == :join and cap.instance == session_uri
        end)

      assert %Capability{} = join_cap
      assert join_cap.granted_by == owner, "owner self-join is owner-rooted"
    end
  end

  describe "g2 exception (ii): ownerless session → admin-fallback granter" do
    test "first-non-anon join of an ownerless session is provisioned granted_by admin" do
      # An ownerless session (spawned bare, no create-path owner).
      session_uri = URI.new!("session://system/default/g2c-ownerless-#{uniq()}")
      {:ok, _} = Ezagent.SpawnRegistry.spawn(session_uri)
      :ok = Ezagent.WorkspaceRegistry.bind(session_uri, URI.new!("workspace://system"))
      on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

      claimer = confirmed_user("g2c-claimer")

      assert :ok = Membership.provision_join_authority(session_uri, claimer)

      join_cap =
        claimer
        |> Ezagent.Identity.list_caps_for()
        |> Enum.find(fn cap ->
          match?(%Capability{}, cap) and cap.kind == :session and
            cap.behavior == Ezagent.ActionSet.Session and
            Capability.action_of(cap) == :join and cap.instance == session_uri
        end)

      assert %Capability{} = join_cap,
             "the first-non-anon joiner of an ownerless session must be provisioned a join cap"

      assert join_cap.granted_by == User.admin_uri(),
             "an ownerless session's first-join is granted_by the admin fallback (g2 exc ii), got " <>
               inspect(join_cap.granted_by)
    end
  end

  describe "g3: public_view session admits a join via the owner-configured rule" do
    # A public_view session: the join cap is minted by
    # `anon_user.mint_for_public_session/1` (the public-view RULE; configurer =
    # owner) — born WITH the anon, granted_by the session owner. This admits the
    # join under the anon's OWN authority (no universal baseline). The full
    # positive end-to-end admit + granted_by==owner is exhaustively pinned in the
    # socialware suite (`Ezagent.Socialware.AnonPublicViewGrantTest`); here we
    # reproduce the minimal owner-rooted admit using the same fixture shape so
    # this acceptance file is self-contained.
    @ws "team-alpha"

    test "a public_view session mints a join cap granted_by the owner (admit via rule)" do
      owner = Ezagent.URI.entity(:team_alpha, :user, "g3-owner")
      session_uri = public_view_session(true, owner)

      assert {:ok, anon_uri} = Ezagent.Socialware.AnonUser.mint_for_public_session(session_uri)

      %{caps: caps} = Ezagent.Users.get_by_uri(anon_uri)

      join_cap =
        Enum.find(caps, fn cap ->
          match?(%Capability{}, cap) and cap.kind == :session and
            cap.behavior == Ezagent.ActionSet.Session and
            Capability.action_of(cap) == :join and
            cap.instance == Ezagent.URI.instance(session_uri)
        end)

      assert %Capability{} = join_cap,
             "the public_view session must admit a join via the rule (anon minted a join cap)"

      assert join_cap.granted_by == owner,
             "the public_view admit is owner-rooted: granted_by must be the owner (g3), got " <>
               inspect(join_cap.granted_by)

      refute match?(%URI{scheme: "system"}, join_cap.granted_by),
             "the public_view admit must NOT be granted by a system:// principal"
    end

    test "a PRIVATE (non-public-view) session REFUSES the rule admit" do
      owner = Ezagent.URI.entity(:team_alpha, :user, "g3-priv-owner")
      session_uri = public_view_session(false, owner)

      assert {:error, :not_public_view} =
               Ezagent.Socialware.AnonUser.mint_for_public_session(session_uri),
             "a private session must not admit a public-view join"
    end
  end

  # A live session in `team-alpha` whose installed socialware definition
  # declares `web_anon_access: flag`, owned by `owner_uri`.
  defp public_view_session(flag, %URI{} = owner_uri) do
    u = uniq()
    name = "g3-def-#{u}"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(definition(name, flag),
        workspace_uri: Ezagent.URI.workspace(@ws)
      )

    content = %{name: "g3-tmpl-#{u}", installs: [name]}
    {:ok, tmpl_uri} = SessionTemplate.persist_version_as_system(content, @ws)

    session_uri = URI.new!("session://#{@ws}/default/g3-#{u}")
    {:ok, behaviors} = Installation.behavior_set_for_template(content, Ezagent.URI.workspace(@ws))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: behaviors,
        owner_uri: owner_uri
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    :ok =
      Installation.install_template_installs(
        session_uri,
        Ezagent.URI.workspace(@ws),
        content,
        owner_uri
      )

    {:ok, _} =
      Ezagent.ActionSet.Session.ConfigActions.system_set_working_copy(
        session_uri,
        %{session_template_uri: tmpl_uri}
      )

    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)
    session_uri
  end

  defp definition(name, web_anon_access) do
    %{
      name: name,
      bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
      owner_policy: %{type: :installer},
      visibility_policy: %{publish_policy: :auto, web_anon_access: web_anon_access}
    }
  end
end
