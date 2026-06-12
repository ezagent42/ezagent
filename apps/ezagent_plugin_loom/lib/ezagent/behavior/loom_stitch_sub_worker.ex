defmodule Ezagent.Behavior.LoomStitchSubWorker do
  @moduledoc """
  Stitch sub-worker Behavior (2026-06-12) — one real worker Kind per Stitch
  role, `entity://agent/<ws>/loomstitchsub_<sid>_<role>`
  (role ∈ chat / navigation / controls / content; see
  `EzagentPluginLoom.StitchExperts`). Spawned for **every** loom session by
  `EzagentPluginLoom.Team.ensure_team/2`.

  @-only (acts only when the orchestrator @mentions it). On a subtask it runs
  one DeepSeek call with its role prompt + the page capabilities it handles,
  and replies to the orchestrator (`ref_id = subtask.id`) with the structured
  result in the message body's `stitch_part` field (`%{kind, say, drive,
  answer}`), so the orchestrator can collect drives + compose. The visible
  text stays a short one-liner (`say`) so the session timeline isn't noisy.

  Preview side = the fast DeepSeek plane (direct `EzagentPluginLoom.DeepSeek`),
  same as the old single-call Stitch — NOT the LLM dispatcher / team brain.
  """

  use Ezagent.Behavior
  @behaviour Ezagent.Behavior

  alias Ezagent.{Cmd, Message}
  alias EzagentPluginLoom.{DeepSeek, StitchExperts}

  action(:receive,
    args: %{message: :map},
    returns: %{},
    caps: [:receive],
    modes: [:cast],
    description:
      "loom stitch sub-worker — handle one Stitch subtask (its role + page caps) → reply a structured stitch_part"
  )

  def required_caps do
    %{receive: Ezagent.Capability.cap(:loomstitchsub, __MODULE__, :receive)}
  end

  def state_slice, do: :loom_stitch_sub

  def init_slice(_args), do: %{count: 0, last_error: nil}

  def handle_receive(%{message: %Message{} = msg}, ctx) do
    if addressed_to_self?(msg, ctx) do
      role_key = role_of(Map.get(ctx, :self_uri))
      role_meta = StitchExperts.role(role_key) || StitchExperts.role("chat")
      sub = sub_payload(msg.body)

      task = to_string(sub["task"] || "")
      user_text = to_string(sub["user_text"] || task)
      kb = to_string(sub["kb"] || "")
      caps = normalize_caps(sub["caps"] || [])
      count = ctx[:read].(:count, 0)

      messages = StitchExperts.worker_messages(role_meta, caps, kb, task, user_text)

      case DeepSeek.chat(messages, temperature: 0.3, thinking_disabled: true) do
        {:ok, raw} ->
          part =
            StitchExperts.parse_part(raw)
            |> Map.merge(%{"worker" => role_key, "label" => role_meta.label, "icon" => role_meta.icon})

          {:ok, %{},
           [{:set, :count, count + 1}, {:set, :last_error, nil}] ++
             reply_effect(ctx, msg, part)}

        {:error, reason} ->
          part = %{
            "kind" => "answer",
            "say" => "失败",
            "drive" => nil,
            "answer" => "",
            "worker" => role_key,
            "label" => role_meta.label,
            "icon" => role_meta.icon
          }

          {:ok, %{}, [{:set, :last_error, reason}] ++ reply_effect(ctx, msg, part)}
      end
    else
      {:ok, %{}, []}
    end
  end

  # role = last underscore segment of `loomstitchsub_<sid>_<role>`.
  @doc false
  @spec role_of(URI.t() | String.t() | nil) :: String.t()
  def role_of(%URI{} = uri), do: role_of(URI.to_string(uri))

  def role_of(s) when is_binary(s) do
    case Regex.run(~r{loomstitchsub_[^/]+_([a-z]+)$}, s) do
      [_full, role] -> role
      _ -> "chat"
    end
  end

  def role_of(_), do: "chat"

  defp sub_payload(body) when is_map(body), do: body["stitch_sub"] || body[:stitch_sub] || %{}
  defp sub_payload(_), do: %{}

  defp normalize_caps(caps) when is_list(caps), do: Enum.filter(caps, &is_map/1) |> Enum.take(40)
  defp normalize_caps(_), do: []

  defp addressed_to_self?(%Message{mentions: mentions}, %{self_uri: %URI{} = self_uri})
       when is_list(mentions) do
    self_str = URI.to_string(self_uri)
    Enum.any?(mentions, fn %URI{} = m -> URI.to_string(m) == self_str; _ -> false end)
  end

  defp addressed_to_self?(_, _), do: false

  # Reply to the orchestrator: visible text = `say` (short); structured result
  # in the body's `stitch_part` field; `ref_id` correlates back to the subtask.
  defp reply_effect(ctx, %Message{} = subtask_msg, part) when is_map(part) do
    with %URI{} = self_uri <- Map.get(ctx, :self_uri),
         %URI{scheme: "session"} = session_uri <- session_from_ctx(ctx) do
      reply =
        Message.new(
          self_uri,
          %{text: to_string(part["say"] || ""), attachments: [], stitch_part: part},
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

  def data_owner(_), do: :no_owner
end
