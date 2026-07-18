defmodule EzagentDomainInstanceMessage.UnfilledRoleSlotReasonTest do
  @moduledoc """
  任务 B DoD-3 —— skip 行的结构化 reason 必须区分三类，供 UI/operator 决策：

    * `:missing_credentials`         — 文件型凭证（cc 的 .credentials.json）无源可解
    * `:missing_provider_credential` — 环境型凭证（provider key）不可用
      （#1449 cc-custom 的 per-profile key 缺失同走此类）
    * `:unavailable`                 — 其他失败（不该被误读成"配凭证就能修"）
  """
  use EzagentCore.DataCase, async: false

  alias EzagentDomainInstanceMessage.SessionCreator

  defp uniq, do: System.unique_integer([:positive])

  defp session! do
    installer = Ezagent.URI.user(:system, "reasonuser#{uniq()}")
    Ezagent.SpawnRegistry.spawn(installer)

    {:ok, session_uri, _} =
      SessionCreator.create_session("reason-#{uniq()}", installer,
        workspace_uri: Ezagent.URI.workspace(:system),
        template_name: "default"
      )

    session_uri
  end

  test "no_credential_source / config_home_without_credentials → :missing_credentials" do
    session_uri = session!()

    :ok =
      SessionCreator.record_unfilled_role_slots(session_uri, [
        %{role_name: "a", reason: {:no_credential_source, "cc"}},
        %{role_name: "b", reason: {:config_home_without_credentials, "cc"}}
      ])

    assert [
             %{role_name: "a", reason: :missing_credentials},
             %{role_name: "b", reason: :missing_credentials}
           ] = SessionCreator.unfilled_agent_role_slots(session_uri)
  end

  test "credential_unavailable (env-backed provider key) → :missing_provider_credential" do
    session_uri = session!()

    :ok =
      SessionCreator.record_unfilled_role_slots(session_uri, [
        %{role_name: "c", reason: {:credential_unavailable, "cc-deepseek"}}
      ])

    assert [%{role_name: "c", reason: :missing_provider_credential}] =
             SessionCreator.unfilled_agent_role_slots(session_uri)
  end

  test "anything else stays :unavailable (not mistakable for a credential fix)" do
    session_uri = session!()

    :ok =
      SessionCreator.record_unfilled_role_slots(session_uri, [
        %{role_name: "d", reason: {:agent_spawn_failed, :boom}}
      ])

    assert [%{role_name: "d", reason: :unavailable}] =
             SessionCreator.unfilled_agent_role_slots(session_uri)
  end
end
