defmodule Ezagent.ExternalMirror.AdapterTest do
  use ExUnit.Case, async: true

  alias Ezagent.ExternalMirror.Adapter

  defmodule LegacyPullAdapter do
    @behaviour Adapter

    @impl true
    def adapter_id, do: "legacy_pull"

    @impl true
    def display_name, do: "Legacy Pull"

    @impl true
    def description, do: "Pull adapter without live-delivery declarations."

    @impl true
    def adapter_kind, do: :pull

    @impl true
    def cap_subject,
      do: %{
        behavior_module: Ezagent.ExternalMirror.TestSupport.PullAdapter.Allow,
        description: "..."
      }

    @impl true
    def render(%URI{} = _session_uri, _ctx), do: %{}
  end

  defmodule DeclaredPullAdapter do
    @behaviour Adapter

    @impl true
    def adapter_id, do: "declared_pull"

    @impl true
    def display_name, do: "Declared Pull"

    @impl true
    def description, do: "Pull adapter with live-delivery declarations."

    @impl true
    def adapter_kind, do: :pull

    @impl true
    def cap_subject,
      do: %{
        behavior_module: Ezagent.ExternalMirror.TestSupport.PullAdapter.Allow,
        description: "..."
      }

    @impl true
    def render(%URI{} = _session_uri, _ctx), do: %{}

    @impl true
    def delivery_discipline, do: :cursor_replay

    @impl true
    def participation_profile, do: :participatory
  end

  describe "delivery_discipline_of/1" do
    test "defaults to :snapshot_refresh for back-compat pull adapters" do
      assert Adapter.delivery_discipline_of(LegacyPullAdapter) == :snapshot_refresh
    end

    test "returns the adapter-declared discipline when exported" do
      assert Adapter.delivery_discipline_of(DeclaredPullAdapter) == :cursor_replay
    end
  end

  describe "participation_profile_of/1" do
    test "defaults to :read_only for back-compat pull adapters" do
      assert Adapter.participation_profile_of(LegacyPullAdapter) == :read_only
    end

    test "returns the adapter-declared profile when exported" do
      assert Adapter.participation_profile_of(DeclaredPullAdapter) == :participatory
    end
  end
end
