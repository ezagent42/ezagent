defmodule Ezagent.PluginCodex.Template.CodexAgentHomeIsolationTest do
  use ExUnit.Case, async: true

  alias Ezagent.PluginCodex.Template.CodexAgent

  defp uniq, do: System.unique_integer([:positive])

  defp source_codex_home do
    dir = Path.join(System.tmp_dir!(), "codex-home-src-#{uniq()}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "auth.json"), ~s/{"token":"source"}/)
    File.write!(Path.join(dir, "config.toml"), "model = \"gpt-5\"\n")
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp target_codex_home(agent_uri) do
    dir = CodexAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "config_dir namespace + materialization" do
    test "declares codex namespace for domain-allocated per-agent CODEX_HOME" do
      assert CodexAgent.config_dir_namespace() == "codex"
      assert Ezagent.Kind.Template.namespace_of(CodexAgent) == "codex"
    end

    test "copies source codex auth/config into the allocated target home" do
      source = source_codex_home()
      agent_uri = URI.new!("entity://system/agent/codex_home-#{uniq()}")
      target = target_codex_home(agent_uri)

      tmpl = %{
        "config_dir" => source,
        "allocated_config_dir" => target
      }

      assert {:ok, ^target} = CodexAgent.create_agent_config_dir(agent_uri, tmpl)

      assert File.read!(Path.join(target, "auth.json")) == ~s/{"token":"source"}/
      assert File.read!(Path.join(target, "config.toml")) == "model = \"gpt-5\"\n"

      {:ok, stat} = File.stat(Path.join(target, "auth.json"))
      assert Bitwise.band(stat.mode, 0o777) == 0o600
    end
  end

  describe "CODEX_HOME env wiring" do
    test "all three codex subprocess paths receive the same per-agent CODEX_HOME" do
      agent_uri = URI.new!("entity://system/agent/codex_env-#{uniq()}")
      codex_home = target_codex_home(agent_uri)

      tmpl = %{
        "agent_config_dir" => codex_home,
        "model" => "gpt-5",
        "approval_policy" => "never",
        "sandbox" => "workspace-write"
      }

      assert CodexAgent.resolve_config_home(agent_uri, tmpl) == codex_home
      assert CodexAgent.codex_home_env(agent_uri, tmpl) == %{"CODEX_HOME" => codex_home}

      app_params =
        CodexAgent.build_app_server_params("/work", "/sock/app.sock", "/bin/codex", false, tmpl)

      assert app_params.cmd_env == %{"CODEX_HOME" => codex_home}

      bridge_params =
        CodexAgent.build_bridge_sidecar_params(
          "/work",
          "/sock/app.sock",
          "/sock/thread-id",
          "ws://127.0.0.1:10042/agent_bridge/websocket",
          tmpl,
          "/bin/codex",
          false
        )

      assert bridge_params.cmd_env == %{"CODEX_HOME" => codex_home}

      assert {:ok, pty_params} =
               CodexAgent.build_pty_params_for_env(
                 "/work",
                 "/sock/app.sock",
                 "thread-1",
                 tmpl,
                 "/bin/codex",
                 :dev
               )

      assert pty_params.cmd_env == %{"CODEX_HOME" => codex_home}
    end
  end
end
