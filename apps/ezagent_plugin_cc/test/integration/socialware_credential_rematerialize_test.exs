defmodule Ezagent.Integration.SocialwareCredentialRematerializeTest do
  @moduledoc """
  任务 B（handoff 2026-07-16 gaga-agent-runtime §4）—— 补物化路：

  凭证缺失时 install 会 loud-skip 角色（chain C，#1326）；skip 行是 install 时刻
  快照。本测试钉住"凭证就位 → 重跑 install → 角色补物化 + skip 行清掉"的闭环：

    1. 非 admin installer 建会话 → cc 角色 skip（`{:no_credential_source, "cc"}`），
       `unfilled_agent_role_slots` 有 durable 行；
    2. operator 配 workspace-shared 凭证源（生产写入器
       `Ezagent.ActionSet.WorkspaceSharedCredentialSource` 落的同一张表）；
    3. 重跑 `install_session_socialware`（幂等管道）→ 角色进成员表，skip 行清空；
    4. 再跑一次 → 不重复建员（already-joined skip 语义）。

  `mix ezagent.session.reinstall_socialware` 是这条管道的 operator 触发面。
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Credential.WorkspaceSharedSource
  alias Ezagent.Entity.User
  alias EzagentCore.Repo
  alias EzagentDomainInstanceMessage.SessionCreator

  defp uniq, do: System.unique_integer([:positive])

  setup do
    recipe = Module.concat([Ezagent, Orchestrator, OrchestratorRecipe]) |> apply(:recipe, [])
    Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  # A credentialed SOURCE agent home the workspace-shared pointer can copy from:
  # a real config home dir carrying a non-empty `.credentials.json`, addressed
  # by a cc-flavored agent URI in the SAME workspace.
  defp seed_source_agent!(%URI{} = workspace_uri) do
    ws_name = Ezagent.URI.workspace_name!(workspace_uri)
    source_uri = Ezagent.URI.agent(ws_name, "cred-source-#{uniq()}")

    :ok =
      Ezagent.AgentFlavorAttributes.put_from_template_class(
        source_uri,
        Ezagent.PluginCc.Template.CcAgent
      )

    dir =
      Ezagent.Credential.HomeRuntime.agent_config_dir(
        source_uri,
        Ezagent.PluginCc.Template.CcAgent
      )

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, ".credentials.json"),
      Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "test-only-shared-token"}})
    )

    File.write!(Path.join(dir, ".ezagent-config-complete"), "ok\n")
    on_exit(fn -> File.rm_rf(dir) end)

    # The resolver's availability predicate requires the source to EXIST as a
    # persisted Kind (`SnapshotStore.latest/1` — same check the production
    # writer's `validate_source_exists` applies), and the cascade copy resolves
    # the source's config dir via `UriQuery :config_dir` → the snapshot's
    # sandbox slice `:config_dir_path`.
    {:ok, _} =
      Ezagent.SnapshotStore.write(
        URI.to_string(source_uri),
        %{sandbox: %{state: %{config_dir_path: dir}}},
        kind_type: :agent
      )

    source_uri
  end

  defp bind_workspace_shared!(%URI{} = workspace_uri, %URI{} = source_uri) do
    %{
      workspace_uri: URI.to_string(workspace_uri),
      flavor: "cc",
      source_uri: URI.to_string(source_uri),
      set_by: URI.to_string(User.admin_uri())
    }
    |> WorkspaceSharedSource.changeset()
    |> Repo.insert!(
      on_conflict: {:replace, [:source_uri, :set_by, :updated_at]},
      conflict_target: :id
    )
  end

  defp role_member(session_uri, role_name) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        pid
        |> :sys.get_state()
        |> Map.get(:state, %{})
        |> Map.get(Ezagent.ActionSet.Session.state_slice(), %{})
        |> then(&Map.get(&1, :state, &1))
        |> Map.get(:members, %{})
        |> Enum.find_value(fn {uri, meta} ->
          if Map.get(meta, :role_name) == role_name, do: uri
        end)

      :error ->
        nil
    end
  end

  test "credential arrives → reinstall fills the skipped role and clears the durable skip row" do
    ws = Ezagent.URI.workspace(:system)
    installer = Ezagent.URI.user(:system, "rematuser#{uniq()}")
    Ezagent.SpawnRegistry.spawn(installer)

    template_name = "remat-#{uniq()}"
    {:ok, _} = persist_orchestrator_template(template_name)

    {:ok, session_uri, _} =
      SessionCreator.create_session("remat-#{uniq()}", installer,
        workspace_uri: ws,
        template_name: template_name
      )

    # ① 无凭证：角色 loud-skip，skip 行 durable
    assert {:ok, %{satisfied: [], skipped: [%{role_name: "orchestrator"}]}} =
             SessionCreator.install_session_socialware(session_uri)

    assert [%{role_name: "orchestrator", reason: :missing_credentials}] =
             SessionCreator.unfilled_agent_role_slots(session_uri)

    # ② 凭证就位（workspace-shared 源，行与生产写入器同表同形）
    source_uri = seed_source_agent!(ws)
    bind_workspace_shared!(ws, source_uri)

    # ③ 重跑 install → 角色补物化 + skip 行清空
    assert {:ok, %{satisfied: ["orchestrator"], skipped: []}} =
             SessionCreator.install_session_socialware(session_uri)

    assert SessionCreator.unfilled_agent_role_slots(session_uri) == []
    assert role_member(session_uri, "orchestrator")

    # ④ 幂等：再跑不重复建员（already-joined skip 语义，成员 URI 不变）
    member_before = role_member(session_uri, "orchestrator")
    assert {:ok, _} = SessionCreator.install_session_socialware(session_uri)
    assert role_member(session_uri, "orchestrator") == member_before
  end

  test "credential still missing → skip row survives the rerun (no false clear)" do
    ws = Ezagent.URI.workspace(:system)
    installer = Ezagent.URI.user(:system, "stillskip#{uniq()}")
    Ezagent.SpawnRegistry.spawn(installer)

    template_name = "still-#{uniq()}"
    {:ok, _} = persist_orchestrator_template(template_name)

    {:ok, session_uri, _} =
      SessionCreator.create_session("still-#{uniq()}", installer,
        workspace_uri: ws,
        template_name: template_name
      )

    assert {:ok, _} = SessionCreator.install_session_socialware(session_uri)
    assert {:ok, _} = SessionCreator.install_session_socialware(session_uri)

    assert [%{role_name: "orchestrator", reason: :missing_credentials}] =
             SessionCreator.unfilled_agent_role_slots(session_uri)
  end

  # ── template fixture (mirrors chain-C test) ────────────────────────────────

  defp persist_orchestrator_template(name) do
    Ezagent.Entity.SessionTemplate.persist_version_as_system(
      %{
        name: name,
        description: "orchestrator-bearing template (rematerialize regression)",
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
