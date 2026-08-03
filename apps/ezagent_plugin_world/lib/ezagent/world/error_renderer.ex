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
  @spec render(map() | nil, keyword()) :: card()
  def render(nil, opts) do
    # Layer 3 — unregistered error: auto-register issue
    issue_id = register_issue(nil, opts)

    %{
      layer: 3,
      what: "Agent 执行时遇到内部错误",
      impact: "无法完成你的请求。此问题已自动登记（#{issue_id}），团队会跟进处理",
      fix_link: nil,
      fix_owner_name: nil,
      notify_action: nil,
      issue_id: issue_id
    }
  end

  def render(code, opts) when is_map(code) and is_map_key(code, :code) do
    user_can_fix = Keyword.get(opts, :user_can_fix, false)
    fix_owner_name = Keyword.get(opts, :fix_owner_display_name)
    message = Map.fetch!(code, :message)

    fix_link =
      fix_path_to_url(Map.get(message, :fix_path), Keyword.get(opts, :fix_target_uri))

    cond do
      user_can_fix and is_binary(fix_link) ->
        layer1_card(code, fix_link)

      Map.get(message, :fix_owner) != nil ->
        layer2_card(code, fix_owner_name)

      true ->
        layer3_fallback(code, opts)
    end
  end

  defp layer1_card(code, fix_link) do
    message = Map.fetch!(code, :message)

    %{
      layer: 1,
      what: Map.fetch!(message, :what),
      impact: Map.fetch!(message, :impact),
      fix_link: fix_link,
      fix_owner_name: nil,
      notify_action: nil,
      issue_id: nil
    }
  end

  defp layer2_card(code, fix_owner_name) do
    message = Map.fetch!(code, :message)

    %{
      layer: 2,
      what: Map.fetch!(message, :what),
      impact: Map.fetch!(message, :impact),
      fix_link: nil,
      fix_owner_name: fix_owner_name,
      notify_action: %{
        action: "notification.send",
        args: %{
          type: "error_fix_request",
          body: %{
            error_code: Map.fetch!(code, :code),
            what: Map.fetch!(message, :what)
          }
        }
      },
      issue_id: nil
    }
  end

  defp layer3_fallback(code, opts) do
    issue_id = register_issue(code, opts)
    message = Map.fetch!(code, :message)

    %{
      layer: 3,
      what: Map.fetch!(message, :what),
      impact: Map.fetch!(message, :impact),
      fix_link: nil,
      fix_owner_name: nil,
      notify_action: nil,
      issue_id: issue_id
    }
  end

  defp register_issue(code_or_nil, opts) do
    code_str = if code_or_nil, do: Map.fetch!(code_or_nil, :code), else: "unregistered"

    case Keyword.get(opts, :issue_ref) do
      ref when is_binary(ref) and ref != "" ->
        # Message-anchored render (G5 source 2, async agent errors): the id is
        # derived from the DURABLE message so re-rendering history neither
        # mints a fresh issue per pass nor re-logs — the persisted message is
        # the registration record.
        "G5-#{code_str}-#{ref}"

      _ ->
        ts = System.os_time(:second)
        issue_id = "G5-#{code_str}-#{ts}"

        require Logger
        Logger.warning("[G5 Layer3] Auto-registered issue #{issue_id}: error_code=#{code_str}")

        issue_id
    end
  end

  @doc false
  def fix_path_to_url(:agent_keys_page, %URI{} = agent_uri) do
    encoded_uri = agent_uri |> URI.to_string() |> URI.encode_www_form()
    "/identities/agents/#{encoded_uri}/api-keys"
  end

  def fix_path_to_url(_other, _target_uri), do: nil

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
