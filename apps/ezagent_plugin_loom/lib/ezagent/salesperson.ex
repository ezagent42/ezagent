defmodule EzagentPluginLoom.Stitch do
  @moduledoc """
  Stitch 共享逻辑(2026-06-10 重构)。

  原先 Stitch / AiSpot 在 `WebPlug` 里**直连 DeepSeek**。重构后,preview 侧 AI 一律
  走 session 里的 **`loomstitch_<sid>` worker**(`Ezagent.Behavior.LoomStitchWorker`,
  仍调 DeepSeek,但作为 team 成员、@-only、对话进 session 持久化)。本模块抽出与传输无关
  的纯逻辑,供 worker 复用:

  - `system_prompt/2` —— Stitch 聊天系统提示(能力驱动 + DRIVE 强制 + 知识库 grounding)。
  - `aispot_prompt/3` —— AiSpot ✨ 卡片系统提示(紧扣热点 + `[[术语]]` 标注)。
  - `build_messages/3` —— 把历史(带 drive)+ 新输入拼成 DeepSeek messages(防 history 污染)。
  - `parse_reply/1` —— 从回复抽 `DRIVE:` / `OP:` 行 → `{text, op, drive}`。
  """

  # ---- Stitch 聊天系统提示 ----------------------------------------------

  @spec system_prompt([map()], String.t()) :: String.t()
  def system_prompt(caps, kb) do
    caps_json =
      case caps do
        [_ | _] -> Jason.encode!(caps)
        _ -> "[]"
      end

    kb_block =
      case String.trim(kb || "") do
        "" -> "(本页没有提供知识库)"
        k -> k
      end

    """
    你是 Stitch —— 嵌在一个网页里的友好助手。页面作者声明了若干「能力」(见下方 JSON,
    每项是参数化指令集:`options` 可选值 + `commands` 命令形状)。你每次回复,要么**操作页面**,
    要么**回答问题**。

    ════ 输出格式(每次都要,顺序固定:先决策,后动作)════
    **回复的第一行永远先写一行决策说明**,然后才给 DRIVE 行 / OP 行 / 回答正文:
      DECISION: <一句到三句,说清你这次为什么这么决定 —— 为什么选择「操作页面」还是「直接回答」;
                若操作,为什么选这个能力、这个 action、这一项参数;若不操作 / 这页没有对应能力,为什么;
                若是解释 / 闲聊,为什么这么答>
    这行**只给页面作者排查问题用,不会展示给终端用户**,所以请直说你真实的判断依据,别客套。
    写完 DECISION 这一行,再按下面 A)/ B)给出 DRIVE 行、OP 行或回答正文。

    ════ A)操作页面(切换 / 对比 / 筛选 / 排序 / 高亮 / 调数值 / 打开解读)════
    当用户的意图能对应某能力的某 command 时,你**必须**在回复里输出一行机器指令:
      DRIVE: {"id":"<能力 id>","action":"<command.action>","params":<你据 options 自己构造的真实参数>}

    ⛔ **铁律(最重要,违反就是欺骗用户)**:
      **没有输出 DRIVE 行,就绝对不许说「已切换 / 已切到 / 已对比 / 已筛选 / 已高亮 / 已设为 / 已…」
      之类表示"做完了"的话。** 不许只动嘴、不干活。要么 DRIVE 行 + 确认话一起给,要么都别给。

    （历史里若有你过去「已切…」却**没带 DRIVE 行**的回复,那是旧 bug,**别模仿**;也别因此以为
      操作已做完。只要用户这次要切换/对比/筛选,不管你是否觉得页面已是该状态,都**重新输出 DRIVE 行**
      ——这些操作是幂等的,重复发安全。)

    构造要点:
      - `params` 里用 `options` 的 **key**(不是 label、不是 `<占位符>`)自己填;支持任意组合,别被示例局限。
      - 一次最多一行 DRIVE;`options` 里没有的值不要硬编成命令。

    例(设某能力 id="datascope:渠道",options 含 {key:"tb",label:"淘宝"}、{key:"dy",label:"抖音"}):
      用户说「看看淘宝」「只看淘宝」 → 你回:
        DRIVE: {"id":"datascope:渠道","action":"setScope","params":{"scope":"tb"}}
        已切到淘宝渠道。
      用户说「对比淘宝和抖音」 → 你回:
        DRIVE: {"id":"datascope:渠道","action":"setCompare","params":{"pair":["tb","dy"]}}
        已对比淘宝和抖音。

    ════ B)回答问题 / 闲聊 ════
    用户在提问 / 闲聊 / 意图对应不上任何能力时,就**友好具体地回答**,优先依据下方【知识库】;
    知识库没写到的用常识简洁回答或坦诚说"这点资料里没提到"。**绝不要**简单回"抱歉我不懂"。
    若用户想做的操作**这页没有对应能力**,要**如实说**"这个页面暂时没有这个操作"并说明它能做什么
    ——**不要假装操作成功**(这就是上面铁律的另一面)。

    【这页声明的能力】(JSON;每项含 id/label、options[{key,label}]、commands[{action,desc,params}]):
    #{caps_json}

    【知识库】(页面作者写的,作答的首要依据):
    #{kb_block}

    用户明确只想"在某处加段文字"时可输出:
      OP: {"op":"addText","position":"<top|bottom|top-right|top-left|bottom-right|bottom-left>","text":"..."}
    保持简短、友好、中文。
    """
  end

  # ---- AiSpot ✨ 卡片系统提示 -------------------------------------------

  @spec aispot_prompt(String.t(), String.t(), String.t(), [map()]) :: String.t()
  def aispot_prompt(feature, context, kb, caps \\ []) do
    kb_block =
      case String.trim(kb || "") do
        "" -> ""
        k -> "\n这页的知识库(可作依据):\n#{k}\n"
      end

    caps_json =
      case caps do
        [_ | _] -> Jason.encode!(caps)
        _ -> "[]"
      end

    """
    你在为一个网页上的「✨ AI 点」生成一小段有用、与该处强相关的内容。

    **第一行先写一行决策说明,再写卡片正文**(顺序固定):
      DECISION: <为什么生成这块内容、依据是什么;若放了 `[[标记]]`,为什么标这些;若没放,为什么>
    这行**只给页面作者排查用,不进卡片、不展示给终端用户**。写完 DECISION 再写卡片正文。

    卡片正文:直接、具体、口语化中文,2-4 句,**紧扣下面给的这块是什么和它的当前数据/状态**
    (有知识库就结合),不要套话/客套/免责声明。

    回答里可以放**最多 3 个可点击标记**,用 `[[显示词|点击后要对页面助手说的话]]` 语法(竖线左边是
    展示的短词,右边是用户点击时**自动发给助手 Stitch 的那句话**)。两类标记**只标真正有价值的**:

    1. **可解释的实词** —— 知识库里出现的、或有一定门槛/专业性的名词(如 `[[唾液酸|什么是唾液酸?]]`)。
       **普通常识词不要标**(如「价格」「商品」这种谁都懂的不标)。点击 = 让助手解释它。
    2. **真实存在的页面功能** —— **必须**对应下面【这页的能力】里真实存在的某个 command,把它写成
       自然的一句操作话(如 `[[按价格从高到低|按价格从高到低排序]]`、`[[对比标准款和Pro|对比标准款和Pro]]`)。
       点击 = 助手执行该操作。**能力清单里没有的功能,绝对不要编造成标记。**

    无论哪类,点击标记**永远等效于给助手发右边那句话**(助手会自己决定是解释还是执行)。没有合适的就别标。

    【这页的能力】(JSON;据此判断哪些"功能动作"是真实存在的,id/label/options/commands):
    #{caps_json}

    这块功能:#{if feature in [nil, ""], do: "(未命名)", else: feature}
    这块的上下文/数据:#{if context in [nil, ""], do: "(无)", else: context}#{kb_block}
    """
  end

  # ---- 历史 → DeepSeek messages(防 history 污染)----------------------

  # history = [%{"role"=>"user"|"assistant", "text"=>..., "drive"=>map|nil}]。
  # assistant 历史若带 drive,把 `DRIVE: {json}` 行拼回去 → 回放给模型的历史呈现
  # 「确认话 + 机器指令」正确样式(否则模型模仿"只说话不发 DRIVE")。只取最近 16 条。
  @spec build_messages(String.t(), [map()], String.t()) :: [map()]
  def build_messages(system, history, user_text) do
    hist =
      (history || [])
      |> Enum.take(-16)
      |> Enum.map(fn m ->
        role = to_string(m["role"] || m[:role] || "user")
        text = to_string(m["text"] || m[:text] || "")
        drive = m["drive"] || m[:drive]

        content =
          if role == "assistant" and is_map(drive) do
            text <> "\nDRIVE: " <> Jason.encode!(drive)
          else
            text
          end

        %{"role" => role, "content" => content}
      end)

    [%{"role" => "system", "content" => system}] ++
      hist ++ [%{"role" => "user", "content" => to_string(user_text)}]
  end

  # ---- 解析回复 --------------------------------------------------------

  # 从回复里抽 `DECISION:` / `DRIVE: {json}` / `OP: {json}` 行
  # → {显示文本, addText_op|nil, drive|nil, decision|nil}。
  # decision 是模型的「先决策」那行(纯文本,排查用),从可见文本里剔掉。
  @spec parse_reply(String.t()) :: {String.t(), map() | nil, map() | nil, String.t() | nil}
  def parse_reply(raw) when is_binary(raw) do
    lines = String.split(raw, "\n")

    decode_line = fn prefix ->
      lines
      |> Enum.find(fn l -> l |> String.trim() |> String.starts_with?(prefix) end)
      |> case do
        nil ->
          nil

        line ->
          json = line |> String.trim() |> String.replace_prefix(prefix, "") |> String.trim()

          case Jason.decode(json) do
            {:ok, m} when is_map(m) -> m
            _ -> nil
          end
      end
    end

    drive =
      case decode_line.("DRIVE:") do
        %{"id" => id, "action" => action} = m when is_binary(id) and is_binary(action) -> m
        _ -> nil
      end

    op =
      case decode_line.("OP:") do
        %{"op" => _} = o -> o
        _ -> nil
      end

    decision = find_decision(lines)

    text =
      lines
      |> Enum.reject(&control_line?/1)
      |> Enum.join("\n")
      |> String.trim()
      |> case do
        "" -> "好的。"
        t -> t
      end

    {text, op, drive, decision}
  end

  def parse_reply(_), do: {"好的。", nil, nil, nil}

  # AiSpot 用:只切掉 `DECISION:` 行 → {decision|nil, 卡片正文}。
  @spec split_decision(String.t()) :: {String.t() | nil, String.t()}
  def split_decision(raw) when is_binary(raw) do
    lines = String.split(raw, "\n")

    text =
      lines
      |> Enum.reject(fn l -> l |> String.trim() |> String.starts_with?("DECISION:") end)
      |> Enum.join("\n")
      |> String.trim()

    {find_decision(lines), text}
  end

  def split_decision(other), do: {nil, to_string(other)}

  defp find_decision(lines) do
    lines
    |> Enum.find(fn l -> l |> String.trim() |> String.starts_with?("DECISION:") end)
    |> case do
      nil ->
        nil

      line ->
        case line |> String.trim() |> String.replace_prefix("DECISION:", "") |> String.trim() do
          "" -> nil
          d -> d
        end
    end
  end

  defp control_line?(l) do
    t = String.trim(l)

    String.starts_with?(t, "DRIVE:") or String.starts_with?(t, "OP:") or
      String.starts_with?(t, "DECISION:")
  end
end
