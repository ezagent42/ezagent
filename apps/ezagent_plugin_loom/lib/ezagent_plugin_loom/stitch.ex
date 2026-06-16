defmodule EzagentPluginLoom.Stitch do
  @moduledoc """
  Loom **Stitch** — 发布页 preview 侧辅助 AI(文档清单 B vertical 独有)。

  访客在发布页跟 Stitch 对话:简短问答 + 可选「drive」(建议一个页面操作,前端执行)。
  务实版用 loom LLM client(curl 平面);完整「orchestrator + 4 sub-worker」体系作后续。
  """

  alias EzagentPluginLoom.{Json, LLM}

  @system """
  你是 loom 发布页的辅助助手 Stitch。访客就当前页面提问,你简短(1-3 句)中文作答。
  若访客的诉求可以转成一个明确的页面操作(切换视图/筛选/高亮/跳转),additionally 给出 drive。
  严格只输出 JSON,不要 markdown:
  {"reply": "给访客看的中文回复", "drive": {"op": "<操作名>", "args": {...}}}
  无明确页面操作时 drive 设为 null。
  """

  @doc """
  Stitch 一轮对话。`opts[:page]` 可传页面上下文摘要。
  返回 `{:ok, %{reply: String.t(), drive: map() | nil}}` | `{:error, reason}`。
  """
  @spec reply(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reply(user_text, opts \\ []) when is_binary(user_text) do
    content =
      case opts[:page] do
        page when is_binary(page) and page != "" -> "当前页面：#{page}\n\n访客：#{user_text}"
        _ -> user_text
      end

    with {:ok, text} <- LLM.chat([%{role: "user", content: content}], Keyword.put(opts, :system, @system)),
         {:ok, %{"reply" => r}} when is_binary(r) <- Json.extract_object(text) do
      drive = parse_drive(text)
      {:ok, %{reply: r, drive: drive}}
    else
      _ -> {:error, :stitch_failed}
    end
  end

  defp parse_drive(text) do
    case Json.extract_object(text) do
      {:ok, %{"drive" => %{"op" => op} = drive}} when is_binary(op) -> drive
      _ -> nil
    end
  end
end
