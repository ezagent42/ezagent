defmodule EzagentPluginLoom.MaterialFiles do
  @moduledoc """
  Loom **素材库(目录即库)** —— per-session 磁盘文件树(迁移自 loom-stitch `Materials`)。
  文件落 `<home>/loom_materials/<ws>/<sid>/<rel>`(保留文件夹);v0(cc,cwd + Read)直接读,
  页面用 `/loom/materials/<ws>/<sid>/<rel>` 当 `<img src>`。

  与现有 `EzagentPluginLoom.Materials`(socialware Uploads / resource:// 那套)并存:这个是
  前端素材面板 + cc-v0 用的原生文件树;路径净化防目录遍历。用 `Ezagent.Home.path` 尊重
  sandbox home(测试不污染真实 FS)。
  """

  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg .bmp .ico)
  @text_exts ~w(.txt .md .markdown .json .csv .html .css .js .jsx .ts .tsx .yml .yaml)

  @doc "本 session 素材根目录(绝对路径)。"
  @spec dir(String.t(), String.t()) :: String.t()
  def dir(ws, sid) when is_binary(ws) and is_binary(sid) do
    Path.join([Ezagent.Home.path("loom_materials"), ws, sid])
  end

  @doc "确保目录存在。返回目录路径。"
  @spec ensure_dir(String.t(), String.t()) :: String.t()
  def ensure_dir(ws, sid) do
    d = dir(ws, sid)
    File.mkdir_p!(d)
    d
  rescue
    _ -> dir(ws, sid)
  end

  @doc "存上传文件到 `rel_path`(保留文件夹)。{:ok, rel} | {:error, _}。"
  @spec save_file(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def save_file(ws, sid, rel_path, src_tmp_path) when is_binary(src_tmp_path) do
    with {:ok, rel} <- safe_rel(rel_path) do
      dest = Path.join(ensure_dir(ws, sid), rel)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(src_tmp_path, dest)
      {:ok, rel}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "删一条素材(相对路径,目录遍历受限)。"
  @spec remove(String.t(), String.t(), String.t()) :: :ok
  def remove(ws, sid, rel_path) do
    with {:ok, rel} <- safe_rel(rel_path) do
      _ = File.rm(Path.join(dir(ws, sid), rel))
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @doc "列出全部素材(相对路径 + 类型 + 大小),按路径排序。"
  @spec list(String.t(), String.t()) :: [map()]
  def list(ws, sid) do
    root = dir(ws, sid)

    walk(root, "")
    |> Enum.sort()
    |> Enum.map(fn rel ->
      %{
        "path" => rel,
        "name" => Path.basename(rel),
        "type" => type_of(rel),
        "size" => file_size(Path.join(root, rel))
      }
    end)
  end

  @doc "读一条素材(给 serve 用)。{:ok, bin, rel} | :error。"
  @spec read(String.t(), String.t(), String.t()) :: {:ok, binary(), String.t()} | :error
  def read(ws, sid, rel_path) do
    with {:ok, rel} <- safe_rel(rel_path),
         path = Path.join(dir(ws, sid), rel),
         true <- File.regular?(path),
         {:ok, bin} <- File.read(path) do
      {:ok, bin, rel}
    else
      _ -> :error
    end
  end

  @doc "按扩展名粗分类型:image | text | other。"
  @spec type_of(String.t()) :: String.t()
  def type_of(name) do
    ext = name |> Path.extname() |> String.downcase()

    cond do
      ext in @image_exts -> "image"
      ext in @text_exts -> "text"
      true -> "other"
    end
  end

  defp walk(root, rel) do
    full = Path.join(root, rel)

    case File.ls(full) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn e ->
          child = if rel == "", do: e, else: Path.join(rel, e)
          if File.dir?(Path.join(root, child)), do: walk(root, child), else: [child]
        end)

      _ ->
        []
    end
  end

  defp safe_rel(path) do
    parts =
      path
      |> to_string()
      |> String.split(["/", "\\"])
      |> Enum.reject(&(&1 in ["", ".", ".."]))

    if parts == [], do: :error, else: {:ok, Path.join(parts)}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: s}} -> s
      _ -> 0
    end
  end
end
