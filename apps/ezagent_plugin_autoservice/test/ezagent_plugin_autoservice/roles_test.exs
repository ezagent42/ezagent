defmodule EzagentPluginAutoservice.RolesTest do
  @moduledoc """
  Re-route Phase 1 regression: the `:admin` role bundle MUST grant caps that
  authorize every `ContentAdmin` action, so the admin UI can dispatch through
  ContentAdmin instead of writing files directly.

  This guards the kind-axis bug found by the 2026-06-17 main-sync recon: the
  bundle once granted `cap(:content, ContentAdmin, …)` while ContentAdmin's
  required_caps use `cap(:workspace, …)` (ContentAdmin dispatches to the
  workspace Kind), so the grant never matched. A single `:workspace`/`:any`
  cap now covers all actions via the action-axis wildcard.
  """
  use ExUnit.Case, async: true

  alias EzagentPluginAutoservice.Roles
  alias EzagentPluginContent.Behavior.ContentAdmin

  describe "bundle(:admin, workspace_uri)" do
    test "authorizes every ContentAdmin action" do
      ws = Ezagent.URI.workspace("roles-admin-test")
      held = Roles.bundle(:admin, ws)

      # Build the `needed` descriptor the way dispatch does (cap_for_action):
      # CONCRETE target instance/workspace, not the `:any` template that
      # required_caps/0 returns — instance_match? has no `(_, :any)` clause,
      # so a held cap scoped to this workspace matches a concrete same-ws need.
      uncovered =
        for {action, req_cap} <- ContentAdmin.required_caps(),
            needed = %{
              kind: req_cap.kind,
              behavior: req_cap.behavior,
              action: action,
              instance: ws,
              workspace_uri: ws
            },
            not Enum.any?(held, &Ezagent.Capability.matches?(&1, needed)),
            do: action

      assert uncovered == [],
             "admin bundle does not authorize ContentAdmin actions: #{inspect(uncovered)}"
    end
  end
end
