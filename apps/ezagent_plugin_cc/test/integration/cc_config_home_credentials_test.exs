defmodule Ezagent.PluginCc.Integration.CcConfigHomeCredentialsTest do
  @moduledoc """
  Chain C — a credential-bearing cc agent must never end up with a config home
  that has no credentials, silently.

  `HostLoginAdopt.ensure_installer_source/3`'s no-op ladder rung 2
  (`host_login_adopt.ex`) refuses to flow the node operator's Claude login to an
  agent a **non-admin** installer caused to exist (#161 / DoD 6 — deliberate).
  Non-admin installers "keep today's resolution (their own pointer, else
  workspace-shared, else NONE)".

  When the answer is NONE, `create_agent_config_dir/4` still materializes the
  per-agent home from the flavor's reference dir and `stage_and_swap/7` writes
  `.ezagent-config-complete` UNCONDITIONALLY — before/independently of any
  credential copy. So the home is "complete" and carries no `.credentials.json`.

  Before this fix everything downstream succeeded SILENTLY:
  `install_session_socialware/1` returned `:ok`, the orchestrator joined the
  session as a member, the PTY launched, and `claude` booted "Not logged in" →
  401 → `esr-bridge` never joined → `require_transport_join/1` never resolved →
  the agent's ReadyGate sat at `:not_ready` forever. **@orchestrator never
  replies**, with no error anywhere. (Reproduced on `origin/main` `bf5e717b`.)

  Same failure #1311 fixed for `cc-headless` (a missing `host_login_dir/0`
  delegate), reached by a different route: a normal logged-in user creating an
  orchestrator-bearing session.

  ## What these tests pin

  The rule lives in the AUTOMATIC materialization lane
  (`Ezagent.Agent.CredentialPrecondition`), NOT in the shared launch gate: an
  un-fillable role slot is **skipped loudly and durably**, the batch continues,
  and no credential-less agent ever becomes a session member.

  `config_dir_launchable?/2` (the chain-B gate) deliberately stays
  credential-agnostic — an operator may create a credential-less cc agent and run
  `claude /login` inside its PTY (Allen, 2026-07-10).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CredentialPrecondition
  alias Ezagent.Credential.HomeRuntime
  alias Ezagent.Entity.{SessionTemplate, User}
  alias Ezagent.PluginCc.Template.CcAgent
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @marker ".ezagent-config-complete"

  defp uniq, do: System.unique_integer([:positive])

  setup do
    recipe = Module.concat([Ezagent, Orchestrator, OrchestratorRecipe]) |> apply(:recipe, [])
    Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  # `config_dir_launchable?/2` is the CHAIN-B gate ("don't launch before the home
  # is materialized"), shared by both lanes. It must NOT grow a credential
  # requirement: an operator may deliberately create a credential-less cc agent
  # and run `claude /login` inside its PTY (Allen, 2026-07-10). The credential
  # rule belongs to the AUTOMATIC materialization lane only.
  describe "config_dir_launchable?/2 (chain B gate — must stay credential-agnostic)" do
    test "still accepts a materialized home with no credentials (interactive-login agent)" do
      dir = Path.join(System.tmp_dir!(), "cc-marker-no-creds-#{uniq()}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, @marker), "ok\n")
      on_exit(fn -> File.rm_rf(dir) end)

      assert HomeRuntime.config_dir_launchable?(dir, CcAgent),
             "tightening this would break the user who logs in inside the PTY"
    end

    test "rejects an un-materialized home (chain B)" do
      dir = Path.join(System.tmp_dir!(), "cc-bare-#{uniq()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      refute HomeRuntime.config_dir_launchable?(dir, CcAgent)
    end
  end

  describe "CredentialPrecondition (the automatic-lane rule)" do
    test "cc is credential-bearing; credential-less flavors are not" do
      assert CredentialPrecondition.credential_bearing?("cc")
      refute CredentialPrecondition.credential_bearing?("py")
      refute CredentialPrecondition.credential_bearing?("curl")
      refute CredentialPrecondition.credential_bearing?("no-such-flavor")
    end

    test "a credential-less flavor is never skipped, whoever the installer is" do
      installer = Ezagent.URI.user(:system, "nobody#{uniq()}")

      assert :ok =
               CredentialPrecondition.check_source(
                 installer,
                 Ezagent.URI.workspace(:system),
                 "py"
               )
    end
  end

  describe "post-create socialware install, non-admin installer (chain C)" do
    test "skips the orchestrator loudly instead of joining a credential-less zombie" do
      template_name = "orch-cred-#{uniq()}"
      ws = Ezagent.URI.workspace(:system)
      {:ok, _} = persist_orchestrator_template(template_name)

      installer = Ezagent.URI.user(:system, "creduser#{uniq()}")
      Ezagent.SpawnRegistry.spawn(installer)

      {:ok, session_uri, _} =
        SessionCreator.create_session("cred-#{uniq()}", installer,
          workspace_uri: ws,
          template_name: template_name
        )

      assert {:ok, summary} = SessionCreator.install_session_socialware(session_uri)

      # The batch completes — an un-fillable role never blocks the rest.
      assert summary.satisfied == []

      assert [%{role_name: "orchestrator", reason: {:no_credential_source, "cc"}}] =
               summary.skipped

      # …and NO credential-less agent joined the session.
      refute orchestrator_member(session_uri),
             "a credential-less orchestrator must never become a session member"

      # …and the skip is DURABLE, so the UI can tell the user (Invariant #9 —
      # a server log alone is a silent drop at a user-facing surface).
      assert [%{role_name: "orchestrator", reason: :missing_credentials}] =
               SessionCreator.unfilled_agent_role_slots(session_uri)
    end

    test "a skipped role does not halt the batch — later slots are still processed" do
      # Pre-fix, `materialize_definition_agents/4` used `reduce_while` +
      # `{:halt, {:error, _}}`: the first un-fillable role aborted every role
      # after it. Two un-fillable cc slots prove the loop now CONTINUES (a single
      # slot would pass even with the old halt-on-first-error).
      ws = Ezagent.URI.workspace(:system)
      installer = Ezagent.URI.user(:system, "batchuser#{uniq()}")
      Ezagent.SpawnRegistry.spawn(installer)

      agents = [
        %{role_name: "orchestrator", fill: :agent, recipe: "orchestrator", flavor: "cc"},
        %{role_name: "second-desk", fill: :agent, recipe: "orchestrator", flavor: "cc"}
      ]

      {:ok, session_uri, _} =
        SessionCreator.create_session("batch-#{uniq()}", installer,
          workspace_uri: ws,
          template_name: "default"
        )

      assert {:ok, summary} =
               DefinitionAgents.materialize_definition_agents(session_uri, ws, installer, agents)

      assert summary.satisfied == []

      assert Enum.map(summary.skipped, & &1.role_name) == ["orchestrator", "second-desk"],
             "the second slot must be reached — a skip is not a halt"
    end

    test "an admin (host-operator) installer still gets a credentialled orchestrator" do
      template_name = "orch-cred-admin-#{uniq()}"
      ws = Ezagent.URI.workspace(:system)
      {:ok, _} = persist_orchestrator_template(template_name)

      {:ok, session_uri, _} =
        SessionCreator.create_session("cred-admin-#{uniq()}", User.admin_uri(),
          workspace_uri: ws,
          template_name: template_name
        )

      assert {:ok, %{skipped: [], satisfied: ["orchestrator"]}} =
               SessionCreator.install_session_socialware(session_uri)

      assert %URI{} = agent_uri = orchestrator_member(session_uri)
      dir = CcAgent.agent_config_dir(agent_uri)
      on_exit(fn -> File.rm_rf(dir) end)

      assert has_credentials?(dir),
             "the host operator's login must reach their own agents"

      assert SessionCreator.unfilled_agent_role_slots(session_uri) == []
    end
  end

  defp has_credentials?(dir) do
    Enum.any?(CcAgent.credential_relpaths(), &File.exists?(Path.join(dir, &1)))
  end

  defp persist_orchestrator_template(name) do
    SessionTemplate.persist_version_as_system(
      %{
        name: name,
        description: "orchestrator-bearing template (chain C regression)",
        members: [],
        prompt_templates: %{},
        installs: ["chat", "orchestrator"],
        legends: %{},
        routing_rules: [],
        default_workspace_uri: Ezagent.URI.workspace(:system),
        parent_template_uri: nil,
        version_tag: nil,
        created_by: nil,
        created_at: nil
      },
      "system"
    )
  end

  defp orchestrator_member(session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} ->
        pid
        |> :sys.get_state()
        |> Map.get(:state, %{})
        |> Map.get(Ezagent.ActionSet.Session.state_slice(), %{})
        |> then(&Map.get(&1, :state, &1))
        |> Map.get(:members, %{})
        |> Enum.find_value(fn {uri, meta} ->
          if Map.get(meta, :role_name) == "orchestrator", do: uri
        end)

      :error ->
        nil
    end
  end
end
