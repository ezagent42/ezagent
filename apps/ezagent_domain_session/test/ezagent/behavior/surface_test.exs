defmodule EzagentDomainInstanceMessage.Behavior.SurfaceTest do
  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Surface
  alias EzagentDomainInstanceMessage.Test.BehaviorInvoker, as: Invoker

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "surface-#{System.unique_integer([:positive])}")
  end

  defp ctx do
    session = session_uri()

    %{
      self_uri: session,
      caller: session,
      authenticated_principal: session,
      caps: MapSet.new(),
      reply: :ignore
    }
  end

  defp empty_surface, do: %{versions: %{}, approved: nil, version_seq: 0}

  test "create initializes immutable page versions and approved pointer" do
    assert {:ok, state} = Surface.create(%{})
    assert state.versions == %{}
    assert state.approved == nil
    assert state.version_seq == 0
  end

  test "put_version appends a retained immutable version and bumps version_seq" do
    tree1 = %{type: "text", props: %{text: "draft one"}}
    tree2 = %{type: "text", props: %{text: "draft two"}}

    assert {:ok, surface, %{version: 1}, _effects} =
             Invoker.invoke_with_effects(
               Surface,
               :put_version,
               empty_surface(),
               %{turn_id: "turn-1", tree: tree1},
               ctx()
             )

    assert surface.version_seq == 1
    assert surface.versions[1] == %{tree: tree1, by_turn: "turn-1"}

    assert {:ok, surface, %{version: 2}, _effects} =
             Invoker.invoke_with_effects(
               Surface,
               :put_version,
               surface,
               %{turn_id: "turn-2", tree: tree2},
               ctx()
             )

    assert surface.version_seq == 2
    assert surface.versions[1] == %{tree: tree1, by_turn: "turn-1"}
    assert surface.versions[2] == %{tree: tree2, by_turn: "turn-2"}
  end

  test "approve sets pointer only for an existing version" do
    tree = %{type: "text", props: %{text: "approved"}}

    {:ok, surface, %{version: version}, _effects} =
      Invoker.invoke_with_effects(
        Surface,
        :put_version,
        empty_surface(),
        %{turn_id: "turn-1", tree: tree},
        ctx()
      )

    assert {:ok, surface, %{approved: ^version}, _effects} =
             Invoker.invoke_with_effects(Surface, :approve, surface, %{version: version}, ctx())

    assert surface.approved == version

    assert {:error, :no_such_version} =
             Invoker.invoke_with_effects(Surface, :approve, surface, %{version: 99}, ctx())
  end

  test "internal tree reads latest while external tree reads approved version" do
    tree1 = %{type: "text", props: %{text: "approved"}}
    tree2 = %{type: "text", props: %{text: "draft"}}

    {:ok, surface, %{version: v1}, _effects} =
      Invoker.invoke_with_effects(
        Surface,
        :put_version,
        empty_surface(),
        %{turn_id: "turn-1", tree: tree1},
        ctx()
      )

    {:ok, surface, _result, _effects} =
      Invoker.invoke_with_effects(Surface, :approve, surface, %{version: v1}, ctx())

    {:ok, surface, %{version: 2}, _effects} =
      Invoker.invoke_with_effects(
        Surface,
        :put_version,
        surface,
        %{turn_id: "turn-2", tree: tree2},
        ctx()
      )

    assert Surface.internal_tree(surface) == tree2
    assert Surface.external_tree(surface) == tree1
  end

  describe "tree_for_version/2" do
    test "returns the tree for an explicit version regardless of the approved pointer" do
      surface = %{
        versions: %{
          1 => %{tree: %{type: "text", props: %{text: "v1"}}},
          2 => %{tree: %{type: "text", props: %{text: "v2"}}}
        },
        approved: 2
      }

      assert Surface.tree_for_version(surface, 1) == %{type: "text", props: %{text: "v1"}}
      assert Surface.tree_for_version(surface, 2) == %{type: "text", props: %{text: "v2"}}
    end

    test "returns nil for a missing version or nil version" do
      surface = %{versions: %{1 => %{tree: %{type: "text"}}}, approved: 1}
      assert Surface.tree_for_version(surface, 99) == nil
      assert Surface.tree_for_version(surface, nil) == nil
      assert Surface.tree_for_version(%{}, 1) == nil
    end
  end
end
