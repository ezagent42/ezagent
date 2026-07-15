defmodule Ezagent.ActionSet.Kanban.Connectors do
  @moduledoc """
  Kanban Behavior 的**出站连接器动作实现体**（df-tech 下沉：原在 world kanban_actions.ex，
  先搬进 `Ezagent.ActionSet.Kanban` 收口，再从该 Behavior 主模块拆出实现体到本模块——
  主模块只留 `action/3` 宏声明 + `def handle_<x>(a,c), do: Connectors.<x>(a,c)` 薄转发，
  契约/宏不变，仅把实现体搬来此处压主模块 LOC）。

  这组动作：`register_pr` / `attach_code_file` / `sync_miro` / `set_board_config` /
  `save_miro_creds`。

  ## GitHub 主动连接器已删（只留节点 git 定位数据）
  原来的 GitHub 主动连接器（`sync_github` 建 issue / `push_pr` post 评论 / `sync_prs`
  轮询 PR / `save_github_creds` 存凭证——都主动调 GitHub API）已整体删除，连同
  `EzagentPluginKanban.Github` REST 客户端。这里留下的 `register_pr` / `attach_code_file`
  是**纯数据**：把 git 引用（PR 号、commit SHA + 路径）拼成 github 链接挂到节点
  `artifacts`，**不发任何出站 HTTP**。repo 取本图配置（`BoardConfig.github_repo`，纯
  数据，仍可经 `set_board_config` 记录）。

  ## 授权 + effect 契约（与主模块一致）
  - 节点级动作（register_pr/attach_code_file）沿用 `Shared.owner_or_admin?/2`
    闸——同 attach_artifact 要节点 owner 或 admin。
  - 图级动作（sync_miro/set_board_config）= 任意持 cap 的成员（cap gate 已收口）。
  - 凭证保存（save_miro_creds）= admin-gated（全局配置）。
  - 出站 HTTP 副作用（仅 Miro 侧）在 Kind 进程内同步调（拿结果决定是否 commit + 拼回
    返回值）；真改树（挂 artifact）经 `Shared.commit/1`——**树写入仍是全 Behavior 唯一的
    `tree set-effect（经 commit/1 收口）` 收口点**。
  """

  alias Ezagent.ActionSet.Kanban.Shared
  alias EzagentPluginKanban.BoardConfig
  alias EzagentPluginKanban.Miro
  alias EzagentPluginKanban.MiroSync

  # 登记 PR（纯数据）：把 PR 号拼成 github PR 链接挂到节点 artifacts（不发任何出站
  # HTTP，不发评论）。repo 取本图配置（BoardConfig，纯数据）。
  @doc false
  def register_pr(%{id: id, pr: pr_in}, ctx) do
    t = Shared.tree(ctx)

    cond do
      not Map.has_key?(t.nodes, id) ->
        {:error, :node_not_found}

      not Shared.owner_or_admin?(ctx, t.nodes[id]) ->
        {:error, :forbidden}

      true ->
        case {to_pr_number(pr_in), board_repo(ctx)} do
          {pr, repo} when is_integer(pr) and is_binary(repo) ->
            url = "https://github.com/#{repo}/pull/#{pr}"

            art =
              Shared.normalize_artifact(%{tool: "github", kind: "pr", ref: "##{pr}", url: url})

            n = t.nodes[id]
            new_nodes = Map.put(t.nodes, id, %{n | artifacts: n.artifacts ++ [art]})
            {:ok, %{}, [Shared.commit(%{t | nodes: new_nodes})]}

          {:error, _} ->
            {:error, :bad_pr_number}

          {_, nil} ->
            {:error, :github_repo_missing}
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
        case board_repo(ctx) do
          repo when is_binary(repo) ->
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

          nil ->
            {:error, :github_repo_missing}
        end
    end
  end

  # 一键推 Miro：已绑定则 sync；未绑定则建板+绑定+sync。
  # 板名解析序（去gh 决策：同步时弹框填名）：本次 args.name > 本图配置 > URI 名默认。
  @doc false
  def sync_miro(args, ctx) do
    uri = ctx[:self_uri]

    miro_name =
      case Map.get(args, :name) do
        name when is_binary(name) and name != "" ->
          name

        _ ->
          case BoardConfig.read(uri).miro_board do
            name when is_binary(name) and name != "" -> name
            _ -> "ezagent: " <> uri_name(uri)
          end
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

  # --- helpers ---------------------------------------------------

  # 本图 repo（纯数据，取本图 BoardConfig 配置）。返回 repo 字符串 | nil。
  # GitHub 主动连接器删后，register_pr / attach_code_file 只用 repo 拼链接，不需 token。
  defp board_repo(ctx) do
    case ctx[:self_uri] do
      %URI{} = uri -> BoardConfig.read(uri).github_repo
      _ -> nil
    end
  end

  defp to_pr_number(pr) when is_integer(pr), do: pr

  defp to_pr_number(pr) when is_binary(pr) do
    case pr |> String.trim() |> String.trim_leading("#") |> Integer.parse() do
      {n, _} -> n
      :error -> :error
    end
  end

  defp to_pr_number(_), do: :error

  # kanban 实例 URI 的末段名（建 Miro 板默认名用）。
  defp uri_name(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()
  defp uri_name(_), do: "kanban"
end
