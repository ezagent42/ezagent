defmodule EzagentPluginGitWorkflow.GitHubLiveTest do
  @moduledoc """
  §8 主场景，打真实 GitHub。跑法与前提见
  `EzagentPluginGitWorkflow.GitHubLiveCase`。

  故障路径与 §6.2 的窗口在 `github_live_fault_test.exs`。
  """

  use EzagentPluginGitWorkflow.GitHubLiveCase

  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowRun

  describe "§8 主场景" do
    test "一条主干跑通，重跑不产生第二个 ref/commit/PR", ctx do
      %{creds: creds, run: run, head_ref: head_ref, mirror: mirror} = ctx

      facts = to_pr_open!(ctx)
      first_pass = observed()

      # base 必须是 GitHub 上 main 的真实 head —— 镜像是它的忠实副本。
      assert facts.expected_base_sha == mirror.head_sha
      assert facts.deterministic_head_ref == head_ref
      assert is_binary(facts.change_request_id)
      assert is_binary(facts.head_sha)

      first_pr = facts.change_request_id
      first_commit = facts.head_sha

      # ---- 断言 3/4/5：远端**实际**状态，不是我们记了什么 ----
      assert {:ok, remote_ref} = gh_get(creds, "/git/ref/heads/#{head_ref}")
      assert remote_ref["object"]["sha"] == first_commit

      assert {:ok, remote_commit} = gh_get(creds, "/git/commits/#{first_commit}")
      assert hd(remote_commit["parents"])["sha"] == mirror.head_sha

      # §6.1 让重试产出同一个 sha 的全部依据：GitHub 认不认 run.inserted_at 作为
      # author date。替身此前只是「我们说它认」。
      {:ok, persisted_run} = Store.read_run(run.id)

      assert remote_commit["author"]["date"] ==
               persisted_run.inserted_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      # ---- 断言 7：一次 adapter callback 一个 token ----
      # 到 pr_open 为止只有 create_change_request 这一个 callback 碰了 provider
      # （provision 与 collect 是本地的），所以恰好一次铸造。
      assert token_mints(first_pass) == 1,
             "第一遍铸了 #{token_mints(first_pass)} 个 token，一次 callback 应当只铸 1 个"

      # ---- observation：回读真实 PR / checks / reviews ----
      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)
      obs_pass = observed()

      observed_facts = facts!(run.id)
      assert observed_facts.change_request_state == "open"
      assert observed_facts.checks_revision == 1

      # observation 是三个 callback（read / checks / reviews），三次铸造。
      assert token_mints(obs_pass) == 3

      # 且一个变更请求都不发 —— §6.3「重复 tick 不创建 mutation」。
      assert mutations(obs_pass) == []

      # ---- 断言 8：facts 与 provider 自己的响应逐字段一致 ----
      assert {:ok, remote_pr} = gh_get(creds, "/pulls/#{first_pr}")
      assert observed_facts.change_request_url == remote_pr["html_url"]
      assert observed_facts.change_request_head_ref == remote_pr["head"]["ref"]
      assert observed_facts.change_request_base_ref == remote_pr["base"]["ref"]
      assert observed_facts.change_request_state == remote_pr["state"]
      assert observed_facts.head_sha == remote_pr["head"]["sha"]

      # ---- 断言 6：第二遍 fresh-read，但没有重复 mutation ----
      rewind!(run.id, "changes_ready")
      _ = observed()
      assert {:ok, %WorkflowRun{status: "pr_open"}} = StageRunner.advance(run.id)
      second_pass = observed()

      again = facts!(run.id)
      assert again.change_request_id == first_pr, "第二遍开了第二个 PR"
      assert again.head_sha == first_commit, "第二遍产生了不同的 commit"

      # 第二遍必须**读过**（fresh-read），否则「幂等」只是没跑而已。
      assert Enum.any?(second_pass, fn {m, _} -> m == :get end)

      # 且不得重复建 PR。blob/tree/commit 是内容寻址的，重复 POST 返回同一个
      # sha —— 那不是重复 mutation，而是 GitHub 自己的幂等语义，也正是这条只有
      # 真实 GitHub 能验的地方。
      refute Enum.any?(second_pass, fn {m, p} -> m == :post and String.ends_with?(p, "/pulls") end),
             "第二遍发了 POST /pulls"

      # ---- 断言 5：远端确实只有一个 PR ----
      assert {:ok, prs} = gh_get(creds, "/pulls?state=all&head=#{owner(creds)}:#{head_ref}")
      assert length(prs) == 1, "真实仓库里出现了 #{length(prs)} 个 PR，期望 1 个"
    end
  end
end
