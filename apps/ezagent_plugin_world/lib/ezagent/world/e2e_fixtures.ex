defmodule Ezagent.World.E2EFixtures do
  @moduledoc """
  Deterministic Tier-1 browser projection of the backend World contract.

  These fixtures intentionally contain no Repo/runtime calls. Renderer family,
  slot metadata, plugin navigation and admitted actions are projected from the
  production registries; the state maps are minimal representative payloads for
  the frontend-only gate. Real data builders and transport remain Tier-2.
  """

  alias Ezagent.World.{DispatchContract, PluginPageRegistry, SlotRegistry}

  @version 1

  @fixture_specs %{
    "sessions" =>
      {"sessions_table",
       %{
         "component" => "sessions_table",
         "current_session_uri" => "session://acme/default/alpha-support",
         "path" => "/sessions",
         "sessions" => [
           %{
             "name" => "Alpha support",
             "uri" => "session://acme/default/alpha-support",
             "workspace_uri" => "workspace://acme"
           },
           %{
             "name" => "Release room",
             "uri" => "session://acme/default/release-room",
             "workspace_uri" => "workspace://acme"
           }
         ],
         "templates" => ["default"],
         "title" => "Chat",
         "workspace_uri" => "workspace://acme"
       }},
    "conversation" =>
      {"conversation",
       %{
         "active_view" => "conversation",
         "caller_uri" => "entity://acme/user/allen",
         "component" => "conversation",
         "invite_candidates" => [],
         "members" => [],
         "messages" => [],
         "path" => "/sessions/alpha-support",
         "routing_rules" => [],
         "session_uri" => "session://acme/default/alpha-support",
         "sessions" => [
           %{
             "name" => "Alpha support",
             "uri" => "session://acme/default/alpha-support",
             "workspace_uri" => "workspace://acme"
           }
         ],
         "title" => "Alpha support",
         "views" => [%{"id" => "conversation", "label" => "Conversation", "mode" => "chat"}],
         "workspace_uri" => "workspace://acme"
       }},
    "kanban" =>
      {"kanban",
       %{
         "component" => "kanban",
         "instances" => [],
         "miro" => %{"configured" => false},
         "path" => "/plugins/kanban",
         "title" => "Kanban",
         "workspace_uri" => "workspace://acme"
       }},
    "pty" =>
      {"pty_terminal",
       %{
         "agent_status" => %{"flavor" => "cc", "phase" => "ready"},
         "agent_uri" => "entity://acme/agent/terminal",
         "component" => "pty_terminal",
         "path" => "/identities/agents/terminal/pty",
         "pty_alive" => false,
         "pty_phase" => "stopped",
         "title" => "Terminal",
         "workspace_uri" => "workspace://acme"
       }},
    "admin" =>
      {"dashboard",
       %{
         "component" => "dashboard",
         "kpis" => %{"agents" => 2, "entities" => 4, "sessions" => 3},
         "path" => "/admin",
         "title" => "Admin dashboard",
         "workspace_uri" => "workspace://acme"
       }},
    "workspace_plugins" =>
      {"workspaces_list",
       %{
         "component" => "workspaces_list",
         "path" => "/workspaces",
         "title" => "Workspaces",
         "workspace_uri" => "workspace://acme",
         "workspaces" => [
           %{
             "detail_path" => "/workspaces/acme",
             "live" => true,
             "members_count" => 2,
             "name" => "acme",
             "routing_rules_count" => 1,
             "templates_count" => 1,
             "uri" => "workspace://acme"
           }
         ]
       }}
  }

  @doc "JSON-able generated contract used by the static Playwright harness."
  @spec manifest() :: map()
  def manifest do
    %{
      "version" => @version,
      "accepted_actions" => DispatchContract.accepted_actions(),
      "fixtures" =>
        Map.new(@fixture_specs, fn {name, {slot_type, state}} ->
          {name, fixture(slot_type, state)}
        end)
    }
  end

  @doc "Pretty JSON with a trailing newline, matching the checked-in file."
  @spec manifest_json() :: String.t()
  def manifest_json do
    manifest()
    |> canonical_json()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  @doc "Fixture names and their production renderer families."
  @spec fixture_families() :: %{String.t() => atom()}
  def fixture_families do
    Map.new(@fixture_specs, fn {name, {slot_type, _state}} ->
      {name, SlotRegistry.renderer_family(slot_type)}
    end)
  end

  defp canonical_json(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {key, canonical_json(value)} end)
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Jason.OrderedObject.new()
  end

  defp canonical_json(list) when is_list(list) do
    Enum.map(list, &canonical_json/1)
  end

  defp canonical_json(value), do: value

  defp fixture(slot_type, state) do
    slot = SlotRegistry.slot(slot_type) || raise "unregistered E2E fixture slot: #{slot_type}"

    %{
      "renderer_family" => Atom.to_string(slot.renderer_family),
      "slot_type" => slot_type,
      "layout" => %{
        "version" => 1,
        "scope" => "workspace://acme",
        "components" => [
          %{
            "id" => "e2e-#{slot_type}",
            "type" => slot_type,
            "placement" => %{"x" => 0, "y" => 0, "w" => 12, "h" => 12}
          }
        ]
      },
      "state" => state,
      "plugin_nav" => Enum.map(PluginPageRegistry.pages(), & &1.nav),
      "caller" => %{
        "current_workspace_name" => "acme",
        "display_name" => "Allen",
        "entity_uri" => "entity://acme/user/allen",
        "is_system_member" => true,
        "workspace_uri" => "workspace://acme",
        "workspaces" => [
          %{"current" => true, "name" => "acme", "uri" => "workspace://acme"}
        ]
      }
    }
  end
end
