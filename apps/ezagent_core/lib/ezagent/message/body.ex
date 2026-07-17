defmodule Ezagent.Message.Body do
  @moduledoc """
  Pure accessors over a `Ezagent.Message` `body` map and its attachment list.

  Shared by the session render path (`Ezagent.ActionSet.Session.Delivery.message_vars/2`)
  and the agent-delivery payload build (`Ezagent.ActionSet.Agent.Delivery`). Lives in
  `ezagent_core` so both the session domain and the agent domain reach these helpers
  without a cross-domain compile edge — keeping the `im → session → agent` dependency
  graph acyclic (the PR-9 domain split).

  Each accessor tolerates both atom-keyed (`%{text: …, attachments: […]}`) and
  string-keyed (`%{"text" => …, "attachments" => […]}`) shapes: inbound JSON arrives
  string-keyed, internal structs arrive atom-keyed.
  """

  @doc "The body's `text`, or `\"\"` when absent or non-binary."
  @spec body_text(term()) :: String.t()
  def body_text(%{text: t}) when is_binary(t), do: t
  def body_text(%{"text" => t}) when is_binary(t), do: t
  def body_text(_), do: ""

  @doc "The body's `attachments` list, or `[]` when absent."
  @spec body_attachments(term()) :: list()
  def body_attachments(%{attachments: list}) when is_list(list), do: list
  def body_attachments(%{"attachments" => list}) when is_list(list), do: list
  def body_attachments(_), do: []

  @doc "The body's structured actionable error, or nil when absent."
  @spec actionable_error(term()) :: map() | nil
  def actionable_error(%{actionable_error: error}) when is_map(error), do: error
  def actionable_error(%{"actionable_error" => error}) when is_map(error), do: error
  def actionable_error(_), do: nil

  @doc "The first attachment's `:local_path` (atom- or string-keyed), or `nil` when none/blank."
  @spec first_attachment_path(term()) :: String.t() | nil
  def first_attachment_path([]), do: nil

  def first_attachment_path([att | _]) do
    case att[:local_path] || att["local_path"] do
      p when is_binary(p) and p != "" -> p
      _ -> nil
    end
  end

  def first_attachment_path(_), do: nil

  @doc "A human-readable hint line summarizing `attachments` (`\"\"` when the list is empty)."
  @spec attachment_hint_text(list()) :: String.t()
  def attachment_hint_text([]), do: ""

  def attachment_hint_text(list) do
    parts =
      Enum.map(list, fn att ->
        type = att[:type] || att["type"] || "unknown"
        name = att[:name] || att["name"] || "?"
        "[attachment: type=#{type} name=#{name}]"
      end)

    Enum.join(parts, " ")
  end
end
