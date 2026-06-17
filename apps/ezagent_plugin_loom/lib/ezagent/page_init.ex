defmodule Ezagent.PluginLoom.PageInit do
  @moduledoc """
  Loom **每页「初始版本」源码**(2026-06-17)。

  回退历史里要永远有一条「初始版本」——哪怕用户只改了一句、或编辑很多次把最早的
  page_update 挤出了消息窗口,也能一键回到最初。这里**一次性**记下每页**第一次被构建前**
  的源码(= 衍生/发布带过来的种子,或新建页的空种子),之后不再覆盖。

  旁路 JSON:`~/.ezagent/<profile>/loom_page_init.json`,

      %{ "session://loom/<ws>/<sid>" => %{ "<pageid>" => <files map> } }
  """

  defp file_path do
    profile = System.get_env("EZAGENT_PROFILE") || "default"
    Path.expand("~/.ezagent/#{profile}/loom_page_init.json")
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
    :ok
  end

  @doc "**一次性**记某页的初始源码(已记过 / 空源码 → 不动)。"
  @spec capture(String.t(), String.t(), String.t(), map() | nil) :: :ok
  def capture(ws, sid, id, src)
      when is_binary(ws) and is_binary(sid) and is_binary(id) and is_map(src) do
    if map_size(src) > 0 do
      all = load_all()
      sess = Map.get(all, skey(ws, sid), %{})

      if Map.has_key?(sess, id) do
        :ok
      else
        all |> Map.put(skey(ws, sid), Map.put(sess, id, src)) |> save_all()
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def capture(_, _, _, _), do: :ok

  @doc "取某页的初始源码;无 → nil。"
  @spec get(String.t(), String.t(), String.t()) :: map() | nil
  def get(ws, sid, id) when is_binary(ws) and is_binary(sid) and is_binary(id) do
    load_all() |> Map.get(skey(ws, sid), %{}) |> Map.get(id)
  rescue
    _ -> nil
  end

  def get(_, _, _), do: nil
end
