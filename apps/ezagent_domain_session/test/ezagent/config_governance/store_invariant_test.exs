defmodule Ezagent.ConfigGovernance.StoreInvariantTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{CreatorGrant, Invocation}
  alias Ezagent.ConfigGovernance.Store
  alias Ezagent.Entity.Agent
  alias Ezagent.ConfigGovernance.Socialware, as: SocialwareGovernance

  @agent_key "agent.soul"
  @owner Ezagent.URI.new!("entity://team-alpha/user/owner")
  @workspace Ezagent.URI.new!("workspace://team-alpha")

  test "agent and socialware publish paths land change requests in the shared governance store" do
    agent = Ezagent.URI.entity(:team_alpha, :agent, "store-invariant-#{uniq()}")
    workspace = Ezagent.Capability.workspace_of(agent)
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: MapSet.new()})
    :ok = Ezagent.WorkspaceRegistry.bind(agent, workspace)

    manager = grant_manage_cap(agent, workspace)
    {:ok, %{cr_id: agent_cr_id}} = dispatch(agent, :open_cr, %{}, manager)

    {:ok, _} =
      dispatch(
        agent,
        :stage_item,
        %{change_request_id: agent_cr_id, key: @agent_key, patch: %{"tone" => "direct"}},
        manager
      )

    assert {:ok, %{status: "published"}} =
             dispatch(agent, :publish_cr, %{change_request_id: agent_cr_id}, manager)

    socialware_name = "store-invariant-socialware-#{uniq()}"
    ctx = socialware_owner_ctx(socialware_name)

    assert {:ok, %{cr_id: socialware_cr_id}} =
             SocialwareGovernance.open_cr(%{name: socialware_name}, ctx)

    assert {:ok, _} =
             SocialwareGovernance.stage_definition(
               socialware_cr_id,
               socialware_definition(socialware_name),
               ctx
             )

    assert {:ok, %{status: "published"}} =
             SocialwareGovernance.publish_cr(socialware_cr_id, ctx)

    assert {:ok, %{status: "published", subject_uri: agent_subject}} = Store.fetch(agent_cr_id)

    assert {:ok, %{status: "published", subject_uri: socialware_subject}} =
             Store.fetch(socialware_cr_id)

    assert agent_subject == URI.to_string(agent)
    assert socialware_subject == "socialware:#{socialware_name}"
    assert [%{key: @agent_key}] = Store.items(agent_cr_id)
    assert [%{key: "socialware"}] = Store.items(socialware_cr_id)
  end

  defp dispatch(agent, action, args, principal) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(agent)}?action=config_governance.#{action}"),
      mode: :call,
      args: args,
      ctx: %{caller: principal.uri, caps: principal.caps, reply: {:caller_inbox, self()}}
    })
  end

  defp grant_manage_cap(agent, workspace) do
    manager = Ezagent.URI.entity(:team_alpha, :user, "mgr-#{uniq()}")
    cap = CreatorGrant.manage_cap(:agent, agent, workspace, manager)
    %{uri: manager, caps: MapSet.new([cap])}
  end

  defp socialware_owner_ctx(name) do
    %{
      caller: @owner,
      workspace_uri: @workspace,
      caps: MapSet.new([SocialwareGovernance.manage_cap(name, @workspace, @owner)])
    }
  end

  defp socialware_definition(name) do
    %{
      name: name,
      title: "Store invariant #{name}",
      bases: [Ezagent.ActionSet.Session],
      shape: [],
      visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
    }
  end

  defp uniq, do: System.unique_integer([:positive])
end
