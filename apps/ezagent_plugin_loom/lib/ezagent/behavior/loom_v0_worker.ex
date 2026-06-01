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
  alias EzagentPluginLoom.{DeepSeek, Prompts, Span}

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom v0worker — page-gen DeepSeek call; reply with `<span type=\"page_update\">{source, summary}</span>` body"
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

      case DeepSeek.chat(
             [
               %{"role" => "system", "content" => Prompts.page_gen_system_prompt()},
               %{"role" => "user", "content" => subtask}
             ],
             temperature: 0.7,
             thinking_disabled: true
           ) do
        {:ok, reply_text} ->
          case extract_jsx_and_summary(reply_text) do
            {:ok, source, summary} ->
              body_text = Span.span("page_update", %{"source" => source, "summary" => summary})

              {:ok, %{},
               [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
                 reply_effect(ctx, msg, body_text)}

            :error ->
              {:ok, %{},
               [{:set, :last_error, :no_jsx_block}] ++
                 reply_effect(ctx, msg, Span.error_span(:no_jsx_block))}
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

  # Extract the first ```jsx ... ``` block as source; first non-empty line of
  # the prose around it as summary (fallback "页面已更新" if no prose).
  @doc false
  @spec extract_jsx_and_summary(String.t()) :: {:ok, String.t(), String.t()} | :error
  def extract_jsx_and_summary(text) when is_binary(text) do
    case Regex.run(~r/```(?:jsx|tsx|javascript|js|react)?\s*\n([\s\S]*?)```/, text) do
      [full_match, source] ->
        prose = text |> String.replace(full_match, "", global: false) |> String.trim()

        summary =
          case prose |> String.split("\n", trim: true) |> List.first() do
            line when is_binary(line) and line != "" -> String.trim(line)
            _ -> "页面已更新"
          end

        {:ok, String.trim(source), summary}

      _ ->
        :error
    end
  end

  def extract_jsx_and_summary(_), do: :error

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
          mentions: [subtask_msg.sender]
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
