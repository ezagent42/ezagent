defmodule Ezagent.CapSigningNotailInvestigationTest do
  @moduledoc """
  Opt-in, real-data investigation for the 2026-07-14 no-tail signing upgrade.

  The suite is intentionally excluded from ordinary test runs because its
  fixture is the isolated canary dump described in the handoff. Run it against
  a throwaway clone of that dump with `CAP_SIGNING_INVESTIGATION=1`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot

  @moduletag :cap_signing_investigation
  @moduletag skip:
               if(System.get_env("CAP_SIGNING_INVESTIGATION") == "1",
                 do: false,
                 else: "requires the isolated canary database clone"
               )

  test "normal lifecycle paths expose signed and bypassed cap classes" do
    before = inventory()
    started = start_reactivation_apps!()
    on_exit(fn -> Enum.each(Enum.reverse(started), &Application.stop/1) end)
    after_reactivation = inventory()

    assert logical_inventory(before) == logical_inventory(after_reactivation)

    suffix = System.unique_integer([:positive])
    admin = Ezagent.Entity.User.admin_uri()
    agent_uri = Ezagent.URI.new!("entity://system/agent/py_cap_signing_#{suffix}")

    recipe_proposal =
      Capability.cap(
        :agent,
        Ezagent.ActionSet.Sandbox,
        :read,
        Ezagent.URI.instance(agent_uri),
        Capability.workspace_of(agent_uri)
      )

    assert {:ok, _binding} =
             Ezagent.Identity.RecipeCapBinding.issue_and_upsert(
               agent_uri,
               "cap-signing-investigation",
               admin,
               [recipe_proposal]
             )

    assert {:ok, agent_state} = Ezagent.ActionSet.Identity.create(%{uri: agent_uri})
    agent_create = state_inventory(agent_state)

    assert {:ok, %{}} =
             Ezagent.ActionSet.Identity.activate(agent_state, %{self_uri: agent_uri})

    agent_activate = state_inventory(agent_state)

    assert agent_create == agent_activate

    assert agent_create == [
             {:agent, Ezagent.ActionSet.ConfigEvolve, :reconcile_cascade, :uri, false},
             {:agent, Ezagent.ActionSet.Identity, :list_caps, :uri, false},
             {:agent, Ezagent.ActionSet.Sandbox, :read, :uri, true},
             {:agent, Ezagent.ActionSet.Sandbox, :update_config, :uri, false}
           ]

    user_uri = Ezagent.URI.new!("entity://system/user/cap-signing-#{suffix}")

    raw_user_cap = %Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: :send,
      instance: :any,
      workspace_uri: Ezagent.URI.workspace(:system),
      granted_by: admin,
      granted_at: DateTime.utc_now()
    }

    assert {:ok, _user} = Ezagent.Users.create(user_uri, nil, [raw_user_cap])
    assert {:ok, _pid} = Ezagent.SpawnRegistry.spawn(user_uri)
    assert :ok = Ezagent.ReadyGate.await(user_uri, 5_000)

    assert holder_inventory(user_uri) == [
             {:snapshot, :session, Ezagent.ActionSet.Session, :send, :any, false},
             {:snapshot, :user, Ezagent.ActionSet.Identity, :list_caps, :uri, false},
             {:users, :session, Ezagent.ActionSet.Session, :send, :any, false}
           ]

    workspace_name = "cap-signing-#{suffix}"
    assert {:ok, _pid} = Ezagent.Workspace.create(workspace_name, %{})
    workspace_uri = Ezagent.URI.workspace(workspace_name)
    admin_ctx = %{caller: admin, caps: MapSet.new([Capability.admin_genesis_cap()])}

    issued_user_uri = Ezagent.URI.new!("entity://#{workspace_name}/user/issued-#{suffix}")

    assert {:ok, %{caps_granted: 1}} =
             Ezagent.Workspace.create_user(
               workspace_uri,
               %{
                 user_uri: URI.to_string(issued_user_uri),
                 password: "cap-signing-investigation",
                 caps: "*"
               },
               admin_ctx
             )

    assert holder_inventory(issued_user_uri) == [
             {:snapshot, :any, :any, :any, :any, true},
             {:snapshot, :user, Ezagent.ActionSet.Identity, :list_caps, :uri, false},
             {:users, :any, :any, :any, :any, true}
           ]

    assert {:ok, %{agent_uri: materialized_agent_uri}} =
             Ezagent.Workspace.create_agent(
               workspace_uri,
               %{flavor: "curl", name: "worker", cwd: "", with_pty: false},
               admin_ctx
             )

    materialized_agent = holder_inventory(materialized_agent_uri)
    admin_before_session = holder_inventory(admin)

    assert materialized_agent == [
             {:snapshot, :agent, Ezagent.ActionSet.ConfigEvolve, :reconcile_cascade, :uri, false},
             {:snapshot, :agent, Ezagent.ActionSet.Identity, :list_caps, :uri, false},
             {:snapshot, :agent, Ezagent.ActionSet.Sandbox, :update_config, :uri, false}
           ]

    assert has_cap?(admin_before_session, :agent, Ezagent.ActionSet.Manage, :any, true)
    assert has_cap?(admin_before_session, :agent, Ezagent.ActionSet.Sandbox, :destroy, true)

    assert has_cap?(
             admin_before_session,
             :agent,
             Ezagent.ActionSet.Terminable,
             :terminate,
             true
           )

    assert has_cap?(admin_before_session, :any, :any, :any, false)

    admin_before_template = holder_inventory(admin)

    assert {:ok, template_uri} =
             Ezagent.Entity.SessionTemplate.create(
               "cap-signing-#{suffix}",
               %{description: "cap-signing investigation"},
               caps: [Capability.admin_genesis_cap()],
               caller: admin,
               owner: admin,
               workspace: "system"
             )

    admin_after_template = holder_inventory(admin)

    assert cap_count(
             admin_after_template,
             :session_template,
             Ezagent.ActionSet.Template,
             :any,
             true
           ) ==
             cap_count(
               admin_before_template,
               :session_template,
               Ezagent.ActionSet.Template,
               :any,
               true
             ) + 1

    assert holder_inventory(template_uri) == [
             {:snapshot, :user, Ezagent.ActionSet.Identity, :list_caps, :uri, false}
           ]

    admin_before_session = holder_inventory(admin)

    assert {:ok, session_uri, _meta} =
             EzagentDomainInstanceMessage.SessionCreator.create_session(
               "cap-signing-#{suffix}",
               admin,
               template_name: "default"
             )

    admin_after_session = holder_inventory(admin)

    for action <- [:assign_role, :receive, :remove_participant] do
      assert cap_count(admin_after_session, :session, Ezagent.ActionSet.Session, action, true) ==
               cap_count(admin_before_session, :session, Ezagent.ActionSet.Session, action, true) +
                 1
    end

    inventory_before_session_rehydrate = inventory()
    assert {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

    assert :ok =
             DynamicSupervisor.terminate_child(
               EzagentDomainInstanceMessage.SessionSupervisor,
               session_pid
             )

    wait_until(fn -> Ezagent.KindRegistry.lookup(session_uri) == :error end)
    assert {:ok, :rehydrated} = Ezagent.SpawnRegistry.ensure_live(session_uri)
    assert :ok = Ezagent.ReadyGate.await(session_uri, 5_000)
    assert inventory() == inventory_before_session_rehydrate
  end

  defp start_reactivation_apps! do
    Enum.flat_map([:ezagent_plugin_curl_agent, :ezagent_plugin_py, :ezagent_plugin_cc], fn app ->
      {:ok, started} = Application.ensure_all_started(app)
      started
    end)
    |> Enum.uniq()
  end

  defp inventory do
    durable_candidates()
    |> Enum.group_by(&class_key/1)
    |> Enum.map(fn {class, candidates} -> {class, length(candidates)} end)
    |> Enum.sort()
  end

  defp logical_inventory(entries) do
    Enum.map(entries, fn entry -> Tuple.delete_at(entry, tuple_size(entry) - 1) end)
  end

  defp holder_inventory(holder) do
    durable_candidates()
    |> Enum.filter(&(&1.holder == holder))
    |> Enum.map(fn %{home: home, cap: cap} ->
      {home, cap.kind, cap.behavior, Capability.action_of(cap), instance_shape(cap.instance),
       signed?(cap)}
    end)
    |> Enum.sort()
  end

  defp state_inventory(%{caps: caps}) do
    caps
    |> Enum.map(fn cap ->
      {cap.kind, cap.behavior, Capability.action_of(cap), instance_shape(cap.instance),
       signed?(cap)}
    end)
    |> Enum.sort()
  end

  defp has_cap?(inventory, kind, behavior, action, signed?) do
    Enum.any?(inventory, fn
      {_home, ^kind, ^behavior, ^action, _instance, ^signed?} -> true
      _other -> false
    end)
  end

  defp cap_count(inventory, kind, behavior, action, signed?) do
    Enum.count(inventory, fn
      {_home, ^kind, ^behavior, ^action, _instance, ^signed?} -> true
      _other -> false
    end)
  end

  defp durable_candidates do
    user_candidates =
      Ezagent.Users.list_all()
      |> Enum.flat_map(fn %{uri: holder, caps: caps} ->
        candidates_from_caps(:users, holder, caps)
      end)

    snapshot_candidates =
      KindSnapshot.list_all()
      |> Enum.flat_map(fn %KindSnapshot{uri: uri} = snapshot ->
        with {:ok, holder} <- parse_uri(uri),
             {:ok, state} <- KindSnapshot.decode_state(snapshot) do
          candidates_from_caps(:snapshot, holder, identity_caps(state))
        else
          _ -> []
        end
      end)

    user_candidates ++ snapshot_candidates
  end

  defp candidates_from_caps(home, holder, caps) when is_list(caps) or is_struct(caps, MapSet) do
    Enum.flat_map(caps, fn
      %Capability{} = cap -> [%{home: home, holder: holder, cap: cap}]
      _other -> []
    end)
  end

  defp identity_caps(%{identity: %{state: %{caps: caps}}}), do: cap_list(caps)
  defp identity_caps(%{identity: %{caps: caps}}), do: cap_list(caps)
  defp identity_caps(_state), do: []

  defp cap_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp cap_list(caps) when is_list(caps), do: caps
  defp cap_list(_caps), do: []

  defp class_key(%{home: home, holder: holder, cap: cap}) do
    {
      home,
      holder_kind(holder),
      cap.kind,
      cap.behavior,
      Capability.action_of(cap),
      instance_shape(cap.instance),
      signed?(cap)
    }
  end

  defp holder_kind(%URI{scheme: "entity"} = holder) do
    if Ezagent.URI.type?(holder, :agent), do: :agent, else: :user
  end

  defp holder_kind(%URI{scheme: scheme}), do: scheme

  defp instance_shape(:any), do: :any
  defp instance_shape(%URI{}), do: :uri
  defp instance_shape({tag, %URI{}}), do: tag
  defp instance_shape(other), do: {:other, inspect(other)}

  defp signed?(%Capability{signature: signature, key_id: key_id, grantee_uri: %URI{}}),
    do: is_binary(signature) and is_binary(key_id)

  defp signed?(_cap), do: false

  defp parse_uri(uri) when is_binary(uri) do
    {:ok, Ezagent.URI.new!(uri)}
  rescue
    ArgumentError -> :error
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(_fun, 0), do: flunk("condition not met before timeout")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end
end
