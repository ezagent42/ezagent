defmodule Ezagent.Invariants.CapSingleAuthorizationHomeTest do
  @moduledoc """
  I7/C1: `Cap.issue/3` routes every mint through target `K.grant`; that action's
  central verifier is the single grantor-authorization home. The downstream
  Identity handler is store-only.
  """
  use ExUnit.Case, async: true

  test "issue authorizes once and the dispatch handler only stores" do
    root = repo_root()
    cap = File.read!(Path.join(root, "apps/ezagent_core/lib/ezagent/cap.ex"))

    identity =
      File.read!(Path.join(root, "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"))

    assert cap =~ "Ezagent.Cap.Grant.authorize_and_issue_current"
    assert cap =~ "dispatch_grant(target, %Ezagent.Invocation{"
    assert cap =~ "origin: :trusted_internal"

    grant =
      File.read!(Path.join(root, "apps/ezagent_core/lib/ezagent/cap/grant.ex"))

    assert grant =~ "Ezagent.Cap.Verifier.authorize"
    assert grant =~ "Authority.issue_current(intent)"
    refute identity =~ "check_grant_authorized"
    refute identity =~ "check_action_wildcard_grant_authorized"
  end

  defp repo_root do
    {root, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    String.trim(root)
  end
end
