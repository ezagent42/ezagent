defmodule EzagentPluginKanban.BoardConfig do
  @moduledoc """
  每张看板图**自己的**出站连接器配置：`miro_board`（板名）。

  一图一板——所以配置**按图存**（不是全局）。按图 URI 存一份 JSON
  （`system://credentials/kanban-boards.json` 是 `{图URI → %{miro_board}}` 的 map）。

  **token 不在这里**：access token 留在 plugin 全局（`miro.yaml`），上线后每个用户配自己的。
  这里只放不敏感的板名（板名而非 id，因为 id 用户不可见）。
  """

  @doc "读某张图的配置。返回 `%{miro_board: name|nil}`。"
  @spec read(URI.t() | String.t()) :: %{miro_board: String.t() | nil}
  def read(uri) do
    m = Map.get(read_all(), uri_key(uri), %{})
    %{miro_board: blank_to_nil(m["miro_board"])}
  end

  @doc "写某张图的配置（miro_board，空串存 nil）。"
  @spec write(URI.t() | String.t(), %{optional(:miro_board) => String.t() | nil}) ::
          :ok | {:error, term()}
  def write(uri, cfg) do
    entry = %{"miro_board" => blank_to_nil(Map.get(cfg, :miro_board))}

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

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
