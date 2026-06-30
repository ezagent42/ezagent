defmodule EzagentPluginKanban.BoardConfig do
  @moduledoc """
  每张看板图**自己的**出站连接器配置：`github_repo`（owner/name）+ `miro_board`（板名）。

  一图一仓库/一板——所以配置**按图存**（不是全局）。按图 URI 存一份 JSON
  （`system://credentials/kanban-boards.json` 是 `{图URI → %{github_repo, miro_board}}` 的 map）。

  **token 不在这里**：access token 留在 plugin 全局（`github.yaml`/`miro.yaml`），上线后每个用户配自己的。
  这里只放不敏感的 repo / 板名（板名而非 id，因为 id 用户不可见）。
  """

  @doc "读某张图的配置。返回 `%{github_repo, miro_board, session_uri}`（缺省 nil）。"
  @spec read(URI.t() | String.t()) :: %{
          github_repo: String.t() | nil,
          miro_board: String.t() | nil,
          session_uri: String.t() | nil
        }
  def read(uri) do
    m = Map.get(read_all(), uri_key(uri), %{})

    %{
      github_repo: blank_to_nil(m["github_repo"]),
      miro_board: blank_to_nil(m["miro_board"]),
      session_uri: blank_to_nil(m["session_uri"])
    }
  end

  @doc """
  写某张图的配置（**合并**语义：只更新 cfg 里出现的键，其余保留）。

  `github_repo`/`miro_board`（set_board_config 配出站）与 `session_uri`（bind_session 绑路由
  会话，B1）各自独立设置、互不覆盖。空串存 nil。
  """
  @spec write(URI.t() | String.t(), %{
          optional(:github_repo) => String.t() | nil,
          optional(:miro_board) => String.t() | nil,
          optional(:session_uri) => String.t() | nil
        }) :: :ok | {:error, term()}
  def write(uri, cfg) do
    existing = Map.get(read_all(), uri_key(uri), %{})

    entry =
      existing
      # 補存 board URI 本身（§3 缺口修法）：key 是 `Ezagent.URI.stable_key`，
      # 可能不可逆 → 反查（boards_for_session/1）拿到 key 还原不了 board URI。
      # 每次写都把完整 board URI 串存进 entry["uri"]，反查直接读它。
      |> Map.put("uri", uri_string(uri))
      |> put_if_present(cfg, :github_repo, "github_repo")
      |> put_if_present(cfg, :miro_board, "miro_board")
      |> put_if_present(cfg, :session_uri, "session_uri")

    updated = Map.put(read_all(), uri_key(uri), entry)
    file = path()
    _ = File.mkdir_p(Path.dirname(file))

    case File.write(file, Jason.encode!(updated)) do
      :ok ->
        _ = File.chmod(file, 0o600)
        :ok

      err ->
        err
    end
  end

  @doc """
  反查：列出**绑定到 `session` 的所有 board URI**（板级 `session_uri` == 该会话）。

  正查（board→session）走 `read/1`；本函数是 Layer-3 session tab 条件渲染的前置——
  world 据「该 session 有没有绑定板」决定是否长出 kanban tab（board-entry-and-modular-ui
  §3）。线性扫 `read_all/0`（O(板数)，板少无碍；量大需反向索引，记一笔暂不做），过滤
  `session_uri` 命中，返回每个 entry 補存的完整 board URI 串（`write/2` 存的 `entry["uri"]`）。
  """
  @spec boards_for_session(URI.t() | String.t()) :: [String.t()]
  def boards_for_session(session) do
    session_str = uri_string(session)

    read_all()
    |> Enum.flat_map(fn {key, entry} ->
      with true <- is_map(entry),
           true <- blank_to_nil(entry["session_uri"]) == session_str,
           board_uri when is_binary(board_uri) <- entry["uri"] || key do
        [board_uri]
      else
        _ -> []
      end
    end)
  end

  @doc """
  谓词：`session` 是否绑了**至少一块板**。Layer-3 `session_tabs/0` 的 `condition`——
  world 经它判该 session 该不该出 kanban tab（便宜的文件读，不走 dispatch）。
  """
  @spec session_bound?(URI.t() | String.t()) :: boolean()
  def session_bound?(session), do: boards_for_session(session) != []

  @doc false
  @spec read_all() :: map()
  def read_all do
    case File.read(path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp path,
    do: Ezagent.System.FsResolver.path!(Ezagent.URI.system("credentials", "kanban-boards.json"))

  defp uri_key(%URI{} = uri), do: Ezagent.URI.stable_key(uri)
  defp uri_key(s) when is_binary(s), do: s

  defp uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp uri_string(s) when is_binary(s), do: s
  defp uri_string(_), do: nil

  # 合并写：只在 cfg 含该键时更新 entry，否则保留 existing 的旧值。
  defp put_if_present(entry, cfg, src_key, dst_key) do
    if Map.has_key?(cfg, src_key) do
      Map.put(entry, dst_key, blank_to_nil(Map.get(cfg, src_key)))
    else
      entry
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
