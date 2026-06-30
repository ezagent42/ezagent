defmodule EzagentPluginGithub.GhTest do
  @moduledoc """
  纯逻辑单测：`token_env/0`（凭证→GH_TOKEN env）+ `*_args/N`（gh 参数构造）。

  实际 shell out 真 gh / 真 github 是 live e2e（后续步骤），本文件**不打真网、不调 gh**。
  """
  use ExUnit.Case, async: false

  alias EzagentPluginGithub.{Creds, Gh}

  # token_env 读 github.yaml → 沙箱 EZAGENT_HOME 隔离。
  setup do
    tmp = Path.join(System.tmp_dir!(), "esr-gh-tokenenv-#{System.unique_integer([:positive])}")
    System.put_env("EZAGENT_HOME", tmp)
    System.put_env("EZAGENT_PROFILE", "default")

    on_exit(fn ->
      System.delete_env("EZAGENT_HOME")
      System.delete_env("EZAGENT_PROFILE")
      File.rm_rf!(tmp)
    end)

    :ok
  end

  describe "token_env/0" do
    test "配了 token → [{\"GH_TOKEN\", t}]" do
      assert :ok = Creds.write(%{access_token: "ghp_configured"})
      assert Gh.token_env() == [{"GH_TOKEN", "ghp_configured"}]
    end

    test "没配（无文件）→ [] —— 走 gh 自带 auth" do
      assert Gh.token_env() == []
    end
  end

  describe "命令参数构造（纯函数）" do
    test "issue_create_args：gh api POST repos/.../issues + title/body" do
      assert Gh.issue_create_args("o/r", "标题", "正文\n多行") ==
               [
                 "api",
                 "-X",
                 "POST",
                 "repos/o/r/issues",
                 "-f",
                 "title=标题",
                 "-f",
                 "body=正文\n多行"
               ]
    end

    test "comment_args：gh api POST issues/N/comments + body" do
      assert Gh.comment_args("o/r", 42, "评论") ==
               ["api", "-X", "POST", "repos/o/r/issues/42/comments", "-f", "body=评论"]
    end

    test "pull_args：gh api GET pulls/N" do
      assert Gh.pull_args("o/r", 7) == ["api", "repos/o/r/pulls/7"]
    end

    test "status_args：gh api POST statuses/SHA + state/context/description" do
      assert Gh.status_args("o/r", "deadbeef", "failure", "ezagent/ci-gate", "门未过") ==
               [
                 "api",
                 "-X",
                 "POST",
                 "repos/o/r/statuses/deadbeef",
                 "-f",
                 "state=failure",
                 "-f",
                 "context=ezagent/ci-gate",
                 "-f",
                 "description=门未过"
               ]
    end

    test "list_open_prs_args：gh pr list --state open --json ... --limit 100" do
      assert Gh.list_open_prs_args("o/r") ==
               [
                 "pr",
                 "list",
                 "--repo",
                 "o/r",
                 "--state",
                 "open",
                 "--json",
                 "number,headRefName,headRefOid,state",
                 "--limit",
                 "100"
               ]
    end
  end
end
