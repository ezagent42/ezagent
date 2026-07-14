defmodule EzagentDomainWorkspace.Architecture.WorkspaceAgentCreateSelfStoreTest do
  @moduledoc """
  S7 cold-agent lock: the workspace agent-create lane may ISSUE authority and
  hand artifacts to the grantee's self-store cast, but may never drive a
  blocking grant into the freshly-created agent.
  """
  use ExUnit.Case, async: true

  test "grant_initial_caps is issue-all then absorb-all with no legacy driver" do
    source = source!("apps/ezagent_domain_workspace/lib/ezagent/workspace.ex")

    [_, grant_section] = String.split(source, "def grant_initial_caps(_agent_uri", parts: 2)
    [grant_section | _] = String.split(grant_section, "def grant_creator_manage_cap", parts: 2)

    assert grant_section =~ "Ezagent.Cap.issue("
    assert grant_section =~ "Ezagent.Identity.absorb_cap("
    assert ordered?(grant_section, "<- issue_initial_caps(", "<- absorb_initial_caps(")

    refute grant_section =~ "Identity.Grant"
    refute grant_section =~ "Invocation.dispatch"
    refute grant_section =~ "Router.dispatch"
    refute grant_section =~ "mode: :call"
    refute grant_section =~ "await_ready"
    refute grant_section =~ "ReadyGate.await"
  end

  test "all workspace cold-agent callers delegate to the non-blocking helper" do
    callers = [
      {"apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create/role_step.ex",
       "Ezagent.Workspace.grant_initial_caps("},
      {"apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex",
       "Ezagent.Workspace.issue_and_absorb_initial_caps("},
      {"apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex",
       "Ezagent.Workspace.grant_initial_caps("}
    ]

    Enum.each(callers, fn {relative, helper_call} ->
      source = source!(relative)

      assert source =~ helper_call,
             "#{relative} must use the S7 workspace hand-off"

      refute source =~ "Ezagent.Identity.Grant.grant_cap("
      refute source =~ "?action=identity.grant_cap"
    end)
  end

  test "the short-lived create CLI awaits exact self-store commit before success" do
    source =
      source!("apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.create.ex")

    [_, create_body] = String.split(source, "defp do_create", parts: 2)
    [create_body | _] = String.split(create_body, "defp operator_admin_ctx", parts: 2)

    assert create_body =~ "Ezagent.Workspace.issue_and_absorb_initial_caps("

    assert ordered?(
             create_body,
             "<-\n           Ezagent.Workspace.issue_and_absorb_initial_caps(",
             "<-\n           Ezagent.Identity.CapAbsorbAwait.await_exact("
           )

    await_source =
      source!("apps/ezagent_domain_identity/lib/ezagent/identity/cap_absorb_await.ex")

    assert await_source =~ "Ezagent.EntityCaps.load(entity_uri)"
    assert await_source =~ "{:absorb_not_committed, missing}"
  end

  defp ordered?(source, first, second) do
    case {:binary.match(source, first), :binary.match(source, second)} do
      {{first_at, _}, {second_at, _}} -> first_at < second_at
      _ -> false
    end
  end

  defp source!(relative), do: repo_root() |> Path.join(relative) |> File.read!()

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
