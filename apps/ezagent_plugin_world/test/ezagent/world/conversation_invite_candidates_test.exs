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
             session_uri
             |> ConversationData.member_options()
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
             session_uri
             |> ConversationData.member_options()
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

    row =
      session_uri
      |> ConversationData.member_options()
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
    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
      mode: :call,
      args: Map.put(facets, :member, member_uri),
      ctx: %{
        caller: User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp register_member(%URI{} = member_uri) do
    test_pid = self()

    pid =
      spawn(fn ->
        :ok = Ezagent.KindRegistry.put_new(member_uri)
        send(test_pid, {:registered, member_uri})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^member_uri}, 1_000
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :stop) end)
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
