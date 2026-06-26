defmodule Ezagent.Behavior.Kanban.Connectors do
  @moduledoc """
  Kanban Behavior 的**出站连接器动作实现体**（df-tech 下沉：原在 world kanban_actions.ex，
  先搬进 `Ezagent.Behavior.Kanban` 收口，再从该 Behavior 主模块拆出实现体到本模块——
  主模块只留 `action/3` 宏声明 + `def handle_<x>(a,c), do: Connectors.<x>(a,c)` 薄转发，
  契约/宏不变，仅把实现体搬来此处压主模块 LOC）。

  这组动作：`sync_github` / `push_pr` / `register_pr` / `attach_code_file` / `sync_prs` /
  `sync_miro` / `set_board_config` / `save_github_creds` / `save_miro_creds`。

  ## 授权 + effect 契约（与主模块一致，未变）
  - 节点级动作（sync_github/push_pr/register_pr/attach_code_file）沿用 `Shared.owner_or_admin?/2`
    闸——同 attach_artifact 要节点 owner 或 admin。
  - 图级动作（sync_prs/sync_miro/set_board_config）= 任意持 cap 的成员（cap gate 已收口）。
  - 凭证保存（save_*_creds）= admin-gated（全局配置）。
  - 出站 HTTP 副作用在 Kind 进程内同步调（拿结果决定是否 commit + 拼回返回值，纯 `{:ref}`
    替换表达不了这层逻辑，对齐 UserTokens handler 内联 Token.list 先例）；只有真改树
    （挂 artifact / set done）才经 `Shared.commit/1`——**树写入仍是全 Behavior 唯一的
    `tree set-effect（经 commit/1 收口）` 收口点**。
  """

  alias Ezagent.Behavior.Kanban.Shared
  alias EzagentPluginKanban.BoardConfig
  alias EzagentPluginKanban.Ci
  alias EzagentPluginKanban.Github
  alias EzagentPluginKanban.Miro
  alias EzagentPluginKanban.MiroSync

  # 出站到 GitHub：建 issue + 回挂 issue 产物到节点（同节点 = 折进一次 commit，不自分发）。
  @doc false
  def sync_github(%{id: id}, ctx) do
    t = Shared.tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not Shared.owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case board_creds(ctx) do
          {:ok, %{token: token, repo: repo}} when is_binary(repo) ->
            n = t.nodes[id]

            case Github.create_issue(token, repo, n.title || "(untitled)", github_issue_body(n)) do
              {:ok, %{number: num, url: url}} ->
                art =
                  Shared.normalize_artifact(%{
                    tool: "github",
                    kind: "issue",
                    ref: "##{num}",
                    url: url
                  })

                new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
                {:ok, %{number: num, url: url}, [Shared.commit(%{t | nodes: new_nodes})]}

              {:error, reason} ->
                {:error, gh_reason(reason)}
            end

          {:ok, %{repo: nil}} ->
            {:error, :github_repo_missing}

          {:error, _} ->
            {:error, :github_token_missing}
        end
    end
  end

  # 出站 PR 留言 + 硬 CI 门：把产品需求摘要 post 到 PR（软），再把 check_pr_gate verdict
  # 推成 GitHub commit status check（硬，红挡合并）。两步都是纯出站、不改树。
  @doc false
  def push_pr(%{id: id}, ctx) do
    t = Shared.tree(ctx)

    with node when is_map(node) <- Map.get(t.nodes, id),
         true <- Shared.owner_or_admin?(ctx, node) or :forbidden,
         {:ok, %{token: token, repo: repo}} when is_binary(repo) <- board_creds(ctx),
         pr when is_integer(pr) <- node_pr(node),
         digest <- Ci.requirement_digest(t, id),
         {:ok, url} <- Github.post_comment(token, repo, pr, digest) do
      # 软留言已发；再推硬 CI status check。best-effort：拿不到 sha / 推失败 → gate_state
      # 返回 "skipped"（不回滚已发留言、不算 push_pr 失败），调用方可见、非静默丢。
      gate_state = push_ci_status(token, repo, pr, Ci.check_pr_gate(t, id))
      {:ok, %{url: url, gate_state: gate_state}, []}
    else
      nil -> {:error, :node_not_found}
      :forbidden -> {:error, :forbidden}
      {:ok, %{repo: nil}} -> {:error, :github_repo_missing}
      {:error, :github_token_missing} -> {:error, :github_token_missing}
      {:error, reason} -> {:error, gh_reason(reason)}
      false -> {:error, :no_pr_registered}
      _ -> {:error, :no_pr_registered}
    end
  end

  # 把 CI verdict 推成 GitHub commit status（硬门）。返回推上的 state 字符串，失败返回 "skipped"。
  defp push_ci_status(token, repo, pr, verdict) do
    with {:ok, %{head_sha: sha}} when is_binary(sha) <- Github.get_pull(token, repo, pr),
         state <- Ci.gate_state(verdict),
         {:ok, _} <-
           Github.create_commit_status(token, repo, sha, state,
             context: "ezagent/ci-gate",
             description: "ezagent 前置判据 #{verdict.score}/#{verdict.max}"
           ) do
      state
    else
      _ -> "skipped"
    end
  end

  # 登记 PR：把 PR 链接挂到节点（不发评论；出站留言在 push_pr）。
  @doc false
  def register_pr(%{id: id, pr: pr_in}, ctx) do
    t = Shared.tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not Shared.owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case {to_pr_number(pr_in), board_creds(ctx)} do
          {pr, {:ok, %{repo: repo}}} when is_integer(pr) and is_binary(repo) ->
            url = "https://github.com/#{repo}/pull/#{pr}"

            art =
              Shared.normalize_artifact(%{tool: "github", kind: "pr", ref: "##{pr}", url: url})

            n = t.nodes[id]
            new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
            {:ok, %{}, [Shared.commit(%{t | nodes: new_nodes})]}

          {:error, _} ->
            {:error, :bad_pr_number}

          {_, {:ok, %{repo: nil}}} ->
            {:error, :github_repo_missing}

          _ ->
            {:error, :github_token_missing}
        end
    end
  end

  # 挂代码文件：钉 commit SHA + 路径 → 拼 github blob 链接（永久可点）。repo 取本图配置。
  @doc false
  def attach_code_file(%{id: id, sha: sha, path: path}, ctx)
      when is_binary(sha) and is_binary(path) do
    t = Shared.tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not Shared.owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case board_creds(ctx) do
          {:ok, %{repo: repo}} when is_binary(repo) ->
            clean = String.trim_leading(path, "/")
            url = "https://github.com/#{repo}/blob/#{sha}/#{clean}"
            name = clean |> String.split("/") |> List.last()

            art =
              Shared.normalize_artifact(%{
                tool: "github",
                kind: "github_file",
                ref: name,
                url: url
              })

            n = t.nodes[id]
            new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
            {:ok, %{url: url}, [Shared.commit(%{t | nodes: new_nodes})]}

          {:ok, %{repo: nil}} ->
            {:error, :github_repo_missing}

          _ ->
            {:error, :github_token_missing}
        end
    end
  end

  # 轮询已登记 PR 的节点；merged/closed → set_status done（折进一次 commit）。
  @doc false
  def sync_prs(_args, ctx) do
    t = Shared.tree(ctx)

    case board_creds(ctx) do
      {:ok, %{token: token, repo: repo}} when is_binary(repo) ->
        {new_nodes, advanced, unreachable?} = advance_merged_prs(t.nodes, token, repo)

        cond do
          unreachable? -> {:error, :github_unreachable}
          advanced == 0 -> {:ok, %{advanced: 0}, []}
          true -> {:ok, %{advanced: advanced}, [Shared.commit(%{t | nodes: new_nodes})]}
        end

      {:ok, %{repo: nil}} ->
        {:error, :github_repo_missing}

      _ ->
        {:error, :github_token_missing}
    end
  end

  # 一键推 Miro：已绑定则 sync；未绑定则建板+绑定+sync。板名取本图配置或默认。
  @doc false
  def sync_miro(_args, ctx) do
    uri = ctx[:self_uri]

    miro_name =
      case BoardConfig.read(uri).miro_board do
        name when is_binary(name) and name != "" -> name
        _ -> "ezagent: " <> uri_name(uri)
      end

    case MiroSync.sync_or_bind(uri, miro_name) do
      {:ok, %{board_id: board}} -> {:ok, %{board_id: board}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # 写本图连接器配置（github_repo + miro 板名）。任意持 cap 的成员（cap gate 收口）。
  @doc false
  def set_board_config(%{github_repo: github_repo, miro_board: miro_board}, ctx) do
    uri = ctx[:self_uri]

    case BoardConfig.write(uri, %{github_repo: github_repo, miro_board: miro_board}) do
      :ok ->
        c = BoardConfig.read(uri)
        {:ok, %{github_repo: c.github_repo, miro_board: c.miro_board}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 绑定本看板到一个会话（B1）：之后接力动作向该会话 session.send 公告、重入路由。
  # 任意持 cap 的成员（cap gate 收口）；合并写不动 github/miro 配置。
  @doc false
  def bind_session(%{session_uri: session_uri}, ctx) do
    uri = ctx[:self_uri]

    case BoardConfig.write(uri, %{session_uri: session_uri}) do
      :ok -> {:ok, %{session_uri: BoardConfig.read(uri).session_uri}, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # 保存全局 GitHub 凭证（admin-gated）。
  @doc false
  def save_github_creds(%{access_token: token} = args, ctx) when is_binary(token) do
    if Shared.admin?(ctx) do
      case Github.write_creds(%{access_token: token, repo: Map.get(args, :repo, "")}) do
        :ok -> {:ok, %{}, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  # 保存全局 Miro 凭证（admin-gated）。
  @doc false
  def save_miro_creds(%{access_token: token} = args, ctx) when is_binary(token) do
    if Shared.admin?(ctx) do
      case Miro.write_creds(%{access_token: token, board_id: Map.get(args, :board_id, "")}) do
        :ok -> {:ok, %{}, []}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :unauthorized}
    end
  end

  # --- 出站 helpers ---------------------------------------------------

  # 每图独立配置：token 取全局（github.yaml），repo 取本图配置。返回 {:ok,%{token,repo}}|{:error,_}。
  defp board_creds(ctx) do
    case Github.read_creds() do
      {:ok, %{token: token}} ->
        repo =
          case ctx[:self_uri] do
            %URI{} = uri -> BoardConfig.read(uri).github_repo
            _ -> nil
          end

        {:ok, %{token: token, repo: repo}}

      err ->
        err
    end
  end

  # 拼 github issue body：节点 stage/status + inline content 产物。
  defp github_issue_body(n) do
    content =
      (Map.get(n, :artifacts) || [])
      |> Enum.map(&Map.get(&1, :content))
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    "**stage**: #{n.stage} · **status**: #{n.status}\n\n" <>
      content <> "\n\n_由 ezagent kanban 节点出站_"
  end

  # 从节点 pr 产物里抠出 PR 号（"#42"→42）。artifacts 用 atom 键（已 normalize）。
  defp node_pr(node) do
    node
    |> Map.get(:artifacts, [])
    |> Enum.find_value(fn a ->
      if to_string(Map.get(a, :kind)) == "pr" do
        case to_pr_number(to_string(Map.get(a, :ref))) do
          n when is_integer(n) -> n
          _ -> nil
        end
      end
    end)
  end

  defp to_pr_number(pr) when is_integer(pr), do: pr

  defp to_pr_number(pr) when is_binary(pr) do
    case pr |> String.trim() |> String.trim_leading("#") |> Integer.parse() do
      {n, _} -> n
      :error -> :error
    end
  end

  defp to_pr_number(_), do: :error

  # 遍历登记过 PR 的节点查状态；merged/closed 的 set status=done。返回 {新nodes,推进数,连不上?}。
  defp advance_merged_prs(nodes, token, repo) do
    Enum.reduce(nodes, {nodes, 0, false}, fn {id, node}, {acc_nodes, n, unreachable?} ->
      case node_pr(node) do
        nil ->
          {acc_nodes, n, unreachable?}

        pr ->
          case Github.get_pull(token, repo, pr) do
            {:ok, %{merged: true}} -> {done_node(acc_nodes, id), n + 1, unreachable?}
            {:ok, %{state: "closed"}} -> {done_node(acc_nodes, id), n + 1, unreachable?}
            {:error, {:http_error, _}} -> {acc_nodes, n, true}
            _ -> {acc_nodes, n, unreachable?}
          end
      end
    end)
  end

  defp done_node(nodes, id) do
    case nodes[id] do
      %{owner: o} = node when not is_nil(o) -> Map.put(nodes, id, %{node | status: :done})
      _ -> nodes
    end
  end

  # kanban 实例 URI 的末段名（建 Miro 板默认名用）。
  defp uri_name(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()
  defp uri_name(_), do: "kanban"

  # GitHub 失败 → 干净错误 atom（前端 dispatchError 映射成中文提示）。
  defp gh_reason({:http_status, code, _}) when code in [401, 403], do: :github_unauthorized
  defp gh_reason({:http_status, 404, _}), do: :github_not_found
  defp gh_reason({:http_status, code, _}), do: String.to_atom("github_http_#{code}")
  defp gh_reason({:http_error, _}), do: :github_unreachable
  defp gh_reason(other) when is_atom(other), do: other
  defp gh_reason(other), do: {:github_error, other}
end
