defmodule Ezagent.Behavior.AdminAgent do
  @moduledoc """
  Admin Agent Behavior — handles natural-language admin commands.

  Dispatched from the Admin Session LiveView chat interface. Parses
  intent from free-form text (Chinese or English) and executes the
  corresponding admin operation.

  ## Actions
  - `:process_command` — parse intent and execute admin operation
  """

  use Ezagent.Behavior

  action :process_command,
    args: %{text: :string},
    returns: %{result: :map},
    caps: [:admin_session],
    description: "处理管理员的自然语言命令"

  @doc """
  Handle a natural-language admin command.

  Parses the intent from the text and executes the corresponding
  operation. Currently supports:
  - Publish CR (关键词: 发布)
  - Check status (关键词: 检查)
  """
  def handle_process_command(%{text: text}, _ctx) do
    case parse_intent(text) do
      {:publish_cr, tid} ->
        if Code.ensure_loaded?(EzagentPluginCr.CrEngine) do
          case EzagentPluginCr.CrEngine.publish(tid) do
            {:ok, _result} ->
              {:ok, %{reply: "CR #{tid} 发布成功", action: :publish_cr, tid: tid}, []}

            {:error, reason} ->
              {:ok, %{reply: "CR #{tid} 发布失败: #{inspect(reason)}", action: :publish_cr, tid: tid},
               []}
          end
        else
          {:ok, %{reply: "CR Engine 不可用", action: :publish_cr, tid: tid}, []}
        end

      {:check_status, tid} ->
        {:ok, %{reply: "CR #{tid} 状态检查 (stub)", action: :check_status, tid: tid}, []}

      :unknown ->
        {:ok, %{reply: "命令未识别: #{text}", action: :unknown}, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Intent parsing
  # ---------------------------------------------------------------------------

  defp parse_intent(text) when is_binary(text) do
    cond do
      String.contains?(text, "发布") ->
        {:publish_cr, extract_tid(text)}

      String.contains?(text, "检查") ->
        {:check_status, extract_tid(text)}

      true ->
        :unknown
    end
  end

  defp parse_intent(_), do: :unknown

  # Extract a tenant ID from text. Looks for patterns like "tid:xxx",
  # "tenant xxx", or standalone alphanumeric tokens that look like IDs.
  defp extract_tid(text) do
    cond do
      match = Regex.run(~r/tid[:=]\s*(\S+)/, text) ->
        Enum.at(match, 1)

      match = Regex.run(~r/tenant\s+(\S+)/, text) ->
        Enum.at(match, 1)

      true ->
        "default"
    end
  end
end
