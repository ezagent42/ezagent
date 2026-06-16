defmodule Ezagent.PluginLoom.Materials do
  @moduledoc """
  Loom **素材库**(2026-06-12 重写为「目录即库」)。

  每个 loom session 有一个素材根目录(session 初始化时建好):

      ~/.ezagent/<profile>/loom_materials/<ws>/<sid>/

  用户从素材库 modal 上传**文件 / 文件夹**(保留目录结构)直接落进这里;**文件系统本身就是库**
  (没有旁路 JSON 元数据)。v0(本地 Claude Code)生成 / 修改页面时,这个目录被设为它的
  **工作目录(cwd)** 并放开 `Read/Glob/LS` —— 它能像平时一样 `Read zuatu-source-backup/src/App.jsx`
  读任意素材、浏览整个文件夹,**不受 prompt 预算限**。图片素材在页面里用
  `/loom/materials/<ws>/<sid>/<相对路径>` 公开 URL 引用。
  """

  @image_exts ~w(.png .jpg .jpeg .gif .webp .svg .bmp .ico)
  @text_exts ~w(.html .htm .txt .md .markdown .json .css .js .jsx .ts .tsx .csv .xml .yaml .yml .vue .svelte)

  # ---- 目录 ----------------------------------------------------------------

  @doc "本 session 素材根目录(绝对路径)。"
  @spec dir(String.t(), String.t()) :: String.t()
  def dir(ws, sid) when is_binary(ws) and is_binary(sid) do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_materials/#{ws}/#{sid}")
  end

  @doc "确保素材目录存在(session 初始化 / 首次上传时调)。返回目录路径。"
  @spec ensure_dir(String.t(), String.t()) :: String.t()
  def ensure_dir(ws, sid) do
    d = dir(ws, sid)
    File.mkdir_p!(d)
    d
  rescue
    _ -> dir(ws, sid)
  end

  # ---- 增 / 删 / 列 --------------------------------------------------------

  @doc "把一个上传文件存进素材目录的 `rel_path`(保留文件夹)。返回 {:ok, rel} | {:error, _}。"
  @spec save_file(String.t(), String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
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

  @doc "列出本 session 全部素材(相对路径 + 类型 + 大小),按路径排序。"
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

  @doc "读一条素材(给 serve 用)。"
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

  # ---- v0 manifest ---------------------------------------------------------

  @doc """
  渲染本 session 素材库**清单**给 v0(Claude Code 用 cwd + Read 读实际内容,这里只给目录树)。
  无素材 → "".
  """
  @spec render_for_builder(String.t(), String.t()) :: String.t()
  def render_for_builder(ws, sid) do
    items = list(ws, sid)

    if items == [] do
      ""
    else
      lines =
        Enum.map(items, fn it ->
          rel = it["path"]

          case it["type"] do
            "image" -> "- #{rel}  [图片:页面里用 `/loom/materials/#{ws}/#{sid}/#{rel}` 当 <img src>]"
            "text" -> "- #{rel}  [文本:`Read #{rel}` 读内容]"
            _ -> "- #{rel}  [`Read #{rel}` 看,或当资源 `/loom/materials/#{ws}/#{sid}/#{rel}`]"
          end
        end)

      """

      # 用户上传的素材库(就在你的**工作目录**里)
      下面是清单。**需要某个素材的实际内容时,用 `Read <相对路径>` 工具读**(用 `Glob`/`LS` 浏览),
      不要凭空猜。图片素材用上面给的 `/loom/materials/...` URL 在页面里 `<img src>` 引用。
      #{Enum.join(lines, "\n")}
      """
    end
  end

  # ---- helpers -------------------------------------------------------------

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

  # 递归列相对路径。
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

  # 相对路径净化:去掉空 / "." / ".." 段,防目录遍历;空 → :error。
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
