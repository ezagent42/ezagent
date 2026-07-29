defmodule EzagentPluginGitWorkflow.GitHubLiveCase do
  @moduledoc """
  真实 GitHub 往返的共享装置。**默认排除**（`:live_github`）。

      GITHUB_APP_ID=... GITHUB_APP_PRIVATE_KEY="$(cat app.pem)" \\
      EZAGENT_LIVE_GITHUB_REPO=owner/repo \\
      EZAGENT_LIVE_GITHUB_PROXY=http://127.0.0.1:7890 \\
      mix test apps/ezagent_plugin_git_workflow/test/e2e --include live_github

  ## 这里没有替身

  P4e 的 `StubGitProvider` 编码的是**我们对 GitHub 行为的信念**。这一组问的是
  GitHub 认不认。所以除了下面两处**本地**注入点，全链路都是真的：

    * **观察器**（`plugins:`）—— 它不拦截也不伪造，只在请求飞向真实 GitHub 之前
      抄一份 method+url 发给测试进程。用来断言「发生了几次」以及「一次都没有」；
    * **本地状态破坏** —— 抹掉 facts 行、回退 run 状态、让本地写失败。这些模拟
      的是**我们这侧**崩在什么位置，GitHub 那侧的状态完全是真的。

  ## workspace 为什么不从真实 remote clone

  `GitRunner` 用 `clear_env: true` 起 git（只留 `GIT_CONFIG_NOSYSTEM` /
  `GIT_TERMINAL_PROMPT`），代理变量到不了它。所以由本装置先把真实仓库镜像成本地
  bare repo 再供给。镜像是忠实副本，`resolved_base_commit` 因此仍是 GitHub 的
  真实 head sha，`expected_base_sha` 对得上，而 provider 调用打的是真实 GitHub。
  """

  use ExUnit.CaseTemplate

  alias Ezagent.DomainGit.TaskAccessSupervisor
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.DeterministicRef
  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.Store

  @head_namespace "task/live/"
  @worker_file "ezagent-live-probe.md"

  using do
    quote do
      use EzagentCore.DataCase, async: false

      import EzagentPluginGitWorkflow.GitHubLiveCase

      @moduletag :live_github
      # 真实网络往返，比替身慢得多。
      @moduletag timeout: 600_000

      setup do
        EzagentPluginGitWorkflow.GitHubLiveCase.setup_live()
      end
    end
  end

  @doc false
  def setup_live do
    creds = live_creds!()
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "git-live-#{unique}")
    File.mkdir_p!(root)

    previous_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", root)

    # 先注册清理再动全局状态：setup 中途炸掉不该把 EZAGENT_HOME 和
    # :ezagent_plugin_github 的键漏给后面的测试。
    ExUnit.Callbacks.on_exit(fn ->
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
    Application.put_env(:ezagent_plugin_github, :adapter_req_opts, observed_req_opts(creds))

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

    # 真实 backend（设计 §3.4）：换成 test double 只证明「给定授权后流水线能跑」；
    # 用真实的才连 authorize_receiver / action_allowed / 一张真实签名的 cap 一起
    # 证明。被替身的始终是 GitHub —— 而这一组连 GitHub 也不替。
    {:ok, policy} = PolicyDerivation.derive(run, binding)
    task_access_uri = GitTaskAccess.uri_from_args(policy)
    :ok = ExecutionSeamTestDelegate.put_backend(CapBacked)
    ExUnit.Callbacks.on_exit(fn -> TaskAccessSupervisor.teardown(task_access_uri) end)

    # 建出来的分支/PR 一定要收掉，哪怕断言中途炸了。
    ExUnit.Callbacks.on_exit(fn -> cleanup_remote(creds, head_ref) end)

    %{creds: creds, binding: binding, run: run, head_ref: head_ref, mirror: mirror}
  end

  # ---------------------------------------------------------------------------
  # 凭证与网络
  # ---------------------------------------------------------------------------

  @doc false
  def live_creds! do
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
      raise """
      #{var} 未设置。本组测试默认排除，跑它需要真实凭证：

          GITHUB_APP_ID=... GITHUB_APP_PRIVATE_KEY="$(cat app.pem)" \\
          EZAGENT_LIVE_GITHUB_REPO=owner/repo \\
          mix test apps/ezagent_plugin_git_workflow/test/e2e --include live_github

      权限清单与逐环验证见 docs/guide/github-plugin-config.md。
      """
  end

  @doc """
  给 adapter 的 Req 选项：真实网络 + 一个**透传**观察器。

  观察器不拦截、不伪造、不改写 —— 它只在请求飞出去之前把 `{:gh, method, path}`
  抄送测试进程。这是「数了几次」和「一次都没有」两类断言唯一诚实的做法：拿替身
  数请求数的是替身的行为，不是 GitHub 的。
  """
  @spec observed_req_opts(map(), pid()) :: keyword()
  def observed_req_opts(creds, observer \\ nil) do
    me = observer || self()

    plugin = fn req ->
      Req.Request.append_request_steps(req,
        ezagent_live_probe: fn r ->
          send(me, {:gh, r.method, r.url.path})
          r
        end
      )
    end

    base = [retry: false, plugins: [plugin]]

    case creds.proxy do
      nil ->
        base

      proxy ->
        uri = URI.parse(proxy)
        base ++ [connect_options: [proxy: {:http, uri.host, uri.port, []}]]
    end
  end

  @doc "同样的选项，但不带观察器 —— 给测试自己直接问 GitHub 用。"
  @spec plain_req_opts(map()) :: keyword()
  def plain_req_opts(creds) do
    creds |> observed_req_opts() |> Keyword.delete(:plugins)
  end

  # ---------------------------------------------------------------------------
  # 观察器断言
  # ---------------------------------------------------------------------------

  @doc "排空并按顺序返回观察到的 `{method, path}`。"
  @spec observed(list()) :: list()
  def observed(acc \\ []) do
    receive do
      {:gh, m, p} -> observed([{m, p} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  观察到的**仓库状态变更**请求 —— 幂等断言数的就是这些。

  铸 token 的 `POST …/access_tokens` 被排除：它是认证，不改仓库任何状态。把它
  算进「mutation」会让「一次 tick 零变更」这类断言永远为假，而那恰恰是 §6.3
  要保证的性质。
  """
  @spec mutations(list()) :: list()
  def mutations(events) do
    Enum.filter(events, fn {m, p} ->
      m in [:post, :patch, :delete] and not String.ends_with?(p, "/access_tokens")
    end)
  end

  @doc "铸 token 的请求数 —— §8 断言 7 的「一次 callback 一个 token」。"
  @spec token_mints(list()) :: non_neg_integer()
  def token_mints(events),
    do: Enum.count(events, fn {m, p} -> m == :post and String.ends_with?(p, "/access_tokens") end)

  # ---------------------------------------------------------------------------
  # 本地镜像
  # ---------------------------------------------------------------------------

  @doc false
  def mirror_real_repo!(root, creds) do
    path = Path.join(root, "mirror.git")

    args =
      proxy_git_args(creds) ++
        ["clone", "--bare", "https://github.com/#{creds.repo}.git", path]

    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> raise "镜像真实仓库失败（exit #{status}）：\n#{out}"
    end

    %{path: path, head_sha: git!(path, ["rev-parse", creds.base_ref])}
  end

  defp proxy_git_args(%{proxy: nil}), do: []
  defp proxy_git_args(%{proxy: proxy}), do: ["-c", "http.proxy=#{proxy}"]

  defp git!(git_dir, args) do
    case System.cmd("git", ["--git-dir", git_dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status}:\n#{out}"
    end
  end

  # ---------------------------------------------------------------------------
  # 直接问 GitHub：断言的是远端实际状态，不是我们记了什么
  # ---------------------------------------------------------------------------

  @doc "以 installation token 读远端资源。"
  @spec gh_get(map(), String.t()) :: {:ok, term()} | {:error, term()}
  def gh_get(creds, path), do: gh(creds, :get, path, nil)

  @doc "以 installation token 写远端资源（构造前置状态用）。"
  @spec gh_post(map(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def gh_post(creds, path, body), do: gh(creds, :post, path, body)

  defp gh(creds, method, path, body) do
    token = installation_token!(creds)
    url = "https://api.github.com/repos/#{creds.repo}#{path}"
    opts = [headers: auth_headers(token)] ++ plain_req_opts(creds)
    opts = if body, do: opts ++ [json: body], else: opts

    result =
      case method do
        :get -> Req.get(url, opts)
        :post -> Req.post(url, opts)
      end

    case result do
      {:ok, %{status: s, body: b}} when s in 200..299 -> {:ok, b}
      {:ok, %{status: s, body: b}} -> {:error, {s, b}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def installation_token!(creds) do
    jwt = EzagentPluginGithub.GitHubAppJwt.generate()
    h = auth_headers(jwt)
    opts = plain_req_opts(creds)

    {:ok, %{status: 200, body: inst}} =
      Req.get("https://api.github.com/repos/#{creds.repo}/installation", [headers: h] ++ opts)

    {:ok, %{status: 201, body: tok}} =
      Req.post(
        "https://api.github.com/app/installations/#{inst["id"]}/access_tokens",
        [headers: h] ++ opts
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

  @doc false
  def owner(creds), do: creds.repo |> String.split("/") |> hd()

  # ---------------------------------------------------------------------------
  # 收尾
  # ---------------------------------------------------------------------------

  @doc false
  def cleanup_remote(creds, head_ref) do
    token = installation_token!(creds)
    opts = [headers: auth_headers(token)] ++ plain_req_opts(creds)
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
    # 收尾失败不该把测试结果盖掉 —— 断言已经做完了。
    error -> IO.warn("live 收尾失败（分支/PR 可能需要手动删）：#{Exception.message(error)}")
  end

  # ---------------------------------------------------------------------------
  # 场景步骤
  # ---------------------------------------------------------------------------

  @doc "§8 步骤 4：一个真实 worker 往真实 worktree 写一个有界 UTF-8 文件。"
  @spec write_worker_file!(String.t(), String.t()) :: :ok
  def write_worker_file!(run_id, content \\ nil) do
    {:ok, facts} = Store.read_facts(run_id)
    path = Path.join(worktree_path!(facts.workspace_provision_id), @worker_file)
    File.write!(path, content || "ezagent live probe — #{System.unique_integer([:positive])}\n")
  end

  @doc false
  def worktree_path!(provision_id) do
    %Postgrex.Result{rows: [[path]]} =
      EzagentCore.Repo.query!(
        "SELECT worktree_path FROM git_task_workspace_provisions WHERE provision_id = $1",
        [provision_id]
      )

    path
  end

  @doc "把 run 的状态直接改成 `status` —— 模拟「我们这侧崩在这一步之前」。"
  @spec rewind!(String.t(), String.t()) :: :ok
  def rewind!(run_id, status) do
    EzagentCore.Repo.query!("UPDATE git_workflow_runs SET status = $1 WHERE id = $2", [
      status,
      run_id
    ])

    :ok
  end

  @doc """
  抹掉 facts 行里的某些列 —— 模拟「远端动作成功了，本地 receipt 没落库」。

  这是 §6.2 全部窗口的本质：**效果已发生、记录未落地**。破坏的是我们这侧的
  记录，GitHub 那侧原封不动。
  """
  @spec forget_facts!(String.t(), [atom()]) :: :ok
  def forget_facts!(run_id, columns) do
    sets = columns |> Enum.map(&"#{&1} = NULL") |> Enum.join(", ")
    EzagentCore.Repo.query!("UPDATE git_workflow_facts SET #{sets} WHERE run_id = $1", [run_id])
    :ok
  end

  @doc "读回 facts，断言用。"
  @spec facts!(String.t()) :: EzagentPluginGitWorkflow.WorkflowFacts.t()
  def facts!(run_id) do
    {:ok, facts} = Store.read_facts(run_id)
    facts
  end

  @doc "跑到 `pr_open`：授权 → 供给 → 写文件 → 收集 → 建 PR。"
  @spec to_pr_open!(map()) :: EzagentPluginGitWorkflow.WorkflowFacts.t()
  def to_pr_open!(%{run: run, binding: binding}) do
    {:ok, _} = EzagentPluginGitWorkflow.Authorization.authorize_run(run, binding)
    {:ok, _} = EzagentPluginGitWorkflow.StageRunner.advance(run.id)
    write_worker_file!(run.id)
    {:ok, _} = EzagentPluginGitWorkflow.StageRunner.advance(run.id)
    {:ok, _} = EzagentPluginGitWorkflow.StageRunner.advance(run.id)
    facts!(run.id)
  end
end
