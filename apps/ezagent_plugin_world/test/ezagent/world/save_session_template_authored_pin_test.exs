defmodule Ezagent.World.SaveSessionTemplateAuthoredPinTest do
  # SECURITY (codex BLOCKER) — the user-facing template-save socket action must
  # reject a smuggled pinned `config_id`/`content_hash` in `installs`. Otherwise a
  # user with template-authoring authority could author a template whose install
  # pins a PRIVATE foreign-workspace revision by id, which materialization would
  # resolve via a raw `ConfigStore.fetch_object/1` with NO installable-scope gate.
  #
  # The rejection happens at `composition_template_content/4` (the shared author
  # boundary); this test proves it surfaces cleanly through the real
  # `save_session_template/2` action WITHOUT persisting the template.
  use ExUnit.Case, async: true

  alias Ezagent.World.WorkspacePluginActions

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, world_state: %{}}, assigns)
    }
  end

  test "REJECTS a save carrying a user-supplied installs config_id (no persist)" do
    workspace_uri = Ezagent.URI.new!("workspace://authored-pin-save")
    caller = Ezagent.URI.new!("entity://authored-pin-save/user/attacker")

    {:noreply, socket} =
      WorkspacePluginActions.save_session_template(
        socket(%{current_entity_uri: caller, current_workspace_uri: workspace_uri}),
        %{
          "name" => "smuggle-template",
          "installs" => [%{"ref" => "victim", "config_id" => "foreign-private-revision-id"}]
        }
      )

    assert socket.assigns.last_dispatch_status == "error:template_save_failed"

    assert socket.assigns.world_state["template_error"] =~ "socialware_authored_pin_forbidden"
    assert socket.assigns.world_state["template_notice"] == nil
    # never reached the persist step
    assert socket.assigns.world_state["last_template_uri"] == nil
  end
end
