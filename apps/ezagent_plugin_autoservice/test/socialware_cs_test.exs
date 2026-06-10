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

    # The customer→bot routing rule exists (workspace-scoped to this ws).
    # The BOT is the receiver — that's how the live cc bot gets the customer
    # message and replies; the Turn adapter listens on the PubSub
    # session-events topic and needs no routing receiver.
    rules = Ezagent.Routing.RuleStore.list(@routing_table)
    session_str = URI.to_string(session_uri)
    bot_str = URI.to_string(bot_uri)

    rule = Enum.find(rules, fn r -> inspect(r.matcher_data) =~ session_str end)

    assert rule, "expected a routing rule scoped to #{session_str}"
    assert bot_str in (rule.receivers || [])
  end

  describe "materialize_skill/2 (Task 4)" do
    @stage1_skill "customer-type-clarifier"

    test "writes the Stage-1 SKILL.md into the bot working dir at the expected skills path" do
      work_dir =
        Path.join(System.tmp_dir!(), "cs-skill-test-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(work_dir) end)

      assert :ok = SocialwareCS.materialize_skill(work_dir, @stage1_skill)

      skill_file =
        Path.join([
          work_dir,
          "plugins",
          "cinnox",
          "skills",
          "customer",
          @stage1_skill,
          "SKILL.md"
        ])

      assert File.exists?(skill_file)

      # Real vendored content materialized (stable phrase from the SKILL body).
      content = File.read!(skill_file)
      assert content =~ "Weak-Signal Customer-Type Clarifier"
    end

    test "is idempotent — re-materializing converges, no error" do
      work_dir =
        Path.join(System.tmp_dir!(), "cs-skill-test-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(work_dir) end)

      assert :ok = SocialwareCS.materialize_skill(work_dir, @stage1_skill)
      assert :ok = SocialwareCS.materialize_skill(work_dir, @stage1_skill)
    end
  end

  describe "ensure_joined/1 (CustomerLive mount path)" do
    test "on an already-provisioned customer returns the session URI and the session stays a SocialwareSession" do
      n = System.unique_integer([:positive])
      workspace = Ezagent.URI.workspace(:team_alpha)
      customer = Ezagent.URI.user(:team_alpha, "cust-joined-#{n}")

      {:ok, %{session_uri: session_uri}} =
        SocialwareCS.provision(customer,
          workspace_uri: workspace,
          ctx: ctx(),
          create_bot_agent: false
        )

      assert {:ok, ^session_uri} = SocialwareCS.ensure_joined(customer)

      # Still the socialware base — Turn + Surface slices present.
      assert {:ok, _turns} = Ezagent.Kind.get_slice(session_uri, :turns)
      assert {:ok, _surface} = Ezagent.Kind.get_slice(session_uri, :surface)

      # Customer is (still) a chat member.
      {:ok, chat} = Ezagent.Kind.get_slice(session_uri, :chat)
      assert Map.has_key?(chat.members, customer)
    end

    test "on a fresh customer spawns a SocialwareSession (NOT a bare Session) and joins the customer" do
      n = System.unique_integer([:positive])
      customer = Ezagent.URI.user(:team_alpha, "cust-fresh-#{n}")

      assert {:ok, session_uri} = SocialwareCS.ensure_joined(customer)
      assert session_uri == SocialwareCS.session_uri(customer)

      # A bare Ezagent.Entity.Session has no :turns / :surface slices —
      # their presence proves the socialware Kind type was spawned.
      assert {:ok, _turns} = Ezagent.Kind.get_slice(session_uri, :turns)
      assert {:ok, _surface} = Ezagent.Kind.get_slice(session_uri, :surface)

      {:ok, chat} = Ezagent.Kind.get_slice(session_uri, :chat)
      assert Map.has_key?(chat.members, customer)
    end
  end
end
