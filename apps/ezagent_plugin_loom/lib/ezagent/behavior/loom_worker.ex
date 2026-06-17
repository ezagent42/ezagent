defmodule Ezagent.Behavior.LoomWorker do
  @moduledoc """
  Loom worker Behavior (loom v0.2, G-E) — a DeepSeek "干活 agent" that
  ONLY responds to a subtask the orchestrator addressed to it, produces a
  content fragment, and replies to the orchestrator with a `ref_id`
  pointing back at the subtask message.

  ## New-contract migration (2026-05-29)

  `use Ezagent.Behavior` + `action :receive` macro; the old
  `invoke(:receive, slice, args, ctx)` is now `handle_receive(args, ctx)`
  returning effects. Slice reads via `ctx[:read].(:key, default)`;
  the orchestrator reply is a `{:dispatch, %Cmd{}}` effect (NOT
  `Invocation.dispatch` — §11 Gate 3: plugin Behaviors use `Router`).

  ## Loop-guard (PRD §5.3 — no message storm)

  `:receive` fires for EVERY session message routed to this worker. The
  worker acts ONLY when the message `@mentions` itself. Any other message
  is IGNORED (no effects, no reply) — defense in depth against feedback
  storms.

  ## Reply addressing (correlation = `ref_id`)

  Replies are `chat.send` into the originating session with
  `mentions = [orchestrator_uri]` (= the subtask sender) and
  `ref_id = subtask_msg.id` so the orchestrator can correlate the
  deliverable to the turn it fanned out.

  ## Theme prompt

  The worker's system prompt + role come from its `:loom_worker` slice
  (`system_prompt` / `role`); the two demo workers derive a 政策/企业 theme
  from their URI name (`loomworker_<sid>_policy` / `_company`).
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginLoom.LLM

  @default_system_prompt ~S"""
  你是Loom 科技企业孵化器编排团队里的一名 worker。编排器会把一个子任务交给你,
  你只产出该子任务对应的**一段内容片段**(中文、简洁、具体,可合理虚构园区/政策/企业细节使其逼真),
  不要寒暄,不要输出卡片或 JSON,只回正文片段。编排器会把多名 worker 的片段组合后再回给用户。
  """

  @theme_prompts %{
    "policy" => ~S"""
    你是Loom 孵化器编排团队的【政策侧】worker。编排器交给你一个子任务时,
    你只产出**政策/资源面**的内容片段:政策名称、扶持额度、申报截止、研发费用加计扣除、
    人才公寓与落户、首台套保险补偿等(可合理虚构使其逼真,数字每次可不同)。
    中文、简洁,不寒暄,不输出卡片或 JSON,只回正文片段。
    """,
    "company" => ~S"""
    你是Loom 孵化器编排团队的【企业侧】worker。编排器交给你一个子任务时,
    你只产出**企业匹配/对接面**的内容片段:企业名、所在赛道、匹配度 fit、对接路径、
    产线规模、轮次估值等(可合理虚构使其逼真)。
    中文、简洁,不寒暄,不输出卡片或 JSON,只回正文片段。
    """
  }

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom worker — produce a Claude Code content fragment for an orchestrator subtask and reply (ref_id correlated)"
  )

  # Pin the kind axis `:loomworker` (macro's auto-derived default is `:any`).
  def required_caps do
    %{receive: Ezagent.Capability.cap(:loomworker, __MODULE__, :receive)}
  end

  def state_slice, do: :loom_worker

  def init_slice(args) do
    %{
      system_prompt:
        to_string(
          Map.get(args, :system_prompt) || Map.get(args, "system_prompt") ||
            @default_system_prompt
        ),
      role: to_string(Map.get(args, :role) || Map.get(args, "role") || "worker"),
      count: 0,
      last_error: nil
    }
  end

  # ---------------------------------------------------------------
  # handle_<action>/2 (new contract)
  # ---------------------------------------------------------------

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    if addressed_to_self?(msg, ctx) do
      subtask = extract_text(msg.body)
      system_prompt = system_prompt_for(ctx)
      count = ctx[:read].(:count, 0)
      role = ctx[:read].(:role, "worker")

      case LLM.chat(
             [
               %{"role" => "system", "content" => system_prompt},
               %{"role" => "user", "content" => subtask}
             ],
             temperature: 0.6,
             thinking_disabled: true,
             group: group_id(ctx)
           ) do
        {:ok, fragment} ->
          {:ok, %{},
           [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
             reply_effect(ctx, msg, fragment)}

        # 用户中止 → 静默,不回任何卡(否则会在会话里留个"失败"卡)。
        {:error, :stopped} ->
          {:ok, %{}, []}

        {:error, reason} ->
          # silent-drop guard (PRD §8): tell the orchestrator the worker
          # failed so its aggregation can degrade rather than wait for a timeout.
          {:ok, %{},
           [{:set, :last_error, reason}] ++
             reply_effect(ctx, msg, "⚠️ worker(#{role}) 失败:#{inspect(reason)}")}
      end
    else
      # loop-guard: not a subtask addressed to me → ignore, no reply.
      {:ok, %{}, []}
    end
  end

  # Addressed to self iff this worker's URI is in the message's mentions.
  defp addressed_to_self?(%Message{mentions: mentions}, %{self_uri: %URI{} = self_uri})
       when is_list(mentions) do
    self_str = URI.to_string(self_uri)

    Enum.any?(mentions, fn
      %URI{} = m -> URI.to_string(m) == self_str
      _ -> false
    end)
  end

  defp addressed_to_self?(_, _), do: false

  # Build the `{:dispatch, %Cmd{}}` effect that replies to the orchestrator
  # (ref_id correlated, @mentioning the subtask sender). Empty list when
  # self/session URIs are unavailable.
  defp reply_effect(ctx, %Message{} = subtask_msg, text) when is_binary(text) do
    with %URI{} = self_uri <- Map.get(ctx, :self_uri),
         %URI{scheme: "session"} = session_uri <- session_from_ctx(ctx) do
      reply =
        Message.new(self_uri, %{text: text, attachments: []},
          ref_id: subtask_msg.id,
          mentions: [subtask_msg.sender]
        )

      target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")

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

  # Pick the system prompt: theme keyed off this worker's own URI name,
  # else the generic slice default.
  defp system_prompt_for(ctx) do
    case theme_for(Map.get(ctx, :self_uri)) do
      nil -> ctx[:read].(:system_prompt, @default_system_prompt)
      theme -> Map.fetch!(@theme_prompts, theme)
    end
  end

  @doc """
  Derive a worker's theme (`"policy"` / `"company"` / `nil`) from its URI
  name. Pure — the demo's two workers are `loomworker_<sid>_policy` /
  `loomworker_<sid>_company`.
  """
  @spec theme_for(URI.t() | String.t() | nil) :: String.t() | nil
  def theme_for(%URI{} = uri), do: theme_for(URI.to_string(uri))

  def theme_for(s) when is_binary(s) do
    cond do
      String.contains?(s, "policy") -> "policy"
      String.contains?(s, "company") -> "company"
      true -> nil
    end
  end

  def theme_for(_), do: nil

  # On the chat.receive path, `ctx.caller` is the originating session URI.
  # 停止用的 group = 本 session 字符串(stop/1 据此中断本 session 全部 claude)。
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
