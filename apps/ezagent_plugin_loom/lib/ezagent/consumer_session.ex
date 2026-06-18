defmodule Ezagent.PluginLoom.ConsumerSession do
  @moduledoc """
  「发布消费会话」标记(2026-06-10)。

  loom 会话分两类:
  - **创作会话**:直接从 `session.loom`、或从手存模板(如 zuatu 的 `session.zuatu`)
    实例化 —— 用来编辑/创作页面,**应当有 loom 视图**。
  - **发布消费会话**:`/p/:token/open` 从**已发布模板**(`published:true`)mint 出来的
    per-访客只读消费页(名为 `pub_<hex>`)。它不该出现 loom 编辑视图 tab。

  按**名字**(`pub_` 前缀)判不可靠;按**有没有 v0** 也分不开(zuatu 也无 v0)。真正的
  区别是**创建来源**:是否经 `/p/:token/open` 从发布物 mint。所以在那唯一的创建点
  `mark/2` 打一个**持久标志**,`LoomSessionView.applies_to?/1` 读它来隐藏 loom tab。

  ## 持久化(旁路 JSON)

  `~/.ezagent/<profile>/loom_consumer_sessions.json`,key=session uri → true:

      %{ "session://loom/<ws>/<sid>" => true }
  """

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_consumer_sessions.json")
  end

  defp load_all do
    case File.read(file_path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, m} when is_map(m) -> m
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp save_all(map) when is_map(map) do
    path = file_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true))
  end

  defp key(ws, sid), do: "session://loom/#{ws}/#{sid}"

  @doc "标记某 session 为发布消费会话(无 loom 视图)。在 `/p/:token/open` 调用。"
  @spec mark(String.t(), String.t()) :: :ok
  def mark(ws, sid) when is_binary(ws) and is_binary(sid) do
    all = load_all()

    # 合并而非覆盖:`put_anon` 可能已先写了 `%{"anon"=>uri}`,mark 只加 consumer 标记,
    # 不能把 anon 冲掉。
    entry =
      case Map.get(all, key(ws, sid)) do
        %{} = m -> Map.put(m, "consumer", true)
        _ -> %{"consumer" => true}
      end

    all |> Map.put(key(ws, sid), entry) |> save_all()
    :ok
  rescue
    _ -> :ok
  end

  def mark(_ws, _sid), do: :ok

  @doc """
  记下这个消费会话的 substrate **anon 身份**(`AnonUser.mint` 出来的只读 anon,经
  `AnonBinding` 绑定)。entry 从 legacy `true` 升级成 `%{"consumer"=>true,"anon"=>uri}`,
  `consumer?` 仍兼容两种形态。`consumer_sender` 读它复用稳定身份(每消费会话一个 anon)。
  """
  @spec put_anon(String.t(), String.t(), String.t()) :: :ok
  def put_anon(ws, sid, anon_uri)
      when is_binary(ws) and is_binary(sid) and is_binary(anon_uri) do
    all = load_all()

    # 不隐含 consumer 标记:anon 存储与「是否消费会话」是两件事 —— 创作会话的
    # 导购预览也会 mint anon,但它不是发布消费会话(loom 编辑视图必须留着)。
    entry =
      case Map.get(all, key(ws, sid)) do
        true -> %{"consumer" => true}
        %{} = m -> m
        _ -> %{}
      end

    all |> Map.put(key(ws, sid), Map.put(entry, "anon", anon_uri)) |> save_all()
    :ok
  rescue
    _ -> :ok
  end

  @doc "读这个消费会话已绑定的 substrate anon URI(无 → nil)。"
  @spec anon(String.t(), String.t()) :: String.t() | nil
  def anon(ws, sid) when is_binary(ws) and is_binary(sid) do
    case Map.get(load_all(), key(ws, sid)) do
      %{"anon" => a} when is_binary(a) and a != "" -> a
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def anon(_ws, _sid), do: nil

  @doc "是否是发布消费会话(无 loom 视图)。兼容 legacy `true` 与新的 map entry。"
  @spec consumer?(String.t(), String.t()) :: boolean()
  def consumer?(ws, sid) when is_binary(ws) and is_binary(sid) do
    case Map.get(load_all(), key(ws, sid)) do
      true -> true
      %{"consumer" => true} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def consumer?(_ws, _sid), do: false
end
