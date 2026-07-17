defmodule Ezagent.World.ErrorCode do
  @moduledoc """
  Registry of structured error codes for the G5 general error mechanism.

  Each entry maps a `{:error, reason}` trigger to a structured message card
  with `what` (what happened), `impact` (what it means for the user),
  `fix_path` (where to fix it), and `fix_owner` (who can fix it).

  See `docs/plans/2026-07-17-error-mechanism-sop.md` §2 for the full schema.
  """

  @typedoc "Error code entry following SOP §2 Schema"
  @type t :: %{
    code: String.t(),
    trigger: term(),
    category: atom(),
    message: %{
      what: String.t(),
      impact: String.t(),
      fix_path: atom() | nil,
      fix_owner: atom() | nil
    }
  }

  @doc "Returns all registered error codes."
  @spec all() :: [t()]
  def all do
    [
      # 1 — agent_credential_missing
      %{
        code: "agent_credential_missing",
        trigger: {:error, {:no_api_key, _}},
        category: :credential,
        message: %{
          what: "Agent 未配置凭证",
          impact: "无法调用 AI 模型，你的消息暂时无法得到回复",
          fix_path: :agent_keys_page,
          fix_owner: :workspace_founder
        }
      },
      # 3 — action_unauthorized
      %{
        code: "action_unauthorized",
        trigger: {:error, :unauthorized},
        category: :permission,
        message: %{
          what: "你没有权限执行此操作",
          impact: "如需访问，请联系 workspace founder",
          fix_path: nil,
          fix_owner: :workspace_founder
        }
      }
    ]
  end

  @doc "Looks up an error code by its code string."
  @spec lookup(String.t()) :: t() | nil
  def lookup(code) do
    Enum.find(all(), &(&1.code == code))
  end
end
