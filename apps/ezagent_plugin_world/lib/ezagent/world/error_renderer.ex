defmodule Ezagent.World.ErrorRenderer do
  @moduledoc """
  Renders a structured error message card from a matched ErrorCode.

  Determines Layer 1 / 2 / 3 based on the current user's permissions
  relative to the error's `fix_path` and `fix_owner`.

  ## Layers

  - **Layer 1** — user has permission to fix the problem.
    Card includes `what`, `impact`, and a clickable fix link.
  - **Layer 2** — user cannot fix; `fix_owner` names who can.
    Card includes `what`, `impact`, who to contact, and a "notify" button.
  - **Layer 3** — error code not found or `fix_owner` is nil.
    Card includes generic `what`/`impact` + auto-registered issue notice.
  """

  alias Ezagent.World.ErrorCode

  @typedoc "Rendered message card for frontend display"
  @type card :: %{
    layer: 1 | 2 | 3,
    what: String.t(),
    impact: String.t(),
    fix_link: String.t() | nil,
    fix_owner_name: String.t() | nil,
    notify_action: map() | nil,
    issue_id: String.t() | nil
  }

  @doc """
  Renders an error card for the given error code and user context.

  `user_can_fix` should be true when the current user has permission to
  access the page identified by `error_code.message.fix_path`.
  `fix_owner_display_name` is the human-readable name of the fix_owner
  (e.g., the workspace founder's display name).
  """
  @spec render(ErrorCode.t() | nil, keyword()) :: card()
  def render(nil, _opts) do
    # Layer 3 — unregistered error
    %{
      layer: 3,
      what: "Agent 执行时遇到内部错误",
      impact: "无法完成你的请求。此问题已自动登记，团队会跟进处理",
      fix_link: nil,
      fix_owner_name: nil,
      notify_action: nil,
      issue_id: nil
    }
  end

  def render(%ErrorCode{} = code, opts) do
    user_can_fix = Keyword.get(opts, :user_can_fix, false)
    fix_owner_name = Keyword.get(opts, :fix_owner_display_name)

    cond do
      user_can_fix and code.message.fix_path != nil ->
        layer1_card(code)

      not user_can_fix and code.message.fix_owner != nil ->
        layer2_card(code, fix_owner_name)

      true ->
        layer3_fallback(code)
    end
  end

  defp layer1_card(code) do
    %{
      layer: 1,
      what: code.message.what,
      impact: code.message.impact,
      fix_link: fix_path_to_url(code.message.fix_path),
      fix_owner_name: nil,
      notify_action: nil,
      issue_id: nil
    }
  end

  defp layer2_card(code, fix_owner_name) do
    %{
      layer: 2,
      what: code.message.what,
      impact: code.message.impact,
      fix_link: nil,
      fix_owner_name: fix_owner_name,
      notify_action: %{
        action: "notification.send",
        args: %{
          type: "error_fix_request",
          body: %{
            error_code: code.code,
            what: code.message.what
          }
        }
      },
      issue_id: nil
    }
  end

  defp layer3_fallback(code) do
    %{
      layer: 3,
      what: code.message.what,
      impact: code.message.impact,
      fix_link: nil,
      fix_owner_name: nil,
      notify_action: nil,
      issue_id: nil
    }
  end

  @doc false
  def fix_path_to_url(:agent_keys_page), do: "/identities/agents/api-keys"
  def fix_path_to_url(_other), do: nil

  @doc """
  Pushes a structured error card to the frontend via `world:state`.

  Used by action modules (ConversationActions, etc.) to replace the
  raw `last_dispatch_status` string with a structured error card.

  Returns the updated socket.
  """
  @spec push_dispatch_error_card(Phoenix.LiveView.Socket.t(), term(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def push_dispatch_error_card(socket, reason, opts \\ []) do
    error_code = Ezagent.World.ErrorMatcher.match({:error, reason})
    card = render(error_code, opts)
    current_state = Map.get(socket.assigns, :world_state, %{})
    new_state = Map.put(current_state, "dispatch_error", card)
    Phoenix.LiveView.push_event(socket, "world:state", new_state)
  end
end
