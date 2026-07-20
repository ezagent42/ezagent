defmodule Ezagent.PluginCodex.Template.CodexUnifiedCreateConfigTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Workspace
  alias Ezagent.Workspace.Store

  defmodule FlavorConfigSpawnFacade do
    @moduledoc false

    def spawn_from_template_content(content, agent_uri, _caller, _workspace_uri, _opts) do
      case Ezagent.Entity.AgentTemplate.to_template_data(content, agent_uri) do
        {:ok, data} ->
          send(test_pid(), {:codex_flavor_config_spawn, content, data})
          {:ok, %{fresh?: true}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp test_pid do
      Application.fetch_env!(:ezagent_domain_workspace, :agent_create_flavor_config_test_pid)
    end
  end

  setup do
    {:ok, _apps} = Application.ensure_all_started(:ezagent_domain_session)
    cwd = System.tmp_dir!()
    previous_allowed_roots = System.get_env("EZAGENT_ALLOWED_CWD_ROOTS")
    System.put_env("EZAGENT_ALLOWED_CWD_ROOTS", cwd)

    case EzagentDomainInstanceMessage.UriQueryResolvers.register() do
      :ok -> :ok
      {:error, {:already_registered, _attr}} -> :ok
    end

    previous = Application.get_env(:ezagent_domain_workspace, :agent_spawn_facade)

    previous_pid =
      Application.get_env(:ezagent_domain_workspace, :agent_create_flavor_config_test_pid)

    Application.put_env(
      :ezagent_domain_workspace,
      :agent_spawn_facade,
      FlavorConfigSpawnFacade
    )

    Application.put_env(:ezagent_domain_workspace, :agent_create_flavor_config_test_pid, self())

    on_exit(fn ->
      restore_env(:agent_spawn_facade, previous)
      restore_env(:agent_create_flavor_config_test_pid, previous_pid)
      restore_system_env("EZAGENT_ALLOWED_CWD_ROOTS", previous_allowed_roots)
    end)

    ws_name = "codex-create-config-#{System.unique_integer([:positive])}"
    {:ok, _ws_pid} = Workspace.create(ws_name, %{})
    workspace_uri = URI.new!("workspace://#{ws_name}")

    admin_ctx = Ezagent.Test.CapHelper.signed_workspace_ctx!(workspace_uri, User.admin_uri())

    {:ok, ws_name: ws_name, workspace_uri: workspace_uri, admin_ctx: admin_ctx, cwd: cwd}
  end

  test "Workspace.create_agent carries codex config into content and respawn data", %{
    ws_name: ws_name,
    workspace_uri: workspace_uri,
    admin_ctx: admin_ctx,
    cwd: cwd
  } do
    name = "codex-config-#{System.unique_integer([:positive])}"

    assert {:ok, %{agent_uri: _agent_uri, template_name: tmpl_name}} =
             Workspace.create_agent(
               workspace_uri,
               %{
                 flavor: "codex",
                 name: name,
                 cwd: cwd,
                 with_pty: false,
                 flavor_config: %{
                   "model" => "gpt-5",
                   "approval_policy" => "never",
                   "sandbox" => "read-only"
                 }
               },
               admin_ctx
             )

    assert_receive {:codex_flavor_config_spawn, content, data}

    expected = %{
      "model" => "gpt-5",
      "approval_policy" => "never",
      "sandbox" => "read-only"
    }

    assert Map.take(content, Map.keys(expected)) == expected
    assert Map.take(data, Map.keys(expected)) == expected

    %{session_templates: tmpls} = Store.get_by_name(ws_name)
    assert Map.take(Map.fetch!(tmpls, tmpl_name), Map.keys(expected)) == expected
  end

  test "invalid codex enum config fails closed through the Template Class validator", %{
    workspace_uri: workspace_uri,
    admin_ctx: admin_ctx,
    cwd: cwd
  } do
    assert {:error,
            {:cascade_spawn_failed,
             {:invalid_template_data, {:invalid_enum_field, "sandbox", "root"}}}} =
             Workspace.create_agent(
               workspace_uri,
               %{
                 flavor: "codex",
                 name: "codex-invalid-#{System.unique_integer([:positive])}",
                 cwd: cwd,
                 with_pty: false,
                 flavor_config: %{"sandbox" => "root"}
               },
               admin_ctx
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:ezagent_domain_workspace, key)
  defp restore_env(key, value), do: Application.put_env(:ezagent_domain_workspace, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
