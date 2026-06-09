defmodule EzagentPluginAutoservice.SocialwareCSTest do
  @moduledoc """
  Task 3 — provision a SocialwareSession + soul-driven cc bot (Stage 1).

  ## LIVE-CC BOUNDARY (read before editing this test)

  Creating the real cc bot agent (`Ezagent.Workspace.create_agent` with the
  `cc` flavor) and repointing its #17 user-cascade layer
  (`Ezagent.Socialware.CascadeRepoint.repoint_user_layer/3`) both require a
  LIVE claude environment + a fully-cascaded agent — neither is available in a
  unit test. `repoint_user_layer/3` in particular returns
  `{:error, :no_cascade_resolution}` for any agent that did not come up through
  the cc create cascade.

  So `provision/2` gates the real bot-agent creation + cascade repoint behind
  the `:create_bot_agent` opt (default `true` in prod). This test passes
  `create_bot_agent: false`: the bot is brought up as a plain registered
  entity (so the `chat.join` set-membership requirement — the member URI must
  be registered — is satisfied) but its cascade is NOT repointed. The test
  asserts the STRUCTURAL result, NOT a live claude reply (that is a later live
  task):

    * the session is a `SocialwareSession` with `:turns` + `:surface` slices,
    * the customer is a chat member,
    * the cinnox soul `ConfigObject` resolves on the bot's session layer,
    * the customer→session routing rule exists.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginAutoservice.SocialwareCS
  alias Ezagent.Socialware.ConfigStore

  @routing_table EzagentDomainInstanceMessage.Routing.MentionRouting

  defp ctx do
    %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  test "provision/2 puts the CS session on the socialware base with a soul-driven bot" do
    n = System.unique_integer([:positive])
    workspace = Ezagent.URI.workspace(:team_alpha)
    customer = Ezagent.URI.user(:team_alpha, "cust-#{n}")

    {:ok, %{session_uri: session_uri, bot_uri: bot_uri}} =
      SocialwareCS.provision(customer,
        workspace_uri: workspace,
        ctx: ctx(),
        create_bot_agent: false
      )

    # Derived deterministically from the customer URI.
    assert session_uri == SocialwareCS.session_uri(customer)
    assert bot_uri == SocialwareCS.bot_uri(customer)

    # The session is a SocialwareSession — its Turn + Surface slices are present.
    assert {:ok, _turns} = Ezagent.Kind.get_slice(session_uri, :turns)
    assert {:ok, _surface} = Ezagent.Kind.get_slice(session_uri, :surface)

    # The customer is a chat member of the session.
    {:ok, chat} = Ezagent.Kind.get_slice(session_uri, :chat)
    assert Map.has_key?(chat.members, customer)
    assert Map.has_key?(chat.members, bot_uri)

    # The cinnox soul ConfigObject resolves on the bot's session layer.
    {:ok, soul} = ConfigStore.resolve("session", workspace, bot_uri, "soul")
    assert soul.body["soul_md"] =~ "IDENTITY"

    # The customer→session routing rule exists (workspace-scoped to this ws).
    rules = Ezagent.Routing.RuleStore.list(@routing_table)
    session_str = URI.to_string(session_uri)

    assert Enum.any?(rules, fn r ->
             session_str in (r.receivers || [])
           end)
  end
end
