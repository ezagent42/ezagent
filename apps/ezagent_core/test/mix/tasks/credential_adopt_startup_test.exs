defmodule Mix.Tasks.Ezagent.Credential.AdoptStartupTest do
  @moduledoc """
  #17 cascade PR-0 (spec §5.2, codex M3) — the adoption task must start enough of the
  umbrella for its dispatch to ROUTE.

  `mix ezagent.credential.adopt` writes through `Ezagent.Router.dispatch` on the
  `:set_default_credential_source` Behavior. That dispatch needs TWO registrations that
  only land when their owning apps boot:

    * the `Ezagent.Behavior.UserDefaultCredentialSource` action registered on the User
      Kind — owned by `:ezagent_domain_identity`;
    * the `:flavor` `Ezagent.UriQuery` resolver (source-flavor validation) — owned by
      `:ezagent_domain_instance_message`.

  Starting only `:ezagent_core` (the pre-fix behavior) leaves the migration unroutable.

  We cannot `Mix.Task.run/2` the task inside ExUnit (its `ensure_all_started/1` would run
  against the same OTP tree the suite uses — same caveat documented in
  `Mix.Tasks.Ezagent.User.CreateEmailTest`). So this test pins the two halves the task
  depends on:

    1. the task source declares startup of BOTH required domain apps (a deletion of
       either line re-opens the gap silently);
    2. the routability prerequisites those apps provide are actually present — the cap
       action is registered on the User Kind, and `:flavor` resolves (not `:no_resolver`).
  """
  use EzagentCore.DataCase, async: false

  @task_path Path.expand(
               "../../../lib/mix/tasks/ezagent.credential.adopt.ex",
               __DIR__
             )

  test "the adopt task starts the apps that register the Behavior + :flavor resolver" do
    src = File.read!(@task_path)

    assert src =~ "ensure_all_started(:ezagent_domain_identity)",
           "adopt task must start :ezagent_domain_identity (registers the " <>
             "UserDefaultCredentialSource Behavior the dispatch routes to)"

    assert src =~ "ensure_all_started(:ezagent_domain_instance_message)",
           "adopt task must start :ezagent_domain_instance_message (registers the " <>
             ":flavor UriQuery resolver the source-flavor validation needs)"
  end

  test "dispatch prerequisites are present once those apps are started" do
    # `:ezagent_domain_identity` registered the action on the User Kind. The registry
    # resolves the action → Behavior module; a missing registration returns `:error`
    # (the same lookup the dispatch runtime performs at step 6).
    assert {:ok, Ezagent.Behavior.UserDefaultCredentialSource} =
             Ezagent.BehaviorRegistry.lookup(
               Ezagent.Entity.User,
               :set_default_credential_source
             )

    # `:ezagent_domain_instance_message` registered the `:flavor` resolver. A registered
    # resolver returns `:none`/`{:ok, _}`/`{:error, _}` for the probe URI — but NEVER
    # the `{:error, {:no_resolver, _}}` shape that means "unregistered".
    refute match?(
             {:error, {:no_resolver, _}},
             Ezagent.UriQuery.resolve(:flavor, Ezagent.URI.new!("entity://team-a/agent/probe"))
           )
  end
end
