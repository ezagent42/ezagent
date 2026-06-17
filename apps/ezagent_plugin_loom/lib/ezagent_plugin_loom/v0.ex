defmodule EzagentPluginLoom.V0 do
  @moduledoc """
  v0 页面生成 —— loom 原本的 page-builder 逻辑(迁移自 loom-stitch `Behavior.LoomV0Worker`)。

  调 LLM(走对齐的 `EzagentPluginLoom.LLM`,system = `V0Prompts.page_gen_system_prompt`)→
  抽出 ```jsx file=/path``` 多文件 + summary + 可选 stitchConfig → 包成
  `<span type="page_update">{files, source, summary, stitchConfig?}</span>`(`Span` 格式)。
  前端 loom_ui 从消息 body 的 page_update span 读 files → **Sandpack 编译预览**。

  提取逻辑逐字搬 loom v0 worker;只改对接缝:LLM 走对齐客户端。无代码块(纯闲聊/提问)→
  返回 `{:prose, text}`(页面不变);真空回复 → `{:error, :no_jsx_block}`。
  """

  alias EzagentPluginLoom.{LLM, Span, V0Prompts}

  @doc """
  生成/修改页面。`user_text` = 用户需求;`opts`: `:current_files`(当前页 files map,供增量改)、
  `:flavor`/`:model`/`:session_uri`/`:role`。返回:
  - `{:page_update, span_text}` —— 包好的 page_update span(直接当消息 body 发)
  - `{:prose, text}` —— 闲聊/提问的纯文字回复(页面不变)
  - `{:error, reason}`
  """
  @spec generate(String.t(), keyword()) ::
          {:page_update, String.t()} | {:prose, String.t()} | {:error, term()}
  def generate(user_text, opts \\ []) when is_binary(user_text) do
    messages = [
      %{role: "system", content: V0Prompts.page_gen_system_prompt()},
      %{role: "user", content: build_user_message(user_text, opts[:current_files])}
    ]

    case LLM.chat(messages, Keyword.put_new(opts, :role, "v0")) do
      {:ok, reply_text} ->
        stitch_cfg = extract_stitch_config(reply_text)
        files_text = Regex.replace(~r/```stitchConfig\s*\n[\s\S]*?```/, reply_text, "")

        case extract_files_and_summary(files_text) do
          {:ok, files, summary} ->
            base = %{
              "files" => files,
              "source" => Map.get(files, "/App.jsx", ""),
              "summary" => summary
            }

            span_map =
              if is_map(stitch_cfg), do: Map.put(base, "stitchConfig", stitch_cfg), else: base

            {:page_update, Span.span("page_update", span_map)}

          :error ->
            case conversational_reply(files_text) do
              prose when is_binary(prose) and prose != "" -> {:prose, prose}
              _ -> {:error, :no_jsx_block}
            end
        end

      {:error, _} = err ->
        err
    end
  end

  defp build_user_message(user_text, current_files)
       when is_map(current_files) and map_size(current_files) > 0 do
    files_block =
      current_files
      |> Enum.map(fn {path, src} -> "```jsx file=#{path}\n#{src}\n```" end)
      |> Enum.join("\n")

    "当前页面的全部文件:\n#{files_block}\n\n用户需求:\n#{user_text}"
  end

  defp build_user_message(user_text, _), do: user_text

  # ── 提取逻辑(逐字搬 loom v0 worker)──────────────────────────────────────
  @spec extract_files_and_summary(String.t()) ::
          {:ok, %{String.t() => String.t()}, String.t()} | :error
  def extract_files_and_summary(text) when is_binary(text) do
    files =
      ~r/```(?:jsx|tsx|javascript|js|react)?(?:\s+file=(\S+))?[^\n]*\n([\s\S]*?)```/
      |> Regex.scan(text)
      |> Enum.reduce(%{}, fn [_full, path, src], acc ->
        p = normalize_file_path(path)
        src = String.trim(src)
        if protected_file?(p) or src == "", do: acc, else: Map.put(acc, p, src)
      end)
      |> ensure_entry()

    case map_size(files) do
      0 -> :error
      _ -> {:ok, files, extract_summary(text)}
    end
  end

  def extract_files_and_summary(_), do: :error

  defp normalize_file_path(""), do: "/App.jsx"
  defp normalize_file_path(nil), do: "/App.jsx"

  defp normalize_file_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/") -> path
      String.starts_with?(path, "./") -> "/" <> String.trim_leading(path, "./")
      true -> "/" <> path
    end
  end

  defp protected_file?(path) do
    base = path |> Path.basename() |> String.replace(~r/\.(jsx?|tsx?)$/, "")
    base in ~w(platform ezagent-ui)
  end

  defp ensure_entry(files) when map_size(files) == 0, do: files

  defp ensure_entry(files) do
    cond do
      Map.has_key?(files, "/App.jsx") -> files
      map_size(files) == 1 -> %{"/App.jsx" => files |> Map.values() |> hd()}
      true -> files
    end
  end

  defp conversational_reply(text) when is_binary(text),
    do: Regex.replace(~r/```[\s\S]*?```/, text, "") |> String.trim()

  defp conversational_reply(_), do: ""

  defp extract_summary(text) do
    prose = Regex.replace(~r/```[\s\S]*?```/, text, "") |> String.trim()

    case prose |> String.split("\n", trim: true) |> List.first() do
      line when is_binary(line) and line != "" -> String.trim(line)
      _ -> "页面已更新"
    end
  end

  defp extract_stitch_config(text) when is_binary(text) do
    case Regex.run(~r/```stitchConfig\s*\n([\s\S]*?)```/, text) do
      [_, json] ->
        case Jason.decode(String.trim(json)) do
          {:ok, m} when is_map(m) -> m
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_stitch_config(_), do: nil
end
