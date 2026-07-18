defmodule EzagentPluginCc.SdkSidecarEnvTest do
  @moduledoc """
  Pins the sidecar→worker env contract (`SdkSidecar.worker_env/1`) — the middle
  link of the #1323 chain:

      sdk_sidecar_params/2  →  worker_env/1  →  worker resolve_mcp_config
      (elixir params test)     (THIS test)      (python unittest)

  Regression lock for the Task A DoD: a `config_dir` carrying `.mcp.json` must
  reach the worker (`EZAGENT_CC_SDK_CONFIG_DIR`) so its servers appear in the
  SDK options; the process env (`cmd_env` — provider + CLI-identity) must ride
  `EZAGENT_CC_SDK_ENV`.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginCc.SdkSidecar

  defp base_args do
    %{
      cwd: "/tmp/agent-cwd",
      config_dir: "/tmp/agent-cfg",
      session_id: "sess-1",
      permission_mode: "default"
    }
  end

  defp env_map(args) do
    args
    |> SdkSidecar.worker_env()
    |> Map.new(fn {k, v} -> {List.to_string(k), List.to_string(v)} end)
  end

  test "config_dir is exported as EZAGENT_CC_SDK_CONFIG_DIR (worker's .mcp.json anchor)" do
    env = env_map(base_args())

    assert env["EZAGENT_CC_SDK_CONFIG_DIR"] == "/tmp/agent-cfg"
    assert env["EZAGENT_CC_SDK_CWD"] == "/tmp/agent-cwd"
  end

  test "cmd_env rides EZAGENT_CC_SDK_ENV as JSON (provider + CLI identity)" do
    env =
      base_args()
      |> Map.put(:cmd_env, %{"EZAGENT_USER_TOKEN" => "tok", "ANTHROPIC_BASE_URL" => "u"})
      |> env_map()

    assert %{"EZAGENT_USER_TOKEN" => "tok", "ANTHROPIC_BASE_URL" => "u"} =
             Jason.decode!(env["EZAGENT_CC_SDK_ENV"])
  end

  test "explicit mcp_servers still rides EZAGENT_CC_SDK_MCP_SERVERS verbatim" do
    servers = %{"custom" => %{"type" => "stdio", "command" => "x"}}

    env = base_args() |> Map.put(:mcp_servers, servers) |> env_map()

    assert Jason.decode!(env["EZAGENT_CC_SDK_MCP_SERVERS"]) == servers
  end

  test "empty/nil cmd_env and mcp_servers are omitted (worker falls back to config_dir)" do
    env = base_args() |> Map.merge(%{cmd_env: %{}, mcp_servers: nil}) |> env_map()

    refute Map.has_key?(env, "EZAGENT_CC_SDK_ENV")
    refute Map.has_key?(env, "EZAGENT_CC_SDK_MCP_SERVERS")
  end
end
