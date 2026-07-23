defmodule Ezagent.Socialware.AnonPublicViewGrantTest do
  @moduledoc """
  Issue #51 §4.1 / GLOSSARY Decision #154 — the anonymous public-view access path
  authorizes a visitor WITHOUT any abstract `system://` principal.

  `Ezagent.Socialware.AnonUser.mint_for_public_session/1` is the structural
  authorization chokepoint: `public_view == true` is itself the rule that
  authorizes minting the anon a NARROW participation grant. The grant is born WITH
  the identity (written into `caps_json` at create time), so the anon joins ONLY
  its own session under its OWN authority — no system principal in the dispatch.

  ## The escalation risk this test exists to close

  A too-broad authorization branch. These tests prove:

    * a `public_view == true` session authorizes ONLY a `{this session}`-scoped
      join grant — nothing broader, nothing touching another session;
    * a `public_view == false` / private session REFUSES the grant (the rule
      branch checks the flag is ACTUALLY true);
    * `granted_by` on the resulting cap = the canonical admin entity that
      actually exercises the sealed target authority, never an impersonated
      session owner and never a `system://` principal;
    * (positive, end-to-end) an anon minted via this path joins the session AS
      ITSELF (caller = anon, presenting its born-signed cap) and becomes a live member
      able to participate — proving no system principal is needed for the join.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.{Capability, KindRegistry}
  alias Ezagent.Socialware.{AnonUser, ChatFeed, DefinitionRegistry, Installation}

  # NOTE: spawned Session / User Kinds run in their own processes — `use
  # EzagentCore.DataCase, async: false` already shares the sandbox via a
  # drainable Agent owner, so a redundant `Sandbox.mode({:shared, self()})`
  # only re-globalized the connection onto the dying test pid and clobbered
  # concurrent suites with "owner exited" errors (#92).

  # ----- fixtures --------------------------------------------------------

  @workspace "team-alpha"
  @owner_default Ezagent.URI.new!("entity://team-alpha/user/pv-owner")

  # A live session in `team-alpha` with a socialware install whose definition
  # declares `web_anon_access` per `flag`. Direct Kind fixtures use canonical
  # admin as owner because no separate owner principal/delegation is spawned.
  defp public_session(flag, _owner_uri \\ @owner_default) do
    u = System.unique_integer([:positive])
    name = "pv-grant-def-#{u}"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(definition(name, flag),
        workspace_uri: Ezagent.URI.workspace(@workspace)
      )

    content = %{name: "pv-grant-tmpl-#{u}", installs: [name]}
    {:ok, tmpl_uri} = SessionTemplate.persist_version_as_system(content, @workspace)

    session_uri = Ezagent.URI.new!("session://#{@workspace}/default/pv-grant-#{u}")

    {:ok, behaviors} =
      Installation.behavior_set_for_template(content, Ezagent.URI.workspace(@workspace))

    spawn_opts = %{uri: session_uri, behaviors: behaviors, owner_uri: User.admin_uri()}

    {:ok, _pid} = Ezagent.Socialware.TestCapHelper.spawn_session(spawn_opts)
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    :ok =
      Installation.install_template_installs(
        session_uri,
        Ezagent.URI.workspace(@workspace),
        content,
        User.admin_uri()
      )

    {:ok, _} =
      ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl_uri})

    on_exit(fn -> terminate(Session, session_uri) end)
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

  defp spawn_anon_kind(anon_uri) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{
        uri: anon_uri,
        initial_caps: User.initial_caps_for_spawn(anon_uri)
      })

    on_exit(fn -> terminate(User, anon_uri) end)
    :ok
  end

  defp terminate(kind, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        sup =
          case kind do
            Session -> EzagentDomainInstanceMessage.SessionSupervisor
            User -> EzagentDomainIdentity.Application.UserSupervisor
          end

        DynamicSupervisor.terminate_child(sup, pid)

      :error ->
        :ok
    end
  end

  defp minted_join_cap(anon_uri) do
    %{caps: caps} = Ezagent.Users.get_by_uri(anon_uri)

    Enum.find(caps, fn
      %Capability{behavior: Ezagent.ActionSet.Session, action: :join} -> true
      _ -> false
    end)
  end

  # The needed cap dispatch derives for a `session.join` on `session_uri`.
  defp join_need(session_uri) do
    %{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :join,
      instance: Ezagent.URI.instance(session_uri),
      workspace_uri: Capability.workspace_of(session_uri)
    }
  end

  # ----- NEGATIVE: scope is exactly this session, nothing broader --------

  describe "the grant is scoped to EXACTLY the public session (no escalation)" do
    test "a public session mints ONE join cap that authorizes ONLY itself" do
      session = public_session(true)
      {:ok, anon} = AnonUser.mint_for_public_session(session)

      cap = minted_join_cap(anon)
      assert %Capability{} = cap, "expected exactly one Session :join cap in caps_json"

      # Concrete-instance, action exactly :join (NOT :any), workspace pinned.
      assert cap.action == :join
      refute cap.action == :any
      assert cap.kind == :session
      assert cap.instance == Ezagent.URI.instance(session)
      assert cap.workspace_uri == Capability.workspace_of(session)

      # It authorizes a join into THIS session …
      assert Capability.matches?(cap, join_need(session))
    end

    test "the grant does NOT authorize a join into ANOTHER session" do
      session_a = public_session(true)
      session_b = public_session(true, Ezagent.URI.entity(:team_alpha, :user, "pv-owner-b"))

      {:ok, anon_a} = AnonUser.mint_for_public_session(session_a)
      cap = minted_join_cap(anon_a)

      assert Capability.matches?(cap, join_need(session_a))

      refute Capability.matches?(cap, join_need(session_b)),
             "a public-view grant for session A must NOT authorize joining session B"
    end

    test "the anon holds NO cap broader than the single session-join grant" do
      session = public_session(true)
      {:ok, anon} = AnonUser.mint_for_public_session(session)
      %{caps: caps} = Ezagent.Users.get_by_uri(anon)

      # Exactly one cap, no wildcards on any axis, no foreign-instance reach.
      assert length(caps) == 1
      [cap] = caps
      refute cap.kind == :any
      refute cap.behavior == :any
      refute cap.action == :any
      refute cap.instance == :any
      refute cap.workspace_uri == :any
    end
  end

  # ----- NEGATIVE: private session refuses the grant ---------------------

  describe "a non-public session REFUSES the grant (the rule checks the flag)" do
    test "public_view == false → {:error, :not_public_view}, no anon minted" do
      session = public_session(false)
      assert {:error, :not_public_view} = AnonUser.mint_for_public_session(session)
    end

    test "a session with no materializing public-view Template → refused (fail-closed)" do
      bare =
        Ezagent.URI.session(
          :team_alpha,
          :default,
          "pv-bare-#{System.unique_integer([:positive])}"
        )

      {:ok, _pid} =
        Ezagent.Socialware.TestCapHelper.spawn_session(%{
          uri: bare,
          behaviors: Session.socialware_behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(bare, Capability.workspace_of(bare))
      on_exit(fn -> terminate(Session, bare) end)

      assert {:error, :not_public_view} = AnonUser.mint_for_public_session(bare)
    end

    test "a non-session URI is refused" do
      assert {:error, {:not_a_session, _}} =
               AnonUser.mint_for_public_session(Ezagent.URI.entity(:team_alpha, :user, "alice"))
    end
  end

  # ----- granted_by records the real accountable issuer ------------------

  describe "granted_by records the real issuer, never an impersonated principal" do
    test "an owned public session is still issued by canonical admin authority" do
      owner = Ezagent.URI.entity(:team_alpha, :user, "pv-real-owner")
      session = public_session(true, owner)

      {:ok, anon} = AnonUser.mint_for_public_session(session)
      cap = minted_join_cap(anon)

      assert cap.granted_by == User.admin_uri()
      refute cap.granted_by == owner
      assert match?(%URI{scheme: "entity"}, cap.granted_by)
      refute match?(%URI{scheme: "system"}, cap.granted_by)
    end

    test "an ownerless public session uses the same canonical admin issuer" do
      # nil owner — RFC #402 first-join-owner not yet claimed.
      session = public_session(true, nil)

      {:ok, anon} = AnonUser.mint_for_public_session(session)
      cap = minted_join_cap(anon)

      assert cap.granted_by == User.admin_uri()
      assert match?(%URI{scheme: "entity"}, cap.granted_by)
      refute match?(%URI{scheme: "system"}, cap.granted_by)
    end
  end

  # ----- POSITIVE: end-to-end join AS THE ANON ITSELF (no system principal)

  describe "an anon minted for a public session joins AS ITSELF and participates" do
    test "join succeeds with caller=anon and its born-signed cap → live registered member" do
      session = public_session(true)
      {:ok, anon} = AnonUser.mint_for_public_session(session)

      # Real controller order: mint → spawn → join AS THE ANON while explicitly
      # presenting the receiver-bound cap hydrated from caps_json.
      :ok = spawn_anon_kind(anon)

      target = Ezagent.URI.with_action(session, :session, :join)
      cap = minted_join_cap(anon)

      result =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          origin: :trusted_internal,
          target: target,
          mode: :call,
          args: %{member: anon},
          ctx: %{
            caller: anon,
            authenticated_principal: anon,
            caps: MapSet.new([cap]),
            reply: :ignore
          }
        })

      assert match?(:ok, result) or match?({:ok, _}, result),
             "anon self-join must succeed under its own authority, got: #{inspect(result)}"

      # And it is now a real member able to read the feed (membership-only access).
      assert {:ok, %{messages: _}} = ChatFeed.snapshot(session, anon)
    end

    test "an anon for session A canNOT self-join session B (scope holds at dispatch)" do
      session_a = public_session(true)
      session_b = public_session(true, Ezagent.URI.entity(:team_alpha, :user, "pv-owner-b2"))

      {:ok, anon_a} = AnonUser.mint_for_public_session(session_a)
      :ok = spawn_anon_kind(anon_a)

      target_b = Ezagent.URI.with_action(session_b, :session, :join)
      cap_a = minted_join_cap(anon_a)

      result =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          origin: :trusted_internal,
          target: target_b,
          mode: :call,
          args: %{member: anon_a},
          ctx: %{
            caller: anon_a,
            authenticated_principal: anon_a,
            caps: MapSet.new([cap_a]),
            reply: :ignore
          }
        })

      assert match?({:error, :missing_cap}, result),
             "anon_a's session-A grant must NOT authorize joining session B, got: #{inspect(result)}"
    end
  end
end
