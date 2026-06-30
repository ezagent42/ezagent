defmodule EzagentPluginGithub.Gh do
  @moduledoc """
  GitHub `gh` CLI 客户端（出站 + 入站 list）。

  经 `System.cmd("gh", args, env: token_env())` 接通 github —— **sanctioned**：arch gate
  只禁 raw `Port.open({:spawn_executable, …})`，`System.cmd` 合规（参照
  `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/llm/claude_code.ex` 的 `System.cmd`
  范式）。**不搬 :httpc**。

  ## token 可配置（per-identity 覆盖 + 全局 fallback）

  每个公共动作收一个可选末位 `token` 参（默认 `nil`）——gateway 按 `ctx.caller` 解出的
  per-identity PAT 经此传入（T8）：

    * `token` 非空 → `[{"GH_TOKEN", token}]`（用 caller 自己的）；
    * `token == nil` → 落 `token_env/0`（全局 `github.yaml`，没配再落 gh 自带 auth）。

  `token_env/0` 读 `github.yaml`：配了 token → `[{"GH_TOKEN", t}]` 覆盖；没配 → `[]`，
  调用落到 `gh` 自带 auth（当前暂存的 jjkysy auth 作 debug default）。入站 poller（PrSync）
  不传 token → 走全局（系统级轮询非 per-identity）。

  ## 命令构造（纯函数，可单测）

  每个动作的 `gh` 参数列表由 `*_args/N` 纯函数构造（与 shell 无关——`System.cmd` 直传 argv，
  无 shell 注入面，body/title 的换行与引号安全）。多数走 `gh api`（返回 raw GitHub JSON，
  统一 `Jason.decode`）；`list_open_prs/1` 走 `gh pr list --json`（gh 自有投影）。

  ## 返回

  每个公共函数解析 gh 的 JSON 输出，返回归一化 map。gh 进程非零退出 →
  `{:error, {:gh_exit, code, stderr}}`；gh 不可用（未装/不在 PATH）→ `{:error, {:gh_unavailable, msg}}`。
  实际 shell out 真 github 是 live e2e；本模块单测只覆纯逻辑（`token_env` + `*_args`）。
  """

  alias EzagentPluginGithub.Creds

  # GitHub commit status 的 description 上限（超长被 API 截，先本地 slice）。
  @status_desc_limit 140

  # ---------------------------------------------------------------------------
  # token env（Miro 式可配置覆盖）
  # ---------------------------------------------------------------------------

  @doc """
  调 gh 用的环境变量：配了 github.yaml token → `[{"GH_TOKEN", t}]`；没配 → `[]`。

  `[]` 时 gh 走自带 auth（`gh auth login` 的暂存凭证），作 debug default。
  """
  @spec token_env() :: [{String.t(), String.t()}]
  def token_env do
    case Creds.read() do
      {:ok, %{token: t}} when is_binary(t) and t != "" -> [{"GH_TOKEN", t}]
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # 公共动作（薄包 gh CLI）
  # ---------------------------------------------------------------------------

  @doc "在 repo(`owner/name`) 建 issue。`token` nil → 全局；非空 → caller 自己的 PAT。返回 `{:ok, %{number, url}}`。"
  @spec create_issue(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, %{number: integer(), url: String.t()}} | {:error, term()}
  def create_issue(repo, title, body, token \\ nil) do
    case run_json(issue_create_args(repo, title, body), token) do
      {:ok, %{"number" => n, "html_url" => url}} -> {:ok, %{number: n, url: url}}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc "在 issue/PR(#number) 下 post 评论（issue 与 PR 共用此端点）。`token` nil → 全局。返回 `{:ok, %{url}}`。"
  @spec post_comment(String.t(), integer(), String.t(), String.t() | nil) ::
          {:ok, %{url: String.t()}} | {:error, term()}
  def post_comment(repo, number, body, token \\ nil) do
    case run_json(comment_args(repo, number, body), token) do
      {:ok, %{"html_url" => url}} -> {:ok, %{url: url}}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc "读一个 PR 的状态。`token` nil → 全局。返回 `{:ok, %{state, merged, head_ref, head_sha}}`。"
  @spec get_pull(String.t(), integer(), String.t() | nil) ::
          {:ok,
           %{
             state: String.t(),
             merged: boolean(),
             head_ref: String.t() | nil,
             head_sha: String.t() | nil
           }}
          | {:error, term()}
  def get_pull(repo, number, token \\ nil) do
    case run_json(pull_args(repo, number), token) do
      {:ok, %{"state" => s} = m} ->
        {:ok,
         %{
           state: s,
           merged: Map.get(m, "merged", false),
           head_ref: get_in(m, ["head", "ref"]),
           head_sha: get_in(m, ["head", "sha"])
         }}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  推一个 commit status check 到某 sha（硬 CI 门）。

  `state` ∈ `success`|`failure`|`pending`|`error`（GitHub 语义）。配 branch protection 的
  required status check（`context`）后 `failure` 真能挡合并。`description` 截到 #{@status_desc_limit} 字。
  返回 `{:ok, %{url}}`。
  """
  @spec create_commit_status(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) ::
          {:ok, %{url: String.t() | nil}} | {:error, term()}
  def create_commit_status(repo, sha, state, context, description, token \\ nil)
      when is_binary(sha) and is_binary(state) do
    desc = String.slice(description || "", 0, @status_desc_limit)

    case run_json(status_args(repo, sha, state, context, desc), token) do
      {:ok, %{"state" => _} = m} -> {:ok, %{url: Map.get(m, "url")}}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end

  @doc """
  列出 repo 的 open PR（入站轮询用）。

  返回 `{:ok, [%{number, head_ref, head_sha, state}]}`。走 `gh pr list --json`，字段名
  是 gh 的 camelCase（`headRefName`/`headRefOid`），本函数归一化成 snake_case。
  """
  @spec list_open_prs(String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def list_open_prs(repo, token \\ nil) do
    case run_json(list_open_prs_args(repo), token) do
      {:ok, list} when is_list(list) ->
        {:ok,
         Enum.map(list, fn m ->
           %{
             number: Map.get(m, "number"),
             head_ref: Map.get(m, "headRefName"),
             head_sha: Map.get(m, "headRefOid"),
             state: Map.get(m, "state")
           }
         end)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # 命令参数构造（纯函数 —— 单测覆盖点）
  # ---------------------------------------------------------------------------

  @doc false
  @spec issue_create_args(String.t(), String.t(), String.t()) :: [String.t()]
  def issue_create_args(repo, title, body) do
    ["api", "-X", "POST", "repos/#{repo}/issues", "-f", "title=#{title}", "-f", "body=#{body}"]
  end

  @doc false
  @spec comment_args(String.t(), integer(), String.t()) :: [String.t()]
  def comment_args(repo, number, body) do
    ["api", "-X", "POST", "repos/#{repo}/issues/#{number}/comments", "-f", "body=#{body}"]
  end

  @doc false
  @spec pull_args(String.t(), integer()) :: [String.t()]
  def pull_args(repo, number) do
    ["api", "repos/#{repo}/pulls/#{number}"]
  end

  @doc false
  @spec status_args(String.t(), String.t(), String.t(), String.t(), String.t()) :: [String.t()]
  def status_args(repo, sha, state, context, description) do
    [
      "api",
      "-X",
      "POST",
      "repos/#{repo}/statuses/#{sha}",
      "-f",
      "state=#{state}",
      "-f",
      "context=#{context}",
      "-f",
      "description=#{description}"
    ]
  end

  @doc false
  @spec list_open_prs_args(String.t()) :: [String.t()]
  def list_open_prs_args(repo) do
    [
      "pr",
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--json",
      "number,headRefName,headRefOid,state",
      "--limit",
      "100"
    ]
  end

  # ---------------------------------------------------------------------------
  # 运行（live —— shell out 真 gh，单测不覆盖）
  # ---------------------------------------------------------------------------

  # 跑一次 gh，返回 stdout（exit 0）或结构化错误。token 经 GH_TOKEN env 覆盖。
  defp run(args, token) do
    case System.cmd("gh", args, env: env_for(token), stderr_to_stdout: false) do
      {out, 0} -> {:ok, out}
      {err, code} -> {:error, {:gh_exit, code, String.slice(err, 0, 500)}}
    end
  rescue
    # gh 未装 / 不在 PATH → System.cmd 抛 :enoent；不静默丢，返回显式错误。
    e -> {:error, {:gh_unavailable, Exception.message(e)}}
  end

  # 跑 gh 并 JSON 解析其 stdout。
  defp run_json(args, token) do
    with {:ok, out} <- run(args, token) do
      Jason.decode(out)
    end
  end

  # token 选择：caller 自己的 PAT（非空）覆盖；nil/空 → 落全局 token_env/0。
  defp env_for(token) when is_binary(token) and token != "", do: [{"GH_TOKEN", token}]
  defp env_for(_), do: token_env()
end
