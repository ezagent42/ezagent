defmodule Ezagent.PluginLoom.Pages do
  @moduledoc """
  Loom **per-session 多页**(2026-06-16)。

  一个发布物默认是**一页**;作者可以在编辑页增删页,每个页:
  - `id`     — 稳定标识(slug);默认页固定 `home`,**不可删**。
  - `slug`   — `?page=<slug>` 的路由值(= id,保持一致)。
  - `title`  — 页名(编辑器下拉 / 页配置显示)。
  - `salesperson` — 该页是否显示 salesperson 输入框(每页独立)。
  - `source` — 该页的页面源码(files map);**builder 改的是「活动页」**。

  ## 权威与同步

  - 「活动页」(`active`)的源码以**编排器 slice `loom_source`** 为准(builder 实时写);
    本旁路存**各页源码 + 元数据**。前端每次渲染活动页后回存 `put_source`,切页前也回存,
    所以非活动页的源码 = 它上次活动时的最新。发布时活动页用 slice 的最新覆盖(见 web_plug)。
  - builder 的「当前源码」读 `active_source/2`(本旁路的活动页),所以**切页 = 改 active**,
    builder 自然改新页,无需写 slice。

  旁路 JSON:`~/.ezagent/<profile>/loom_pages.json`,key = session 字符串 →

      %{ "active" => "home", "pages" => [ %{"id","slug","title","salesperson","source"}, ... ] }
  """

  @default_id "home"
  @id_re ~r/^[a-z0-9][a-z0-9_-]*$/
  @max_pages 20

  def default_id, do: @default_id

  # ── store ──

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_pages.json")
  end

  defp skey(ws, sid), do: "session://loom/#{ws}/#{sid}"

  defp load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp save_all(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
  end

  defp read_session(ws, sid), do: Map.get(load_all(), skey(ws, sid))

  defp write_session(ws, sid, data) do
    all = load_all() |> Map.put(skey(ws, sid), data)
    save_all(all)
    data
  end

  # ── normalize ──

  defp norm_page(p, idx) when is_map(p) do
    id = p |> Map.get("id", "") |> to_string() |> normalize_id(idx)

    %{
      "id" => id,
      "slug" => id,
      "title" => p |> Map.get("title", "") |> to_string() |> default_title(id),
      "salesperson" => Map.get(p, "salesperson", true) == true,
      "source" => normalize_source(Map.get(p, "source"))
    }
  end

  defp norm_page(_, idx), do: norm_page(%{}, idx)

  defp normalize_id(id, idx) do
    if Regex.match?(@id_re, id), do: id, else: if(idx == 0, do: @default_id, else: "page#{idx}")
  end

  defp default_title("", id), do: id
  defp default_title(t, _), do: t

  defp normalize_source(s) do
    EzagentPluginLoom.Prompts.normalize_source(s || %{})
  end

  # ── public API ──

  @doc "读某 session 的多页结构(无 → nil,让调用方用 ensure_default 兜)。"
  @spec get(String.t(), String.t()) :: map() | nil
  def get(ws, sid) when is_binary(ws) and is_binary(sid) do
    case read_session(ws, sid) do
      %{"pages" => list} = m when is_list(list) and list != [] ->
        pages = list |> Enum.with_index() |> Enum.map(fn {p, i} -> norm_page(p, i) end)
        %{"active" => active_or_first(Map.get(m, "active"), pages), "pages" => pages}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def get(_, _), do: nil

  defp active_or_first(active, pages) do
    ids = Enum.map(pages, & &1["id"])
    if active in ids, do: active, else: List.first(ids)
  end

  @doc "确保有多页结构;没有就用 `default_source` 建一个默认页 `home`。返回完整结构。"
  @spec ensure_default(String.t(), String.t(), map() | binary() | nil) :: map()
  def ensure_default(ws, sid, default_source) do
    case get(ws, sid) do
      %{} = m ->
        m

      nil ->
        data = %{
          "active" => @default_id,
          "pages" => [
            %{
              "id" => @default_id,
              "slug" => @default_id,
              "title" => "首页",
              "salesperson" => true,
              "source" => normalize_source(default_source)
            }
          ]
        }

        write_session(ws, sid, data)
    end
  rescue
    _ -> %{"active" => @default_id, "pages" => []}
  end

  @doc """
  整盘写**元数据**(增删/改名/排序/salesperson 开关)。保留各页已存的 `source`(按 id 配),
  新页给空 seed 源;默认页 `home` 不可删(强制保留 + 置顶)。返回更新后的完整结构。
  `incoming` = `%{"active"=>id, "pages"=>[%{"id","title","salesperson"}, ...]}`。
  """
  @spec put_meta(String.t(), String.t(), map(), map() | binary() | nil) ::
          {:ok, map()} | {:error, term()}
  def put_meta(ws, sid, incoming, default_source) when is_map(incoming) do
    prev = ensure_default(ws, sid, default_source)
    prev_by_id = Map.new(prev["pages"], fn p -> {p["id"], p} end)

    incoming_pages = incoming |> Map.get("pages", []) |> List.wrap()

    pages =
      incoming_pages
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        m = norm_page(p, i)
        # 保留已存源码(改元数据不动源)。
        case Map.get(prev_by_id, m["id"]) do
          %{"source" => src} -> Map.put(m, "source", src)
          _ -> m
        end
      end)
      |> Enum.filter(&(&1["id"] != ""))
      |> Enum.uniq_by(& &1["id"])
      |> Enum.take(@max_pages)
      |> ensure_default_present(prev_by_id)

    active = active_or_first(Map.get(incoming, "active") || prev["active"], pages)
    data = %{"active" => active, "pages" => pages}
    {:ok, write_session(ws, sid, data)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def put_meta(_, _, _, _), do: {:error, :bad_args}

  # 默认页必须在,且置顶(发布物根路由 = 默认页)。
  defp ensure_default_present(pages, prev_by_id) do
    {default, rest} = Enum.split_with(pages, &(&1["id"] == @default_id))

    default_page =
      case default do
        [d | _] -> d
        [] -> Map.get(prev_by_id, @default_id) || fresh_default()
      end

    [default_page | rest]
  end

  defp fresh_default do
    %{
      "id" => @default_id,
      "slug" => @default_id,
      "title" => "首页",
      "salesperson" => true,
      "source" => normalize_source(EzagentPluginLoom.Prompts.loom_seed_files())
    }
  end

  @doc "切换活动页(builder 之后改的就是这页)。"
  @spec set_active(String.t(), String.t(), String.t(), map() | binary() | nil) ::
          {:ok, map()} | {:error, term()}
  def set_active(ws, sid, id, default_source) when is_binary(id) do
    data = ensure_default(ws, sid, default_source)

    if Enum.any?(data["pages"], &(&1["id"] == id)) do
      {:ok, write_session(ws, sid, Map.put(data, "active", id))}
    else
      {:error, :no_such_page}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def set_active(_, _, _, _), do: {:error, :bad_args}

  @doc "回存某页的源码(前端渲染后/切页前回存活动页)。"
  @spec put_source(String.t(), String.t(), String.t(), map() | binary()) ::
          {:ok, map()} | {:error, term()}
  def put_source(ws, sid, id, source) when is_binary(id) do
    data = ensure_default(ws, sid, nil)
    src = normalize_source(source)

    pages =
      Enum.map(data["pages"], fn p ->
        if p["id"] == id, do: Map.put(p, "source", src), else: p
      end)

    {:ok, write_session(ws, sid, Map.put(data, "pages", pages))}
  rescue
    e -> {:error, Exception.message(e)}
  end

  def put_source(_, _, _, _), do: {:error, :bad_args}

  @doc "整盘 seed(发布物打开 / fork / save-template 还原多页)。"
  @spec seed(String.t(), String.t(), map()) :: :ok
  def seed(ws, sid, %{"pages" => list} = data) when is_list(list) and list != [] do
    pages = list |> Enum.with_index() |> Enum.map(fn {p, i} -> norm_page(p, i) end)
    active = active_or_first(Map.get(data, "active"), pages)
    write_session(ws, sid, %{"active" => active, "pages" => pages})
    :ok
  rescue
    _ -> :ok
  end

  def seed(_, _, _), do: :ok

  # ── helpers for builder / publish ──

  @doc "活动页 id(无多页 → 默认 home)。"
  def active_id(ws, sid) do
    case get(ws, sid) do
      %{"active" => a} -> a
      _ -> @default_id
    end
  end

  @doc "活动页源码(builder 读这个 → 改的就是活动页)。无多页 → nil(调用方 fallback slice)。"
  @spec active_source(String.t(), String.t()) :: map() | nil
  def active_source(ws, sid) do
    case get(ws, sid) do
      %{"active" => a, "pages" => pages} ->
        case Enum.find(pages, &(&1["id"] == a)) do
          %{"source" => src} -> src
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc "按 slug 找页(发布页 ?page= 解析用)。"
  def find_by_slug(ws, sid, slug) do
    case get(ws, sid) do
      %{"pages" => pages} -> Enum.find(pages, &(&1["slug"] == slug))
      _ -> nil
    end
  end

  @doc """
  发布/快照/读取用:取全部页。旁路是各页源码的权威(前端每次渲染活动页 + 切页前都回存),
  所以这里**不覆盖**任何页;`default_source` 仅在旁路还没建过时用来 seed 默认页 `home`
  (新会话:builder 刚生成、前端还没 GET 过 pages 的情况)。
  """
  @spec bundle(String.t(), String.t(), map() | binary() | nil) :: map()
  def bundle(ws, sid, default_source) do
    ensure_default(ws, sid, default_source)
  rescue
    _ -> %{"active" => @default_id, "pages" => []}
  end
end
