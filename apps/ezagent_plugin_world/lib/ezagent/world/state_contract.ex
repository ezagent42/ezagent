defmodule Ezagent.World.StateContract do
  @moduledoc """
  Backend-owned minimum mount contract for World renderer families.

  Production payloads may contain additional fields. The maps here are the
  smallest deterministic projections that must still mount the corresponding
  frontend renderer. Tier-1 fixtures consume this contract directly, so adding
  or changing a required field is caught by `mix world.e2e.fixtures --check`.
  """

  @workspace_uri "workspace://acme"
  @session_uri "session://acme/support/alpha-support"

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
            "uri" => "session://acme/support/release-room",
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
        "caller_uri" => "entity://acme/user/allen",
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
        "agent_uri" => "entity://acme/agent/terminal",
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
  def fixtures, do: @fixtures

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
end
