defmodule Ezagent.World.StateContract do
  @moduledoc """
  Backend-owned minimum mount contract for World renderer families.

  Production payloads may contain additional fields. The maps here are the
  smallest deterministic projections that must still mount the corresponding
  frontend renderer. Tier-1 fixtures consume this contract directly, so adding
  or changing a required field is caught by `mix world.e2e.fixtures --check`.
  """

  @workspace_uri :fixture_workspace_uri
  @session_uri :fixture_session_uri
  @release_session_uri :fixture_release_session_uri
  @caller_uri :fixture_caller_uri
  @terminal_agent_uri :fixture_terminal_agent_uri

  @error_agent_uri :fixture_error_agent_uri
  @fixtures %{
    "overview" => %{
      slot_type: "overview",
      state: %{
        "available_sessions" => [%{"name" => "Alpha support", "uri" => @session_uri}],
        "component" => "overview",
        "kpis" => %{
          "agents" => 2,
          "entities" => 4,
          "kinds" => 6,
          "sessions" => 3,
          "workspaces" => 1
        },
        "path" => "/overview",
        "session_template_names" => ["support"],
        "title" => "Overview",
        "workspace_uri" => @workspace_uri
      }
    },
    "sessions" => %{
      slot_type: "sessions_table",
      state: %{
        "component" => "sessions_table",
        "current_session_uri" => @session_uri,
        "path" => "/sessions",
        "sessions" => [
          %{"name" => "Alpha support", "uri" => @session_uri, "workspace_uri" => @workspace_uri},
          %{
            "name" => "Release room",
            "uri" => @release_session_uri,
            "workspace_uri" => @workspace_uri
          }
        ],
        "templates" => ["support"],
        "title" => "Chat",
        "workspace_uri" => @workspace_uri
      }
    },
    "conversation" => %{
      slot_type: "conversation",
      state: %{
        "active_view" => "conversation",
        "caller_uri" => @caller_uri,
        "component" => "conversation",
        "invite_candidates" => [],
        "members" => [],
        "messages" => [],
        "path" => "/sessions/alpha-support",
        "routing_rules" => [],
        "session_uri" => @session_uri,
        "sessions" => [
          %{"name" => "Alpha support", "uri" => @session_uri, "workspace_uri" => @workspace_uri}
        ],
        "title" => "Alpha support",
        "views" => [%{"id" => "conversation", "label" => "Conversation", "mode" => "chat"}],
        "workspace_uri" => @workspace_uri
      }
    },
    "actionable_errors" => %{
      slot_type: "conversation",
      state: %{
        "active_view" => "conversation",
        "caller_uri" => @caller_uri,
        "component" => "conversation",
        "invite_candidates" => [],
        "members" => [],
        "messages" => [
          %{
            "id" => "g5-layer-1",
            "sender" => @error_agent_uri,
            "sender_display" => "Claude Agent #1",
            "sender_kind" => "agent",
            "text" => "missing credentials",
            "attachments" => [],
            "at" => "2026-07-17T04:20:00Z",
            "actionable_error" => %{
              "code" => "agent.credentials_missing",
              "severity" => "error",
              "layer" => 1,
              "title" => "Agent 缺少访问凭据",
              "what_happened" => "这个 Agent 尚未配置调用模型所需的 API Key。",
              "impact" => "本次消息未能交给模型处理，Agent 无法生成回复。",
              "next_step" => "配置 API Key 后，重新发送本条消息。",
              "action" => %{
                "label" => "配置 API Key",
                "href" => "/identities/agents/claude/api-keys"
              }
            }
          },
          %{
            "id" => "g5-layer-2",
            "sender" => @error_agent_uri,
            "sender_display" => "Claude Agent #1",
            "sender_kind" => "agent",
            "text" => "missing credentials",
            "attachments" => [],
            "at" => "2026-07-17T04:21:00Z",
            "actionable_error" => %{
              "code" => "agent.credentials_missing",
              "severity" => "error",
              "layer" => 2,
              "title" => "Agent 缺少访问凭据",
              "what_happened" => "这个 Agent 尚未配置调用模型所需的 API Key。",
              "impact" => "本次消息未能交给模型处理，Agent 无法生成回复。",
              "next_step" => "请联系 workspace founder 陈瑞华，由其检查 Agent 的凭据配置。",
              "action" => %{
                "label" => "发送提醒给陈瑞华",
                "kind" => "notify_admin"
              }
            }
          },
          %{
            "id" => "g5-layer-3",
            "sender" => @error_agent_uri,
            "sender_display" => "Claude Agent #1",
            "sender_kind" => "agent",
            "text" => "unknown failure",
            "attachments" => [],
            "at" => "2026-07-17T04:22:00Z",
            "actionable_error" => %{
              "code" => "agent.unclassified_failure",
              "severity" => "error",
              "layer" => 3,
              "title" => "Agent 遇到未识别的错误",
              "what_happened" => "系统暂时无法将这次失败归入已知类型。",
              "impact" => "本次消息未能完成处理。",
              "next_step" => "此问题已自动登记（登记号 #1042），团队会跟进处理。",
              "ticket" => "#1042",
              "detail" => "decode=:invalid_json"
            }
          }
        ],
        "path" => "/sessions/alpha-support",
        "routing_rules" => [],
        "session_uri" => @session_uri,
        "sessions" => [
          %{
            "name" => "Alpha support",
            "uri" => @session_uri,
            "workspace_uri" => @workspace_uri
          }
        ],
        "title" => "G5 可行动失败态",
        "views" => [%{"id" => "conversation", "label" => "Conversation", "mode" => "chat"}],
        "workspace_uri" => @workspace_uri
      }
    },
    "kanban" => %{
      slot_type: "kanban",
      state: %{
        "component" => "kanban",
        "instances" => [],
        "miro" => %{"configured" => false},
        "path" => "/plugins/kanban",
        "title" => "Kanban",
        "workspace_uri" => @workspace_uri
      }
    },
    "pty" => %{
      slot_type: "pty_terminal",
      state: %{
        "agent_status" => %{"flavor" => "cc", "phase" => "ready"},
        "agent_uri" => @terminal_agent_uri,
        "component" => "pty_terminal",
        "path" => "/identities/agents/terminal/pty",
        "pty_alive" => false,
        "pty_phase" => "stopped",
        "title" => "Terminal",
        "workspace_uri" => @workspace_uri
      }
    },
    "admin" => %{
      slot_type: "dashboard",
      state: %{
        "component" => "dashboard",
        "kpis" => %{"agents" => 2, "entities" => 4, "sessions" => 3},
        "path" => "/admin",
        "title" => "Admin dashboard",
        "workspace_uri" => @workspace_uri
      }
    },
    "workspace_plugins" => %{
      slot_type: "workspaces_list",
      state: %{
        "component" => "workspaces_list",
        "path" => "/workspaces",
        "title" => "Workspaces",
        "workspace_uri" => @workspace_uri,
        "workspaces" => [
          %{
            "detail_path" => "/workspaces/acme",
            "live" => true,
            "members_count" => 2,
            "name" => "acme",
            "routing_rules_count" => 1,
            "templates_count" => 1,
            "uri" => @workspace_uri
          }
        ]
      }
    }
  }

  @doc "All deterministic minimum-state projections, keyed by fixture name."
  @spec fixtures() :: %{String.t() => %{slot_type: String.t(), state: map()}}
  def fixtures, do: materialize(@fixtures)

  @doc "Required top-level state keys for one registered slot type."
  @spec required_keys(String.t()) :: [String.t()]
  def required_keys(slot_type) when is_binary(slot_type) do
    @fixtures
    |> Map.values()
    |> Enum.find_value(fn
      %{slot_type: ^slot_type, state: state} -> Map.keys(state) |> Enum.sort()
      _fixture -> nil
    end)
    |> case do
      nil -> raise ArgumentError, "no World state contract for slot #{inspect(slot_type)}"
      keys -> keys
    end
  end

  @doc "Validate that a state payload satisfies the minimum mount contract."
  @spec validate!(String.t(), map()) :: map()
  def validate!(slot_type, state) when is_binary(slot_type) and is_map(state) do
    missing = required_keys(slot_type) -- Map.keys(state)

    if missing != [] do
      raise ArgumentError,
            "World state for #{inspect(slot_type)} is missing contract keys: #{inspect(missing)}"
    end

    state
  end

  defp materialize(:fixture_workspace_uri),
    do: "acme" |> Ezagent.URI.workspace() |> URI.to_string()

  defp materialize(:fixture_session_uri),
    do: "acme" |> Ezagent.URI.session("support", "alpha-support") |> URI.to_string()

  defp materialize(:fixture_release_session_uri),
    do: "acme" |> Ezagent.URI.session("support", "release-room") |> URI.to_string()

  defp materialize(:fixture_caller_uri),
    do: "acme" |> Ezagent.URI.user("allen") |> URI.to_string()

  defp materialize(:fixture_error_agent_uri),
    do: "acme" |> Ezagent.URI.agent("claude") |> URI.to_string()

  defp materialize(:fixture_terminal_agent_uri),
    do: "acme" |> Ezagent.URI.agent("terminal") |> URI.to_string()

  defp materialize(%{} = map) do
    Map.new(map, fn {key, value} -> {key, materialize(value)} end)
  end

  defp materialize(list) when is_list(list), do: Enum.map(list, &materialize/1)
  defp materialize(value), do: value
end
