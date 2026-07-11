defmodule Ezagent.Invariants.CapSingleAuthorizationHomeTest do
  @moduledoc """
  I7/C1: `Cap.issue/3` is the single grantor-authorization home, and authority
  is loaded through the configured durable loader rather than supplied by a
  caller. The downstream Identity handler is store-only.
  """
  use ExUnit.Case, async: true

  test "issue authorizes once and the dispatch handler only stores" do
    root = repo_root()
    cap = File.read!(Path.join(root, "apps/ezagent_core/lib/ezagent/cap.ex"))

    identity =
      File.read!(Path.join(root, "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"))

    assert cap =~ "CapabilityRegistry.authorize_grant(caps, cap, context)"
    assert cap =~ "loader.read_held_caps(actor)"
    refute identity =~ "check_grant_authorized"
    refute identity =~ "check_action_wildcard_grant_authorized"
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
