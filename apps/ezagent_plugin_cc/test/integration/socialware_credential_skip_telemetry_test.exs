defmodule Ezagent.Integration.SocialwareCredentialSkipTelemetryTest do
  @moduledoc """
  任务 B（handoff 2026-07-16 gaga-agent-runtime §4）—— skip 可观测 DoD-3：
  skip 事件发射 telemetry，reason 区分 "no credential source" vs "env credential
  unavailable"。已有 definition_agents.ex:197 的 telemetry emit；本测试钉住
  事件及其 metadata 可被 handler 捕获。
  """
  use EzagentCore.DataCase, async: false

  alias EzagentDomainInstanceMessage.SessionCreator

  defp uniq, do: System.unique_integer([:positive])

  setup do
    recipe = Module.concat([Ezagent, Orchestrator, OrchestratorRecipe]) |> apply(:recipe, [])
    Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    _ = Ezagent.SpawnRegistry.spawn(Ezagent.Entity.User.admin_uri())
    :ok
  end

  test "skip event carries role_name + structured reason via telemetry" do
    test_pid = self()
    template_name = "sk-tel-#{uniq()}"
    installer = Ezagent.URI.user(:system, "teluser#{uniq()}")
    Ezagent.SpawnRegistry.spawn(installer)

    {:ok, _} = persist_orchestrator_template(template_name)

    {:ok, session_uri, _} =
      SessionCreator.create_session("tel-#{uniq()}", installer,
        workspace_uri: Ezagent.URI.workspace(:system),
        template_name: template_name
      )

    # `[:ezagent, :socialware, :definition_agents, :skipped]` is the production
    # emit (definition_agents.ex @telemetry_prefix ++ [:skipped]) — attach and
    # capture without changing production code.
    handler_id = "task-b-skip-handler-#{uniq()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:ezagent, :socialware, :definition_agents, :skipped],
        fn event_name, _measurements, metadata, _config ->
          send(test_pid, {:skip_event, event_name, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _} = SessionCreator.install_session_socialware(session_uri)

    assert_receive {:skip_event, [:ezagent, :socialware, :definition_agents, :skipped],
                    %{
                      session_uri: ^session_uri,
                      role_name: "orchestrator",
                      reason: {:no_credential_source, "cc"}
                    }},
                   1_000,
                   "the skip must fire telemetry identifying the role + the RAW reason"
  end

  # ── template fixture (mirrors chain-C test) ────────────────────────────────

  defp persist_orchestrator_template(name) do
    Ezagent.Entity.SessionTemplate.persist_version_as_system(
      %{
        name: name,
        description: "orchestrator-bearing template (telemetry regression)",
        members: [],
        prompt_templates: %{},
        installs: [
          "chat",
          %{
            ref: "orchestrator",
            config: %{role_slots: [%{role_name: "orchestrator", flavor: "cc"}]}
          }
        ],
        legends: %{},
        routing_rules: [],
        default_workspace_uri: Ezagent.URI.workspace(:system),
        parent_template_uri: nil,
        version_tag: nil,
        created_by: nil,
        created_at: nil
      },
      "system"
    )
  end
end
