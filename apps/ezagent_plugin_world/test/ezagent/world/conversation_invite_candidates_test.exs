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
