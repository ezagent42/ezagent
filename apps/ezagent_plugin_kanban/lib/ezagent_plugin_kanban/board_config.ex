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

  defp read_all do
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
