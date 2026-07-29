defmodule EzagentPluginGitWorkflow.GitHubLiveTest do
  @moduledoc """
  真实 GitHub 往返 e2e。**默认排除**（`:live_github`），需要凭证 + 网络：

      GITHUB_APP_ID=... \\
      GITHUB_APP_PRIVATE_KEY="$(cat path/to/app.private-key.pem)" \\
      EZAGENT_LIVE_GITHUB_REPO=owner/repo \\
      EZAGENT_LIVE_GITHUB_PROXY=http://127.0.0.1:7890 \\
      mix test apps/ezagent_plugin_git_workflow/test/e2e/github_live_test.exs --include live_github

  ## 为什么需要它，既然 P4e 已经有 31 个 e2e

  P4e 的 `StubGitProvider` 编码的是**我们对 GitHub 行为的信念**：重复建 ref 返
  422、`PATCH` 拒绝非快进、PR 按 head+base+state 精确匹配、blob/tree/commit 内容
  寻址。P3 的幂等 reconciliation 整个建立在这些信念上。

  **任何一条信念错了，替身测试照样全绿，真实环境照样失败。** 这是替身永远查不出、
  而这一条能查出的东西——也是它存在的唯一理由。

  ## 与替身测试的分工

  | | P4e（替身） | 本文件（真实） |
  |---|---|---|
  | 覆盖面 | §8 十六项 + §6.2 五个窗口 | 一条主干 + 幂等重跑 |
  | 断言粒度 | 逐 pass 计数每个变更请求 | GitHub 上的**实际状态** |
  | 跑的频率 | 每次 CI | 手动，改 adapter 后 |

  本文件**不重复** P4e 已覆盖的故障注入——那些用替身注入既精确又免费，用真实
  GitHub 注入既做不精确又要真的把仓库搞脏。

  ## 环境前提（两处代理，都不认环境变量）

  见 `docs/guide/github-plugin-config.md`：

  - Req/Finch 不认 `HTTPS_PROXY`，经 `:adapter_req_opts` 显式传；
  - `GitRunner` 用 `clear_env: true` 起 git，`https_proxy` 到不了它 —— 所以
    workspace **不从真实 remote clone**，而是由本测试先把真实仓库镜像成本地
    bare repo 再供给。`resolved_base_commit` 因此仍是 GitHub 的真实 head sha，
    `expected_base_sha` 对得上，而 provider 调用打的是真实 GitHub。

  ## 收尾

  测试会在真实仓库里建一个分支和一个 PR。`on_exit` 关 PR、删分支。孤立的
  blob/tree/commit 不清理 —— 没有 ref 指向它们，GitHub 会 GC。
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.TaskAccessSupervisor
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Authorization
  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture
  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :live_github
  # 真实网络往返，比替身慢得多。
  @moduletag timeout: 300_000

  @head_namespace "task/live/"
  @worker_file "ezagent-live-probe.md"

  setup do
    creds = live_creds!()
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "git-live-#{unique}")
    File.mkdir_p!(root)

    previous_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", root)

    # 先注册清理，再动任何全局状态：setup 中途炸掉不该把 EZAGENT_HOME 和三个
    # :ezagent_plugin_github 键漏给后面的测试（P4e 同样的理由）。
    on_exit(fn ->
      Application.delete_env(:ezagent_plugin_github, :adapter_req_opts)
      Application.delete_env(:ezagent_plugin_github, :app_id)
      Application.delete_env(:ezagent_plugin_github, :private_key)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_remote_builder)

      if is_nil(previous_home),
        do: System.delete_env("EZAGENT_HOME"),
        else: System.put_env("EZAGENT_HOME", previous_home)

      File.rm_rf!(root)
    end)

    mirror = mirror_real_repo!(root, creds)

    Application.put_env(:ezagent_domain_workspace, :task_workspace_remote_builder, fn _req,
                                                                                      _pol ->
      %{remote_url: mirror.path, allow_local_fixture: true}
    end)

    Application.put_env(:ezagent_plugin_github, :app_id, creds.app_id)
    Application.put_env(:ezagent_plugin_github, :private_key, creds.private_key)
    Application.put_env(:ezagent_plugin_github, :adapter_req_opts, req_opts(creds))

    [owner, _repo] = String.split(creds.repo, "/", parts: 2)

    binding =
      GitTaskAccessFixture.binding(%{
        workspace: "git-live-#{unique}",
        provider_adapter: :github,
        provider_host: "github.com",
        external_id: creds.repo,
        owner_path: owner,
        base_ref: creds.base_ref,
        visibility: :public,
        allowed_head_namespace: @head_namespace
      })

    {:ok, _} = Store.register_binding(binding)

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: binding.id,
        binding_generation: binding.generation,
        external_task_id: "live-#{unique}",
        source_task_uri: Ezagent.URI.resource("git-live-#{unique}", "kanban-task", "t-#{unique}"),
        source_revision: nil,
        requested_head_ref: nil
      })

    {:ok, run} = Store.accept(intent)
    head_ref = DeterministicRef.derive(@head_namespace, run.id)

    # 真实 backend，与 P4e 同一个理由（设计 §3.4）：换成 test double 只能证明
    # 「给定授权后流水线能跑」；用真实的才连 authorize_receiver / action_allowed
    # / validate_requested_head 与一张真实签名的 cap 一起证明。
    # 被替身的始终是 GitHub，从来不是 seam —— 而这一条连 GitHub 也不替。
    {:ok, policy} = PolicyDerivation.derive(run, binding)
    task_access_uri = GitTaskAccess.uri_from_args(policy)
    :ok = ExecutionSeamTestDelegate.put_backend(CapBacked)
    on_exit(fn -> TaskAccessSupervisor.teardown(task_access_uri) end)

    # 建出来的分支/PR 一定要收掉，哪怕断言中途炸了。
    on_exit(fn -> cleanup_remote(creds, head_ref) end)

    %{creds: creds, binding: binding, run: run, head_ref: head_ref, mirror: mirror}
  end

  describe "真实 GitHub 往返" do
    test "一条主干跑通，重跑不产生第二个 ref/commit/PR", ctx do
      %{creds: creds, binding: binding, run: run, head_ref: head_ref, mirror: mirror} = ctx

      # ---- 第一遍 ----
      assert {:ok, %WorkflowRun{status: "authorized"}} =
               Authorization.authorize_run(run, binding)

      assert {:ok, %WorkflowRun{status: "workspace_ready"}} = StageRunner.advance(run.id)

      # §8 步骤 4：一个真实的 worker 往真实 worktree 里写一个有界 UTF-8 文件。
      write_worker_file!(run.id)

      assert {:ok, %WorkflowRun{status: "changes_ready"}} = StageRunner.advance(run.id)
      assert {:ok, %WorkflowRun{status: "pr_open"}} = StageRunner.advance(run.id)

      {:ok, facts} = Store.read_facts(run.id)

      # base 必须是 GitHub 上 main 的真实 head —— 镜像是它的忠实副本。
      assert facts.expected_base_sha == mirror.head_sha
      assert facts.deterministic_head_ref == head_ref
      assert is_binary(facts.change_request_id)
      assert is_binary(facts.head_sha)

      first_pr = facts.change_request_id
      first_commit = facts.head_sha

      # ---- 真实 GitHub 上的状态 ----
      assert {:ok, remote_ref} = get_json(creds, "/git/ref/heads/#{head_ref}")
      assert remote_ref["object"]["sha"] == first_commit

      assert {:ok, remote_commit} = get_json(creds, "/git/commits/#{first_commit}")
      assert hd(remote_commit["parents"])["sha"] == mirror.head_sha

      # commit date 必须是 run.inserted_at —— 这是 §6.1 让重试产出同一个 sha 的
      # 全部依据，也是替身测不到「GitHub 到底认不认这个 date」的一点。
      # 从库里重读：Store.accept/1 返回的结构不带 inserted_at（生产侧无碍，
      # StageRunner 本来就现读 run）。
      {:ok, persisted_run} = Store.read_run(run.id)

      assert remote_commit["author"]["date"] ==
               persisted_run.inserted_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      # ---- observation：回读真实 PR / checks / reviews ----
      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)
      {:ok, observed} = Store.read_facts(run.id)
      assert observed.change_request_state == "open"
      assert is_binary(observed.checks_summary)
      assert is_binary(observed.reviews_summary)
      assert observed.checks_revision == 1

      # ---- 第二遍：同一个 run 重跑变更阶段 ----
      rewind!(run.id, "changes_ready")
      assert {:ok, %WorkflowRun{status: "pr_open"}} = StageRunner.advance(run.id)

      {:ok, again} = Store.read_facts(run.id)

      # 幂等的三条断言 —— 这是本文件存在的理由：替身说「重复建 ref 返 422、PR
      # 按 head+base 精确匹配」，这里问的是**真实 GitHub 认不认**。
      assert again.change_request_id == first_pr, "第二遍开了第二个 PR"
      assert again.head_sha == first_commit, "第二遍产生了不同的 commit"

      assert {:ok, prs} = get_json(creds, "/pulls?state=all&head=#{owner(creds)}:#{head_ref}")
      assert length(prs) == 1, "真实仓库里出现了 #{length(prs)} 个 PR，期望 1 个"
    end
  end

  # ---------------------------------------------------------------------------
  # 凭证与网络
  # ---------------------------------------------------------------------------

  defp live_creds! do
    %{
      app_id: fetch!("GITHUB_APP_ID"),
      private_key: fetch!("GITHUB_APP_PRIVATE_KEY"),
      repo: fetch!("EZAGENT_LIVE_GITHUB_REPO"),
      base_ref: System.get_env("EZAGENT_LIVE_GITHUB_BASE_REF", "main"),
      proxy: System.get_env("EZAGENT_LIVE_GITHUB_PROXY")
    }
  end

  defp fetch!(var) do
    System.get_env(var) ||
      flunk("""
      #{var} 未设置。本测试默认排除，跑它需要真实凭证：

          GITHUB_APP_ID=... GITHUB_APP_PRIVATE_KEY="$(cat app.pem)" \\
          EZAGENT_LIVE_GITHUB_REPO=owner/repo \\
          mix test #{__ENV__.file |> Path.relative_to_cwd()} --include live_github

      权限与逐环验证见 docs/guide/github-plugin-config.md。
      """)
  end

  # Req/Finch 不认 HTTPS_PROXY，要显式传；retry: false 与生产一致（#1613），
  # 免得一次 attempt 静默变成四个请求。
  defp req_opts(%{proxy: nil}), do: [retry: false]

  defp req_opts(%{proxy: proxy}) do
    uri = URI.parse(proxy)
    [retry: false, connect_options: [proxy: {:http, uri.host, uri.port, []}]]
  end

  # ---------------------------------------------------------------------------
  # 本地镜像：GitRunner 的 clear_env 让它上不了网，所以镜像由测试自己做
  # ---------------------------------------------------------------------------

  defp mirror_real_repo!(root, creds) do
    path = Path.join(root, "mirror.git")

    args =
      proxy_git_args(creds) ++ ["clone", "--bare", "https://github.com/#{creds.repo}.git", path]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> flunk("镜像真实仓库失败（exit #{status}）：\n#{out}")
    end

    %{path: path, head_sha: git!(path, ["rev-parse", creds.base_ref])}
  end

  defp proxy_git_args(%{proxy: nil}), do: []
  defp proxy_git_args(%{proxy: proxy}), do: ["-c", "http.proxy=#{proxy}"]

  defp git!(git_dir, args) do
    case System.cmd("git", ["--git-dir", git_dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}:\n#{out}")
    end
  end

  # ---------------------------------------------------------------------------
  # 直接问 GitHub：断言的是**远端实际状态**，不是我们记了什么
  # ---------------------------------------------------------------------------

  defp get_json(creds, path) do
    token = installation_token!(creds)
    url = "https://api.github.com/repos/#{creds.repo}#{path}"

    case Req.get(url, [headers: auth_headers(token)] ++ req_opts(creds)) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp installation_token!(creds) do
    jwt = EzagentPluginGithub.GitHubAppJwt.generate()
    h = auth_headers(jwt)

    {:ok, %{status: 200, body: inst}} =
      Req.get(
        "https://api.github.com/repos/#{creds.repo}/installation",
        [headers: h] ++ req_opts(creds)
      )

    {:ok, %{status: 201, body: tok}} =
      Req.post(
        "https://api.github.com/app/installations/#{inst["id"]}/access_tokens",
        [headers: h] ++ req_opts(creds)
      )

    tok["token"]
  end

  defp auth_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "ezagent-live-e2e"}
    ]
  end

  defp owner(creds), do: creds.repo |> String.split("/") |> hd()

  # ---------------------------------------------------------------------------
  # 收尾：关 PR、删分支
  # ---------------------------------------------------------------------------

  defp cleanup_remote(creds, head_ref) do
    token = installation_token!(creds)
    opts = [headers: auth_headers(token)] ++ req_opts(creds)
    base = "https://api.github.com/repos/#{creds.repo}"

    with {:ok, %{status: 200, body: prs}} <-
           Req.get("#{base}/pulls?state=open&head=#{owner(creds)}:#{head_ref}", opts) do
      for pr <- prs do
        Req.patch("#{base}/pulls/#{pr["number"]}", opts ++ [json: %{state: "closed"}])
      end
    end

    Req.delete("#{base}/git/refs/heads/#{head_ref}", opts)
    :ok
  rescue
    # 收尾失败不该把测试结果盖掉——它已经断言完了。
    error -> IO.warn("live 收尾失败（分支/PR 可能需要手动删）：#{Exception.message(error)}")
  end

  # ---------------------------------------------------------------------------
  # 本地辅助
  # ---------------------------------------------------------------------------

  defp write_worker_file!(run_id) do
    {:ok, facts} = Store.read_facts(run_id)

    %Postgrex.Result{rows: [[worktree_path]]} =
      Repo.query!(
        "SELECT worktree_path FROM git_task_workspace_provisions WHERE provision_id = $1",
        [facts.workspace_provision_id]
      )

    File.write!(
      Path.join(worktree_path, @worker_file),
      "ezagent live e2e probe — #{DateTime.utc_now() |> DateTime.to_iso8601()}\n"
    )
  end

  defp rewind!(run_id, status) do
    Repo.query!("UPDATE git_workflow_runs SET status = $1 WHERE id = $2", [status, run_id])
    :ok
  end
end
