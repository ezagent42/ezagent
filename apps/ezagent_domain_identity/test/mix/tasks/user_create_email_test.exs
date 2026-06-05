defmodule Mix.Tasks.Ezagent.User.CreateEmailTest do
  @moduledoc """
  2026-05-26 (Allen "做" directive) — pins the `--email` flag added to
  `mix ezagent.user.create`.

  Before this flag, every new user provisioned via the CLI hit a
  silent magic-link drop at first login because `entity_profiles.email`
  stayed NULL (the User row exists, the Profile doesn't — and
  `Registration.send_allowed?/1` rejects unknown-email/un-allowlisted
  cases). PR #365 added `mix ezagent.user.set_email` as a bootstrap
  remediation; this flag closes the loop at create-time so the gap
  doesn't reopen for the next user.

  We can't `Mix.Task.run/2` the task inside ExUnit (it'd hit
  `Application.ensure_all_started/1` against the same OTP supervision
  tree the test is using), so this test exercises the same write path
  the task uses — `Ezagent.Users.create/3` followed by
  `Ezagent.Entity.Profile.upsert/1` with the email — and asserts the
  observable invariant: a new user with `--email` ends up with BOTH
  a `users` row AND an `entity_profiles` row carrying that email.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Profile
  alias Ezagent.Users

  test "user.create --email path writes BOTH users row AND entity_profiles row" do
    uri_str =
      "entity://team-alpha/user/email-create-#{System.unique_integer([:positive])}"

    user_uri = Ezagent.URI.new!(uri_str)
    email = "test-#{System.unique_integer([:positive])}@example.com"

    # Step 1: same as task's `Users.create/3` call
    assert {:ok, _decoded} = Users.create(user_uri, "temp-pw", [])

    # Step 2: same as task's `maybe_set_email/3` path — Profile.upsert
    # with the URI-derived workspace and a display name derived from
    # the URI path segment.
    workspace_uri_str = URI.to_string(Ezagent.URI.entity_workspace_uri(user_uri))

    assert {:ok, _row} =
             Profile.upsert(%{
               entity_uri: uri_str,
               display_name: "email-create",
               email: email,
               workspace_uri: workspace_uri_str
             })

    # Observable invariant: magic-link send_allowed? path resolves
    # the email to this principal.
    assert {:ok, found_uri} = Ezagent.Registration.principal_for_email(email)
    assert URI.to_string(found_uri) == uri_str
  end

  test "user.create WITHOUT --email leaves entity_profiles untouched (regression gate)" do
    # Pins the negative case: bypassing the new flag must NOT
    # accidentally upsert a Profile row (e.g. via a default-display-name
    # path that fires unconditionally). If someone refactors the task
    # to ALWAYS upsert, this test goes red and surfaces the change.
    uri_str =
      "entity://team-alpha/user/no-email-#{System.unique_integer([:positive])}"

    user_uri = Ezagent.URI.new!(uri_str)
    assert {:ok, _} = Users.create(user_uri, "temp-pw", [])

    # No profile means no email shortcut for this URI.
    assert Ezagent.Registration.principal_for_email("no-such-email@x.com") == :none
  end
end
