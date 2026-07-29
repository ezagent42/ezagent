defmodule EzagentPluginGitWorkflow.GitHubLiveFaultTest do
  @moduledoc """
  §8 的故障注入与 §6.2 的窗口，打真实 GitHub。

  ## 注入的是什么、不是什么

  **不伪造 GitHub 的任何回答。** 每条注入只做两件事之一：

    * 破坏**我们这侧**的记录（抹 facts 列、回退 run 状态）—— 这正是 §6.2 全部
      窗口的本质：效果已发生、记录未落地；
    * 用真实 API 在远端**构造前置状态**（先占住 ref、先建好 PR）—— 然后问真实
      GitHub「你怎么答」。

  所以这里验的是 GitHub 的实际语义，不是我们对它的信念。替身能便宜地伪造
  429/5xx，但伪造不出「你请求的权限没被授予」这种它自己都不知道的规则。

  ## 本组不覆盖，以及为什么

    * **429 / 5xx** —— 无法让 GitHub 按需故障。这两个状态到稳定错误码的映射由
      `plan_e_fault_injection_test.exs` 用替身覆盖，那里测的是**我们的映射逻辑**，
      本来也不需要真实 GitHub。
    * **digest 冲突 / CAS 竞态** —— 纯本地逻辑，GitHub 全程不参与，
      `store_test.exs` 与 `concurrency_test.exs` 已覆盖。
  """

  use EzagentPluginGitWorkflow.GitHubLiveCase

  alias EzagentPluginGitWorkflow.Authorization
  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowRun

  # ---------------------------------------------------------------------------
  # §8 注入 1 / 2 —— 证明「没有碰 GitHub」
  # ---------------------------------------------------------------------------

  describe "provider 在该沉默的阶段确实沉默" do
    # 「零副作用」只有在真实环境里断言才算数：替身没被调用，可能只是因为替身
    # 没被装上。这里断言的是**真实 GitHub 没有收到任何请求**。
    test "授权失败时，一个请求都不发", %{run: run} do
      :ok =
        EzagentPluginGitWorkflow.ExecutionSeamTestDelegate.put_backend(
          EzagentPluginGitWorkflow.ExecutionSeam.Unavailable
        )

      _ = observed()

      assert {:error, :authorization_unavailable} =
               Authorization.authorize_run(run, binding_of(run))

      assert observed() == [], "授权失败却打了 GitHub"
      assert {:ok, %WorkflowRun{status: "accepted"}} = Store.read_run(run.id)
    end

    test "workspace_ready 之前，provider 一个请求都不发", ctx do
      %{run: run, binding: binding} = ctx

      {:ok, _} = Authorization.authorize_run(run, binding)
      _ = observed()

      # provision 是本地 git + 本地 DB，全程不该碰 provider。
      assert {:ok, %WorkflowRun{status: "workspace_ready"}} = StageRunner.advance(run.id)
      assert observed() == [], "workspace 供给阶段打了 GitHub"

      # collect 同样是本地的。
      write_worker_file!(run.id)
      assert {:ok, %WorkflowRun{status: "changes_ready"}} = StageRunner.advance(run.id)
      assert observed() == [], "变更收集阶段打了 GitHub"
    end

    test "收集到不受支持的变更时，停在收集，不碰 provider", ctx do
      %{run: run, binding: binding} = ctx

      {:ok, _} = Authorization.authorize_run(run, binding)
      {:ok, _} = StageRunner.advance(run.id)

      # 二进制内容 —— V1 envelope 只收有界 UTF-8。
      facts = facts!(run.id)
      path = Path.join(worktree_path!(facts.workspace_provision_id), "binary.bin")
      File.write!(path, <<0, 1, 2, 3, 0xFF>>)

      _ = observed()
      assert {:blocked, %{code: :unsupported_workspace_change}} = StageRunner.advance(run.id)

      assert observed() == [], "不受支持的变更却打了 GitHub"
      assert {:ok, %WorkflowRun{status: "blocked"}} = Store.read_run(run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # §8 注入 3 / §6.2 窗口 3 —— PR 建成了，receipt 丢了
  # ---------------------------------------------------------------------------

  describe "§6.2 窗口 3 —— PR 已建，本地 receipt 丢失" do
    test "重跑找回同一个 PR，绝不开第二个", ctx do
      %{creds: creds, run: run, head_ref: head_ref} = ctx

      facts = to_pr_open!(ctx)
      first_pr = facts.change_request_id

      # 崩在「PR 已经建好、facts 还没落」的那一刻。GitHub 那边原封不动。
      forget_facts!(run.id, [:change_request_id, :change_request_url, :change_request_state])
      rewind!(run.id, "changes_ready")
      _ = observed()

      assert {:ok, %WorkflowRun{status: "pr_open"}} = StageRunner.advance(run.id)
      replay = observed()

      # 这一条只有真实 GitHub 能验：它的 PR 搜索按 head+base 命中既有 PR 吗？
      assert facts!(run.id).change_request_id == first_pr,
             "重跑没找回原 PR —— GitHub 的 PR 搜索语义与我们的假设不符"

      refute Enum.any?(replay, fn {m, p} -> m == :post and String.ends_with?(p, "/pulls") end),
             "重跑发了 POST /pulls"

      assert {:ok, prs} = gh_get(creds, "/pulls?state=all&head=#{owner(creds)}:#{head_ref}")
      assert length(prs) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # §8 注入 5 —— 分支冲突
  # ---------------------------------------------------------------------------

  describe "§8 注入 5 —— 确定性 ref 上坐着外来 commit" do
    test "是 head_ref_conflict，且绝不 force push", ctx do
      %{creds: creds, run: run, binding: binding, head_ref: head_ref, mirror: mirror} = ctx

      {:ok, _} = Authorization.authorize_run(run, binding)
      {:ok, _} = StageRunner.advance(run.id)
      write_worker_file!(run.id)
      {:ok, _} = StageRunner.advance(run.id)

      # 在确定性 ref 上先放一个与本 run 无关的真实 commit。
      {:ok, blob} = gh_post(creds, "/git/blobs", %{content: "foreign\n", encoding: "utf-8"})

      {:ok, tree} =
        gh_post(creds, "/git/trees", %{
          base_tree: mirror.head_sha,
          tree: [%{path: "foreign.txt", mode: "100644", type: "blob", sha: blob["sha"]}]
        })

      {:ok, foreign} =
        gh_post(creds, "/git/commits", %{
          message: "foreign commit",
          tree: tree["sha"],
          parents: [mirror.head_sha]
        })

      {:ok, _} =
        gh_post(creds, "/git/refs", %{ref: "refs/heads/#{head_ref}", sha: foreign["sha"]})

      _ = observed()
      assert {:blocked, %{code: :head_ref_conflict}} = StageRunner.advance(run.id)
      events = observed()

      # 绝不 force push：ref 更新是 PATCH，本次一次都不该发。
      refute Enum.any?(events, fn {m, p} -> m == :patch and String.contains?(p, "/git/refs") end),
             "对冲突的 ref 发了 PATCH（force push 的形状）"

      # 远端仍指向那个外来 commit —— 我们没动过它。
      assert {:ok, still} = gh_get(creds, "/git/ref/heads/#{head_ref}")
      assert still["object"]["sha"] == foreign["sha"]
    end
  end

  # ---------------------------------------------------------------------------
  # §6.2 窗口 1 / 2 —— 远端做了一半
  # ---------------------------------------------------------------------------

  describe "§6.2 窗口 1 —— ref 建了但仍停在 base" do
    test "resume 完成整条链，不冲突", ctx do
      %{creds: creds, run: run, binding: binding, head_ref: head_ref, mirror: mirror} = ctx

      {:ok, _} = Authorization.authorize_run(run, binding)
      {:ok, _} = StageRunner.advance(run.id)
      write_worker_file!(run.id)
      {:ok, _} = StageRunner.advance(run.id)

      # 崩在「ref 建好、指向 base、commit 还没推上去」那一刻。
      {:ok, _} =
        gh_post(creds, "/git/refs", %{ref: "refs/heads/#{head_ref}", sha: mirror.head_sha})

      assert {:ok, %WorkflowRun{status: "pr_open"}} = StageRunner.advance(run.id)

      facts = facts!(run.id)
      assert {:ok, remote} = gh_get(creds, "/git/ref/heads/#{head_ref}")
      assert remote["object"]["sha"] == facts.head_sha
      refute facts.head_sha == mirror.head_sha, "ref 仍停在 base，commit 没推上去"
    end
  end

  describe "§6.2 窗口 2 —— commit 推上去了，PR 没建" do
    test "resume 恰好建一个 PR，不重建 git data", ctx do
      %{creds: creds, run: run, head_ref: head_ref} = ctx

      facts = to_pr_open!(ctx)
      commit = facts.head_sha

      # 关掉 PR 并抹掉 receipt —— 远端只剩 ref + commit，PR 那一步等于没发生。
      {:ok, prs} = gh_get(creds, "/pulls?state=all&head=#{owner(creds)}:#{head_ref}")
      token = installation_token!(creds)

      for pr <- prs do
        Req.patch(
          "https://api.github.com/repos/#{creds.repo}/pulls/#{pr["number"]}",
          [
            headers: [
              {"authorization", "Bearer #{token}"},
              {"accept", "application/vnd.github+json"},
              {"user-agent", "ezagent-live-e2e"}
            ],
            json: %{state: "closed"}
          ] ++ plain_req_opts(creds)
        )
      end

      forget_facts!(run.id, [:change_request_id, :change_request_url, :change_request_state])
      rewind!(run.id, "changes_ready")
      _ = observed()

      assert {:ok, %WorkflowRun{status: "pr_open"}} = StageRunner.advance(run.id)
      replay = observed()

      # commit 不该被重建：它已经在 ref 上了。
      assert facts!(run.id).head_sha == commit

      # 恰好一次 POST /pulls —— 既有的那个是 closed，按 head+base+state=open
      # 搜不到，所以这次**应该**建一个新的。这正是 §6.2 与注入 3 的分界。
      posts =
        Enum.count(replay, fn {m, p} -> m == :post and String.ends_with?(p, "/pulls") end)

      assert posts == 1, "重开 PR 时发了 #{posts} 次 POST /pulls"
    end
  end

  # ---------------------------------------------------------------------------
  # §6.2 窗口 5 —— observation 拿到了响应，快照没落库
  # ---------------------------------------------------------------------------

  describe "§6.2 窗口 5 —— observation 响应已到，快照未落" do
    test "重 tick 写下一整拍，且不产生任何变更请求", ctx do
      %{run: run} = ctx

      _ = to_pr_open!(ctx)
      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)

      # 崩在「三个读都成功、facts 还没写」那一刻。
      forget_facts!(run.id, [
        :checks_summary,
        :checks_revision,
        :checks_observed_at,
        :reviews_summary,
        :reviews_revision,
        :reviews_observed_at
      ])

      rewind!(run.id, "pr_open")
      _ = observed()

      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)
      replay = observed()

      after_retry = facts!(run.id)

      # 一整拍：六列要么全在，要么全不在 —— 不允许出现「checks 是这一拍、
      # reviews 是上一拍」这种从未存在过的快照。
      assert is_binary(after_retry.checks_summary)
      assert is_binary(after_retry.reviews_summary)
      assert after_retry.checks_observed_at == after_retry.reviews_observed_at
      assert after_retry.checks_revision == after_retry.reviews_revision

      assert mutations(replay) == [], "observation 重试产生了仓库变更"
    end
  end

  # ---------------------------------------------------------------------------
  # §8 注入 8 —— 真实的 404（429/5xx 造不出来，留给替身）
  # ---------------------------------------------------------------------------

  describe "§8 注入 8 —— 真实的 provider 错误映射" do
    # 429/5xx 造不出来（不能让 GitHub 按需故障），但 404 能：指向一个真实不存在
    # 的仓库，GitHub 会真的答 404。这里验的是**真实响应到稳定码**的那一段，以及
    # 呈现里不带 GitHub 的响应体。
    #
    # 用独立的 binding + run，而不是中途改 binding：policy 是从 binding 派生的，
    # 中途改会先撞上 :workspace_identity_mismatch（系统正确地拒绝了一个变了的
    # binding），那是另一条路径，不是本条要验的。镜像与 binding.external_id 相互
    # 独立，所以 workspace 供给照常成功，只有 provider 调用会 404。
    test "指向不存在的仓库，得到稳定码且不泄漏响应体", %{creds: creds} do
      missing = "#{owner(creds)}/definitely-not-real-#{System.unique_integer([:positive])}"
      ws = "git-live-404-#{System.unique_integer([:positive])}"

      binding =
        EzagentPluginGitWorkflow.GitTaskAccessFixture.binding(%{
          id: "bnd-404-#{System.unique_integer([:positive])}",
          workspace: ws,
          provider_adapter: :github,
          provider_host: "github.com",
          external_id: missing,
          owner_path: owner(creds),
          base_ref: creds.base_ref,
          visibility: :public,
          allowed_head_namespace: "task/live/"
        })

      {:ok, _} = Store.register_binding(binding)

      {:ok, intent} =
        EzagentPluginGitWorkflow.AcceptIntent.new(%{
          binding_id: binding.id,
          binding_generation: binding.generation,
          external_task_id: "live-404-#{System.unique_integer([:positive])}",
          source_task_uri: Ezagent.URI.resource(ws, "kanban-task", "t404"),
          source_revision: nil,
          requested_head_ref: nil
        })

      {:ok, run404} = Store.accept(intent)

      {:ok, policy} = EzagentPluginGitWorkflow.PolicyDerivation.derive(run404, binding)
      uri = Ezagent.Entity.GitTaskAccess.uri_from_args(policy)
      on_exit(fn -> Ezagent.DomainGit.TaskAccessSupervisor.teardown(uri) end)

      {:ok, _} = Authorization.authorize_run(run404, binding)
      {:ok, _} = StageRunner.advance(run404.id)
      write_worker_file!(run404.id)
      {:ok, _} = StageRunner.advance(run404.id)

      assert {:blocked, presented} = StageRunner.advance(run404.id)

      # 稳定码 —— GitHub 对「装了 App 但仓库不存在」答 404，客户端映射为
      # :repository_not_found。
      assert presented.code in [:repository_not_found, :provider_permission_denied]

      # 呈现里不得出现 GitHub 的响应体片段。
      dump = inspect(presented)
      refute dump =~ "documentation_url"
      refute dump =~ "Not Found"
      refute dump =~ missing

      {:ok, blocked} = Store.read_run(run404.id)
      assert blocked.status == "blocked"
      assert blocked.last_error_code == to_string(presented.code)
    end
  end

  # ---------------------------------------------------------------------------

  defp binding_of(run) do
    {:ok, binding} = Store.read_binding(run.binding_id)
    binding
  end
end
