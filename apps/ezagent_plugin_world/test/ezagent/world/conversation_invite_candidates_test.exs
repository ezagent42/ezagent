defmodule Ezagent.World.ConversationInviteCandidatesTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.World.ConversationData

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _}} -> :ok
    end

    :ok
  end

  test "conversation state exposes caller-authorized invite candidates excluding current members" do
    admin = User.admin_uri()
    short = "world-invite-candidates-#{System.unique_integer([:positive])}"

    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(short, admin,
        template_name: "default"
      )

    assert wait_until(fn ->
             ConversationData.member_options(admin, session_uri)
             |> Enum.any?(&(&1["uri"] == URI.to_string(admin)))
           end)

    invitee =
      Ezagent.URI.new!(
        "entity://system/user/invite_candidate_#{System.unique_integer([:positive])}"
      )

    assert :ok = create_read_only_user(invitee, [])

    state =
      ConversationData.state_for(session_uri, %{
        caller_uri: admin,
        caller_caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        workspace_uri: Ezagent.URI.workspace(:system),
        sessions: []
      })

    candidates = Map.fetch!(state, "invite_candidates")
    candidate_uris = Enum.map(candidates, & &1["uri"])

    assert URI.to_string(invitee) in candidate_uris
    refute URI.to_string(admin) in candidate_uris

    row = Enum.find(candidates, &(&1["uri"] == URI.to_string(invitee)))
    assert row["kind"] == "user"
    assert is_binary(row["display_name"]) and row["display_name"] != ""

    routing_candidates = Map.fetch!(state, "routing_entity_candidates")
    routing_uris = Enum.map(routing_candidates, & &1["uri"])
    assert URI.to_string(admin) in routing_uris
    assert URI.to_string(invitee) in routing_uris
  end

  test "invite candidates include provisioned users before their Kind is live" do
    admin = User.admin_uri()
    short = "world-invite-persisted-user-#{System.unique_integer([:positive])}"

    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(short, admin,
        template_name: "default"
      )

    assert wait_until(fn ->
             ConversationData.member_options(admin, session_uri)
             |> Enum.any?(&(&1["uri"] == URI.to_string(admin)))
           end)

    invitee =
      Ezagent.URI.new!(
        "entity://system/user/invite_persisted_#{System.unique_integer([:positive])}"
      )

    assert {:ok, _user} = Ezagent.Users.create_read_only(invitee, [])

    candidates =
      ConversationData.invite_candidates(
        session_uri,
        admin,
        Ezagent.URI.workspace(:system)
      )

    assert Enum.any?(candidates, &(&1["uri"] == URI.to_string(invitee)))
  end

  test "member options use agent role name when display falls back to UUID" do
    admin = User.admin_uri()
    short = "world-agent-role-display-#{System.unique_integer([:positive])}"
    role_name = "builder-#{System.unique_integer([:positive])}"

    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(short, admin,
        template_name: "default"
      )

    member_uri =
      "entity://system/agent/#{Ecto.UUID.generate()}"
      |> Ezagent.URI.new!()
      |> register_member()

    assert {:ok, _} =
             join_call(session_uri, member_uri, %{
               role_name: role_name,
               in_session_template: true
             })

    # `session.join` commits before its member-cap delivery/add_self effect is
    # observed.  Wait for that projection instead of racing the async effect
    # (and then tearing the member Kind down while add_self is still queued).
    assert wait_until(fn ->
             ConversationData.member_options(admin, session_uri)
             |> Enum.any?(&(&1["uri"] == URI.to_string(member_uri)))
           end)

    row =
      admin
      |> ConversationData.member_options(session_uri)
      |> Enum.find(&(&1["uri"] == URI.to_string(member_uri)))

    assert row["kind"] == "agent"
    assert row["role_name"] == role_name
    assert row["display_name"] == role_name
  end

  defp create_read_only_user(uri, caps) do
    result =
      case Ezagent.Users.create_read_only(uri, caps) do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{errors: [uri: {"has already been taken", _}]}} -> :ok
      end

    with :ok <- result do
      Ezagent.Entity.spawn_principal(uri)
    end
  end

  defp join_call(session_uri, member_uri, facets) do
    target = Ezagent.URI.with_action(session_uri, :session, :join)
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: Map.put(facets, :member, member_uri),
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp register_member(%URI{} = member_uri) do
    assert {:ok, _pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
               uri: member_uri,
               initial_caps: MapSet.new()
             })

    # Keep the synthetic agent registered through the asynchronous member-cap
    # delivery/add_self round-trip.  Real agents are workspace-bound at create;
    # without the bind this bare test Kind can be reaped before add_self checks
    # KindRegistry under a busy full-suite run.
    assert :ok =
             Ezagent.WorkspaceRegistry.bind(
               member_uri,
               Ezagent.Capability.workspace_of(member_uri)
             )

    on_exit(fn -> Ezagent.Kind.terminate(member_uri) end)
    member_uri
  end

  defp wait_until(fun, retries \\ 100)

  defp wait_until(fun, retries) when retries > 0 do
    case fun.() do
      true ->
        true

      _ ->
        Process.sleep(10)
        wait_until(fun, retries - 1)
    end
  end

  defp wait_until(fun, _retries), do: fun.() == true
end
