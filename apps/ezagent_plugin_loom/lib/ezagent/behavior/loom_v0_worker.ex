defmodule Ezagent.Behavior.LoomV0Worker do
  @moduledoc """
  Loom v0worker Behavior — the in-session AI page generator. Sibling to
  `Ezagent.Behavior.LoomWorker` (same dispatch+mention+ref_id contract)
  but with **two** specializations:

  1. Calls DeepSeek with `Prompts.page_gen_system_prompt/0` (the jsx-only
     rules), not the business "fragment" prompt the policy/company workers
     use.
  2. Output is the **first jsx code block** from the model reply, wrapped
     as `<span type="page_update">{source, summary}</span>` (`EzagentPluginLoom.Span.span/2`)
     and sent back into the session. The orchestrator catches it (via
     `worker_deliverable` + page_update detection) and updates its
     `:loom_source` slice; the loom-view bridge picks it up from session
     chat history and re-renders Sandpack.

  ## Loop-guard

  Same as LoomWorker — `handle_receive` only acts when the message
  `@mentions` this v0worker. Anything else → ignore.

  ## Reply addressing

  Reply has `mentions = [subtask_sender]` (= orchestrator) and
  `ref_id = subtask_msg.id`, exactly like LoomWorker. The body is the
  page_update span (vs LoomWorker's plain text fragment).

  See `docs/loom/2026-06-01-loom-as-session-redesign.md` §3.2.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Cmd, Message}
  alias Ezagent.PluginLoom.Materials
  alias EzagentPluginLoom.{LLM, Prompts, Span}

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom v0worker — page-gen Claude Code call; reply with `<span type=\"page_update\">{source, summary}</span>` body"
  )

  # Pin the kind axis `:loomv0` (macro's auto-derived default is `:any`).
  def required_caps do
    %{receive: Ezagent.Capability.cap(:loomv0, __MODULE__, :receive)}
  end

  def state_slice, do: :loom_v0

  def init_slice(_args) do
    %{count: 0, last_error: nil}
  end

  # ---------------------------------------------------------------
  # handle_<action>/2
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    if addressed_to_self?(msg, ctx) do
      subtask = extract_text(msg.body)
      count = ctx[:read].(:count, 0)

      # 2026-06-12 素材库:把本 session 素材目录设为 Claude Code 的 cwd(放开 Read)+ 给它清单;
      # 它需要素材内容时直接 Read 文件,不靠 prompt 塞。无素材 → 不传(行为同前)。
      {mws, msid} = v0_ws_sid(ctx)
      manifest = if mws, do: Materials.render_for_v0(mws, msid), else: ""

      materials_dir =
        if mws && Materials.list(mws, msid) != [], do: Materials.dir(mws, msid), else: nil

      case LLM.chat(
             [
               %{"role" => "system", "content" => Prompts.page_gen_system_prompt()},
               %{"role" => "user", "content" => build_user_message(ctx, subtask, manifest)}
             ],
             temperature: 0.7,
             thinking_disabled: true,
             group: group_id(ctx),
             materials_dir: materials_dir,
             role: "v0"
           ) do
        # 用户中止 → 静默丢弃:不发 page_update、不发 error 卡 → :loom_source 不变、页面不变。
        {:error, :stopped} ->
          {:ok, %{}, []}

        {:ok, reply_text} ->
          # 2026-06-10:先抽可选 stitchConfig,再把该块从文本剥掉(否则会被 file 正则
          # 误当成一个代码块文件)。文件抽取走剥干净的文本。
          stitch_cfg = extract_stitch_config(reply_text)
          files_text = Regex.replace(~r/```stitchConfig\s*\n[\s\S]*?```/, reply_text, "")

          case extract_files_and_summary(files_text) do
            {:ok, files, summary} ->
              # span 带 `files`(权威)+ `source`(= /App.jsx,旧 dist 降级兼容)+ `summary`
              # + 可选 `stitchConfig`(页面助手样式)。
              base = %{
                "files" => files,
                "source" => Map.get(files, "/App.jsx", ""),
                "summary" => summary
              }

              span_map =
                if is_map(stitch_cfg), do: Map.put(base, "stitchConfig", stitch_cfg), else: base

              body_text = Span.span("page_update", span_map)

              {:ok, %{},
               [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
                 reply_effect(ctx, msg, body_text)}

            :error ->
              # 没有代码块:多半是闲聊 / 提问(如「你好」「这个页面能做成商城吗」),LLM
              # 自然只回了文字。把这段文字当**普通对话回复**呈现、页面保持不变 —— 不甩
              # danger 错误卡。只有连文字都没有(真·空回复)才报 :no_jsx_block。
              case conversational_reply(files_text) do
                prose when is_binary(prose) and prose != "" ->
                  {:ok, %{},
                   [{:set, :last_error, nil}] ++ reply_effect(ctx, msg, prose)}

                _ ->
                  {:ok, %{},
                   [{:set, :last_error, :no_jsx_block}] ++
                     reply_effect(ctx, msg, Span.error_span(:no_jsx_block))}
              end
          end

        {:error, reason} ->
          {:ok, %{},
           [{:set, :last_error, reason}] ++
             reply_effect(ctx, msg, Span.error_span(reason))}
      end
    else
      {:ok, %{}, []}
    end
  end

  # 2026-06-02 多文件:收集回复里**所有** ```jsx file=/路径``` 代码块 → files map。
  # - 块标 `file=/x.jsx` → 用该路径;未标 → 兜底 `/App.jsx`(向后兼容旧单块输出)。
  # - 丢弃命中受保护模块名的块(platform / ezagent-ui),agent 写了也不生效。
  # - summary = 所有代码块之外的第一句 prose(fallback "页面已更新")。
  # 返回 `{:ok, files_map, summary}`;一个有效文件都没有 → `:error`。
  @doc false
  @spec extract_files_and_summary(String.t()) ::
          {:ok, %{String.t() => String.t()}, String.t()} | :error
  def extract_files_and_summary(text) when is_binary(text) do
    files =
      ~r/```(?:jsx|tsx|javascript|js|react)?(?:\s+file=(\S+))?[^\n]*\n([\s\S]*?)```/
      |> Regex.scan(text)
      |> Enum.reduce(%{}, fn [_full, path, src], acc ->
        p = normalize_file_path(path)
        src = String.trim(src)

        if protected_file?(p) or src == "" do
          acc
        else
          Map.put(acc, p, src)
        end
      end)
      |> ensure_entry()

    case map_size(files) do
      0 -> :error
      _ -> {:ok, files, extract_summary(text)}
    end
  end

  def extract_files_and_summary(_), do: :error

  # 空(未标 file=)→ /App.jsx;`./x` → `/x`;无前导 / → 补 /。
  defp normalize_file_path(""), do: "/App.jsx"

  defp normalize_file_path(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "/") -> path
      String.starts_with?(path, "./") -> "/" <> String.trim_leading(path, "./")
      true -> "/" <> path
    end
  end

  # 受保护:basename 去扩展名后是 platform / ezagent-ui(不分目录、不分扩展名)。
  defp protected_file?(path) do
    base = path |> Path.basename() |> String.replace(~r/\.(jsx?|tsx?)$/, "")
    base in ~w(platform ezagent-ui)
  end

  # 没有入口但只有一个文件 → 把它当 /App.jsx(兜底)。多文件且缺 /App.jsx 则原样
  # (属 agent 错误,前端会显示缺入口)。
  defp ensure_entry(files) when map_size(files) == 0, do: files

  defp ensure_entry(files) do
    cond do
      Map.has_key?(files, "/App.jsx") -> files
      map_size(files) == 1 -> %{"/App.jsx" => files |> Map.values() |> hd()}
      true -> files
    end
  end

  # 无代码块回复 → 抽出纯文字(剥掉任何残留围栏),当普通对话呈现。空 → "".
  defp conversational_reply(text) when is_binary(text) do
    Regex.replace(~r/```[\s\S]*?```/, text, "") |> String.trim()
  end

  defp conversational_reply(_), do: ""

  defp extract_summary(text) do
    prose = Regex.replace(~r/```[\s\S]*?```/, text, "") |> String.trim()

    case prose |> String.split("\n", trim: true) |> List.first() do
      line when is_binary(line) and line != "" -> String.trim(line)
      _ -> "页面已更新"
    end
  end

  # 2026-06-10 — 抽 ```stitchConfig\n{...}\n``` 块(可选):v0 用它控制页面助手(Stitch)
  # 的**样式/位置**(placement: bottom-right|bottom-center,draggable,accent),功能不变。
  # 前端 loom-bridge 从 page_update 的 stitchConfig 字段读它。无块 → nil。
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

  # ---------------------------------------------------------------
  # boilerplate — mention guard + reply dispatch (copied from LoomWorker)
  # ---------------------------------------------------------------

  defp addressed_to_self?(%Message{mentions: mentions}, %{self_uri: %URI{} = self_uri})
       when is_list(mentions) do
    self_str = URI.to_string(self_uri)

    Enum.any?(mentions, fn
      %URI{} = m -> URI.to_string(m) == self_str
      _ -> false
    end)
  end

  defp addressed_to_self?(_, _), do: false

  defp reply_effect(ctx, %Message{} = subtask_msg, text) when is_binary(text) do
    with %URI{} = self_uri <- Map.get(ctx, :self_uri),
         %URI{scheme: "session"} = session_uri <- session_from_ctx(ctx) do
      reply =
        Message.new(self_uri, %{text: text, attachments: []},
          ref_id: subtask_msg.id,
          mentions: reply_mentions(self_uri, subtask_msg.sender)
        )

      target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

      cmd =
        Cmd.new(target, :send, %{message: reply}, %{
          caller: self_uri,
          caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
          reply: :ignore
        })

      [{:dispatch, cmd}]
    else
      _ -> []
    end
  end

  # 2026-06-05 v0 解耦:v0 可能被**直接 @**(sender=用户),此时编排器收不到这条
  # page_update → loom_source 不更新 → publish/snapshot 失效。所以回复**始终也 @ 编排器**
  # (`loomorch_<sid>`,从 self_uri 的 `loomv0_` 推导),保证编排器缓存源。dedupe:
  # 编排器派发场景 sender 本就是编排器。
  defp reply_mentions(%URI{} = self_uri, sender) do
    case orchestrator_uri(self_uri) do
      %URI{} = orch -> Enum.uniq([sender, orch])
      _ -> [sender]
    end
  end

  defp orchestrator_uri(%URI{} = self_uri) do
    s = URI.to_string(self_uri)

    if String.contains?(s, "/loomv0_") do
      try do
        Ezagent.URI.new!(String.replace(s, "/loomv0_", "/loomorch_"))
      rescue
        _ -> nil
      end
    end
  end

  # 2026-06-09 修 `:no_jsx_block`:**修改请求**(如「改成web端」「换个颜色」)必须让
  # claude 看到当前页面源码,否则它无从下手、只回文字 → 无 jsx 块。这里读编排器
  # `:loom_orchestrator` slice 的 `loom_source`(权威当前页),非种子页时拼进 user 消息,
  # 并明确要求输出完整修改后文件。首次生成(无源/种子页)→ 只发指令(原行为)。
  defp build_user_message(ctx, subtask, materials) do
    case current_source(ctx) do
      files when is_map(files) and map_size(files) > 0 ->
        serialized =
          files
          |> Enum.map(fn {path, code} -> "```jsx file=#{path}\n#{code}\n```" end)
          |> Enum.join("\n\n")

        """
        这是这个页面**当前的完整源码(可能多文件)**:

        #{serialized}
        #{materials}
        ——————
        用户的修改要求:#{subtask}

        请在**上面当前源码的基础上**做这个修改,然后输出**完整的修改后文件代码块**
        (每个文件一个 ```jsx file=/路径``` 块;**即使某文件没改也要原样带上、即使只改一处也要
        输出整份文件**)。平台用你输出的文件整体替换页面——只用文字描述改动、不给完整代码会让
        页面无法更新。
        """

      _ ->
        subtask <> materials
    end
  end

  # 把本次消息附件入库 + 渲染本 session 整个素材库(2026-06-12 素材库)。
  # 从 session 推 {ws, sid}(本 session 素材目录的 key);非 loom session → {nil, nil}。
  defp v0_ws_sid(ctx) do
    with %URI{path: path} <- session_from_ctx(ctx),
         [ws, sid | _] <- path |> to_string() |> String.trim_leading("/") |> String.split("/"),
         true <- ws != "" and sid != "" do
      {ws, sid}
    else
      _ -> {nil, nil}
    end
  end

  # 读编排器当前 loom_source(files map);无 / 为种子占位页 → nil(当首次生成处理)。
  defp current_source(ctx) do
    with %URI{} = self_uri <- Map.get(ctx, :self_uri),
         %URI{} = orch <- orchestrator_uri(self_uri),
         {:ok, slice} when is_map(slice) <- Ezagent.Kind.get_slice(orch, :loom_orchestrator) do
      files =
        EzagentPluginLoom.Prompts.normalize_source(slice[:loom_source] || slice["loom_source"])

      if is_map(files) and map_size(files) > 0 and
           files != EzagentPluginLoom.Prompts.loom_seed_files() do
        files
      else
        nil
      end
    else
      _ -> nil
    end
  end

  defp group_id(ctx) do
    case session_from_ctx(ctx) do
      %URI{} = u -> URI.to_string(u)
      _ -> nil
    end
  end

  defp session_from_ctx(%{caller: %URI{} = u}), do: u

  defp session_from_ctx(%{caller: s}) when is_binary(s) do
    case URI.new(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp session_from_ctx(_), do: nil

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  def data_owner(_), do: :no_owner
end
