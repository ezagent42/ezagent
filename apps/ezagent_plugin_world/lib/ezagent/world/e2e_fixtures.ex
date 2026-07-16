defmodule Ezagent.World.E2EFixtures do
  @moduledoc """
  Deterministic Tier-1 browser projection of the backend World contract.

  These fixtures intentionally contain no Repo/runtime calls. Renderer family,
  slot metadata, plugin navigation and admitted actions are projected from the
  production registries and `StateContract`; real data builders and transport
  remain Tier-2.
  """

  alias Ezagent.World.{DispatchContract, PluginPageRegistry, SlotRegistry, StateContract}

  @version 1

  @doc "JSON-able generated contract used by the static Playwright harness."
  @spec manifest() :: map()
  def manifest do
    %{
      "version" => @version,
      "accepted_actions" => DispatchContract.accepted_actions(),
      "fixtures" =>
        Map.new(StateContract.fixtures(), fn {name, %{slot_type: slot_type, state: state}} ->
          {name, fixture(slot_type, StateContract.validate!(slot_type, state))}
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
    Map.new(StateContract.fixtures(), fn {name, %{slot_type: slot_type}} ->
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
    workspace_uri = "acme" |> Ezagent.URI.workspace() |> URI.to_string()
    caller_uri = "acme" |> Ezagent.URI.user("allen") |> URI.to_string()

    %{
      "renderer_family" => Atom.to_string(slot.renderer_family),
      "slot_type" => slot_type,
      "layout" => %{
        "version" => 1,
        "scope" => workspace_uri,
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
        "entity_uri" => caller_uri,
        "is_system_member" => true,
        "workspace_uri" => workspace_uri,
        "workspaces" => [
          %{"current" => true, "name" => "acme", "uri" => workspace_uri}
        ]
      }
    }
  end
end
