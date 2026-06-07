defmodule EzagentDomainSocialware.Integration.ConfigUpdateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.ConfigStore

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "config-update-#{System.unique_integer([:positive])}"
    )
  end

  defp agent_uri do
    Ezagent.URI.entity(
      :team_alpha,
      :agent,
      "advisor-config-#{System.unique_integer([:positive])}"
    )
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    agent = agent_uri()
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    {:ok, seed} =
      ConfigStore.write_and_point(%{
        layer: :workspace,
        workspace_uri: workspace,
        subject_uri: agent,
        key: "advisor.behavior",
        body: %{"tone" => "neutral", "cta" => "compare"},
        actor_uri: User.admin_uri(),
        source_turn_id: "seed"
      })

    %{session: session, workspace: workspace, agent: agent, seed: seed}
  end

  test "immutable config changes via settled turn and rollback repoints deterministically", ctx do
    before = ConfigStore.resolve!(:workspace, ctx.workspace, ctx.agent, "advisor.behavior")

    assert before.id == ctx.seed.config_id
    assert before.body == %{"tone" => "neutral", "cta" => "compare"}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{
                   kind: :config_delta,
                   layer: :workspace,
                   workspace_uri: ctx.workspace,
                   subject_uri: ctx.agent,
                   key: "advisor.behavior",
                   patch: %{"tone" => "decisive"}
                 }
               ]
             })

    assert {:ok, %{status: :awaiting_human}} =
             dispatch(ctx.session, :turn, :claim, %{turn_id: turn_id, by: User.admin_uri()})

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    changed =
      wait_for_config(ctx.workspace, ctx.agent, "advisor.behavior", fn config ->
        config.body["tone"] == "decisive"
      end)

    assert changed.id != before.id
    assert changed.body == %{"tone" => "decisive", "cta" => "compare"}
    assert ConfigStore.get!(before.id).body == before.body

    assert {:ok, %{config_id: prior_id}} =
             dispatch(ctx.session, :config_update, :repoint, %{
               layer: :workspace,
               workspace_uri: ctx.workspace,
               subject_uri: ctx.agent,
               key: "advisor.behavior",
               config_id: before.id
             })

    assert prior_id == before.id

    assert ConfigStore.resolve!(:workspace, ctx.workspace, ctx.agent, "advisor.behavior").body ==
             before.body

    restart_session(ctx.session)

    assert ConfigStore.resolve!(:workspace, ctx.workspace, ctx.agent, "advisor.behavior").body ==
             before.body
  end

  test "two writes retain two distinct immutable config objects", ctx do
    {:ok, first} =
      ConfigStore.write_config(%{
        workspace_uri: ctx.workspace,
        subject_uri: ctx.agent,
        key: "advisor.behavior",
        body: %{"tone" => "first"},
        actor_uri: User.admin_uri(),
        source_turn_id: "manual-1"
      })

    {:ok, second} =
      ConfigStore.write_config(%{
        workspace_uri: ctx.workspace,
        subject_uri: ctx.agent,
        key: "advisor.behavior",
        body: %{"tone" => "second"},
        actor_uri: User.admin_uri(),
        source_turn_id: "manual-2"
      })

    assert first.id != second.id
    assert ConfigStore.get!(first.id).body == %{"tone" => "first"}
    assert ConfigStore.get!(second.id).body == %{"tone" => "second"}
  end

  defp wait_for_config(workspace_uri, subject_uri, key, predicate, attempts \\ 100)

  defp wait_for_config(_workspace_uri, _subject_uri, _key, _predicate, 0),
    do: flunk("config never changed")

  defp wait_for_config(workspace_uri, subject_uri, key, predicate, attempts) do
    config = ConfigStore.resolve!(:workspace, workspace_uri, subject_uri, key)

    if predicate.(config) do
      config
    else
      Process.sleep(20)
      wait_for_config(workspace_uri, subject_uri, key, predicate, attempts - 1)
    end
  end

  defp restart_session(session_uri) do
    {:ok, pid} = Ezagent.KindRegistry.lookup(session_uri)

    :ok =
      DynamicSupervisor.terminate_child(EzagentDomainSocialware.SocialwareSessionSupervisor, pid)

    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session_uri})
    :ok
  end
end
