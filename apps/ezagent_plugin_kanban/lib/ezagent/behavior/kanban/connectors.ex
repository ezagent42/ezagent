defmodule Ezagent.ActionSet.Kanban.Connectors do
  @moduledoc """
  Kanban Behavior 的**出站连接器动作实现体**（df-tech 下沉：原在 world kanban_actions.ex，
  先搬进 `Ezagent.ActionSet.Kanban` 收口，再从该 Behavior 主模块拆出实现体到本模块——
  主模块只留 `action/3` 宏声明 + `def handle_<x>(a,c), do: Connectors.<x>(a,c)` 薄转发，
  契约/宏不变，仅把实现体搬来此处压主模块 LOC）。

  这组动作：`sync_miro` / `set_board_config` / `save_miro_creds`。

  ## GitHub 集成已整体移出 kanban
  原来的 GitHub 主动连接器（`sync_github` / `push_pr` / `sync_prs` / `save_github_creds`
  调 GitHub API），连同 `register_pr` / `attach_code_file`（把 PR 号 / commit SHA 拼成
  github 链接挂节点）和 board 级 `github_repo` 配置**全部删除**。要挂代码库、看 PR
  进度，用独立的 **github plugin** 直接同步——kanban 不再碰 github。留下的出站连接器
  仅 Miro 一侧。

  ## 授权 + effect 契约（与主模块一致）
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

  # 写本图连接器配置（miro 板名）。任意持 cap 的成员（cap gate 收口）。
  @doc false
  def set_board_config(%{miro_board: miro_board}, ctx) do
    uri = ctx[:self_uri]

    case BoardConfig.write(uri, %{miro_board: miro_board}) do
      :ok ->
        {:ok, %{miro_board: BoardConfig.read(uri).miro_board}, []}

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

  # kanban 实例 URI 的末段名（建 Miro 板默认名用）。
  defp uri_name(%URI{} = uri), do: uri |> URI.to_string() |> String.split("/") |> List.last()
  defp uri_name(_), do: "kanban"
end
