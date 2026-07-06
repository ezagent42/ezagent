defmodule EzagentPluginKanban.BoardViewTest do
  @moduledoc """
  S4 unit gate for `EzagentPluginKanban.BoardView` — the kanban-team board
  `Ezagent.UI.SessionView` DECLARATION（照 hello `PageView` 先例）.

  Declaration-side only: the view + its json-render tree live in the kanban
  plugin; world consumes the registry generically (world-views #1192/#1199) —
  ZERO world changes here. What this test locks:

    * the `SessionView` contract surface (id/label/icon);
    * cap-gating: `view_behavior/0 → Ezagent.ActionSet.KanbanRender`, so
      `SessionView.authorize_view/3` requires `{Session, :kanban_render}`;
    * `applies_to?/1` is FAIL-SAFE and keyed on the kanban-team Definition
      being installed (a session without it → false, junk input → false);
    * the external target: `external_render?/0 → true` +
      `external_render/1` delegating to the read-only board projection.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginKanban.BoardView

  test "implements Ezagent.UI.SessionView with the kanban board identity" do
    assert Enum.member?(
             BoardView.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten(),
             Ezagent.UI.SessionView
           )

    assert BoardView.id() == :kanban_board
    assert BoardView.label() == "看板"
    assert is_binary(BoardView.icon()) and BoardView.icon() != ""
  end

  test "is cap-gated by the KanbanRender view read ActionSet (T2-2b)" do
    assert BoardView.view_behavior() == Ezagent.ActionSet.KanbanRender

    # the gate has a concrete cap to check (same shape Installation mints).
    session_uri = Ezagent.URI.session("ws-bv", "kanban", "s1")

    assert [%Ezagent.Capability{action: :kanban_render}] =
             Ezagent.UI.SessionView.render_needed_caps(Ezagent.ActionSet.KanbanRender, session_uri)
  end

  test "applies_to?/1 is false for a session without the kanban-team Definition (fail-safe)" do
    # no install rows for this session (and no DB checkout in this async test) —
    # the check must degrade to false, never raise.
    refute BoardView.applies_to?(Ezagent.URI.session("ws-bv", "kanban", "not-installed"))
  end

  test "applies_to?/1 is false for junk input (fail-safe)" do
    refute BoardView.applies_to?(nil)
    refute BoardView.applies_to?("not a uri")
    refute BoardView.applies_to?(Ezagent.URI.workspace("ws-bv"))
  end

  test "declares an EXTERNAL json-render target delegating to KanbanRender" do
    assert BoardView.external_render?()

    # no board in this workspace → nil (nothing to render externally yet),
    # per the SessionView external_render/1 contract; junk input → nil.
    assert BoardView.external_render(Ezagent.URI.session("ws-bv-none", "kanban", "s2")) == nil
    assert BoardView.external_render(nil) == nil
  end
end
