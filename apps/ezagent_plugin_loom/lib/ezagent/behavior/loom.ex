defmodule Ezagent.Behavior.Loom do
  @moduledoc """
  Loom Behavior — DeepSeek-backed bot with two faces:

  - `:say` — scene-card brain. Accepts a multi-turn `messages` list + a
    `persona`, calls DeepSeek, returns a normalized
    `<span type="...">{json}</span>` scene card. Optionally mirrors the
    turn into a bound session (`session` arg) so it shows in the session
    view + syncs to Feishu.
  - `:receive` — chat fan-out hook. Plain friendly reply (NOT scene cards)
    so Feishu/session mirrors stay readable.

  ## New-contract migration (2026-05-29)

  `use Ezagent.Behavior` + `action` macros; `invoke/4` → `handle_<action>/2`
  returning effects. Slice reads via `ctx[:read]`; outbound chat sends are
  `{:dispatch, %Cmd{}}` effects (Router, not the legacy Invocation entry).

  ## Shared modules

  - `EzagentPluginLoom.DeepSeek.chat/2` — the HTTP shell
  - `EzagentPluginLoom.Prompts` — system/persona prompts
  - `EzagentPluginLoom.Span.normalize/1` — raw → `{span, readable}`

  ## Config

  - `DEEPSEEK_KEY` env var on the runtime process (never hard-coded).
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  require Logger

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginLoom.{DeepSeek, Span, Prompts}

  action(:say,
    args: %{messages: {:list, :map}, persona: :string, session: :string},
    returns: %{reply: :string},
    caps: [:say],
    modes: [:call],
    description: "Generate a Loom scene-card (multi-turn messages + persona) via DeepSeek"
  )

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description: "Plain DeepSeek reply into the originating session"
  )

  # Pin the kind axis `:loom` (macro's auto-derived default is `:any`).
  def required_caps do
    %{
      say: Ezagent.Capability.cap(:loom, __MODULE__, :say),
      receive: Ezagent.Capability.cap(:loom, __MODULE__, :receive)
    }
  end

  def state_slice, do: :loom

  def init_slice(_args), do: %{count: 0, last_error: nil}

  # ---------------------------------------------------------------
  # handle_<action>/2 (new contract)
  # ---------------------------------------------------------------

  # `:say` — args %{messages: [...], persona: "visitor", session: "session://..."}
  def handle_say(args, ctx) do
    persona = to_string(Map.get(args, :persona) || Map.get(args, "persona") || "visitor")
    history = build_history(args)
    count = ctx[:read].(:count, 0)

    full =
      [
        %{"role" => "system", "content" => Prompts.web_system_prompt()},
        %{"role" => "system", "content" => Prompts.persona_line(persona)}
      ] ++ history

    case DeepSeek.chat(full, temperature: 0.6, thinking_disabled: true) do
      {:ok, raw} ->
        {span, _readable} = Span.normalize(raw)

        {:ok, %{reply: span},
         [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
           mirror_effects(args, ctx, history, span)}

      {:error, reason} ->
        {:ok, %{reply: Span.error_span(reason)}, [{:set, :last_error, reason}]}
    end
  end

  # `:receive` — chat/session/Feishu path. Plain friendly reply.
  def handle_receive(%{message: %Message{} = msg}, ctx) do
    user_text = extract_text(msg.body)
    count = ctx[:read].(:count, 0)

    case DeepSeek.chat(
           [
             %{"role" => "system", "content" => Prompts.chat_system_prompt()},
             %{"role" => "user", "content" => user_text}
           ],
           []
         ) do
      {:ok, reply} ->
        {:ok, %{},
         [{:set, :count, count + 1}, {:set, :last_error, nil}] ++ reply_effect(ctx, msg, reply)}

      {:error, reason} ->
        {:ok, %{},
         [{:set, :last_error, reason}] ++
           reply_effect(ctx, msg, "⚠️ DeepSeek 调用失败:#{inspect(reason)}")}
    end
  end

  # Mirror the :say turn into a bound session (post the user's message with
  # NO @-mention so it doesn't re-trigger :receive, then Loom's reply).
  # No-op when no `session` arg is given.
  defp mirror_effects(args, ctx, history, reply_span) do
    with s when is_binary(s) and s != "" <- Map.get(args, :session) || Map.get(args, "session"),
         {:ok, %URI{scheme: "session"} = session_uri} <- URI.new(s) do
      user_text = (List.last(history) || %{})["content"] || ""

      send_cmd(session_uri, ctx_caller(ctx), user_text) ++
        send_cmd(session_uri, Map.get(ctx, :self_uri), reply_span)
    else
      _ -> []
    end
  end

  # `:receive` reply back into the originating session (ctx.caller).
  defp reply_effect(ctx, %Message{} = msg, reply_text) do
    case session_uri_from_caller(ctx) do
      nil ->
        []

      %URI{} = session_uri ->
        self_uri = Map.get(ctx, :self_uri)

        case self_uri do
          %URI{} ->
            reply_msg =
              Message.new(self_uri, %{text: reply_text, attachments: []}, ref_id: msg.id)

            target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

            [
              {:dispatch,
               Cmd.new(target, :send, %{message: reply_msg}, %{
                 caller: self_uri,
                 caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
                 reply: :ignore
               })}
            ]

          _ ->
            []
        end
    end
  end

  # Build a `[{:dispatch, %Cmd{}}]` (or `[]`) sending `text` into `session_uri`
  # as `sender_uri`.
  defp send_cmd(_session_uri, nil, _text), do: []
  defp send_cmd(_session_uri, _sender, ""), do: []

  defp send_cmd(%URI{} = session_uri, %URI{} = sender_uri, text) when is_binary(text) do
    msg = Message.new(sender_uri, %{text: text, attachments: []})
    target = URI.new!("#{URI.to_string(session_uri)}?action=chat.send")

    [
      {:dispatch,
       Cmd.new(target, :send, %{message: msg}, %{
         caller: sender_uri,
         caps: Ezagent.SystemPrincipal.caps("system://chat-reply"),
         reply: :ignore
       })}
    ]
  end

  defp send_cmd(_, _, _), do: []

  # --- helpers --------------------------------------------------------

  defp build_history(args) do
    case Map.get(args, :messages) || Map.get(args, "messages") do
      list when is_list(list) and list != [] ->
        Enum.map(list, fn m ->
          %{
            "role" => to_string(Map.get(m, "role") || Map.get(m, :role) || "user"),
            "content" => to_string(Map.get(m, "content") || Map.get(m, :content) || "")
          }
        end)

      _ ->
        msg = to_string(Map.get(args, :msg) || Map.get(args, "msg") || "")
        [%{"role" => "user", "content" => msg}]
    end
  end

  defp ctx_caller(%{caller: %URI{} = u}), do: u

  defp ctx_caller(%{caller: s}) when is_binary(s) do
    case URI.new(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp ctx_caller(_), do: nil

  defp session_uri_from_caller(%{caller: %URI{} = u}), do: u

  defp session_uri_from_caller(%{caller: s}) when is_binary(s) do
    case URI.new(s) do
      {:ok, u} -> u
      _ -> nil
    end
  end

  defp session_uri_from_caller(_), do: nil

  defp extract_text(%{text: t}) when is_binary(t), do: t
  defp extract_text(%{"text" => t}) when is_binary(t), do: t
  defp extract_text(_), do: ""

  def data_owner(_), do: :no_owner
end
