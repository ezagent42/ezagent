defmodule Ezagent.PluginCc.Template.GitIdentityEnvTest do
  use ExUnit.Case, async: true

  alias Ezagent.PluginCc.Template.SpawnPlan

  @base %{"EZAGENT_AGENT_URI" => "entity://ws/agent/a", "EZAGENT_AGENT_TOKEN" => "t"}

  describe "merge_git_identity_env/2" do
    test "关闭态:env 逐字节不变" do
      assert SpawnPlan.merge_git_identity_env(@base, {:ok, :none}) == @base
    end

    test "错误态:env 逐字节不变(配错不能连带改变 agent 的其它 env)" do
      assert SpawnPlan.merge_git_identity_env(@base, {:error, :owner_has_no_key}) == @base
      assert SpawnPlan.merge_git_identity_env(@base, {:error, :known_hosts_unconfigured}) == @base
    end

    test "开启态:恰好多出 GIT_SSH_COMMAND,其余不变" do
      merged =
        SpawnPlan.merge_git_identity_env(@base, {:ok, %{"GIT_SSH_COMMAND" => "ssh -i /k"}})

      assert merged == Map.put(@base, "GIT_SSH_COMMAND", "ssh -i /k")
    end

    test "不覆盖已有的 GIT_SSH_COMMAND 以外的键" do
      base = Map.put(@base, "GIT_SSH_COMMAND", "ssh -i /old")

      merged =
        SpawnPlan.merge_git_identity_env(base, {:ok, %{"GIT_SSH_COMMAND" => "ssh -i /new"}})

      assert merged["GIT_SSH_COMMAND"] == "ssh -i /new"
      assert Map.delete(merged, "GIT_SSH_COMMAND") == Map.delete(base, "GIT_SSH_COMMAND")
    end
  end
end
